# Benchmark Runbook — End to End

## Purpose

This runbook covers every step required to run the thesis benchmark from a
fresh AWS account to completed k6 results in S3. It is written for the
researcher, thesis reviewer, or anyone reproducing the experiment.

Estimated total time: 3–4 hours (including infrastructure provisioning).

---

## Prerequisites

### Local tools

Install these before starting:

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Terraform >= 1.6
# https://developer.hashicorp.com/terraform/install

# kubectl
# https://kubernetes.io/docs/tasks/tools/

# helm >= 3
# https://helm.sh/docs/intro/install/

# Verify
aws --version
terraform --version
kubectl version --client
helm version
```

### AWS account

You need an AWS account with an IAM user that has admin permissions.

Configure AWS CLI:

```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region: ap-southeast-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

Note your account ID from the output — you will need it later.

---

## Phase 1 — One-Time Setup (Persistent Resources)

These resources are created once and survive `terraform destroy`. Do not
recreate them for each experiment run.

### Step 1.1 — Create S3 Results Bucket

```bash
make aws-create-s3
# default: S3_BUCKET=skripsi-benchmark-results AWS_REGION=ap-southeast-1
# override: make aws-create-s3 S3_BUCKET=my-bucket AWS_REGION=ap-southeast-1
```

### Step 1.2 — Create ECR Repositories

```bash
make aws-create-ecr
# Creates: skripsi/monolith, skripsi/api-gateway, skripsi/auth-service,
#          skripsi/item-service, skripsi/transaction-service,
#          skripsi/seed-runner, skripsi/k6-runner
```

### Step 1.3 — Build and Push Docker Images

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
make ecr-push-all IMAGE_TAG=$IMAGE_TAG
# Override explicitly, for example: IMAGE_TAG=my-tag
```

### Step 1.4 — Optional Preflight: Update EKS Manifests with Pushed Image Tag

This step is now optional as a manual preflight check. The cluster deploy
scripts automatically rerun the same manifest rendering step before validation
and `kubectl apply`.

```bash
make eks-render-manifests IMAGE_TAG=$IMAGE_TAG
# Optional manual preflight. eks-deploy-* will rerun this automatically.
```

This renders EKS deployment manifests, EKS migration/seed jobs, benchmark
jobs, Datadog version labels, and benchmark `IMAGES_JSON` values with the real
ECR image URIs into a temporary directory. Repository manifests remain
unchanged.

If you deploy a tag other than the default current Git commit, pass the same
`IMAGE_TAG` into `make eks-deploy-monolith` / `make eks-deploy-msa` so the
automatic render step uses the correct image references.

The deploy scripts still support the shorter implicit form without `IMAGE_TAG`,
because they fall back to `git rev-parse --short HEAD` at execution time. That
shortcut is fine for quick local deploys when `HEAD` will not change during the
session, but the runbook keeps the explicit pinned-tag pattern as the primary
example so one experiment session cannot accidentally mix image tags.

---

## Phase 2 — Infrastructure Provisioning

### Step 2.1 — Apply Shared Infrastructure (VPC + IAM)

```bash
cd infra/terraform/shared
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set s3_results_bucket to the bucket name from Step 1.1
```

Optional helper flow:

```bash
make env-init-eks
make eks-render-tfvars
make terraform-auth-check
```

This renders `infra/terraform/shared/terraform.tfvars` from
`env/terraform.shared.env`.

```bash
make eks-shared-apply

AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/shared output
# vpc_id, private_subnet_ids, k6_runner_role_arn
```

### Step 2.2 — Apply Experiment Clusters (Two EKS + Two RDS)

```bash
cd infra/terraform/experiment
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   cluster_endpoint_public_access_cidrs = ["<operator-public-ip>/32"]
```

If you used the helper flow above, `make eks-render-tfvars` also renders
`infra/terraform/experiment/terraform.tfvars` from
`env/terraform.experiment.env`.

`DB_PASSWORD` remains in `env/terraform.experiment.env` and is passed to the
experiment Terraform stack at runtime through `TF_VAR_db_password`; it is not
written into `infra/terraform/experiment/terraform.tfvars`.

Before rendering experiment tfvars, replace the generated
`CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS=REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR`
placeholder in `env/terraform.experiment.env` with your current operator public
IP CIDR, for example `203.0.113.10/32`. For a single laptop operator this is
normally a `/32`. Do not use `0.0.0.0/0`.

By default, `make env-init-eks` now attempts to detect the current operator
public IP automatically and writes it with
`CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=auto`. If you want to pin a custom
CIDR list instead, change the source to `manual` and maintain the CIDR value
yourself.

If the autodetect helper receives a malformed non-IP response, it now fails
instead of writing an invalid CIDR value into `env/terraform.experiment.env`.

If the experiment clusters already exist and you later move to a different
network, update that CIDR value, rerender tfvars, and re-run the Terraform
apply for the existing `experiment` stack so the EKS API endpoint allowlist is
updated in place.

```bash
make eks-apply
# Takes approximately 15-20 minutes

AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/experiment output
# monolith_cluster_name, monolith_rds_endpoint
# msa_cluster_name, msa_rds_endpoint
```

`experiment` reads shared outputs from the local state file at
`infra/terraform/shared/terraform.tfstate`. Apply `shared` first, then
`experiment`, from the same laptop.

### Step 2.3 — Configure kubectl Contexts

```bash
make eks-setup-contexts

# Verify both clusters are reachable
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

Expected: 3 nodes per cluster (2 app-nodes of type `c8i.2xlarge` + 1 testing-node), all Ready.


---

## Phase 3 — Create Kubernetes Secrets

Secrets must be created in each cluster before deploying applications.

Optional helper flow before creating secrets:

```bash
make env-init-eks
make eks-render-tfvars
make terraform-auth-check
```

Optional helper commands to create secrets from `env/*.env` plus Terraform
outputs:

```bash
make eks-create-secrets
```

If you use the helper command above, you do not need to run the long manual
`kubectl create secret ...` commands below. Use
`make create-eks-secrets-monolith` or `make create-eks-secrets-microservices`
only when you intentionally want to recreate secrets for one cluster.

### Step 4.1 — Monolith Cluster Secrets

```bash
MONOLITH_RDS=$(AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/experiment output -raw monolith_rds_endpoint)
DB_PASSWORD="<same password from env/terraform.experiment.env>"
DB_PASSWORD_URI_ENCODED=$(printf '%s' "$DB_PASSWORD" | jq -sRr @uri)
JWT_SECRET="<generate: openssl rand -hex 32>"
ADMIN_USER_PASSWORD="$(openssl rand -hex 24)"

# DB bootstrap secret
kubectl --context=monolith create namespace benchmark --dry-run=client -o yaml | kubectl --context=monolith apply -f -
kubectl --context=monolith create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MONOLITH_RDS}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | kubectl --context=monolith apply -f -

# Monolith app secret
kubectl --context=monolith create namespace mono --dry-run=client -o yaml | kubectl --context=monolith apply -f -
kubectl --context=monolith create secret generic monolith-env \
  --namespace mono \
  --from-literal=APP_ENV=production \
  --from-literal=APP_PORT=8080 \
  --from-literal=SERVICE_NAME=monolith \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MONOLITH_RDS}:5432/mono_db?sslmode=require" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=DB_POOL_MAX_CONNS=25 \
  --from-literal=DB_POOL_MIN_CONNS=2 \
  --from-literal=DB_POOL_MAX_CONN_LIFETIME=5m \
  --from-literal=DB_POOL_MAX_CONN_IDLE_TIME=1m \
  --from-literal=DB_PING_TIMEOUT=5s \
  --from-literal=HTTP_READ_HEADER_TIMEOUT=5s \
  --from-literal=HTTP_READ_TIMEOUT=15s \
  --from-literal=HTTP_WRITE_TIMEOUT=30s \
  --from-literal=HTTP_IDLE_TIMEOUT=1m \
  --from-literal=HTTP_SHUTDOWN_TIMEOUT=10s \
  --from-literal=HTTP_MAX_HEADER_BYTES=1048576 \
  --from-literal=BCRYPT_COST=10 \
  --dry-run=client -o yaml | kubectl --context=monolith apply -f -

# k6 runner secret (admin credentials for enriched-transactions)
kubectl --context=monolith create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="benchmark-user-001@example.com" \
  --from-literal=ADMIN_USER_PASSWORD="$ADMIN_USER_PASSWORD" \
  --dry-run=client -o yaml | kubectl --context=monolith apply -f -
```

### Step 4.2 — MSA Cluster Secrets

```bash
MSA_RDS=$(AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/experiment output -raw msa_rds_endpoint)
DB_PASSWORD="<same password>"
DB_PASSWORD_URI_ENCODED=$(printf '%s' "$DB_PASSWORD" | jq -sRr @uri)
JWT_SECRET="<same JWT secret>"
ADMIN_USER_PASSWORD="$(openssl rand -hex 24)"
GRPC_PORT_AUTH=50051
GRPC_PORT_ITEM=50052
GRPC_PORT_TX=50053

# DB bootstrap secret
kubectl --context=msa create namespace benchmark --dry-run=client -o yaml | kubectl --context=msa apply -f -
kubectl --context=msa create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MSA_RDS}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -

# Create msa namespace
kubectl --context=msa create namespace msa --dry-run=client -o yaml | kubectl --context=msa apply -f -

# API Gateway secret
kubectl --context=msa create secret generic api-gateway-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=HTTP_PORT=8080 \
  --from-literal=SERVICE_NAME=api-gateway \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=AUTH_SERVICE_ADDR="auth-service.msa.svc.cluster.local:${GRPC_PORT_AUTH}" \
  --from-literal=ITEM_SERVICE_ADDR="item-service.msa.svc.cluster.local:${GRPC_PORT_ITEM}" \
  --from-literal=TRANSACTION_SERVICE_ADDR="transaction-service.msa.svc.cluster.local:${GRPC_PORT_TX}" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -

# Auth Service secret
kubectl --context=msa create secret generic auth-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT="$GRPC_PORT_AUTH" \
  --from-literal=SERVICE_NAME=auth-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MSA_RDS}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST=10 \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -

# Item Service secret
kubectl --context=msa create secret generic item-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT="$GRPC_PORT_ITEM" \
  --from-literal=SERVICE_NAME=item-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MSA_RDS}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -

# Transaction Service secret
kubectl --context=msa create secret generic transaction-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT="$GRPC_PORT_TX" \
  --from-literal=SERVICE_NAME=transaction-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${DB_PASSWORD_URI_ENCODED}@${MSA_RDS}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR="item-service.msa.svc.cluster.local:${GRPC_PORT_ITEM}" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -

# k6 runner secret
kubectl --context=msa create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="benchmark-user-001@example.com" \
  --from-literal=ADMIN_USER_PASSWORD="$ADMIN_USER_PASSWORD" \
  --dry-run=client -o yaml | kubectl --context=msa apply -f -
```

If `DB_PASSWORD` contains reserved URI characters such as `@`, `:`, `/`, `?`,
`#`, or `%`, URL-encode it before embedding it into PostgreSQL URIs. The
`make eks-create-secrets` helper now performs this encoding automatically for
both clusters.

---

## Phase 4 — Deploy Applications

### Step 5.1 — Deploy Monolith Cluster

```bash
SCALING_MODE=fixed make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together:

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG
```

Important:

- switching between `fixed` and `hpa` is a redeploy action
- changing `SCALING_MODE` only on the benchmark runner does not switch the live
  application stack

This script runs:
1. Apply namespaces (mono, benchmark)
2. DB bootstrap job → creates `mono_db`
3. Migration job → creates schema in `mono_db`
4. Reset + seed benchmark data (100 users, 100 items)
5. Deploy monolith application
6. Install metrics-server automatically when `SCALING_MODE=hpa` using the pinned default release, with insecure kubelet TLS disabled unless explicitly opted in
7. Apply ResourceQuota (fixed mode: no HPA)
8. Install Datadog (only when `DATADOG_API_KEY` is a real non-placeholder value)

Verify:

```bash
kubectl --context=monolith get hpa -n mono
# Expected in fixed mode: no resources found

kubectl --context=monolith get pods -n mono
# Expected: monolith-xxx Running

kubectl --context=monolith get pods -n benchmark
# Expected: seed job Completed
```

### Step 5.2 — Deploy MSA Cluster

```bash
SCALING_MODE=fixed make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together:

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG
```

Quick local alternative for per-cluster deploys:

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa
```

Use the implicit form only when you want the deploy scripts to derive
`IMAGE_TAG` from the current `HEAD` at command execution time and you do not
expect that commit to change during the deploy session.

When both architectures should move together, prefer:

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG
make eks-deploy-all-hpa IMAGE_TAG=$IMAGE_TAG
```

This script runs:
1. Apply namespaces (msa, benchmark)
2. DB bootstrap job → creates `auth_db`, `item_db`, `transaction_db`
3. Migration jobs (auth, item, transaction) in parallel
4. Reset + seed benchmark data
5. Deploy all 4 MSA services
6. Install metrics-server automatically when `SCALING_MODE=hpa` using the pinned default release, with insecure kubelet TLS disabled unless explicitly opted in
7. Apply ResourceQuota (fixed mode: no HPA)
8. Install Datadog (only when `DATADOG_API_KEY` is a real non-placeholder value)

Verify:

```bash
kubectl --context=msa get hpa -n msa
# Expected in fixed mode: no resources found

kubectl --context=msa get pods -n msa
# Expected: api-gateway, auth-service, item-service, transaction-service all Running
```

Known transition risk:

- if the cluster was previously running in HPA mode, `auth-service` or another
  deployment may still be scaled out
- that can consume the full `msa-resource-quota` CPU limit before the fixed
  deploy script reaches its scale-down step
- in that case the migration jobs can be rejected with:

```text
exceeded quota: msa-resource-quota, requested: limits.cpu=100m, used: limits.cpu=4, limited: limits.cpu=4
```

Safe recovery:

```bash
kubectl --context=msa delete hpa --all -n msa
kubectl --context=msa scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa
kubectl --context=msa delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found
SCALING_MODE=fixed make eks-deploy-msa
```

### Step 5.3 — Install Datadog (if not done in deploy scripts)

```bash
DATADOG_API_KEY=<your_api_key> make datadog-install-eks-monolith
DATADOG_API_KEY=<your_api_key> make datadog-install-eks-msa
```

Placeholder values such as `replace-me`, `CHANGE_ME`, `your_api_key`, and
`redacted` are rejected by the deploy and secret-creation scripts.

Verify:

```bash
kubectl --context=monolith get pods -n datadog
kubectl --context=msa get pods -n datadog
# Expected: datadog DaemonSet pods Running, cluster-agent Running
```

---

## Phase 5 — Smoke Test (Validation Before Benchmark)

Run a quick smoke test on both clusters simultaneously to confirm everything
is working before the measured benchmark.

```bash
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=50 \
  RUN_ID=smoke-$(date +%Y%m%d) \
  ATTEMPT=attempt-01 \
  K6_PROFILE=smoke \
  TEST_DURATION=1m \
  S3_BUCKET=skripsi-benchmark-results
```

Verify smoke results in S3:

```bash
aws s3 ls s3://skripsi-benchmark-results/experiments/smoke-$(date +%Y%m%d)/ --recursive
```

Expected files per architecture:
```text
.../monolith/login/.../summary.json
.../monolith/login/.../metadata.json
.../microservices/login/.../summary.json
.../microservices/login/.../metadata.json
```

Interpret smoke runner results the same way as measured runs:

- `PASS`: smoke validation succeeded
- `OVERLOAD`: the benchmark path worked, but the chosen target exceeded the
  configured thresholds
- `INVALID`: infra/config/runtime failure; fix before continuing
- `TIMEOUT`: orchestration timeout; inspect before continuing

---

## Phase 6 — Measured Benchmark

Use the suite runner for measured Bab 4 data collection. It executes the
scenario/RPS matrix in a consistent order, runs monolith and microservices in
parallel per case, uploads a suite manifest and summary to S3, and handles the
reset/seed lifecycle for each scenario.

### Phase 6.1 — Matrix Definition

The primary Bab 4 matrix uses two deployment modes, three primary workload
scenarios, and five target RPS levels.

| Dimension | Values |
|---|---|
| Scaling modes | `fixed`, `hpa` |
| Primary scenarios | `login`, `create-transaction`, `enriched-transactions` |
| Default target RPS levels | `1000`, `2500`, `5000`, `7500`, `10000` |
| Optional exploratory scenario | `mixed-workload` |

Primary case count:

```text
3 scenarios x 5 RPS levels = 15 suite cases per scaling mode
2 scaling modes x 15 cases = 30 primary suite cases
```

Each suite case runs the monolith and microservices k6 jobs together. The S3
layout still stores one artifact folder per architecture:

```text
s3://<bucket>/experiments/<run_id>/<architecture>/<scenario>/<target_rps>rps/<attempt>/
```

Use `mixed-workload` only when you intentionally want an additional exploratory
matrix. It is not part of the primary RQ1/RQ2 comparison unless the thesis
chapter explicitly analyzes mixed traffic.

### Phase 6.2 — Fixed Mode Primary Matrix

Fixed mode is the primary clean architecture comparison for RQ1. It uses fixed
replica counts and the `steady` k6 profile.

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG

make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-fixed-final \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  SCENARIOS="login create-transaction enriched-transactions" \
  RPS_LEVELS="1000 2500 5000 7500 10000" \
  S3_BUCKET=skripsi-benchmark-results
```

Expected suite shape:

```text
experiment   : rq1-fixed-final
run_id       : eks-fixed-rq1-fixed-final
attempt      : attempt-01, then attempt-02/03 when the same run_id is reused
scaling_mode : fixed
k6_profile   : steady
scenarios    : login create-transaction enriched-transactions
rps_levels   : 1000 2500 5000 7500 10000
case count   : 15
```

When one scenario needs a tighter load range than the others, use
`SCENARIO_RPS_MATRIX` instead of the normal `SCENARIOS` x `RPS_LEVELS`
cross-product:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-fixed-primary \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  SCENARIO_RPS_MATRIX="login:100,120,140,160,180,200;create-transaction:100,150,200,250,300,400,500;enriched-transactions:100,150,200,250,300,400,500" \
  S3_BUCKET=skripsi-benchmark-results
```

This keeps the executor and methodology consistent while letting each scenario
use a more informative calibrated RPS range.

For the final fixed primary matrix, interpret this choice as a conservative
main run:

- `login` is capped at `200` RPS because the microservices login path usually
  reaches its critical transition zone earlier than the other scenarios.
- `create-transaction` and `enriched-transactions` continue to `500` RPS
  because the higher range still yields useful separation between
  architectures.
- If the thesis needs stronger evidence that monolith login still has headroom
  above `200` RPS, add a separate `login` extension run rather than changing
  the primary matrix while measured attempts are already in progress.

Recommended fixed `login` extension run:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=rq1-login-extension \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=90 \
  SCENARIOS="login" \
  RPS_LEVELS="225 250" \
  S3_BUCKET=skripsi-benchmark-results
```

Treat this extension as supporting/exploratory evidence, not as a replacement
for the primary fixed matrix.

For unattended overnight runs, you may add:

```bash
AUTO_DESTROY_CONFIRMED=true
```

This makes the suite call `make eks-destroy-confirmed` after
`_suite/summary.json` is uploaded. Use it only when you do not need to inspect
the live cluster after the suite finishes.

### Phase 6.3 — HPA Mode Primary Matrix

HPA mode is the primary autoscaling behavior comparison for RQ2. Redeploy both
application stacks with HPA overlays before running the suite. Do not reuse a
fixed-mode deployment by changing only `SCALING_MODE` on the runner.

```bash
make eks-deploy-all-hpa IMAGE_TAG=$IMAGE_TAG

make run-benchmark-suite \
  SCALING_MODE=hpa \
  EXPERIMENT_NAME=rq2-hpa-final \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=300 \
  SCENARIOS="login create-transaction enriched-transactions" \
  RPS_LEVELS="1000 2500 5000 7500 10000" \
  S3_BUCKET=skripsi-benchmark-results
```

Expected suite shape:

```text
experiment   : rq2-hpa-final
run_id       : eks-hpa-rq2-hpa-final
attempt      : attempt-01, then attempt-02/03 when the same run_id is reused
scaling_mode : hpa
k6_profile   : hpa
scenarios    : login create-transaction enriched-transactions
rps_levels   : 1000 2500 5000 7500 10000
case count   : 15
```

### Phase 6.4 — Calibration Matrix

For early calibration, use smaller RPS levels and no inter-case delay so
feedback is fast:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  TEST_DURATION=30s \
  INTER_CASE_DELAY=0 \
  SCENARIOS="login" \
  RPS_LEVELS="50 100 150 200 250 300 350 400 450 500" \
  S3_BUCKET=skripsi-benchmark-results
```

Calibration is useful for finding the first range where latency or dropped
iterations become visible. Do not mix calibration runs with final Bab 4 tables
unless they are clearly labeled as calibration.

### Phase 6.5 — Optional Mixed Workload

`mixed-workload` can be run as an optional exploratory scenario after the
primary matrix:

```bash
make run-benchmark-suite \
  SCALING_MODE=fixed \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  SCENARIOS="mixed-workload" \
  RPS_LEVELS="1000 2500 5000 7500 10000" \
  S3_BUCKET=skripsi-benchmark-results
```

For HPA exploratory mixed workload, redeploy HPA first and use
`INTER_CASE_DELAY=300`.

### Phase 6.6 — Scenario Data Lifecycle

The suite runner uses this data lifecycle:

- `login`: reset and seed once before the first RPS level.
- `create-transaction`: reset and seed before every RPS level because the
  scenario mutates transaction data.
- `enriched-transactions`: scale app workloads down, reset, seed, and prepare
  enrichment data once before the first RPS level, then restore the rendered
  fixed/HPA workloads before k6 starts. This avoids ResourceQuota deadlock and
  ensures the prepare jobs use the same rendered image references as the suite.
- `mixed-workload`: supported for exploration, but exclude it from the primary
  Bab 4 RQ1/RQ2 matrix unless the thesis explicitly analyzes mixed load.

### Phase 6.7 — Suite Interpretation

Interpret suite and case results carefully:

- `PASS` means the benchmark completed and all thresholds passed.
- `OVERLOAD` means the benchmark completed and produced valid artifacts, but
  one or more thresholds failed.
- `INVALID` means the run should not be used for analysis until rerun.
- `TIMEOUT` means the orchestration did not complete within the expected
  window.

The suite command exits non-zero when any case is non-pass, but it still writes
the available per-case artifacts plus `_suite/summary.json`. Inspect the S3
artifacts before deciding whether a non-pass case is a valid overload datapoint
or an invalid run.

`INTER_CASE_DELAY` is a methodological stabilization gap between independent
k6 jobs. It accepts a non-negative integer value in seconds and rejects values
above `86400` seconds to avoid accidental multi-day pauses. Duration suffixes
such as `5m` are not supported; use `300` for five minutes. When the suite has
only one case, for example one scenario with one RPS level, the runner does not
sleep because there is no next case to stabilize for. It is not the same as k6
`gracefulStop`, which only lets in-flight iterations finish inside one k6 run.
Use `120` seconds for fixed final runs and `300` seconds for HPA final runs
unless the experiment log documents a different value.

`RUN_ID` remains the strongest override. If `RUN_ID` is blank and
`EXPERIMENT_NAME` is set, the suite generates a stable `RUN_ID` using
`eks-{mode}-{experiment_name}` so rerunning the same command can advance
automatically from `attempt-01` to `attempt-02` and beyond. If both are blank,
the runner falls back to the timestamp-based `RUN_ID`.

`SCENARIO_RPS_MATRIX` is optional. When set, it overrides the usual
`SCENARIOS` x `RPS_LEVELS` cross-product with a per-scenario mapping in the
form `scenario:rps1,rps2;scenario:rps1,rps2`. The suite manifest and summary
store the full matrix in `scenario_rps_matrix`.

`AUTO_DESTROY_CONFIRMED=true` is an explicit unattended-run convenience flag.
After the suite uploads `_suite/summary.json`, it forwards to
`make eks-destroy-confirmed`, which in turn enforces the existing
`S3_BENCHMARK_DATA_VERIFIED=true` guard before Terraform destroy. If the suite
fails before summary upload, automatic destroy does not run. This mode also
requires either `EXPERIMENT_NAME` or `RUN_ID` so the unattended run keeps a
stable, operator-chosen identity.

---

## Phase 7 — Verify Results

Verify the run-level suite files first:

```bash
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/_suite/manifest.json - | jq .
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/_suite/summary.json - | jq .
```

Expected primary matrix values:

```bash
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/_suite/manifest.json - \
  | jq '{scaling_mode, k6_profile, scenarios, rps_levels, inter_case_delay}'

aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/_suite/summary.json - \
  | jq '{suite_status, case_count: (.cases | length), cases}'
```

For a primary fixed or HPA run, `case_count` should be `15` when the suite uses:

```text
SCENARIOS="login create-transaction enriched-transactions"
RPS_LEVELS="1000 2500 5000 7500 10000"
```

Verify expected attempt folders for every primary scenario/RPS combination:

```bash
RUN_ID=<suite-run-id>
BUCKET=skripsi-benchmark-results
ATTEMPT=attempt-01

for scenario in login create-transaction enriched-transactions; do
  for rps in 1000 2500 5000 7500 10000; do
    for architecture in monolith microservices; do
      prefix="s3://${BUCKET}/experiments/${RUN_ID}/${architecture}/${scenario}/${rps}rps/${ATTEMPT}"
      echo "=== ${prefix}"
      aws s3 ls "${prefix}/" | awk '{print $4}' | sort
    done
  done
done
```

Each attempt folder should include:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
result-status.json
k6-options.json
thresholds.json
datadog-time-window.json  # when Datadog is enabled
```

Check a specific summary:

```bash
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/monolith/login/1000rps/attempt-01/summary.json - \
  | jq '{p90: .metrics.http_req_duration.values["p(90)"], p95: .metrics.http_req_duration.values["p(95)"], error_rate: .metrics.http_req_failed.values.rate}'
```

Check result classification for a case:

```bash
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/microservices/login/1000rps/attempt-01/result-status.json - \
  | jq .
```

If a case is `OVERLOAD`, the result may still be valid for analysis when
artifacts are present and the failure is caused by thresholds such as high
latency or dropped iterations. If a case is `INVALID` or `TIMEOUT`, inspect the
pod logs and rerun after fixing the infra/config/runtime problem.

Do not destroy infrastructure until all expected files are present.

---

## Phase 8 — Destroy Infrastructure

```bash
# Re-auth and verify Terraform-compatible AWS auth first
aws login
make terraform-auth-check

# Destroy both EKS clusters and RDS instances
make eks-destroy-confirmed

# Destroy VPC and IAM (only when fully done with all experiments)
# S3 bucket and ECR repositories are NOT destroyed — they are persistent.
make eks-shared-destroy
```

`make eks-destroy` now enforces the S3 verification policy before it forwards
`terraform destroy` for the experiment stack. Use
`make eks-destroy-confirmed` as the normal operator command after you verify the
uploaded benchmark artifacts in S3.

---

## Troubleshooting

For a broader operator command cheat sheet that covers deployment rollout,
job reruns, k6 inspection, Datadog checks, and AWS live cross-checks, see
`docs/infrastructure/eks-debug-command-reference.md`.

### Pods not starting

```bash
kubectl --context=monolith describe pod -n mono -l app=monolith
kubectl --context=monolith get events -n mono --sort-by=.metadata.creationTimestamp
```

Common causes:
- Secret missing → check `kubectl --context=monolith get secrets -n mono`
- Image pull error → verify ECR image URI in manifest and ECR login
- RDS not reachable → verify security group allows port 5432 from EKS node SG

### k6 job fails

```bash
kubectl --context=monolith logs job/k6-benchmark-monolith -n benchmark
```

Common causes:
- `BASE_URL` not reachable → verify app pods are Running and Service exists
- No enrichment data → run prepare-enrichment job before enriched-transactions
- S3 upload fails → verify EKS Pod Identity association for k6-runner ServiceAccount

### Datadog not showing traces

```bash
kubectl --context=monolith get pods -n datadog
kubectl --context=monolith logs -n datadog -l app=datadog --tail=50
```

Common causes:
- `datadog-secret` missing → run `make datadog-install-eks-monolith` with `DATADOG_API_KEY` set
- Agent not on app-nodes → verify DaemonSet is running on all nodes
- `DD_AGENT_HOST` wrong → pods use `status.hostIP` which requires Agent on same node

### RDS connection refused

```bash
# Test from inside cluster
kubectl --context=monolith run pg-test \
  --image=postgres:18 \
  --rm -it \
  --restart=Never \
  -- psql "postgres://postgres_admin:<password>@<rds-endpoint>:5432/bootstrap?sslmode=require" -c '\l'
```

---

## Quick Reference

| Command | Purpose |
|---|---|
| `docs/infrastructure/eks-debug-command-reference.md` | Operator cheat sheet for `kubectl` and AWS CLI debugging |
| `make aws-create-s3` | Create S3 results bucket (one-time) |
| `make aws-create-ecr` | Create ECR repositories (one-time) |
| `make ecr-push-all` | Build and push all Docker images to ECR |
| `make eks-render-manifests` | Render EKS manifests with ECR image URIs into a temp directory |
| `make terraform-auth-check` | Verify Terraform-compatible AWS auth before plan/apply/destroy |
| `make eks-shared-apply` | Apply shared Terraform (VPC + IAM) |
| `make eks-apply` | Apply experiment Terraform (2 EKS + 2 RDS) |
| `make eks-setup-contexts` | Configure kubectl for both clusters |
| `SCALING_MODE=fixed make eks-deploy-monolith` | Deploy monolith (fixed replicas) |
| `SCALING_MODE=fixed make eks-deploy-msa` | Deploy MSA (fixed replicas) |
| `make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG` | Deploy both architectures in fixed mode |
| `SCALING_MODE=hpa make eks-deploy-monolith` | Deploy monolith (HPA enabled) |
| `make eks-deploy-all-hpa IMAGE_TAG=$IMAGE_TAG` | Deploy both architectures in HPA mode |
| `DATADOG_API_KEY=<key> make datadog-install-eks-monolith` | Install Datadog on monolith cluster |
| `DATADOG_API_KEY=<key> make datadog-install-eks-msa` | Install Datadog on MSA cluster |
| `make run-benchmark-parallel SCENARIO=login TARGET_RPS=1000 RUN_ID=... S3_BUCKET=...` | Run parallel benchmark |
| `make run-benchmark-suite SCALING_MODE=fixed SCENARIOS="login create-transaction enriched-transactions" RPS_LEVELS="1000 2500 5000 7500 10000"` | Run primary fixed-mode matrix |
| `make run-benchmark-suite SCALING_MODE=hpa SCENARIOS="login create-transaction enriched-transactions" RPS_LEVELS="1000 2500 5000 7500 10000"` | Run primary HPA-mode matrix |
| `make eks-destroy-confirmed` | Destroy experiment clusters and RDS after confirming benchmark artifacts are safe in S3 |
| `make eks-shared-destroy` | Destroy VPC and IAM (keep S3 and ECR) |

---

## Scaling Mode Reference

| Goal | `SCALING_MODE` | `K6_PROFILE` | Manifest applied |
|---|---|---|---|
| RQ1 clean comparison | `fixed` | `steady` | `overlays/fixed` |
| RQ2 + HPA behavior | `hpa` | `hpa` | `overlays/hpa` |

See `docs/experiment/scaling-mode-strategy.md` for full details.
