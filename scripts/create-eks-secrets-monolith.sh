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
monolith_env_file="${monolith_env_file:-env/monolith.app.env}"
k6_runner_env_file="${k6_runner_env_file:-env/k6-runner.app.env}"

required_files=(
  "$monolith_env_file"
  env/terraform.experiment.env
  "$k6_runner_env_file"
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

context="monolith"

JWT_SECRET="$(resolve_preserved_secret_value "${JWT_SECRET:-}" "$context" mono monolith-env JWT_SECRET || true)"
ADMIN_USER_EMAIL="$(resolve_preserved_secret_value "${ADMIN_USER_EMAIL:-}" "$context" benchmark k6-runner-secret ADMIN_USER_EMAIL || true)"
ADMIN_USER_PASSWORD="$(resolve_preserved_secret_value "${ADMIN_USER_PASSWORD:-}" "$context" benchmark k6-runner-secret ADMIN_USER_PASSWORD || true)"

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

monolith_secret_pairs=()
append_secret_pair monolith_secret_pairs APP_ENV "${APP_ENV:-production}"
append_secret_pair monolith_secret_pairs APP_PORT "${APP_PORT:-8080}"
append_secret_pair monolith_secret_pairs SERVICE_NAME "${SERVICE_NAME:-monolith}"
append_secret_pair monolith_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${MONOLITH_RDS}:5432/mono_db?sslmode=require"
append_secret_pair monolith_secret_pairs JWT_SECRET "$JWT_SECRET"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONNS "${DB_POOL_MAX_CONNS:-}" "25"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MIN_CONNS "${DB_POOL_MIN_CONNS:-}" "2"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_LIFETIME "${DB_POOL_MAX_CONN_LIFETIME:-}" "5m"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "${DB_POOL_MAX_CONN_IDLE_TIME:-}" "1m"
append_secret_pair_if_override monolith_secret_pairs DB_PING_TIMEOUT "${DB_PING_TIMEOUT:-}" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_HEADER_TIMEOUT "${HTTP_READ_HEADER_TIMEOUT:-}" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_TIMEOUT "${HTTP_READ_TIMEOUT:-}" "15s"
append_secret_pair_if_override monolith_secret_pairs HTTP_IDLE_TIMEOUT "${HTTP_IDLE_TIMEOUT:-}" "1m"
append_secret_pair_if_override monolith_secret_pairs HTTP_SHUTDOWN_TIMEOUT "${HTTP_SHUTDOWN_TIMEOUT:-}" "10s"
append_secret_pair_if_override monolith_secret_pairs HTTP_MAX_HEADER_BYTES "${HTTP_MAX_HEADER_BYTES:-}" "1048576"
append_secret_pair_if_override monolith_secret_pairs BCRYPT_COST "${BCRYPT_COST:-}" "10"

effective_http_write_timeout="40s"
if [[ -n "${HTTP_WRITE_TIMEOUT:-}" ]]; then
  effective_http_write_timeout="$(normalize_http_write_timeout "${HTTP_WRITE_TIMEOUT:-}" "40s")"
fi
if [[ -n "${APP_REQUEST_TIMEOUT:-}" || "$effective_http_write_timeout" != "40s" ]]; then
  effective_app_request_timeout="$(derive_app_request_timeout "${APP_REQUEST_TIMEOUT:-}" "$effective_http_write_timeout")"
  validate_monolith_timeout_chain "$effective_app_request_timeout" "$effective_http_write_timeout"
  append_secret_pair_if_override monolith_secret_pairs HTTP_WRITE_TIMEOUT "$effective_http_write_timeout" "40s"
  append_secret_pair_if_override monolith_secret_pairs APP_REQUEST_TIMEOUT "$effective_app_request_timeout" "35s"
fi

if [[ -n "${LOGIN_ADMISSION_ENABLED:-}" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_ADMISSION_ENABLED "${LOGIN_ADMISSION_ENABLED:-}" "true"
fi
if [[ "${LOGIN_ADMISSION_ENABLED:-true}" == "true" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_MAX_CONCURRENCY "${LOGIN_MAX_CONCURRENCY:-}" "8"
  append_secret_pair_if_override monolith_secret_pairs LOGIN_QUEUE_TIMEOUT "${LOGIN_QUEUE_TIMEOUT:-}" "2s"
fi

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${MONOLITH_RDS}:5432/bootstrap?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

apply_secret_from_pairs "$context" mono monolith-env "${monolith_secret_pairs[@]}"

$K8S create secret generic k6-runner-secret \
  --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$ADMIN_USER_EMAIL" \
  --from-literal=ADMIN_USER_PASSWORD="$ADMIN_USER_PASSWORD" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "EKS monolith secrets created"
