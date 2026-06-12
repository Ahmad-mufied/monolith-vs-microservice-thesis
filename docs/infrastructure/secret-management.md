# Secret Management

## Vultr VKE Benchmark Secrets

The Vultr VKE path also does not have EKS Pod Identity. The k6 runner receives
AWS S3 upload credentials through `benchmark/k6-runner-secret`, created by:

```bash
make vultr-create-secrets
make vultr-create-secrets-sequential
```

Preferred path:

```bash
make aws-s3-writer-apply
terraform -chdir=infra/terraform/aws-s3-writer output -raw vultr_k6_s3_access_key_id
terraform -chdir=infra/terraform/aws-s3-writer output -raw vultr_k6_s3_secret_access_key
```

`make vultr-apply` runs
`make aws-s3-writer-apply` first, so the standard Vultr apply flow prepares the
S3 writer before creating cluster infrastructure. Manual `AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY` values in `env/vultr.env` remain a fallback only.

Application secrets reuse the current Kubernetes Secret names consumed by the
cloud manifests. PostgreSQL URLs point to Vultr private VPC IPs from Terraform
outputs. Do not commit `env/vultr.env`, generated `terraform.tfvars`, local
Terraform state, or kubeconfig files.

For the full variable list and creation order, see
`docs/infrastructure/vultr-configuration-reference.md` and
`docs/infrastructure/vultr-operator-guide.md`.

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

Use EKS Pod Identity or IRSA for AWS access on EKS-managed clusters.

Do not store AWS access keys in Kubernetes Secrets for EKS-managed clusters.

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
DATADOG_ENABLED
DD_ENV
DD_SERVICE
DD_VERSION
DD_AGENT_HOST
DD_TRACE_AGENT_PORT
DD_TRACE_ENABLED
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

Current repository helper flow for EKS:

```text
env-init PLATFORM=eks EXECUTION_MODE=parallel|sequential
  -> reads env/operator-profile.env and dispatches the operator flow
env-init-app
  -> lower-level helper that creates provider-neutral app env files under env/*.app.env
env-init-eks
  -> lower-level helper that creates AWS helper env files under env/
eks-render-tfvars
  -> renders infra/terraform/*/terraform.tfvars
terraform-auth-check
  -> verifies Terraform can read AWS credentials through terraform-process
eks-create-secrets
  -> create Kubernetes secrets for both EKS clusters from env/ + Terraform outputs
eks-create-secrets-sequential
  -> create mono, msa, and benchmark namespace secrets in the single sequential cluster
```

Granular targets are still available when only one cluster's secrets need to be
recreated:

```bash
make create-eks-secrets-monolith
make create-eks-secrets-microservices
make eks-create-secrets-sequential
```

Important distinction:

- `env/*.env` helper files are the editable local source for repeatable setup
- `terraform.tfvars` remains the Terraform input artifact and is rendered from
  the relevant `env/terraform.*.env` files
- `env/*.env` does not replace `terraform.tfvars`; it feeds it
- Terraform-related helper commands should use the standard local profile
  `terraform-process` through `TERRAFORM_AWS_PROFILE`, not the operator's
  default shell profile implicitly

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
deployments/k8s/local/shared/db-bootstrap-job.yaml
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
APP_REQUEST_TIMEOUT
HTTP_READ_HEADER_TIMEOUT
HTTP_READ_TIMEOUT
HTTP_WRITE_TIMEOUT
HTTP_IDLE_TIMEOUT
HTTP_SHUTDOWN_TIMEOUT
HTTP_MAX_HEADER_BYTES
BCRYPT_COST
JWT_SECRET
DATADOG_ENABLED
LOGIN_ADMISSION_ENABLED
LOGIN_MAX_CONCURRENCY
LOGIN_QUEUE_TIMEOUT
```

For Kubernetes benchmark deployments, the gRPC dependency addresses should use
headless Services with the gRPC DNS resolver scheme:

```text
AUTH_SERVICE_ADDR=dns:///auth-service-headless.msa.svc.cluster.local:50051
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
TRANSACTION_SERVICE_ADDR=dns:///transaction-service-headless.msa.svc.cluster.local:50053
```

Datadog `DD_*` runtime configuration is applied directly in Kubernetes
workload manifests because it is non-sensitive. The Datadog API key is stored
separately in the Datadog Agent secret.

The purpose of the DB pool and HTTP timeout variables is explained in
`docs/development/run-monolith-local.md`, because the same keys are used for
local Compose and local Kubernetes flows.

In the current local Minikube flow, this secret is mounted by:

```text
deployments/k8s/local/monolith/migration-job.yaml
deployments/k8s/local/monolith/monolith.yaml
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
HTTP_PORT
SERVICE_NAME
JWT_SECRET
AUTH_SERVICE_ADDR
ITEM_SERVICE_ADDR
TRANSACTION_SERVICE_ADDR
GRPC_CALL_TIMEOUT
REQUEST_TIMEOUT
HTTP_READ_HEADER_TIMEOUT
HTTP_READ_TIMEOUT
HTTP_WRITE_TIMEOUT
HTTP_IDLE_TIMEOUT
HTTP_SHUTDOWN_TIMEOUT
```

### Auth Service

Secret:

```text
auth-service-secret
```

Keys:

```text
APP_ENV
GRPC_PORT
SERVICE_NAME
DATABASE_URL
BCRYPT_COST
JWT_SECRET
GRPC_REQUEST_TIMEOUT
DATADOG_ENABLED
LOGIN_ADMISSION_ENABLED
LOGIN_MAX_CONCURRENCY
LOGIN_QUEUE_TIMEOUT
```

### Item Service

Secret:

```text
item-service-secret
```

Keys:

```text
APP_ENV
GRPC_PORT
SERVICE_NAME
DATABASE_URL
GRPC_REQUEST_TIMEOUT
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
GRPC_PORT
SERVICE_NAME
DATABASE_URL
ITEM_SERVICE_ADDR
GRPC_REQUEST_TIMEOUT
ITEM_VALIDATION_TIMEOUT
DATADOG_ENABLED
```

For Kubernetes benchmark deployments, `ITEM_SERVICE_ADDR` should point to the
Item Service headless target so the gRPC client can distribute calls across
ready Item Service pods:

```text
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
```

---

## Datadog Agent Secret

Secret:

```text
datadog-secret
```

Namespace:

```text
datadog
```

Keys:

```text
api-key
app-key (optional)
site
```

Create it from the local shell environment:

```bash
DATADOG_API_KEY=<redacted> make datadog-secret
```

Important distinction:

```text
env/datadog.minikube.env
is a local helper file

datadog-secret
is the Kubernetes Secret consumed by the Datadog Helm chart
```

The helper file is only a source of values. The cluster never reads that file
directly. The file must first be loaded into the shell environment, then
`make datadog-secret` creates or updates the Kubernetes Secret.

Optional app key:

```bash
DATADOG_APP_KEY=<redacted> \
DATADOG_API_KEY=<redacted> \
make datadog-secret
```

Do not write the Datadog API key into committed env files, manifests, Helm
values, or documentation examples.

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
ADMIN_AUTH_TOKEN
ADMIN_USER_EMAIL
ADMIN_USER_PASSWORD
```

Do not store AWS keys here for EKS-managed clusters.

On EKS, the k6 runner should upload to S3 through EKS Pod Identity or IRSA.

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

- used by `deployments/k8s/local/shared/postgres.yaml`,
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
- make eks-create-secrets has been run after eks-apply/context setup, or
  make eks-create-secrets-sequential has been run after sequential context setup
- db-bootstrap-env exists
- monolith-env exists
- app secrets exist
- k6 runner has S3 IAM role access
- RDS is private
- secrets are not printed in logs
```
