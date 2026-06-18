#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

url_encode() {
  local string="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to URL-encode database credentials" >&2
    exit 1
  fi

  printf '%s' "$string" | jq -sRr @uri
}

for file in env/terraform.experiment.env env/values.yaml; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init" >&2
    exit 1
  fi
done

read_env_value() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

db_password="$(read_env_value env/terraform.experiment.env DB_PASSWORD)"
context="${SEQUENTIAL_CONTEXT:-benchmark}"

# Admin user email and password
admin_user_email="${ADMIN_USER_EMAIL:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_EMAIL")}"
admin_user_email="$(resolve_preserved_secret_value "$admin_user_email" "$context" benchmark k6-runner-secret ADMIN_USER_EMAIL || true)"

admin_user_password="${ADMIN_USER_PASSWORD:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_PASSWORD")}"
admin_user_password="$(resolve_preserved_secret_value "$admin_user_password" "$context" benchmark k6-runner-secret ADMIN_USER_PASSWORD || true)"

# Monolith
monolith_app_env="${APP_ENV:-$(read_yaml_value ".cluster.monolith.APP_ENV")}"
monolith_app_port="${APP_PORT:-$(read_yaml_value ".cluster.monolith.APP_PORT")}"
monolith_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.monolith.SERVICE_NAME")}"
monolith_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.monolith.JWT_SECRET")}"
monolith_jwt_secret="$(resolve_preserved_secret_value "$monolith_jwt_secret" "$context" mono monolith-env JWT_SECRET || true)"
monolith_pool_max="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONNS")}"
monolith_pool_min="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.monolith.DB_POOL_MIN_CONNS")}"
monolith_pool_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONN_LIFETIME")}"
monolith_pool_idle="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONN_IDLE_TIME")}"
monolith_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.monolith.DB_PING_TIMEOUT")}"
monolith_read_header_timeout="${HTTP_READ_HEADER_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_READ_HEADER_TIMEOUT")}"
monolith_read_timeout="${HTTP_READ_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_READ_TIMEOUT")}"
raw_monolith_write_timeout="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_WRITE_TIMEOUT")}"
monolith_idle_timeout="${HTTP_IDLE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_IDLE_TIMEOUT")}"
monolith_shutdown_timeout="${HTTP_SHUTDOWN_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_SHUTDOWN_TIMEOUT")}"
monolith_max_header_bytes="${HTTP_MAX_HEADER_BYTES:-$(read_yaml_value ".cluster.monolith.HTTP_MAX_HEADER_BYTES")}"
monolith_bcrypt_cost="${BCRYPT_COST:-$(read_yaml_value ".cluster.monolith.BCRYPT_COST")}"
monolith_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.monolith.DIAGNOSTIC_LOGGING_ENABLED")}"
raw_monolith_app_request_timeout="${APP_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.monolith.APP_REQUEST_TIMEOUT")}"
monolith_login_admission_enabled="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".cluster.monolith.LOGIN_ADMISSION_ENABLED")}"
monolith_login_max_concurrency="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".cluster.monolith.LOGIN_MAX_CONCURRENCY")}"
monolith_login_queue_timeout="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.LOGIN_QUEUE_TIMEOUT")}"

# API Gateway
api_gateway_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".APP_ENV")}"
api_gateway_http_port="${HTTP_PORT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".HTTP_PORT")}"
api_gateway_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".SERVICE_NAME")}"
api_gateway_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".DIAGNOSTIC_LOGGING_ENABLED")}"
api_gateway_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".JWT_SECRET")}"
api_gateway_jwt_secret="$(resolve_preserved_secret_value "$api_gateway_jwt_secret" "$context" msa api-gateway-secret JWT_SECRET || true)"
api_gateway_auth_service_addr="${AUTH_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".AUTH_SERVICE_ADDR")}"
api_gateway_item_service_addr="${ITEM_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".ITEM_SERVICE_ADDR")}"
api_gateway_transaction_service_addr="${TRANSACTION_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".TRANSACTION_SERVICE_ADDR")}"
raw_api_gateway_grpc_call_timeout="${GRPC_CALL_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".GRPC_CALL_TIMEOUT")}"
raw_api_gateway_request_timeout="${REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".REQUEST_TIMEOUT")}"
raw_api_gateway_http_write_timeout="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"api-gateway\".HTTP_WRITE_TIMEOUT")}"

# Auth Service
auth_service_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"auth-service\".APP_ENV")}"
auth_service_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".GRPC_PORT")}"
auth_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".SERVICE_NAME")}"
auth_service_jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.microservices.\"auth-service\".JWT_SECRET")}"
auth_service_jwt_secret="$(resolve_preserved_secret_value "$auth_service_jwt_secret" "$context" msa auth-service-secret JWT_SECRET || true)"
auth_service_bcrypt_cost="${BCRYPT_COST:-$(read_yaml_value ".cluster.microservices.\"auth-service\".BCRYPT_COST")}"
auth_service_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
raw_auth_service_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".GRPC_REQUEST_TIMEOUT")}"
auth_service_login_admission_enabled="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_ADMISSION_ENABLED")}"
auth_service_login_max_concurrency="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY")}"
auth_service_login_max_concurrency_hpa="${LOGIN_MAX_CONCURRENCY_HPA:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_MAX_CONCURRENCY_HPA")}"
auth_service_login_queue_timeout="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".LOGIN_QUEUE_TIMEOUT")}"
auth_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONNS")}"
auth_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MIN_CONNS")}"
auth_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONN_LIFETIME")}"
auth_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
auth_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"auth-service\".DB_PING_TIMEOUT")}"

# Item Service
item_service_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"item-service\".APP_ENV")}"
item_service_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"item-service\".GRPC_PORT")}"
item_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"item-service\".SERVICE_NAME")}"
item_service_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"item-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
raw_item_service_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"item-service\".GRPC_REQUEST_TIMEOUT")}"
item_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONNS")}"
item_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MIN_CONNS")}"
item_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONN_LIFETIME")}"
item_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
item_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"item-service\".DB_PING_TIMEOUT")}"

# Transaction Service
transaction_service_app_env="${APP_ENV:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".APP_ENV")}"
transaction_service_grpc_port="${GRPC_PORT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".GRPC_PORT")}"
transaction_service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".SERVICE_NAME")}"
transaction_service_diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DIAGNOSTIC_LOGGING_ENABLED")}"
transaction_service_item_service_addr="${ITEM_SERVICE_ADDR:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".ITEM_SERVICE_ADDR")}"
raw_transaction_service_grpc_request_timeout="${GRPC_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".GRPC_REQUEST_TIMEOUT")}"
raw_transaction_service_item_validation_timeout="${ITEM_VALIDATION_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".ITEM_VALIDATION_TIMEOUT")}"
transaction_db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONNS")}"
transaction_db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MIN_CONNS")}"
transaction_db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONN_LIFETIME")}"
transaction_db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_POOL_MAX_CONN_IDLE_TIME")}"
transaction_db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.microservices.\"transaction-service\".DB_PING_TIMEOUT")}"

: "${db_password:?DB_PASSWORD must be set in env/terraform.experiment.env}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_EMAIL}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_PASSWORD}"
: "${monolith_jwt_secret:?monolith_jwt_secret must be set in env/values.yaml under .cluster.monolith.JWT_SECRET}"
: "${api_gateway_jwt_secret:?api_gateway_jwt_secret must be set in env/values.yaml under .cluster.microservices.api-gateway.JWT_SECRET}"
: "${auth_service_jwt_secret:?auth_service_jwt_secret must be set in env/values.yaml under .cluster.microservices.auth-service.JWT_SECRET}"

effective_auth_login_max_concurrency="$(resolve_login_max_concurrency_for_mode "${SCALING_MODE:-fixed}" "$auth_service_login_max_concurrency" "$auth_service_login_max_concurrency_hpa" "2" "1")"

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

temp_secret_files=()
cleanup() {
  local file
  for file in "${temp_secret_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

create_secret_from_pairs() {
  local namespace="$1"
  local secret_name="$2"
  shift 2

  apply_secret_from_pairs "$context" "$namespace" "$secret_name" "$@"
}

sequential_rds="$(terraform_with_profile -chdir=infra/terraform/aws-sequential output -raw sequential_rds_endpoint)"
encoded_db_password="$(url_encode "$db_password")"
K8S="kubectl --context=${context}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

create_secret_from_pairs benchmark db-bootstrap-env \
  BOOTSTRAP_DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/bootstrap?sslmode=require"

monolith_secret_pairs=()
append_secret_pair monolith_secret_pairs APP_ENV "${monolith_app_env:-production}"
append_secret_pair monolith_secret_pairs APP_PORT "${monolith_app_port:-8080}"
append_secret_pair monolith_secret_pairs SERVICE_NAME "${monolith_service_name:-monolith}"
append_secret_pair monolith_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/mono_db?sslmode=require"
append_secret_pair monolith_secret_pairs JWT_SECRET "$monolith_jwt_secret"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONNS "$monolith_pool_max" "25"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MIN_CONNS "$monolith_pool_min" "2"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$monolith_pool_lifetime" "5m"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$monolith_pool_idle" "1m"
append_secret_pair_if_override monolith_secret_pairs DB_PING_TIMEOUT "$monolith_db_ping_timeout" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_HEADER_TIMEOUT "$monolith_read_header_timeout" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_TIMEOUT "$monolith_read_timeout" "15s"
append_secret_pair_if_override monolith_secret_pairs HTTP_IDLE_TIMEOUT "$monolith_idle_timeout" "1m"
append_secret_pair_if_override monolith_secret_pairs HTTP_SHUTDOWN_TIMEOUT "$monolith_shutdown_timeout" "10s"
append_secret_pair_if_override monolith_secret_pairs HTTP_MAX_HEADER_BYTES "$monolith_max_header_bytes" "1048576"
append_secret_pair_if_override monolith_secret_pairs BCRYPT_COST "$monolith_bcrypt_cost" "10"
append_secret_pair monolith_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${monolith_diagnostic_logging_enabled:-false}"
effective_monolith_write_timeout="40s"
if [[ -n "$raw_monolith_write_timeout" ]]; then
  effective_monolith_write_timeout="$(normalize_http_write_timeout "$raw_monolith_write_timeout" "40s")"
fi
if [[ -n "$raw_monolith_app_request_timeout" || "$effective_monolith_write_timeout" != "40s" ]]; then
  effective_monolith_app_request_timeout="$(derive_app_request_timeout "$raw_monolith_app_request_timeout" "$effective_monolith_write_timeout")"
  validate_monolith_timeout_chain "$effective_monolith_app_request_timeout" "$effective_monolith_write_timeout"
  append_secret_pair_if_override monolith_secret_pairs HTTP_WRITE_TIMEOUT "$effective_monolith_write_timeout" "40s"
  append_secret_pair_if_override monolith_secret_pairs APP_REQUEST_TIMEOUT "$effective_monolith_app_request_timeout" "35s"
fi
if [[ -n "$monolith_login_admission_enabled" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_ADMISSION_ENABLED "$monolith_login_admission_enabled" "true"
fi
if [[ "${monolith_login_admission_enabled:-true}" == "true" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_MAX_CONCURRENCY "$monolith_login_max_concurrency" "8"
  append_secret_pair_if_override monolith_secret_pairs LOGIN_QUEUE_TIMEOUT "$monolith_login_queue_timeout" "2s"
fi
create_secret_from_pairs mono monolith-env "${monolith_secret_pairs[@]}"

api_gateway_secret_pairs=()
append_secret_pair api_gateway_secret_pairs APP_ENV "${api_gateway_app_env:-production}"
append_secret_pair api_gateway_secret_pairs HTTP_PORT "${api_gateway_http_port:-8080}"
append_secret_pair api_gateway_secret_pairs SERVICE_NAME "${api_gateway_service_name:-api-gateway}"
append_secret_pair api_gateway_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${api_gateway_diagnostic_logging_enabled:-false}"
append_secret_pair api_gateway_secret_pairs JWT_SECRET "$api_gateway_jwt_secret"
append_secret_pair api_gateway_secret_pairs AUTH_SERVICE_ADDR "${api_gateway_auth_service_addr:-dns:///auth-service-headless.msa.svc.cluster.local:50051}"
append_secret_pair api_gateway_secret_pairs ITEM_SERVICE_ADDR "${api_gateway_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}"
append_secret_pair api_gateway_secret_pairs TRANSACTION_SERVICE_ADDR "${api_gateway_transaction_service_addr:-dns:///transaction-service-headless.msa.svc.cluster.local:50053}"
effective_api_gateway_grpc_call_timeout="${raw_api_gateway_grpc_call_timeout:-32s}"
effective_api_gateway_http_write_timeout="40s"
if [[ -n "$raw_api_gateway_http_write_timeout" ]]; then
  effective_api_gateway_http_write_timeout="$(normalize_http_write_timeout "$raw_api_gateway_http_write_timeout" "40s")"
fi
if [[ -n "$raw_api_gateway_grpc_call_timeout" || -n "$raw_api_gateway_request_timeout" || "$effective_api_gateway_http_write_timeout" != "40s" ]]; then
  effective_api_gateway_request_timeout="$(derive_gateway_request_timeout "$raw_api_gateway_request_timeout" "$effective_api_gateway_http_write_timeout" "$effective_api_gateway_grpc_call_timeout")"
  validate_gateway_timeout_chain "$effective_api_gateway_grpc_call_timeout" "$effective_api_gateway_request_timeout" "$effective_api_gateway_http_write_timeout"
  append_secret_pair_if_override api_gateway_secret_pairs GRPC_CALL_TIMEOUT "$effective_api_gateway_grpc_call_timeout" "32s"
  append_secret_pair_if_override api_gateway_secret_pairs REQUEST_TIMEOUT "$effective_api_gateway_request_timeout" "35s"
  append_secret_pair_if_override api_gateway_secret_pairs HTTP_WRITE_TIMEOUT "$effective_api_gateway_http_write_timeout" "40s"
fi
create_secret_from_pairs msa api-gateway-secret "${api_gateway_secret_pairs[@]}"

auth_service_secret_pairs=()
append_secret_pair auth_service_secret_pairs APP_ENV "${auth_service_app_env:-production}"
append_secret_pair auth_service_secret_pairs GRPC_PORT "${auth_service_grpc_port:-50051}"
append_secret_pair auth_service_secret_pairs SERVICE_NAME "${auth_service_name:-auth-service}"
append_secret_pair auth_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${auth_service_diagnostic_logging_enabled:-false}"
append_secret_pair auth_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/auth_db?sslmode=require"
append_secret_pair auth_service_secret_pairs JWT_SECRET "$auth_service_jwt_secret"
append_secret_pair_if_override auth_service_secret_pairs BCRYPT_COST "$auth_service_bcrypt_cost" "10"
append_secret_pair_if_override auth_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_auth_service_grpc_request_timeout" "30s"
if [[ -n "$auth_service_login_admission_enabled" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_ADMISSION_ENABLED "$auth_service_login_admission_enabled" "true"
fi
if [[ "${auth_service_login_admission_enabled:-true}" == "true" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_MAX_CONCURRENCY "$effective_auth_login_max_concurrency" "2"
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_QUEUE_TIMEOUT "$auth_service_login_queue_timeout" "2s"
fi
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONNS "$auth_db_pool_max_conns" "6"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MIN_CONNS "$auth_db_pool_min_conns" "1"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$auth_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override auth_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$auth_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override auth_service_secret_pairs DB_PING_TIMEOUT "$auth_db_ping_timeout" "5s"
create_secret_from_pairs msa auth-service-secret "${auth_service_secret_pairs[@]}"

item_service_secret_pairs=()
append_secret_pair item_service_secret_pairs APP_ENV "${item_service_app_env:-production}"
append_secret_pair item_service_secret_pairs GRPC_PORT "${item_service_grpc_port:-50052}"
append_secret_pair item_service_secret_pairs SERVICE_NAME "${item_service_name:-item-service}"
append_secret_pair item_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${item_service_diagnostic_logging_enabled:-false}"
append_secret_pair item_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/item_db?sslmode=require"
append_secret_pair_if_override item_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_item_service_grpc_request_timeout" "30s"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONNS "$item_db_pool_max_conns" "6"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MIN_CONNS "$item_db_pool_min_conns" "1"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$item_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override item_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$item_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override item_service_secret_pairs DB_PING_TIMEOUT "$item_db_ping_timeout" "5s"
create_secret_from_pairs msa item-service-secret "${item_service_secret_pairs[@]}"

transaction_service_secret_pairs=()
append_secret_pair transaction_service_secret_pairs APP_ENV "${transaction_service_app_env:-production}"
append_secret_pair transaction_service_secret_pairs GRPC_PORT "${transaction_service_grpc_port:-50053}"
append_secret_pair transaction_service_secret_pairs SERVICE_NAME "${transaction_service_name:-transaction-service}"
append_secret_pair transaction_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${transaction_service_diagnostic_logging_enabled:-false}"
append_secret_pair transaction_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/transaction_db?sslmode=require"
append_secret_pair transaction_service_secret_pairs ITEM_SERVICE_ADDR "${transaction_service_item_service_addr:-dns:///item-service-headless.msa.svc.cluster.local:50052}"
effective_transaction_service_grpc_request_timeout="${raw_transaction_service_grpc_request_timeout:-30s}"
effective_transaction_service_item_validation_timeout="${raw_transaction_service_item_validation_timeout:-25s}"
if [[ -n "$raw_transaction_service_item_validation_timeout" || -n "$raw_transaction_service_grpc_request_timeout" ]]; then
  if [[ -z "$raw_transaction_service_item_validation_timeout" ]]; then
    effective_transaction_service_item_validation_timeout="$(derive_item_validation_timeout "" "$effective_transaction_service_grpc_request_timeout")"
  fi
  validate_transaction_timeout_chain "$effective_transaction_service_grpc_request_timeout" "$effective_transaction_service_item_validation_timeout"
  append_secret_pair_if_override transaction_service_secret_pairs GRPC_REQUEST_TIMEOUT "$effective_transaction_service_grpc_request_timeout" "30s"
  append_secret_pair_if_override transaction_service_secret_pairs ITEM_VALIDATION_TIMEOUT "$effective_transaction_service_item_validation_timeout" "25s"
fi
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONNS "$transaction_db_pool_max_conns" "6"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MIN_CONNS "$transaction_db_pool_min_conns" "1"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$transaction_db_pool_max_conn_lifetime" "15m"
append_secret_pair_if_override transaction_service_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$transaction_db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override transaction_service_secret_pairs DB_PING_TIMEOUT "$transaction_db_ping_timeout" "5s"
create_secret_from_pairs msa transaction-service-secret "${transaction_service_secret_pairs[@]}"

create_secret_from_pairs benchmark k6-runner-secret \
  ADMIN_USER_EMAIL "$admin_user_email" \
  ADMIN_USER_PASSWORD "$admin_user_password"

echo "EKS sequential secrets created in context: $context"
