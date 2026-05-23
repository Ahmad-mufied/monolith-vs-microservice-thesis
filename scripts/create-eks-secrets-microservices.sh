#!/usr/bin/env bash
set -euo pipefail

required_files=(
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

api_gateway_app_env="$(read_env_value env/api-gateway.eks.env APP_ENV)"
api_gateway_http_port="$(read_env_value env/api-gateway.eks.env HTTP_PORT)"
api_gateway_service_name="$(read_env_value env/api-gateway.eks.env SERVICE_NAME)"
api_gateway_jwt_secret="$(read_env_value env/api-gateway.eks.env JWT_SECRET)"
api_gateway_auth_service_addr="$(read_env_value env/api-gateway.eks.env AUTH_SERVICE_ADDR)"
api_gateway_item_service_addr="$(read_env_value env/api-gateway.eks.env ITEM_SERVICE_ADDR)"
api_gateway_transaction_service_addr="$(read_env_value env/api-gateway.eks.env TRANSACTION_SERVICE_ADDR)"

auth_service_app_env="$(read_env_value env/auth-service.eks.env APP_ENV)"
auth_service_grpc_port="$(read_env_value env/auth-service.eks.env GRPC_PORT)"
auth_service_name="$(read_env_value env/auth-service.eks.env SERVICE_NAME)"
auth_service_bcrypt_cost="$(read_env_value env/auth-service.eks.env BCRYPT_COST)"
auth_service_jwt_secret="$(read_env_value env/auth-service.eks.env JWT_SECRET)"

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
: "${api_gateway_jwt_secret:?JWT_SECRET must be set in env/api-gateway.eks.env}"
: "${auth_service_jwt_secret:?JWT_SECRET must be set in env/auth-service.eks.env}"

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

MSA_RDS="$(terraform_with_profile -chdir=infra/terraform/experiment output -raw msa_rds_endpoint)"
K8S="kubectl --context=msa"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace msa --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${db_password}@${MSA_RDS}:5432/bootstrap?sslmode=require" \
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
  --from-literal=DATABASE_URL="postgres://postgres_admin:${db_password}@${MSA_RDS}:5432/auth_db?sslmode=require" \
  --from-literal=BCRYPT_COST="${auth_service_bcrypt_cost:-10}" \
  --from-literal=JWT_SECRET="$auth_service_jwt_secret" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic item-service-secret \
  --namespace msa \
  --from-literal=APP_ENV="${item_service_app_env:-production}" \
  --from-literal=GRPC_PORT="${item_service_grpc_port:-50052}" \
  --from-literal=SERVICE_NAME="${item_service_name:-item-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${db_password}@${MSA_RDS}:5432/item_db?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic transaction-service-secret \
  --namespace msa \
  --from-literal=APP_ENV="${transaction_service_app_env:-production}" \
  --from-literal=GRPC_PORT="${transaction_service_grpc_port:-50053}" \
  --from-literal=SERVICE_NAME="${transaction_service_name:-transaction-service}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${db_password}@${MSA_RDS}:5432/transaction_db?sslmode=require" \
  --from-literal=ITEM_SERVICE_ADDR="${transaction_service_item_service_addr:-item-service.msa.svc.cluster.local:50052}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "EKS microservices secrets created"
