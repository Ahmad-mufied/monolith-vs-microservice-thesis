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

jwt_secret="$(random_hex 32)"

if [[ -f env/postgres.env ]]; then
  postgres_password="$(grep -E '^POSTGRES_PASSWORD=' env/postgres.env | cut -d= -f2- || true)"
  if [[ -z "$postgres_password" ]]; then
    echo "env/postgres.env exists but POSTGRES_PASSWORD is empty" >&2
    exit 1
  fi
else
  postgres_password="$(random_hex 16)"
fi

write_if_missing "env/postgres.env" "POSTGRES_USER=postgres
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=bootstrap"

write_if_missing "env/monolith.env" "APP_ENV=local
APP_PORT=8080
SERVICE_NAME=monolith
DATABASE_URL=postgres://postgres:${postgres_password}@postgres:5432/mono_db?sslmode=disable
MONO_DATABASE_URL=postgres://postgres:${postgres_password}@localhost:5432/mono_db?sslmode=disable
JWT_SECRET=${jwt_secret}
DATADOG_ENABLED=false"

write_if_missing "env/db-bootstrap.env" "BOOTSTRAP_DATABASE_URL=postgres://postgres:${postgres_password}@postgres.benchmark.svc.cluster.local:5432/bootstrap?sslmode=disable"

echo "local env initialization complete"
