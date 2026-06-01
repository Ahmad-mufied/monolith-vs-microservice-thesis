#!/usr/bin/env bash
set -euo pipefail

url_encode() {
  local string="$1"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to URL-encode database credentials" >&2
    exit 1
  fi

  printf '%s' "$string" | jq -sRr @uri
}

required_files=(
  env/monolith.eks.env
  env/api-gateway.eks.env
  env/auth-service.eks.env
  env/item-service.eks.env
  env/transaction-service.eks.env
  env/terraform.experiment.env
  env/k6-runner.eks.env
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init-eks" >&2
    exit 1
  fi
done

read_env_value() {
  local file="$1"
  local key="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

db_password="$(read_env_value env/terraform.experiment.env DB_PASSWORD)"
admin_user_email="$(read_env_value env/k6-runner.eks.env ADMIN_USER_EMAIL)"
admin_user_password="$(read_env_value env/k6-runner.eks.env ADMIN_USER_PASSWORD)"

monolith_app_env="$(read_env_value env/monolith.eks.env APP_ENV)"
monolith_app_port="$(read_env_value env/monolith.eks.env APP_PORT)"
monolith_service_name="$(read_env_value env/monolith.eks.env SERVICE_NAME)"
monolith_jwt_secret="$(read_env_value env/monolith.eks.env JWT_SECRET)"
monolith_pool_max="$(read_env_value env/monolith.eks.env DB_POOL_MAX_CONNS)"
monolith_pool_min="$(read_env_value env/monolith.eks.env DB_POOL_MIN_CONNS)"
monolith_pool_lifetime="$(read_env_value env/monolith.eks.env DB_POOL_MAX_CONN_LIFETIME)"
monolith_pool_idle="$(read_env_value env/monolith.eks.env DB_POOL_MAX_CONN_IDLE_TIME)"
monolith_db_ping_timeout="$(read_env_value env/monolith.eks.env DB_PING_TIMEOUT)"
monolith_read_header_timeout="$(read_env_value env/monolith.eks.env HTTP_READ_HEADER_TIMEOUT)"
monolith_read_timeout="$(read_env_value env/monolith.eks.env HTTP_READ_TIMEOUT)"
monolith_write_timeout="$(read_env_value env/monolith.eks.env HTTP_WRITE_TIMEOUT)"
monolith_idle_timeout="$(read_env_value env/monolith.eks.env HTTP_IDLE_TIMEOUT)"
monolith_shutdown_timeout="$(read_env_value env/monolith.eks.env HTTP_SHUTDOWN_TIMEOUT)"
monolith_max_header_bytes="$(read_env_value env/monolith.eks.env HTTP_MAX_HEADER_BYTES)"
monolith_bcrypt_cost="$(read_env_value env/monolith.eks.env BCRYPT_COST)"

api_gateway_jwt_secret="$(read_env_value env/api-gateway.eks.env JWT_SECRET)"
api_gateway_app_env="$(read_env_value env/api-gateway.eks.env APP_ENV)"
api_gateway_http_port="$(read_env_value env/api-gateway.eks.env HTTP_PORT)"
api_gateway_service_name="$(read_env_value env/api-gateway.eks.env SERVICE_NAME)"
api_gateway_auth_service_addr="$(read_env_value env/api-gateway.eks.env AUTH_SERVICE_ADDR)"
api_gateway_item_service_addr="$(read_env_value env/api-gateway.eks.env ITEM_SERVICE_ADDR)"
api_gateway_transaction_service_addr="$(read_env_value env/api-gateway.eks.env TRANSACTION_SERVICE_ADDR)"

auth_service_app_env="$(read_env_value env/auth-service.eks.env APP_ENV)"
auth_service_grpc_port="$(read_env_value env/auth-service.eks.env GRPC_PORT)"
auth_service_name="$(read_env_value env/auth-service.eks.env SERVICE_NAME)"
auth_service_jwt_secret="$(read_env_value env/auth-service.eks.env JWT_SECRET)"
auth_service_bcrypt_cost="$(read_env_value env/auth-service.eks.env BCRYPT_COST)"

item_service_app_env="$(read_env_value env/item-service.eks.env APP_ENV)"
item_service_grpc_port="$(read_env_value env/item-service.eks.env GRPC_PORT)"
item_service_name="$(read_env_value env/item-service.eks.env SERVICE_NAME)"

transaction_service_app_env="$(read_env_value env/transaction-service.eks.env APP_ENV)"
transaction_service_grpc_port="$(read_env_value env/transaction-service.eks.env GRPC_PORT)"
transaction_service_name="$(read_env_value env/transaction-service.eks.env SERVICE_NAME)"
transaction_service_item_service_addr="$(read_env_value env/transaction-service.eks.env ITEM_SERVICE_ADDR)"

: "${db_password:?DB_PASSWORD must be set in env/terraform.experiment.env}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/k6-runner.eks.env}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/k6-runner.eks.env}"
: "${monolith_jwt_secret:?JWT_SECRET must be set in env/monolith.eks.env}"
: "${api_gateway_jwt_secret:?JWT_SECRET must be set in env/api-gateway.eks.env}"
: "${auth_service_jwt_secret:?JWT_SECRET must be set in env/auth-service.eks.env}"

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

sequential_rds="$(terraform_with_profile -chdir=infra/terraform/experiment-sequential output -raw sequential_rds_endpoint)"
encoded_db_password="$(url_encode "$db_password")"
context="${SEQUENTIAL_CONTEXT:-benchmark}"
K8S="kubectl --context=${context}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic monolith-env \
  --namespace mono \
  --from-literal=APP_ENV="${monolith_app_env:-production}" \
  --from-literal=APP_PORT="${monolith_app_port:-8080}" \
  --from-literal=SERVICE_NAME="${monolith_service_name:-monolith}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/mono_db?sslmode=require" \
  --from-literal=JWT_SECRET="$monolith_jwt_secret" \
  --from-literal=DB_POOL_MAX_CONNS="${monolith_pool_max:-25}" \
  --from-literal=DB_POOL_MIN_CONNS="${monolith_pool_min:-2}" \
  --from-literal=DB_POOL_MAX_CONN_LIFETIME="${monolith_pool_lifetime:-5m}" \
  --from-literal=DB_POOL_MAX_CONN_IDLE_TIME="${monolith_pool_idle:-1m}" \
  --from-literal=DB_PING_TIMEOUT="${monolith_db_ping_timeout:-5s}" \
  --from-literal=HTTP_READ_HEADER_TIMEOUT="${monolith_read_header_timeout:-5s}" \
  --from-literal=HTTP_READ_TIMEOUT="${monolith_read_timeout:-15s}" \
  --from-literal=HTTP_WRITE_TIMEOUT="${monolith_write_timeout:-30s}" \
  --from-literal=HTTP_IDLE_TIMEOUT="${monolith_idle_timeout:-1m}" \
  --from-literal=HTTP_SHUTDOWN_TIMEOUT="${monolith_shutdown_timeout:-10s}" \
  --from-literal=HTTP_MAX_HEADER_BYTES="${monolith_max_header_bytes:-1048576}" \
  --from-literal=BCRYPT_COST="${monolith_bcrypt_cost:-10}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic api-gateway-secret \
  --namespace msa \
  --from-literal=APP_ENV="${api_gateway_app_env:-production}" \
  --from-literal=HTTP_PORT="${api_gateway_http_port:-8080}" \
  --from-literal=SERVICE_NAME="${api_gateway_service_name:-api-gateway}" \
  --from-literal=JWT_SECRET="$api_gateway_jwt_secret" \
  --from-literal=AUTH_SERVICE_ADDR="${api_gateway_auth_service_addr:-auth-service.msa.svc.cluster.local:50051}" \
  --from-literal=ITEM_SERVICE_ADDR="${api_gateway_item_service_addr:-item-service.msa.svc.cluster.local:50052}" \
  --from-literal=TRANSACTION_SERVICE_ADDR="${api_gateway_transaction_service_addr:-transaction-service.msa.svc.cluster.local:50053}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic auth-service-secret \
  --namespace msa \
  --from-literal=APP_ENV="${auth_service_app_env:-production}" \
  --from-literal=GRPC_PORT="${auth_service_grpc_port:-50051}" \
  --from-literal=SERVICE_NAME="${auth_service_name:-auth-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST="${auth_service_bcrypt_cost:-10}" \
  --from-literal=JWT_SECRET="$auth_service_jwt_secret" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic item-service-secret \
  --namespace msa \
  --from-literal=APP_ENV="${item_service_app_env:-production}" \
  --from-literal=GRPC_PORT="${item_service_grpc_port:-50052}" \
  --from-literal=SERVICE_NAME="${item_service_name:-item-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic transaction-service-secret \
  --namespace msa \
  --from-literal=APP_ENV="${transaction_service_app_env:-production}" \
  --from-literal=GRPC_PORT="${transaction_service_grpc_port:-50053}" \
  --from-literal=SERVICE_NAME="${transaction_service_name:-transaction-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${sequential_rds}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR="${transaction_service_item_service_addr:-item-service.msa.svc.cluster.local:50052}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "EKS sequential secrets created in context: $context"
