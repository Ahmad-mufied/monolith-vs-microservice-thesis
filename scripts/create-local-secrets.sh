#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f env/postgres.env || ! -f env/monolith.env ]]; then
  echo "missing env files; run: make env-init" >&2
  exit 1
fi

# URL-encode function for DB credentials (reserved chars: : @ / ? # %)
url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

set -a
source env/postgres.env
source env/monolith.env
set +a

# URL-encode DB credentials to handle reserved characters
encoded_user="$(url_encode "$POSTGRES_USER")"
encoded_pass="$(url_encode "$POSTGRES_PASSWORD")"

tmp_monolith_env="$(mktemp /tmp/monolith-k8s-env.XXXXXX)"
tmp_db_bootstrap_env="$(mktemp /tmp/db-bootstrap-k8s-env.XXXXXX)"
trap 'rm -f "$tmp_monolith_env" "$tmp_db_bootstrap_env"' EXIT

cat >"$tmp_monolith_env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
SERVICE_NAME=${SERVICE_NAME}
DATABASE_URL=postgres://${encoded_user}:${encoded_pass}@postgres.benchmark.svc.cluster.local:5432/mono_db?sslmode=disable
DB_POOL_MAX_CONNS=${DB_POOL_MAX_CONNS:-25}
DB_POOL_MIN_CONNS=${DB_POOL_MIN_CONNS:-2}
DB_POOL_MAX_CONN_LIFETIME=${DB_POOL_MAX_CONN_LIFETIME:-5m}
DB_POOL_MAX_CONN_IDLE_TIME=${DB_POOL_MAX_CONN_IDLE_TIME:-1m}
DB_PING_TIMEOUT=${DB_PING_TIMEOUT:-5s}
HTTP_READ_HEADER_TIMEOUT=${HTTP_READ_HEADER_TIMEOUT:-5s}
HTTP_READ_TIMEOUT=${HTTP_READ_TIMEOUT:-15s}
HTTP_WRITE_TIMEOUT=${HTTP_WRITE_TIMEOUT:-30s}
HTTP_IDLE_TIMEOUT=${HTTP_IDLE_TIMEOUT:-60s}
HTTP_SHUTDOWN_TIMEOUT=${HTTP_SHUTDOWN_TIMEOUT:-10s}
HTTP_MAX_HEADER_BYTES=${HTTP_MAX_HEADER_BYTES:-1048576}
JWT_SECRET=${JWT_SECRET}
DATADOG_ENABLED=${DATADOG_ENABLED}
EOF

cat >"$tmp_db_bootstrap_env" <<EOF
BOOTSTRAP_DATABASE_URL=postgres://${encoded_user}:${encoded_pass}@postgres.benchmark.svc.cluster.local:5432/bootstrap?sslmode=disable
EOF

kubectl apply -f deployments/k8s/namespaces/benchmark.yaml

kubectl create secret generic postgres-local-env \
  --namespace benchmark \
  --from-env-file env/postgres.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-env-file "$tmp_db_bootstrap_env" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic monolith-env \
  --namespace mono \
  --from-env-file "$tmp_monolith_env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "local Kubernetes secrets created"
