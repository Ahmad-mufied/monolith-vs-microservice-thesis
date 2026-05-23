# Benchmark Execution Lifecycle

## 1. Purpose

This document defines the benchmark execution lifecycle for the thesis
experiment on AWS EKS.

It covers:

- infrastructure lifecycle,
- database lifecycle,
- migration, reset, and seed jobs,
- k6 rerun behavior,
- S3 result storage layout.

The goal is to keep benchmark runs clean, repeatable, and easy to analyze
without mixing results from different executions.

## 2. Final Decision

The benchmark uses two cleanup levels:

```text
Per k6 execution cleanup
= reset dataset and seed again before k6 starts

Per experiment lifecycle cleanup
= destroy EKS and RDS after all benchmark results are uploaded to S3
```

Important rules:

- do not reset data inside application startup,
- do not run migration, reset, or seed during k6 execution,
- run reset and seed before every k6 execution,
- upload k6 results to S3 before running the next execution or destroying infrastructure,
- do not run `make eks-destroy` until all expected result files are present in S3.

## 3. Infrastructure Lifecycle

An experiment lifecycle starts with:

```text
build/push images
-> patch EKS manifests with IMAGE_TAG
-> aws login
-> make terraform-auth-check
-> make eks-apply
```

This provisions the benchmark infrastructure:

- EKS cluster,
- node groups,
- RDS PostgreSQL,
- IAM roles / IRSA / EKS Pod Identity,
- networking and security groups,
- supporting Kubernetes resources when managed by IaC.

An experiment lifecycle ends with:

```text
aws login
-> make terraform-auth-check
-> make eks-destroy
```

When RDS is included in the destroy plan, all database state is removed:

- database schema,
- Goose migration history,
- benchmark seed data,
- k6-mutated data.

This is intentional for a fully clean experiment lifecycle.

## 4. Fresh Experiment Flow

Use this flow when starting from a new IaC-provisioned environment:

```text
aws login
-> make terraform-auth-check
-> make eks-apply
-> create EKS and RDS
-> run database bootstrap job
-> run migration job
-> run reset job
-> run seed job
-> deploy application
-> validate row counts and readiness
-> run k6 job
-> upload result files to S3
-> verify result files in S3
-> make eks-destroy after all benchmark executions are complete
```

Migration and seed have different responsibilities:

| Job | Responsibility |
|---|---|
| bootstrap job | create logical databases such as `mono_db`, `auth_db`, `item_db`, and `transaction_db` |
| migration job | create or update schema using Goose |
| reset job | clean benchmark data while keeping schema |
| seed job | insert deterministic benchmark dataset |
| k6 job | run the selected workload and upload outputs |

## 5. Rerun Flow Without Destroying Infrastructure

If a k6 execution finishes and the infrastructure is still alive, do not destroy
EKS or RDS just to rerun the same scenario.

Use this flow instead:

```text
previous k6 execution finished
-> upload previous result files to S3
-> choose the next attempt id
-> run reset job
-> run seed job
-> validate row counts and readiness
-> run k6 job again
-> upload result files to a different S3 prefix
```

This is the recommended flow for:

- rerunning a scenario after an unexpected result,
- running multiple attempts for statistical comparison,
- repeating a failed k6 run,
- running the next RPS level in the same experiment lifecycle.

Do not run k6 again directly against data mutated by the previous k6 execution.

## 6. Migration Behavior

Migration jobs may be run again after EKS is recreated or after app schema
changes.

Goose stores migration state in the database, so rerunning migration against an
existing RDS instance is safe when migrations are properly versioned:

```text
already applied migrations -> skipped
new migrations             -> applied
```

For a fresh RDS created by `terraform apply`, migration jobs must run before
reset, seed, application benchmark execution, or k6.

For a rerun in the same infrastructure with no schema change:

```text
run reset job
run seed job
run k6 job
```

Migration does not need to run again in that case.

## 7. Reset and Seed Policy

Reset and seed are required before every k6 execution.

Reason:

- create-transaction workloads mutate transaction tables,
- retrying k6 without reset changes the dataset,
- comparing monolith and microservices requires equivalent logical input data,
- each attempt must start from a known state.

Reset must clean data, not infrastructure.

Examples:

```text
Monolith reset:
truncate users, items, transactions, transaction_items in mono_db

Microservices reset:
truncate users in auth_db
truncate items in item_db
truncate transactions and transaction_items in transaction_db
```

Seed must insert deterministic benchmark data and preserve logical equivalence
between architectures.

The UUID values do not need to match between monolith and microservices as long
as the logical dataset is equivalent and the generated ID mappings are captured.

## 8. S3 Result Storage

Each k6 execution must upload results to a unique S3 prefix.

Final prefix format:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Field meanings:

| Field | Meaning |
|---|---|
| `run_id` | timestamp-like id for the experiment lifecycle or execution group |
| `architecture` | `monolith` or `microservices` |
| `scenario_name` | k6 scenario name, usually the script basename without `.js` |
| `target_rps` | RPS configured for that k6 execution |
| `attempt` | repeated execution number for the same architecture, scenario, and RPS |

Example:

```text
s3://skripsi-benchmark-results/experiments/20260512-103000/monolith/login/1000rps/attempt-01/
s3://skripsi-benchmark-results/experiments/20260512-103000/monolith/login/1000rps/attempt-02/
s3://skripsi-benchmark-results/experiments/20260512-103000/microservices/create-transaction/2500rps/attempt-01/
```

`target_rps` is included in the S3 path for quick navigation and overwrite
avoidance. The authoritative value must also be written to `metadata.json`.

`scenario_name` should map directly to the k6 script name without extension:

| k6 script | `scenario_name` |
|---|---|
| `k6/scripts/login.js` | `login` |
| `k6/scripts/create-transaction.js` | `create-transaction` |
| `k6/scripts/enriched-transactions.js` | `enriched-transactions` |
| `k6/scripts/mixed-workload.js` | `mixed-workload` |

## 9. Files Per Attempt

Each attempt folder must keep raw collection output separated from other
attempts.

Required files per attempt:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
```

Required when Datadog is enabled:

```text
datadog-time-window.json
```

Optional files:

```text
summary.html
```

Additional files may be added when useful, but do not overwrite or merge raw
attempt output during collection. Kubernetes snapshot files are not required
by default; the primary internal evidence comes from Datadog telemetry plus
`metadata.json`.

Raw collection must stay separated by attempt.

Aggregated data should be produced later during analysis.

Recommended analysis output location:

```text
s3://{bucket}/experiments/{run_id}/analysis/
```

Example analysis files:

```text
comparison-summary.csv
monolith-login-1000rps-summary.csv
microservices-create-transaction-2500rps-summary.csv
```

## 10. Metadata

Each attempt must include `metadata.json`.

Recommended fields:

```json
{
  "run_id": "20260512-103000",
  "attempt": "attempt-01",
  "architecture": "monolith",
  "scenario_name": "create-transaction",
  "k6_script": "k6/scripts/create-transaction.js",
  "target_rps": 2500,
  "duration": "5m",
  "base_url": "https://example",
  "timestamp_utc": "2026-05-12T03:30:00Z",

  "git_commit": "a1b2c3d",
  "image_tag": "a1b2c3d",
  "images": {
    "monolith": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/monolith:a1b2c3d",
    "api_gateway": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/api-gateway:a1b2c3d",
    "auth_service": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/auth-service:a1b2c3d",
    "item_service": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/item-service:a1b2c3d",
    "transaction_service": "720166597212.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/transaction-service:a1b2c3d"
  },

  "dataset_version": "v1",
  "seed_size": {
    "users": 1000,
    "items": 1000,
    "transactions": 0
  },

  "k6": {
    "version": "x.x.x",
    "executor": "constant-arrival-rate",
    "vus": 100,
    "pre_allocated_vus": 100,
    "max_vus": 500
  },

  "infra": {
    "provider": "aws",
    "region": "ap-southeast-1",
    "eks_cluster": "skripsi-benchmark",
    "app_node_pool": "app-nodes",
    "testing_node_pool": "testing-nodes",
    "rds_instance_class": "db.xxx",
    "postgres_version": "18"
  },

  "resources": {
    "app_resource_quota": "4000m CPU / 4096Mi memory",
    "autoscaling_mode": "hpa",
    "hpa_enabled": true,
    "hpa_target_cpu": "70%",
    "min_replicas": 1,
    "max_replicas": 16
  },

  "datadog": {
    "enabled": true,
    "env": "benchmark",
    "time_window_start": "2026-05-12T03:30:00Z",
    "time_window_end": "2026-05-12T03:35:00Z",
    "k6_statsd_addr": "datadog-agent.datadog.svc.cluster.local:8125",
    "k6_statsd_namespace": "k6"
  }
}
```

`metadata.json` is the source of truth for automated analysis.

`metadata.json` is also the source of truth for determining whether a benchmark
attempt used HPA or fixed replicas.

For a fixed-replica experiment without HPA, use this resources shape:

```json
{
  "resources": {
    "app_resource_quota": "4000m CPU / 4096Mi memory",
    "autoscaling_mode": "fixed",
    "hpa_enabled": false,
    "replica_count": 4
  }
}
```

The S3 path is an index for human navigation and overwrite protection.

## 11. Attempt Policy

Use a new attempt folder for every repeated k6 execution.

Examples:

```text
attempt-01
attempt-02
attempt-03
```

Attempt numbering resets per:

```text
run_id + architecture + scenario_name + target_rps
```

Example:

```text
experiments/20260512-103000/monolith/login/1000rps/attempt-01/
experiments/20260512-103000/monolith/login/1000rps/attempt-02/
experiments/20260512-103000/monolith/login/2500rps/attempt-01/
```

Do not reuse an attempt folder.

## 12. Destroy Policy

Destroy infrastructure only after:

- all planned k6 executions are complete,
- all attempt folders are uploaded to S3,
- all expected files are present,
- basic result integrity has been checked,
- there is no need to inspect live Kubernetes or RDS state.

Final destroy step:

```text
aws login
-> make terraform-auth-check
-> make eks-destroy
```

When RDS is part of the destroy plan, this removes all database state.

This is acceptable after results are safely stored in S3.

## 13. Summary

Recommended final policy:

```text
Fresh experiment:
aws login
-> make terraform-auth-check
-> terraform apply
-> bootstrap
-> migration
-> reset
-> seed
-> k6
-> upload
-> make eks-destroy after all results are safe

Rerun while infra is alive:
reset
-> seed
-> k6
-> upload to a new attempt prefix
```

This keeps infrastructure lifecycle clean while preserving repeatable benchmark
inputs for every k6 execution.
