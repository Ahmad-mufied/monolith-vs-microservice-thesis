# Vultr Sequential Final Experiment Guide

## Purpose

This guide is the final operator path for running the thesis benchmark on the
Vultr sequential setup.

Use this document when the final experiment uses:

```text
PLATFORM=vultr
EXECUTION_MODE=sequential
Kubernetes context=benchmark
Terraform experiment stack=infra/terraform/vultr-sequential
Image registry=Docker Hub
Result storage=AWS S3
```

The primary path uses the generic operator workflow. Start with the shared
infrastructure and cluster setup:

```bash
make env-init PLATFORM=vultr EXECUTION_MODE=sequential
make render-tfvars
make shared-plan
make shared-apply
make experiment-plan
make experiment-apply
make setup-contexts
make create-secrets
make measure-resource-baseline
```

Then choose one of these benchmark execution paths:

```bash
# Optional smoke validation for one architecture.
ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith make verify-live-mode

# Final matrix. The sequential suite deploys each architecture phase itself.
SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" ARCHITECTURE_ORDER="monolith microservices" make run-benchmark-suite
```

Provider-specific `vultr-*` commands remain useful for debugging individual
steps, but the final experiment should prefer the generic workflow so the same
mental model works across EKS, Hetzner, and Vultr.

## Mental Model

```text
make env-init             = choose provider and execution mode
EXECUTION_MODE=sequential = test monolith and microservices one after another
SCALING_MODE=fixed|hpa    = choose the active Kubernetes deployment shape
make deploy-workloads     = apply the selected architecture and scaling mode
make run-benchmark-case   = run one scenario at one target RPS
make run-benchmark-suite  = run the full scenario/RPS matrix
```

Sequential mode does not mean HPA. Fixed/HPA is a separate deployment state.

Use `deploy-workloads` for manual smoke validation. Use `run-benchmark-suite`
for the final matrix.

The important distinction:

```text
manual smoke path:
  deploy-workloads
  -> verify-live-mode
  -> run-benchmark-case

full suite path:
  run-benchmark-suite
  -> auto-deploy architecture phase 1
  -> run all cases for phase 1
  -> wait ARCHITECTURE_SWITCH_DELAY
  -> auto-deploy architecture phase 2
  -> run all cases for phase 2
```

So, for a full sequential suite, you do **not** need to run
`make deploy-workloads` immediately before `make run-benchmark-suite`.
The suite deploys each architecture phase internally using the suite-level
`SCALING_MODE`, `IMAGE_TAG`, and `ARCHITECTURE_ORDER`.

However, `run-benchmark-suite` only deploys what you ask it to deploy. If you
want HPA, pass `SCALING_MODE=hpa`. If you want fixed, pass
`SCALING_MODE=fixed`. Do not rely on whatever was manually deployed earlier.

## Sequential Suite Behavior

`make run-benchmark-suite` uses `scripts/run-benchmark-suite-sequential.sh`
when the operator profile contains `EXECUTION_MODE=sequential`.

In sequential mode, one suite has two architecture phases:

```text
phase 1: deploy selected architecture, reset/seed as needed, run all cases
phase 2: wait ARCHITECTURE_SWITCH_DELAY, deploy the other architecture, run all cases
```

The architecture order is controlled by `ARCHITECTURE_ORDER`.

Use monolith first:

```bash
ARCHITECTURE_ORDER="monolith microservices"
```

Use microservices first:

```bash
ARCHITECTURE_ORDER="microservices monolith"
```

Rules:

- `ARCHITECTURE_ORDER` must contain exactly `monolith` and `microservices`.
- Use spaces, not commas.
- The first value runs first and the second value runs after
  `ARCHITECTURE_SWITCH_DELAY`.
- The suite redeploys each architecture at the start of its phase using
  `SCALING_MODE`, `IMAGE_TAG`, and `DOCKERHUB_NAMESPACE` from the suite
  command/operator env.
- The deploy step scales down the inactive architecture, so only one
  architecture is active during each phase.

Fixed versus HPA is controlled by `SCALING_MODE`.

Use fixed mode:

```bash
SCALING_MODE=fixed K6_PROFILE=steady
```

Use HPA mode:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa
```

Safety rules enforced by the script:

- `SCALING_MODE=fixed` must not use `K6_PROFILE=hpa`.
- `SCALING_MODE=hpa` must use `K6_PROFILE=hpa` for the standard autoscaling
  experiment.
- If `K6_PROFILE` is omitted, fixed defaults to `steady` and HPA defaults to
  `hpa`.

For each architecture phase, the suite loops through the scenario/RPS matrix.
Before mutating or data-dependent scenarios, it resets and reseeds the active
architecture. For enriched and mixed workloads, it also prepares enrichment
benchmark data before running the case.

Resume behavior:

- Before running a case, the suite checks whether
  `result-status.json` already exists in S3 for that exact
  `run_id/architecture/scenario/rps/attempt`.
- Existing completed cases are skipped and included in the suite summary.
- To rerun the same matrix from scratch, use a new `RUN_ID` or a new
  `ATTEMPT`.

## Command Selection Cheat Sheet

Use these commands when you want to verify a single architecture manually:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith make verify-live-mode
ARCHITECTURE=monolith SCENARIO=login TARGET_RPS=100 RUN_ID=smoke ATTEMPT=attempt-01 SCALING_MODE=fixed K6_PROFILE=smoke IMAGE_TAG="$IMAGE_TAG" make run-benchmark-case
```

Use this when you want the suite to manage deployment automatically:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
IMAGE_TAG="$IMAGE_TAG" \
ARCHITECTURE_ORDER="monolith microservices" \
SCENARIO_RPS_MATRIX="login:100,200;create-transaction:100,200" \
make run-benchmark-suite
```

Do not combine the two mental models unnecessarily. If the goal is the final
suite, the suite is the deployment orchestrator. If the goal is a smoke check,
you are the deployment orchestrator.

Quick decision table:

| Goal | Command path | Deploy command needed first? |
|---|---|---|
| Check image pull, secrets, migration, seed for one architecture | `deploy-workloads -> verify-live-mode` | Yes |
| Run one smoke case after manual deploy | `run-benchmark-case` | Yes, recommended |
| Run fixed full matrix | `SCALING_MODE=fixed make run-benchmark-suite` | No |
| Run HPA full matrix | `SCALING_MODE=hpa make run-benchmark-suite` | No |
| Change order to MSA first | `ARCHITECTURE_ORDER="microservices monolith" make run-benchmark-suite` | No |
| Switch fixed suite to HPA suite | run a new suite with `SCALING_MODE=hpa` | No manual deploy required |

## 1. Initialize Operator Config

Run once at the start of the operator session:

```bash
make env-init PLATFORM=vultr EXECUTION_MODE=sequential
make profile-show
```

Then edit `env/vultr.env` if placeholders remain:

```bash
VULTR_API_KEY=...
DOCKERHUB_NAMESPACE=...
S3_BUCKET=...
AWS_REGION=ap-southeast-1
OPERATOR_CIDRS=<your-public-ip>/32
OPERATOR_SSH_PUBLIC_KEY='ssh-ed25519 ...'
```

What this does:

- `env-init` creates provider-neutral app env files, Vultr env, and
  `env/operator-profile.env`.
- `profile-show` confirms the current repo session points to
  `PLATFORM=vultr` and `EXECUTION_MODE=sequential`.

## 2. Choose, Push, and Pin One Image Tag

Choose one image tag for the whole experiment:

```bash
export IMAGE_TAG=thesis-vultr-20260606
```

Build and push all required Docker Hub images:

```bash
make docker-build-all IMAGE_TAG="$IMAGE_TAG"
make dockerhub-push-all IMAGE_TAG="$IMAGE_TAG"
```

Pin the tag so later commands have a stable default:

```bash
make pin-image-tag IMAGE_TAG="$IMAGE_TAG"
make show-image-tag
```

Final experiment rules:

- Do not rebuild a different commit into the same tag.
- If code changes, create a new image tag.
- Still pass `IMAGE_TAG="$IMAGE_TAG"` on deploy and benchmark commands so the
  execution log is explicit.

## 3. Render Terraform Inputs

Render Vultr `terraform.tfvars` files from `env/vultr.env`:

```bash
make render-tfvars
```

For Vultr, this renders:

```text
infra/terraform/vultr-shared/terraform.tfvars
infra/terraform/vultr-parallel/terraform.tfvars
infra/terraform/vultr-sequential/terraform.tfvars
```

Do not commit generated `terraform.tfvars` files.

## 4. Run Preflight

Run preflight before creating expensive resources:

```bash
IMAGE_TAG="$IMAGE_TAG" make preflight-check
```

For Vultr, this checks:

- `VULTR_API_KEY`
- `DOCKERHUB_NAMESPACE`
- AWS S3 writer credentials for k6 upload
- S3 bucket access
- required Docker Hub images for the selected `IMAGE_TAG`
- whether the Vultr resource baseline has already been measured

The resource-baseline warning is expected before the cluster exists.

## 5. Apply Terraform

Apply shared Vultr resources:

```bash
make shared-plan
make shared-apply
```

Apply the sequential experiment stack:

```bash
make experiment-plan
make experiment-apply
```

For `PLATFORM=vultr` and `EXECUTION_MODE=sequential`,
`experiment-apply` provisions:

- one VKE cluster for context `benchmark`,
- app node pool,
- testing/k6 node pool,
- one PostgreSQL VM,
- private network integration.

The Vultr experiment apply path also ensures the AWS S3 writer stack exists for
k6 uploads.

## 6. Setup Kubernetes Context

Create the local kubeconfig context:

```bash
make setup-contexts
kubectl --context=benchmark get nodes -o wide
```

Expected node roles:

```text
node-group=app      for application workloads
node-group=testing  for k6 runner jobs
```

## 7. Create Kubernetes Secrets

Create application and benchmark secrets:

```bash
make create-secrets
```

For Vultr sequential, this creates secrets in context `benchmark` for:

```text
mono
msa
benchmark
```

The secret generation combines:

- `env/*.app.env`,
- `env/vultr.env`,
- private PostgreSQL IP from Terraform output,
- AWS S3 writer credentials for k6 upload.

## 8. Measure Resource Baseline

Vultr must measure live allocatable app-node capacity before rendering final
manifests:

```bash
VULTR_CONTEXT=benchmark make measure-resource-baseline
cat env/vultr-resource-baseline.env
```

Generated files:

```text
env/vultr-resource-baseline.env
env/vultr-resource-baseline.json
```

The Vultr renderer uses these values for ResourceQuota and resource allocation
so monolith and microservices use the same measured architecture ceiling.

## 9. Render Manifests

Render and validate manifests with the final image tag:

```bash
IMAGE_TAG="$IMAGE_TAG" make render-manifests
```

For Vultr, rendered images use:

```text
docker.io/<DOCKERHUB_NAMESPACE>/<repo>:<IMAGE_TAG>
```

## 10. Smoke Test Fixed Mode

Deploy fixed monolith:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=monolith make verify-live-mode
```

Run a monolith smoke case:

```bash
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-seq-fixed-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
IMAGE_TAG="$IMAGE_TAG" \
make run-benchmark-case
```

Deploy fixed microservices:

```bash
ARCHITECTURE=microservices SCALING_MODE=fixed IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=fixed EXECUTION_MODE=sequential ARCHITECTURE=microservices make verify-live-mode
```

Run a microservices smoke case:

```bash
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-seq-fixed-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
IMAGE_TAG="$IMAGE_TAG" \
make run-benchmark-case
```

## 11. Run Fixed Suite

Run the final fixed suite with monolith first:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
EXPERIMENT_NAME=rq1-fixed-vultr-sequential \
ARCHITECTURE_ORDER="monolith microservices" \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
IMAGE_TAG="$IMAGE_TAG" \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500;concurrent-mixed-workload:100,200,300,400,500" \
make run-benchmark-suite
```

Run the same fixed suite with microservices first:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
TEST_DURATION=5m \
EXPERIMENT_NAME=rq1-fixed-vultr-sequential-msa-first \
ARCHITECTURE_ORDER="microservices monolith" \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
IMAGE_TAG="$IMAGE_TAG" \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500;concurrent-mixed-workload:100,200,300,400,500" \
make run-benchmark-suite
```

Notes:

- `ARCHITECTURE_ORDER` uses spaces, not commas.
- `ARCHITECTURE_ORDER="monolith microservices"` means monolith runs first.
- `ARCHITECTURE_ORDER="microservices monolith"` means microservices runs
  first.
- Sequential suite redeploys each architecture at phase start with
  `SCALING_MODE=fixed`.
- The suite uploads `_suite/manifest.json` and `_suite/summary.json` to S3.

## 12. Switch to HPA

Switching from fixed to HPA is a redeploy event.

Deploy HPA monolith:

```bash
ARCHITECTURE=monolith SCALING_MODE=hpa IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=hpa EXECUTION_MODE=sequential ARCHITECTURE=monolith make verify-live-mode
```

Deploy HPA microservices:

```bash
ARCHITECTURE=microservices SCALING_MODE=hpa IMAGE_TAG="$IMAGE_TAG" make deploy-workloads
SCALING_MODE=hpa EXECUTION_MODE=sequential ARCHITECTURE=microservices make verify-live-mode
```

## 13. Smoke Test HPA

Run a monolith HPA smoke case:

```bash
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-seq-hpa-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=1m \
IMAGE_TAG="$IMAGE_TAG" \
make run-benchmark-case
```

Run a microservices HPA smoke case:

```bash
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=vultr-seq-hpa-smoke \
ATTEMPT=attempt-01 \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=1m \
IMAGE_TAG="$IMAGE_TAG" \
make run-benchmark-case
```

## 14. Run HPA Suite

Run the final HPA suite with monolith first:

```bash
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=5m \
EXPERIMENT_NAME=rq2-hpa-vultr-sequential \
ARCHITECTURE_ORDER="monolith microservices" \
INTER_CASE_DELAY=300 \
ARCHITECTURE_SWITCH_DELAY=300 \
IMAGE_TAG="$IMAGE_TAG" \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-suite
```

Run the same HPA suite with microservices first:

```bash
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=5m \
EXPERIMENT_NAME=rq2-hpa-vultr-sequential-msa-first \
ARCHITECTURE_ORDER="microservices monolith" \
INTER_CASE_DELAY=300 \
ARCHITECTURE_SWITCH_DELAY=300 \
IMAGE_TAG="$IMAGE_TAG" \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-suite
```

Notes:

- HPA suite redeploys each architecture at phase start with
  `SCALING_MODE=hpa`.
- Keep `K6_PROFILE=hpa`; the script rejects the standard HPA run if it uses
  `steady`, `ramp`, or `smoke`.
- If the first HPA run warms shared cluster components, run the opposite
  `ARCHITECTURE_ORDER` as a second suite and compare both orderings during
  analysis.

## 15. Verify S3 Results

Before destroy, verify the uploaded benchmark artifacts:

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
datadog-time-window.json
```

Inspect one metadata file:

```bash
aws s3 cp "s3://$S3_BUCKET/experiments/<run_id>/<architecture>/<scenario>/<rps>rps/<attempt>/metadata.json" -
```

Expected metadata:

```text
provider=vultr
execution_mode=sequential
terraform_stack=vultr-sequential
scaling_mode=fixed or hpa
image_tag=<IMAGE_TAG final>
app_resource_quota=<measured Vultr quota>
```

## 16. Destroy Guarded

Destroy only after S3 results are verified:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make experiment-destroy-confirmed
```

If all experiments are complete and no other stack uses shared Vultr
network/firewall resources:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make shared-destroy-confirmed
```

## Avoid

- Do not use `ARCHITECTURE_ORDER="monolith,microservices"`.
- Do not switch fixed to HPA only in the benchmark command without redeploying.
- Do not assume `ARCHITECTURE_ORDER` changes fixed versus HPA; it only changes
  which architecture runs first.
- Do not destroy before S3 results are verified.
- Do not rebuild a different image into the same tag.
- Do not use the EKS runbook as the primary guide for the Vultr final
  experiment.
