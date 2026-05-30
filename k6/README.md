# k6 Benchmark Scripts

## Purpose

The `k6/` directory contains benchmark scripts, reusable k6 helpers, local/EKS runner support, and sample runtime data for the thesis benchmark.

The benchmark compares the same REST API behavior under two runtime architectures:

```text
Monolith
Microservices
```

The scripts are designed to be driven by environment variables so the same source can run against:

```text
local Docker Compose
local Kubernetes / Minikube
EKS dry run
EKS final benchmark
```

Final thesis benchmark data should be collected from EKS.

---

## Directory Structure

```text
k6/
├── README.md
├── data/
│   ├── users.sample.json
│   └── item-ids.sample.json
├── runner/
│   ├── Dockerfile
│   ├── env.example
│   └── run-k6.sh
└── scripts/
    ├── common/
    │   ├── config.js
    │   ├── data.js
    │   ├── requests.js
    │   └── summary.js
    ├── smoke.js
    ├── login.js
    ├── create-transaction.js
    ├── enriched-transactions.js
    ├── sync-items.js
    └── mixed-workload.js
```

---

## Main Benchmark Scenarios

The required benchmark scenarios are:

| Script | Endpoint | Workload Type |
|---|---|---|
| `login.js` | `POST /api/v1/auth/login` | authentication / CPU + DB read |
| `create-transaction.js` | `POST /api/v1/transactions` | write-heavy transaction workload |
| `enriched-transactions.js` | `GET /api/v1/admin/transactions` | read-heavy enrichment workload |

Validation and optional scripts:

| Script | Purpose |
|---|---|
| `smoke.js` | end-to-end deployment validation |
| `sync-items.js` | optional full item synchronization workload |
| `mixed-workload.js` | optional mixed traffic simulation; requires enrichment preparation when the enriched branch weight is enabled |

---

## Required Data Lifecycle

The k6 scripts assume the database lifecycle is handled outside k6.

### Login Benchmark

```text
reset
seed base users/items
run k6/scripts/login.js
collect results
```

### Create Transaction Benchmark

```text
reset
seed base users/items
run k6/scripts/create-transaction.js
collect results
```

Transactions are created by k6 during the measured workload.

### Enriched Transactions Benchmark

```text
reset
seed base users/items
prepare enrichment transaction dataset
run k6/scripts/enriched-transactions.js
collect results
```

The enrichment preparation step is not measured as part of the k6 result.

### Mixed Workload Benchmark

```text
reset
seed base users/items
prepare enrichment transaction dataset when MIX_ENRICHED_TRANSACTIONS_WEIGHT > 0
run k6/scripts/mixed-workload.js
collect results
```

The default mixed workload includes an enriched-transactions branch. If that
branch weight is non-zero, the runner must prepare enrichment data first or the
scenario setup will fail intentionally.

---

## Seed Alignment

Default k6 data generation is aligned with the seed runner `benchmark`
dataset:

```text
benchmark-user-001@example.com
benchmark-user-002@example.com
...
password: Password123!
```

These defaults can be changed through environment variables.

```text
USER_EMAIL_PREFIX
USER_EMAIL_SEPARATOR
USER_EMAIL_PADDING
USER_EMAIL_DOMAIN
USER_PASSWORD
```

Default benchmark pattern:

```text
USER_COUNT=100
USER_EMAIL_PREFIX=benchmark-user
USER_EMAIL_SEPARATOR=-
USER_EMAIL_PADDING=3
USER_EMAIL_DOMAIN=example.com
USER_PASSWORD=Password123!
```

When `enriched-transactions.js` uses `ADMIN_USER_EMAIL` /
`ADMIN_USER_PASSWORD`, those credentials must still match a seeded benchmark
user. For the repository default benchmark dataset, the expected pair is:

```text
ADMIN_USER_EMAIL=benchmark-user-001@example.com
ADMIN_USER_PASSWORD=Password123!
```

If a particular run does not follow the default benchmark generator pattern,
provide an optional input file:

```text
USERS_FILE=./k6/data/users.sample.json
ITEM_IDS_FILE=./k6/data/item-ids.sample.json
```

Default deterministic item IDs use:

```text
00000000-0000-7000-8000-000000000001
00000000-0000-7000-8000-000000000002
...
```

This matches the seed runner `benchmark` item IDs.

If your seed runner exports item IDs, provide them through:

```text
ITEM_IDS_FILE=/path/to/item-ids.json
```

Supported item ID file shapes:

```json
["uuid-1", "uuid-2"]
```

```json
{
  "item_ids": ["uuid-1", "uuid-2"]
}
```

```json
{
  "items": [
    { "id": "uuid-1" },
    { "id": "uuid-2" }
  ]
}
```

---

## Profiles

Set `K6_PROFILE` to control the executor behavior.

| Profile | Behavior |
|---|---|
| `smoke` | fixed VUs and duration |
| `steady` | constant arrival rate |
| `ramp` | ramping arrival rate |
| `hpa` | staged load useful for observing HPA behavior |

Default:

```text
K6_PROFILE=steady
```

For final benchmark scenarios, use `steady` unless the experiment specifically evaluates HPA behavior.

`K6_PROFILE` is validated strictly. Unsupported profile names now fail fast
instead of silently falling back to the steady benchmark executor.

When `RAMP_STAGES_JSON` is provided, it must be valid JSON and contain a
non-empty array of `{target, duration}` objects. Invalid stage JSON now fails
fast instead of silently falling back to generated stages.

---

## Common Environment Variables

### Target

```text
BASE_URL
```

Examples:

```text
http://localhost:8080
http://monolith.monolith.svc.cluster.local:8080
http://api-gateway.msa.svc.cluster.local:8080
```

### Scenario identity

```text
RUN_ID
ATTEMPT
ARCHITECTURE
SCENARIO_NAME
DATASET
DATASET_VERSION
GIT_COMMIT
IMAGE_TAG
```

### Load configuration

```text
K6_PROFILE
TARGET_RPS
TEST_DURATION
TIME_UNIT
VUS
PRE_ALLOCATED_VUS
MAX_VUS
```

### Thresholds

```text
MAX_ERROR_RATE
MIN_CHECK_RATE
P90_THRESHOLD_MS
P95_THRESHOLD_MS
MAX_DROPPED_ITERATIONS
```

### Seed data

```text
USER_COUNT
USER_EMAIL_PREFIX
USER_EMAIL_SEPARATOR
USER_EMAIL_PADDING
USER_EMAIL_DOMAIN
USER_PASSWORD
USERS_FILE

ITEM_COUNT
ITEM_IDS_FILE
ITEM_ID_NAMESPACE
```

---

## Local Examples

If the target environment was seeded with the `benchmark` dataset, the login,
create-transaction, and enriched-transactions examples below work with the
default generated users and item IDs.

If the target environment was seeded with the `smoke` dataset, set
`DATASET=smoke` so k6 uses the built-in smoke fixtures that match the seed
runner.

For local Minikube verification, start with `TARGET_RPS=1`. That value is
small enough to validate end-to-end behavior without turning local CPU limits
or bcrypt-heavy login into false-negative threshold failures. Increase RPS only
after the local verification pass is green and the target environment has
enough headroom.

### Smoke

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=smoke.js \
DATASET=smoke \
K6_PROFILE=smoke \
ARCHITECTURE=monolith \
SCENARIO_NAME=smoke \
VUS=1 \
TEST_DURATION=30s \
./k6/runner/run-k6.sh
```

### Login

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=login.js \
ARCHITECTURE=monolith \
SCENARIO_NAME=login \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
./k6/runner/run-k6.sh
```

### Create Transaction

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=create-transaction.js \
ARCHITECTURE=monolith \
SCENARIO_NAME=create-transaction \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
TOKEN_POOL_SIZE=5 \
./k6/runner/run-k6.sh
```

### Enriched Transactions

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=enriched-transactions.js \
ARCHITECTURE=monolith \
SCENARIO_NAME=enriched-transactions \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
./k6/runner/run-k6.sh
```

---

## Kubernetes / EKS Usage

In Kubernetes, k6 should run as a Job.

Recommended operating modes:

- `Minikube validation mode`
  Use the same runner script and the same k6 image shape, but keep the flow
  lightweight: no S3 upload by default, and Kubernetes state collection stays
  optional.
- `EKS benchmark mode`
  Use the benchmark Job manifests under `deployments/k8s/benchmark/` with
  Datadog enabled, in-cluster DogStatsD, Kubernetes state collection, and S3
  upload enabled.

For Datadog tagging, this repository uses purpose-based environment values:

- `development` for local or Minikube validation runs
- `benchmark` for final EKS benchmark runs

Recommended environment variable reference:

| Variable | Purpose | Minikube validation mode | EKS benchmark mode |
|---|---|---|---|
| `BASE_URL` | target benchmark endpoint | Minikube ingress or service URL | in-cluster service or EKS ingress URL |
| `K6_SCRIPT` | selected scenario script | `login.js`, `create-transaction.js`, `enriched-transactions.js` | same as Minikube |
| `ARCHITECTURE` | benchmark architecture identity | `monolith` or `microservices` | `monolith` or `microservices` |
| `SCENARIO_NAME` | benchmark scenario label in metadata | `login`, `create-transaction`, `enriched-transactions` | same as Minikube |
| `TARGET_RPS` | target request rate | small validation value such as `1` | final benchmark target such as `1000`, `2500`, `5000` |
| `TEST_DURATION` | run duration | short duration such as `10s` or `30s` | measured benchmark duration such as `5m` |
| `PRE_ALLOCATED_VUS` | initial VU pool for arrival-rate executor | small validation value | benchmark-sized value |
| `MAX_VUS` | maximum VU pool | small validation value | benchmark-sized value |
| `DATADOG_ENABLED` | enable DogStatsD output and Datadog metadata | `true` when validating Datadog, otherwise `false` | `true` |
| `DATADOG_ENV` | Datadog environment tag | `development` | `benchmark` |
| `K6_STATSD_ADDR` | DogStatsD endpoint used by k6 | local or Minikube-reachable Agent endpoint | `datadog-agent.datadog.svc.cluster.local:8125` |
| `K6_STATSD_NAMESPACE` | metric prefix in Datadog | usually `k6` | usually `k6` |
| `K6_STATSD_ENABLE_TAGS` | include tags in DogStatsD output | usually `true` | `true` |
| `K6_STATSD_OUTPUT_TYPE` | k6 output adapter used for DogStatsD | usually `output-statsd` | usually `output-statsd` |
| `RUN_ID` | benchmark run identity | optional validation label | required final run label |
| `ATTEMPT` | attempt identity | optional validation label | required attempt label such as `attempt-01` |
| `S3_URI` | upload destination for result artifacts | empty by default | required S3 prefix for final benchmark |

Recommended node placement:

```yaml
nodeSelector:
  node-group: testing
```

Application pods should run on:

```yaml
nodeSelector:
  node-group: app
```

The EKS k6 runner image should be built from:

```text
k6/runner/Dockerfile
```

Recommended build command from the repository root:

```bash
docker build -f k6/runner/Dockerfile -t <account>.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/k6-runner:$IMAGE_TAG .
```

This image includes:

```text
k6
bash
gzip
jq
curl
aws-cli
kubectl
```

This allows the runner to:

- generate result files,
- inspect cluster state for troubleshooting or optional operator-driven checks,
- upload results to S3.

Recommended EKS manifests:

```text
deployments/k8s/benchmark/namespace.yaml
deployments/k8s/benchmark/k6-runner-rbac.yaml
deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml
deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml
deployments/k8s/benchmark/k6-runner-secret.example.yaml
```

Recommended in-cluster DogStatsD endpoint:

```text
datadog-agent.datadog.svc.cluster.local:8125
```

---

## Result Files

Each k6 execution should produce:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
result-status.json
k6-options.json
thresholds.json
```

When Datadog is enabled, also produce:

```text
datadog-time-window.json
```

Recommended S3 prefix:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

The S3 path is for navigation and overwrite prevention.

`metadata.json` is the source of truth for analysis.

`thresholds.json` is the primary source for `PASS` vs `OVERLOAD`, while
`result-status.json` records k6 exit code, S3 upload state, and artifact
presence for orchestration-level classification.

A benchmark attempt is only `PASS` when k6 exits with code `0`. Runtime exits
such as k6 `107` (script exception) must be treated as `INVALID` even if
partial artifacts or threshold files were uploaded.

`kubectl` is included for troubleshooting and optional cluster inspection during
benchmark operations, but the current runner does not collect separate
Kubernetes or HPA snapshot files automatically. HPA and runtime behavior are
instead interpreted from Datadog telemetry, attempt metadata, and the benchmark
scenario configuration.

---

## Rerun Policy

Every repeated attempt must use a new attempt ID and S3 prefix.

```text
attempt-01
attempt-02
attempt-03
```

Do not reuse a mutated database state from a previous k6 attempt.

For every measured attempt:

```text
reset
seed
optional prepare enrichment data
k6
upload results
```

### Automatic Attempt Detection

The suite runner automatically detects the next attempt number by inspecting
existing S3 artifacts. The detection uses per-RPS granularity:

```text
For each RPS level in the suite:
  - Find highest attempt in S3 for that (scenario, RPS) pair
  - Track the max attempt across all RPS

If ALL RPS levels have the max attempt:
  → return max + 1 (new run)

If ANY RPS level is missing the max attempt:
  → return max (continuation)
```

This allows resuming a failed suite run without creating unnecessary attempt
numbers. For example, if `enriched-transactions:1000,2500` completed as
attempt-01 but the suite failed before `5000,7500,10000`:

```text
Re-run with: enriched-transactions:1000,2500,5000,7500,10000
Detection: 5000,7500,10000rps have no attempt → continuation
Result: attempt-01 (same as the partial run)
```

To override automatic detection, pass `ATTEMPT` explicitly:

```text
ATTEMPT=attempt-01
```

---

## Important Notes

### Create Transaction

`create-transaction.js` sends the final OpenAPI payload shape:

```json
{
  "items": [
    {
      "item_id": "uuid",
      "amount": 1
    }
  ]
}
```

It does not send the older `item_ids` payload shape.

### Sync Items

`sync-items.js` sends the final OpenAPI sync shape:

```json
{
  "items": [
    {
      "id": "uuid",
      "name": "Benchmark Item 000001",
      "available_amount": 1000000
    }
  ]
}
```

Because `PUT /api/v1/items` is a full active item synchronization endpoint, run this scenario only in an isolated attempt after reset and seed.

The benchmark runners now support `sync-items` as an optional scenario name,
but it should stay outside the primary fixed/HPA matrix and be executed as its
own isolated suite or single-case run.

### Enriched Transactions

`enriched-transactions.js` expects transaction data to exist.

The scenario now performs dedicated setup traffic before the measured workload
starts:

- setup login when an admin token is not pre-supplied,
- setup probe to confirm enriched transaction data exists.

That setup traffic is tagged separately from the measured workload. The
scenario thresholds and summary output are scoped to workload-tagged enriched
transaction requests so setup traffic does not pollute the primary benchmark
artifacts.

Prepare the read dataset before running this script:

```text
reset
seed base users/items
prepare enrichment data
run enriched-transactions.js
```
