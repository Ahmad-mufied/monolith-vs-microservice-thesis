# Sequential Benchmark Runbook

## 1. Purpose

Sequential mode runs monolith and microservices benchmarks one architecture at a
time on a single EKS cluster. It is intended for AWS accounts where quota or
budget cannot support the full dual-cluster parallel topology.

Use this mode when the account only has enough vCPU for one benchmark stack at
a time. Use `docs/infrastructure/eks-parallel-runbook.md` when you need
wall-clock aligned Datadog time-series from two isolated clusters.

For the combined topology diagram, see
`docs/diagrams/sequential-parallel-topology.md`.

## 2. Topology

```text
shared Terraform stack
  -> VPC
  -> subnets
  -> NAT
  -> k6 S3 upload IAM role

aws-sequential Terraform stack
  -> EKS cluster: skripsi-benchmark
  -> RDS: skripsi-benchmark-postgres

kubectl context:
  benchmark

namespaces:
  mono       -> monolith deployment and jobs
  msa        -> microservices deployments and jobs
  benchmark  -> db bootstrap, k6 runner, RBAC
```

During a measured run, only one application architecture should be active. The
deploy script scales the opposite architecture down to zero and removes its HPA
objects before the active architecture is prepared.

## 3. Prerequisites

```text
- S3 result bucket exists
- ECR repositories exist
- Images are built and pushed
- env/terraform.shared.env and env/terraform.experiment.env exist
- AWS auth is fresh
- shared Terraform stack is applied
```

Recommended bootstrap:

```bash
aws login
make env-init PLATFORM=eks EXECUTION_MODE=sequential
make eks-render-tfvars
make ecr-push-all IMAGE_TAG=$(git rev-parse --short HEAD)
make eks-shared-apply
```

`make eks-render-tfvars` renders both the existing parallel tfvars and the new
sequential tfvars. `DB_PASSWORD` still stays in `env/terraform.experiment.env`
and is injected by the Terraform wrapper at runtime.

## 4. Provision Sequential Infrastructure

Always run the recovery check before applying sequential infrastructure,
especially after an interrupted apply or destroy.

```bash
make terraform-sequential-recovery-check
make eks-sequential-plan
make eks-sequential-apply
```

The sequential wrapper refuses to apply if AWS already has
`skripsi-benchmark` or `skripsi-benchmark-postgres` but the sequential
Terraform state does not track them. This prevents duplicate-name drift and
prevents Terraform from hiding an interrupted operation behind a misleading
create plan.

Configure the kube context:

```bash
make eks-setup-context-sequential
kubectl --context=benchmark get nodes
```

Expected node groups:

```text
app-nodes      -> application pods
testing-nodes  -> k6 runner jobs
```

## 5. Create Secrets

Create all required secrets for both architectures in the single cluster:

```bash
make eks-create-secrets-sequential
```

The helper reads:

```text
env/monolith.app.env
env/api-gateway.app.env
env/auth-service.app.env
env/item-service.app.env
env/transaction-service.app.env
env/k6-runner.app.env
env/terraform.experiment.env
```

It writes secrets into `mono`, `msa`, and `benchmark` namespaces and points all
database URLs to `sequential_rds_endpoint`.

## 6. Deploy One Architecture

Deploy monolith:

```bash
ARCHITECTURE=monolith SCALING_MODE=fixed make eks-deploy-sequential-architecture
```

Deploy microservices:

```bash
ARCHITECTURE=microservices SCALING_MODE=fixed make eks-deploy-sequential-architecture
```

For HPA:

```bash
ARCHITECTURE=monolith SCALING_MODE=hpa make eks-deploy-sequential-architecture
ARCHITECTURE=microservices SCALING_MODE=hpa make eks-deploy-sequential-architecture
```

The deploy script performs the safe preparation sequence:

```text
render manifests
validate rendered assets
create namespaces/RBAC
scale down opposite architecture
run db bootstrap
run migrations
reset data
seed benchmark data
apply selected fixed/HPA overlay
wait for readiness
install Datadog if DATADOG_API_KEY is configured
```

Do not run migration, reset, seed, or enrichment jobs while a k6 job is running.

## 7. Run One Sequential Case

Monolith example:

```bash
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=1000 \
RUN_ID=eks-sequential-fixed-rq1 \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
make run-benchmark-sequential
```

Microservices example:

```bash
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=1000 \
RUN_ID=eks-sequential-fixed-rq1 \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
make run-benchmark-sequential
```

The runner writes artifacts to:

```text
s3://<bucket>/experiments/<run_id>/<architecture>/<scenario>/<target_rps>rps/<attempt>/
```

Each attempt metadata includes:

```text
execution_mode=sequential
terraform_stack=aws-sequential
cluster_name=skripsi-benchmark
architecture_order=<configured order>
```

## 8. Run the Sequential Suite

Default order is monolith first, then microservices:

```bash
make run-benchmark-suite-sequential \
  SCALING_MODE=fixed \
  ARCHITECTURE_ORDER="monolith microservices" \
  EXPERIMENT_NAME=rq1-fixed-sequential \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  ARCHITECTURE_SWITCH_DELAY=300 \
  SCENARIO_RPS_MATRIX="login:1000,2500,5000;create-transaction:1000,2500,5000;enriched-transactions:1000,2500,5000"
```

Reverse order when you want to check whether warm-up, time-of-day, or AWS
capacity variation affects results:

```bash
ARCHITECTURE_ORDER="microservices monolith" make run-benchmark-suite-sequential ...
```

The suite deploys the active architecture before its phase, resets and reseeds
data as needed, runs one k6 case at a time, and uploads:

```text
s3://<bucket>/experiments/<run_id>/_suite/manifest.json
s3://<bucket>/experiments/<run_id>/_suite/summary.json
```

Each sequential suite case now also records:

- case-level `started_at_utc`
- case-level `finished_at_utc`
- case-level `timing_source`
- `architectures.<active-architecture>.*`

This is separate from `architecture_phases`:

- case timing tracks one `scenario + target_rps + architecture` execution
- `architecture_phases` still summarizes the broader monolith or microservices
  phase in the sequential suite

Timing precedence per case is:

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

The sequential dual-architecture suite is fixed-only. If you need a broader
supplemental HPA batch on one architecture, use `run-benchmark-arch-suite`:

```bash
ARCHITECTURE=microservices \
SCALING_MODE=hpa \
EXPERIMENT_NAME=eks-sequential-hpa-rq2 \
INTER_CASE_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-arch-suite
```

For one-off retries or smoke-style checks, keep using the single-case runners.
- `orchestrator`: both timestamps came from orchestrator wall-clock

Case-level `timing_source` values:

- `attempt_metadata`: the architecture used full metadata (attempt_metadata or datadog_artifact)
- `orchestrator`: the architecture used orchestrator-based timing (includes
  `attempt_metadata_partial` which normalizes to `orchestrator` at case level)
- `mixed`: reserved; currently unreachable in sequential mode with a single
  architecture per case

Delay controls:

| Variable | Scope | Default | Purpose |
|---|---|---|---|
| `INTER_CASE_DELAY` | between scenario/RPS cases inside the same architecture phase | `0` | lets app, RDS, HPA, and Datadog settle between measured cases |
| `ARCHITECTURE_SWITCH_DELAY` | between monolith and microservices phases | `300` | creates a consistent Datadog gap before the next architecture is deployed |

For measured sequential runs, keep `ARCHITECTURE_SWITCH_DELAY` explicit in the
command even though the default is `300`. This makes the Datadog separation
visible in shell history, suite manifest, and suite summary.

## 9. Switching Between Architectures

Manual switch from monolith to microservices:

```bash
kubectl --context=benchmark get jobs -n benchmark
aws s3 ls s3://<bucket>/experiments/<run_id>/monolith/ --recursive
ARCHITECTURE=microservices SCALING_MODE=fixed make eks-deploy-sequential-architecture
```

Manual switch from microservices to monolith:

```bash
kubectl --context=benchmark get jobs -n benchmark
aws s3 ls s3://<bucket>/experiments/<run_id>/microservices/ --recursive
ARCHITECTURE=monolith SCALING_MODE=fixed make eks-deploy-sequential-architecture
```

The switch is a redeploy event. Do not simply change `ARCHITECTURE` on the k6
runner while the wrong application stack is still active.

## 10. Switching Between Modes

Parallel to sequential:

```bash
aws s3 ls s3://<bucket>/experiments/<parallel-run-id>/ --recursive
make eks-destroy-confirmed
make terraform-sequential-recovery-check
make eks-sequential-apply
make eks-setup-context-sequential
make eks-create-secrets-sequential
```

Sequential to parallel:

```bash
aws s3 ls s3://<bucket>/experiments/<sequential-run-id>/ --recursive
make eks-sequential-destroy-confirmed
make terraform-recovery-check
make eks-apply
make eks-setup-contexts
make eks-create-secrets
```

Keep the `shared` stack unless you are done with all benchmark work. Destroying
`shared` removes the VPC, subnets, NAT gateway, and k6 IAM role.

## 11. Destroy Sequential Infrastructure

Destroy only after S3 results are verified:

```bash
aws s3 ls s3://<bucket>/experiments/<run_id>/ --recursive
make eks-sequential-destroy-confirmed
```

The raw wrapper also accepts:

```bash
S3_BENCHMARK_DATA_VERIFIED=true bash scripts/terraform-aws-sequential.sh destroy
```

Without `S3_BENCHMARK_DATA_VERIFIED=true`, destroy is blocked.

## 12. Troubleshooting

Use these commands first:

```bash
make terraform-sequential-recovery-check
kubectl --context=benchmark get nodes
kubectl --context=benchmark get pods -A
kubectl --context=benchmark get jobs -A
kubectl --context=benchmark get hpa -A
aws s3 ls s3://<bucket>/experiments/<run_id>/ --recursive
```

Common failure modes:

| Symptom | Likely cause | Action |
|---|---|---|
| `BLOCKED` in recovery check | live AWS resource exists but state does not track it | stop before apply; import, remove stale resource, or reconcile state deliberately |
| k6 job succeeds but artifacts missing | AWS/S3 auth expired during upload | refresh login, inspect job logs, rerun the attempt with a new attempt id |
| wrong architecture receives traffic | active deployment does not match runner `ARCHITECTURE` | redeploy with `ARCHITECTURE=<target> make eks-deploy-sequential-architecture` |
| HPA absent in HPA run | app was deployed in fixed mode | redeploy with `SCALING_MODE=hpa` before running k6 |
| Datadog cluster tag unexpected | `SEQUENTIAL_CLUSTER_NAME` was overridden | confirm Helm values and `metadata.json` `cluster_name` |

## 13. Fairness Notes

Sequential mode is quota-efficient but changes the analysis shape:

- Resource ceilings remain equivalent.
- Runtime manifests and k6 scripts remain symmetrical.
- Monolith and microservices no longer run at the same wall-clock time.
- Compare Datadog windows by metadata, not by assuming simultaneous timestamps.
- Prefer alternating `ARCHITECTURE_ORDER` across repeated attempts if external
  AWS conditions may bias long-running measurements.
