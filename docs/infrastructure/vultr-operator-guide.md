# Vultr Operator Guide

## Purpose

Single operator guide for running the thesis benchmark on Vultr Kubernetes
Engine (VKE). Covers the full lifecycle through one unified Terraform stack
(`infra/terraform/vultr`) with an `execution_mode` variable (`parallel` or
`sequential`) that controls whether one or two VKE clusters are provisioned.

```text
Kubernetes/application compute : VKE              PostgreSQL compute    : Vultr VM per arch
private network                : Vultr legacy VPC benchmark artifacts   : AWS S3
container images               : Docker Hub       observability         : Datadog SaaS
```

Related: `docs/infrastructure/vultr-complete-architecture.md`,
`docs/infrastructure/vultr-configuration-reference.md`,
`docs/experiment/scaling-mode-strategy.md`.

## Prerequisites

```bash
terraform version     # >= 1.6    kubectl version --client    helm version
aws --version         docker version    vultr-cli version   # optional
```

Required: Vultr API token, Docker Hub account, AWS S3 credentials, S3 bucket.
Optional: Datadog API key. Do not commit env files, tfvars, kubeconfigs, or state.

## Quick Start

```text
env-init → build/push images → preflight → render-tfvars
→ terraform apply → setup contexts → create secrets
→ measure resource baseline → render manifests
→ deploy → benchmark → verify S3 → destroy
```

Bootstrap shortcut (Phases 5–9): `make experiment-bootstrap`

---

## Phase 1 — Initialize Operator Session

```bash
make env-init PLATFORM=vultr EXECUTION_MODE=<parallel|sequential>
make profile-show
```

Edit `env/vultr.env` and replace placeholders:

```text
VULTR_API_KEY=...  DOCKERHUB_NAMESPACE=...  S3_BUCKET=...  AWS_REGION=ap-southeast-1
POSTGRES_PASSWORD=...  OPERATOR_CIDRS=<your-ip>/32  OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

`env-init` auto-detects operator public IP and SSH key. Set
`OPERATOR_CIDRS_SOURCE=manual` to pin a specific value.

Recommended defaults:

```text
VULTR_REGION=sgp  VULTR_VPC_CIDR=10.20.0.0/16  VULTR_KUBERNETES_VERSION=v1.36.1+1
VULTR_APP_NODE_PLAN=voc-c-8c-16gb-150s-amd  VULTR_APP_NODE_COUNT=1
VULTR_TESTING_NODE_PLAN=vc2-2c-4gb  VULTR_POSTGRES_PLAN=voc-c-2c-4gb-50s-amd
```

One larger app node avoids scheduling fragmentation. VKE uses legacy VPC
Networks — keep the PostgreSQL VM on the same legacy VPC.

## Phase 2 — Build, Push, and Pin Images

```bash
export IMAGE_TAG=thesis-vultr-20260606
make docker-build-all IMAGE_TAG="$IMAGE_TAG"
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"
```

Verify all 7 images exist (`monolith`, `api-gateway`, `auth-service`,
`item-service`, `transaction-service`, `seed-runner`, `k6-runner`):

```bash
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  docker manifest inspect "docker.io/$(grep '^DOCKERHUB_NAMESPACE=' env/vultr.env | cut -d= -f2- | tr -d \"'\")/${repo}:${IMAGE_TAG}" >/dev/null
done
```

Pin: `make pin-image-tag IMAGE_TAG="$IMAGE_TAG" && make show-image-tag`

Rules: one tag per session, never rebuild different commit into same tag, create
new tag if code changes.

## Phase 3 — Render Terraform Inputs

```bash
make render-tfvars    # generates infra/terraform/vultr/terraform.tfvars
```

Do not commit. All Vultr resources managed by the single
`infra/terraform/vultr` stack — do not delete manually from the dashboard.

## Phase 4 — Run Preflight

```bash
make preflight-check
```

Validates: API key, Docker Hub namespace, S3 credentials, image availability,
resource baseline status. The baseline warning is expected before cluster exists.

Static check after init: `terraform -chdir=infra/terraform/vultr validate`

---

## Phase 5 — Apply Infrastructure

### Shared + Experiment

```bash
make shared-plan && make shared-apply       # VPC, firewall, SSH key
make experiment-bootstrap                   # everything below in one shot
```

Note: for Vultr, `shared-plan`/`shared-apply` and `experiment-plan`/`experiment-apply`
all dispatch to the same unified `infra/terraform/vultr` stack. The generic
targets (`shared-*`, `experiment-*`) are provider-aware shortcuts that route
through `operator-dispatch.sh`. For Vultr, `shared-apply` and `experiment-apply`
run the same Terraform — you can use either, or use `make vultr-plan` +
`make vultr-apply` directly.

`experiment-bootstrap` runs:

```text
experiment-plan → experiment-apply → setup-contexts → create-secrets
→ measure-resource-baseline → render-manifests
```

`experiment-apply` provisions: VKE cluster(s) per `execution_mode`, app node
pool, testing node pool (tainted `workload=benchmark:NoSchedule`), PostgreSQL
VM(s), private network, AWS S3 writer stack.

VKE node registration timeout default: 15 min. Override:

```bash
VULTR_NODE_READY_TIMEOUT_SECONDS=1200 make experiment-bootstrap
```

### AWS S3 Writer

Applied automatically by `experiment-apply`. Creates least-privilege IAM user
scoped to `s3://<bucket>/experiments/*`. Credentials flow from Terraform state
into `k6-runner-secret` via `create-secrets`. The same Terraform output is also
the default credential source for Vultr benchmark preflight, suite metadata
upload, resume checks, and local artifact inspection. No AWS auth needed for
the read step (state is local). Debug independently:

```bash
make aws-s3-writer-plan && make aws-s3-writer-apply
```

### Individual steps (debugging)

```bash
make experiment-plan && make experiment-apply && make setup-contexts
make create-secrets && make measure-resource-baseline && make render-manifests
```

### Refresh operator CIDR

After network change: `make env-init` → `make render-tfvars` →
`make shared-plan` → `make shared-apply`. Only the shared stack needs re-apply.

---

## Phase 6 — Setup Kubernetes Contexts

Included in `experiment-bootstrap`. Manual:

```bash
make setup-contexts
kubectl --context=benchmark get nodes -o wide          # sequential
kubectl --context=monolith get nodes -o wide            # parallel
kubectl --context=msa get nodes -o wide                 # parallel
```

Node roles: `node-group=app` (applications), `node-group=testing` (k6, tainted).

## Phase 7 — Create Kubernetes Secrets

Included in `experiment-bootstrap`. Manual: `make create-secrets`

Creates application secrets in `mono`, `msa`, and `benchmark` from
`env/*.app.env`, `env/vultr.env`, and Terraform outputs. The scripts reconcile
existing secrets with the current template:

- Go remains the source of truth for runtime defaults; the scripts always pass
  only required secrets, environment-specific values, and explicit overrides
- preserved credentials such as `JWT_SECRET`, `ADMIN_USER_EMAIL`, and
  `ADMIN_USER_PASSWORD` can fall back to the current in-cluster secret when the
  local env file leaves them empty
- when an operator supplies only part of a timeout chain, the scripts derive the
  dependent timeout required to keep rollout-safe invariants
- invalid timeout chains still fail before `kubectl apply`

Runtime defaults that now live in Go unless explicitly overridden:

```text
Monolith:
APP_REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s
DIAGNOSTIC_LOGGING_ENABLED=false
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=8
LOGIN_QUEUE_TIMEOUT=2s

Microservices API Gateway:
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s
DIAGNOSTIC_LOGGING_ENABLED=false

Microservices services:
GRPC_REQUEST_TIMEOUT=30s
ITEM_VALIDATION_TIMEOUT=25s        # transaction-service only

Auth Service login admission:
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=2
LOGIN_MAX_CONCURRENCY_HPA=1
LOGIN_QUEUE_TIMEOUT=2s
```

When `SCALING_MODE=hpa`, the secret generation flow selects
`LOGIN_MAX_CONCURRENCY_HPA=1` for `auth-service` so the admission-slot budget
stays proportional to the smaller `975m` HPA pod CPU limit.

`DIAGNOSTIC_LOGGING_ENABLED` is now config-driven through the same app env
files and Secret creation flow. To enable it for a focused RCA run, set the
flag in the relevant `*.app.env` file, rerun `make create-secrets` (or the
Vultr-specific secret target you use), then redeploy the workload so the pod
reads the updated Secret.

`LOGIN_MAX_CONCURRENCY` is now config-driven through the same flow as well.
For microservices, keep `LOGIN_MAX_CONCURRENCY=2` as the fixed baseline and
`LOGIN_MAX_CONCURRENCY_HPA=1` as the HPA baseline unless you are intentionally
running a supplemental tuning experiment.

Expected overload behavior:

```text
Auth Service login queue full -> gRPC ResourceExhausted
API Gateway maps ResourceExhausted -> HTTP 503 SERVICE_UNAVAILABLE
Monolith login queue full -> HTTP 503 SERVICE_UNAVAILABLE
```

gRPC addresses must use headless services:

```text
AUTH_SERVICE_ADDR=dns:///auth-service-headless.msa.svc.cluster.local:50051
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
TRANSACTION_SERVICE_ADDR=dns:///transaction-service-headless.msa.svc.cluster.local:50053
```

Validation:

```bash
kubectl --context=<ctx> get secret -A
kubectl --context=<ctx> get secret monolith-env -n mono -o jsonpath='{.data.APP_REQUEST_TIMEOUT}' | base64 -d && echo
kubectl --context=<ctx> get secret monolith-env -n mono -o jsonpath='{.data.HTTP_WRITE_TIMEOUT}' | base64 -d && echo
kubectl --context=<ctx> get secret monolith-env -n mono -o jsonpath='{.data.LOGIN_MAX_CONCURRENCY}' | base64 -d && echo
kubectl --context=<ctx> get secret auth-service-secret -n msa -o jsonpath='{.data.LOGIN_ADMISSION_ENABLED}' | base64 -d && echo
kubectl --context=<ctx> get secret auth-service-secret -n msa -o jsonpath='{.data.LOGIN_MAX_CONCURRENCY}' | base64 -d && echo
kubectl --context=<ctx> get secret api-gateway-secret -n msa -o jsonpath='{.data.GRPC_CALL_TIMEOUT}' | base64 -d && echo
```

## Phase 8 — Measure Resource Baseline

Included in `experiment-bootstrap`. Manual:

```bash
VULTR_CONTEXT=benchmark make measure-resource-baseline    # sequential
VULTR_CONTEXT=monolith make measure-resource-baseline     # parallel
cat env/vultr-resource-baseline.env
```

Writes `env/vultr-resource-baseline.env` and `.json`. The renderer uses
`VULTR_APP_CPU_QUOTA` and `VULTR_APP_MEMORY_QUOTA` for both architectures.
Do not adjust one architecture without the other.

## Phase 9 — Render Manifests

Included in `experiment-bootstrap`. Manual: `make render-manifests`

Fails if baseline env is missing (unless smoke-only override). Patches Docker
Hub image refs, ResourceQuota ceilings, benchmark metadata, and removes stale
AWS/ECR metadata.

---

## Phase 10 — Deploy

**Full suite path (recommended):** do **not** run `deploy-workloads` manually.
`run-benchmark-suite` deploys each architecture phase internally.

**Manual smoke path (optional):**

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=<mode> ARCHITECTURE=monolith make verify-live-mode
```

The deploy script: validates secrets → scales down inactive arch → bootstraps
DBs → runs migrations → resets data → seeds → applies Kustomize overlay →
installs metrics-server (HPA) → waits for rollout → installs Datadog.

Switching fixed↔HPA is a redeploy event. Always redeploy and verify.

## Phase 11 — Run Benchmark

### Mental model

```text
manual smoke: deploy-workloads → verify-live-mode → run-benchmark-case
full suite:   run-benchmark-suite auto-deploys each architecture phase
```

For the full suite, do **not** run `deploy-workloads` first. The suite deploys
each phase internally using the fixed suite baseline and `IMAGE_TAG`.
For a single case, `run-benchmark-case` checks the requested architecture and
mode first: if the target is already live and ready, it skips deploy; otherwise
it deploys the target architecture before running the case.

Mechanism for `run-benchmark-case` in Vultr sequential mode:

1. Load `IMAGE_TAG` from the pinned env file if not passed explicitly.
2. Validate benchmark inputs such as `ARCHITECTURE`, `SCENARIO`,
   `TARGET_RPS`, `SCALING_MODE`, and `K6_PROFILE`.
3. Run benchmark preflight for S3 access and cluster auth.
4. Check whether the requested architecture is already valid for this run:
   deployment(s) must be ready, image tags must match, the opposite
   architecture must be scaled down, and the live scaling mode must match the
   request.
5. If those checks pass, deploy is skipped and the script proceeds to
   scenario-specific setup.
6. If those checks fail, the script calls `deploy-sequential-architecture.sh`
   to scale down the inactive architecture, run bootstrap/migration/reset/seed,
   apply the correct overlay, and wait for rollout.
7. After the architecture is ready, the script renders and submits the k6 job,
   waits for completion, then classifies the result from the S3 artifacts.

### Single case

```bash
ARCHITECTURE=monolith SCENARIO=login TARGET_RPS=100 RUN_ID=vultr-smoke \
  ATTEMPT=attempt-01 SCALING_MODE=fixed K6_PROFILE=smoke TEST_DURATION=1m \
  make run-benchmark-case
```

Auto-skips deploy if the target architecture is already live and ready.
If the target architecture is not live, not ready, or running a different
scaling mode than the request, `run-benchmark-case` deploys it first.

Common single-case examples:

```bash
# Quick smoke login on monolith. Deploy runs only if monolith is not already ready.
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-smoke-login \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
make run-benchmark-case

# Login smoke on microservices after pinning a new IMAGE_TAG. This usually
# redeploys first because the live image no longer matches the requested tag.
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=500 \
RUN_ID=vultr-seq-fixed-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=3m \
make run-benchmark-case

# HPA validation on microservices. If the cluster is still in fixed mode,
# `run-benchmark-case` redeploys the HPA overlay before running the case.
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=2500 \
RUN_ID=vultr-hpa-login-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
make run-benchmark-case
```

### Fixed suite

```bash
SCALING_MODE=fixed K6_PROFILE=steady TEST_DURATION=5m \
  EXPERIMENT_NAME=final-stable-v1 ATTEMPT=attempt-01 \
  INTER_CASE_DELAY=120 ARCHITECTURE_SWITCH_DELAY=300 \
  SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000" \
  make run-benchmark-suite
```

Example generated `RUN_ID` for the fixed suite above:

```text
vultr-sequential-fixed-final-stable-v1-670736c
```

### HPA architecture suite

```bash
ARCHITECTURE=microservices \
SCALING_MODE=hpa K6_PROFILE=hpa \
EXPERIMENT_NAME=final-hpa-v1 ATTEMPT=attempt-01 \
INTER_CASE_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-arch-suite
```

`K6_PROFILE=hpa` uses ramping-arrival-rate stages (~13 min/case).
`TEST_DURATION` is ignored for HPA.

### SCALING_MODE / K6_PROFILE pairing

| SCALING_MODE | K6_PROFILE | Notes |
|---|---|---|
| `fixed` | `steady` | Default if omitted. |
| `hpa` | `hpa` | Required. Rejects `steady`, `ramp`, `smoke`. |

### Suite behavior

Two architecture phases: phase 1 deploys first arch, runs all cases, waits
`ARCHITECTURE_SWITCH_DELAY`; phase 2 deploys second arch, runs all cases.

Default: `ARCHITECTURE_ORDER="monolith microservices"`. Override with spaces
(not commas): `ARCHITECTURE_ORDER="microservices monolith"`.

Mechanism for `run-benchmark-suite` in Vultr sequential mode:

1. Parse the matrix from `SCENARIO_RPS_MATRIX` or from `SCENARIOS` plus
   `RPS_LEVELS`.
2. Validate `SCALING_MODE`, `K6_PROFILE`, `INTER_CASE_DELAY`, and
   `ARCHITECTURE_SWITCH_DELAY`.
3. Run suite preflight and upload suite metadata.
   - For Vultr, these local S3 operations use the `aws-s3-writer` credentials
     from Terraform output by default.
   - Expired local `aws login` / SSO sessions should not block the suite unless
     the writer credentials themselves are missing or invalid.
4. Iterate through each architecture in `ARCHITECTURE_ORDER`.
5. For each architecture phase:
   - deploy the architecture if there are still pending cases for it,
   - skip deploy if all cases for that phase already exist in S3,
   - run scenario-specific reset/seed/setup only when needed.
6. For each `scenario + RPS` pair, call the sequential single-case runner.
7. Sleep `INTER_CASE_DELAY` between cases.
8. Sleep `ARCHITECTURE_SWITCH_DELAY` before switching to the next architecture.
9. Upload suite summary to S3 after all phases finish.

Mechanism for `run-benchmark-arch-suite` in Vultr sequential mode:

1. Parse the matrix from `SCENARIO_RPS_MATRIX` or from `SCENARIOS` plus
   `RPS_LEVELS`.
2. Validate `ARCHITECTURE`, `SCALING_MODE`, `K6_PROFILE`, and
   `INTER_CASE_DELAY`.
3. Reject `ARCHITECTURE=monolith SCALING_MODE=hpa` explicitly in the active
   benchmark model.
4. Run suite preflight and upload `_arch_suite/manifest.json`.
5. Deploy or reuse the selected architecture once for the whole run.
6. For each `scenario + RPS` pair, call the sequential single-case runner.
7. Reuse per-scenario setup for data-stable workloads and keep per-case setup
   for mutating workloads.
8. Sleep `INTER_CASE_DELAY` between cases.
9. Upload `_arch_suite/summary.json` after all cases finish.

For the thesis-methodology version of this flow, including Mermaid diagrams for
the sequential suite lifecycle, data setup decision, and inter-case gap
components, see
[`docs/diagrams/vultr-sequential-suite-lifecycle.md`](../diagrams/vultr-sequential-suite-lifecycle.md).


Common suite examples:

```bash
# Narrow login-only smoke across both architectures.
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
EXPERIMENT_NAME=smoke-login-admission \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500" \
make run-benchmark-suite

# Standard fixed suite with multiple scenarios.
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
EXPERIMENT_NAME=final-stable-v1 \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000" \
make run-benchmark-suite

# Standard HPA single-architecture suite. TEST_DURATION is ignored for K6_PROFILE=hpa.
ARCHITECTURE=microservices \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
EXPERIMENT_NAME=final-hpa-v1 \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-arch-suite
```

Important distinction:

- In **Vultr sequential**, `run-benchmark-case` can auto-deploy one target
  architecture when needed.
- In **Vultr sequential**, `run-benchmark-suite` manages deploys internally per
  architecture phase.
- In **Vultr sequential**, `run-benchmark-arch-suite` manages one architecture
  only and reuses the sequential single-case runner across its case matrix.
- In **parallel mode**, the benchmark runners assume both architectures are
  already deployed; use `deploy-workloads` and `verify-live-mode` first.

Data setup in the sequential suite depends on whether the workload mutates the
benchmark dataset across RPS levels.

- Data-stable scenarios reuse one setup across pending RPS cases in the same
  architecture phase.
- Mutating scenarios still reset before every pending RPS case.
- Enrichment preparation is reused only when the workload itself is data-stable.

| Scenario | Class | Setup | Suite setup reuse |
|---|---|---|---|
| `login` | readonly | reset + seed | once before the first pending RPS level |
| `create-transaction` | mutating | reset + seed | before every pending RPS level |
| `sync-items` | mutating | reset + seed | before every pending RPS level |
| `enriched-transactions` | enrichment | reset + seed + prepare enrichment | once before the first pending RPS level |
| `concurrent-mixed-workload` | enrichment | reset + seed + prepare enrichment | before every pending RPS level |
| `mixed-workload` | enrichment | reset + seed + prepare enrichment | before every pending RPS level |

Direct single-case sequential runs remain conservative: if the target
architecture is already deployed, the runner still performs scenario data setup
before the k6 job unless the suite explicitly tells it to reuse a setup that it
already performed.

Resume: checks S3 for existing `result-status.json`; completed cases are
skipped. To rerun from scratch, use new `RUN_ID` or `ATTEMPT`.

Default `RUN_ID` behavior for suite runs:

- manual `RUN_ID` always wins when set explicitly;
- when `RUN_ID` is blank and `EXPERIMENT_NAME` is set, the suite generates a
  stable default `RUN_ID` as
  `vultr-sequential-{mode}-{experiment_name}-{image_tag}`;
- when both `RUN_ID` and `EXPERIMENT_NAME` are blank, the suite falls back to
  `vultr-sequential-{mode}-{yyyymmdd}-{HHMM}`;
- if an auto-named run is interrupted, reuse the printed `RUN_ID` explicitly on
  the rerun command so the resume targets the same S3 run folder.

Recommended operator workflow:

1. Start a new measured suite with `EXPERIMENT_NAME` and leave `RUN_ID` blank.
2. Copy the printed `RUN_ID` from the suite header.
3. If the run completes, keep using the generated folder for verification and
   reporting.
4. If the run is interrupted:
   - rerun with the same `EXPERIMENT_NAME` and unchanged `IMAGE_TAG` when you
     want the default generated `RUN_ID` to stay the same; or
   - rerun with the printed `RUN_ID` explicitly when you want the resume target
     to be unambiguous regardless of local env changes.

Resume example after interruption:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
RUN_ID=vultr-sequential-fixed-final-stable-v1-670736c \
ATTEMPT=attempt-01 \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:1000,2500,5000,7500,10000;create-transaction:1000,2500,5000,7500,10000;enriched-transactions:1000,2500,5000,7500,10000" \
make run-benchmark-suite
```

ETA: `est_case`, `est_scenario`, `est_suite`. Both the sequential suite (`run-benchmark-suite`) and the single-architecture suite (`run-benchmark-arch-suite`) compute and log ETA information using these parameters.

- `SEQUENTIAL_CASE_OVERHEAD_SECONDS=180` is the full-case overhead buffer used
  when a case still performs its own reset/seed/setup.
- `SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS=120` is the lighter overhead buffer
  used when the sequential suite is reusing one prepared dataset across pending
  RPS levels for a data-stable scenario.
- `SEQUENTIAL_RETRY_BUFFER_SECONDS=0` is the additional buffer allocated for retries/errors.

### SCENARIO_RPS_MATRIX

```bash
SCENARIO_RPS_MATRIX="login:100,200;create-transaction:100,200"
```

### Inter-case delay

| Mode | `INTER_CASE_DELAY` |
|---|---|
| Fixed | `120` seconds |
| HPA | `300` seconds |

### Auto-destroy

```bash
AUTO_DESTROY_CONFIRMED=true RUN_ID=rq1-fixed-vultr SCALING_MODE=fixed make run-benchmark-suite
```

### Command cheat sheet

| Goal | Command | Deploy first? |
|---|---|---|
| Smoke check one arch | `deploy-workloads` → `verify-live-mode` | Yes |
| Single smoke case | `run-benchmark-case` | Recommended |
| Fixed full matrix | `SCALING_MODE=fixed make run-benchmark-suite` | No |
| HPA full matrix on one architecture | `ARCHITECTURE=microservices SCALING_MODE=hpa make run-benchmark-arch-suite` | No |
| MSA first | add `ARCHITECTURE_ORDER="microservices monolith"` | No |

---

## Phase 12 — Verify S3 Results

```bash
aws s3 ls "s3://$S3_BUCKET/experiments/<run_id>/" --recursive
```

Per attempt: `summary.json`, `raw.json.gz`, `stdout.log`, `metadata.json`,
`k6-options.json`, `thresholds.json`, `result-status.json`,
`datadog-time-window.json` (when Datadog enabled). `status-summary.json` is a
derived analysis artifact and may be generated later from `raw.json.gz` during
offline report processing.

`summary.json` is the original aggregate k6 summary. Use
`status-summary.json` when overload handling makes status-aware interpretation
important, for example to separate latency percentiles for successful `2xx`
responses from bounded overload responses such as `503`. The file also records
status-family breakdown and successful RPS achievement against the configured
target RPS.

Metadata check:

```bash
aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/<arch>/<scenario>/<rps>rps/<attempt>/metadata.json" -
```

Required fields: `provider=vultr`, `execution_mode=parallel|sequential`,
`scaling_mode=fixed|hpa`, `terraform_stack=vultr`, `image_tag=<expected>`,
`app_resource_quota=<measured>`.

Expected quota: `7800m CPU / 15360Mi memory`. Per microservice fixed:
`1950m CPU / 3840Mi memory`. HPA: `975m CPU / 1920Mi memory` per pod.

Suite summary: `aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/_suite/summary.json" - | jq .`

Do not destroy until all expected files are present.

## Phase 13 — Destroy

```bash
S3_BENCHMARK_DATA_VERIFIED=true make experiment-destroy-confirmed
```

After all experiments complete:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make shared-destroy-confirmed
```

Check Vultr dashboard for leftover: VKE clusters, compute instances, firewall
groups, legacy VPC networks, SSH keys.

---

## Troubleshooting

Order: read first failing stderr → confirm mode and context → confirm
`IMAGE_TAG`/`DOCKERHUB_NAMESPACE` → check Terraform outputs → check pod events
→ verify S3 before destroy.

Quick status:

```bash
make show-image-tag && make preflight-check
terraform -chdir=infra/terraform/vultr output
kubectl config get-contexts && kubectl --context=<ctx> get pods -A
```

| Symptom | Fix |
|---|---|
| `DOCKERHUB_NAMESPACE` empty | `make preflight-check` (auto-loads env) |
| Image push/pull fails | `make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"`, verify with manifest inspect loop |
| Terraform fails: `VULTR_API_KEY` missing | fill `env/vultr.env`, rerun preflight + render |
| Terraform fails: `OPERATOR_CIDRS` missing | set `/32` IP, rerun render |
| Terraform fails: quota | use sequential or request Vultr limit increase |
| Context setup fails | `terraform output` → `make setup-contexts` |
| Secret creation fails | `make env-init-app && make env-init-vultr`, then `make create-secrets` |
| Baseline missing | `VULTR_CONTEXT=<ctx> make measure-resource-baseline` |
| `ImagePullBackOff` | verify tag, redeploy with correct `IMAGE_TAG` |
| `CreateContainerConfigError` | check secret names and env keys |
| Migration/seed job failed | inspect job logs, fix, redeploy |
| Pods pending | check node labels, taints, resource requests, quota |
| App can't reach PostgreSQL | same legacy VPC? firewall allows 5432? check `terraform output` |
| HPA metrics unknown | `kubectl get apiservice v1beta1.metrics.k8s.io`, check metrics-server |
| k6 S3 upload fails | verify `k6-runner-secret` key matches `terraform -chdir=infra/terraform/aws-s3-writer output` |
| `INVALID` result | fix root cause, rerun with new `ATTEMPT` |
| `TIMEOUT` result | inspect job logs, pod readiness, service endpoint |
| ResourceQuota deadlock (HPA→fixed) | delete HPA, scale to 0, delete migration jobs, redeploy |
| Destroy blocked | verify S3, then `S3_BENCHMARK_DATA_VERIFIED=true make experiment-destroy-confirmed` |
| Parallel quota fail | destroy partial, switch to `EXECUTION_MODE=sequential` |

---

## K8s Monitoring & Debugging Commands

All commands use `--context=<context>`: `benchmark` (sequential), `monolith`/`msa`
(parallel). Replace `<ctx>` accordingly.

```bash
# Cluster overview
kubectl --context=<ctx> get nodes -o wide
kubectl --context=<ctx> get pods,svc,hpa,resourcequota -n mono
kubectl --context=<ctx> get pods,svc,hpa,resourcequota -n msa
kubectl --context=<ctx> get jobs -n benchmark
kubectl --context=<ctx> get events -A --sort-by=.metadata.creationTimestamp
kubectl --context=<ctx> top nodes && kubectl --context=<ctx> top pods -A

# Deployment status
kubectl --context=<ctx> rollout status deployment/monolith -n mono --timeout=300s
kubectl --context=<ctx> rollout status deployment/api-gateway -n msa --timeout=300s
kubectl --context=<ctx> rollout status deployment/auth-service -n msa --timeout=300s
kubectl --context=<ctx> rollout status deployment/item-service -n msa --timeout=300s
kubectl --context=<ctx> rollout status deployment/transaction-service -n msa --timeout=300s

# Logs
kubectl --context=<ctx> logs deploy/monolith -n mono --tail=100
kubectl --context=<ctx> logs deploy/api-gateway -n msa --tail=100
kubectl --context=<ctx> logs deploy/auth-service -n msa --tail=100
kubectl --context=<ctx> logs deploy/item-service -n msa --tail=100
kubectl --context=<ctx> logs deploy/transaction-service -n msa --tail=100
kubectl --context=<ctx> logs deploy/monolith -n mono --previous --tail=100  # after crash

# Restart
kubectl --context=<ctx> rollout restart deployment/monolith -n mono
kubectl --context=<ctx> rollout restart deployment/api-gateway -n msa

# Jobs
kubectl --context=<ctx> logs job/db-bootstrap-job -n benchmark
kubectl --context=<ctx> logs job/monolith-migration-job -n mono
kubectl --context=<ctx> logs job/seed-monolith-benchmark-data-job -n mono
kubectl --context=<ctx> logs job/k6-benchmark-monolith -n benchmark
kubectl --context=<ctx> logs job/auth-migration-job -n msa
kubectl --context=<ctx> logs job/item-migration-job -n msa
kubectl --context=<ctx> logs job/transaction-migration-job -n msa
kubectl --context=<ctx> logs job/k6-benchmark-microservices -n benchmark

# HPA / ResourceQuota
kubectl --context=<ctx> get hpa -n mono && kubectl --context=<ctx> get hpa -n msa
kubectl --context=<ctx> describe hpa monolith -n mono
kubectl --context=<ctx> get resourcequota -n mono && kubectl --context=<ctx> get resourcequota -n msa

# Secrets
kubectl --context=<ctx> get secrets -n mono -n msa -n benchmark

# Image verification
kubectl --context=<ctx> get pods -n mono -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[*].image}{"\n"}{end}'
kubectl --context=<ctx> get pods -n msa -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[*].image}{"\n"}{end}'

# Datadog
kubectl --context=<ctx> get pods -n datadog && kubectl --context=<ctx> logs -n datadog -l app=datadog --tail=50

# Live benchmark
kubectl --context=<ctx> logs job/k6-benchmark-monolith -n benchmark -f
kubectl --context=<ctx> get deployment -n mono && kubectl --context=<ctx> get deployment -n msa

# PostgreSQL test
kubectl --context=<ctx> run pg-test --image=postgres:18 --rm -it --restart=Never \
  -- psql "postgres://postgres_admin:<pw>@<ip>:5432/bootstrap?sslmode=require" -c '\l'

# Vultr CLI
vultr-cli kubernetes list && vultr-cli instance list
```

---

## Quick Reference

| Command | Purpose |
|---|---|
| `make env-init PLATFORM=vultr EXECUTION_MODE=<mode>` | Initialize session |
| `make profile-show` | Verify profile |
| `make docker-build-all IMAGE_TAG=<tag>` | Build images |
| `make dockerhub-push-all IMAGE_TAG=<tag>` | Push to Docker Hub |
| `make pin-image-tag IMAGE_TAG=<tag>` | Pin tag |
| `make render-tfvars` | Render Terraform inputs |
| `make preflight-check` | Validate prerequisites |
| `make shared-plan` / `make shared-apply` | Shared Terraform |
| `make experiment-bootstrap` | Full bootstrap |
| `make experiment-plan` / `make experiment-apply` | Experiment Terraform |
| `make setup-contexts` | Configure kubectl |
| `make create-secrets` | Create K8s secrets |
| `make measure-resource-baseline` | Measure node capacity |
| `make render-manifests` | Render Kustomize manifests |
| `make deploy-workloads` | Deploy one arch (smoke) |
| `make verify-live-mode` | Verify live mode |
| `make run-benchmark-case` | Single case |
| `make run-benchmark-suite` | Full suite |
| `make experiment-destroy-confirmed` | Destroy experiment |
| `make shared-destroy-confirmed` | Destroy shared |

### Suite arguments

| Argument | Example | Purpose |
|---|---|---|
| `SCALING_MODE` | `fixed`/`hpa` | Deployment overlay. |
| `K6_PROFILE` | `steady`/`hpa` | k6 profile. HPA must use `hpa`. |
| `TEST_DURATION` | `5m` | Fixed duration. Ignored for HPA. |
| `EXPERIMENT_NAME` | `final-stable-v1` | Human-readable experiment label used in default generated `RUN_ID`. |
| `RUN_ID` | `rq1-fixed-vultr` | S3 run folder. |
| `ATTEMPT` | `attempt-01` | Attempt folder. |
| `ARCHITECTURE_ORDER` | `"microservices monolith"` | Override order (spaces). |
| `INTER_CASE_DELAY` | `120`/`300` | Pause between cases. |
| `ARCHITECTURE_SWITCH_DELAY` | `300` | Pause between phases. |
| `SCENARIO_RPS_MATRIX` | `login:100,200` | Per-scenario RPS. |
| `AUTO_DESTROY_CONFIRMED` | `true` | Auto-destroy after suite. |

## Avoid

- `ARCHITECTURE_ORDER="monolith,microservices"` (commas) — use spaces.
- Switching fixed↔HPA in benchmark command without redeploying.
- Destroying before S3 results are verified.
- Rebuilding a different image into the same tag.
- Old stack names (`vultr-shared`, `vultr-sequential`, `vultr-parallel`) — the
  stack is `infra/terraform/vultr` with `execution_mode`.
