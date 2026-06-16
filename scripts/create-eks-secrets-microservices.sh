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

required_files=(
  "$api_gateway_env_file"
  "$auth_service_env_file"
  "$item_service_env_file"
  "$transaction_service_env_file"
  env/terraform.experiment.env
  "$k6_runner_env_file"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init-app and make env-init-eks" >&2
    exit 1
  fi
done

read_env_value() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

db_password="$(read_env_value env/terraform.experiment.env DB_PASSWORD)"
context="msa"
admin_user_email="$(resolve_preserved_secret_value "$(read_env_value "$k6_runner_env_file" ADMIN_USER_EMAIL)" "$context" benchmark k6-runner-secret ADMIN_USER_EMAIL || true)"
admin_user_password="$(resolve_preserved_secret_value "$(read_env_value "$k6_runner_env_file" ADMIN_USER_PASSWORD)" "$context" benchmark k6-runner-secret ADMIN_USER_PASSWORD || true)"

api_gateway_app_env="$(read_env_value "$api_gateway_env_file" APP_ENV)"
api_gateway_http_port="$(read_env_value "$api_gateway_env_file" HTTP_PORT)"
api_gateway_service_name="$(read_env_value "$api_gateway_env_file" SERVICE_NAME)"
api_gateway_diagnostic_logging_enabled="$(read_env_value "$api_gateway_env_file" DIAGNOSTIC_LOGGING_ENABLED)"
api_gateway_jwt_secret="$(resolve_preserved_secret_value "$(read_env_value "$api_gateway_env_file" JWT_SECRET)" "$context" msa api-gateway-secret JWT_SECRET || true)"
api_gateway_auth_service_addr="$(read_env_value "$api_gateway_env_file" AUTH_SERVICE_ADDR)"
api_gateway_item_service_addr="$(read_env_value "$api_gateway_env_file" ITEM_SERVICE_ADDR)"
api_gateway_transaction_service_addr="$(read_env_value "$api_gateway_env_file" TRANSACTION_SERVICE_ADDR)"
raw_api_gateway_grpc_call_timeout="$(read_env_value "$api_gateway_env_file" GRPC_CALL_TIMEOUT)"
raw_api_gateway_request_timeout="$(read_env_value "$api_gateway_env_file" REQUEST_TIMEOUT)"
raw_api_gateway_http_write_timeout="$(read_env_value "$api_gateway_env_file" HTTP_WRITE_TIMEOUT)"

auth_service_app_env="$(read_env_value "$auth_service_env_file" APP_ENV)"
auth_service_grpc_port="$(read_env_value "$auth_service_env_file" GRPC_PORT)"
auth_service_name="$(read_env_value "$auth_service_env_file" SERVICE_NAME)"
auth_service_diagnostic_logging_enabled="$(read_env_value "$auth_service_env_file" DIAGNOSTIC_LOGGING_ENABLED)"
auth_service_bcrypt_cost="$(read_env_value "$auth_service_env_file" BCRYPT_COST)"
auth_service_jwt_secret="$(resolve_preserved_secret_value "$(read_env_value "$auth_service_env_file" JWT_SECRET)" "$context" msa auth-service-secret JWT_SECRET || true)"
raw_auth_service_grpc_request_timeout="$(read_env_value "$auth_service_env_file" GRPC_REQUEST_TIMEOUT)"
auth_service_login_admission_enabled="$(read_env_value "$auth_service_env_file" LOGIN_ADMISSION_ENABLED)"
auth_service_login_max_concurrency="$(read_env_value "$auth_service_env_file" LOGIN_MAX_CONCURRENCY)"
auth_service_login_queue_timeout="$(read_env_value "$auth_service_env_file" LOGIN_QUEUE_TIMEOUT)"

item_service_app_env="$(read_env_value "$item_service_env_file" APP_ENV)"
item_service_grpc_port="$(read_env_value "$item_service_env_file" GRPC_PORT)"
item_service_name="$(read_env_value "$item_service_env_file" SERVICE_NAME)"
item_service_diagnostic_logging_enabled="$(read_env_value "$item_service_env_file" DIAGNOSTIC_LOGGING_ENABLED)"
raw_item_service_grpc_request_timeout="$(read_env_value "$item_service_env_file" GRPC_REQUEST_TIMEOUT)"

transaction_service_app_env="$(read_env_value "$transaction_service_env_file" APP_ENV)"
transaction_service_grpc_port="$(read_env_value "$transaction_service_env_file" GRPC_PORT)"
transaction_service_name="$(read_env_value "$transaction_service_env_file" SERVICE_NAME)"
transaction_service_diagnostic_logging_enabled="$(read_env_value "$transaction_service_env_file" DIAGNOSTIC_LOGGING_ENABLED)"
transaction_service_item_service_addr="$(read_env_value "$transaction_service_env_file" ITEM_SERVICE_ADDR)"
raw_transaction_service_grpc_request_timeout="$(read_env_value "$transaction_service_env_file" GRPC_REQUEST_TIMEOUT)"
raw_transaction_service_item_validation_timeout="$(read_env_value "$transaction_service_env_file" ITEM_VALIDATION_TIMEOUT)"

: "${db_password:?DB_PASSWORD must be set in env/terraform.experiment.env}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in ${k6_runner_env_file}}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in ${k6_runner_env_file}}"
: "${api_gateway_jwt_secret:?JWT_SECRET must be set in ${api_gateway_env_file}}"
: "${auth_service_jwt_secret:?JWT_SECRET must be set in ${auth_service_env_file}}"

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

MSA_RDS="$(terraform_with_profile -chdir=infra/terraform/aws-parallel output -raw msa_rds_endpoint)"
encoded_db_password="$(url_encode "$db_password")"
K8S="kubectl --context=msa"

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

auth_service_secret_pairs=()
append_secret_pair auth_service_secret_pairs APP_ENV "${auth_service_app_env:-production}"
append_secret_pair auth_service_secret_pairs GRPC_PORT "${auth_service_grpc_port:-50051}"
append_secret_pair auth_service_secret_pairs SERVICE_NAME "${auth_service_name:-auth-service}"
append_secret_pair auth_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${auth_service_diagnostic_logging_enabled:-false}"
append_secret_pair auth_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${MSA_RDS}:5432/auth_db?sslmode=require"
append_secret_pair auth_service_secret_pairs JWT_SECRET "$auth_service_jwt_secret"
append_secret_pair_if_override auth_service_secret_pairs BCRYPT_COST "$auth_service_bcrypt_cost" "10"
append_secret_pair_if_override auth_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_auth_service_grpc_request_timeout" "30s"
if [[ -n "$auth_service_login_admission_enabled" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_ADMISSION_ENABLED "$auth_service_login_admission_enabled" "true"
fi
if [[ "${auth_service_login_admission_enabled:-true}" == "true" ]]; then
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_MAX_CONCURRENCY "$auth_service_login_max_concurrency" "2"
  append_secret_pair_if_override auth_service_secret_pairs LOGIN_QUEUE_TIMEOUT "$auth_service_login_queue_timeout" "2s"
fi

item_service_secret_pairs=()
append_secret_pair item_service_secret_pairs APP_ENV "${item_service_app_env:-production}"
append_secret_pair item_service_secret_pairs GRPC_PORT "${item_service_grpc_port:-50052}"
append_secret_pair item_service_secret_pairs SERVICE_NAME "${item_service_name:-item-service}"
append_secret_pair item_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${item_service_diagnostic_logging_enabled:-false}"
append_secret_pair item_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${MSA_RDS}:5432/item_db?sslmode=require"
append_secret_pair_if_override item_service_secret_pairs GRPC_REQUEST_TIMEOUT "$raw_item_service_grpc_request_timeout" "30s"

transaction_service_secret_pairs=()
append_secret_pair transaction_service_secret_pairs APP_ENV "${transaction_service_app_env:-production}"
append_secret_pair transaction_service_secret_pairs GRPC_PORT "${transaction_service_grpc_port:-50053}"
append_secret_pair transaction_service_secret_pairs SERVICE_NAME "${transaction_service_name:-transaction-service}"
append_secret_pair transaction_service_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${transaction_service_diagnostic_logging_enabled:-false}"
append_secret_pair transaction_service_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${MSA_RDS}:5432/transaction_db?sslmode=require"
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

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${MSA_RDS}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

apply_secret_from_pairs "$context" msa api-gateway-secret "${api_gateway_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa auth-service-secret "${auth_service_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa item-service-secret "${item_service_secret_pairs[@]}"
apply_secret_from_pairs "$context" msa transaction-service-secret "${transaction_service_secret_pairs[@]}"

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "EKS microservices secrets created"
