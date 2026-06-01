# Vultr VKE Benchmark Runbook

## Purpose

This runbook is the end-to-end operator guide for running the thesis benchmark
on Vultr Kubernetes Engine (VKE). It covers setup, Terraform provisioning,
Kubernetes context setup, secrets, manifest rendering, fixed/HPA deployment,
parallel and sequential benchmark execution, result verification, and guarded
destroy.

Use this document together with:

- `docs/infrastructure/vultr-cloud-architecture.md`
- `docs/infrastructure/vultr-configuration-reference.md`
- `docs/diagrams/vultr-vke-topology.md`
- `docs/experiment/scaling-mode-strategy.md`
- `docs/infrastructure/secret-management.md`

The Vultr path is additive to the existing AWS EKS and Hetzner paths. It uses
the same application manifests under `deployments/k8s/eks/`, rendered at
runtime for Vultr-specific image registry, metadata, and measured resource
baseline values.

```text
Kubernetes/application compute : Vultr Kubernetes Engine (VKE)
PostgreSQL compute             : Vultr Compute VM per architecture
private network                : Vultr legacy VPC Network
benchmark artifacts            : AWS S3
container images               : Docker Hub public
observability                  : Datadog SaaS
provisioning                   : Terraform
```

## Operating Modes

| Mode | Terraform stack | Kubernetes contexts | Use when |
|---|---|---|---|
| Parallel | `infra/terraform/vultr-experiment` | `monolith`, `msa` | Preferred thesis mode because monolith and MSA run in the same wall-clock benchmark window. |
| Sequential | `infra/terraform/vultr-experiment-sequential` | `benchmark` | Fallback when Vultr quota or budget cannot support two full clusters at the same time. |

Parallel mode is the default target for final benchmark runs. Sequential mode
is valid for smoke tests, quota-constrained iteration, and fallback execution,
but its metadata must be interpreted as separate time windows.

## Phase 0 - Local Prerequisites

Install and verify these tools:

```bash
terraform version
kubectl version --client
helm version
aws --version
docker version
```

Required accounts and tokens:

```text
Vultr API token       : creates VPC, VKE, firewall, and PostgreSQL VM
Docker Hub account   : hosts public benchmark images
AWS credentials      : uploads benchmark artifacts to S3
Datadog API key      : optional but expected for measured thesis runs
```

Do not commit local env files, generated `terraform.tfvars`, kubeconfigs,
Terraform state, or secret values.

## Phase 1 - Build and Push Images

Vultr uses Docker Hub public images. Build and push the same image tag for all
deployables before provisioning or deployment:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
DOCKERHUB_NAMESPACE=ahmadryzen

make docker-build-all IMAGE_TAG="$IMAGE_TAG"
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"
```

If the repository does not have a combined Docker Hub push target in your local
branch, push each image using the existing Docker commands and keep the same
`IMAGE_TAG` for every service, seed runner, and k6 runner.

Validation:

```bash
docker pull "docker.io/$DOCKERHUB_NAMESPACE/monolith:$IMAGE_TAG"
docker pull "docker.io/$DOCKERHUB_NAMESPACE/k6-runner:$IMAGE_TAG"
```

## Phase 2 - Initialize Local Vultr Env

Create the local Vultr env file:

```bash
make env-init-vultr
```

Edit `env/vultr.env` and replace placeholders:

```bash
VULTR_API_KEY=...
DOCKERHUB_NAMESPACE=ahmadryzen
AWS_REGION=ap-southeast-1
S3_BUCKET=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
POSTGRES_PASSWORD=...
OPERATOR_CIDRS=<your-public-ip>/32
OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

Recommended defaults for thesis-sized Vultr tests:

```bash
VULTR_REGION=sgp
VULTR_VPC_CIDR=10.20.0.0/16
VULTR_KUBERNETES_VERSION=v1.33.0+1
VULTR_APP_NODE_PLAN=voc-c-16c-32gb-300s
VULTR_TESTING_NODE_PLAN=vc2-4c-8gb
VULTR_POSTGRES_PLAN=vc2-4c-8gb
```

Notes:

- `OPERATOR_CIDRS` is used for PostgreSQL SSH firewall access. Keep it as a
  narrow `/32` where possible.
- VKE currently uses legacy Vultr VPC Networks in this implementation, not VPC
  2.0. Keep the PostgreSQL VM attached to the same legacy VPC as the VKE
  cluster.
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are only for k6 S3 uploads
  from Vultr. Scope them narrowly to the benchmark results bucket or prefix.

Run preflight before any cost-heavy action:

```bash
make vultr-preflight-check
```

Expected behavior:

- fails if `env/vultr.env` is missing
- fails if required secrets are empty
- fails if critical placeholders remain
- warns if resource baseline measurement has not been captured yet

## Phase 3 - Render Terraform Inputs

Render Vultr `terraform.tfvars` files from `env/vultr.env`:

```bash
make vultr-render-tfvars
```

Generated files:

```text
infra/terraform/vultr-shared/terraform.tfvars
infra/terraform/vultr-experiment/terraform.tfvars
infra/terraform/vultr-experiment-sequential/terraform.tfvars
```

Do not commit these files. They may contain local operator CIDRs and sensitive
database configuration.

## Phase 4 - Apply Shared Infrastructure

The shared stack creates the Vultr legacy VPC, operator SSH key, and PostgreSQL
firewall group.

```bash
make vultr-shared-plan
make vultr-shared-apply
```

Inspect outputs:

```bash
terraform -chdir=infra/terraform/vultr-shared output
```

Expected outputs include:

```text
network_id
network_cidr
ssh_key_ids
postgres_firewall_group_id
```

## Phase 5A - Apply Parallel Clusters

Parallel mode creates two isolated VKE clusters and two PostgreSQL VMs:

```bash
make vultr-parallel-plan
make vultr-parallel-apply
```

Expected resources:

```text
skripsi-vultr-monolith  : app pool + testing pool + monolith PostgreSQL VM
skripsi-vultr-msa       : app pool + testing pool + MSA PostgreSQL VM
```

Configure local kubeconfig contexts:

```bash
make vultr-setup-contexts-parallel
kubectl config get-contexts monolith msa
```

Smoke-check the clusters:

```bash
kubectl --context=monolith get nodes -o wide
kubectl --context=msa get nodes -o wide
```

## Phase 5B - Apply Sequential Fallback Cluster

Use sequential mode only when quota or cost constraints prevent parallel mode:

```bash
make vultr-sequential-plan
make vultr-sequential-apply
make vultr-setup-context-sequential
kubectl config get-contexts benchmark
kubectl --context=benchmark get nodes -o wide
```

Expected resources:

```text
skripsi-vultr-benchmark : app pool + testing pool + one PostgreSQL VM
```

Do not keep parallel and sequential stacks active together unless the quota and
budget impact is intentional.

## Phase 6 - Create Kubernetes Secrets

Parallel:

```bash
make vultr-create-secrets
```

Sequential:

```bash
make vultr-create-secrets-sequential
```

The scripts create:

```text
mono/app-secret
msa/app-secret
benchmark/k6-runner-secret
benchmark/db-bootstrap-secret
```

The Vultr secret scripts reuse existing EKS env files for application-level
settings and combine them with Vultr Terraform outputs for private PostgreSQL
IPs. If a script says an EKS env file is missing, run the existing env init
flow first:

```bash
make env-init-eks
```

Validation:

```bash
kubectl --context=monolith get secret -n mono
kubectl --context=msa get secret -n msa
kubectl --context=monolith get secret -n benchmark
kubectl --context=msa get secret -n benchmark
```

For sequential mode, replace both contexts with `benchmark`.

## Phase 7 - Measure Live Resource Baseline

Vultr resource quotas are measurement-derived. Do not render final manifests
until the app node allocatable capacity has been measured from the live cluster.

Parallel:

```bash
VULTR_CONTEXT=monolith make vultr-measure-resource-baseline
cat env/vultr-resource-baseline.env
```

Sequential:

```bash
VULTR_CONTEXT=benchmark make vultr-measure-resource-baseline
cat env/vultr-resource-baseline.env
```

The measurement writes:

```text
env/vultr-resource-baseline.env
env/vultr-resource-baseline.json
```

The renderer uses `VULTR_APP_CPU_QUOTA` and `VULTR_APP_MEMORY_QUOTA` from that
file for both monolith and microservices. This preserves fairness when the
Vultr allocatable capacity differs from the nominal plan size.

Do not manually lower memory or raise CPU for only one architecture. Any
resource adjustment must be applied equally to both resource ceilings and must
be documented in benchmark metadata.

## Phase 8 - Render and Validate Manifests

Manual smoke render:

```bash
IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" make vultr-render-manifests
```

The renderer must fail if `env/vultr-resource-baseline.env` is missing, unless
an explicit smoke-only override is used by a validation command.

The Vultr renderer patches:

```text
Docker Hub image references
ResourceQuota CPU and memory ceilings
benchmark metadata provider/region/cluster fields
S3 upload configuration placeholders at benchmark runtime
stale AWS/ECR metadata that must not appear in Vultr manifests
```

## Phase 9A - Deploy Parallel Fixed Mode

Deploy both architecture clusters in fixed-replica mode:

```bash
SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  make vultr-deploy-all
```

Verify live mode:

```bash
SCALING_MODE=fixed EXECUTION_MODE=parallel make vultr-verify-live-mode
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
```

Expected:

- no HPA objects in `mono` or `msa`
- monolith deployment has fixed replicas
- MSA services have fixed replicas
- pods run on app nodes, not testing nodes

## Phase 9B - Deploy Parallel HPA Mode

Switching from fixed to HPA is a redeploy event:

```bash
SCALING_MODE=hpa IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  make vultr-deploy-all
```

Verify:

```bash
SCALING_MODE=hpa EXECUTION_MODE=parallel make vultr-verify-live-mode
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
```

Expected:

- HPA objects exist
- HPA target CPU is 70%
- metrics-server is available
- baseline replicas are ready before load starts

Do not assume changing `SCALING_MODE` in a benchmark command changes the live
Kubernetes objects. Always redeploy and verify after switching fixed/HPA mode.

## Phase 9C - Deploy Sequential Mode

Deploy one architecture at a time in the `benchmark` context:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  make vultr-deploy-sequential-architecture

SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith \
  make vultr-verify-live-mode
```

Then, after the monolith run is complete and results are verified, switch:

```bash
ARCHITECTURE=microservices SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  make vultr-deploy-sequential-architecture

SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=microservices \
  make vultr-verify-live-mode
```

Use the same pattern for `SCALING_MODE=hpa`.

## Phase 10 - Run Smoke Benchmarks

Run smoke tests before a long suite. Parallel examples:

```bash
SCALING_MODE=fixed K6_PROFILE=smoke make run-benchmark-parallel-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-parallel-fixed-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"

SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-parallel-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-parallel-hpa-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"
```

Sequential examples:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed K6_PROFILE=smoke make run-benchmark-sequential-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-seq-mono-fixed-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"

ARCHITECTURE=microservices SCALING_MODE=fixed K6_PROFILE=smoke make run-benchmark-sequential-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-seq-msa-fixed-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"
```

Interpret results:

```text
PASS      : valid run, thresholds passed
OVERLOAD  : valid stress result, thresholds failed because target exceeded capacity
INVALID   : rerun after fixing application, data, secret, or infra issue
TIMEOUT   : rerun after investigating stuck job or unreachable endpoint
```

## Phase 11 - Run Full Parallel Suites

Fixed suite:

```bash
SCALING_MODE=fixed K6_PROFILE=steady make run-benchmark-suite-vultr \
  EXPERIMENT_NAME=rq1-fixed-vultr \
  IMAGE_TAG="$IMAGE_TAG" \
  DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000"
```

HPA suite:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-suite-vultr \
  EXPERIMENT_NAME=rq2-hpa-vultr \
  IMAGE_TAG="$IMAGE_TAG" \
  DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000"
```

For thesis execution, keep fixed and HPA as separate suites and separate
`EXPERIMENT_NAME` values. This makes S3 prefixes, metadata, and Datadog windows
cleaner to analyze.

## Phase 12 - Run Sequential Suites

Sequential suites are useful when quota cannot support parallel mode:

```bash
SCALING_MODE=fixed K6_PROFILE=steady make run-benchmark-suite-sequential-vultr \
  ARCHITECTURE_ORDER="monolith,microservices" \
  EXPERIMENT_NAME=rq1-fixed-vultr-sequential \
  IMAGE_TAG="$IMAGE_TAG" \
  DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  SCENARIO_RPS_MATRIX="login:1000,2500;create-transaction:1000,2500;enriched-transactions:1000,2500"
```

HPA sequential:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-suite-sequential-vultr \
  ARCHITECTURE_ORDER="monolith,microservices" \
  EXPERIMENT_NAME=rq2-hpa-vultr-sequential \
  IMAGE_TAG="$IMAGE_TAG" \
  DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  SCENARIO_RPS_MATRIX="login:1000,2500;create-transaction:1000,2500;enriched-transactions:1000,2500"
```

The sequential suite records `execution_mode=sequential`,
`terraform_stack=vultr-experiment-sequential`, and active architecture metadata.

## Phase 13 - Verify Results in S3

Before destroy, verify that every expected attempt folder exists:

```bash
aws s3 ls "s3://$S3_BUCKET/experiments/"
aws s3 ls "s3://$S3_BUCKET/experiments/<run_id>/" --recursive | head
```

Each attempt should include:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
datadog-time-window.json   # when Datadog is enabled
```

Quick metadata check:

```bash
aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/<architecture>/<scenario>/<rps>rps/<attempt>/metadata.json" -
```

Confirm these fields before considering the run valid:

```text
provider=vultr
execution_mode=parallel or sequential
scaling_mode=fixed or hpa
terraform_stack=vultr-experiment or vultr-experiment-sequential
image_tag=<expected tag>
app_resource_quota=<measurement-derived quota>
```

## Phase 14 - Guarded Destroy

Destroy only after S3 artifacts are verified.

Parallel:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-parallel-destroy-confirmed
```

Sequential:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-sequential-destroy-confirmed
```

Shared:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-shared-destroy-confirmed
```

After destroy, check the Vultr dashboard for leftover:

```text
VKE clusters
Compute instances
firewall groups
legacy VPC networks
SSH keys created for the benchmark
```

Do not destroy the shared stack while an experiment stack still references the
shared VPC or firewall group.

## Troubleshooting

### Dedicated CPU or instance quota is not enough

Use sequential mode, reduce the RPS matrix for smoke testing, or request a
Vultr limit increase. Do not silently change only one architecture's node size
or resource quota.

### `make vultr-render-manifests` fails on missing baseline

Create the cluster and measure allocatable capacity first:

```bash
VULTR_CONTEXT=monolith make vultr-measure-resource-baseline
```

For sequential:

```bash
VULTR_CONTEXT=benchmark make vultr-measure-resource-baseline
```

### k6 cannot upload to S3

Check the Vultr k6 secret and AWS credentials:

```bash
kubectl --context=monolith get secret k6-runner-secret -n benchmark
make vultr-preflight-check
```

Verify that the AWS credentials can write to the benchmark bucket:

```bash
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws s3 ls "s3://$S3_BUCKET/"
```

### Application cannot reach PostgreSQL

Check private IP outputs and secret-generated URLs:

```bash
terraform -chdir=infra/terraform/vultr-experiment output
kubectl --context=monolith get secret app-secret -n mono
kubectl --context=monolith get pods -n mono
kubectl --context=monolith logs -n mono deploy/monolith --tail=100
```

The PostgreSQL VM and VKE cluster must be attached to the same legacy Vultr VPC.

### Fixed/HPA mode looks wrong

Redeploy with the intended mode and run verifier:

```bash
SCALING_MODE=fixed make vultr-deploy-all IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"
SCALING_MODE=fixed EXECUTION_MODE=parallel make vultr-verify-live-mode
```

For HPA:

```bash
SCALING_MODE=hpa make vultr-deploy-all IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE"
SCALING_MODE=hpa EXECUTION_MODE=parallel make vultr-verify-live-mode
```
