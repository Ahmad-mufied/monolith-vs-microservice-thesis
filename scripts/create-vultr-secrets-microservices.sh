#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

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

api_gateway_env_file="$(resolve_app_env_file api-gateway || true)"
auth_service_env_file="$(resolve_app_env_file auth-service || true)"
item_service_env_file="$(resolve_app_env_file item-service || true)"
transaction_service_env_file="$(resolve_app_env_file transaction-service || true)"
k6_runner_env_file="$(resolve_app_env_file k6-runner || true)"
api_gateway_env_file="${api_gateway_env_file:-env/api-gateway.app.env}"
auth_service_env_file="${auth_service_env_file:-env/auth-service.app.env}"
item_service_env_file="${item_service_env_file:-env/item-service.app.env}"
transaction_service_env_file="${transaction_service_env_file:-env/transaction-service.app.env}"
k6_runner_env_file="${k6_runner_env_file:-env/k6-runner.app.env}"

for file in env/vultr.env "$api_gateway_env_file" "$auth_service_env_file" "$item_service_env_file" "$transaction_service_env_file" "$k6_runner_env_file"; do
  [ -f "$file" ] || { echo "missing $file; run: make env-init-app and make env-init-vultr" >&2; exit 1; }
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
  postgres_ip="$(terraform_output_required infra/terraform/vultr-parallel msa_postgres_private_ip "microservices PostgreSQL private IP")"
fi
encoded_db_password="$(url_encode "$POSTGRES_PASSWORD")"
K8S="kubectl --context=${VULTR_CONTEXT:-msa}"
api_jwt_secret="$(read_env_value "$api_gateway_env_file" JWT_SECRET)"
api_app_env="$(read_env_value "$api_gateway_env_file" APP_ENV)"
api_http_port="$(read_env_value "$api_gateway_env_file" HTTP_PORT)"
api_service_name="$(read_env_value "$api_gateway_env_file" SERVICE_NAME)"
api_auth_service_addr="$(read_env_value "$api_gateway_env_file" AUTH_SERVICE_ADDR)"
api_item_service_addr="$(read_env_value "$api_gateway_env_file" ITEM_SERVICE_ADDR)"
api_transaction_service_addr="$(read_env_value "$api_gateway_env_file" TRANSACTION_SERVICE_ADDR)"
auth_jwt_secret="$(read_env_value "$auth_service_env_file" JWT_SECRET)"
auth_app_env="$(read_env_value "$auth_service_env_file" APP_ENV)"
auth_grpc_port="$(read_env_value "$auth_service_env_file" GRPC_PORT)"
auth_service_name="$(read_env_value "$auth_service_env_file" SERVICE_NAME)"
auth_bcrypt_cost="$(read_env_value "$auth_service_env_file" BCRYPT_COST)"
item_app_env="$(read_env_value "$item_service_env_file" APP_ENV)"
item_grpc_port="$(read_env_value "$item_service_env_file" GRPC_PORT)"
item_service_name="$(read_env_value "$item_service_env_file" SERVICE_NAME)"
transaction_app_env="$(read_env_value "$transaction_service_env_file" APP_ENV)"
transaction_grpc_port="$(read_env_value "$transaction_service_env_file" GRPC_PORT)"
transaction_service_name="$(read_env_value "$transaction_service_env_file" SERVICE_NAME)"
transaction_item_service_addr="$(read_env_value "$transaction_service_env_file" ITEM_SERVICE_ADDR)"
admin_user_email="$(read_env_value "$k6_runner_env_file" ADMIN_USER_EMAIL)"
admin_user_password="$(read_env_value "$k6_runner_env_file" ADMIN_USER_PASSWORD)"

: "${api_jwt_secret:?JWT_SECRET must be set in ${api_gateway_env_file}}"
: "${auth_jwt_secret:?JWT_SECRET must be set in ${auth_service_env_file}}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in ${k6_runner_env_file}}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in ${k6_runner_env_file}}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/postgres?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic api-gateway-secret --namespace msa \
  --from-literal=APP_ENV="${api_app_env:-production}" \
  --from-literal=HTTP_PORT="${api_http_port:-8080}" \
  --from-literal=SERVICE_NAME="${api_service_name:-api-gateway}" \
  --from-literal=JWT_SECRET="$api_jwt_secret" \
  --from-literal=AUTH_SERVICE_ADDR="${api_auth_service_addr:-dns:///auth-service-headless.msa.svc.cluster.local:50051}" \
  --from-literal=ITEM_SERVICE_ADDR="${api_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}" \
  --from-literal=TRANSACTION_SERVICE_ADDR="${api_transaction_service_addr:-dns:///transaction-service-headless.msa.svc.cluster.local:50053}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic auth-service-secret --namespace msa \
  --from-literal=APP_ENV="${auth_app_env:-production}" \
  --from-literal=GRPC_PORT="${auth_grpc_port:-50051}" \
  --from-literal=SERVICE_NAME="${auth_service_name:-auth-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST="${auth_bcrypt_cost:-10}" \
  --from-literal=JWT_SECRET="$auth_jwt_secret" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic item-service-secret --namespace msa \
  --from-literal=APP_ENV="${item_app_env:-production}" \
  --from-literal=GRPC_PORT="${item_grpc_port:-50052}" \
  --from-literal=SERVICE_NAME="${item_service_name:-item-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic transaction-service-secret --namespace msa \
  --from-literal=APP_ENV="${transaction_app_env:-production}" \
  --from-literal=GRPC_PORT="${transaction_grpc_port:-50053}" \
  --from-literal=SERVICE_NAME="${transaction_service_name:-transaction-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR="${transaction_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}" \
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
