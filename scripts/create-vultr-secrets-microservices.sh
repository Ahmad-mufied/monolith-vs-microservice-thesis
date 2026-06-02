#!/usr/bin/env bash
set -euo pipefail

url_encode() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required to URL-encode database credentials" >&2; exit 1; }
  printf '%s' "$1" | jq -sRr @uri
}

read_env_value() {
  grep -E "^${2}=" "$1" | head -n 1 | cut -d= -f2- || true
}

terraform_output_required() {
  local stack="$1"
  local output_name="$2"
  local description="$3"
  local value err_file

  err_file="$(mktemp)"
  if ! value="$(terraform -chdir="$stack" output -raw "$output_name" 2>"$err_file")"; then
    echo "ERROR: failed to read $description from Terraform output '$output_name'" >&2
    sed 's/^/  terraform: /' "$err_file" >&2
    rm -f "$err_file"
    exit 1
  fi
  rm -f "$err_file"

  if [ -z "$value" ]; then
    echo "ERROR: Terraform output '$output_name' for $description is empty" >&2
    exit 1
  fi

  printf '%s' "$value"
}

for file in env/vultr.env env/api-gateway.eks.env env/auth-service.eks.env env/k6-runner.eks.env; do
  [ -f "$file" ] || { echo "missing $file; run: make env-init-eks and make env-init-vultr" >&2; exit 1; }
done

set -a
source env/vultr.env
set +a
source scripts/lib/vultr-s3-credentials.sh
load_vultr_s3_credentials

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/vultr.env}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in env/vultr.env or Terraform aws-s3-writer output vultr_k6_s3_access_key_id}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in env/vultr.env or Terraform aws-s3-writer output vultr_k6_s3_secret_access_key}"
: "${AWS_REGION:?AWS_REGION must be set in env/vultr.env}"
: "${S3_BUCKET:?S3_BUCKET must be set in env/vultr.env}"

if [ -n "${VULTR_SEQUENTIAL_POSTGRES_IP:-}" ]; then
  postgres_ip="$VULTR_SEQUENTIAL_POSTGRES_IP"
else
  postgres_ip="$(terraform_output_required infra/terraform/vultr-experiment msa_postgres_private_ip "microservices PostgreSQL private IP")"
fi
encoded_db_password="$(url_encode "$POSTGRES_PASSWORD")"
K8S="kubectl --context=${VULTR_CONTEXT:-msa}"
api_jwt_secret="$(read_env_value env/api-gateway.eks.env JWT_SECRET)"
auth_jwt_secret="$(read_env_value env/auth-service.eks.env JWT_SECRET)"
admin_user_email="$(read_env_value env/k6-runner.eks.env ADMIN_USER_EMAIL)"
admin_user_password="$(read_env_value env/k6-runner.eks.env ADMIN_USER_PASSWORD)"

: "${api_jwt_secret:?JWT_SECRET must be set in env/api-gateway.eks.env}"
: "${auth_jwt_secret:?JWT_SECRET must be set in env/auth-service.eks.env}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/k6-runner.eks.env}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/k6-runner.eks.env}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic api-gateway-secret --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=HTTP_PORT=8080 \
  --from-literal=SERVICE_NAME=api-gateway \
  --from-literal=JWT_SECRET="$api_jwt_secret" \
  --from-literal=AUTH_SERVICE_ADDR=auth-service.msa.svc.cluster.local:50051 \
  --from-literal=ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052 \
  --from-literal=TRANSACTION_SERVICE_ADDR=transaction-service.msa.svc.cluster.local:50053 \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic auth-service-secret --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50051 \
  --from-literal=SERVICE_NAME=auth-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST="${BCRYPT_COST:-10}" \
  --from-literal=JWT_SECRET="$auth_jwt_secret" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic item-service-secret --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50052 \
  --from-literal=SERVICE_NAME=item-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic transaction-service-secret --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50053 \
  --from-literal=SERVICE_NAME=transaction-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052 \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic k6-runner-secret --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "Vultr microservices secrets created"
