#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

for file in env/postgres.env env/values.yaml; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init" >&2
    exit 1
  fi
done

bash scripts/create-local-postgres-secrets.sh

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

set -a
source env/postgres.env
set +a

# Monolith variables with environment variable override pattern
APP_ENV="${APP_ENV:-$(read_yaml_value ".local.monolith.APP_ENV")}"
APP_PORT="${APP_PORT:-$(read_yaml_value ".local.monolith.APP_PORT")}"
SERVICE_NAME="${SERVICE_NAME:-$(read_yaml_value ".local.monolith.SERVICE_NAME")}"
DB_POOL_MAX_CONNS="${DB_POOL_MAX_CONNS:-$(read_yaml_value ".local.monolith.DB_POOL_MAX_CONNS")}"
DB_POOL_MIN_CONNS="${DB_POOL_MIN_CONNS:-$(read_yaml_value ".local.monolith.DB_POOL_MIN_CONNS")}"
DB_POOL_MAX_CONN_LIFETIME="${DB_POOL_MAX_CONN_LIFETIME:-$(read_yaml_value ".local.monolith.DB_POOL_MAX_CONN_LIFETIME")}"
DB_POOL_MAX_CONN_IDLE_TIME="${DB_POOL_MAX_CONN_IDLE_TIME:-$(read_yaml_value ".local.monolith.DB_POOL_MAX_CONN_IDLE_TIME")}"
DB_PING_TIMEOUT="${DB_PING_TIMEOUT:-$(read_yaml_value ".local.monolith.DB_PING_TIMEOUT")}"
HTTP_READ_HEADER_TIMEOUT="${HTTP_READ_HEADER_TIMEOUT:-$(read_yaml_value ".local.monolith.HTTP_READ_HEADER_TIMEOUT")}"
HTTP_READ_TIMEOUT="${HTTP_READ_TIMEOUT:-$(read_yaml_value ".local.monolith.HTTP_READ_TIMEOUT")}"
HTTP_WRITE_TIMEOUT="${HTTP_WRITE_TIMEOUT:-$(read_yaml_value ".local.monolith.HTTP_WRITE_TIMEOUT")}"
HTTP_IDLE_TIMEOUT="${HTTP_IDLE_TIMEOUT:-$(read_yaml_value ".local.monolith.HTTP_IDLE_TIMEOUT")}"
HTTP_SHUTDOWN_TIMEOUT="${HTTP_SHUTDOWN_TIMEOUT:-$(read_yaml_value ".local.monolith.HTTP_SHUTDOWN_TIMEOUT")}"
HTTP_MAX_HEADER_BYTES="${HTTP_MAX_HEADER_BYTES:-$(read_yaml_value ".local.monolith.HTTP_MAX_HEADER_BYTES")}"
BCRYPT_COST="${BCRYPT_COST:-$(read_yaml_value ".local.monolith.BCRYPT_COST")}"
JWT_SECRET="${JWT_SECRET:-$(read_yaml_value ".local.monolith.JWT_SECRET")}"
DATADOG_ENABLED="${DATADOG_ENABLED:-$(read_yaml_value ".local.monolith.DATADOG_ENABLED")}"
DIAGNOSTIC_LOGGING_ENABLED="${DIAGNOSTIC_LOGGING_ENABLED:-$(read_yaml_value ".local.monolith.DIAGNOSTIC_LOGGING_ENABLED")}"
APP_REQUEST_TIMEOUT="${APP_REQUEST_TIMEOUT:-$(read_yaml_value ".local.monolith.APP_REQUEST_TIMEOUT")}"
LOGIN_ADMISSION_ENABLED="${LOGIN_ADMISSION_ENABLED:-$(read_yaml_value ".local.monolith.LOGIN_ADMISSION_ENABLED")}"
LOGIN_MAX_CONCURRENCY="${LOGIN_MAX_CONCURRENCY:-$(read_yaml_value ".local.monolith.LOGIN_MAX_CONCURRENCY")}"
LOGIN_QUEUE_TIMEOUT="${LOGIN_QUEUE_TIMEOUT:-$(read_yaml_value ".local.monolith.LOGIN_QUEUE_TIMEOUT")}"

HTTP_WRITE_TIMEOUT="$(normalize_http_write_timeout "$HTTP_WRITE_TIMEOUT" "40s")"
APP_REQUEST_TIMEOUT="$(derive_app_request_timeout "$APP_REQUEST_TIMEOUT" "$HTTP_WRITE_TIMEOUT")"

if [[ -z "${JWT_SECRET:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/values.yaml under .local.monolith.JWT_SECRET" >&2
  exit 1
fi

encoded_user="$(url_encode "$POSTGRES_USER")"
encoded_pass="$(url_encode "$POSTGRES_PASSWORD")"

tmp_monolith_env="$(mktemp /tmp/monolith-k8s-env.XXXXXX)"
trap 'rm -f "$tmp_monolith_env"' EXIT

cat >"$tmp_monolith_env" <<EOFMONO
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
SERVICE_NAME=${SERVICE_NAME}
DATABASE_URL=postgres://${encoded_user}:${encoded_pass}@postgres.local-database.svc.cluster.local:5432/mono_db?sslmode=disable
DB_POOL_MAX_CONNS=${DB_POOL_MAX_CONNS:-25}
DB_POOL_MIN_CONNS=${DB_POOL_MIN_CONNS:-2}
DB_POOL_MAX_CONN_LIFETIME=${DB_POOL_MAX_CONN_LIFETIME:-5m}
DB_POOL_MAX_CONN_IDLE_TIME=${DB_POOL_MAX_CONN_IDLE_TIME:-1m}
DB_PING_TIMEOUT=${DB_PING_TIMEOUT:-5s}
HTTP_READ_HEADER_TIMEOUT=${HTTP_READ_HEADER_TIMEOUT:-5s}
HTTP_READ_TIMEOUT=${HTTP_READ_TIMEOUT:-15s}
HTTP_WRITE_TIMEOUT=${HTTP_WRITE_TIMEOUT}
HTTP_IDLE_TIMEOUT=${HTTP_IDLE_TIMEOUT:-60s}
HTTP_SHUTDOWN_TIMEOUT=${HTTP_SHUTDOWN_TIMEOUT:-10s}
HTTP_MAX_HEADER_BYTES=${HTTP_MAX_HEADER_BYTES:-1048576}
BCRYPT_COST=${BCRYPT_COST:-10}
JWT_SECRET=${JWT_SECRET}
DATADOG_ENABLED=${DATADOG_ENABLED}
DIAGNOSTIC_LOGGING_ENABLED=${DIAGNOSTIC_LOGGING_ENABLED:-false}
APP_REQUEST_TIMEOUT=${APP_REQUEST_TIMEOUT}
LOGIN_ADMISSION_ENABLED=${LOGIN_ADMISSION_ENABLED:-true}
LOGIN_MAX_CONCURRENCY=${LOGIN_MAX_CONCURRENCY:-8}
LOGIN_QUEUE_TIMEOUT=${LOGIN_QUEUE_TIMEOUT:-2s}
EOFMONO

apply_secret_and_config_from_env_file "" mono monolith-env "$tmp_monolith_env"


echo "local monolith Kubernetes secrets created"
