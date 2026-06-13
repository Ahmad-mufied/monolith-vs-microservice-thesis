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

The final benchmark uses one primary system-level scenario and three diagnostic
endpoint scenarios.

Primary scenario:

| Scenario | Script | Endpoint mix | Category |
|---|---|---|---|
| Concurrent Mixed Workload | `k6/scripts/concurrent-mixed-workload.js` | `POST /api/v1/auth/login` 20%, `POST /api/v1/transactions` 40%, `GET /api/v1/admin/transactions` 40% | system-level composite workload |

Diagnostic scenarios:

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
| Mixed Workload | `k6/scripts/mixed-workload.js` | legacy random-branch mixed traffic; optional |

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

In sequential suite mode, the same seeded dataset may be reused across multiple
pending RPS levels for `login` because the measured workload does not mutate the
benchmark data.

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

When `enriched-transactions` is configured with `ADMIN_USER_EMAIL` /
`ADMIN_USER_PASSWORD`, those credentials must also match the seeded benchmark
user. For the repository default benchmark dataset, that means
`benchmark-user-001@example.com / Password123!`.

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

In sequential suite mode, the prepared enrichment dataset may be reused across
multiple pending RPS levels for `enriched-transactions` because the measured
workload is read-only after setup completes.

### 3.4 Concurrent Mixed Workload

Lifecycle:

```text
reset data
seed base users/items
prepare enrichment transaction dataset
validate setup logins and enrichment probe
run concurrent-mixed-workload scenario
collect results
```

Measured endpoints:

```text
POST /api/v1/auth/login              = 20% of total target RPS
POST /api/v1/transactions            = 40% of total target RPS
GET /api/v1/admin/transactions       = 40% of total target RPS
```

The scenario uses separate k6 arrival-rate scenarios for each endpoint branch.
This means the three endpoint branches run concurrently in one k6 execution
rather than being selected randomly inside a single iteration.

Only workload traffic is used for thresholds and the stdout summary line.
Setup logins and the enrichment readiness probe are tagged separately as setup
traffic, so they do not pollute the primary latency, failure-rate, and check-rate
metrics.

Example split:

```text
TARGET_RPS=100 -> login 20 RPS, create transaction 40 RPS, enriched transactions 40 RPS
TARGET_RPS=250 -> login 50 RPS, create transaction 100 RPS, enriched transactions 100 RPS
TARGET_RPS=500 -> login 100 RPS, create transaction 200 RPS, enriched transactions 200 RPS
```

With the default `20/40/40` split, `TARGET_RPS` must be divisible by `5`.
The configured `PRE_ALLOCATED_VUS` and `MAX_VUS` values represent total
load-generator capacity for the composite run and are divided proportionally
across the internal k6 scenarios.

The workload split represents external traffic composition, not microservices
resource allocation. Resource allocation is still controlled separately through
the architecture-level ResourceQuota and pod request/limit configuration.

The scenario fails fast when:

```text
seeded users are missing
seeded items are missing
token setup fails
enrichment data is not ready
TARGET_RPS cannot be split exactly by the configured weights
```

Default weights:

```text
CONCURRENT_MIX_LOGIN_WEIGHT=20
CONCURRENT_MIX_CREATE_TRANSACTION_WEIGHT=40
CONCURRENT_MIX_ENRICHED_TRANSACTIONS_WEIGHT=40
```

### 3.5 Legacy Mixed Workload

Lifecycle:

```text
reset data
seed base users/items
prepare enrichment transaction dataset when enriched branch weight > 0
validate setup logins and enrichment probe
run mixed-workload scenario
collect results
```

If `MIX_ENRICHED_TRANSACTIONS_WEIGHT` is greater than zero, the scenario setup
now validates that the enriched-transactions endpoint returns data before the
measured workload begins. This prevents the mixed scenario from silently
degrading into authentication/write-only traffic when enrichment fixtures are
missing.

Unlike `concurrent-mixed-workload`, the legacy `mixed-workload` script chooses
one branch per iteration using random weights. It can produce concurrent mixed
traffic at aggregate k6 level because many VUs run at the same time, but it is
not the final system-level workload used for primary RQ analysis.

---

## 4. Load Model

Main fixed-mode benchmark scenarios use RPS-based execution with k6
`constant-arrival-rate`.

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

`K6_PROFILE` and `RAMP_STAGES_JSON` are validated strictly. Invalid profile
names or malformed custom ramp-stage JSON now fail fast instead of silently
falling back to another executor or generated stages.

## 4.1 Request timeout precedence

The benchmark client now uses one central per-request timeout knob in
`k6/scripts/common/config.js`:

```text
K6_REQUEST_TIMEOUT_MS
```

Default value:

```text
60000
```

This value must remain larger than the application's own timeout budget so the
application, not k6, is the first layer to declare a timeout.

Current intended precedence:

```text
application-managed timeout boundary
    <
k6 HTTP request timeout (60s)
```

Current application-managed boundaries in this branch:

- monolith request deadline: `APP_REQUEST_TIMEOUT=35s`
- microservices outbound dependency deadline: `GRPC_CALL_TIMEOUT=32s`
- login overload boundary: `LOGIN_ADMISSION_ENABLED=true` with bounded bcrypt
  concurrency and `LOGIN_QUEUE_TIMEOUT=2s`

This keeps `k6` aligned with its historic long wait behavior while still making
the timeout explicit and overridable from one place if a future experiment
needs a tighter client guardrail.

Interpretation:

- `499` indicates the caller canceled or disconnected first.
- `503` indicates the application hit its own managed timeout boundary first.
- If k6 times out before the application, the run no longer reflects the
  intended timeout policy and the benchmark setup should be corrected before
  using the result for analysis.

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
k6-options.json
thresholds.json
```

When Datadog is enabled:

```text
datadog-time-window.json
```

For real-time Datadog output, the k6 runner sends metrics through DogStatsD.
The runner expects a k6 binary built with `xk6-output-statsd`, then enables the
StatsD output when:

```text
DATADOG_ENABLED=true
```

The Datadog Agent must expose DogStatsD on UDP `8125`.

---

## 7. S3 Layout

Recommended S3 prefix:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Example:

```text
s3://skripsi-benchmark-results/experiments/20260517-120000/microservices/create-transaction/1000rps/attempt-01/
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
concurrent-mixed-workload.js
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
