# Secret Management

## Purpose

This document describes secret and configuration management for the benchmark project.

Final strategy:

```text
Local development       : ignored env files
Docker Compose          : env_file
Minikube                : Kubernetes Secret from env file
AWS EKS                 : Kubernetes Secret for app secrets
AWS service access      : IRSA or EKS Pod Identity
External Secrets tools  : not used by default
```

---

## Final Decision

Use Kubernetes Secret for sensitive runtime values.

Use ConfigMap for non-sensitive configuration.

Use EKS Pod Identity or IRSA for AWS access.

Do not store AWS access keys in Kubernetes Secrets.

---

## Secret vs Config

Sensitive values:

```text
DATABASE_URL
MONO_DATABASE_URL
AUTH_DATABASE_URL
ITEM_DATABASE_URL
TRANSACTION_DATABASE_URL
BOOTSTRAP_DATABASE_URL
JWT_SECRET
DATADOG_API_KEY
AUTH_TOKEN
```

Non-sensitive values:

```text
APP_ENV
APP_PORT
SERVICE_NAME
AUTH_SERVICE_ADDR
ITEM_SERVICE_ADDR
TRANSACTION_SERVICE_ADDR
BASE_URL
TARGET_RPS
TEST_DURATION
SCENARIO
ARCHITECTURE
S3_BUCKET
```

---

## Env File Structure

Recommended structure:

```text
env/
├── monolith.example.env
├── api-gateway.example.env
├── auth-service.example.env
├── item-service.example.env
├── transaction-service.example.env
├── db-bootstrap.example.env
└── k6-runner.example.env
```

Git rule:

```gitignore
env/*.env
!env/*.example.env
```

Only `*.example.env` files should be committed.

---

## DB Bootstrap Secret

Current local / Minikube secret name:

```text
db-bootstrap-env
```

Namespace:

```text
benchmark
```

Required key:

```text
BOOTSTRAP_DATABASE_URL
```

Current local generation path:

```text
scripts/create-local-postgres-secrets.sh
```

Example:

```text
postgres://postgres_admin:<password>@<rds-endpoint>:5432/bootstrap?sslmode=require
```

This secret is used by `db-bootstrap-job` to create:

```text
mono_db
auth_db
item_db
transaction_db
```

In the current local Minikube flow, this secret is mounted by:

```text
deployments/k8s/local/db-bootstrap-job.yaml
```

---

## Application Secrets

### Monolith

Current local / Minikube secret:

```text
monolith-env
```

Namespace:

```text
mono
```

Keys:

```text
APP_ENV
APP_PORT
SERVICE_NAME
DATABASE_URL
DB_POOL_MAX_CONNS
DB_POOL_MIN_CONNS
DB_POOL_MAX_CONN_LIFETIME
DB_POOL_MAX_CONN_IDLE_TIME
DB_PING_TIMEOUT
HTTP_READ_HEADER_TIMEOUT
HTTP_READ_TIMEOUT
HTTP_WRITE_TIMEOUT
HTTP_IDLE_TIMEOUT
HTTP_SHUTDOWN_TIMEOUT
HTTP_MAX_HEADER_BYTES
JWT_SECRET
DATADOG_ENABLED
```

The purpose of the DB pool and HTTP timeout variables is explained in
`docs/development/run-monolith-local.md`, because the same keys are used for
local Compose and local Kubernetes flows.

In the current local Minikube flow, this secret is mounted by:

```text
deployments/k8s/monolith/migration-job.yaml
deployments/k8s/monolith/monolith.yaml
```

### API Gateway

Secret:

```text
api-gateway-secret
```

Namespace:

```text
msa
```

Keys:

```text
APP_ENV
APP_PORT
SERVICE_NAME
JWT_SECRET
AUTH_SERVICE_ADDR
ITEM_SERVICE_ADDR
TRANSACTION_SERVICE_ADDR
DATADOG_ENABLED
```

### Auth Service

Secret:

```text
auth-service-secret
```

Keys:

```text
APP_ENV
APP_PORT
SERVICE_NAME
DATABASE_URL
JWT_SECRET
DATADOG_ENABLED
```

### Item Service

Secret:

```text
item-service-secret
```

Keys:

```text
APP_ENV
APP_PORT
SERVICE_NAME
DATABASE_URL
DATADOG_ENABLED
```

### Transaction Service

Secret:

```text
transaction-service-secret
```

Keys:

```text
APP_ENV
APP_PORT
SERVICE_NAME
DATABASE_URL
AUTH_SERVICE_ADDR
ITEM_SERVICE_ADDR
DATADOG_ENABLED
```

---

## k6 Runner Secret

Secret:

```text
k6-runner-secret
```

Namespace:

```text
benchmark
```

Sensitive key:

```text
AUTH_TOKEN
```

Do not store AWS keys here.

The k6 runner should upload to S3 through EKS Pod Identity or IRSA.

---

## Creating Secrets from Env Files

The repository currently uses two slightly different patterns:

- Docker Compose reads ignored local env files directly with `env_file`.
- Local Minikube generates Kubernetes Secrets from those env files, with some
  values rewritten for in-cluster DNS.
- AWS EKS should also use Kubernetes Secrets, but the exact creation flow may be
  managed separately from the local helper script.

### Local Minikube helper flow

Use these helper scripts for the repository's default local Minikube path.

They keep the ignored local env files as the source input, then rewrite only the values that must change for in-cluster DNS and local Kubernetes secret names.

Namespaces:

```bash
kubectl apply -f deployments/k8s/namespaces/local.yaml
```

PostgreSQL runtime secret for local cluster:

```bash
kubectl create secret generic postgres-local-env \
  --from-env-file=env/postgres.env \
  -n local-database \
  --dry-run=client -o yaml | kubectl apply -f -
```

Purpose:

- used by `deployments/k8s/local/postgres.yaml`,
- provides `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` to the local
  PostgreSQL StatefulSet.

DB bootstrap secret for local cluster:

```bash
bash scripts/create-local-postgres-secrets.sh
```

Important note:

- the current helper script does not apply `env/db-bootstrap.env` verbatim,
- it generates an in-cluster value for `BOOTSTRAP_DATABASE_URL`,
- it rewrites the hostname to
  `postgres.local-database.svc.cluster.local`.
- the local Minikube flow also synchronizes the in-cluster `postgres` user
  password after the PostgreSQL pod becomes Ready, so regenerated local env
  files remain usable even if the local PostgreSQL data directory already
  exists.

Monolith secret helper:

```bash
bash scripts/create-local-secrets.sh
```

Important note for monolith local Minikube:

- the helper does not apply `env/monolith.env` verbatim,
- it rewrites `DATABASE_URL` from the Compose host to `postgres.local-database.svc.cluster.local`,
- this keeps the same base local env file usable for both Compose and Minikube.

Microservices secret helper:

```bash
bash scripts/create-local-secrets-microservices.sh
```

Important note for microservices local Minikube:

- the helper rewrites each service `DATABASE_URL` to `postgres.local-database.svc.cluster.local`,
- it also rewrites gRPC addresses to in-cluster service DNS using the configured service ports,
- this keeps the host-run env files reusable while still producing valid Kubernetes Secrets.

Reference:

```text
scripts/create-local-postgres-secrets.sh
scripts/create-local-secrets.sh
scripts/create-local-secrets-microservices.sh
```

### Manual Kubernetes secret creation pattern

If you are creating secrets manually outside the local helper flow, use this
general pattern and choose names that match the manifests being applied.

DB bootstrap:

```bash
kubectl apply -f deployments/k8s/namespaces/local.yaml

kubectl create secret generic db-bootstrap-env \
  --from-env-file=env/db-bootstrap.env \
  -n local-database \
  --dry-run=client -o yaml | kubectl apply -f -
```

Monolith:

```bash
kubectl apply -f deployments/k8s/namespaces/local.yaml

kubectl create secret generic monolith-env \
  --from-env-file=env/monolith.env \
  -n mono \
  --dry-run=client -o yaml | kubectl apply -f -
```

Microservices:

```bash
kubectl apply -f deployments/k8s/namespaces/local.yaml

kubectl create secret generic api-gateway-secret \
  --from-env-file=env/api-gateway.env \
  -n msa \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic auth-service-secret \
  --from-env-file=env/auth-service.env \
  -n msa \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic item-service-secret \
  --from-env-file=env/item-service.env \
  -n msa \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic transaction-service-secret \
  --from-env-file=env/transaction-service.env \
  -n msa \
  --dry-run=client -o yaml | kubectl apply -f -
```

Important note for microservices local Minikube:

- `scripts/create-local-secrets-microservices.sh` rewrites each service `DATABASE_URL` to `postgres.local-database.svc.cluster.local`,
- it also rewrites gRPC addresses to in-cluster service DNS using the configured service ports,
- this keeps the host-run env files reusable while still producing valid Kubernetes Secrets.

---

## AWS Access

Do not use:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

Use:

```text
EKS Pod Identity
```

or:

```text
IRSA
```

For k6 runner S3 upload, use:

```text
ServiceAccount: k6-runner
Namespace: benchmark
IAM Role: k6-runner-role
```

Required permissions:

```text
s3:PutObject
s3:GetObject
s3:ListBucket
```

Scope permissions to the benchmark result bucket only.

---

## Why Not ESO or AWS Secrets Manager by Default

Not used by default because:

```text
- adds operational complexity
- requires external secret backend setup
- requires extra IAM/provider configuration
- is not required for short-lived experiment infrastructure
```

This project prioritizes simplicity, reproducibility, and low operational overhead.

---

## Security Checklist

Before committing:

```text
- no real env files
- no database passwords
- no JWT secrets
- no AWS access keys
- no Datadog API keys
- no kubeconfig
- no Terraform state
- no private keys
```

Before benchmark:

```text
- db-bootstrap-env exists
- monolith-env exists
- app secrets exist
- k6 runner has S3 IAM role access
- RDS is private
- secrets are not printed in logs
```
