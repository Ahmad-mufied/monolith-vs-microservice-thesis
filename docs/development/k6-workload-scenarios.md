# k6 Workload Scenarios

## 1. Purpose

This document defines the k6 workload scenarios used in the monolith versus microservices thesis benchmark.

The goal is to compare runtime behavior under equivalent REST API workloads while preserving the architectural distinction:

```text
Monolith
→ one deployable application
→ in-process module calls
→ one database

Microservices
→ API Gateway
→ internal gRPC calls
→ separate service databases
```

---

## 2. Scenario Set

The benchmark uses three required scenarios:

| Scenario | Script | Endpoint | Category |
|---|---|---|---|
| Login | `k6/scripts/login.js` | `POST /api/v1/auth/login` | authentication workload |
| Create Transaction | `k6/scripts/create-transaction.js` | `POST /api/v1/transactions` | write-heavy workload |
| Enriched Transactions | `k6/scripts/enriched-transactions.js` | `GET /api/v1/admin/transactions` | read-heavy aggregation workload |

Additional validation or optional scenarios:

| Scenario | Script | Status |
|---|---|---|
| Smoke | `k6/scripts/smoke.js` | validation only |
| Sync Items | `k6/scripts/sync-items.js` | optional |
| Mixed Workload | `k6/scripts/mixed-workload.js` | optional |

---

## 3. Scenario Lifecycle

### 3.1 Login

Lifecycle:

```text
reset data
seed base users/items
validate users
run login scenario
collect results
```

Measured endpoint:

```text
POST /api/v1/auth/login
```

The scenario uses seeded users and performs one login request per iteration.

### 3.2 Create Transaction

Lifecycle:

```text
reset data
seed base users/items
validate users and items
run create-transaction scenario
collect results
```

Measured endpoint:

```text
POST /api/v1/transactions
```

The scenario uses seeded users and seeded items.

Transactions are created by k6 during the measured workload.

This scenario does not use pre-seeded transaction rows.

For the `benchmark` dataset, k6 default user and item generation must match
the seed runner benchmark data:

```text
benchmark-user-001@example.com
password: Password123!
00000000-0000-7000-8000-000000000001
```

For non-benchmark datasets that do not follow the generator pattern, pass
optional k6 input files with `USERS_FILE` and `ITEM_IDS_FILE`. These files are
runtime input for k6 only; they are not database seed data.

### 3.3 Enriched Transactions

Lifecycle:

```text
reset data
seed base users/items
prepare enrichment transaction dataset
validate transaction row count
run enriched-transactions scenario
collect results
```

Measured endpoint:

```text
GET /api/v1/admin/transactions
```

The enrichment preparation step inserts transactions and transaction_items before the measured read benchmark begins.

That preparation step is not part of the measured k6 result.

---

## 4. Load Model

Main benchmark scenarios use RPS-based execution with k6 `constant-arrival-rate`.

Reason:

```text
The experiment is interested in target request rate, latency, error rate, and resource usage under controlled arrival pressure.
```

Default profile:

```text
K6_PROFILE=steady
```

Optional profiles:

```text
smoke
ramp
hpa
```

`hpa` profile should be used only when autoscaling behavior is part of the experiment.

---

## 5. Metrics

Primary k6 metrics:

```text
http_req_duration p90
http_req_duration p95
http_req_failed
http_reqs
iterations
checks
dropped_iterations
```

Primary infrastructure and observability metrics:

```text
CPU usage
memory usage
pod count
HPA behavior, when enabled
Datadog service latency
Datadog error rate
Datadog distributed traces
```

---

## 6. Output Files

Each attempt should produce:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
metadata.partial.json
k6-options.json
thresholds.json
```

Infrastructure snapshots are collected outside k6:

```text
pods-state.txt
top-pods.txt
top-nodes.txt
events.txt
resource-quotas.yaml
deployments-state.yaml
services-state.yaml
```

When HPA is enabled:

```text
hpa-state.yaml
hpa-describe.txt
```

When Datadog is enabled:

```text
datadog-time-window.json
```

---

## 7. S3 Layout

Recommended S3 prefix:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Example:

```text
s3://skripsi-benchmark-results/experiments/20260517-120000/msa/create-transaction/1000rps/attempt-01/
```

`metadata.json` is the source of truth.

The S3 path is used for navigation, grouping, and overwrite prevention.

---

## 8. Fairness Rules

For every measured attempt:

```text
reset
seed
optional enrichment preparation
k6
collect results
```

Do not run migration, reset, seed, or enrichment preparation while k6 is running.

Do not compare results from different dataset states.

Do not use local Docker Compose or Minikube results as final thesis benchmark data.

Final results should come from EKS.

---

## 9. Interpretation

### Login

Compares authentication path overhead.

Monolith:

```text
client -> monolith -> database
```

Microservices:

```text
client -> api-gateway -> auth-service -> auth_db
```

### Create Transaction

Compares transaction write path.

Monolith:

```text
client -> monolith -> item validation -> transaction write
```

Microservices:

```text
client -> api-gateway -> transaction-service -> item-service -> transaction_db
```

### Enriched Transactions

Compares read-heavy aggregation.

Monolith:

```text
client -> monolith -> local database join
```

Microservices:

```text
client -> api-gateway -> transaction-service
                    -> auth-service
                    -> item-service
                    -> in-memory enrichment
```

---

## 10. Final Policy

Required benchmark scripts:

```text
login.js
create-transaction.js
enriched-transactions.js
```

Validation script:

```text
smoke.js
```

Optional scripts:

```text
sync-items.js
mixed-workload.js
```

Base seed:

```text
users + items
```

Enriched read preparation:

```text
transactions + transaction_items
```

This keeps write workload output separate from read workload preparation.
