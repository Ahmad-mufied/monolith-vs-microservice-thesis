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

write_or_update_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if [[ ! -f "$file" ]]; then
    printf "%s=%s\n" "$key" "$value" >"$file"
    echo "created $file"
    return
  fi

  local current_value
  current_value="$(read_env_value "$file" "$key")"
  if [[ "$current_value" == "$value" ]]; then
    echo "skip $file ($key already up to date)"
    return
  fi

  if grep -q -E "^${key}=" "$file"; then
    perl -0pi -e "s#^${key}=.*#${key}=${value}#m" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >>"$file"
  fi

  echo "updated $file"
}

update_if_missing_or_default() {
  local file="$1"
  local key="$2"
  local old_default="$3"
  local new_default="$4"

  local current_value
  current_value="$(read_env_value "$file" "$key")"
  if [[ -z "$current_value" || "$current_value" == "$old_default" ]]; then
    write_or_update_env_value "$file" "$key" "$new_default"
  else
    echo "skip $file ($key has custom value)"
  fi
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
BCRYPT_COST=10
GRPC_REQUEST_TIMEOUT=30s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=2
LOGIN_QUEUE_TIMEOUT=2s
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/item-service.env" "GRPC_PORT=50052
DATABASE_URL=${item_database_url}
ITEM_DATABASE_URL=${item_database_url}
GRPC_REQUEST_TIMEOUT=30s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/transaction-service.env" "GRPC_PORT=50053
DATABASE_URL=${transaction_database_url}
TRANSACTION_DATABASE_URL=${transaction_database_url}
ITEM_SERVICE_ADDR=localhost:50052
GRPC_REQUEST_TIMEOUT=30s
ITEM_VALIDATION_TIMEOUT=25s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/api-gateway.env" "HTTP_PORT=8080
JWT_SECRET=${jwt_secret}
AUTH_SERVICE_ADDR=localhost:50051
ITEM_SERVICE_ADDR=localhost:50052
TRANSACTION_SERVICE_ADDR=localhost:50053
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false"

write_if_missing "env/auth-service.compose.env" "GRPC_PORT=50051
DATABASE_URL=${compose_auth_database_url}
AUTH_DATABASE_URL=${compose_auth_database_url}
JWT_SECRET=${jwt_secret}
JWT_EXPIRY=24h
BCRYPT_COST=10
GRPC_REQUEST_TIMEOUT=30s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=2
LOGIN_QUEUE_TIMEOUT=2s
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/item-service.compose.env" "GRPC_PORT=50052
DATABASE_URL=${compose_item_database_url}
ITEM_DATABASE_URL=${compose_item_database_url}
GRPC_REQUEST_TIMEOUT=30s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/transaction-service.compose.env" "GRPC_PORT=50053
DATABASE_URL=${compose_transaction_database_url}
TRANSACTION_DATABASE_URL=${compose_transaction_database_url}
ITEM_SERVICE_ADDR=item-service:50052
GRPC_REQUEST_TIMEOUT=30s
ITEM_VALIDATION_TIMEOUT=25s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false
DB_POOL_MAX_CONNS=6
DB_POOL_MIN_CONNS=1
DB_POOL_MAX_CONN_LIFETIME=15m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s"

write_if_missing "env/api-gateway.compose.env" "HTTP_PORT=8080
JWT_SECRET=${jwt_secret}
AUTH_SERVICE_ADDR=auth-service:50051
ITEM_SERVICE_ADDR=item-service:50052
TRANSACTION_SERVICE_ADDR=transaction-service:50053
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s
DATADOG_ENABLED=false
DIAGNOSTIC_LOGGING_ENABLED=false"

write_or_update_env_value "env/auth-service.env" "BCRYPT_COST" "10"
write_or_update_env_value "env/auth-service.compose.env" "BCRYPT_COST" "10"
for auth_env_file in env/auth-service.env env/auth-service.compose.env; do
  write_or_update_env_value "$auth_env_file" "DIAGNOSTIC_LOGGING_ENABLED" "false"
  update_if_missing_or_default "$auth_env_file" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
  write_or_update_env_value "$auth_env_file" "LOGIN_ADMISSION_ENABLED" "true"
  write_or_update_env_value "$auth_env_file" "LOGIN_MAX_CONCURRENCY" "2"
  write_or_update_env_value "$auth_env_file" "LOGIN_QUEUE_TIMEOUT" "2s"
  write_or_update_env_value "$auth_env_file" "DB_POOL_MAX_CONNS" "6"
  write_or_update_env_value "$auth_env_file" "DB_POOL_MIN_CONNS" "1"
  write_or_update_env_value "$auth_env_file" "DB_POOL_MAX_CONN_LIFETIME" "15m"
  write_or_update_env_value "$auth_env_file" "DB_POOL_MAX_CONN_IDLE_TIME" "1m"
  write_or_update_env_value "$auth_env_file" "DB_PING_TIMEOUT" "5s"
done
for item_env_file in env/item-service.env env/item-service.compose.env; do
  write_or_update_env_value "$item_env_file" "DIAGNOSTIC_LOGGING_ENABLED" "false"
  update_if_missing_or_default "$item_env_file" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
  write_or_update_env_value "$item_env_file" "DB_POOL_MAX_CONNS" "6"
  write_or_update_env_value "$item_env_file" "DB_POOL_MIN_CONNS" "1"
  write_or_update_env_value "$item_env_file" "DB_POOL_MAX_CONN_LIFETIME" "15m"
  write_or_update_env_value "$item_env_file" "DB_POOL_MAX_CONN_IDLE_TIME" "1m"
  write_or_update_env_value "$item_env_file" "DB_PING_TIMEOUT" "5s"
done
for tx_env_file in env/transaction-service.env env/transaction-service.compose.env; do
  write_or_update_env_value "$tx_env_file" "DIAGNOSTIC_LOGGING_ENABLED" "false"
  update_if_missing_or_default "$tx_env_file" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
  update_if_missing_or_default "$tx_env_file" "ITEM_VALIDATION_TIMEOUT" "10s" "25s"
  write_or_update_env_value "$tx_env_file" "DB_POOL_MAX_CONNS" "6"
  write_or_update_env_value "$tx_env_file" "DB_POOL_MIN_CONNS" "1"
  write_or_update_env_value "$tx_env_file" "DB_POOL_MAX_CONN_LIFETIME" "15m"
  write_or_update_env_value "$tx_env_file" "DB_POOL_MAX_CONN_IDLE_TIME" "1m"
  write_or_update_env_value "$tx_env_file" "DB_PING_TIMEOUT" "5s"
done
for gateway_env_file in env/api-gateway.env env/api-gateway.compose.env; do
  write_or_update_env_value "$gateway_env_file" "DIAGNOSTIC_LOGGING_ENABLED" "false"
  update_if_missing_or_default "$gateway_env_file" "GRPC_CALL_TIMEOUT" "10s" "32s"
  update_if_missing_or_default "$gateway_env_file" "REQUEST_TIMEOUT" "30s" "35s"
  update_if_missing_or_default "$gateway_env_file" "HTTP_WRITE_TIMEOUT" "15s" "40s"
done

echo "local microservices env initialization complete"
