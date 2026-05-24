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
scripts automatically rerun the same manifest patching step before validation
and `kubectl apply`.

```bash
make eks-update-manifests IMAGE_TAG=$IMAGE_TAG
# Optional manual preflight. eks-deploy-* will rerun this automatically.
```

This patches the EKS deployment manifests, EKS migration/seed jobs, benchmark
jobs, Datadog version labels, and benchmark `IMAGES_JSON` values with the real
ECR image URIs.

If you deploy a tag other than the default current Git commit, pass the same
`IMAGE_TAG` into `make eks-deploy-monolith` / `make eks-deploy-msa` so the
automatic patching step stamps the correct image references.

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

Expected: 3 nodes per cluster (2 app-nodes + 1 testing-node), all Ready.


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
make create-eks-secrets-monolith
make create-eks-secrets-microservices
```

If you use the helper commands above, you do not need to run the long manual
`kubectl create secret ...` commands below.

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
`make create-eks-secrets-monolith` and `make create-eks-secrets-microservices`
helpers now perform this encoding automatically.

---

## Phase 4 — Deploy Applications

### Step 5.1 — Deploy Monolith Cluster

```bash
SCALING_MODE=fixed make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
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
6. Install metrics-server automatically when `SCALING_MODE=hpa`
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

Quick local alternative:

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa
```

Use the implicit form only when you want the deploy scripts to derive
`IMAGE_TAG` from the current `HEAD` at command execution time and you do not
expect that commit to change during the deploy session.

This script runs:
1. Apply namespaces (msa, benchmark)
2. DB bootstrap job → creates `auth_db`, `item_db`, `transaction_db`
3. Migration jobs (auth, item, transaction) in parallel
4. Reset + seed benchmark data
5. Deploy all 4 MSA services
6. Install metrics-server automatically when `SCALING_MODE=hpa`
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
```
.../monolith/login/.../summary.json
.../monolith/login/.../metadata.json
.../microservices/login/.../summary.json
.../microservices/login/.../metadata.json
```

---

## Phase 6 — Measured Benchmark

Run the three primary benchmark scenarios. Reset and seed before each
scenario that mutates data (create-transaction).

### Scenario 1: Login

```bash
RUN_ID="eks-run-$(date +%Y%m%d)"

make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=$RUN_ID \
  ATTEMPT=attempt-01 \
  S3_BUCKET=skripsi-benchmark-results
```

### Scenario 2: Create Transaction

Reset and seed before each RPS level:

```bash
# Reset both clusters
kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/reset-monolith-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/reset-microservices-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

# Seed both clusters
kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/seed-monolith-benchmark-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/seed-microservices-benchmark-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

# Run benchmark
make run-benchmark-parallel \
  SCENARIO=create-transaction \
  TARGET_RPS=1000 \
  RUN_ID=$RUN_ID \
  ATTEMPT=attempt-01 \
  S3_BUCKET=skripsi-benchmark-results
```

### Scenario 3: Enriched Transactions

Requires enrichment data preparation after base seed:

```bash
# After reset and seed (same as above), prepare enrichment data
make eks-prepare-enrichment-benchmark

# Run benchmark
make run-benchmark-parallel \
  SCENARIO=enriched-transactions \
  TARGET_RPS=1000 \
  RUN_ID=$RUN_ID \
  ATTEMPT=attempt-01 \
  S3_BUCKET=skripsi-benchmark-results
```

### Multiple RPS Levels

Repeat each scenario at different RPS levels. For create-transaction, reset
and seed before each level. For login and enriched-transactions, seed once
before the first level.

Default target RPS levels: `1000 2500 5000 7500 10000`

---

## Phase 7 — Verify Results

```bash
# List all result files
aws s3 ls s3://skripsi-benchmark-results/experiments/$RUN_ID/ --recursive | grep summary.json

# Check a specific summary
aws s3 cp s3://skripsi-benchmark-results/experiments/$RUN_ID/monolith/login/1000rps/attempt-01/summary.json - \
  | jq '{p90: .metrics.http_req_duration.values["p(90)"], p95: .metrics.http_req_duration.values["p(95)"], error_rate: .metrics.http_req_failed.values.rate}'
```

Do not destroy infrastructure until all expected files are present.

---

## Phase 8 — Destroy Infrastructure

```bash
# Re-auth and verify Terraform-compatible AWS auth first
aws login
make terraform-auth-check

# Destroy both EKS clusters and RDS instances
make eks-destroy

# Destroy VPC and IAM (only when fully done with all experiments)
# S3 bucket and ECR repositories are NOT destroyed — they are persistent.
make eks-shared-destroy
```

---

## Troubleshooting

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
| `make aws-create-s3` | Create S3 results bucket (one-time) |
| `make aws-create-ecr` | Create ECR repositories (one-time) |
| `make ecr-push-all` | Build and push all Docker images to ECR |
| `make eks-update-manifests` | Patch EKS manifests with ECR image URIs |
| `make terraform-auth-check` | Verify Terraform-compatible AWS auth before plan/apply/destroy |
| `make eks-shared-apply` | Apply shared Terraform (VPC + IAM) |
| `make eks-apply` | Apply experiment Terraform (2 EKS + 2 RDS) |
| `make eks-setup-contexts` | Configure kubectl for both clusters |
| `SCALING_MODE=fixed make eks-deploy-monolith` | Deploy monolith (fixed replicas) |
| `SCALING_MODE=fixed make eks-deploy-msa` | Deploy MSA (fixed replicas) |
| `SCALING_MODE=hpa make eks-deploy-monolith` | Deploy monolith (HPA enabled) |
| `DATADOG_API_KEY=<key> make datadog-install-eks-monolith` | Install Datadog on monolith cluster |
| `DATADOG_API_KEY=<key> make datadog-install-eks-msa` | Install Datadog on MSA cluster |
| `make run-benchmark-parallel SCENARIO=login TARGET_RPS=1000 RUN_ID=... S3_BUCKET=...` | Run parallel benchmark |
| `make eks-destroy` | Destroy experiment clusters and RDS |
| `make eks-shared-destroy` | Destroy VPC and IAM (keep S3 and ECR) |

---

## Scaling Mode Reference

| Goal | `SCALING_MODE` | `K6_PROFILE` | Manifest applied |
|---|---|---|---|
| RQ1 clean comparison | `fixed` | `steady` | `resource-management-fixed.yaml` |
| RQ2 + HPA behavior | `hpa` | `hpa` | `resource-management-hpa.yaml` |

See `docs/experiment/scaling-mode-strategy.md` for full details.
