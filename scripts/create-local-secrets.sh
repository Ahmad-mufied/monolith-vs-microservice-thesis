#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

if [[ ! -f env/postgres.env || ! -f env/monolith.env ]]; then
  echo "missing env files; run: make env-init-monolith" >&2
  exit 1
fi

bash scripts/create-local-postgres-secrets.sh

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

set -a
source env/postgres.env
source env/monolith.env
set +a

HTTP_WRITE_TIMEOUT="$(normalize_http_write_timeout "${HTTP_WRITE_TIMEOUT:-}" "40s")"
APP_REQUEST_TIMEOUT="$(derive_app_request_timeout "${APP_REQUEST_TIMEOUT:-}" "$HTTP_WRITE_TIMEOUT")"

if [[ -z "${JWT_SECRET:-}" ]]; then
  echo "JWT_SECRET must be non-empty in env/monolith.env" >&2
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

kubectl create secret generic monolith-env \
  --namespace mono \
  --from-env-file "$tmp_monolith_env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "local monolith Kubernetes secrets created"
