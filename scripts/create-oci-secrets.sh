#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh
source scripts/lib/vultr-s3-credentials.sh

url_encode() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required to URL-encode database credentials" >&2; exit 1; }
  printf '%s' "$1" | jq -sRr @uri
}

set +e
set -a
[ -f env/oci.env ] && source env/oci.env
set +a
set -e

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/oci.env}"
db_password="$POSTGRES_PASSWORD"
encoded_db_password="$(url_encode "$db_password")"

sequential_db_ip=$(terraform -chdir=infra/terraform/oci output -json postgres_endpoints 2>/dev/null | jq -r '.sequential' 2>/dev/null)
if [ -n "$sequential_db_ip" ] && [ "$sequential_db_ip" != "null" ]; then
  monolith_db_ip="$sequential_db_ip"
  msa_db_ip="$sequential_db_ip"
else
  monolith_db_ip=$(terraform -chdir=infra/terraform/oci output -json postgres_endpoints 2>/dev/null | jq -r '.monolith' 2>/dev/null)
  msa_db_ip=$(terraform -chdir=infra/terraform/oci output -json postgres_endpoints 2>/dev/null | jq -r '.msa' 2>/dev/null)
fi

if [ -z "$monolith_db_ip" ] || [ "$monolith_db_ip" = "null" ]; then
  monolith_db_ip="10.0.4.206"
fi
if [ -z "$msa_db_ip" ] || [ "$msa_db_ip" = "null" ]; then
  msa_db_ip="10.0.4.206"
fi

jwt_secret="${JWT_SECRET:-super-secret-jwt-key-change-in-production}"
admin_email="${ADMIN_USER_EMAIL:-admin@example.com}"
admin_password="${ADMIN_USER_PASSWORD:-AdminPassword123!}"

# Load AWS S3 credentials
load_vultr_s3_credentials
aws_region="${AWS_REGION:-ap-southeast-1}"
s3_bucket="${S3_BUCKET:-skripsi-benchmark-results}"

# ── Monolith Secrets ──────────────────────────────────────────────────────────
K8S="kubectl --context=monolith"
$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${monolith_db_ip}:5432/postgres?sslmode=disable" \
  --dry-run=client -o yaml | $K8S apply -f -

monolith_secret_pairs=()
append_secret_pair monolith_secret_pairs APP_ENV "production"
append_secret_pair monolith_secret_pairs APP_PORT "8080"
append_secret_pair monolith_secret_pairs SERVICE_NAME "monolith"
append_secret_pair monolith_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${monolith_db_ip}:5432/mono_db?sslmode=disable"
append_secret_pair monolith_secret_pairs JWT_SECRET "$jwt_secret"
append_secret_pair monolith_secret_pairs BCRYPT_COST "10"
append_secret_pair monolith_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "false"

apply_secret_from_pairs "monolith" mono monolith-env "${monolith_secret_pairs[@]}"

$K8S create secret generic k6-runner-secret --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$aws_region" \
  --from-literal=S3_BUCKET="$s3_bucket" \
  --dry-run=client -o yaml | $K8S apply -f -

# ── Microservices Secrets ─────────────────────────────────────────────────────
K8S_MSA="kubectl --context=msa"
$K8S_MSA create namespace msa --dry-run=client -o yaml | $K8S_MSA apply -f -

auth_secret_pairs=()
append_secret_pair auth_secret_pairs APP_ENV "production"
append_secret_pair auth_secret_pairs APP_PORT "8081"
append_secret_pair auth_secret_pairs GRPC_PORT "50051"
append_secret_pair auth_secret_pairs SERVICE_NAME "auth-service"
append_secret_pair auth_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${msa_db_ip}:5432/auth_db?sslmode=disable"
append_secret_pair auth_secret_pairs JWT_SECRET "$jwt_secret"
append_secret_pair auth_secret_pairs BCRYPT_COST "10"
append_secret_pair auth_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "false"
apply_secret_from_pairs "msa" msa auth-service-secret "${auth_secret_pairs[@]}"

item_secret_pairs=()
append_secret_pair item_secret_pairs APP_ENV "production"
append_secret_pair item_secret_pairs APP_PORT "8082"
append_secret_pair item_secret_pairs GRPC_PORT "50052"
append_secret_pair item_secret_pairs SERVICE_NAME "item-service"
append_secret_pair item_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${msa_db_ip}:5432/item_db?sslmode=disable"
append_secret_pair item_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "false"
apply_secret_from_pairs "msa" msa item-service-secret "${item_secret_pairs[@]}"

transaction_secret_pairs=()
append_secret_pair transaction_secret_pairs APP_ENV "production"
append_secret_pair transaction_secret_pairs APP_PORT "8083"
append_secret_pair transaction_secret_pairs GRPC_PORT "50053"
append_secret_pair transaction_secret_pairs SERVICE_NAME "transaction-service"
append_secret_pair transaction_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${msa_db_ip}:5432/transaction_db?sslmode=disable"
append_secret_pair transaction_secret_pairs ITEM_SERVICE_ADDR "dns:///item-service-headless.msa.svc.cluster.local:50052"
append_secret_pair transaction_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "false"
apply_secret_from_pairs "msa" msa transaction-service-secret "${transaction_secret_pairs[@]}"

api_gateway_secret_pairs=()
append_secret_pair api_gateway_secret_pairs APP_ENV "production"
append_secret_pair api_gateway_secret_pairs APP_PORT "8080"
append_secret_pair api_gateway_secret_pairs SERVICE_NAME "api-gateway"
append_secret_pair api_gateway_secret_pairs AUTH_SERVICE_ADDR "dns:///auth-service-headless.msa.svc.cluster.local:50051"
append_secret_pair api_gateway_secret_pairs ITEM_SERVICE_ADDR "dns:///item-service-headless.msa.svc.cluster.local:50052"
append_secret_pair api_gateway_secret_pairs TRANSACTION_SERVICE_ADDR "dns:///transaction-service-headless.msa.svc.cluster.local:50053"
append_secret_pair api_gateway_secret_pairs JWT_SECRET "$jwt_secret"
append_secret_pair api_gateway_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "false"
apply_secret_from_pairs "msa" msa api-gateway-secret "${api_gateway_secret_pairs[@]}"

echo "OCI secrets created successfully."
