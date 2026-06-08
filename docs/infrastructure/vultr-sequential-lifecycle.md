# Vultr Sequential Lifecycle

## Purpose

This document is the single operator path for running the final thesis benchmark
on the Vultr sequential setup.

```text
PLATFORM=vultr
EXECUTION_MODE=sequential
Kubernetes context=benchmark
Terraform experiment stack=infra/terraform/vultr-sequential
Image registry=Docker Hub
Result storage=AWS S3
```

It covers the complete lifecycle:

```text
env-init → image build/push → tfvars → preflight → terraform apply
→ deploy → benchmark → verify S3 → destroy
```

This document supersedes the following older or provider-specific runbooks for
sequential mode:

- `docs/infrastructure/sequential-benchmark-runbook.md` (EKS sequential)
- `docs/experiment/vultr-sequential-final-experiment-guide.md`
- Sequential sections of `docs/infrastructure/benchmark-runbook-end-to-end.md`

For parallel mode on Vultr, see `docs/infrastructure/vultr-vke-runbook.md`.

## Prerequisites

### Local tools

```bash
terraform --version    # >= 1.6
kubectl version --client
helm version
aws --version
vultr-cli version      # optional, for manual Vultr API checks
```

### Accounts and credentials

| Requirement | Source |
|---|---|
| Vultr API key | `env/vultr.env` → `VULTR_API_KEY` |
| Docker Hub namespace | `env/vultr.env` → `DOCKERHUB_NAMESPACE` |
| AWS S3 credentials | `env/aws-benchmark.env` or Vultr S3 writer Terraform output |
| S3 bucket | `env/vultr.env` → `S3_BUCKET` |

## Mental Model

```text
make env-init             = choose provider and execution mode
make profile-show         = verify current operator session
make render-tfvars        = generate terraform.tfvars from env files
make preflight-check      = validate all prerequisites
make experiment-bootstrap = terraform apply + context + secrets + baseline + manifests
make deploy-workloads     = deploy one architecture (manual smoke only)
make run-benchmark-suite  = run full matrix (deploys each architecture internally)
make experiment-destroy-confirmed = destroy after S3 verification
```

The generic operator workflow dispatches through `scripts/operator-dispatch.sh`,
which reads the operator profile and routes to provider-specific scripts.

Key distinction:

```text
manual smoke path:
  deploy-workloads → verify-live-mode → run-benchmark-case

full suite path:
  run-benchmark-suite
  → auto-deploy architecture phase 1 (monolith)
  → run all cases for phase 1
  → wait ARCHITECTURE_SWITCH_DELAY
  → auto-deploy architecture phase 2 (microservices)
  → run all cases for phase 2
```

For the full suite, you do **not** need to run `make deploy-workloads` before
`make run-benchmark-suite`. The suite deploys each architecture phase internally.

---

## Phase 1 — Initialize Operator Session

Run once at the start of each operator session:

```bash
make env-init PLATFORM=vultr EXECUTION_MODE=sequential
make profile-show
```

Expected output:

```text
PLATFORM=vultr
CLOUD_PROVIDER=vultr
EXECUTION_MODE=sequential
IMAGE_REGISTRY=dockerhub
RESULT_STORAGE=aws-s3
```

Then edit `env/vultr.env` if placeholders remain:

```bash
VULTR_API_KEY=<your-vultr-api-key>
DOCKERHUB_NAMESPACE=<your-dockerhub-namespace>
S3_BUCKET=skripsi-benchmark-results
AWS_REGION=ap-southeast-1
OPERATOR_CIDRS=<your-public-ip>/32
OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

`env-init` auto-detects the operator public IP and SSH key. If the auto-detection
fails or you want to pin a specific value, edit `OPERATOR_CIDRS_SOURCE` or
`OPERATOR_SSH_PUBLIC_KEY_SOURCE` to `manual`.

---

## Phase 2 — Build, Push, and Pin Images

Choose one image tag for the whole experiment:

```bash
export IMAGE_TAG=thesis-vultr-20260606
```

Build and push all required Docker Hub images:

```bash
make docker-build-all IMAGE_TAG="$IMAGE_TAG"
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"
```

Pin the tag so later commands use it by default:

```bash
make pin-image-tag IMAGE_TAG="$IMAGE_TAG"
make show-image-tag
```

Rules:

- Do not rebuild a different commit into the same tag.
- If code changes, create a new image tag.
- After pinning, deploy and benchmark commands can omit `IMAGE_TAG`; the
  Makefile reads `env/image-tag.env`.
- To override the pin for one command, pass a non-empty literal value such as
  `IMAGE_TAG=670736c make run-benchmark-suite`.

---

## Phase 3 — Render Terraform Inputs

Render Vultr `terraform.tfvars` files from `env/vultr.env`:

```bash
make render-tfvars
```

This generates:

```text
infra/terraform/vultr-shared/terraform.tfvars
infra/terraform/vultr-parallel/terraform.tfvars
infra/terraform/vultr-sequential/terraform.tfvars
```

Do not commit generated `terraform.tfvars` files.

---

## Phase 4 — Run Preflight

Run preflight before creating expensive resources:

```bash
make preflight-check
```

This validates:

- `VULTR_API_KEY` is set and not a placeholder
- `DOCKERHUB_NAMESPACE` is set and not a placeholder
- AWS S3 writer credentials exist for k6 upload
- S3 bucket is accessible
- Required Docker Hub images exist for the pinned `IMAGE_TAG`
- Whether the Vultr resource baseline has already been measured

The resource-baseline warning is expected before the cluster exists.

---

## Phase 5 — Apply Terraform

### 5.1 Shared infrastructure

Apply shared Vultr resources (VPC, firewall, SSH key):

```bash
make shared-plan
make shared-apply
```

### 5.2 Experiment bootstrap

Bootstrap the sequential experiment stack and Kubernetes runtime:

```bash
make experiment-bootstrap
```

This is the main command. It runs:

```text
make experiment-plan       → terraform plan for vultr-sequential
make experiment-apply      → terraform apply (includes aws-s3-writer-apply)
make setup-contexts        → configure kubectl context "benchmark"
make create-secrets        → create K8s secrets for mono, msa, benchmark namespaces
make measure-resource-baseline → measure live Vultr app-node capacity
make render-manifests      → render Kustomize manifests with final image tag
```

`experiment-apply` provisions:

- one VKE cluster for context `benchmark`
- app node pool (`node-group=app`)
- testing/k6 node pool (`node-group=testing`)
- one PostgreSQL VM
- private network integration
- AWS S3 writer stack for k6 result uploads

### 5.3 Individual steps (for debugging)

Use these only when debugging a specific step or resuming from a known partial
bootstrap point:

```bash
make experiment-plan
make experiment-apply
make setup-contexts
make create-secrets
VULTR_CONTEXT=benchmark make measure-resource-baseline
make render-manifests
```

### 5.4 Refresh operator CIDR

If the operator machine changes network (VPN, hotspot, ISP), refresh
`OPERATOR_CIDRS` before running Terraform:

```bash
# Auto-detect
make env-init PLATFORM=vultr EXECUTION_MODE=sequential
make render-tfvars
make shared-plan
make shared-apply
```

For manual CIDR, edit `env/vultr.env` first:

```bash
OPERATOR_CIDRS=<new-public-ip>/32
OPERATOR_CIDRS_SOURCE=manual
```

Only the shared stack needs re-apply for CIDR changes. The experiment stack
usually does not need re-apply.

### 5.5 Verify

```bash
kubectl --context=benchmark get nodes -o wide
```

Expected node roles:

```text
node-group=app      for application workloads
node-group=testing  for k6 runner jobs (tainted workload=benchmark:NoSchedule)
```

For Vultr VKE, `setup-contexts` waits for both node groups to register. Default
timeout is 15 minutes. Override if needed:

```bash
VULTR_NODE_READY_TIMEOUT_SECONDS=1200 make experiment-bootstrap
```

---

## Phase 6 — Deploy

### 6.1 Full suite path (recommended)

For the full benchmark matrix, do **not** run `make deploy-workloads` manually.
`make run-benchmark-suite` deploys each architecture phase internally using the
suite-level `SCALING_MODE`, `IMAGE_TAG`, and architecture order.

Skip to [Phase 7 — Run Benchmark](#phase-7--run-benchmark).

### 6.2 Manual smoke path (optional)

Use this only for validating image pull, secrets, migrations, and seed jobs
before the full matrix.

Deploy fixed monolith:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith make verify-live-mode
```

Deploy fixed microservices:

```bash
ARCHITECTURE=microservices SCALING_MODE=fixed make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=microservices make verify-live-mode
```

### 6.3 What deploy-sequential-architecture.sh does

For each architecture, the deploy script performs:

```text
1. Validate required secrets exist
2. Scale down the inactive architecture (delete HPA, scale to 0)
3. Bootstrap databases (creates mono_db or auth_db/item_db/transaction_db)
4. Run migrations (Goose)
5. Reset data (truncate tables)
6. Seed benchmark data
7. Apply Kustomize overlay (fixed or HPA)
8. Install metrics-server (if SCALING_MODE=hpa)
9. Wait for rollout
10. Install Datadog (if DATADOG_API_KEY is configured)
```

All jobs use `kubectl --context=benchmark`.

---

## Phase 7 — Run Benchmark

### 7.1 Single case (smoke)

Run one architecture, one scenario, one RPS level:

```bash
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-seq-fixed-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
make run-benchmark-case
```

### 7.2 Full sequential suite

Before running, verify the operator profile:

```bash
make profile-show
```

Run the fixed suite with monolith first:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
RUN_ID=rq1-fixed-vultr-sequential \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500;concurrent-mixed-workload:100,200,300,400,500" \
make run-benchmark-suite
```

Run with microservices first (override architecture order):

```bash
ARCHITECTURE_ORDER="microservices monolith" \
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
RUN_ID=rq1-fixed-vultr-sequential-msa-first \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500;concurrent-mixed-workload:100,200,300,400,500" \
make run-benchmark-suite
```

### 7.3 HPA suite

```bash
SCALING_MODE=hpa \
K6_PROFILE=hpa \
RUN_ID=rq2-hpa-vultr-sequential \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=300 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-suite
```

Note: `K6_PROFILE=hpa` uses `ramping-arrival-rate` stages (~13 minutes per
case). `TEST_DURATION` is ignored for HPA.

### 7.4 Suite behavior

Architecture phases:

```text
phase 1: deploy first architecture, run all cases, wait ARCHITECTURE_SWITCH_DELAY
phase 2: deploy second architecture, run all cases
```

Default order: `ARCHITECTURE_ORDER="monolith microservices"`.

Data reset per scenario:

| Scenario | Reset/seed timing |
|---|---|
| `login` | Once before the first RPS level. |
| `create-transaction` | Before every RPS level (mutates data). |
| `enriched-transactions` | Once before the first RPS level, then prepare enrichment data. |
| `concurrent-mixed-workload` | Before every RPS level (mutates data). |
| `mixed-workload` | Before every RPS level (mutates data). |

Resume support:

- Before each case, the suite checks S3 for an existing `result-status.json`.
- Completed cases are skipped and included in the summary.
- If all cases for an architecture exist in S3, redeploy is skipped.
- To rerun from scratch, use a new `RUN_ID` or `ATTEMPT`.

ETA behavior:

- `est_case` — expected finish time for the current case.
- `est_scenario` — expected finish time for remaining RPS levels in the current
  scenario.
- `est_suite` — expected finish time for the remaining sequential suite.
- Per-case overhead buffer: `SEQUENTIAL_CASE_OVERHEAD_SECONDS=180` (default).

SCALING_MODE / K6_PROFILE pairing:

| SCALING_MODE | K6_PROFILE | Notes |
|---|---|---|
| `fixed` | `steady` | Default if omitted. |
| `hpa` | `hpa` | Required. Rejects `steady`, `ramp`, `smoke`. |

### 7.5 SCENARIO_RPS_MATRIX

Override the usual `SCENARIOS` x `RPS_LEVELS` cross-product:

```bash
SCENARIO_RPS_MATRIX="login:100,200;create-transaction:100,200"
```

Format: `scenario1:rps1,rps2;rscenario2:rps3,rps4`. Uses spaces between
entries.

### 7.6 Inter-case delay

| Mode | Recommended `INTER_CASE_DELAY` |
|---|---|
| Fixed | `120` seconds |
| HPA | `300` seconds |

`ARCHITECTURE_SWITCH_DELAY` defaults to `300` seconds between monolith and
microservices phases.

### 7.7 Auto-destroy

For unattended runs:

```bash
AUTO_DESTROY_CONFIRMED=true \
RUN_ID=rq1-fixed-vultr-sequential \
SCALING_MODE=fixed \
make run-benchmark-suite
```

After `_suite/summary.json` is uploaded, the suite calls
`make experiment-destroy-confirmed`.

---

## Phase 8 — Verify S3 Results

Before destroy, verify uploaded benchmark artifacts:

```bash
aws s3 ls "s3://$S3_BUCKET/experiments/"
aws s3 ls "s3://$S3_BUCKET/experiments/<run_id>/" --recursive
```

Per attempt, expect:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
result-status.json
datadog-time-window.json   # when Datadog is enabled
```

Inspect one metadata file:

```bash
aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/<architecture>/<scenario>/<rps>rps/<attempt>/metadata.json" -
```

Expected metadata fields:

```text
provider=vultr
execution_mode=sequential
terraform_stack=vultr-sequential
scaling_mode=fixed or hpa
image_tag=<IMAGE_TAG final>
app_resource_quota=7800m CPU / 15360Mi memory
```

Inspect the suite summary:

```bash
aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/_suite/summary.json" - | jq .
```

Do not destroy infrastructure until all expected files are present.

---

## Phase 9 — Destroy Infrastructure

Destroy only after S3 artifacts are verified:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make experiment-destroy-confirmed
```

This destroys the VKE cluster, PostgreSQL VM, and related resources.

If all experiments are complete and no other stack uses shared Vultr
network/firewall resources:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make shared-destroy-confirmed
```

After destroy, check the Vultr dashboard for leftover resources:

```text
VKE clusters
Compute instances
Firewall groups
Legacy VPC networks
SSH keys created for the benchmark
```

Do not destroy the shared stack while an experiment stack still references its
VPC or firewall group.

---

## Quick Reference

| Command | Purpose |
|---|---|
| `make env-init PLATFORM=vultr EXECUTION_MODE=sequential` | Initialize operator session |
| `make profile-show` | Verify operator profile |
| `make docker-build-all IMAGE_TAG=<tag>` | Build all Docker images |
| `make dockerhub-push-all IMAGE_TAG=<tag>` | Push all images to Docker Hub |
| `make pin-image-tag IMAGE_TAG=<tag>` | Pin image tag for the session |
| `make show-image-tag` | Show current pinned tag |
| `make render-tfvars` | Render Terraform tfvars from env files |
| `make preflight-check` | Validate prerequisites |
| `make shared-plan` | Plan shared Terraform |
| `make shared-apply` | Apply shared Terraform (VPC, firewall) |
| `make experiment-bootstrap` | Full infra bootstrap (plan+apply+context+secrets+baseline+manifests) |
| `make experiment-plan` | Plan experiment Terraform |
| `make experiment-apply` | Apply experiment Terraform |
| `make setup-contexts` | Configure kubectl context `benchmark` |
| `make create-secrets` | Create K8s secrets for all namespaces |
| `make measure-resource-baseline` | Measure Vultr app-node capacity |
| `make render-manifests` | Render Kustomize manifests with final image tag |
| `ARCHITECTURE=... SCALING_MODE=... make deploy-workloads` | Deploy one architecture (manual smoke) |
| `make verify-live-mode` | Verify live cluster matches expected mode |
| `ARCHITECTURE=... SCENARIO=... TARGET_RPS=... make run-benchmark-case` | Run single benchmark case |
| `make run-benchmark-suite` | Run full sequential suite |
| `S3_BENCHMARK_DATA_VERIFIED=true make experiment-destroy-confirmed` | Destroy experiment infra |
| `S3_BENCHMARK_DATA_VERIFIED=true make shared-destroy-confirmed` | Destroy shared infra |

### Suite argument reference

| Argument | Example | Purpose |
|---|---|---|
| `SCALING_MODE` | `fixed` or `hpa` | Deployment overlay for each architecture phase. |
| `K6_PROFILE` | `steady` or `hpa` | k6 execution profile. HPA suite must use `hpa`. |
| `TEST_DURATION` | `5m` | Fixed/steady case duration. Ignored for HPA. |
| `RUN_ID` | `rq1-fixed-vultr-sequential` | S3 run folder under `experiments/`. |
| `ATTEMPT` | `attempt-01` | Attempt folder per case. |
| `ARCHITECTURE_ORDER` | `"microservices monolith"` | Override default order (`monolith microservices`). |
| `INTER_CASE_DELAY` | `120` or `300` | Pause between cases within an architecture phase. |
| `ARCHITECTURE_SWITCH_DELAY` | `300` | Pause between architecture phases. |
| `IMAGE_TAG` | `670736c` | Optional override; default from `env/image-tag.env`. |
| `SCENARIO_RPS_MATRIX` | `login:100,200` | Per-scenario RPS override. |
| `AUTO_DESTROY_CONFIRMED` | `true` | Auto-destroy after suite completes. |

### Env-file values (do not pass on command line normally)

| Env value | Source | Purpose |
|---|---|---|
| `PLATFORM` | `env/operator-profile.env` | Selects Vultr. |
| `EXECUTION_MODE` | `env/operator-profile.env` | Selects sequential. |
| `CLOUD_PROVIDER` | `env/operator-profile.env` | Normalized provider value. |
| `S3_BUCKET` | `env/vultr.env` | Result bucket. |
| `AWS_REGION` | `env/vultr.env` | AWS region for S3. |
| `DOCKERHUB_NAMESPACE` | `env/vultr.env` | Docker Hub namespace. |

---

## Troubleshooting

Use this order when a command fails:

1. Read the first failing command and stderr, not only the final `make` error.
2. Confirm the selected mode: sequential uses context `benchmark`.
3. Confirm `IMAGE_TAG` and `DOCKERHUB_NAMESPACE`.
4. Check Terraform outputs before debugging Kubernetes secrets.
5. Check pod events before application logs.
6. Verify S3 artifacts before any destroy.

Quick status bundle:

```bash
make show-image-tag
make preflight-check
terraform -chdir=infra/terraform/vultr-shared output
kubectl --context=benchmark get nodes
kubectl --context=benchmark get pods -A
```

### Node not ready after terraform apply

```bash
kubectl --context=benchmark get nodes -o wide
kubectl --context=benchmark describe node <node-name>
```

Vultr VKE node pool registration can take up to 15 minutes. If nodes do not
appear, check the Vultr dashboard for provisioning errors.

### Secret missing or wrong

```bash
kubectl --context=benchmark get secrets -n mono
kubectl --context=benchmark get secrets -n msa
kubectl --context=benchmark get secrets -n benchmark
```

Fix: `make create-secrets`

### Docker image pull fails

Verify images exist:

```bash
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  docker manifest inspect "docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${IMAGE_TAG}" >/dev/null \
    && printf 'OK %s\n' "$repo" \
    || printf 'MISSING %s\n' "$repo"
done
```

Fix: `make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"`

### Pods not starting

```bash
kubectl --context=benchmark describe pod -n mono -l app=monolith
kubectl --context=benchmark get events -n mono --sort-by=.metadata.creationTimestamp
```

Common causes:

- Secret missing
- Image pull error
- PostgreSQL not reachable (check security group allows port 5432)
- ResourceQuota exceeded (previous HPA scale-out not cleaned up)

### k6 job fails

```bash
kubectl --context=benchmark logs job/k6-benchmark -n benchmark
```

Common causes:

- `BASE_URL` not reachable (check app pods and Service)
- No enrichment data (run prepare-enrichment before enriched-transactions)
- S3 upload fails (check S3 writer credentials)

### Datadog not showing traces

```bash
kubectl --context=benchmark get pods -n datadog
kubectl --context=benchmark logs -n datadog -l app=datadog --tail=50
```

Common causes:

- `datadog-secret` missing
- Agent not on app-nodes (check DaemonSet)
- `DD_AGENT_HOST` wrong (pods use `status.hostIP`)

### PostgreSQL connection refused

```bash
kubectl --context=benchmark run pg-test \
  --image=postgres:18 \
  --rm -it \
  --restart=Never \
  -- psql "postgres://postgres_admin:<password>@<postgres-ip>:5432/bootstrap?sslmode=require" -c '\l'
```

Check that the PostgreSQL VM is running and the firewall allows port 5432 from
the VKE cluster's private network.

### ResourceQuota deadlock after switching from HPA to fixed

```bash
kubectl --context=benchmark delete hpa --all -n msa
kubectl --context=benchmark scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa
kubectl --context=benchmark delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found
ARCHITECTURE=microservices SCALING_MODE=fixed make deploy-workloads
```

---

## K8s Monitoring & Debugging Commands

Use these commands when you need to inspect live cluster state, debug failing
resources, or monitor a running benchmark. All commands target
`--context=benchmark` because sequential mode uses a single cluster.

### Cluster overview

Get node status and roles:

```bash
kubectl --context=benchmark get nodes -o wide
kubectl --context=benchmark describe node <node-name>
```

Get a quick runtime summary across all namespaces:

```bash
kubectl --context=benchmark get pods,svc,hpa,resourcequota -n mono
kubectl --context=benchmark get pods,svc,hpa,resourcequota -n msa
kubectl --context=benchmark get jobs -n benchmark
```

Get the newest events first:

```bash
kubectl --context=benchmark get events -A --sort-by=.metadata.creationTimestamp
```

Check resource consumption (requires metrics-server):

```bash
kubectl --context=benchmark top nodes
kubectl --context=benchmark top pods -A
```

### Deployment inspection

Monolith:

```bash
kubectl --context=benchmark rollout status deployment/monolith -n mono --timeout=300s
kubectl --context=benchmark get deployment monolith -n mono
kubectl --context=benchmark get pods -n mono -o wide
kubectl --context=benchmark describe deployment monolith -n mono
kubectl --context=benchmark describe pod -n mono -l app=monolith
```

Microservices:

```bash
kubectl --context=benchmark rollout status deployment/api-gateway -n msa --timeout=300s
kubectl --context=benchmark rollout status deployment/auth-service -n msa --timeout=300s
kubectl --context=benchmark rollout status deployment/item-service -n msa --timeout=300s
kubectl --context=benchmark rollout status deployment/transaction-service -n msa --timeout=300s
kubectl --context=benchmark get deployment -n msa
kubectl --context=benchmark get pods -n msa -o wide
```

### Application logs

Read current logs:

```bash
# Monolith
kubectl --context=benchmark logs deploy/monolith -n mono --tail=100

# Microservices
kubectl --context=benchmark logs deploy/api-gateway -n msa --tail=100
kubectl --context=benchmark logs deploy/auth-service -n msa --tail=100
kubectl --context=benchmark logs deploy/item-service -n msa --tail=100
kubectl --context=benchmark logs deploy/transaction-service -n msa --tail=100
```

Read previous container logs after a crash:

```bash
kubectl --context=benchmark logs deploy/monolith -n mono --previous --tail=100
kubectl --context=benchmark logs deploy/transaction-service -n msa --previous --tail=100
```

### Restart deployments

Safe operator actions when pods need a fresh start:

```bash
# Monolith
kubectl --context=benchmark rollout restart deployment/monolith -n mono
kubectl --context=benchmark rollout status deployment/monolith -n mono --timeout=300s

# Microservices
kubectl --context=benchmark rollout restart deployment/api-gateway -n msa
kubectl --context=benchmark rollout restart deployment/auth-service -n msa
kubectl --context=benchmark rollout restart deployment/item-service -n msa
kubectl --context=benchmark rollout restart deployment/transaction-service -n msa
```

### Job inspection

Get job summaries:

```bash
kubectl --context=benchmark get jobs -n mono
kubectl --context=benchmark get jobs -n msa
kubectl --context=benchmark get jobs -n benchmark
```

Inspect a specific job:

```bash
kubectl --context=benchmark describe job monolith-migration-job -n mono
kubectl --context=benchmark describe job transaction-migration-job -n msa
kubectl --context=benchmark get pods -n mono -l job-name=monolith-migration-job
kubectl --context=benchmark get pods -n msa -l job-name=transaction-migration-job
```

Read job logs:

```bash
# Monolith jobs
kubectl --context=benchmark logs job/db-bootstrap-job -n benchmark
kubectl --context=benchmark logs job/monolith-migration-job -n mono
kubectl --context=benchmark logs job/reset-monolith-data-job -n mono
kubectl --context=benchmark logs job/seed-monolith-benchmark-data-job -n mono
kubectl --context=benchmark logs job/prepare-monolith-enrichment-benchmark-data-job -n mono
kubectl --context=benchmark logs job/k6-benchmark-monolith -n benchmark

# Microservices jobs
kubectl --context=benchmark logs job/auth-migration-job -n msa
kubectl --context=benchmark logs job/item-migration-job -n msa
kubectl --context=benchmark logs job/transaction-migration-job -n msa
kubectl --context=benchmark logs job/reset-microservices-data-job -n msa
kubectl --context=benchmark logs job/seed-microservices-benchmark-data-job -n msa
kubectl --context=benchmark logs job/prepare-microservices-enrichment-benchmark-data-job -n msa
kubectl --context=benchmark logs job/k6-benchmark-microservices -n benchmark
```

Wait for job completion:

```bash
kubectl --context=benchmark wait --for=condition=complete job/monolith-migration-job -n mono --timeout=300s
kubectl --context=benchmark wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=600s
```

### HPA and ResourceQuota inspection

```bash
kubectl --context=benchmark get hpa -n mono
kubectl --context=benchmark get hpa -n msa
kubectl --context=benchmark describe hpa monolith -n mono
kubectl --context=benchmark describe hpa api-gateway -n msa

kubectl --context=benchmark get resourcequota -n mono
kubectl --context=benchmark get resourcequota -n msa
kubectl --context=benchmark describe resourcequota mono-resource-quota -n mono
kubectl --context=benchmark describe resourcequota msa-resource-quota -n msa
```

### Secrets and config

```bash
kubectl --context=benchmark get secrets -n mono
kubectl --context=benchmark get secrets -n msa
kubectl --context=benchmark get secrets -n benchmark
kubectl --context=benchmark get secret monolith-env -n mono -o yaml
kubectl --context=benchmark get secret api-gateway-secret -n msa -o yaml
```

### Image verification

Check which images are running:

```bash
kubectl --context=benchmark get pods -n mono -o jsonpath='{range .items[*]}{.metadata.name}{"  ->  "}{.spec.containers[*].image}{"\n"}{end}'
kubectl --context=benchmark get pods -n msa -o jsonpath='{range .items[*]}{.metadata.name}{"  ->  "}{.spec.containers[*].image}{"\n"}{end}'
```

### Datadog Agent health

```bash
kubectl --context=benchmark get pods -n datadog
kubectl --context=benchmark get daemonset -n datadog
kubectl --context=benchmark rollout status daemonset/datadog -n datadog --timeout=300s
kubectl --context=benchmark logs -n datadog -l app=datadog --tail=100
```

### Live benchmark monitoring

While a k6 job is running, inspect the benchmark pod:

```bash
kubectl --context=benchmark get pods -n benchmark -l job-name=k6-benchmark-monolith -o wide
kubectl --context=benchmark get pods -n benchmark -l job-name=k6-benchmark-microservices -o wide
kubectl --context=benchmark describe job k6-benchmark-monolith -n benchmark
kubectl --context=benchmark logs job/k6-benchmark-monolith -n benchmark -f
```

Check which architecture is currently active:

```bash
kubectl --context=benchmark get deployment -n mono
kubectl --context=benchmark get deployment -n msa
```

Only one architecture should have running pods. If both have replicas > 0,
the deploy step did not scale down the inactive architecture.

### PostgreSQL connectivity test

```bash
kubectl --context=benchmark run pg-test \
  --image=postgres:18 \
  --rm -it \
  --restart=Never \
  -- psql "postgres://postgres_admin:<password>@<postgres-ip>:5432/bootstrap?sslmode=require" -c '\l'
```

### Vultr-specific checks

Check VKE cluster status from the Vultr CLI:

```bash
vultr-cli kubernetes list
vultr-cli kubernetes get <cluster-id>
```

Check node pool status:

```bash
vultr-cli kubernetes node-pool list <cluster-id>
vultr-cli kubernetes node-pool get <cluster-id> <node-pool-id>
```

Check PostgreSQL VM:

```bash
vultr-cli instance list
```

---

## Avoid

- Do not use `ARCHITECTURE_ORDER="monolith,microservices"` (commas).
- Do not switch fixed to HPA only in the benchmark command without redeploying.
- Do not assume `ARCHITECTURE_ORDER` changes fixed versus HPA; it only changes
  which architecture runs first.
- Do not destroy before S3 results are verified.
- Do not rebuild a different image into the same tag.
- Do not use the EKS runbook as the primary guide for the Vultr sequential
  experiment.
