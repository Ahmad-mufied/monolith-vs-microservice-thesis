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
go install github.com/pressly/goose/v3/cmd/goose@latest
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
JWT_SECRET=<generated-local-secret>
DATADOG_ENABLED=false
```

`DATABASE_URL` is used inside the monolith container. The hostname is the
Compose service name: `postgres`.

`MONO_DATABASE_URL` is used by host-side migration commands. The hostname is
`localhost`.

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
docker build -t skripsi/monolith:local -f monolith/Dockerfile .
minikube image load skripsi/monolith:local
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
