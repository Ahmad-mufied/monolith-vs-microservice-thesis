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

Secret name:

```text
db-bootstrap-secret
```

Namespace:

```text
benchmark
```

Required key:

```text
BOOTSTRAP_DATABASE_URL
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

---

## Application Secrets

### Monolith

Secret:

```text
monolith-secret
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
JWT_SECRET
DATADOG_ENABLED
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

DB bootstrap:

```bash
kubectl create namespace benchmark --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic db-bootstrap-secret \
  --from-env-file=env/db-bootstrap.env \
  -n benchmark \
  --dry-run=client -o yaml | kubectl apply -f -
```

Monolith:

```bash
kubectl create namespace mono --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic monolith-secret \
  --from-env-file=env/monolith.env \
  -n mono \
  --dry-run=client -o yaml | kubectl apply -f -
```

Microservices:

```bash
kubectl create namespace msa --dry-run=client -o yaml | kubectl apply -f -

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
- db-bootstrap-secret exists
- app secrets exist
- k6 runner has S3 IAM role access
- RDS is private
- secrets are not printed in logs
```
