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

monolith_env_file="$(resolve_app_env_file monolith || true)"
k6_runner_env_file="$(resolve_app_env_file k6-runner || true)"

for file in env/vultr.env "${monolith_env_file:-env/monolith.app.env}" "${k6_runner_env_file:-env/k6-runner.app.env}"; do
  [ -f "$file" ] || { echo "missing $file; run: make env-init-app and make env-init-vultr" >&2; exit 1; }
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
K8S="kubectl --context=${VULTR_CONTEXT:-monolith}"
jwt_secret="$(read_env_value "$monolith_env_file" JWT_SECRET)"
app_env="$(read_env_value "$monolith_env_file" APP_ENV)"
app_port="$(read_env_value "$monolith_env_file" APP_PORT)"
service_name="$(read_env_value "$monolith_env_file" SERVICE_NAME)"
db_pool_max_conns="$(read_env_value "$monolith_env_file" DB_POOL_MAX_CONNS)"
db_pool_min_conns="$(read_env_value "$monolith_env_file" DB_POOL_MIN_CONNS)"
db_pool_max_conn_lifetime="$(read_env_value "$monolith_env_file" DB_POOL_MAX_CONN_LIFETIME)"
db_pool_max_conn_idle_time="$(read_env_value "$monolith_env_file" DB_POOL_MAX_CONN_IDLE_TIME)"
db_ping_timeout="$(read_env_value "$monolith_env_file" DB_PING_TIMEOUT)"
http_read_header_timeout="$(read_env_value "$monolith_env_file" HTTP_READ_HEADER_TIMEOUT)"
http_read_timeout="$(read_env_value "$monolith_env_file" HTTP_READ_TIMEOUT)"
http_write_timeout="$(read_env_value "$monolith_env_file" HTTP_WRITE_TIMEOUT)"
http_write_timeout="$(normalize_http_write_timeout "$http_write_timeout" "40s")"
http_idle_timeout="$(read_env_value "$monolith_env_file" HTTP_IDLE_TIMEOUT)"
http_shutdown_timeout="$(read_env_value "$monolith_env_file" HTTP_SHUTDOWN_TIMEOUT)"
http_max_header_bytes="$(read_env_value "$monolith_env_file" HTTP_MAX_HEADER_BYTES)"
bcrypt_cost="$(read_env_value "$monolith_env_file" BCRYPT_COST)"
app_request_timeout="$(read_env_value "$monolith_env_file" APP_REQUEST_TIMEOUT)"
app_request_timeout="$(derive_app_request_timeout "$app_request_timeout" "$http_write_timeout")"
login_admission_enabled="$(read_env_value "$monolith_env_file" LOGIN_ADMISSION_ENABLED)"
login_max_concurrency="$(read_env_value "$monolith_env_file" LOGIN_MAX_CONCURRENCY)"
login_queue_timeout="$(read_env_value "$monolith_env_file" LOGIN_QUEUE_TIMEOUT)"
admin_user_email="$(read_env_value "$k6_runner_env_file" ADMIN_USER_EMAIL)"
admin_user_password="$(read_env_value "$k6_runner_env_file" ADMIN_USER_PASSWORD)"

: "${jwt_secret:?JWT_SECRET must be set in ${monolith_env_file}}"
: "${admin_user_email:?ADMIN_USER_EMAIL must be set in ${k6_runner_env_file}}"
: "${admin_user_password:?ADMIN_USER_PASSWORD must be set in ${k6_runner_env_file}}"

$K8S create namespace benchmark --dry-run=client -o yaml | $K8S apply -f -
$K8S create namespace mono --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic db-bootstrap-env --namespace benchmark \
  --from-literal=BOOTSTRAP_DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/postgres?sslmode=require" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic monolith-env --namespace mono \
  --from-literal=APP_ENV="${app_env:-production}" \
  --from-literal=APP_PORT="${app_port:-8080}" \
  --from-literal=SERVICE_NAME="${service_name:-monolith}" \
  --from-literal=DATABASE_URL="postgres://postgres_admin:${encoded_db_password}@${postgres_ip}:5432/mono_db?sslmode=require" \
  --from-literal=JWT_SECRET="$jwt_secret" \
  --from-literal=DB_POOL_MAX_CONNS="${db_pool_max_conns:-25}" \
  --from-literal=DB_POOL_MIN_CONNS="${db_pool_min_conns:-2}" \
  --from-literal=DB_POOL_MAX_CONN_LIFETIME="${db_pool_max_conn_lifetime:-5m}" \
  --from-literal=DB_POOL_MAX_CONN_IDLE_TIME="${db_pool_max_conn_idle_time:-1m}" \
  --from-literal=DB_PING_TIMEOUT="${db_ping_timeout:-5s}" \
  --from-literal=HTTP_READ_HEADER_TIMEOUT="${http_read_header_timeout:-5s}" \
  --from-literal=HTTP_READ_TIMEOUT="${http_read_timeout:-15s}" \
  --from-literal=HTTP_WRITE_TIMEOUT="${http_write_timeout}" \
  --from-literal=HTTP_IDLE_TIMEOUT="${http_idle_timeout:-1m}" \
  --from-literal=HTTP_SHUTDOWN_TIMEOUT="${http_shutdown_timeout:-10s}" \
  --from-literal=HTTP_MAX_HEADER_BYTES="${http_max_header_bytes:-1048576}" \
  --from-literal=BCRYPT_COST="${bcrypt_cost:-10}" \
  --from-literal=APP_REQUEST_TIMEOUT="${app_request_timeout}" \
  --from-literal=LOGIN_ADMISSION_ENABLED="${login_admission_enabled:-true}" \
  --from-literal=LOGIN_MAX_CONCURRENCY="${login_max_concurrency:-8}" \
  --from-literal=LOGIN_QUEUE_TIMEOUT="${login_queue_timeout:-2s}" \
  --dry-run=client -o yaml | $K8S apply -f -

$K8S create secret generic k6-runner-secret --namespace benchmark \
  --from-literal=ADMIN_USER_EMAIL="$admin_user_email" \
  --from-literal=ADMIN_USER_PASSWORD="$admin_user_password" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --from-literal=S3_BUCKET="$S3_BUCKET" \
  --dry-run=client -o yaml | $K8S apply -f -

echo "Vultr monolith secrets created"
