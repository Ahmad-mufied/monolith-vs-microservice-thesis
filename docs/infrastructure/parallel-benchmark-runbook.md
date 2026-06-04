# Parallel Benchmark Runbook

## 1. Purpose

Step-by-step operational guide for running the benchmark experiment on two
isolated EKS clusters simultaneously.

This runbook covers the full experiment lifecycle from infrastructure
provisioning to result verification and teardown.

For the quota-constrained single-cluster AWS alternative, use
`docs/infrastructure/sequential-benchmark-runbook.md`. For Vultr VKE parallel
or sequential execution, use `docs/infrastructure/vultr-vke-runbook.md`. The
AWS parallel workflow in this document remains unchanged and still uses
`monolith` and `msa` contexts.

---

## 2. Prerequisites

```text
- Both EKS clusters provisioned (see docs/infrastructure/terraform-runbook.md)
- kubectl contexts configured: monolith, msa
- Kubernetes Secrets created in both clusters
- ECR images built and pushed (`make ecr-push-all`)
- Datadog installed on both clusters
- S3 bucket available
```

For Vultr, the equivalent prerequisites are documented in
`docs/infrastructure/vultr-vke-runbook.md`: VKE clusters, Vultr PostgreSQL VMs,
Docker Hub public images, AWS S3 credentials for k6 uploads, and
measurement-derived resource baseline.

Before any long benchmark run, refresh the AWS session you actually use for the
experiment, then run the benchmark preflight:

```bash
aws login
make benchmark-preflight-check
```

The suite and parallel runners now execute the same preflight automatically
before submission and fail fast if AWS STS, S3 access, or either EKS context is
already invalid.

---

## 3. Experiment Lifecycle Overview

```text
build/push images
    ↓
render EKS manifests with IMAGE_TAG
    ↓
terraform apply (shared + experiment)
    ↓
configure kubectl contexts
    ↓
create Kubernetes Secrets in both clusters
    ↓
deploy applications
    ↓
install Datadog on both clusters
    ↓
for each scenario:
    reset data
    seed data
    [prepare enrichment data while app workloads remain scaled down if enriched-transactions]
    restore rendered app workloads
    run parallel k6 jobs
    verify S3 results
    ↓
aws login
    ↓
make terraform-auth-check
    ↓
make eks-destroy-confirmed (after all results verified in S3)
```

---

## 4. Scaling Mode Selection

Choose scaling mode before deploying:

| Goal | Scaling mode | K6_PROFILE |
|---|---|---|
| RQ1 clean comparison | `fixed` | `steady` |
| RQ2 + HPA behavior | `hpa` | `hpa` |

Deploy with the selected mode:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)

# Fixed replica (default), per cluster
SCALING_MODE=fixed make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
SCALING_MODE=fixed make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together in fixed mode:

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG
```

HPA mode, per cluster:

```bash
# metrics-server is installed automatically by the deploy scripts in HPA mode
# default installer pins a metrics-server release and keeps kubelet TLS verification enabled
SCALING_MODE=hpa make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
SCALING_MODE=hpa make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together in HPA mode:

```bash
make eks-deploy-all-hpa IMAGE_TAG=$IMAGE_TAG
```

The source manifests in the repository stay unchanged. Each deploy or benchmark
run now renders runtime-specific EKS manifests into a temporary directory and
applies those rendered files.

Important rules:

- changing `SCALING_MODE` in `make run-benchmark-parallel` does **not** switch
  the live application manifests
- every `fixed <-> hpa` transition must be handled as a fresh redeploy event
- when `SCALING_MODE=hpa`, `K6_PROFILE` auto-defaults to `hpa` and
  `TEST_DURATION` is **ignored** by the k6 executor — the actual run duration
  is controlled by HPA stage env vars (default: 13 minutes per case). See
  §4.1 below.

Verify the live mode after redeploy:

```bash
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

Expected checks:

- fixed mode:
  - no HPA objects in `mono` or `msa`
  - monolith deployment at `2`
  - each MSA deployment at `1`
- HPA mode:
  - HPA objects present
  - baseline deployments typically start at `1` and scale during load

### 4.1 HPA Duration Behavior

When `SCALING_MODE=hpa`, the suite uses `K6_PROFILE=hpa` which applies a
`ramping-arrival-rate` executor. This executor **ignores `TEST_DURATION`**
entirely. The actual k6 run duration per case is:

```text
HPA_RAMP_UP_1  = 2m   (ramp to 25% TARGET_RPS)
HPA_RAMP_UP_2  = 2m   (ramp to 50% TARGET_RPS)
HPA_RAMP_UP_3  = 3m   (ramp to 100% TARGET_RPS)
HPA_HOLD       = 5m   (hold at 100% TARGET_RPS)
HPA_RAMP_DOWN  = 1m   (ramp to 0)
─────────────────────
Total          = 13 minutes per case
```

This means `TEST_DURATION=5m` in the suite command is recorded in
`metadata.json` but has **no effect** on the k6 run.

To shorten HPA runs (e.g. for faster iteration or budget constraints):

```bash
HPA_RAMP_UP_1=1m HPA_RAMP_UP_2=1m HPA_RAMP_UP_3=2m HPA_HOLD=3m HPA_RAMP_DOWN=30s \
  make run-benchmark-suite SCALING_MODE=hpa EXPERIMENT_NAME=rq2-hpa ...
# Total: 7.5 minutes per case
```

For the full HPA stage configuration reference, see
`docs/experiment/scaling-mode-strategy.md` §6.3.

Estimated suite time with default HPA stages:

```text
15 cases × 13m k6 + 5m INTER_CASE_DELAY = ~4.5 hours
```

---

## 5. Scenario: Login

```bash
# Reset and seed (both clusters)
kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/reset-monolith-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/reset-microservices-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/seed-monolith-benchmark-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/seed-microservices-benchmark-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

# Run parallel benchmark
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

Interpret the runner outcome as follows:

- `PASS`: valid run, thresholds passed
- `OVERLOAD`: valid run, thresholds failed, useful for ceiling discovery
- `INVALID`: rerun required after infra/config/runtime issue is fixed
- `TIMEOUT`: rerun required after timeout cause is understood

Do not start this step immediately after an HPA run unless the stack has been
redeployed back to fixed mode and validated.

---

## 6. Scenario: Create Transaction

Same reset and seed steps as login, then:

```bash
make run-benchmark-parallel \
  SCENARIO=create-transaction \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

---

## 7. Scenario: Enriched Transactions

Requires enrichment data preparation after base seed:

```bash
# After reset and seed (same as above), prepare enrichment data
make eks-prepare-enrichment-benchmark

# Run parallel benchmark
make run-benchmark-parallel \
  SCENARIO=enriched-transactions \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

---

## 8. Optional Scenario: Sync Items

`sync-items` is supported as an optional isolated workflow validation scenario.
Because `PUT /api/v1/items` performs full active-item synchronization, reset and
seed the base benchmark dataset before each run just like the write-path
scenario.

```bash
make run-benchmark-parallel \
  SCENARIO=sync-items \
  TARGET_RPS=10 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

---

## 9. Multiple RPS Levels

Repeat the run for each target RPS level. Reset and seed before each run
for scenarios that mutate data (create-transaction).

```bash
for rps in 1000 2500 5000; do
  # Reset and seed (for create-transaction)
  # ... (reset/seed commands) ...

  make run-benchmark-parallel \
    SCENARIO=create-transaction \
    TARGET_RPS=$rps \
    RUN_ID=eks-run-001 \
    ATTEMPT=attempt-01 \
    S3_BUCKET=<bucket>
done
```

For login and enriched-transactions, reset and seed only once before the
first RPS level since they do not mutate data.

---

## 10. Full Benchmark Suite

For final fixed or HPA runs, prefer the suite runner when you want to execute
the full scenario and RPS matrix with less manual operator input:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  RPS_LEVELS="1000 2500 5000"
```

Default suite behavior:

- `SCENARIOS` defaults to `login create-transaction enriched-transactions`
- `RPS_LEVELS` defaults to `1000 2500 5000 7500 10000`
- `SCENARIO_RPS_MATRIX`, when set, overrides the cross-product behavior of `SCENARIOS` x `RPS_LEVELS`
- `RUN_ID` stays highest-precedence when set manually
- `EXPERIMENT_NAME`, when provided and `RUN_ID` is blank, generates a stable `RUN_ID` as `eks-{mode}-{experiment_name}`
- `RUN_ID` falls back to `eks-{mode}-{yyyymmdd}-{HHMM}` only when both `RUN_ID` and `EXPERIMENT_NAME` are blank
- `ATTEMPT` is auto-detected from S3 and starts at `attempt-01`
- `K6_PROFILE` defaults to `steady` for fixed mode and `hpa` for HPA mode
- `INTER_CASE_DELAY` defaults to `0` for backward-compatible smoke and
  calibration runs
- `AUTO_DESTROY_CONFIRMED` defaults to `false` and only triggers
  `make eks-destroy-confirmed` after `_suite/summary.json` is uploaded
- by default, the runner fails fast if `SCALING_MODE` and `K6_PROFILE` are
  paired incorrectly or if the live clusters do not actually match the
  expected HPA/fixed state; use `ALLOW_NONSTANDARD_SCALING_PROFILE=true` only
  for deliberate nonstandard experiments
- by default, the runner also performs an AWS/EKS benchmark preflight before
  the suite starts, before every case, and again before summary upload so an
  expired local session stops with a clear error instead of degrading into
  missing S3 artifacts; set `SKIP_BENCHMARK_PREFLIGHT=true` only for deliberate
  debugging

Recommended repeat-attempt workflow:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-final \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  RPS_LEVELS="1000 2500 5000"
```

With the same `EXPERIMENT_NAME`, the suite resolves to the same `RUN_ID`, so
rerunning the command with `ATTEMPT` left blank will auto-increment from
`attempt-01` to `attempt-02`, `attempt-03`, and so on.

Scenario-specific RPS matrix workflow:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-fixed-primary \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  SCENARIO_RPS_MATRIX="login:100,120,140,160,180,200;create-transaction:100,150,200,250,300,400,500;enriched-transactions:100,150,200,250,300,400,500"
```

Recommended interpretation for this fixed primary matrix:

- Treat it as the conservative primary Bab 4 matrix.
- `login` stops at `200` RPS to keep the main suite focused on the transition
  zone where the microservices path is already informative.
- `create-transaction` and `enriched-transactions` extend to `500` RPS because
  both architectures still provide useful separation in that higher range.
- If later analysis needs to show monolith `login` headroom beyond `200` RPS,
  run a separate `login` extension experiment instead of changing the primary
  matrix mid-stream.

Optional fixed `login` extension workflow:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-login-extension \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=90 \
  SCENARIOS="login" \
  RPS_LEVELS="225 250"
```

This extension run is exploratory/supporting data. Keep it separate from
`rq1-fixed-primary` so the primary matrix remains a clean, repeatable source of
truth for Bab 4.

For `enriched-transactions`, the suite now performs reset, seed, and enrichment
preparation while the application deployments are still scaled down. Only after
the preparation jobs complete does the runner restore the rendered fixed/HPA
workloads and start the k6 case. This prevents the prepare job from being
blocked by a full namespace `ResourceQuota` and guarantees that the job uses
the same rendered image tag as the rest of the suite.

Matrix format:

```text
scenario:rps1,rps2,rps3;scenario:rps1,rps2
```

Notes:

- `SCENARIO_RPS_MATRIX` is optional.
- When it is set, the runner ignores the normal `SCENARIOS` and `RPS_LEVELS`
  cross-product and uses the matrix entries instead.
- The suite manifest and summary keep both the scenario list, the union of all
  RPS values, and the full `scenario_rps_matrix`.

Optional unattended cleanup workflow:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-final \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  AUTO_DESTROY_CONFIRMED=true \
  RPS_LEVELS="1000 2500 5000"
```

This is intended for long unattended runs. After the suite finishes and uploads
`_suite/summary.json`, it immediately runs `make eks-destroy-confirmed`. If the
suite exits early before it reaches summary upload, automatic destroy does not
run. To avoid hard-to-trace timestamp-only unattended runs, this mode requires
either `EXPERIMENT_NAME` or `RUN_ID`.

Manual overrides remain supported:

```bash
make run-benchmark-suite \
  SCALING_MODE=hpa \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=300 \
  RPS_LEVELS="1000 2500 5000" \
  RUN_ID=eks-hpa-final-rq2 \
  ATTEMPT=attempt-02
```

The suite runner still executes one `run-benchmark-parallel` case at a time.
Monolith and microservices run in parallel for each case, while scenarios and
RPS levels run serially.

`INTER_CASE_DELAY` adds an operator-controlled stabilization gap between suite
cases. It accepts a non-negative integer value in seconds, normalizes leading
zeroes, and rejects values above `86400` seconds to avoid accidental multi-day
pauses. Duration suffixes such as `5m` are not supported; use `300` for five
minutes. If the suite has only one case, for example one scenario with one RPS
level, the inter-case delay is skipped because there is no next case to
stabilize. It is intentionally outside the k6 script because k6's
`gracefulStop` controls in-flight iteration shutdown inside one run, not the
system recovery period between independent benchmark runs. Recommended
measured-run values:

| Scaling mode | Suggested inter-case delay | Reason |
|---|---:|---|
| fixed | `60`-`120` seconds | Let application pods, database pressure, and Datadog metrics settle. |
| hpa | `180`-`300` seconds | Let HPA metrics, replica changes, scale-down behavior, and Datadog telemetry settle. |

For fast smoke tests, use `INTER_CASE_DELAY=0`.

The suite runner also writes run-level metadata under:

```text
s3://<bucket>/experiments/<run_id>/_suite/manifest.json
s3://<bucket>/experiments/<run_id>/_suite/summary.json
```

Both files include `resource_configuration` and `inter_case_delay` for the
selected scaling mode. The resource value is generated from the same runner
configuration that is passed into each attempt's `metadata.json`.

In `_suite/summary.json`, each case now also includes:

- case-level `started_at_utc`
- case-level `finished_at_utc`
- case-level `timing_source`
- `architectures.monolith.*`
- `architectures.microservices.*`

Timing precedence per architecture is:

1. `metadata.json.datadog.time_window_start` and `time_window_end`
   → `timing_source: attempt_metadata`
2. `datadog-time-window.json` start and end (fallback if metadata is missing/partial)
   → `timing_source: datadog_artifact`
3. `metadata.json.timestamp_utc` plus suite-orchestrator finish time
   → `timing_source: attempt_metadata_partial`
4. suite-orchestrator start and finish time
   → `timing_source: orchestrator`

Per-architecture `timing_source` values (under `architectures.<name>`):

- `attempt_metadata`: both timestamps came from attempt metadata (Datadog window)
- `datadog_artifact`: both timestamps came from secondary datadog-time-window.json
- `attempt_metadata_partial`: start from metadata `timestamp_utc`, end from
  orchestrator wall-clock
- `orchestrator`: both timestamps came from orchestrator wall-clock

Case-level `timing_source` values:

- `attempt_metadata`: all architectures used full metadata (attempt_metadata or datadog_artifact)
- `orchestrator`: all architectures used orchestrator-based timing (includes
  `attempt_metadata_partial`)
- `mixed`: at least one architecture used full metadata AND at least one used
  fallback

---

## 10. Verify S3 Results

After each run:

```bash
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive | grep summary.json
```

Expected output:

```text
experiments/eks-run-001/monolith/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/microservices/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/monolith/create-transaction/1000rps/attempt-01/summary.json
experiments/eks-run-001/microservices/create-transaction/1000rps/attempt-01/summary.json
...
```

Also verify that each attempt folder includes:

- `summary.json`
- `thresholds.json`
- `result-status.json`
- `metadata.json`
- `stdout.log`

---

## 11. Final Result Interpretation

`make run-benchmark-parallel` exits with:

- `0` only when both architectures finish with `PASS`
- non-zero when either architecture finishes with `OVERLOAD`, `INVALID`, or `TIMEOUT`

This means a non-zero exit does not always mean the benchmark was invalid.

Use the final printed summary plus these artifacts to interpret the run:

- `thresholds.json`: primary source for `PASS` vs `OVERLOAD`
- `result-status.json`: k6 exit code, S3 upload status, and artifact presence
- `stdout.log`: diagnostic context when classification is `INVALID`

`PASS` requires a clean k6 exit code of `0`. A non-zero runtime exit such as
k6 `107` (script exception) must be treated as `INVALID` even if partial
artifacts or threshold files were uploaded to S3.

The final summary also prints a run-level `Report generator source`, for
example:

```text
s3://<bucket>/experiments/<run_id>
```

Use that URI directly as the S3 input for downstream reporting tools such as
`k6-report-generator`.

Treat `OVERLOAD` as valid evidence for capacity discovery. Treat `INVALID` and
`TIMEOUT` as rerun-required states.

---

## 12. Datadog Time Window Alignment

After each parallel run, verify that both `datadog-time-window.json` files
have timestamps within 30 seconds of each other:

```bash
aws s3 cp s3://<bucket>/experiments/eks-run-001/monolith/login/1000rps/attempt-01/datadog-time-window.json - | jq .time_window_start
aws s3 cp s3://<bucket>/experiments/eks-run-001/microservices/login/1000rps/attempt-01/datadog-time-window.json - | jq .time_window_start
```

If the gap is > 30 seconds, the Datadog time-series comparison may not be
perfectly aligned. This is acceptable for analysis but should be noted.

---

## 13. Destroy Infrastructure

Only destroy after all planned runs are complete and all S3 results are
verified.

```bash
# Verify all expected files exist
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive | wc -l

# Verify Terraform-compatible AWS auth
make terraform-auth-check

# Destroy clusters and RDS
make eks-destroy-confirmed

# Destroy shared resources only when fully done with all experiments
# make eks-shared-destroy
```

Do not destroy shared resources if another experiment run is planned soon.
ECR images and S3 results are preserved after cluster destroy.

---

## 14. Metadata Recording

Each run must record the scaling mode in `RESOURCES_CONFIGURATION_JSON`
when calling `run-benchmark-parallel.sh`. The deploy scripts set this
automatically based on `SCALING_MODE`.

Example for fixed mode:

```json
{
  "autoscaling_mode": "fixed",
  "hpa_enabled": false,
  "namespace_resource_quota": { "cpu": "15800m", "memory": "27648Mi" },
  "services": {
    "api-gateway": { "cpu_request": "500m", "cpu_limit": "2000m", "memory_request": "864Mi", "memory_limit": "3456Mi", "replica_count": 1 },
    "auth-service": { "cpu_request": "1500m", "cpu_limit": "4000m", "memory_request": "2592Mi", "memory_limit": "6912Mi", "replica_count": 1 },
    "item-service": { "cpu_request": "1000m", "cpu_limit": "3000m", "memory_request": "1728Mi", "memory_limit": "5184Mi", "replica_count": 1 },
    "transaction-service": { "cpu_request": "2000m", "cpu_limit": "6800m", "memory_request": "3456Mi", "memory_limit": "12096Mi", "replica_count": 1 }
  }
}
```

Example for HPA mode:

```json
{
  "autoscaling_mode": "hpa",
  "hpa_enabled": true,
  "namespace_resource_quota": { "cpu": "15800m", "memory": "27648Mi" },
  "services": {
    "api-gateway": { "cpu_request": "250m", "cpu_limit": "500m", "memory_request": "432Mi", "memory_limit": "864Mi", "min_replicas": 1, "max_replicas": 4, "target_cpu_utilization": 70 },
    "auth-service": { "cpu_request": "500m", "cpu_limit": "1000m", "memory_request": "864Mi", "memory_limit": "1728Mi", "min_replicas": 1, "max_replicas": 4, "target_cpu_utilization": 70 },
    "item-service": { "cpu_request": "250m", "cpu_limit": "500m", "memory_request": "432Mi", "memory_limit": "864Mi", "min_replicas": 1, "max_replicas": 6, "target_cpu_utilization": 70 },
    "transaction-service": { "cpu_request": "850m", "cpu_limit": "1700m", "memory_request": "1512Mi", "memory_limit": "3024Mi", "min_replicas": 1, "max_replicas": 4, "target_cpu_utilization": 70 }
  }
}
```

This is written to `metadata.json` and uploaded to S3 with each attempt.

---

## 15. Recovery: HPA to Fixed Transition

If a fixed-mode deploy is attempted while the MSA stack is still expanded by
HPA, migration jobs may be blocked by the namespace `ResourceQuota`.

Observed symptom:

```text
exceeded quota: msa-resource-quota, requested: limits.cpu=100m, used: limits.cpu=4, limited: limits.cpu=4
```

Recovery sequence:

```bash
# stop invalid benchmark jobs
kubectl --context=monolith delete job k6-benchmark-monolith -n benchmark --ignore-not-found
kubectl --context=msa delete job k6-benchmark-microservices -n benchmark --ignore-not-found

# clear stale HPA state on MSA
kubectl --context=msa delete hpa --all -n msa
kubectl --context=msa scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa

# clear stuck migration jobs if they already exist
kubectl --context=msa delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found

# rerun fixed deploy
SCALING_MODE=fixed make eks-deploy-msa
```
