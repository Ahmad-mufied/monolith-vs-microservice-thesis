#!/usr/bin/env bash
set -euo pipefail

url_encode() {
  local string="$1"
  command -v jq >/dev/null 2>&1 || {
    echo "jq is required to URL-encode database credentials" >&2
    exit 1
  }
  printf '%s' "$string" | jq -sRr @uri
}

read_env_value() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

required_files=(
  env/hetzner.env
  env/monolith.eks.env
  env/api-gateway.eks.env
  env/auth-service.eks.env
  env/item-service.eks.env
  env/transaction-service.eks.env
  env/k6-runner.eks.env
)

for file in "${required_files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "missing $file; run: make env-init-eks and make env-init-hetzner" >&2
    exit 1
  fi
done

set -a
source env/hetzner.env
set +a

source scripts/lib/hetzner-s3-credentials.sh
load_hetzner_s3_credentials

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/hetzner.env}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in env/hetzner.env or Terraform shared output hetzner_k6_s3_access_key_id}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in env/hetzner.env or Terraform shared output hetzner_k6_s3_secret_access_key}"
: "${AWS_REGION:?AWS_REGION must be set in env/hetzner.env}"
: "${S3_BUCKET:?S3_BUCKET must be set in env/hetzner.env}"

postgres_ip="$(terraform -chdir=infra/terraform/hetzner-experiment-sequential output -raw postgres_private_ip)"
encoded_db_password="$(url_encode "$POSTGRES_PASSWORD")"
context="${HETZNER_CONTEXT:-benchmark}"
K8S="kubectl --context=${context}"

admin_user_email="$(read_env_value env/k6-runner.eks.env ADMIN_USER_EMAIL)"
admin_user_password="$(read_env_value env/k6-runner.eks.env ADMIN_USER_PASSWORD)"
monolith_jwt_secret="$(read_env_value env/monolith.eks.env JWT_SECRET)"
api_gateway_jwt_secret="$(read_env_value env/api-gateway.eks.env JWT_SECRET)"
auth_service_jwt_secret="$(read_env_value env/auth-service.eks.env JWT_SECRET)"

: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/k6-runner.eks.env}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/k6-runner.eks.env}"
: "${monolith_jwt_secret:?JWT_SECRET must be set in env/monolith.eks.env}"
: "${api_gateway_jwt_secret:?JWT_SECRET must be set in env/api-gateway.eks.env}"
: "${auth_service_jwt_secret:?JWT_SECRET must be set in env/auth-service.eks.env}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic monolith-env \
  --namespace mono \
  --from-literal=APP_ENV=production \
  --from-literal=APP_PORT=8080 \
  --from-literal=SERVICE_NAME=monolith \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/mono_db?sslmode=require" \
  --from-literal=JWT_SECRET="$monolith_jwt_secret" \
  --from-literal=DB_POOL_MAX_CONNS="${DB_POOL_MAX_CONNS:-25}" \
  --from-literal=DB_POOL_MIN_CONNS="${DB_POOL_MIN_CONNS:-2}" \
  --from-literal=DB_POOL_MAX_CONN_LIFETIME="${DB_POOL_MAX_CONN_LIFETIME:-5m}" \
  --from-literal=DB_POOL_MAX_CONN_IDLE_TIME="${DB_POOL_MAX_CONN_IDLE_TIME:-1m}" \
  --from-literal=DB_PING_TIMEOUT="${DB_PING_TIMEOUT:-5s}" \
  --from-literal=HTTP_READ_HEADER_TIMEOUT="${HTTP_READ_HEADER_TIMEOUT:-5s}" \
  --from-literal=HTTP_READ_TIMEOUT="${HTTP_READ_TIMEOUT:-15s}" \
  --from-literal=HTTP_WRITE_TIMEOUT="${HTTP_WRITE_TIMEOUT:-30s}" \
  --from-literal=HTTP_IDLE_TIMEOUT="${HTTP_IDLE_TIMEOUT:-1m}" \
  --from-literal=HTTP_SHUTDOWN_TIMEOUT="${HTTP_SHUTDOWN_TIMEOUT:-10s}" \
  --from-literal=HTTP_MAX_HEADER_BYTES="${HTTP_MAX_HEADER_BYTES:-1048576}" \
  --from-literal=BCRYPT_COST="${BCRYPT_COST:-10}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic api-gateway-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=HTTP_PORT=8080 \
  --from-literal=SERVICE_NAME=api-gateway \
  --from-literal=JWT_SECRET="$api_gateway_jwt_secret" \
  --from-literal=AUTH_SERVICE_ADDR=auth-service.msa.svc.cluster.local:50051 \
  --from-literal=ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052 \
  --from-literal=TRANSACTION_SERVICE_ADDR=transaction-service.msa.svc.cluster.local:50053 \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic auth-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50051 \
  --from-literal=SERVICE_NAME=auth-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST="${BCRYPT_COST:-10}" \
  --from-literal=JWT_SECRET="$auth_service_jwt_secret" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic item-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50052 \
  --from-literal=SERVICE_NAME=item-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic transaction-service-secret \
  --namespace msa \
  --from-literal=APP_ENV=production \
  --from-literal=GRPC_PORT=50053 \
  --from-literal=SERVICE_NAME=transaction-service \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052 \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "Hetzner sequential secrets created in context: $context"
