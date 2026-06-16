# Run Microservices Locally

Use this document to run the microservices architecture locally for manual
integration testing.

The local MSA flow supports:

- Docker Compose PostgreSQL,
- Docker Compose for the MSA application stack,
- optional `go run` for each service process when debugging from the host,
- API Gateway as the only external REST entry point,
- gRPC between API Gateway and internal services.

Use Docker Compose when you want to validate local deployment behavior. Use
`go run` when you want faster service-by-service debugging.

## 1. Runtime Layout

Local ports:

| Component | Protocol | Port | Public entry point |
|---|---:|---:|---|
| API Gateway | HTTP REST | `8080` | yes |
| Auth Service | gRPC | `50051` | no |
| Item Service | gRPC | `50052` | no |
| Transaction Service | gRPC | `50053` | no |
| PostgreSQL | PostgreSQL | `5432` | local only |

Local databases:

| Component | Database |
|---|---|
| Auth Service | `auth_db` |
| Item Service | `item_db` |
| Transaction Service | `transaction_db` |
| API Gateway | no database |

Important:

- stop the monolith app before using API Gateway on port `8080`,
- keep the Compose PostgreSQL container running,
- do not run monolith and MSA tests against the same external port at the same time.

## 2. Stop Monolith, Keep PostgreSQL

If the monolith app was started with Docker Compose:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml down
```

If the monolith app was started with `make run-monolith`, stop that terminal
with `Ctrl+C`.

Keep PostgreSQL running:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected PostgreSQL container:

```text
skripsi-postgres
```

## 3. Generate Local Env Files

First create the base local env files:

```bash
make env-init-base
```

Then create MSA-specific env files:

```bash
make env-init-microservices
```

Generated local files:

```text
env/api-gateway.env
env/auth-service.env
env/item-service.env
env/transaction-service.env
env/api-gateway.compose.env
env/auth-service.compose.env
env/item-service.compose.env
env/transaction-service.compose.env
```

These files are ignored by Git because they contain local secrets and database
URLs.

## 4. Env File Contents

### API Gateway

File:

```text
env/api-gateway.env
```

Expected keys:

```env
HTTP_PORT=8080
JWT_SECRET=<same-local-secret-as-auth-service>
AUTH_SERVICE_ADDR=localhost:50051
ITEM_SERVICE_ADDR=localhost:50052
TRANSACTION_SERVICE_ADDR=localhost:50053
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_READ_HEADER_TIMEOUT=5s
HTTP_READ_TIMEOUT=15s
HTTP_WRITE_TIMEOUT=40s
HTTP_IDLE_TIMEOUT=60s
HTTP_SHUTDOWN_TIMEOUT=10s
```

### Auth Service

File:

```text
env/auth-service.env
```

Expected keys:

```env
GRPC_PORT=50051
DATABASE_URL=postgres://postgres:<password>@localhost:5432/auth_db?sslmode=disable
AUTH_DATABASE_URL=postgres://postgres:<password>@localhost:5432/auth_db?sslmode=disable
JWT_SECRET=<same-local-secret-as-api-gateway>
JWT_EXPIRY=24h
BCRYPT_COST=10
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_REQUEST_TIMEOUT=30s
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=2
LOGIN_QUEUE_TIMEOUT=2s
```

`DATABASE_URL` is used by the service process.

`AUTH_DATABASE_URL` is used by local migration commands.

### Item Service

File:

```text
env/item-service.env
```

Expected keys:

```env
GRPC_PORT=50052
DATABASE_URL=postgres://postgres:<password>@localhost:5432/item_db?sslmode=disable
ITEM_DATABASE_URL=postgres://postgres:<password>@localhost:5432/item_db?sslmode=disable
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_REQUEST_TIMEOUT=30s
```

### Transaction Service

File:

```text
env/transaction-service.env
```

Expected keys:

```env
GRPC_PORT=50053
DATABASE_URL=postgres://postgres:<password>@localhost:5432/transaction_db?sslmode=disable
TRANSACTION_DATABASE_URL=postgres://postgres:<password>@localhost:5432/transaction_db?sslmode=disable
ITEM_SERVICE_ADDR=localhost:50052
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_REQUEST_TIMEOUT=30s
ITEM_VALIDATION_TIMEOUT=25s
```

### API Gateway

File:

```text
env/api-gateway.env
```

Expected keys:

```env
HTTP_PORT=8080
JWT_SECRET=<same-local-secret-as-auth-service>
AUTH_SERVICE_ADDR=localhost:50051
ITEM_SERVICE_ADDR=localhost:50052
TRANSACTION_SERVICE_ADDR=localhost:50053
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s
```

Transaction Service calls Item Service over gRPC for transaction item
validation.

## 4.1 Local timeout policy

The local microservices flow now uses an explicit timeout chain:

```text
outbound gRPC call deadline (default 32s)
    <
API Gateway request deadline (default 35s)
    <
API Gateway HTTP write timeout (default 40s)

service-side gRPC request deadline (default 30s)
    <
API Gateway outbound gRPC call deadline (default 32s)

Transaction Service item validation deadline (default 25s)
    <
service-side gRPC request deadline (default 30s)
```

Meaning:

- `GRPC_CALL_TIMEOUT` is the per-call application deadline used by API Gateway
  for every outbound gRPC request to Auth, Item, and Transaction Service.
- `REQUEST_TIMEOUT` is the API Gateway's overall HTTP request deadline.
  If this budget expires before the upstream gRPC response is translated back
  to HTTP, the client also observes a `503`.
- `GRPC_REQUEST_TIMEOUT` is the per-request server-side deadline enforced by
  Auth Service, Item Service, and Transaction Service for incoming unary gRPC
  requests.
- `ITEM_VALIDATION_TIMEOUT` is the per-call deadline used by Transaction
  Service when it calls Item Service for transaction item validation.
- Auth Service login admission control bounds concurrent bcrypt comparisons.
  Requests wait up to `LOGIN_QUEUE_TIMEOUT`; when no slot is available, Auth
  Service returns gRPC `ResourceExhausted`, and API Gateway maps it to `503`.
- `DIAGNOSTIC_LOGGING_ENABLED=true` enables failure-only structured diagnostic
  events in API Gateway and the backend services. Keep it `false` for ordinary
  runs and enable it only for focused RCA.
- `HTTP_WRITE_TIMEOUT` must remain larger than `REQUEST_TIMEOUT` so API Gateway
  can translate dependency deadline or overload failures into a proper `503`
  response before the transport layer closes the connection.

Observed error semantics:

- `499`: the caller canceled or disconnected before the request completed
- `503`: an application-managed upstream dependency deadline was exceeded, or
  the API Gateway `REQUEST_TIMEOUT` budget expired, or login admission control
  rejected overload with `ResourceExhausted`

## 5. Run Migrations

Run all MSA migrations:

```bash
make migrate-microservices-local
```

Equivalent manual commands:

```bash
set -a
source env/auth-service.env
source env/item-service.env
source env/transaction-service.env
set +a

goose -dir microservices/auth-service/migrations postgres "$AUTH_DATABASE_URL" up
goose -dir microservices/item-service/migrations postgres "$ITEM_DATABASE_URL" up
goose -dir microservices/transaction-service/migrations postgres "$TRANSACTION_DATABASE_URL" up
```

Check migration status:

```bash
set -a
source env/auth-service.env
source env/item-service.env
source env/transaction-service.env
set +a

goose -dir microservices/auth-service/migrations postgres "$AUTH_DATABASE_URL" status
goose -dir microservices/item-service/migrations postgres "$ITEM_DATABASE_URL" status
goose -dir microservices/transaction-service/migrations postgres "$TRANSACTION_DATABASE_URL" status
```

## 6. Start Services With Docker Compose

Start the MSA application stack:

```bash
make compose-microservices-up
```

Equivalent command:

```bash
docker compose -f deployments/compose/docker-compose.microservices.yml up --build
```

Started containers:

```text
skripsi-auth-service
skripsi-item-service
skripsi-transaction-service
skripsi-api-gateway
```

The API Gateway is exposed at:

```text
http://localhost:8080
```

## 7. Alternative: Start Services With Go Run

Use four separate terminals.

Start Auth Service:

```bash
make run-auth-service-local
```

Expected log:

```text
auth-service gRPC listening on :50051
```

Start Item Service:

```bash
make run-item-service-local
```

Expected log:

```text
item-service gRPC listening on :50052
```

Start Transaction Service:

```bash
make run-transaction-service-local
```

Expected log:

```text
transaction-service gRPC listening on :50053
```

Start API Gateway:

```bash
make run-api-gateway-local
```

Expected log:

```text
api-gateway HTTP listening on :8080
```

## 8. Health Check

Endpoint:

- `GET /healthz`

Request:

```bash
curl -i http://localhost:8080/healthz
```

Expected result:

- HTTP `200 OK`
- response body contains:
  - `message: "ok"`
  - `service: "api-gateway"`
  - `timestamp`

## 9. Manual Integration Test Flow

Set base URL:

```bash
BASE_URL="http://localhost:8080"
TOKEN=""
ITEM_ID=""
TRANSACTION_ID=""
```

### 9.1 Register User

```bash
curl -i -X POST "$BASE_URL/api/v1/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "MSA Manual User",
    "email": "msa-manual@example.com",
    "password": "password123"
  }'
```

SQL check in `auth_db`:

```bash
set -a
source env/auth-service.env
set +a

psql "$AUTH_DATABASE_URL" -c "
SELECT id, name, email, password_hash IS NOT NULL AS has_password_hash, created_at, updated_at
FROM users
WHERE lower(email) = 'msa-manual@example.com';
"
```

### 9.2 Login User

```bash
TOKEN=$(curl -s -X POST "$BASE_URL/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{
    "email": "msa-manual@example.com",
    "password": "password123"
  }' | jq -r '.data.token')

echo "$TOKEN"
```

Expected result:

- token is not empty,
- token can be used against protected routes.

### 9.3 Sync Active Items

```bash
curl -i -X PUT "$BASE_URL/api/v1/items" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "name": "MSA Item A",
        "available_amount": 1000
      },
      {
        "name": "MSA Item B",
        "available_amount": 500
      }
    ]
  }'
```

SQL check in `item_db`:

```bash
set -a
source env/item-service.env
set +a

psql "$ITEM_DATABASE_URL" -c "
SELECT id, name, available_amount, deleted_at, created_at, updated_at
FROM items
WHERE lower(name) IN ('msa item a', 'msa item b')
ORDER BY name;
"
```

### 9.4 List Active Items

```bash
curl -s "$BASE_URL/api/v1/items?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

Capture an item id:

```bash
ITEM_ID=$(curl -s "$BASE_URL/api/v1/items?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data[] | select(.name=="MSA Item A") | .id')

echo "$ITEM_ID"
```

### 9.5 Get Item Detail

```bash
curl -s "$BASE_URL/api/v1/items/$ITEM_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 9.6 Create Transaction

```bash
TRANSACTION_ID=$(curl -s -X POST "$BASE_URL/api/v1/transactions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"items\": [
      {
        \"item_id\": \"$ITEM_ID\",
        \"amount\": 2
      }
    ]
  }" | jq -r '.data.id')

echo "$TRANSACTION_ID"
```

SQL check in `transaction_db`:

```bash
set -a
source env/transaction-service.env
set +a

psql "$TRANSACTION_DATABASE_URL" -c "
SELECT id, user_id, status, created_at, updated_at
FROM transactions
WHERE id = '$TRANSACTION_ID'::uuid;
"

psql "$TRANSACTION_DATABASE_URL" -c "
SELECT transaction_id, item_id, amount, created_at, updated_at
FROM transaction_items
WHERE transaction_id = '$TRANSACTION_ID'::uuid
ORDER BY item_id;
"
```

Check that Item Service did not deduct `available_amount`:

```bash
set -a
source env/item-service.env
set +a

psql "$ITEM_DATABASE_URL" -c "
SELECT id, name, available_amount
FROM items
WHERE id = '$ITEM_ID'::uuid;
"
```

Expected result:

- transaction rows exist in `transaction_db`,
- item row exists in `item_db`,
- `available_amount` remains unchanged.

### 9.7 List Own Transactions

```bash
curl -s "$BASE_URL/api/v1/transactions?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 9.8 Get Transaction Detail

```bash
curl -s "$BASE_URL/api/v1/transactions/$TRANSACTION_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 9.9 Get Enriched Transactions

```bash
curl -s "$BASE_URL/api/v1/admin/transactions?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

Expected behavior:

- API Gateway asks Transaction Service for raw transaction data,
- API Gateway asks Auth Service for user summaries,
- API Gateway asks Item Service for item summaries,
- API Gateway enriches the final REST response in memory.

## 10. Negative Test Examples

Missing auth header:

```bash
curl -i "$BASE_URL/api/v1/items"
```

Wrong password:

```bash
curl -i -X POST "$BASE_URL/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{
    "email": "msa-manual@example.com",
    "password": "wrong-password"
  }'
```

Invalid item id:

```bash
curl -i -X POST "$BASE_URL/api/v1/transactions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "item_id": "not-a-uuid",
        "amount": 1
      }
    ]
  }'
```

Amount above availability:

```bash
curl -i -X POST "$BASE_URL/api/v1/transactions" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"items\": [
      {
        \"item_id\": \"$ITEM_ID\",
        \"amount\": 999999
      }
    ]
  }"
```

## 11. Stop Local MSA

For Docker Compose MSA:

```bash
docker compose -f deployments/compose/docker-compose.microservices.yml down
```

For `go run` MSA, stop each service process with `Ctrl+C` in its terminal.

Keep PostgreSQL running if you want to inspect data.

If you want to clean all local Compose data, use:

```bash
make compose-down
```

Important:

- `make compose-down` uses `down -v`,
- it removes the local PostgreSQL volume,
- it destroys local `mono_db`, `auth_db`, `item_db`, and `transaction_db` data.

## 12. Troubleshooting

### Port 8080 already in use

Most likely the monolith app is still running.

Stop monolith first, then rerun:

```bash
make run-api-gateway-local
```

### Missing env file

Run:

```bash
make env-init-microservices
```

### Migration cannot connect

Check PostgreSQL is running:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Check the generated env URLs:

```bash
sed -n '1,120p' env/auth-service.env
sed -n '1,120p' env/item-service.env
sed -n '1,120p' env/transaction-service.env
```

### API Gateway returns upstream errors

Check all gRPC services are running:

```bash
ss -ltnp | rg '50051|50052|50053|8080'
```

Also check the service address values in:

```text
env/api-gateway.env
env/transaction-service.env
```

## 13. Minikube Local Kubernetes

Use this path when you want to validate the microservices stack on local
Kubernetes instead of Docker Compose.

### Canonical smoke flow

```bash
make env-init-base
make env-init-microservices
make minikube-start
make minikube-load-microservices
make minikube-bootstrap-microservices-smoke
make minikube-port-forward-api-gateway
```

This flow will:

- create local PostgreSQL and DB bootstrap secrets,
- create `msa` service secrets,
- run `db-bootstrap-job`,
- run `auth-migration-job`, `item-migration-job`, and `transaction-migration-job`,
- reset the three microservices databases,
- seed the smoke dataset,
- deploy `auth-service`, `item-service`, `transaction-service`, and `api-gateway`,
- apply namespace `ResourceQuota` and per-service HPA.

From another terminal:

```bash
curl -i http://localhost:8080/healthz
```

### Canonical benchmark-prep flow

```bash
make env-init-base
make env-init-microservices
make minikube-start
make minikube-load-microservices
make minikube-bootstrap-microservices-benchmark
```

Use the smoke flow for fast local verification.

Use the benchmark-prep flow when you want the larger deterministic dataset for later load testing.

For local k6 end-to-end runs, prefer the benchmark-prep flow because the
default k6 login/create/enriched examples align with the benchmark dataset.

Use the smoke flow for fast API validation, or run `smoke.js` with
`DATASET=smoke`.

### Access via ingress

Start the Minikube tunnel:

```bash
minikube tunnel
```

Add to `/etc/hosts`:

```text
127.0.0.1 api.skripsi.local
```

Then access:

```bash
curl -i http://api.skripsi.local/healthz
```

### Manual seed and reset targets

If you need to rerun only the data lifecycle without rebuilding the app stack:

```bash
make minikube-reset-microservices-data
make minikube-seed-microservices-smoke
make minikube-seed-microservices-benchmark
make minikube-prepare-microservices-enrichment-smoke
make minikube-prepare-microservices-enrichment-benchmark
```

These commands assume the shared PostgreSQL pod and microservices schemas are
already ready. Use `make minikube-bootstrap-microservices-smoke` or
`make minikube-bootstrap-microservices-benchmark` when you need the full setup
path for login or create-transaction flows. Use
`make minikube-bootstrap-microservices-enrichment-benchmark` when you want the
full read-benchmark path, including enrichment preparation.

For the `enriched-transactions` benchmark, run the preparation target after the
matching base seed:

```bash
make minikube-seed-microservices-benchmark
make minikube-prepare-microservices-enrichment-benchmark
```

Smoke dataset intent:

- small deterministic data for local verification,
- fast login / item sync / transaction smoke tests.

Benchmark dataset intent:

- larger deterministic data for later load-test preparation,
- same dataset shape on every rerun.

If you want the full schema-to-deploy flow for read benchmarking, use
`make minikube-bootstrap-microservices-enrichment-benchmark`.

### k6 after port-forward

After `make minikube-port-forward-api-gateway`, run k6 from another terminal.

If you rerun any bootstrap or deploy target, start
`make minikube-port-forward-api-gateway` again before the next k6 command.
Deployment rollout replaces the backing pod, so the old port-forward session
disconnects even when the Service name stays the same.

For smoke validation:

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=smoke.js \
DATASET=smoke \
K6_PROFILE=smoke \
ARCHITECTURE=microservices \
SCENARIO_NAME=smoke \
VUS=1 \
TEST_DURATION=30s \
./k6/runner/run-k6.sh
```

For local benchmark verification, start with a low arrival rate:

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=login.js \
DATASET=benchmark \
ARCHITECTURE=microservices \
SCENARIO_NAME=login \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
./k6/runner/run-k6.sh
```

The same local verification baseline works for the other benchmark scripts:

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=create-transaction.js \
DATASET=benchmark \
ARCHITECTURE=microservices \
SCENARIO_NAME=create-transaction \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
TOKEN_POOL_SIZE=5 \
./k6/runner/run-k6.sh
```

```bash
BASE_URL=http://localhost:8080 \
K6_SCRIPT=enriched-transactions.js \
DATASET=benchmark \
ARCHITECTURE=microservices \
SCENARIO_NAME=enriched-transactions \
TARGET_RPS=1 \
TEST_DURATION=10s \
PRE_ALLOCATED_VUS=2 \
MAX_VUS=4 \
./k6/runner/run-k6.sh
```
