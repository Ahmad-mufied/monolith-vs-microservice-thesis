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
| `mixed-workload.js` | optional mixed traffic simulation |

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
DURATION
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
DURATION=30s \
./k6/runner/run-k6.sh
```

### Login

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=login.js \
ARCHITECTURE=monolith \
SCENARIO_NAME=login \
TARGET_RPS=1 \
DURATION=10s \
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
DURATION=10s \
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
DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
./k6/runner/run-k6.sh
```

---

## Kubernetes / EKS Usage

In Kubernetes, k6 should run as a Job.

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

This image includes:

```text
k6
bash
gzip
jq
curl
aws-cli
```

This allows the runner to generate result files and upload them to S3.

---

## Result Files

Each k6 execution should produce:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
```

Recommended S3 prefix:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

The S3 path is for navigation and overwrite prevention.

`metadata.json` is the source of truth for analysis.

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
