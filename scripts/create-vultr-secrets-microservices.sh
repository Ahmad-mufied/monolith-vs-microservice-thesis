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

for file in env/vultr.env env/values.yaml; do
  [ -f "$file" ] || { echo "missing $file; run: make env-init" >&2; exit 1; }
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
  postgres_ip="$(terraform_output_required infra/terraform/vultr msa_postgres_private_ip "microservices PostgreSQL private IP")"
fi
encoded_db_password="$(url_encode "$POSTGRES_PASSWORD")"
context="${VULTR_CONTEXT:-msa}"
K8S="kubectl --context=${context}"

# API Gateway
api_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".JWT_SECRET")}"
api_jwt_secret="$(resolve_preserved_secret_value "$api_jwt_secret" "$context" msa api-gateway-secret JWT_SECRET || true)"
api_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".APP_ENV")}"
api_http_port="${HTTP_PORT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".HTTP_PORT")}"
api_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".SERVICE_NAME")}"
api_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".DIAGNOSTIC_LOGGING_ENABLED")}"
api_auth_service_addr="${AUTH_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".AUTH_SERVICE_ADDR")}"
api_item_service_addr="${ITEM_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".ITEM_SERVICE_ADDR")}"
api_transaction_service_addr="${TRANSACTION_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".TRANSACTION_SERVICE_ADDR")}"
raw_api_grpc_call_timeout="${GRPC_CALL_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".GRPC_CALL_TIMEOUT")}"
raw_api_request_timeout="${REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".REQUEST_TIMEOUT")}"
raw_api_http_write_timeout="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".HTTP_WRITE_TIMEOUT")}"

# Auth Service
auth_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.microservices.\"auth-service\".JWT_SECRET")}"
auth_jwt_secret="$(resolve_preserved_secret_value "$auth_jwt_secret" "$context" msa auth-service-secret JWT_SECRET || true)"
auth_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"auth-service\".APP_ENV")}"
auth_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".GRPC_PORT")}"
auth_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".SERVICE_NAME")}"
auth_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
auth_bcrypt_cost="${BCRYPT_COST:-$(read_yaml_value ".cluster.microservices.\"auth-service\".BCRYPT_COST")}"
raw_auth_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".GRPC_REQUEST_TIMEOUT")}"
auth_login_admission_enabled="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_ADMISSION_ENABLED")}"
auth_login_max_concurrency="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY")}"
auth_login_max_concurrency_hpa="${LOGIN_MAX_CONCURRENCY_HPA:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY_HPA")}"
auth_login_queue_timeout="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_QUEUE_TIMEOUT")}"
auth_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONNS")}"
auth_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MIN_CONNS")}"
auth_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONN_LIFETIME")}"
auth_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
auth_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_PING_TIMEOUT")}"

# Item Service
item_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"item-service\".APP_ENV")}"
item_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"item-service\".GRPC_PORT")}"
item_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"item-service\".SERVICE_NAME")}"
item_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"item-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
raw_item_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"item-service\".GRPC_REQUEST_TIMEOUT")}"
item_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONNS")}"
item_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MIN_CONNS")}"
item_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONN_LIFETIME")}"
item_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
item_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_PING_TIMEOUT")}"

# Transaction Service
transaction_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".APP_ENV")}"
transaction_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".GRPC_PORT")}"
transaction_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".SERVICE_NAME")}"
transaction_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
transaction_item_service_addr="${ITEM_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".ITEM_SERVICE_ADDR")}"
raw_transaction_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".GRPC_REQUEST_TIMEOUT")}"
raw_transaction_item_validation_timeout="${ITEM_VALIDATION_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".ITEM_VALIDATION_TIMEOUT")}"
transaction_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONNS")}"
transaction_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MIN_CONNS")}"
transaction_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONN_LIFETIME")}"
transaction_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
transaction_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_PING_TIMEOUT")}"

# Admin Credentials
admin_user_email="${ADMIN_USER_EMAIL:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_EMAIL")}"
admin_user_email="$(resolve_preserved_secret_value "$admin_user_email" "$context" benchmark k6-runner-secret ADMIN_USER_EMAIL || true)"
admin_user_password="${ADMIN_USER_PASSWORD:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_PASSWORD")}"
admin_user_password="$(resolve_preserved_secret_value "$admin_user_password" "$context" benchmark k6-runner-secret ADMIN_USER_PASSWORD || true)"

: "${api_jwt_secret:?JWT_SECRET must be set in env/values.yaml under .cluster.microservices.api-gateway.JWT_SECRET}"
: "${auth_jwt_secret:?JWT_SECRET must be set in env/values.yaml under .cluster.microservices.auth-service.JWT_SECRET}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_EMAIL}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_PASSWORD}"

effective_auth_login_max_concurrency="$(resolve_login_max_concurrency_for_mode "${SCALING_MODE:-fixed}" "$auth_login_max_concurrency" "$auth_login_max_concurrency_hpa" "2" "1")"

api_gateway_secret_pairs=()
append_secret_pair api_gateway_secret_pairs APP_ENV "${api_app_env:-production}"
append_secret_pair api_gateway_secret_pairs HTTP_PORT "${api_http_port:-8080}"
append_secret_pair api_gateway_secret_pairs SERVICE_NAME "${api_service_name:-api-gateway}"
append_secret_pair api_gateway_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${api_diagnostic_logging_enabled:-false}"
append_secret_pair api_gateway_secret_pairs JWT_SECRET "$api_jwt_secret"
append_secret_pair api_gateway_secret_pairs AUTH_SERVICE_ADDR "${api_auth_service_addr:-dns:///auth-service-headless.msa.svc.cluster.local:50051}"
append_secret_pair api_gateway_secret_pairs ITEM_SERVICE_ADDR "${api_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}"
append_secret_pair api_gateway_secret_pairs TRANSACTION_SERVICE_ADDR "${api_transaction_service_addr:-dns:///transaction-service-headless.msa.svc.cluster.local:50053}"

effective_api_grpc_call_timeout="${raw_api_grpc_call_timeout:-32s}"
effective_api_http_write_timeout="40s"
if [[ -n "$raw_api_http_write_timeout" ]]; then
  effective_api_http_write_timeout="$(normalize_http_write_timeout "$raw_api_http_write_timeout" "40s")"
fi
if [[ -n "$raw_api_grpc_call_timeout" || -n "$raw_api_request_timeout" || "$effective_api_http_write_timeout" != "40s" ]]; then
  api_request_timeout="$(derive_gateway_request_timeout "$raw_api_request_timeout" "$effective_api_http_write_timeout" "$effective_api_grpc_call_timeout")"
  validate_gateway_timeout_chain "$effective_api_grpc_call_timeout" "$api_request_timeout" "$effective_api_http_write_timeout"
  append_secret_pair_if_override api_gateway_secret_pairs GRPC_CALL_TIMEOUT "$effective_api_grpc_call_timeout" "32s"
  append_secret_pair_if_override api_gateway_secret_pairs REQUEST_TIMEOUT "$api_request_timeout" "35s"
  append_secret_pair_if_override api_gateway_secret_pairs HTTP_WRITE_TIMEOUT "$effective_api_http_write_timeout" "40s"
fi

auth_service_secret_pairs=()
append_secret_pair auth_service_secret_pairs APP_ENV "${auth_app_env:-production}"
append_secret_pair auth_service_secret_pairs GRPC_PORT "${auth_grpc_port:-50051}"
append_secret_pair auth_service_secret_pairs SERVICE_NAME "${auth_service_name:-auth-service}"
append_secret_pair auth_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${auth_diagnostic_logging_enabled:-false}"
append_secret_pair auth_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/auth_db?sslmode=require"
append_secret_pair auth_service_secret_pairs JWT_SECRET "$auth_jwt_secret"
append_secret_pair_if_override auth_service_secret_pairs BCRYPT_COST "$auth_bcrypt_cost" "10"
append_secret_pair_if_override auth_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_auth_grpc_request_timeout" "30s"
if [[ -n "$auth_login_admission_enabled" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_ADMISSION_ENABLED "$auth_login_admission_enabled" "true"
fi
if [[ "${auth_login_admission_enabled:-true}" == "true" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_MAX_CONCURRENCY "$effective_auth_login_max_concurrency" "2"
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_QUEUE_TIMEOUT "$auth_login_queue_timeout" "2s"
fi
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONNS "$auth_db_pool_max_conns" "6"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MIN_CONNS "$auth_db_pool_min_conns" "1"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$auth_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$auth_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override auth_service_secret_pairs DB_PING_TIMEOUT "$auth_db_ping_timeout" "5s"

item_service_secret_pairs=()
append_secret_pair item_service_secret_pairs APP_ENV "${item_app_env:-production}"
append_secret_pair item_service_secret_pairs GRPC_PORT "${item_grpc_port:-50052}"
append_secret_pair item_service_secret_pairs SERVICE_NAME "${item_service_name:-item-service}"
append_secret_pair item_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${item_diagnostic_logging_enabled:-false}"
append_secret_pair item_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/item_db?sslmode=require"
append_secret_pair_if_override item_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_item_grpc_request_timeout" "30s"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONNS "$item_db_pool_max_conns" "6"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MIN_CONNS "$item_db_pool_min_conns" "1"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$item_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$item_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override item_service_secret_pairs DB_PING_TIMEOUT "$item_db_ping_timeout" "5s"

transaction_service_secret_pairs=()
append_secret_pair transaction_service_secret_pairs APP_ENV "${transaction_app_env:-production}"
append_secret_pair transaction_service_secret_pairs GRPC_PORT "${transaction_grpc_port:-50053}"
append_secret_pair transaction_service_secret_pairs SERVICE_NAME "${transaction_service_name:-transaction-service}"
append_secret_pair transaction_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${transaction_diagnostic_logging_enabled:-false}"
append_secret_pair transaction_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/transaction_db?sslmode=require"
append_secret_pair transaction_service_secret_pairs ITEM_SERVICE_ADDR "${transaction_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}"

effective_transaction_grpc_request_timeout="${raw_transaction_grpc_request_timeout:-30s}"
effective_transaction_item_validation_timeout="${raw_transaction_item_validation_timeout:-25s}"
if [[ -n "$raw_transaction_item_validation_timeout" || -n "$raw_transaction_grpc_request_timeout" ]]; then
  if [[ -z "$raw_transaction_item_validation_timeout" ]]; then
    effective_transaction_item_validation_timeout="$(derive_item_validation_timeout "" "$effective_transaction_grpc_request_timeout")"
  fi
  validate_transaction_timeout_chain "$effective_transaction_grpc_request_timeout" "$effective_transaction_item_validation_timeout"
  append_secret_pair_if_override transaction_service_secret_pairs GRPC_REQUEST_TIMEOUT "$effective_transaction_grpc_request_timeout" "30s"
  append_secret_pair_if_override transaction_service_secret_pairs ITEM_VALIDATION_TIMEOUT "$effective_transaction_item_validation_timeout" "25s"
fi
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONNS "$transaction_db_pool_max_conns" "6"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MIN_CONNS "$transaction_db_pool_min_conns" "1"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$transaction_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$transaction_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override transaction_service_secret_pairs DB_PING_TIMEOUT "$transaction_db_ping_timeout" "5s"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/postgres?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

apply_secret_from_pairs "$context" msa api-gateway-secret "${api_gateway_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa auth-service-secret "${auth_service_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa item-service-secret "${item_service_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa transaction-service-secret "${transaction_service_secret_pairs[@]}"

$K8S create secret generic k6-runner-secret --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "Vultr microservices secrets created"
