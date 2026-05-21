#!/usr/bin/env bash
set -euo pipefail

required_files=(
  env/postgres.env
  env/api-gateway.env
  env/auth-service.env
  env/item-service.env
  env/transaction-service.env
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init-microservices" >&2
    exit 1
  fi
done

read_env_value() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

bash scripts/create-local-postgres-secrets.sh

set -a
source env/postgres.env
set +a

encoded_user="$(url_encode "$POSTGRES_USER")"
encoded_pass="$(url_encode "$POSTGRES_PASSWORD")"

cluster_auth_database_url="postgres://${encoded_user}:${encoded_pass}@postgres.local-database.svc.cluster.local:5432/auth_db?sslmode=disable"
cluster_item_database_url="postgres://${encoded_user}:${encoded_pass}@postgres.local-database.svc.cluster.local:5432/item_db?sslmode=disable"
cluster_transaction_database_url="postgres://${encoded_user}:${encoded_pass}@postgres.local-database.svc.cluster.local:5432/transaction_db?sslmode=disable"

api_gateway_http_port="$(read_env_value env/api-gateway.env HTTP_PORT)"
api_gateway_http_port="${api_gateway_http_port:-8080}"
api_gateway_jwt_secret="$(read_env_value env/api-gateway.env JWT_SECRET)"

auth_grpc_port="$(read_env_value env/auth-service.env GRPC_PORT)"
auth_grpc_port="${auth_grpc_port:-50051}"
auth_jwt_secret="$(read_env_value env/auth-service.env JWT_SECRET)"

if [[ -z "${api_gateway_jwt_secret:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/api-gateway.env" >&2
  exit 1
fi

if [[ -z "${auth_jwt_secret:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/auth-service.env" >&2
  exit 1
fi

auth_jwt_expiry="$(read_env_value env/auth-service.env JWT_EXPIRY)"
auth_jwt_expiry="${auth_jwt_expiry:-24h}"
auth_bcrypt_cost="$(read_env_value env/auth-service.env BCRYPT_COST)"
auth_bcrypt_cost="${auth_bcrypt_cost:-12}"

item_grpc_port="$(read_env_value env/item-service.env GRPC_PORT)"
item_grpc_port="${item_grpc_port:-50052}"

tx_grpc_port="$(read_env_value env/transaction-service.env GRPC_PORT)"
tx_grpc_port="${tx_grpc_port:-50053}"

api_gateway_datadog_enabled="$(read_env_value env/api-gateway.env DATADOG_ENABLED)"
api_gateway_datadog_enabled="${api_gateway_datadog_enabled:-false}"
auth_datadog_enabled="$(read_env_value env/auth-service.env DATADOG_ENABLED)"
auth_datadog_enabled="${auth_datadog_enabled:-false}"
item_datadog_enabled="$(read_env_value env/item-service.env DATADOG_ENABLED)"
item_datadog_enabled="${item_datadog_enabled:-false}"
transaction_datadog_enabled="$(read_env_value env/transaction-service.env DATADOG_ENABLED)"
transaction_datadog_enabled="${transaction_datadog_enabled:-false}"

tmp_api_gateway_env="$(mktemp /tmp/api-gateway-k8s-env.XXXXXX)"
tmp_auth_service_env="$(mktemp /tmp/auth-service-k8s-env.XXXXXX)"
tmp_item_service_env="$(mktemp /tmp/item-service-k8s-env.XXXXXX)"
tmp_transaction_service_env="$(mktemp /tmp/transaction-service-k8s-env.XXXXXX)"
trap 'rm -f "$tmp_api_gateway_env" "$tmp_auth_service_env" "$tmp_item_service_env" "$tmp_transaction_service_env"' EXIT

cat >"$tmp_api_gateway_env" <<EOFGW
HTTP_PORT=${api_gateway_http_port}
JWT_SECRET=${api_gateway_jwt_secret}
AUTH_SERVICE_ADDR=auth-service:${auth_grpc_port}
ITEM_SERVICE_ADDR=item-service:${item_grpc_port}
TRANSACTION_SERVICE_ADDR=transaction-service:${tx_grpc_port}
DATADOG_ENABLED=${api_gateway_datadog_enabled}
EOFGW

cat >"$tmp_auth_service_env" <<EOFAUTH
GRPC_PORT=${auth_grpc_port}
DATABASE_URL=${cluster_auth_database_url}
AUTH_DATABASE_URL=${cluster_auth_database_url}
JWT_SECRET=${auth_jwt_secret}
JWT_EXPIRY=${auth_jwt_expiry}
BCRYPT_COST=${auth_bcrypt_cost}
DATADOG_ENABLED=${auth_datadog_enabled}
EOFAUTH

cat >"$tmp_item_service_env" <<EOFITEM
GRPC_PORT=${item_grpc_port}
DATABASE_URL=${cluster_item_database_url}
ITEM_DATABASE_URL=${cluster_item_database_url}
DATADOG_ENABLED=${item_datadog_enabled}
EOFITEM

cat >"$tmp_transaction_service_env" <<EOFTX
GRPC_PORT=${tx_grpc_port}
DATABASE_URL=${cluster_transaction_database_url}
TRANSACTION_DATABASE_URL=${cluster_transaction_database_url}
ITEM_SERVICE_ADDR=item-service:${item_grpc_port}
DATADOG_ENABLED=${transaction_datadog_enabled}
EOFTX

kubectl create secret generic api-gateway-secret \
  --namespace msa \
  --from-env-file "$tmp_api_gateway_env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic auth-service-secret \
  --namespace msa \
  --from-env-file "$tmp_auth_service_env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic item-service-secret \
  --namespace msa \
  --from-env-file "$tmp_item_service_env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic transaction-service-secret \
  --namespace msa \
  --from-env-file "$tmp_transaction_service_env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "local microservices Kubernetes secrets created"
