#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

for file in env/postgres.env env/values.yaml; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init" >&2
    exit 1
  fi
done

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

# API Gateway variables
api_gateway_http_port="${HTTP_PORT:-$(read_yaml_value ".local.microservices.\"api-gateway\".HTTP_PORT")}"
api_gateway_http_port="${api_gateway_http_port:-8080}"
api_gateway_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".local.microservices.\"api-gateway\".JWT_SECRET")}"
api_gateway_grpc_call_timeout="${GRPC_CALL_TIMEOUT:-$(read_yaml_value ".local.microservices.\"api-gateway\".GRPC_CALL_TIMEOUT")}"
api_gateway_grpc_call_timeout="${api_gateway_grpc_call_timeout:-32s}"
api_gateway_request_timeout="${REQUEST_TIMEOUT:-$(read_yaml_value ".local.microservices.\"api-gateway\".REQUEST_TIMEOUT")}"
api_gateway_http_write_timeout="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".local.microservices.\"api-gateway\".HTTP_WRITE_TIMEOUT")}"
api_gateway_http_write_timeout="$(normalize_http_write_timeout "$api_gateway_http_write_timeout" "40s")"
api_gateway_request_timeout="$(derive_gateway_request_timeout "$api_gateway_request_timeout" "$api_gateway_http_write_timeout" "$api_gateway_grpc_call_timeout")"
api_gateway_datadog_enabled="${DATADOG_ENABLED:-$(read_yaml_value ".local.microservices.\"api-gateway\".DATADOG_ENABLED")}"
api_gateway_datadog_enabled="${api_gateway_datadog_enabled:-false}"
api_gateway_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".local.microservices.\"api-gateway\".DIAGNOSTIC_LOGGING_ENABLED")}"
api_gateway_diagnostic_logging_enabled="${api_gateway_diagnostic_logging_enabled:-false}"

# Auth Service variables
auth_grpc_port="${GRPC_PORT:-$(read_yaml_value ".local.microservices.\"auth-service\".GRPC_PORT")}"
auth_grpc_port="${auth_grpc_port:-50051}"
auth_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".local.microservices.\"auth-service\".JWT_SECRET")}"
auth_jwt_expiry="${JWT_EXPIRY:-$(read_yaml_value ".local.microservices.\"auth-service\".JWT_EXPIRY")}"
auth_jwt_expiry="${auth_jwt_expiry:-24h}"
auth_bcrypt_cost="${BCRYPT_COST:-$(read_yaml_value ".local.microservices.\"auth-service\".BCRYPT_COST")}"
auth_bcrypt_cost="${auth_bcrypt_cost:-10}"
auth_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".local.microservices.\"auth-service\".GRPC_REQUEST_TIMEOUT")}"
auth_grpc_request_timeout="${auth_grpc_request_timeout:-30s}"
auth_login_admission_enabled="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".local.microservices.\"auth-service\".LOGIN_ADMISSION_ENABLED")}"
auth_login_admission_enabled="${auth_login_admission_enabled:-true}"
auth_login_max_concurrency="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".local.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY")}"
auth_login_max_concurrency="${auth_login_max_concurrency:-2}"
auth_login_max_concurrency_hpa="${LOGIN_MAX_CONCURRENCY_HPA:-$(read_yaml_value ".local.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY_HPA")}"
auth_login_max_concurrency_hpa="${auth_login_max_concurrency_hpa:-1}"
auth_login_queue_timeout="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".local.microservices.\"auth-service\".LOGIN_QUEUE_TIMEOUT")}"
auth_login_queue_timeout="${auth_login_queue_timeout:-2s}"
auth_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".local.microservices.\"auth-service\".DB_POOL_MAX_CONNS")}"
auth_db_pool_max_conns="${auth_db_pool_max_conns:-6}"
auth_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".local.microservices.\"auth-service\".DB_POOL_MIN_CONNS")}"
auth_db_pool_min_conns="${auth_db_pool_min_conns:-1}"
auth_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".local.microservices.\"auth-service\".DB_POOL_MAX_CONN_LIFETIME")}"
auth_db_pool_max_conn_lifetime="${auth_db_pool_max_conn_lifetime:-15m}"
auth_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".local.microservices.\"auth-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
auth_db_pool_max_conn_idle_time="${auth_db_pool_max_conn_idle_time:-1m}"
auth_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".local.microservices.\"auth-service\".DB_PING_TIMEOUT")}"
auth_db_ping_timeout="${auth_db_ping_timeout:-5s}"
auth_datadog_enabled="${DATADOG_ENABLED:-$(read_yaml_value ".local.microservices.\"auth-service\".DATADOG_ENABLED")}"
auth_datadog_enabled="${auth_datadog_enabled:-false}"
auth_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".local.microservices.\"auth-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
auth_diagnostic_logging_enabled="${auth_diagnostic_logging_enabled:-false}"

# Item Service variables
item_grpc_port="${GRPC_PORT:-$(read_yaml_value ".local.microservices.\"item-service\".GRPC_PORT")}"
item_grpc_port="${item_grpc_port:-50052}"
item_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".local.microservices.\"item-service\".GRPC_REQUEST_TIMEOUT")}"
item_grpc_request_timeout="${item_grpc_request_timeout:-30s}"
item_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".local.microservices.\"item-service\".DB_POOL_MAX_CONNS")}"
item_db_pool_max_conns="${item_db_pool_max_conns:-6}"
item_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".local.microservices.\"item-service\".DB_POOL_MIN_CONNS")}"
item_db_pool_min_conns="${item_db_pool_min_conns:-1}"
item_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".local.microservices.\"item-service\".DB_POOL_MAX_CONN_LIFETIME")}"
item_db_pool_max_conn_lifetime="${item_db_pool_max_conn_lifetime:-15m}"
item_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".local.microservices.\"item-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
item_db_pool_max_conn_idle_time="${item_db_pool_max_conn_idle_time:-1m}"
item_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".local.microservices.\"item-service\".DB_PING_TIMEOUT")}"
item_db_ping_timeout="${item_db_ping_timeout:-5s}"
item_datadog_enabled="${DATADOG_ENABLED:-$(read_yaml_value ".local.microservices.\"item-service\".DATADOG_ENABLED")}"
item_datadog_enabled="${item_datadog_enabled:-false}"
item_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".local.microservices.\"item-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
item_diagnostic_logging_enabled="${item_diagnostic_logging_enabled:-false}"

# Transaction Service variables
tx_grpc_port="${GRPC_PORT:-$(read_yaml_value ".local.microservices.\"transaction-service\".GRPC_PORT")}"
tx_grpc_port="${tx_grpc_port:-50053}"
tx_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".local.microservices.\"transaction-service\".GRPC_REQUEST_TIMEOUT")}"
tx_grpc_request_timeout="${tx_grpc_request_timeout:-30s}"
tx_item_validation_timeout="${ITEM_VALIDATION_TIMEOUT:-$(read_yaml_value ".local.microservices.\"transaction-service\".ITEM_VALIDATION_TIMEOUT")}"
tx_item_validation_timeout="${tx_item_validation_timeout:-25s}"
tx_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".local.microservices.\"transaction-service\".DB_POOL_MAX_CONNS")}"
tx_db_pool_max_conns="${tx_db_pool_max_conns:-6}"
tx_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".local.microservices.\"transaction-service\".DB_POOL_MIN_CONNS")}"
tx_db_pool_min_conns="${tx_db_pool_min_conns:-1}"
tx_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".local.microservices.\"transaction-service\".DB_POOL_MAX_CONN_LIFETIME")}"
tx_db_pool_max_conn_lifetime="${tx_db_pool_max_conn_lifetime:-15m}"
tx_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".local.microservices.\"transaction-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
tx_db_pool_max_conn_idle_time="${tx_db_pool_max_conn_idle_time:-1m}"
tx_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".local.microservices.\"transaction-service\".DB_PING_TIMEOUT")}"
tx_db_ping_timeout="${tx_db_ping_timeout:-5s}"
transaction_datadog_enabled="${DATADOG_ENABLED:-$(read_yaml_value ".local.microservices.\"transaction-service\".DATADOG_ENABLED")}"
transaction_datadog_enabled="${transaction_datadog_enabled:-false}"
transaction_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".local.microservices.\"transaction-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
transaction_diagnostic_logging_enabled="${transaction_diagnostic_logging_enabled:-false}"

if [[ -z "${api_gateway_jwt_secret:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/values.yaml under .local.microservices.api-gateway.JWT_SECRET" >&2
  exit 1
fi

if [[ -z "${auth_jwt_secret:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/values.yaml under .local.microservices.auth-service.JWT_SECRET" >&2
  exit 1
fi

effective_auth_login_max_concurrency="$(resolve_login_max_concurrency_for_mode "${SCALING_MODE:-fixed}" "$auth_login_max_concurrency" "$auth_login_max_concurrency_hpa" "2" "1")"

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
DIAGNOSTIC_LOGGING_ENABLED=${api_gateway_diagnostic_logging_enabled}
GRPC_CALL_TIMEOUT=${api_gateway_grpc_call_timeout}
REQUEST_TIMEOUT=${api_gateway_request_timeout}
HTTP_WRITE_TIMEOUT=${api_gateway_http_write_timeout}
EOFGW

cat >"$tmp_auth_service_env" <<EOFAUTH
GRPC_PORT=${auth_grpc_port}
DATABASE_URL=${cluster_auth_database_url}
AUTH_DATABASE_URL=${cluster_auth_database_url}
JWT_SECRET=${auth_jwt_secret}
JWT_EXPIRY=${auth_jwt_expiry}
BCRYPT_COST=${auth_bcrypt_cost}
DATADOG_ENABLED=${auth_datadog_enabled}
DIAGNOSTIC_LOGGING_ENABLED=${auth_diagnostic_logging_enabled}
GRPC_REQUEST_TIMEOUT=${auth_grpc_request_timeout}
LOGIN_ADMISSION_ENABLED=${auth_login_admission_enabled}
LOGIN_MAX_CONCURRENCY=${effective_auth_login_max_concurrency}
LOGIN_QUEUE_TIMEOUT=${auth_login_queue_timeout}
DB_POOL_MAX_CONNS=${auth_db_pool_max_conns}
DB_POOL_MIN_CONNS=${auth_db_pool_min_conns}
DB_POOL_MAX_CONN_LIFETIME=${auth_db_pool_max_conn_lifetime}
DB_POOL_MAX_CONN_IDLE_TIME=${auth_db_pool_max_conn_idle_time}
DB_PING_TIMEOUT=${auth_db_ping_timeout}
EOFAUTH

cat >"$tmp_item_service_env" <<EOFITEM
GRPC_PORT=${item_grpc_port}
DATABASE_URL=${cluster_item_database_url}
ITEM_DATABASE_URL=${cluster_item_database_url}
DATADOG_ENABLED=${item_datadog_enabled}
DIAGNOSTIC_LOGGING_ENABLED=${item_diagnostic_logging_enabled}
GRPC_REQUEST_TIMEOUT=${item_grpc_request_timeout}
DB_POOL_MAX_CONNS=${item_db_pool_max_conns}
DB_POOL_MIN_CONNS=${item_db_pool_min_conns}
DB_POOL_MAX_CONN_LIFETIME=${item_db_pool_max_conn_lifetime}
DB_POOL_MAX_CONN_IDLE_TIME=${item_db_pool_max_conn_idle_time}
DB_PING_TIMEOUT=${item_db_ping_timeout}
EOFITEM

cat >"$tmp_transaction_service_env" <<EOFTX
GRPC_PORT=${tx_grpc_port}
DATABASE_URL=${cluster_transaction_database_url}
TRANSACTION_DATABASE_URL=${cluster_transaction_database_url}
ITEM_SERVICE_ADDR=item-service:${item_grpc_port}
DATADOG_ENABLED=${transaction_datadog_enabled}
DIAGNOSTIC_LOGGING_ENABLED=${transaction_diagnostic_logging_enabled}
GRPC_REQUEST_TIMEOUT=${tx_grpc_request_timeout}
ITEM_VALIDATION_TIMEOUT=${tx_item_validation_timeout}
DB_POOL_MAX_CONNS=${tx_db_pool_max_conns}
DB_POOL_MIN_CONNS=${tx_db_pool_min_conns}
DB_POOL_MAX_CONN_LIFETIME=${tx_db_pool_max_conn_lifetime}
DB_POOL_MAX_CONN_IDLE_TIME=${tx_db_pool_max_conn_idle_time}
DB_PING_TIMEOUT=${tx_db_ping_timeout}
EOFTX

apply_secret_and_config_from_env_file "" msa api-gateway-secret "$tmp_api_gateway_env"
apply_secret_and_config_from_env_file "" msa auth-service-secret "$tmp_auth_service_env"
apply_secret_and_config_from_env_file "" msa item-service-secret "$tmp_item_service_env"
apply_secret_and_config_from_env_file "" msa transaction-service-secret "$tmp_transaction_service_env"


echo "local microservices Kubernetes secrets created"
