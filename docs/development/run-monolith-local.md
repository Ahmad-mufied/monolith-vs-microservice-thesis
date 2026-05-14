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
    ├── namespaces/local.yaml
    ├── local/postgres.yaml
    ├── local/db-bootstrap-job.yaml
    └── monolith/
        ├── migration-job.yaml
        ├── monolith.yaml
        └── ingress.yaml
scripts/
├── env-init-base.sh
├── env-init-monolith.sh
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
make env-init-monolith
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
  "message": "ok",
  "service": "monolith"
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

### 4. Sync Active Items

```bash
curl -s -X PUT http://localhost:8080/api/v1/items \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "name": "Benchmark Item A",
        "available_amount": 1000
      },
      {
        "name": "Benchmark Item B",
        "available_amount": 500
      }
    ]
  }' | jq
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

Capture one item id:

```bash
ITEM_ID=$(curl -s "http://localhost:8080/api/v1/items?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data[] | select(.name=="Benchmark Item A") | .id')

echo "$ITEM_ID"
```

### 6. Get Item Detail

```bash
curl -s "http://localhost:8080/api/v1/items/$ITEM_ID" \
  -H "Authorization: Bearer $TOKEN" | jq
```

### 7. Resync Items

```bash
curl -s -X PUT http://localhost:8080/api/v1/items \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "name": "Benchmark Item A Updated",
        "available_amount": 1500
      },
      {
        "name": "Benchmark Item B",
        "available_amount": 500
      }
    ]
  }' | jq
```

Because `PUT /api/v1/items` is a full active snapshot, active items omitted from
the payload are soft-deleted.

Refresh the item id after resync:

```bash
ITEM_ID=$(curl -s "http://localhost:8080/api/v1/items?limit=10&offset=0" \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data[] | select(.name=="Benchmark Item A Updated") | .id')

echo "$ITEM_ID"
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
DATABASE_URL=postgres://postgres:<generated-local-password>@postgres.local-database.svc.cluster.local:5432/mono_db?sslmode=disable
```

`env/db-bootstrap.env` must still contain:

```env
BOOTSTRAP_DATABASE_URL=postgres://postgres:<generated-local-password>@postgres.local-database.svc.cluster.local:5432/bootstrap?sslmode=disable
```

### 4. Create Kubernetes Secrets

```bash
make create-local-secrets
```

This command also rewrites the Kubernetes `monolith-env` Secret so the in-cluster
application uses the PostgreSQL Service DNS in namespace `local-database`.

Check:

```bash
kubectl get secret -n local-database
kubectl get secret -n mono
```

### 5. Deploy PostgreSQL

```bash
make minikube-deploy-postgres
```

This target automatically runs `make create-local-secrets` first.

It also synchronizes the in-cluster `postgres` user password after the pod
becomes Ready. This makes repeated local Minikube reruns more reliable when the
local env files are regenerated but the PostgreSQL data directory already
exists.

The sync step now sources fresh credentials from `env/postgres.env` and passes
them into the `kubectl exec` process, so it does not depend on the running
`postgres-0` pod still exposing up-to-date secret-backed environment values.

You normally do not need to run `make minikube-sync-postgres-password`
manually. It is an internal recovery step that is already executed by
`make minikube-deploy-postgres`.

PostgreSQL DNS inside the cluster:

```text
postgres.local-database.svc.cluster.local
```

### 6. Run DB Bootstrap Job

```bash
make minikube-db-bootstrap
```

This target now depends on `make minikube-deploy-postgres`, so the local
PostgreSQL pod is applied, waited, and password-synchronized before the
bootstrap Job runs.

Check logs:

```bash
kubectl logs job/db-bootstrap-job -n local-database
```

### 7. Run Monolith Migration Job

```bash
make minikube-migrate-monolith
```

This target now depends on `make minikube-db-bootstrap`, so the monolith
migration Job runs only after the bootstrap Job is complete.

Check logs:

```bash
kubectl logs job/monolith-migration-job -n mono
```

### 8. Deploy Monolith

```bash
make minikube-deploy-monolith
```

This target now depends on `make minikube-migrate-monolith`, so the Deployment
rolls out only after PostgreSQL, bootstrap, and schema migration have all
completed successfully.

Check status:

```bash
kubectl get pods -n mono
kubectl get svc -n mono
kubectl get hpa -n mono
kubectl get resourcequota -n mono
```

### 9. Run Monolith Data Lifecycle Only

Use these targets when you want to rebuild the benchmark dataset without
changing the monolith Deployment:

```bash
make minikube-reset-monolith-data
make minikube-seed-monolith-smoke
make minikube-seed-monolith-benchmark
```

These commands assume the PostgreSQL pod and monolith schema are already ready.
Use `make minikube-bootstrap-monolith-smoke` or
`make minikube-bootstrap-monolith-benchmark` when you need the full setup path.

### 10. Access Monolith

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

### Recommended full Minikube monolith sequence

```bash
make env-init-base
make env-init-monolith
make minikube-start
make minikube-load-monolith
make minikube-bootstrap-monolith-smoke
```

Choose `make minikube-bootstrap-monolith-smoke` for fast local verification.

Use `make minikube-bootstrap-monolith-benchmark` when you want the same lifecycle with the larger deterministic benchmark dataset for later load testing.

These bootstrap targets run:

- PostgreSQL deploy,
- password sync,
- bootstrap job,
- migration job,
- monolith data reset,
- monolith smoke or benchmark seed,
- monolith deployment rollout.

## Step Verification Checklist

Use the following checks to confirm each local step actually succeeded.

These commands use the original tools directly (`docker`, `minikube`,
`kubectl`, `goose`, `psql`) so the intent stays visible even when you later use
Makefile shortcuts.

### Docker Compose Verification

#### 1. Verify env initialization

Purpose:

```text
Confirm local env files exist before starting any container or migration.
```

Commands:

```bash
ls -l env/postgres.env env/monolith.env env/db-bootstrap.env
```

Success indicators:

- all three files exist,
- no `No such file or directory` error appears.

#### 2. Verify PostgreSQL container is running

Purpose:

```text
Confirm local PostgreSQL is up and reachable before running migrations.
```

Commands:

```bash
docker compose -f deployments/compose/docker-compose.db.yml ps
docker inspect --format='{{.State.Health.Status}}' skripsi-postgres
docker logs --tail=50 skripsi-postgres
```

Success indicators:

- service `postgres` is `running`,
- container health status is `healthy`,
- logs do not show repeated startup failure or authentication errors.

Optional database verification:

```bash
set -a
source env/postgres.env
set +a

export PGPASSWORD="$POSTGRES_PASSWORD"
psql -h localhost -U "$POSTGRES_USER" -d "${POSTGRES_DB:-bootstrap}" -c '\l'
```

Expected result:

- databases `bootstrap`, `mono_db`, `auth_db`, `item_db`, and
  `transaction_db` exist.

#### 3. Verify monolith migration completed

Purpose:

```text
Confirm schema objects were created in mono_db.
```

Commands:

```bash
set -a
source env/monolith.env
set +a

goose -dir monolith/migrations postgres "$MONO_DATABASE_URL" status
```

Success indicators:

- each migration in `monolith/migrations/` is marked as applied,
- there is no connection or SQL error.

Optional table verification:

```bash
set -a
source env/postgres.env
set +a

export PGPASSWORD="$POSTGRES_PASSWORD"
psql -h localhost -U "$POSTGRES_USER" -d mono_db -c '\dt'
```

Expected result:

- tables such as `users`, `items`, `transactions`, and `transaction_items`
  exist.

#### 4. Verify monolith container is serving traffic

Purpose:

```text
Confirm the monolith process started correctly and passed health checks.
```

Commands:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml ps
docker logs --tail=100 skripsi-monolith
curl -i http://localhost:8080/healthz
```

Success indicators:

- service `monolith` is `running`,
- logs do not show startup panic or database connection failure,
- `GET /healthz` returns `200 OK`.

### Minikube Verification

#### 1. Verify Minikube cluster is ready

Purpose:

```text
Confirm the local Kubernetes control plane and node are ready.
```

Commands:

```bash
minikube status
kubectl get nodes
kubectl get pods -A
```

Success indicators:

- `host`, `kubelet`, and `apiserver` are `Running`,
- at least one node is `Ready`.

#### 2. Verify monolith image exists inside Minikube Docker

Purpose:

```text
Confirm the local image was built into Minikube's Docker daemon before deploy.
```

Commands:

```bash
eval $(minikube docker-env)
docker image ls skripsi/monolith:local
```

Success indicators:

- image `skripsi/monolith:local` is listed.

#### 3. Verify local Kubernetes secrets were created

Purpose:

```text
Confirm Minikube runtime configuration was generated from the local env files.
```

Commands:

```bash
kubectl get secret -n local-database postgres-local-env db-bootstrap-env
kubectl get secret -n mono monolith-env
```

Success indicators:

- all three secrets exist,
- no `NotFound` error appears.

#### 4. Verify local PostgreSQL StatefulSet is ready

Purpose:

```text
Confirm in-cluster PostgreSQL and its persistent storage are ready.
```

Commands:

```bash
kubectl get pods -n local-database
kubectl get svc -n local-database postgres
kubectl get pvc -n local-database
kubectl describe pod postgres-0 -n local-database
```

Success indicators:

- pod `postgres-0` is `Running`,
- service `postgres` exists,
- PVC for PostgreSQL is `Bound`.

#### 5. Verify DB bootstrap job completed

Purpose:

```text
Confirm the application databases were created inside the cluster PostgreSQL.
```

Commands:

```bash
kubectl get job db-bootstrap-job -n local-database
kubectl logs job/db-bootstrap-job -n local-database
kubectl exec -n local-database postgres-0 -- sh -ec 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d "${POSTGRES_DB:-bootstrap}" -c "\l"'
```

Success indicators:

- job completion count is `1/1`,
- logs do not show SQL errors,
- databases `mono_db`, `auth_db`, `item_db`, and `transaction_db` exist.

#### 6. Verify monolith migration job completed

Purpose:

```text
Confirm the monolith schema exists inside in-cluster mono_db.
```

Commands:

```bash
kubectl get job monolith-migration-job -n mono
kubectl logs job/monolith-migration-job -n mono
kubectl exec -n local-database postgres-0 -- sh -ec 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d mono_db -c "\dt"'
```

Success indicators:

- job completion count is `1/1`,
- logs do not show Goose or SQL failure,
- monolith tables exist in `mono_db`.

#### 7. Verify monolith deployment is healthy

Purpose:

```text
Confirm the app is running, routable, and eligible for HPA observation.
```

Commands:

```bash
kubectl rollout status deployment/monolith -n mono
kubectl get pods -n mono
kubectl get svc -n mono
kubectl get hpa -n mono
kubectl logs deploy/monolith -n mono --tail=100
```

Success indicators:

- rollout completes successfully,
- pod is `Running` and `Ready`,
- service `monolith` exists,
- HPA object exists,
- logs do not show repeated crash loop or database connection failure.

#### 8. Verify external access works

Purpose:

```text
Confirm the monolith can be reached from the host after deployment.
```

Commands using port-forward:

```bash
kubectl port-forward svc/monolith -n mono 8080:8080
curl -i http://localhost:8080/healthz
```

Commands using ingress:

```bash
minikube tunnel
curl -i http://monolith.skripsi.local/healthz
```

Success indicators:

- `GET /healthz` returns `200 OK`,
- requests do not fail with connection refused or upstream timeout.

## Stop, Clean, And Data Persistence

The local Minikube and Docker Compose flows do not all behave the same when you
stop them.

Some commands only stop compute, while others also remove persistent data.

### Quick Rule

```text
Stop:
usually keep data

Delete / down -v / delete PVC:
remove data
```

### Command Effect Matrix

| Command | Scope | Keeps migration result? | Keeps CRUD data? | Notes |
|---|---|---|---|---|
| `minikube stop` | stop local cluster VM/container | Yes | Yes | Cluster is stopped, not deleted. StatefulSet PVC remains. |
| `minikube delete` | delete local cluster | No | No | Treat as full reset of local Kubernetes environment. |
| `docker compose -f deployments/compose/docker-compose.db.yml down` | stop Compose PostgreSQL without removing volume | Yes | Yes | Safe stop if you want to keep local Compose DB data. |
| `docker compose -f deployments/compose/docker-compose.db.yml down -v` | stop Compose PostgreSQL and remove named volume | No | No | Deletes Compose PostgreSQL persistent volume. |
| `docker compose -f deployments/compose/docker-compose.monolith.yml down` | stop monolith app container only | Yes | Yes | App stops, DB data remains in PostgreSQL. |
| `make compose-down` | stop all Compose stacks and remove volumes | No | No | Current target uses `down -v`, so local Compose DB data is deleted. |
| `kubectl delete job db-bootstrap-job -n local-database` | remove completed bootstrap job object | Yes | Yes | Deletes Job object only, not the created databases. |
| `kubectl delete job monolith-migration-job -n mono` | remove completed migration job object | Yes | Yes | Deletes Job object only, not the migrated schema. |
| `kubectl delete deployment monolith -n mono` | remove monolith pods | Yes | Yes | App stops, PostgreSQL data remains. |
| `kubectl scale deployment monolith -n mono --replicas=0` | stop monolith pods without deleting object | Yes | Yes | Useful if you want a reversible app-only stop. |
| `kubectl delete statefulset postgres -n local-database` | remove PostgreSQL pod controller | Usually yes | Usually yes | Data remains only if PVC is not deleted. |
| `kubectl delete pvc postgres-data-postgres-0 -n local-database` | delete PostgreSQL persistent volume claim | No | No | This removes the Minikube PostgreSQL data volume. |

### What Happens After Laptop Restart

#### Minikube

If the laptop restarts and you previously used:

```bash
minikube stop
```

or the machine shut down without deleting the Minikube profile:

- the cluster usually comes back with the same PVC,
- PostgreSQL data usually remains,
- completed migrations remain applied,
- CRUD data usually remains,
- you normally do not need to repeat bootstrap and migration from zero.

Recommended verification after restart:

```bash
minikube start --driver=docker --cpus=2 --memory=3072 --disk-size=20g
kubectl get pods -A
kubectl get pvc -n local-database
kubectl exec -n local-database postgres-0 -- sh -ec 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U "$POSTGRES_USER" -d mono_db -c "\dt"'
```

#### Docker Compose

If the laptop restarts while you are using Compose:

- named volumes usually remain on disk,
- Compose PostgreSQL data usually remains,
- monolith migration state remains if the volume was not deleted.

But if you later run:

```bash
make compose-down
```

the current Makefile uses `down -v`, which removes the Compose PostgreSQL
volume and deletes the local Compose data set.

## Recommended Stop And Cleanup Commands

Choose the command based on whether you want to preserve data or fully reset the
environment.

### A. Stop host access only

Purpose:

```text
Stop your local access tunnel, but keep the cluster and app running.
```

Commands:

```bash
# In the terminal running the command:
Ctrl+C

# Applies to:
kubectl port-forward svc/monolith -n mono 8080:8080
minikube tunnel
```

Effect:

- only the access tunnel stops,
- application and database keep running,
- no data is removed.

### B. Stop monolith app only, keep database and data

Purpose:

```text
Pause the application workload without deleting PostgreSQL data.
```

Commands:

```bash
kubectl scale deployment monolith -n mono --replicas=0
kubectl get pods -n mono
```

Restart command:

```bash
kubectl scale deployment monolith -n mono --replicas=1
kubectl rollout status deployment/monolith -n mono
```

Effect:

- monolith pod stops,
- database remains,
- migrations remain,
- CRUD data remains.

### C. Remove monolith workload objects, keep database and data

Purpose:

```text
Clean the app-side Kubernetes objects but preserve PostgreSQL state.
```

Commands:

```bash
kubectl delete ingress monolith -n mono --ignore-not-found
kubectl delete deployment monolith -n mono --ignore-not-found
kubectl delete service monolith -n mono --ignore-not-found
kubectl delete hpa monolith -n mono --ignore-not-found
```

Redeploy commands:

```bash
kubectl apply -f deployments/k8s/monolith/monolith.yaml
kubectl apply -f deployments/k8s/monolith/ingress.yaml
kubectl rollout status deployment/monolith -n mono
```

Effect:

- app workload is removed,
- PostgreSQL StatefulSet and PVC remain,
- data remains.

### D. Stop entire Minikube cluster, keep data

Purpose:

```text
Shut down local Kubernetes runtime without deleting its persistent state.
```

Commands:

```bash
minikube stop
minikube status
```

Restart commands:

```bash
minikube start --driver=docker --cpus=2 --memory=3072 --disk-size=20g
kubectl get nodes
kubectl get pvc -n local-database
```

Effect:

- cluster runtime stops,
- PVC remains,
- migrations remain,
- CRUD data remains.

### E. Full Minikube reset

Purpose:

```text
Delete the entire local Kubernetes cluster and start over from zero.
```

Commands:

```bash
minikube delete
```

Effect:

- cluster is removed,
- local Kubernetes data is treated as lost,
- you should rerun the full Minikube setup flow from the beginning.

### F. Safe Compose stop, keep data

Purpose:

```text
Stop local Compose containers without deleting the PostgreSQL volume.
```

Commands:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml down
docker compose -f deployments/compose/docker-compose.db.yml down
```

Effect:

- containers stop,
- named volume remains,
- migrations remain,
- CRUD data remains.

### G. Full Compose reset

Purpose:

```text
Stop Compose containers and remove the local PostgreSQL volume.
```

Commands:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml down -v
docker compose -f deployments/compose/docker-compose.db.yml down -v
```

Equivalent current shortcut:

```bash
make compose-down
```

Effect:

- containers stop,
- named volume is removed,
- migrations are lost from the Compose database,
- CRUD data is lost from the Compose database.

## When You Must Repeat All Steps From The Beginning

You should assume a full rerun is required when one of the following happens:

- you ran `minikube delete`,
- you deleted the PostgreSQL PVC in namespace `local-database`,
- you ran Compose teardown with `down -v`,
- you manually removed the local Docker volume used by Compose PostgreSQL.

In those cases, repeat:

```text
env-init-monolith
start database
bootstrap database if needed
run migration
deploy monolith
verify health
```
