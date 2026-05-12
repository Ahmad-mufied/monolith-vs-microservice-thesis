# CodeBuild and ECR Image Build

## 1. Purpose

This document describes the image build and push strategy for the thesis benchmark project.

The current focus is:

```text
Build Docker image
Push image to Amazon ECR
Do not deploy to EKS yet
```

The current target images are:

```text
skripsi/monolith
skripsi/api-gateway
skripsi/auth-service
skripsi/item-service
skripsi/transaction-service
```

The current pipeline validates the monolith build path together with all microservice image build paths.

---

## 2. Final Decision

Image registry:

```text
Amazon ECR
```

AWS region:

```text
ap-southeast-1
```

Current ECR repositories:

```text
skripsi/monolith
skripsi/api-gateway
skripsi/auth-service
skripsi/item-service
skripsi/transaction-service
```

Image tag strategy:

```text
git short SHA
```

Example image URIs:

```text
720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/monolith:a1b2c3d
720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/api-gateway:a1b2c3d
720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/auth-service:a1b2c3d
720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/item-service:a1b2c3d
720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/transaction-service:a1b2c3d
```

The ECR repository uses immutable image tags.

Therefore, the build process must not push:

```text
latest
```

The build process should only push the git short SHA tag.

---

## 3. Why Amazon ECR

Amazon ECR is used because the final runtime environment is AWS EKS.

Using ECR keeps the container registry close to the final Kubernetes environment.

Final flow:

```text
CodeBuild
    |
    v
Build Docker image
    |
    v
Push image to Amazon ECR
    |
    v
EKS pulls image from Amazon ECR during deployment
```

---

## 4. Repository Naming

The ECR repositories use the `skripsi/` namespace.

Current repositories:

```text
skripsi/monolith
skripsi/api-gateway
skripsi/auth-service
skripsi/item-service
skripsi/transaction-service
```

Next repositories:

```text
skripsi/seed-runner
skripsi/k6-runner
```

Each service has its own ECR repository because each service is a separate deployable container image.

GitHub repository remains one monorepo:

```text
monolith-vs-microservice-thesis
```

ECR repositories are separated per image:

```text
skripsi/monolith
skripsi/api-gateway
skripsi/auth-service
skripsi/item-service
skripsi/transaction-service
```

---

## 5. Tagging Strategy

Use git short SHA as the main image tag.

Example:

```text
monolith:a1b2c3d
```

Do not use `latest` for benchmark deployment.

Reason:

```text
latest is mutable and difficult to trace.
git short SHA is easier to map to a specific source code commit.
```

For thesis experiment reproducibility, the image tag used during benchmark execution must be recorded in the benchmark metadata.

Example metadata:

```json
{
  "architecture": "monolith",
  "image": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/monolith:a1b2c3d",
  "git_commit": "a1b2c3d",
  "scenario": "create-transaction",
  "timestamp": "2026-05-08T10:00:00Z"
}
```

---

## 6. ECR Repository Configuration

Recommended ECR configuration:

```text
Repositories    : skripsi/monolith, skripsi/api-gateway, skripsi/auth-service, skripsi/item-service, skripsi/transaction-service
Visibility      : Private
Region          : ap-southeast-1
Tag mutability  : Immutable
Encryption      : AES-256
Scan on push    : Enabled
Lifecycle       : Keep last 10 tagged images
```

Lifecycle policy:

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep only the last 10 tagged images",
      "selection": {
        "tagStatus": "tagged",
        "tagPatternList": ["*"],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
```

This prevents old images from accumulating and increasing ECR storage usage.

---

## 7. Buildspec Location

The buildspec file is stored in the repository:

```text
buildspec/buildspec.images.yml
```

CodeBuild project must be configured to use this buildspec path:

```text
buildspec/buildspec.images.yml
```

---

## 8. CodeBuild Project

Recommended CodeBuild project name:

```text
skripsi-images-build
```

Recommended settings:

```text
Source provider : GitHub
Branch          : main
Environment    : Managed image
OS              : Ubuntu
Runtime         : Standard
Privileged mode : Enabled
Buildspec       : buildspec/buildspec.images.yml
```

Privileged mode must be enabled because Docker build requires Docker daemon access.

---

## 9. CodeBuild Service Role

CodeBuild must use a service role, not an IAM user.

Recommended role name:

```text
skripsi-codebuild-service-role
```

Trusted service:

```text
codebuild.amazonaws.com
```

The service role is used by CodeBuild during build execution.

It is different from the human admin user:

```text
mufied-admin
```

Role separation:

```text
mufied-admin
→ used by the developer to manage AWS resources

skripsi-codebuild-service-role
→ used by CodeBuild to build and push images
```

---

## 10. CodeBuild IAM Policy

Attach the following inline policy to the CodeBuild service role.

Replace the account id if needed.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:ap-southeast-1:720166597212:repository/skripsi/*"
    },
    {
      "Sid": "STS",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

To allow the current multi-image scope and future service additions, use the ECR resource scope:

```text
arn:aws:ecr:ap-southeast-1:720166597212:repository/skripsi/*
```

---

## 11. Buildspec Content

File:

```text
buildspec/buildspec.images.yml
```

Content:

```yaml
version: 0.2

env:
  variables:
    AWS_REGION: ap-southeast-1
    ECR_NAMESPACE: skripsi
    IMAGE_TAG_FALLBACK_PREFIX: manual

phases:
  pre_build:
    commands:
      - echo "Starting pre_build phase..."
      - echo "Checking Dockerfiles..."
      - test -f monolith/Dockerfile
      - test -f microservices/api-gateway/Dockerfile
      - test -f microservices/auth-service/Dockerfile
      - test -f microservices/item-service/Dockerfile
      - test -f microservices/transaction-service/Dockerfile

      - echo "Resolving AWS account and ECR registry..."
      - export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      - export ECR_REGISTRY=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
      - export MONOLITH_REPOSITORY_URI=$ECR_REGISTRY/$ECR_NAMESPACE/monolith
      - export API_GATEWAY_REPOSITORY_URI=$ECR_REGISTRY/$ECR_NAMESPACE/api-gateway
      - export AUTH_SERVICE_REPOSITORY_URI=$ECR_REGISTRY/$ECR_NAMESPACE/auth-service
      - export ITEM_SERVICE_REPOSITORY_URI=$ECR_REGISTRY/$ECR_NAMESPACE/item-service
      - export TRANSACTION_SERVICE_REPOSITORY_URI=$ECR_REGISTRY/$ECR_NAMESPACE/transaction-service

      - echo "Resolving image tag..."
      - export IMAGE_TAG=$(printf '%.7s' "${CODEBUILD_RESOLVED_SOURCE_VERSION:-}")
      - if [ -z "$IMAGE_TAG" ]; then export IMAGE_TAG="$IMAGE_TAG_FALLBACK_PREFIX-$(date +%Y%m%d%H%M%S)"; fi

      - echo "AWS_REGION=$AWS_REGION"
      - echo "ECR_REGISTRY=$ECR_REGISTRY"
      - echo "MONOLITH_REPOSITORY_URI=$MONOLITH_REPOSITORY_URI"
      - echo "API_GATEWAY_REPOSITORY_URI=$API_GATEWAY_REPOSITORY_URI"
      - echo "AUTH_SERVICE_REPOSITORY_URI=$AUTH_SERVICE_REPOSITORY_URI"
      - echo "ITEM_SERVICE_REPOSITORY_URI=$ITEM_SERVICE_REPOSITORY_URI"
      - echo "TRANSACTION_SERVICE_REPOSITORY_URI=$TRANSACTION_SERVICE_REPOSITORY_URI"
      - echo "IMAGE_TAG=$IMAGE_TAG"

      - echo "Checking ECR repositories..."
      - aws ecr describe-repositories --repository-names "$ECR_NAMESPACE/monolith" --region "$AWS_REGION"
      - aws ecr describe-repositories --repository-names "$ECR_NAMESPACE/api-gateway" --region "$AWS_REGION"
      - aws ecr describe-repositories --repository-names "$ECR_NAMESPACE/auth-service" --region "$AWS_REGION"
      - aws ecr describe-repositories --repository-names "$ECR_NAMESPACE/item-service" --region "$AWS_REGION"
      - aws ecr describe-repositories --repository-names "$ECR_NAMESPACE/transaction-service" --region "$AWS_REGION"

      - echo "Logging in to Amazon ECR..."
      - aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

  build:
    commands:
      - echo "Starting build phase..."
      - echo "Building monolith image..."
      - docker build -t "monolith:$IMAGE_TAG" -f monolith/Dockerfile .
      - docker tag "monolith:$IMAGE_TAG" "$MONOLITH_REPOSITORY_URI:$IMAGE_TAG"

      - echo "Building api-gateway image..."
      - docker build -t "api-gateway:$IMAGE_TAG" -f microservices/api-gateway/Dockerfile .
      - docker tag "api-gateway:$IMAGE_TAG" "$API_GATEWAY_REPOSITORY_URI:$IMAGE_TAG"

      - echo "Building auth-service image..."
      - docker build -t "auth-service:$IMAGE_TAG" -f microservices/auth-service/Dockerfile .
      - docker tag "auth-service:$IMAGE_TAG" "$AUTH_SERVICE_REPOSITORY_URI:$IMAGE_TAG"

      - echo "Building item-service image..."
      - docker build -t "item-service:$IMAGE_TAG" -f microservices/item-service/Dockerfile .
      - docker tag "item-service:$IMAGE_TAG" "$ITEM_SERVICE_REPOSITORY_URI:$IMAGE_TAG"

      - echo "Building transaction-service image..."
      - docker build -t "transaction-service:$IMAGE_TAG" -f microservices/transaction-service/Dockerfile .
      - docker tag "transaction-service:$IMAGE_TAG" "$TRANSACTION_SERVICE_REPOSITORY_URI:$IMAGE_TAG"

  post_build:
    commands:
      - echo "Starting post_build phase..."
      - echo "Pushing monolith image..."
      - docker push "$MONOLITH_REPOSITORY_URI:$IMAGE_TAG"
      - echo "Pushing api-gateway image..."
      - docker push "$API_GATEWAY_REPOSITORY_URI:$IMAGE_TAG"
      - echo "Pushing auth-service image..."
      - docker push "$AUTH_SERVICE_REPOSITORY_URI:$IMAGE_TAG"
      - echo "Pushing item-service image..."
      - docker push "$ITEM_SERVICE_REPOSITORY_URI:$IMAGE_TAG"
      - echo "Pushing transaction-service image..."
      - docker push "$TRANSACTION_SERVICE_REPOSITORY_URI:$IMAGE_TAG"

      - echo "Writing image detail artifact..."
      - printf '{"tag":"%s","images":{"monolith":"%s","api_gateway":"%s","auth_service":"%s","item_service":"%s","transaction_service":"%s"},"commit":"%s"}' "$IMAGE_TAG" "$MONOLITH_REPOSITORY_URI:$IMAGE_TAG" "$API_GATEWAY_REPOSITORY_URI:$IMAGE_TAG" "$AUTH_SERVICE_REPOSITORY_URI:$IMAGE_TAG" "$ITEM_SERVICE_REPOSITORY_URI:$IMAGE_TAG" "$TRANSACTION_SERVICE_REPOSITORY_URI:$IMAGE_TAG" "$CODEBUILD_RESOLVED_SOURCE_VERSION" > image-detail.json

      - echo "Build and push completed."
      - cat image-detail.json

artifacts:
  files:
    - image-detail.json
```

This buildspec uses a generic image-pipeline filename so the same pattern can
be extended later for `seed-runner` and `k6-runner`.

For the current phase, it builds and pushes:

```text
skripsi/monolith
skripsi/api-gateway
skripsi/auth-service
skripsi/item-service
skripsi/transaction-service
```

All images use the same git short SHA tag from the same commit.

This buildspec only pushes the git short SHA tag.

It does not push `latest` because the ECR repository uses immutable tags.

---

## 12. Manual Build Test

Before enabling automatic trigger, run CodeBuild manually.

Flow:

```text
CodeBuild
→ Build projects
→ skripsi-images-build
→ Start build
```

After the build succeeds, check:

```text
ECR
→ Repositories
→ skripsi/monolith
→ skripsi/api-gateway
→ skripsi/auth-service
→ skripsi/item-service
→ skripsi/transaction-service
→ Images
```

Expected tag example:

```text
a1b2c3d
```

---

## 13. Automatic Trigger

Enable automatic trigger only after manual build succeeds.

Recommended trigger:

```text
Push to main branch
```

Webhook branch filter:

```text
^refs/heads/main$
```

Final flow:

```text
PR merged to main
    |
    v
CodeBuild triggered
    |
    v
Build monolith, api-gateway, auth-service, item-service, and transaction-service Docker images
    |
    v
Push all images to ECR with the same git short SHA tag
```

This trigger also fires for direct pushes to `main`.

Recommended operational policy:

```text
Require pull request review before merge to main
Use push-to-main as the automatic CodeBuild trigger
Keep manual Start build enabled for rebuilds without a new commit
```

---

## 14. What This Does Not Do

This setup does not:

```text
- deploy image to EKS
- run database migration
- run seed job
- run k6 benchmark
- upload benchmark result to S3
```

Deployment to EKS will be handled separately during the benchmark phase.

---

## 15. Next Step

After all service images build and push work, add ECR repositories and build steps for:

```text
skripsi/seed-runner
skripsi/k6-runner
```

All images should use the same git short SHA tag when built from the same commit.
