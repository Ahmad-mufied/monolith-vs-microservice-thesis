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
| Parallel | `infra/terraform/vultr-parallel` | `monolith`, `msa` | Preferred thesis mode because monolith and MSA run in the same wall-clock benchmark window. |
| Sequential | `infra/terraform/vultr-sequential` | `benchmark` | Fallback when Vultr quota or budget cannot support two full clusters at the same time. |

Parallel mode is the default target for final benchmark runs. Sequential mode
is valid for smoke tests, quota-constrained iteration, and fallback execution,
but its metadata must be interpreted as separate time windows.

Quick decision guide:

| Case | Recommended path |
|---|---|
| First real integration test | Sequential smoke first, then parallel smoke |
| Final thesis run with enough quota | Parallel fixed suite, then parallel HPA suite |
| Vultr quota cannot create both clusters | Sequential fixed/HPA suites |
| Image or secret changes during debugging | Redeploy the affected mode before rerunning k6 |
| Resource baseline file is missing | Measure live allocatable capacity before render/deploy |
| S3 upload is not verified | Do not destroy experiment resources yet |

The safest operator flow is:

```text
env init
-> build and push one pinned image tag
-> preflight
-> render tfvars
-> shared apply
-> sequential or parallel apply
-> setup context
-> create secrets
-> measure resource baseline
-> deploy fixed or HPA
-> smoke
-> full suite
-> verify S3
-> guarded destroy
```

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

## Phase 1 - Initialize Local Vultr Env

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
POSTGRES_PASSWORD=...
OPERATOR_CIDRS=<your-public-ip>/32
OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

Do not run `make eks-shared-apply` for Vultr S3 upload credentials. Vultr uses
the separate AWS S3 writer stack:

```bash
make aws-s3-writer-plan
make aws-s3-writer-apply
```

`make vultr-sequential-apply` and `make vultr-parallel-apply` run
`aws-s3-writer-apply` first, so the normal apply flow ensures the writer exists
before the cluster is created. Manual `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` in `env/vultr.env` are still supported as a fallback,
but they should not be the default path.

Recommended defaults for thesis-sized Vultr tests:

```bash
VULTR_REGION=sgp
VULTR_VPC_CIDR=10.20.0.0/16
VULTR_KUBERNETES_VERSION=v1.33.0+1
VULTR_APP_NODE_PLAN=voc-c-16c-32gb-300s
VULTR_TESTING_NODE_PLAN=vc2-4c-8gb
VULTR_POSTGRES_PLAN=vc2-4c-8gb
```

The normal Vultr `make` flow auto-loads `env/vultr.env`, so you do not need to
run a manual shell `source` step before each command:

```bash
make vultr-preflight-check
```

Manual export is still optional when you want to inspect or override variables
interactively, but it is no longer required for the standard Vultr workflow.

Notes:

- `OPERATOR_CIDRS` is used for PostgreSQL SSH firewall access. Keep it as a
  narrow `/32` where possible.
- VKE currently uses legacy Vultr VPC Networks in this implementation, not VPC
  2.0. Keep the PostgreSQL VM attached to the same legacy VPC as the VKE
  cluster.
- AWS S3 upload credentials are only for k6 uploads from Vultr. The Terraform
  writer policy is limited to `s3://<bucket>/experiments/*`; keep manual
  fallback credentials scoped the same way.

## Phase 2 - Build, Push, Verify, and Pin Images

Vultr uses Docker Hub public images. Build and push the same image tag for all
deployables before provisioning or deployment.

Choose one tag and keep it for the whole integration test:

```bash
export IMAGE_TAG="vultr-main-$(git rev-parse --short HEAD)"
echo "$IMAGE_TAG"
```

For final thesis runs, prefer a stable explicit tag:

```bash
export IMAGE_TAG=thesis-vultr-20260602
```

Build all local images:

```bash
make docker-build-all IMAGE_TAG="$IMAGE_TAG"
```

Push every required image to Docker Hub public:

```bash
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"
```

The `dockerhub-push-all` target pushes:

```text
monolith
api-gateway
auth-service
item-service
transaction-service
seed-runner
k6-runner
```

Verify every image tag exists before provisioning expensive resources:

```bash
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  docker manifest inspect "docker.io/$(grep '^DOCKERHUB_NAMESPACE=' env/vultr.env | cut -d= -f2- | tr -d \"'\")/${repo}:${IMAGE_TAG}" >/dev/null
done
```

Pin the tag for this operator session:

```bash
make eks-pin-image-tag IMAGE_TAG="$IMAGE_TAG"
make eks-show-image-tag
```

Although the target name still says `eks`, the pin file is shared by the
provider-aware deploy and benchmark scripts. Passing `IMAGE_TAG="$IMAGE_TAG"`
explicitly is still the clearest pattern for final runs.

Rules for image tags:

- Use one `IMAGE_TAG` for all deployables in one benchmark session.
- Do not rebuild a different commit into the same tag during a measured run.
- If the code changes, create a new tag, push all images again, redeploy, and
  verify the live image tag before rerunning k6.
- Do not rely on implicit `HEAD` for thesis data collection.

If the image push fails:

1. rerun `make dockerhub-push-all` with the same `IMAGE_TAG`,
2. rerun the `docker manifest inspect` loop,
3. redeploy only after all seven images are visible on Docker Hub.

## Phase 3 - Preflight and Render Terraform Inputs

Run preflight before any cost-heavy action:

```bash
make vultr-preflight-check
```

Expected behavior:

- fails if `env/vultr.env` is missing
- fails if required secrets are empty
- fails if critical placeholders remain
- checks that Docker Hub images for the selected `IMAGE_TAG` are accessible
- warns if resource baseline measurement has not been captured yet

Render Vultr `terraform.tfvars` files from `env/vultr.env`:

```bash
make vultr-render-tfvars
```

Generated files:

```text
infra/terraform/vultr-shared/terraform.tfvars
infra/terraform/vultr-parallel/terraform.tfvars
infra/terraform/vultr-sequential/terraform.tfvars
```

Do not commit these files. They may contain local operator CIDRs and sensitive
database configuration.

After a stack has been initialized by its `make vultr-*-plan` target, validate
the Vultr Terraform directories directly when you need a static check:

```bash
terraform -chdir=infra/terraform/vultr-shared validate
terraform -chdir=infra/terraform/vultr-parallel validate
terraform -chdir=infra/terraform/vultr-sequential validate
```

## Phase 4 - Apply Shared Infrastructure

The shared stack creates the Vultr legacy VPC, operator SSH key, and PostgreSQL
firewall group.

Always inspect the reviewed plan before apply:

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

## Phase 5 - Choose and Apply an Experiment Stack

Choose exactly one path for the first integration pass:

| Path | Commands | Use case |
|---|---|---|
| Sequential | `vultr-sequential-plan`, `vultr-sequential-apply` | lowest cost and easiest first smoke |
| Parallel | `vultr-parallel-plan`, `vultr-parallel-apply` | final thesis mode with aligned wall-clock windows |

Do not keep parallel and sequential stacks active together unless the quota and
budget impact is intentional.

### Case A - Sequential First Smoke

Use this path for the first manual integration test:

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

### Case B - Parallel Thesis Run

Parallel mode creates two isolated VKE clusters and two PostgreSQL VMs:

Cost guardrail: this stack intentionally provisions both architecture clusters
at the same time so Datadog and k6 windows align. With the default plans, app
nodes, testing nodes, and PostgreSQL VMs are created for both monolith and MSA.
Use sequential mode instead when quota, credit, or budget cannot support the
full parallel topology, and destroy promptly after S3 results are verified.

```bash
make vultr-parallel-plan
make vultr-parallel-apply
make vultr-setup-contexts-parallel
kubectl config get-contexts monolith msa
kubectl --context=monolith get nodes -o wide
kubectl --context=msa get nodes -o wide
```

Expected resources:

```text
skripsi-vultr-monolith  : app pool + testing pool + monolith PostgreSQL VM
skripsi-vultr-msa       : app pool + testing pool + MSA PostgreSQL VM
```

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
make env-init-app
make env-init-vultr
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
IMAGE_TAG="$IMAGE_TAG" make vultr-render-manifests
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
SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" \
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
SCALING_MODE=hpa IMAGE_TAG="$IMAGE_TAG" \
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
ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" \
  make vultr-deploy-sequential-architecture

SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith \
  make vultr-verify-live-mode
```

Then, after the monolith run is complete and results are verified, switch:

```bash
ARCHITECTURE=microservices SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" \
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
  IMAGE_TAG="$IMAGE_TAG"

SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-parallel-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-parallel-hpa-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG"
```

Sequential examples:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed K6_PROFILE=smoke make run-benchmark-sequential-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-seq-mono-fixed-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG"

ARCHITECTURE=microservices SCALING_MODE=fixed K6_PROFILE=smoke make run-benchmark-sequential-vultr \
  SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-seq-msa-fixed-smoke ATTEMPT=attempt-01 \
  IMAGE_TAG="$IMAGE_TAG"
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
  SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000"
```

HPA suite:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-suite-vultr \
  EXPERIMENT_NAME=rq2-hpa-vultr \
  IMAGE_TAG="$IMAGE_TAG" \
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
  SCENARIO_RPS_MATRIX="login:1000,2500;create-transaction:1000,2500;enriched-transactions:1000,2500"
```

HPA sequential:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa make run-benchmark-suite-sequential-vultr \
  ARCHITECTURE_ORDER="monolith,microservices" \
  EXPERIMENT_NAME=rq2-hpa-vultr-sequential \
  IMAGE_TAG="$IMAGE_TAG" \
  SCENARIO_RPS_MATRIX="login:1000,2500;create-transaction:1000,2500;enriched-transactions:1000,2500"
```

The sequential suite records `execution_mode=sequential`,
`terraform_stack=vultr-sequential`, and active architecture metadata.

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
terraform_stack=vultr-parallel or vultr-sequential
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

Use this order when a command fails:

1. read the first failing command and stderr, not only the final `make` error,
2. confirm the selected mode: `parallel` uses `monolith` and `msa`, sequential
   uses `benchmark`,
3. confirm the selected `IMAGE_TAG` and `DOCKERHUB_NAMESPACE`,
4. check Terraform outputs before debugging Kubernetes secrets,
5. check pod events before application logs,
6. verify S3 artifacts before any destroy.

Quick status bundle:

```bash
make eks-show-image-tag
make vultr-preflight-check
terraform -chdir=infra/terraform/vultr-shared output
kubectl config get-contexts monolith msa benchmark
kubectl --context=benchmark get pods -A
```

For parallel, replace the last command with:

```bash
kubectl --context=monolith get pods -A
kubectl --context=msa get pods -A
```

### `DOCKERHUB_NAMESPACE` is empty or still `replace-me`

Cause:

```text
env/vultr.env exists, but the current shell has not exported it before running
a Make target that expands DOCKERHUB_NAMESPACE.
```

Check:

```bash
grep '^DOCKERHUB_NAMESPACE=' env/vultr.env
printf '%s\n' "$DOCKERHUB_NAMESPACE"
```

Fix:

```bash
make vultr-preflight-check
```

### Docker image push or pull fails

Check whether the tag exists for all required images:

```bash
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  docker manifest inspect "docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${IMAGE_TAG}" >/dev/null \
    && printf 'OK %s\n' "$repo" \
    || printf 'MISSING %s\n' "$repo"
done
```

Fix:

```bash
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"
make vultr-preflight-check
```

If pods are already running with the wrong tag, redeploy the affected mode with
the correct `IMAGE_TAG`.

### Dedicated CPU or instance quota is not enough

Use sequential mode, reduce the RPS matrix for smoke testing, or request a
Vultr limit increase. Do not silently change only one architecture's node size
or resource quota.

Check Terraform failure details:

```bash
terraform -chdir=infra/terraform/vultr-parallel plan
terraform -chdir=infra/terraform/vultr-sequential plan
```

If parallel apply fails because quota is not enough, destroy any partially
created parallel resources after checking the plan/state, then use sequential:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-parallel-destroy-confirmed
make vultr-sequential-plan
make vultr-sequential-apply
```

Do not destroy shared resources unless no experiment stack still depends on the
shared VPC and firewall group.

### Terraform plan or apply fails before creating clusters

Check env and rendered tfvars:

```bash
make vultr-preflight-check
make vultr-render-tfvars
terraform -chdir=infra/terraform/vultr-shared validate
terraform -chdir=infra/terraform/vultr-parallel validate
terraform -chdir=infra/terraform/vultr-sequential validate
```

Common fixes:

| Symptom | Fix |
|---|---|
| `VULTR_API_KEY` missing | fill `env/vultr.env`, then rerun preflight and render |
| `OPERATOR_CIDRS` missing | set your public IP as `/32`, rerun render |
| `POSTGRES_PASSWORD` missing | set it in `env/vultr.env`; do not put it in tfvars |
| provider not initialized | rerun the relevant `make vultr-*-plan` target |
| plan wants unexpected resources | stop and inspect `terraform.tfvars` before apply |

### Kubeconfig context setup fails

Check Terraform outputs:

```bash
terraform -chdir=infra/terraform/vultr-parallel output
terraform -chdir=infra/terraform/vultr-sequential output
```

Fix for parallel:

```bash
make vultr-setup-contexts-parallel
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

Fix for sequential:

```bash
make vultr-setup-context-sequential
kubectl --context=benchmark get nodes
```

If Terraform output does not contain kubeconfig values, the experiment stack is
not applied successfully yet.

### Secret creation fails

Check missing env files first:

```bash
ls env/vultr.env env/monolith.app.env env/api-gateway.app.env env/auth-service.app.env env/item-service.app.env env/transaction-service.app.env env/k6-runner.app.env
```

If any reused app env file is missing:

```bash
make env-init-app
make env-init-vultr
```

Then rerun the mode-specific secret creation:

```bash
make vultr-create-secrets-sequential
```

For parallel:

```bash
make vultr-create-secrets
```

Validate:

```bash
kubectl --context=benchmark get secret -A
```

For parallel:

```bash
kubectl --context=monolith get secret -A
kubectl --context=msa get secret -A
```

### `make vultr-render-manifests` fails on missing baseline

Create the cluster and measure allocatable capacity first:

```bash
VULTR_CONTEXT=monolith make vultr-measure-resource-baseline
```

For sequential:

```bash
VULTR_CONTEXT=benchmark make vultr-measure-resource-baseline
```

If measurement fails, check that app nodes are ready:

```bash
kubectl --context=benchmark get nodes --show-labels
kubectl --context=benchmark describe nodes
```

For parallel:

```bash
kubectl --context=monolith get nodes --show-labels
VULTR_CONTEXT=monolith make vultr-measure-resource-baseline
```

Do not bypass the baseline for measured thesis runs.

### Deployment rollout fails

Start with events, then logs:

```bash
kubectl --context=benchmark get pods -A -o wide
kubectl --context=benchmark get events -A --sort-by=.lastTimestamp
kubectl --context=benchmark describe pod -n mono <pod-name>
kubectl --context=benchmark logs -n mono deploy/monolith --tail=100
```

Common fixes:

| Symptom | Fix |
|---|---|
| `ImagePullBackOff` | verify Docker Hub tag, then redeploy with the expected `IMAGE_TAG` |
| `CreateContainerConfigError` | check Kubernetes secret names and env keys |
| migration job failed | inspect job logs, fix DB URL or migration error, redeploy |
| seed job failed | inspect seed logs, reset/reseed by rerunning deploy |
| pods pending | check node labels, taints, resource requests, and quota |

Parallel contexts:

```bash
kubectl --context=monolith get pods -A -o wide
kubectl --context=msa get pods -A -o wide
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

If the k6 job completed but S3 is empty, inspect job logs:

```bash
kubectl --context=benchmark get jobs -n benchmark
kubectl --context=benchmark logs -n benchmark job/<k6-job-name> --tail=200
```

For parallel, inspect the matching architecture context.

### Application cannot reach PostgreSQL

Check private IP outputs and secret-generated URLs:

```bash
terraform -chdir=infra/terraform/vultr-parallel output
kubectl --context=monolith get secret app-secret -n mono
kubectl --context=monolith get pods -n mono
kubectl --context=monolith logs -n mono deploy/monolith --tail=100
```

The PostgreSQL VM and VKE cluster must be attached to the same legacy Vultr VPC.

If only one architecture fails in parallel mode, compare the PostgreSQL outputs
and secrets for `monolith` and `msa` before changing infrastructure.

### Fixed/HPA mode looks wrong

Redeploy with the intended mode and run verifier:

```bash
SCALING_MODE=fixed make vultr-deploy-all IMAGE_TAG="$IMAGE_TAG"
SCALING_MODE=fixed EXECUTION_MODE=parallel make vultr-verify-live-mode
```

For HPA:

```bash
SCALING_MODE=hpa make vultr-deploy-all IMAGE_TAG="$IMAGE_TAG"
SCALING_MODE=hpa EXECUTION_MODE=parallel make vultr-verify-live-mode
```

For sequential:

```bash
ARCHITECTURE=monolith SCALING_MODE=hpa make vultr-deploy-sequential-architecture IMAGE_TAG="$IMAGE_TAG"
ARCHITECTURE=monolith SCALING_MODE=hpa EXECUTION_MODE=sequential make vultr-verify-live-mode
```

If HPA exists but metrics are unknown:

```bash
kubectl --context=benchmark get apiservice v1beta1.metrics.k8s.io
kubectl --context=benchmark get pods -n kube-system | rg metrics-server
kubectl --context=benchmark top pods -A
```

Install or wait for metrics-server through the deployment script before running
HPA benchmarks.

### Benchmark result is `INVALID` or `TIMEOUT`

Classify the failure before rerunning:

| Result | Meaning | Next action |
|---|---|---|
| `INVALID` | app, seed, secret, or infra problem affected the test | fix root cause and rerun the same attempt with a new attempt id |
| `TIMEOUT` | k6 job or target endpoint did not complete in time | inspect job logs, pod readiness, and service endpoint |
| threshold failed at high RPS | valid overload signal if app and k6 behaved correctly | keep result and mark as overload/stress behavior |

Checks:

```bash
kubectl --context=benchmark get jobs -n benchmark
kubectl --context=benchmark get pods -n benchmark -o wide
kubectl --context=benchmark logs -n benchmark job/<k6-job-name> --tail=200
aws s3 ls "s3://$S3_BUCKET/experiments/<run_id>/" --recursive
```

Use a new `ATTEMPT` for reruns so previous artifacts remain auditable.

### Destroy is blocked or unsafe

Destroy is intentionally guarded. Verify S3 first:

```bash
aws s3 ls "s3://$S3_BUCKET/experiments/<run_id>/" --recursive
```

Then choose the matching stack:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-sequential-destroy-confirmed
S3_BENCHMARK_DATA_VERIFIED=true make vultr-parallel-destroy-confirmed
```

Destroy shared last:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make vultr-shared-destroy-confirmed
```

If destroy fails, rerun `terraform plan` in the same stack and inspect whether
the remaining dependency belongs to shared or experiment state before deleting
anything manually in the Vultr dashboard.
