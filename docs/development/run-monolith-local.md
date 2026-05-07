# Run Monolith Locally

Use two local validation layers:

1. Docker Compose for the fastest manual end-to-end test.
2. Minikube after Compose works, to validate Kubernetes objects.

Do not start with Minikube when the immediate goal is debugging CRUD and
transaction behavior. Compose has a shorter feedback loop.

## Prerequisites

Required tools:

- Docker with Docker Compose v2
- Go
- Goose CLI for host-side migrations
- `curl`
- `jq`

Optional for Kubernetes validation:

- Minikube
- kubectl

Install Goose when needed:

```bash
go install github.com/pressly/goose/v3/cmd/goose@v3.27.1
```

## Repository Layout

Relevant local runtime files:

```text
openapi.yaml
Makefile
go.work
env/
monolith/
├── Dockerfile
├── cmd/server/main.go
└── migrations/
deployments/
├── compose/
│   ├── docker-compose.db.yml
│   ├── docker-compose.monolith.yml
│   └── initdb/001-create-databases.sql
└── k8s/
    ├── namespaces/benchmark.yaml
    ├── local/postgres.yaml
    ├── local/db-bootstrap-job.yaml
    └── monolith/
        ├── migration-job.yaml
        ├── monolith.yaml
        └── ingress.yaml
scripts/
├── env-init.sh
└── create-local-secrets.sh
```

## Kubernetes Local Security Hardening Baseline

The local Kubernetes manifests now include an explicit security baseline to
avoid permissive runtime defaults and reduce accidental privilege exposure
during local validation.

### Security objectives

1. Ensure workloads run as non-root by default.
2. Block Linux privilege escalation where not required.
3. Drop default Linux capabilities.
4. Use the runtime default seccomp profile explicitly.
5. Keep behavior compatible with local development flow (bootstrap, migration,
   and monolith startup).

### Baseline controls used

- `runAsNonRoot: true` (pod/container level where applicable)
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

### Applied manifests and intent

| Manifest | Hardened scope | Notes |
|---|---|---|
| `deployments/k8s/local/db-bootstrap-job.yaml` | Pod + container securityContext | One-shot job; uses read-only root filesystem. |
| `deployments/k8s/monolith/migration-job.yaml` | Pod + container securityContext | One-shot migration execution; uses read-only root filesystem. |
| `deployments/k8s/monolith/monolith.yaml` | Pod + container securityContext | Long-running app workload; hardened runtime defaults. |
| `deployments/k8s/local/postgres.yaml` | Pod + container securityContext | Uses explicit UID/GID/fsGroup and seccomp; `readOnlyRootFilesystem` remains `false` due to PostgreSQL runtime write needs. |

### Why this matters for local runs

- Keeps local manifests closer to production hardening expectations.
- Reduces noisy scanner findings from default security contexts.
- Documents intentional exceptions (for example, PostgreSQL writable runtime
  paths) instead of relying on implicit defaults.

The OpenAPI source of truth is:

```text
openapi.yaml
```

## Docker Compose

### 1. Generate Local Env Files

```bash
make env-init
```

This creates ignored local files:

```text
env/postgres.env
env/monolith.env
env/db-bootstrap.env
```

Expected `env/postgres.env`:

```env
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<generated-local-password>
POSTGRES_DB=bootstrap
```

Expected Compose values in `env/monolith.env`:

```env
APP_ENV=local
APP_PORT=8080
SERVICE_NAME=monolith
DATABASE_URL=postgres://postgres:<generated-local-password>@postgres:5432/mono_db?sslmode=disable
MONO_DATABASE_URL=postgres://postgres:<generated-local-password>@localhost:5432/mono_db?sslmode=disable
DB_POOL_MAX_CONNS=25
DB_POOL_MIN_CONNS=2
DB_POOL_MAX_CONN_LIFETIME=5m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s
HTTP_READ_HEADER_TIMEOUT=5s
HTTP_READ_TIMEOUT=15s
HTTP_WRITE_TIMEOUT=30s
HTTP_IDLE_TIMEOUT=60s
HTTP_SHUTDOWN_TIMEOUT=10s
HTTP_MAX_HEADER_BYTES=1048576
JWT_SECRET=<generated-local-secret>
DATADOG_ENABLED=false
```

`DATABASE_URL` is used inside the monolith container. The hostname is the
Compose service name: `postgres`.

`MONO_DATABASE_URL` is used by host-side migration commands. The hostname is
`localhost`.

The DB pool values control `pgxpool` per monolith pod or process. With the
current HPA cap of 4 monolith replicas, `DB_POOL_MAX_CONNS=25` means the
application can open up to roughly 100 database connections in total during
scale-out.

The HTTP server values control request and connection timeouts for the monolith
process. They keep slow or idle clients from holding resources too long and
define how long graceful shutdown may wait for in-flight requests.

Meaning of each HTTP setting:

- `HTTP_READ_HEADER_TIMEOUT=5s`
  Limits how long the server waits to receive the request headers. This helps
  protect the process from very slow clients that open a connection but send
  headers too slowly.

- `HTTP_READ_TIMEOUT=15s`
  Limits the total time allowed to read the full request, including the body.
  This prevents a request from occupying a connection indefinitely while still
  allowing normal API payloads to arrive comfortably.

- `HTTP_WRITE_TIMEOUT=30s`
  Limits how long the server may spend writing the response. This keeps a slow
  downstream client from holding a response connection open for too long.

- `HTTP_IDLE_TIMEOUT=60s`
  Controls how long keep-alive connections may stay idle before the server
  closes them. This helps reclaim resources from clients that are no longer
  actively sending requests.

- `HTTP_SHUTDOWN_TIMEOUT=10s`
  Controls how long graceful shutdown waits for in-flight requests to finish
  before the server stops. This is used during pod termination and local
  process shutdown.

- `HTTP_MAX_HEADER_BYTES=1048576`
  Caps the total size of HTTP request headers at 1 MiB. This makes the default
  limit explicit and avoids unusually large headers consuming excessive memory.

### 2. Start PostgreSQL

```bash
make compose-db-up
```

Or directly:

```bash
docker compose -f deployments/compose/docker-compose.db.yml up --build
```

The first startup runs:

```text
deployments/compose/initdb/001-create-databases.sql
```

It creates:

```text
mono_db
auth_db
item_db
transaction_db
```

The current monolith uses only `mono_db`.

### 3. Run Monolith Migration

In another terminal:

```bash
make migrate-monolith-local
```

Check migration status:

```bash
goose -dir monolith/migrations postgres "$MONO_DATABASE_URL" status
```

### 4. Start Monolith

```bash
make compose-monolith-up
```

Or directly:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml up --build
```

The app is exposed at:

```text
http://localhost:8080
```

Check logs:

```bash
docker logs -f skripsi-monolith
```

## Manual End-to-End Test

### 1. Health Check

```bash
curl -i http://localhost:8080/healthz
```

Expected body includes:

```json
{
  "status": "ok"
}
```

### 2. Register User

```bash
curl -i -X POST http://localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Test User",
    "email": "test@example.com",
    "password": "password123"
  }'
```

Expected status:

```text
201 Created
```

### 3. Login User

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"test@example.com","password":"password123"}' \
  | jq -r '.data.token')

echo "$TOKEN"
```

### 4. Create Item

```bash
ITEM_ID=$(curl -s -X POST http://localhost:8080/api/v1/items \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Benchmark Item A",
    "available_amount": 1000
  }' | jq -r '.data.id')

echo "$ITEM_ID"
```

Item availability uses:

```json
{
  "available_amount": 1000
}
```

It does not use `amount`. The `amount` field is used by transaction items.

### 5. List Items

```bash
curl -s "http://localhost:8080/api/v1/items?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 6. Get Item Detail

```bash
curl -s "http://localhost:8080/api/v1/items/$ITEM_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 7. Update Item

```bash
curl -s -X PUT "http://localhost:8080/api/v1/items/$ITEM_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Benchmark Item A Updated",
    "available_amount": 1500
  }' | jq
```

### 8. Create Transaction

```bash
TRANSACTION_ID=$(curl -s -X POST http://localhost:8080/api/v1/transactions \
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

Transaction item allocation uses:

```json
{
  "amount": 2
}
```

Meaning:

```text
Item.available_amount      -> amount available on the item
TransactionItem.amount     -> amount used by the transaction
```

### 9. List Own Transactions

```bash
curl -s "http://localhost:8080/api/v1/transactions?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 10. Get Transaction Detail

```bash
curl -s "http://localhost:8080/api/v1/transactions/$TRANSACTION_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 11. List Enriched Transactions

```bash
curl -s "http://localhost:8080/api/v1/admin/transactions?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" | jq
```

For the monolith, this endpoint uses database joins in one database.

## Minikube

Move to Minikube only after Compose works.

### 1. Start Minikube

```bash
make minikube-start
```

Equivalent manual commands:

```bash
minikube start --driver=docker --cpus=2 --memory=3072 --disk-size=20g
minikube addons enable ingress
minikube addons enable metrics-server
```

If Docker has more memory available, you can override the Makefile defaults:

```bash
make minikube-start MINIKUBE_CPUS=4 MINIKUBE_MEMORY=6144
```

### 2. Build and Load Monolith Image

```bash
make minikube-load-monolith
```

Equivalent manual commands:

```bash
eval $(minikube docker-env)
docker build -t skripsi/monolith:local -f monolith/Dockerfile .
```

### 3. Configure Minikube Secret Inputs

Do not manually rewrite `env/monolith.env` before Minikube deploy.

Keep the local Compose value:

```env
DATABASE_URL=postgres://postgres:<generated-local-password>@postgres:5432/mono_db?sslmode=disable
```

`make create-local-secrets` will automatically generate the Kubernetes
`monolith-env` Secret with:

```env
DATABASE_URL=postgres://postgres:<generated-local-password>@postgres.benchmark.svc.cluster.local:5432/mono_db?sslmode=disable
```

`env/db-bootstrap.env` must still contain:

```env
BOOTSTRAP_DATABASE_URL=postgres://postgres:<generated-local-password>@postgres.benchmark.svc.cluster.local:5432/bootstrap?sslmode=disable
```

### 4. Create Kubernetes Secrets

```bash
make create-local-secrets
```

This command also rewrites the Kubernetes `monolith-env` Secret so the in-cluster
application uses the PostgreSQL Service DNS in namespace `benchmark`.

Check:

```bash
kubectl get secret -n benchmark
kubectl get secret -n mono
```

### 5. Deploy PostgreSQL

```bash
make minikube-deploy-postgres
```

This target automatically runs `make create-local-secrets` first.

PostgreSQL DNS inside the cluster:

```text
postgres.benchmark.svc.cluster.local
```

### 6. Run DB Bootstrap Job

```bash
make minikube-db-bootstrap
```

This target also refreshes local Kubernetes Secrets before creating the Job.

Check logs:

```bash
kubectl logs job/db-bootstrap-job -n benchmark
```

### 7. Run Monolith Migration Job

```bash
make minikube-migrate-monolith
```

This target refreshes the Kubernetes Secret first, then creates the migration
Job.

Check logs:

```bash
kubectl logs job/monolith-migration-job -n mono
```

### 8. Deploy Monolith

```bash
make minikube-deploy-monolith
```

This target refreshes the Kubernetes Secret first, then rolls out the
Deployment.

Check status:

```bash
kubectl get pods -n mono
kubectl get svc -n mono
kubectl get hpa -n mono
```

### 9. Access Monolith

Use port-forward for the simplest local test:

```bash
make minikube-port-forward-monolith
```

This target runs in the foreground. Open it in a dedicated terminal and leave it
running while you test the API.

Equivalent manual command:

```bash
kubectl port-forward svc/monolith -n mono 8080:8080
```

Then from another terminal:

```bash
curl -i http://localhost:8080/healthz
```

If local port `8080` is already in use, override it:

```bash
make minikube-port-forward-monolith MONOLITH_PORT=18080
curl -i http://localhost:18080/healthz
```

Or use ingress:

```bash
minikube tunnel
```

Add to `/etc/hosts`:

```text
127.0.0.1 monolith.skripsi.local
```

Then:

```bash
curl -i http://monolith.skripsi.local/healthz
```
