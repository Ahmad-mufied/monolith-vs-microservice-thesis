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

auth_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@localhost:5432/auth_db?sslmode=disable"
item_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@localhost:5432/item_db?sslmode=disable"
transaction_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@localhost:5432/transaction_db?sslmode=disable"

compose_auth_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres:5432/auth_db?sslmode=disable"
compose_item_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres:5432/item_db?sslmode=disable"
compose_transaction_database_url="postgres://${encoded_postgres_user}:${encoded_postgres_password}@postgres:5432/transaction_db?sslmode=disable"

write_if_missing "env/auth-service.env" "GRPC_PORT=50051
DATABASE_URL=${auth_database_url}
AUTH_DATABASE_URL=${auth_database_url}
JWT_SECRET=${jwt_secret}
JWT_EXPIRY=24h
BCRYPT_COST=12"

write_if_missing "env/item-service.env" "GRPC_PORT=50052
DATABASE_URL=${item_database_url}
ITEM_DATABASE_URL=${item_database_url}"

write_if_missing "env/transaction-service.env" "GRPC_PORT=50053
DATABASE_URL=${transaction_database_url}
TRANSACTION_DATABASE_URL=${transaction_database_url}
ITEM_SERVICE_ADDR=localhost:50052"

write_if_missing "env/api-gateway.env" "HTTP_PORT=8080
JWT_SECRET=${jwt_secret}
AUTH_SERVICE_ADDR=localhost:50051
ITEM_SERVICE_ADDR=localhost:50052
TRANSACTION_SERVICE_ADDR=localhost:50053"

write_if_missing "env/auth-service.compose.env" "GRPC_PORT=50051
DATABASE_URL=${compose_auth_database_url}
AUTH_DATABASE_URL=${compose_auth_database_url}
JWT_SECRET=${jwt_secret}
JWT_EXPIRY=24h
BCRYPT_COST=12"

write_if_missing "env/item-service.compose.env" "GRPC_PORT=50052
DATABASE_URL=${compose_item_database_url}
ITEM_DATABASE_URL=${compose_item_database_url}"

write_if_missing "env/transaction-service.compose.env" "GRPC_PORT=50053
DATABASE_URL=${compose_transaction_database_url}
TRANSACTION_DATABASE_URL=${compose_transaction_database_url}
ITEM_SERVICE_ADDR=item-service:50052"

write_if_missing "env/api-gateway.compose.env" "HTTP_PORT=8080
JWT_SECRET=${jwt_secret}
AUTH_SERVICE_ADDR=auth-service:50051
ITEM_SERVICE_ADDR=item-service:50052
TRANSACTION_SERVICE_ADDR=transaction-service:50053"

echo "local microservices env initialization complete"
