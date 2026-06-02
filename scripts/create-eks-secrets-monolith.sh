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

monolith_env_file="$(resolve_app_env_file monolith || true)"
k6_runner_env_file="$(resolve_app_env_file k6-runner || true)"

required_files=(
  "${monolith_env_file:-env/monolith.app.env}"
  env/terraform.experiment.env
  "${k6_runner_env_file:-env/k6-runner.app.env}"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init-app and make env-init-eks" >&2
    exit 1
  fi
done

set -a
source "$monolith_env_file"
source env/terraform.experiment.env
source "$k6_runner_env_file"
set +a

: "${DB_PASSWORD:?DB_PASSWORD must be set in env/terraform.experiment.env}"
: "${JWT_SECRET:?JWT_SECRET must be set in ${monolith_env_file}}"
: "${ADMIN_USER_EMAIL:?ADMIN_USER_EMAIL must be set in ${k6_runner_env_file}}"
: "${ADMIN_USER_PASSWORD:?ADMIN_USER_PASSWORD must be set in ${k6_runner_env_file}}"

terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_with_profile() {
  AWS_PROFILE="$terraform_aws_profile" terraform "$@"
}

MONOLITH_RDS="$(terraform_with_profile -chdir=infra/terraform/aws-parallel output -raw monolith_rds_endpoint)"
encoded_db_password="$(url_encode "$DB_PASSWORD")"
K8S="kubectl --context=monolith"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${MONOLITH_RDS}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic monolith-env \
  --namespace mono \
  --from-literal=APP_ENV="${APP_ENV:-production}" \
  --from-literal=APP_PORT="${APP_PORT:-8080}" \
  --from-literal=SERVICE_NAME="${SERVICE_NAME:-monolith}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${MONOLITH_RDS}:5432/mono_db?sslmode=require" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
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

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$ADMIN_USER_EMAIL" \
  --from-literal=ADMIN_USER_PASSWORD="$ADMIN_USER_PASSWORD" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "EKS monolith secrets created"
