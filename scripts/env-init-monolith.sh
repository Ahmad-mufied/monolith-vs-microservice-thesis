#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

source scripts/lib/shared-env.sh

# 1. Make sure app env has been initialized
if [[ ! -f env/values.yaml ]]; then
  echo "values.yaml not found, running env-init-app first..."
  bash scripts/env-init-app.sh
fi

if [[ ! -f env/postgres.env ]]; then
  echo "missing env/postgres.env; run: make env-init-base" >&2
  exit 1
fi

postgres_user="$(grep -E '^POSTGRES_USER=' env/postgres.env | cut -d= -f2- || true)"
postgres_user="${postgres_user:-postgres}"
postgres_password="$(grep -E '^POSTGRES_PASSWORD=' env/postgres.env | cut -d= -f2- || true)"

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

encoded_postgres_user="$(url_encode "$postgres_user")"
encoded_postgres_password="$(url_encode "$postgres_password")"

# 2. Generate local monolith.env from values.yaml
generate_env_from_yaml ".local.monolith" "env/monolith.env"

# 3. Create db-bootstrap.env
bootstrap_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres.local-database.svc.cluster.local:5432/bootstrap?sslmode=disable"
echo "BOOTSTRAP_DATABASE_URL=$bootstrap_url" > env/db-bootstrap.env
chmod 600 env/db-bootstrap.env
echo "Generated env/db-bootstrap.env"

echo "local monolith env initialization complete"
