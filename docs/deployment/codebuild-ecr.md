# ECR Image Build and Push

## 1. Decision

Images are built locally and pushed to Amazon ECR manually.

CodeBuild is not used. The manual approach is simpler for a single-operator
thesis experiment where builds happen infrequently and the researcher controls
the full pipeline.

The image build and push step must happen **before** `terraform apply` and
before deploying to EKS. This ensures deployment manifests always point to
real, immutable image tags.

---

## 2. ECR Repositories

ECR repositories are persistent resources. Create them once and reuse across
all experiment runs. They are not managed by Terraform.

| Image | ECR repository |
|---|---|
| Monolith | `skripsi/monolith` |
| API Gateway | `skripsi/api-gateway` |
| Auth Service | `skripsi/auth-service` |
| Item Service | `skripsi/item-service` |
| Transaction Service | `skripsi/transaction-service` |
| Seed Runner | `skripsi/seed-runner` |
| k6 Runner | `skripsi/k6-runner` |

---

## 3. Image Tag Strategy

Use git short SHA as the image tag.

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
```

Do not use `latest`. ECR repositories use immutable tags.

The image tag used during benchmark execution is recorded in `metadata.json`
for reproducibility.

---

## 4. Workflow

This is the required order. Do not skip or reorder steps.

### Step 1 — Create ECR repositories (one-time)

```bash
make aws-create-ecr
```

Only needed once. Skip if repositories already exist.

### Step 2 — Login to ECR

```bash
make aws-ecr-login
```

### Step 3 — Build and push all images

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
make ecr-push-all IMAGE_TAG=$IMAGE_TAG
# Override explicitly, for example: IMAGE_TAG=<tag>
```

### Step 4 — Optional Preflight: Render EKS manifests with the pushed image tag

```bash
make eks-render-manifests IMAGE_TAG=$IMAGE_TAG
# Optional manual preflight. eks-deploy-* reruns this automatically.
```

This renders:

- EKS application Deployments,
- EKS migration / reset / seed / prepare Jobs,
- benchmark k6 Jobs,
- Datadog version labels,
- benchmark `IMAGES_JSON` metadata payloads.

The EKS deploy scripts now rerun the same rendering step automatically before
validation and `kubectl apply`. Manual execution remains useful when you want
to inspect the rendered manifests before deployment. If you deploy a non-default
tag, pass the same `IMAGE_TAG` to the deploy command.

The deploy scripts still accept the shorter implicit form without `IMAGE_TAG`,
because they derive the tag from `git rev-parse --short HEAD` at execution
time. The explicit pinned-tag pattern is documented as the default workflow so
the pushed image tag and the deployed manifest tag remain identical across the
same session.

### Step 5 — Apply Terraform and deploy

Only after Steps 1–4 are complete:

```bash
make eks-shared-apply
make eks-apply
make eks-setup-contexts
make eks-validate-manifests
# create cluster secrets
make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
# install Datadog
```

---

## 5. ECR Repository Configuration

`make aws-create-ecr` creates repositories with:

```text
Tag mutability : IMMUTABLE
Scan on push   : not configured by this command
```

Optional lifecycle policy to keep storage bounded (apply via AWS console or CLI):

```json
{
  "rules": [{
    "rulePriority": 1,
    "description": "Keep last 10 tagged images",
    "selection": {
      "tagStatus": "tagged",
      "tagPatternList": ["*"],
      "countType": "imageCountMoreThan",
      "countNumber": 10
    },
    "action": { "type": "expire" }
  }]
}
```

---

## 6. IAM Requirements

The AWS user running `make ecr-push-all` needs ECR push permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "ecr:GetAuthorizationToken",
    "ecr:BatchCheckLayerAvailability",
    "ecr:CompleteLayerUpload",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart"
  ],
  "Resource": "arn:aws:ecr:ap-southeast-1:<account_id>:repository/skripsi/*"
}
```
