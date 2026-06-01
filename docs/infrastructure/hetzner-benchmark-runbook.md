# Hetzner Benchmark Runbook

## 1. Prepare Environment

Initialize the existing app env files and the Hetzner env file:

```bash
make env-init-eks
make env-init-hetzner
```

Edit `env/hetzner.env` and set:

```text
HCLOUD_TOKEN
DOCKERHUB_NAMESPACE
AWS_REGION
S3_BUCKET
```

The AWS S3 writer credentials are created by `infra/terraform/shared`. The
Hetzner secret creation scripts read them from Terraform output when
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are not set manually in
`env/hetzner.env`.

## 2. Publish Images

Hetzner uses Docker Hub public images.

```bash
make dockerhub-push-all DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=<tag>
```

The image check verifies that all required image tags are visible before
deployment.

## 3. Provision Sequential Infrastructure

```bash
make hetzner-render-tfvars
make hetzner-shared-apply
make hetzner-sequential-apply
make hetzner-setup-context-sequential
```

Then create Kubernetes Secrets:

```bash
make hetzner-create-secrets-sequential
```

## 4. Measure Resource Baseline

```bash
make hetzner-measure-resource-baseline
```

Do not deploy benchmark workloads before this file exists unless explicitly
using `SKIP_HETZNER_RESOURCE_BASELINE=true` for manifest debugging only.

## 5. Deploy and Smoke Test

Deploy one architecture at a time:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=monolith \
  SCALING_MODE=fixed \
  IMAGE_TAG=<tag>

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=monolith \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-smoke \
  IMAGE_TAG=<tag>
```

Repeat for microservices:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=microservices \
  SCALING_MODE=fixed \
  IMAGE_TAG=<tag>

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=microservices \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-smoke \
  IMAGE_TAG=<tag>
```

## 6. Preflight

Before a measured run:

```bash
make hetzner-preflight-check IMAGE_TAG=<tag>
```

This verifies:

- Hetzner token presence,
- Kubernetes context and node labels,
- testing node taint,
- AWS S3 access,
- Docker Hub image availability.

## 7. Destroy

Never destroy before verifying S3 artifacts.

```bash
aws s3 ls s3://<bucket>/experiments/<run-id>/ --recursive
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-sequential-destroy-confirmed
```

The shared network stack should be kept if another Hetzner run is planned.
