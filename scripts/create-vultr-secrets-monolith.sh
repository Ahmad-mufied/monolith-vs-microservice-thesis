#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

url_encode() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required to URL-encode database credentials" >&2; exit 1; }
  printf '%s' "$1" | jq -sRr @uri
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
  postgres_ip="$(terraform_output_required infra/terraform/vultr monolith_postgres_private_ip "monolith PostgreSQL private IP")"
fi
encoded_db_password="$(url_encode "$POSTGRES_PASSWORD")"
context="${VULTR_CONTEXT:-monolith}"
K8S="kubectl --context=${context}"

jwt_secret="${JWT_SECRET:-$(read_yaml_value ".cluster.monolith.JWT_SECRET")}"
jwt_secret="$(resolve_preserved_secret_value "$jwt_secret" "$context" mono monolith-env JWT_SECRET || true)"

app_env="${APP_ENV:-$(read_yaml_value ".cluster.monolith.APP_ENV")}"
app_port="${APP_PORT:-$(read_yaml_value ".cluster.monolith.APP_PORT")}"
service_name="${SERVICE_NAME:-$(read_yaml_value ".cluster.monolith.SERVICE_NAME")}"
db_pool_max_conns="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONNS")}"
db_pool_min_conns="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".cluster.monolith.DB_POOL_MIN_CONNS")}"
db_pool_max_conn_lifetime="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONN_LIFETIME")}"
db_pool_max_conn_idle_time="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".cluster.monolith.DB_POOL_MAX_CONN_IDLE_TIME")}"
db_ping_timeout="${DB_PING_TIMEOUT:-$(read_yaml_value ".cluster.monolith.DB_PING_TIMEOUT")}"
http_read_header_timeout="${HTTP_READ_HEADER_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_READ_HEADER_TIMEOUT")}"
http_read_timeout="${HTTP_READ_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_READ_TIMEOUT")}"
raw_http_write_timeout="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_WRITE_TIMEOUT")}"
http_idle_timeout="${HTTP_IDLE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_IDLE_TIMEOUT")}"
http_shutdown_timeout="${HTTP_SHUTDOWN_TIMEOUT:-$(read_yaml_value ".cluster.monolith.HTTP_SHUTDOWN_TIMEOUT")}"
http_max_header_bytes="${HTTP_MAX_HEADER_BYTES:-$(read_yaml_value ".cluster.monolith.HTTP_MAX_HEADER_BYTES")}"
bcrypt_cost="${BCRYPT_COST:-$(read_yaml_value ".cluster.monolith.BCRYPT_COST")}"
diagnostic_logging_enabled="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".cluster.monolith.DIAGNOSTIC_LOGGING_ENABLED")}"
raw_app_request_timeout="${APP_REQUEST_TIMEOUT:-$(read_yaml_value ".cluster.monolith.APP_REQUEST_TIMEOUT")}"
login_admission_enabled="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".cluster.monolith.LOGIN_ADMISSION_ENABLED")}"
login_max_concurrency="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".cluster.monolith.LOGIN_MAX_CONCURRENCY")}"
login_queue_timeout="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".cluster.monolith.LOGIN_QUEUE_TIMEOUT")}"

admin_user_email="${ADMIN_USER_EMAIL:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_EMAIL")}"
admin_user_email="$(resolve_preserved_secret_value "$admin_user_email" "$context" benchmark k6-runner-secret ADMIN_USER_EMAIL || true)"

admin_user_password="${ADMIN_USER_PASSWORD:-$(read_yaml_value ".shared.\"k6-runner\".ADMIN_USER_PASSWORD")}"
admin_user_password="$(resolve_preserved_secret_value "$admin_user_password" "$context" benchmark k6-runner-secret ADMIN_USER_PASSWORD || true)"

: "${jwt_secret:?JWT_SECRET must be set in env/values.yaml under .cluster.monolith.JWT_SECRET}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_EMAIL}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in env/values.yaml under .shared.k6-runner.ADMIN_USER_PASSWORD}"

monolith_secret_pairs=()
append_secret_pair monolith_secret_pairs APP_ENV "${app_env:-production}"
append_secret_pair monolith_secret_pairs APP_PORT "${app_port:-8080}"
append_secret_pair monolith_secret_pairs SERVICE_NAME "${service_name:-monolith}"
append_secret_pair monolith_secret_pairs DATABASE_URL "postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/mono_db?sslmode=require"
append_secret_pair monolith_secret_pairs JWT_SECRET "$jwt_secret"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONNS "$db_pool_max_conns" "25"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MIN_CONNS "$db_pool_min_conns" "2"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_LIFETIME "$db_pool_max_conn_lifetime" "5m"
append_secret_pair_if_override monolith_secret_pairs DB_POOL_MAX_CONN_IDLE_TIME "$db_pool_max_conn_idle_time" "1m"
append_secret_pair_if_override monolith_secret_pairs DB_PING_TIMEOUT "$db_ping_timeout" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_HEADER_TIMEOUT "$http_read_header_timeout" "5s"
append_secret_pair_if_override monolith_secret_pairs HTTP_READ_TIMEOUT "$http_read_timeout" "15s"
append_secret_pair_if_override monolith_secret_pairs HTTP_IDLE_TIMEOUT "$http_idle_timeout" "1m"
append_secret_pair_if_override monolith_secret_pairs HTTP_SHUTDOWN_TIMEOUT "$http_shutdown_timeout" "10s"
append_secret_pair_if_override monolith_secret_pairs HTTP_MAX_HEADER_BYTES "$http_max_header_bytes" "1048576"
append_secret_pair_if_override monolith_secret_pairs BCRYPT_COST "$bcrypt_cost" "10"
append_secret_pair monolith_secret_pairs DIAGNOSTIC_LOGGING_ENABLED "${diagnostic_logging_enabled:-false}"

effective_http_write_timeout="40s"
if [[ -n "$raw_http_write_timeout" ]]; then
  effective_http_write_timeout="$(normalize_http_write_timeout "$raw_http_write_timeout" "40s")"
fi
if [[ -n "$raw_app_request_timeout" || "$effective_http_write_timeout" != "40s" ]]; then
  app_request_timeout="$(derive_app_request_timeout "$raw_app_request_timeout" "$effective_http_write_timeout")"
  validate_monolith_timeout_chain "$app_request_timeout" "$effective_http_write_timeout"
  append_secret_pair_if_override monolith_secret_pairs HTTP_WRITE_TIMEOUT "$effective_http_write_timeout" "40s"
  append_secret_pair_if_override monolith_secret_pairs APP_REQUEST_TIMEOUT "$app_request_timeout" "35s"
fi

if [[ -n "$login_admission_enabled" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_ADMISSION_ENABLED "$login_admission_enabled" "true"
fi
if [[ "${login_admission_enabled:-true}" == "true" ]]; then
  append_secret_pair_if_override monolith_secret_pairs LOGIN_MAX_CONCURRENCY "$login_max_concurrency" "8"
  append_secret_pair_if_override monolith_secret_pairs LOGIN_QUEUE_TIMEOUT "$login_queue_timeout" "2s"
fi

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/postgres?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

apply_secret_from_pairs "$context" mono monolith-env "${monolith_secret_pairs[@]}"

$K8S create secret generic k6-runner-secret --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "Vultr monolith secrets created"
