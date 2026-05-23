# Terraform Runbook

## 1. Purpose

Step-by-step guide for provisioning and destroying the dual EKS cluster
benchmark infrastructure.

---

## 2. Prerequisites

```text
- AWS CLI configured with admin credentials
- Terraform >= 1.6 installed
- kubectl installed
- helm installed
- AWS region: ap-southeast-1
```

### Terraform-Compatible AWS Profile

This repository assumes interactive sign-in is done with `aws login`, but
Terraform itself must use a companion profile that exposes those short-lived
credentials through `credential_process`.

Recommended local `~/.aws/config` layout:

```ini
[default]
login_session = arn:aws:iam::018982314415:user/muf-admin
region = us-east-1

[profile terraform-process]
credential_process = aws configure export-credentials --profile default --format process
region = ap-southeast-1
```

Operator rules:

- do not commit AWS credentials into the repository
- do not copy access keys, session tokens, or secret keys into `env/` or
  `terraform.tfvars`
- do not let repository scripts mutate `~/.aws/config`
- keep `terraform-process` as the standard local profile name unless you
  intentionally override `TERRAFORM_AWS_PROFILE`

Verify the auth bridge before any Terraform apply or destroy:

```bash
aws login
make terraform-auth-check
```

For interrupted apply or destroy recovery, use:

```bash
make terraform-recovery-check
```

This command is audit-only. It does not mutate Terraform state or AWS
resources. It compares local Terraform state with live AWS state for the
critical benchmark resources:

- shared VPC
- shared IAM role
- EKS clusters
- EKS managed node groups
- EKS pod identity associations
- EKS `eks-pod-identity-agent` add-on
- RDS instances

Expected status classes:

- `OK`
- `STALE_IN_STATE`
- `IN_PROGRESS`
- `REVIEW`
- `BLOCKED`

Use this after:

- laptop sleep or shutdown during `terraform apply`
- network interruption during apply or destroy
- AWS session expiration during Terraform execution
- manual AWS CLI cleanup that may have drifted local Terraform state

Quick verification checklist for the `shared` stack before applying a new
`experiment` stack:

```bash
aws login
make terraform-auth-check
make terraform-recovery-check
AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/shared plan -input=false -lock=false
```

Healthy expected outcome:

- `make terraform-auth-check` passes
- `make terraform-recovery-check` reports `shared` as `OK`
- `terraform plan` for `infra/terraform/shared` returns `No changes`

If the `shared` plan is not clean, stop before `make eks-apply` and reconcile
the shared stack first.

---

## 3. Step 0 — Create Persistent Resources (Once)

ECR repositories and S3 results bucket are persistent resources. Create them
manually once before the first experiment. They survive `terraform destroy`.

```bash
# S3 results bucket
aws s3api create-bucket \
  --bucket skripsi-benchmark-results \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-public-access-block \
  --bucket skripsi-benchmark-results \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ECR repositories
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  aws ecr create-repository \
    --repository-name "skripsi/$repo" \
    --image-tag-mutability IMMUTABLE \
    --region ap-southeast-1
done
```

These resources are not managed by Terraform.

---

## 4. Step 1 — Build, Push, and Patch Images

Do this before any Terraform apply so every EKS manifest references real ECR
images.

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)

make ecr-push-all IMAGE_TAG=$IMAGE_TAG
make eks-update-manifests IMAGE_TAG=$IMAGE_TAG
```

`make eks-update-manifests` must be rerun every time `IMAGE_TAG` changes.

---

## 5. Step 2 — Apply Shared Infrastructure

Shared resources (VPC, IAM k6-runner role) are provisioned once and reused
across experiment runs.

Current `shared` stack inventory:

- 1 VPC
- 2 private subnets
- 2 public subnets
- route tables and route table associations for public/private routing
- 1 internet gateway
- 1 NAT gateway
- 1 Elastic IP for the NAT gateway
- default VPC network ACL / route table / security group objects managed by the VPC module
- 1 IAM role for benchmark result upload:
  - `skripsi-k6-runner`
- 1 inline IAM policy attached to that role:
  - `s3-results-access`

Why this is separate from `experiment`:

- `shared` provides the reusable network and IAM foundation
- `experiment` creates the cost-heavy per-session resources on top of it:
  - EKS clusters
  - node groups
  - RDS instances

```bash
cd infra/terraform/shared

# Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set s3_results_bucket to the manually created bucket name

terraform init
terraform plan
terraform apply
```

Optional helper flow:

```bash
make env-init-eks
make eks-render-tfvars
make terraform-auth-check
```

This renders `infra/terraform/shared/terraform.tfvars` from
`env/terraform.shared.env`.

Note the outputs:

```bash
AWS_PROFILE=terraform-process terraform output
# vpc_id, private_subnet_ids, k6_runner_role_arn
```

This workflow assumes a single operator runs Terraform from the same laptop.
The resulting local state file at `infra/terraform/shared/terraform.tfstate`
becomes the source of truth consumed by the `experiment` stack.

---

## 6. Step 3 — Apply Experiment Clusters

```bash
cd infra/terraform/experiment

# Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   db_password         = <strong password>

AWS_PROFILE=terraform-process terraform init
AWS_PROFILE=terraform-process terraform plan
AWS_PROFILE=terraform-process terraform apply
```

If you use the helper flow above, `make eks-render-tfvars` also renders
`infra/terraform/experiment/terraform.tfvars` from
`env/terraform.experiment.env`.

This provisions two EKS clusters and two RDS instances in parallel.
Expect approximately 15–20 minutes.

Verify outputs:

```bash
AWS_PROFILE=terraform-process terraform output
# monolith_cluster_name, monolith_rds_endpoint
# msa_cluster_name, msa_rds_endpoint
# kubeconfig commands for both clusters
```

`experiment` reads `vpc_id`, `private_subnet_ids`, and `k6_runner_role_arn`
from the local shared state file at `../shared/terraform.tfstate`.
Apply `shared` first, then `experiment`, from the same laptop.

---

## 7. Step 4 — Configure kubectl Contexts

```bash
make eks-setup-contexts
# or manually:
aws eks update-kubeconfig --name skripsi-monolith --region ap-southeast-1 --alias monolith
aws eks update-kubeconfig --name skripsi-msa      --region ap-southeast-1 --alias msa

# Verify
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

---

## 8. Step 5 — Create Secrets and Validate Manifests

Before running deploy scripts, create Kubernetes Secrets in each cluster.
See `docs/infrastructure/secret-management.md` for required secret keys.

Optional helper commands:

```bash
make create-eks-secrets-monolith
make create-eks-secrets-microservices
```

These commands create the benchmark and application secrets from the EKS env
helper files under `env/` plus Terraform outputs. They also use
`TERRAFORM_AWS_PROFILE` internally so their `terraform output` calls follow the
same auth path as `make eks-apply` and `make eks-destroy`.

```bash
make eks-validate-manifests
```

This must pass before deploy or benchmark runs. It fails when EKS manifests
still point at local-only images or unresolved ECR placeholders.

---

## 9. Step 6 — Deploy Applications

```bash
# Deploy monolith cluster (fixed replica mode by default)
make eks-deploy-monolith

# Deploy MSA cluster (fixed replica mode by default)
make eks-deploy-msa

# For HPA mode:
SCALING_MODE=hpa make eks-deploy-monolith
SCALING_MODE=hpa make eks-deploy-msa
```

---

## 10. Step 7 — Install Datadog

```bash
# Add Datadog Helm repo
make datadog-repo

# Install on monolith cluster
DATADOG_API_KEY=<redacted> make datadog-install-eks-monolith

# Install on MSA cluster
DATADOG_API_KEY=<redacted> make datadog-install-eks-msa
```

---

## 11. Step 8 — Run Parallel Benchmark

```bash
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket_name>
```

For HPA mode:

```bash
make run-benchmark-parallel \
  SCENARIO=create-transaction \
  TARGET_RPS=2500 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  S3_BUCKET=<bucket_name>
```

---

## 12. Step 9 — Verify S3 Results

```bash
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive
```

Expected files per attempt:

```text
experiments/eks-run-001/monolith/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/monolith/login/1000rps/attempt-01/metadata.json
experiments/eks-run-001/monolith/login/1000rps/attempt-01/raw.json.gz
experiments/eks-run-001/monolith/login/1000rps/attempt-01/datadog-time-window.json
experiments/eks-run-001/microservices/login/1000rps/attempt-01/summary.json
...
```

Do not destroy infrastructure until all expected files are present.

---

## 13. Step 10 — Destroy Infrastructure

```bash
# Destroy clusters and RDS
cd infra/terraform/experiment
AWS_PROFILE=terraform-process terraform destroy

# Destroy shared resources (only when experiment is fully complete).
# WARNING: this removes the VPC and IAM roles.
# ECR repositories and the S3 results bucket are manual resources outside Terraform.
# Benchmark results remain safe in S3 after this command.
cd infra/terraform/shared
AWS_PROFILE=terraform-process terraform destroy
```

Important:

- ECR repositories are **not** destroyed by Terraform because they are created manually.
- S3 results bucket is **not** destroyed by Terraform. Benchmark data is safe.
- To manually delete the S3 bucket after confirming all data is backed up:
  ```bash
  aws s3 rm s3://<bucket> --recursive
  aws s3api delete-bucket --bucket <bucket>
  ```

---

## 12. Variable Reference

### shared/terraform.tfvars

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region | `ap-southeast-1` |
| `project` | Resource name prefix | `skripsi` |
| `s3_results_bucket` | S3 bucket for benchmark result artifacts | `skripsi-benchmark-results` |

### experiment/terraform.tfvars

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region | `ap-southeast-1` |
| `db_password` | RDS master password | strong password |

---

## 13. Troubleshooting

**EKS nodes not ready:**
```bash
kubectl --context=monolith describe nodes
kubectl --context=monolith get events -A
```

**RDS not reachable from pods:**
- Verify security group allows port 5432 from EKS node security group
- Verify RDS is in private subnets
- Test from a pod: `kubectl --context=monolith run pg-test --image=postgres:18 --rm -it -- psql "$DATABASE_URL"`

**k6 job fails:**
```bash
kubectl --context=monolith logs job/k6-benchmark-monolith -n benchmark
```

**Terraform state conflict:**
- Ensure only one operator runs `terraform apply` at a time
- If you later move to multi-operator or CI usage, introduce a remote backend then
