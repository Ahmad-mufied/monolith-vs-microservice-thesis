#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

random_hex() {
  local bytes="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi

  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

read_env_value() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

write_if_missing() {
  local file="$1"
  local content="$2"

  if [[ -f "$file" ]]; then
    echo "skip $file (already exists)"
    return
  fi

  printf "%s\n" "$content" >"$file"
  echo "created $file"
}

if [[ ! -f env/postgres.env ]]; then
  echo "missing env/postgres.env; run: make env-init-base" >&2
  exit 1
fi

postgres_user="$(read_env_value env/postgres.env POSTGRES_USER)"
postgres_user="${postgres_user:-postgres}"
postgres_password="$(read_env_value env/postgres.env POSTGRES_PASSWORD)"
if [[ -z "$postgres_password" ]]; then
  echo "env/postgres.env exists but POSTGRES_PASSWORD is empty" >&2
  exit 1
fi

jwt_secret="$(read_env_value env/monolith.env JWT_SECRET)"
jwt_secret="${jwt_secret:-$(random_hex 32)}"

encoded_postgres_user="$(url_encode "$postgres_user")"
encoded_postgres_password="$(url_encode "$postgres_password")"

write_if_missing "env/monolith.env" "APP_ENV=local
APP_PORT=8080
SERVICE_NAME=monolith
DATABASE_URL=postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres:5432/mono_db?sslmode=disable
MONO_DATABASE_URL=postgres://${encoded_postgres_user}:${encoded_postgres_password}@localhost:5432/mono_db?sslmode=disable
DB_POOL_MAX_CONNS=25
DB_POOL_MIN_CONNS=2
DB_POOL_MAX_CONN_LIFETIME=5m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s
HTTP_READ_HEADER_TIMEOUT=5s
HTTP_READ_TIMEOUT=15s
HTTP_WRITE_TIMEOUT=30s
HTTP_IDLE_TIMEOUT=60s
HTTP_SHUTDOWN_TIMEOUT=10s
HTTP_MAX_HEADER_BYTES=1048576
JWT_SECRET=${jwt_secret}
DATADOG_ENABLED=false"

write_if_missing "env/db-bootstrap.env" "BOOTSTRAP_DATABASE_URL=postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres.local-database.svc.cluster.local:5432/bootstrap?sslmode=disable"

echo "local monolith env initialization complete"
