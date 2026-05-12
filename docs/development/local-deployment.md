# Local Deployment Guide

This document is the entry point for running the project locally.

Use it to choose between:

- monolith local deployment,
- microservices local deployment,
- local database lifecycle,
- stop versus clean behavior.

## 1. Local Deployment Modes

There are two supported local application modes.

| Mode | External port | Runtime style | Database |
|---|---:|---|---|
| Monolith | `8080` | Docker Compose or `go run` | `mono_db` |
| Microservices | `8080` through API Gateway | Docker Compose or `go run` per service | `auth_db`, `item_db`, `transaction_db` |

Both modes use the same local PostgreSQL container:

```text
skripsi-postgres
```

Do not run monolith and API Gateway at the same time on port `8080`.

## 2. First-Time Setup

Generate local env files:

```bash
make env-init-base
make env-init-monolith
make env-init-microservices
```

This creates ignored local files:

```text
env/postgres.env
env/monolith.env
env/db-bootstrap.env
env/api-gateway.env
env/auth-service.env
env/item-service.env
env/transaction-service.env
env/api-gateway.compose.env
env/auth-service.compose.env
env/item-service.compose.env
env/transaction-service.compose.env
```

Command responsibility:

- `make env-init-base` creates `env/postgres.env`
- `make env-init-monolith` creates `env/monolith.env` and `env/db-bootstrap.env`
- `make env-init-microservices` creates the auth, item, transaction, and API Gateway env files

These files contain local passwords, JWT secrets, and database URLs. Do not
commit them.

## 3. Start Local PostgreSQL

Start PostgreSQL:

```bash
make compose-db-up
```

The first startup creates all local databases through:

```text
deployments/compose/initdb/001-create-databases.sql
```

Created databases:

```text
mono_db
auth_db
item_db
transaction_db
```

Check PostgreSQL:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected:

```text
skripsi-postgres
```

## 4. Run Monolith Locally

Use this when testing the monolith architecture.

Migration:

```bash
make migrate-monolith-local
```

Run with Docker Compose:

```bash
make compose-monolith-up
```

Run with `go run` from the host:

```bash
make run-monolith-local
```

Health check:

```bash
curl -i http://localhost:8080/healthz
```

Expected service:

```text
monolith
```

Manual integration test guide:

```text
docs/development/manual-integration-test-monolith.md
```

Latest report:

```text
docs/development/manual-integration-test-monolith-report.md
```

## 5. Run Microservices Locally With Docker Compose

Use this as the default local deployment path when you want all MSA services to
run as containers.

Important:

- PostgreSQL must already be running through `make compose-db-up`,
- monolith must not be running on port `8080`,
- host-side migrations still use the non-compose env files.

Stop monolith container if it is running:

```bash
docker stop skripsi-monolith
```

Run migrations:

```bash
make migrate-microservices-local
```

Start the MSA stack:

```bash
make compose-microservices-up
```

The stack starts:

```text
skripsi-auth-service
skripsi-item-service
skripsi-transaction-service
skripsi-api-gateway
```

Health check:

```bash
curl -i http://localhost:8080/healthz
```

Expected service:

```text
api-gateway
```

## 6. Run Microservices Locally With Go Run

Use this when you want faster service-by-service debugging from the host.

Important:

- stop monolith first,
- keep PostgreSQL running,
- start each service in a separate terminal.

Stop monolith container if it is running:

```bash
docker stop skripsi-monolith
```

Run migrations:

```bash
make migrate-microservices-local
```

Start services:

```bash
make run-auth-service-local
make run-item-service-local
make run-transaction-service-local
make run-api-gateway-local
```

Expected ports:

```text
Auth Service        : 50051
Item Service        : 50052
Transaction Service : 50053
API Gateway         : 8080
```

Health check:

```bash
curl -i http://localhost:8080/healthz
```

Expected service:

```text
api-gateway
```

Manual integration test guide:

```text
docs/development/run-microservices-local.md
```

Latest report:

```text
docs/development/manual-integration-test-microservices-report.md
```

## 7. Stop Behavior

Stop application processes only:

```text
Ctrl+C
```

Use this for services started with `go run`.

Stop monolith Docker container only:

```bash
docker stop skripsi-monolith
```

This keeps PostgreSQL and data intact.

Stop microservices Docker containers only:

```bash
docker compose -f deployments/compose/docker-compose.microservices.yml down
```

This keeps PostgreSQL and database data intact because PostgreSQL is managed by
`docker-compose.db.yml`.

Stop PostgreSQL container without deleting volume:

```bash
docker stop skripsi-postgres
```

This preserves local database data.

## 8. Clean Behavior

Full local Compose cleanup:

```bash
make compose-down
```

Important:

- this runs Docker Compose `down -v`,
- it removes the PostgreSQL volume,
- it deletes local database state for:
  - `mono_db`
  - `auth_db`
  - `item_db`
  - `transaction_db`

Use this when you want a fully clean local database.

## 9. Recommended Local Workflow

For normal development:

```text
make env-init-base
make env-init-monolith
make env-init-microservices
make compose-db-up
run migration for selected architecture
run selected architecture
run manual integration test
stop application only
keep PostgreSQL running for inspection
```

For clean retest:

```text
make compose-down
make compose-db-up
run migration again
run selected architecture
run manual integration test
```

## 10. Quick Troubleshooting

Check occupied ports:

```bash
ss -ltnp | rg '(:8080|:50051|:50052|:50053|:5432)'
```

If port `8080` is already used:

```text
monolith or API Gateway is still running
```

If migration cannot connect:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

If MSA API Gateway returns upstream errors:

```bash
ss -ltnp | rg '(:50051|:50052|:50053)'
```

If Docker build fails because of local sandbox or buildx state, run existing
containers without rebuild when the image already exists:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml up -d
```
