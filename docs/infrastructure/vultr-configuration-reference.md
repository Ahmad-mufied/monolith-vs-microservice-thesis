# Vultr Configuration Reference

## Purpose

This document is the compact reference for Vultr-related environment variables,
Terraform stacks, Make targets, Kubernetes contexts, rendered metadata, and
operational guardrails.

Use `docs/infrastructure/vultr-vke-runbook.md` for the step-by-step execution
flow.

## Local Env Files

| File | Created by | Purpose | Commit? |
|---|---|---|---|
| `env/vultr.env` | `make env-init-vultr` | Local source for Vultr token, region, plans, S3 credentials, Docker Hub namespace, DB password, operator CIDR, and SSH key. | No |
| `env/vultr-resource-baseline.env` | `make vultr-measure-resource-baseline` | Measurement-derived CPU and memory quota used by Vultr manifest rendering. | No |
| `env/vultr-resource-baseline.json` | `make vultr-measure-resource-baseline` | Machine-readable copy of the measured baseline for audit and metadata. | No |
| `infra/terraform/vultr-*/terraform.tfvars` | `make vultr-render-tfvars` | Terraform inputs rendered from `env/vultr.env`. | No |

## Required `env/vultr.env` Values

| Variable | Example | Required for | Notes |
|---|---|---|---|
| `VULTR_API_KEY` | `***` | Terraform and preflight | Must not remain `replace-me`. |
| `VULTR_REGION` | `sgp` | Terraform, metadata | Keep all Vultr stacks in the same region for private networking. |
| `VULTR_VPC_CIDR` | `10.20.0.0/16` | Shared Terraform | Legacy VPC CIDR. |
| `VULTR_KUBERNETES_VERSION` | `v1.36.1+1` | VKE Terraform | Must be available in the selected Vultr region. |
| `VULTR_APP_NODE_PLAN` | `voc-c-8c-16gb-150s-amd` | VKE Terraform, baseline metadata | Single high-vCPU app node plan. |
| `VULTR_APP_NODE_COUNT` | `1` | VKE Terraform, live verification | App node count per active architecture. |
| `VULTR_TESTING_NODE_PLAN` | `vc2-2c-4gb` | VKE Terraform | Dedicated k6/testing node pool. |
| `VULTR_POSTGRES_PLAN` | `voc-c-2c-4gb-50s-amd` | PostgreSQL VM Terraform | Separate DB compute. |
| `VULTR_POSTGRES_OS_ID` | `1743` | PostgreSQL VM Terraform | OS image ID used by Vultr instance. |
| `VULTR_MONOLITH_CLUSTER_NAME` | `skripsi-vultr-monolith` | Parallel Terraform, metadata | Parallel monolith context becomes `monolith`. |
| `VULTR_MSA_CLUSTER_NAME` | `skripsi-vultr-msa` | Parallel Terraform, metadata | Parallel MSA context becomes `msa`. |
| `VULTR_SEQUENTIAL_CLUSTER_NAME` | `skripsi-vultr-benchmark` | Sequential Terraform, metadata | Sequential context becomes `benchmark`. |
| `POSTGRES_PASSWORD` | generated secret | Terraform and Kubernetes secrets | Minimum 16 characters. |
| `DOCKERHUB_NAMESPACE` | `ahmadryzen` | Render/deploy/benchmark | Uses Docker Hub public images. |
| `AWS_REGION` | `ap-southeast-1` | S3 upload | Region of benchmark result bucket. |
| `S3_BUCKET` | `skripsi-benchmark-results` | S3 upload | Existing AWS S3 bucket. |
| `AWS_ACCESS_KEY_ID` | `***` | k6 S3 upload | Optional fallback. Preferred path is `infra/terraform/aws-s3-writer` output. |
| `AWS_SECRET_ACCESS_KEY` | `***` | k6 S3 upload | Optional fallback. Preferred path is `infra/terraform/aws-s3-writer` output. |
| `OPERATOR_CIDRS` | `36.85.120.10/32` | PostgreSQL SSH firewall | Avoid `0.0.0.0/0`. |
| `OPERATOR_SSH_PUBLIC_KEY` | `ssh-ed25519 ...` | PostgreSQL VM SSH | Public key only. |

## Terraform Stacks

| Stack | Path | Creates | Destroy target |
|---|---|---|---|
| AWS S3 writer | `infra/terraform/aws-s3-writer` | IAM user/access key/policy for external k6 uploads to the existing AWS S3 bucket. | `make aws-s3-writer-destroy-confirmed` |
| Shared | `infra/terraform/vultr-shared` | Legacy VPC, SSH key, PostgreSQL firewall group. | `make vultr-shared-destroy-confirmed` |
| Parallel | `infra/terraform/vultr-parallel` | Two VKE clusters and two PostgreSQL VMs. | `make vultr-parallel-destroy-confirmed` |
| Sequential | `infra/terraform/vultr-sequential` | One VKE cluster and one PostgreSQL VM. | `make vultr-sequential-destroy-confirmed` |

State separation is intentional. Do not use `infra/terraform/aws-shared` for
Vultr S3-only credentials because that stack also owns AWS/EKS shared
networking and budget resources.

## Make Target Reference

### Setup and Terraform

| Target | Purpose |
|---|---|
| `make env-init-vultr` | Create or refresh `env/vultr.env` template. |
| `make vultr-render-tfvars` | Render Vultr Terraform `terraform.tfvars` files. |
| `make vultr-preflight-check` | Validate local env and catch placeholders before expensive steps. |
| `make vultr-shared-plan` | Plan shared VPC/firewall/SSH resources. |
| `make vultr-shared-apply` | Apply shared VPC/firewall/SSH resources. |
| `make vultr-parallel-plan` | Plan two-cluster parallel stack. |
| `make vultr-parallel-apply` | Apply two-cluster parallel stack. |
| `make vultr-sequential-plan` | Plan single-cluster sequential stack. |
| `make vultr-sequential-apply` | Apply single-cluster sequential stack. |

### Kubernetes Setup

| Target | Purpose |
|---|---|
| `make vultr-setup-contexts-parallel` | Write kubeconfig contexts `monolith` and `msa`. |
| `make vultr-setup-context-sequential` | Write kubeconfig context `benchmark`. |
| `make vultr-create-secrets` | Create secrets in both parallel clusters. |
| `make vultr-create-secrets-sequential` | Create mono/MSA/benchmark secrets in the sequential cluster. |
| `make vultr-measure-resource-baseline` | Measure app-node allocatable capacity and write Vultr resource baseline. |
| `make vultr-render-manifests` | Render Vultr-specific Kubernetes manifests into a temp directory and validate. |

### Deploy and Verify

| Target | Purpose |
|---|---|
| `make vultr-deploy-all` | Deploy both parallel clusters for the selected `SCALING_MODE`. |
| `make vultr-deploy-sequential-architecture` | Deploy one architecture into the sequential cluster. |
| `make vultr-verify-live-mode` | Verify fixed/HPA mode and placement before benchmark execution. |

### Benchmark

| Target | Purpose |
|---|---|
| `make run-benchmark-parallel-vultr` | Run one parallel benchmark case. |
| `make run-benchmark-sequential-vultr` | Run one sequential benchmark case. |
| `make run-benchmark-suite-vultr` | Run a full parallel matrix suite. |
| `make run-benchmark-suite-sequential-vultr` | Run a full sequential matrix suite. |

### Destroy

| Target | Purpose |
|---|---|
| `S3_BENCHMARK_DATA_VERIFIED=true make vultr-parallel-destroy-confirmed` | Destroy parallel experiment resources. |
| `S3_BENCHMARK_DATA_VERIFIED=true make vultr-sequential-destroy-confirmed` | Destroy sequential experiment resources. |
| `S3_BENCHMARK_DATA_VERIFIED=true make vultr-shared-destroy-confirmed` | Destroy shared Vultr resources. |

## Cost Guardrails

The Vultr plan variables are cost-impacting infrastructure choices:

```text
VULTR_APP_NODE_PLAN
VULTR_APP_NODE_COUNT
VULTR_TESTING_NODE_PLAN
VULTR_POSTGRES_PLAN
```

The parallel stack deliberately creates two full benchmark clusters, one for
monolith and one for microservices, to preserve same-wall-clock benchmark
comparison. Do not make only one parallel module optional unless all downstream
outputs, context setup, secret creation, deployment, benchmark, and metadata
paths are also redesigned. Use the sequential stack as the supported
lower-cost/quota fallback.

## Kubernetes Contexts

| Mode | Context | Namespace | Workload |
|---|---|---|---|
| Parallel | `monolith` | `mono` | Monolith app, migrations, seed jobs. |
| Parallel | `monolith` | `benchmark` | Monolith k6 jobs and bootstrap jobs. |
| Parallel | `msa` | `msa` | API Gateway, auth, item, transaction services, migrations, seed jobs. |
| Parallel | `msa` | `benchmark` | MSA k6 jobs and bootstrap jobs. |
| Sequential | `benchmark` | `mono` | Monolith phase. |
| Sequential | `benchmark` | `msa` | Microservices phase. |
| Sequential | `benchmark` | `benchmark` | k6 jobs and bootstrap jobs. |

## Resource Baseline

Vultr manifests must be rendered from live measured app-node allocatable
capacity:

```bash
VULTR_CONTEXT=monolith make vultr-measure-resource-baseline
```

Output example:

```text
VULTR_RESOURCE_BASELINE_PROVIDER=vultr
VULTR_REGION=sgp
VULTR_APP_NODE_PLAN=voc-c-8c-16gb-150s-amd
VULTR_APP_CPU_QUOTA=7800m
VULTR_APP_MEMORY_QUOTA=15360Mi
VULTR_APP_NODE_COUNT=1
VULTR_APP_ALLOCATABLE_CPU=7800m
VULTR_APP_ALLOCATABLE_MEMORY=15800Mi
VULTR_RESOURCE_SAFETY_CPU=0m
VULTR_RESOURCE_SAFETY_MEMORY=110Mi
```

The exact numbers must come from the live cluster. Do not copy the example into
`env/vultr-resource-baseline.env`.

## Scaling Mode Configuration

Fixed mode:

```bash
SCALING_MODE=fixed make vultr-deploy-all IMAGE_TAG=<tag> DOCKERHUB_NAMESPACE=<namespace>
SCALING_MODE=fixed EXECUTION_MODE=parallel make vultr-verify-live-mode
```

HPA mode:

```bash
SCALING_MODE=hpa make vultr-deploy-all IMAGE_TAG=<tag> DOCKERHUB_NAMESPACE=<namespace>
SCALING_MODE=hpa EXECUTION_MODE=parallel make vultr-verify-live-mode
```

Rules:

- `SCALING_MODE` in benchmark commands records expected mode and chooses k6
  profile behavior; it does not mutate live Kubernetes deployment objects.
- Every `fixed <-> hpa` transition must redeploy manifests.
- HPA uses the same 70% CPU target as the existing benchmark strategy.
- ResourceQuota is equal for monolith and MSA.
- The active Vultr documentation path uses equal split across the four
  microservices:
  `1950m CPU / 3840Mi memory` per service in fixed mode,
  `975m CPU / 1920Mi memory` per pod with `minReplicas=1` and
  `maxReplicas=2` in HPA mode.
- Set `VULTR_EXPECTED_APP_NODE_COUNT=1` when verifying the current single app
  node topology.

## Benchmark Metadata

Vultr benchmark runs should record:

```text
provider=vultr
region=<VULTR_REGION>
execution_mode=parallel or sequential
terraform_stack=vultr-parallel or vultr-sequential
cluster=<active VKE cluster name>
app_node_pool=app-nodes
testing_node_pool=testing-nodes
postgres_version=18
resource_profile=vultr-equal-split
app_resource_quota=<measured quota>
image_tag=<pushed Docker Hub tag>
```

If a result is missing these fields, treat it as invalid for final thesis
analysis until the metadata path is fixed.

## Microservices gRPC Service Discovery

Microservices use gRPC for internal calls. On Kubernetes/VKE, the benchmark
deployment exposes each gRPC backend through two Services:

| Backend | Compatibility Service | Load-balanced gRPC target |
|---|---|---|
| Auth Service | `auth-service` | `auth-service-headless` |
| Item Service | `item-service` | `item-service-headless` |
| Transaction Service | `transaction-service` | `transaction-service-headless` |

Application secrets should point gRPC clients at the headless Services with
the `dns:///` resolver scheme:

```text
AUTH_SERVICE_ADDR=dns:///auth-service-headless.msa.svc.cluster.local:50051
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
TRANSACTION_SERVICE_ADDR=dns:///transaction-service-headless.msa.svc.cluster.local:50053
```

Transaction Service uses the same pattern for its Item Service dependency:

```text
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
```

API Gateway and Transaction Service configure gRPC `round_robin` client-side
load balancing. This is needed because gRPC multiplexes RPCs over long-lived
HTTP/2 connections; with a normal ClusterIP target, traffic can remain
concentrated on the backend selected for that connection. Headless Services let
the gRPC DNS resolver see the ready pod IPs directly.

## Guardrails

The Vultr integration should fail rather than silently continue when:

- required env files are missing
- token or namespace placeholders remain
- `env/vultr-resource-baseline.env` is missing before manifest rendering
- Vultr-rendered manifests still contain ECR image references
- AWS S3 credentials are missing from the k6 secret path
- microservices gRPC secrets still point at non-headless ClusterIP service DNS
- fixed/HPA live mode does not match requested benchmark mode
- `VULTR_EXPECTED_APP_NODE_COUNT` is set and the live app node count differs
- destroy is attempted without `S3_BENCHMARK_DATA_VERIFIED=true`

These guardrails are intentionally simple and repo-native. They avoid extra
controllers or services while protecting benchmark reproducibility.
