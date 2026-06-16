#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

source scripts/lib/shared-env.sh

random_hex() {
  local bytes="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi

  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

is_invalid_k6_benchmark_password() {
  local value="${1:-}"

  case "$value" in
    ""|"replace-me"|"CHANGE_ME"|"change-me"|"your_api_key"|"example")
      return 0
      ;;
  esac

  return 1
}

read_env_value() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  read_env_value_from_file "$file" "$key"
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

migrate_if_missing() {
  local preferred="$1"
  local legacy="$2"

  if [[ -f "$preferred" || ! -f "$legacy" ]]; then
    return 0
  fi

  cp "$legacy" "$preferred"
  chmod 600 "$preferred"
  echo "migrated $legacy -> $preferred"
}

migrate_if_missing "env/datadog.shared.env" "env/datadog.eks.env"
migrate_if_missing "env/monolith.app.env" "env/monolith.eks.env"
migrate_if_missing "env/api-gateway.app.env" "env/api-gateway.eks.env"
migrate_if_missing "env/auth-service.app.env" "env/auth-service.eks.env"
migrate_if_missing "env/item-service.app.env" "env/item-service.eks.env"
migrate_if_missing "env/transaction-service.app.env" "env/transaction-service.eks.env"
migrate_if_missing "env/k6-runner.app.env" "env/k6-runner.eks.env"

resolve_shared_jwt_secret() {
  local service env_file jwt_secret

  for service in monolith api-gateway auth-service; do
    env_file="$(resolve_app_env_file "$service" || true)"
    case "$service" in
      monolith)
        env_file="${env_file:-env/monolith.app.env}"
        ;;
      api-gateway)
        env_file="${env_file:-env/api-gateway.app.env}"
        ;;
      auth-service)
        env_file="${env_file:-env/auth-service.app.env}"
        ;;
    esac

    jwt_secret="$(read_env_value "$env_file" JWT_SECRET)"
    if [[ -n "$jwt_secret" ]]; then
      printf '%s\n' "$jwt_secret"
      return 0
    fi
  done

  return 0
}

jwt_secret="$(resolve_shared_jwt_secret)"
jwt_secret="${jwt_secret:-$(random_hex 32)}"

benchmark_k6_runner_password="Password123!"
k6_runner_file="$(resolve_app_env_file k6-runner || true)"
k6_runner_email="$(read_env_value "${k6_runner_file:-env/k6-runner.app.env}" ADMIN_USER_EMAIL)"
k6_runner_email="${k6_runner_email:-benchmark-user-001@example.com}"
k6_runner_password_current="$(read_env_value "${k6_runner_file:-env/k6-runner.app.env}" ADMIN_USER_PASSWORD)"
k6_runner_password="$k6_runner_password_current"
if is_invalid_k6_benchmark_password "$k6_runner_password_current"; then
  k6_runner_password="$benchmark_k6_runner_password"
fi

write_if_missing "env/datadog.shared.env" "DATADOG_API_KEY=replace-me
DATADOG_SITE=datadoghq.com"

write_if_missing "env/monolith.app.env" "APP_ENV=production
APP_PORT=8080
SERVICE_NAME=monolith
DB_POOL_MAX_CONNS=25
DB_POOL_MIN_CONNS=2
DB_POOL_MAX_CONN_LIFETIME=5m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s
HTTP_READ_HEADER_TIMEOUT=5s
HTTP_READ_TIMEOUT=15s
HTTP_WRITE_TIMEOUT=40s
HTTP_IDLE_TIMEOUT=1m
HTTP_SHUTDOWN_TIMEOUT=10s
HTTP_MAX_HEADER_BYTES=1048576
BCRYPT_COST=10
JWT_SECRET=${jwt_secret}
DIAGNOSTIC_LOGGING_ENABLED=false
APP_REQUEST_TIMEOUT=35s
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=8
LOGIN_QUEUE_TIMEOUT=2s"

write_if_missing "env/api-gateway.app.env" "APP_ENV=production
HTTP_PORT=8080
SERVICE_NAME=api-gateway
JWT_SECRET=${jwt_secret}
DIAGNOSTIC_LOGGING_ENABLED=false
AUTH_SERVICE_ADDR=dns:///auth-service-headless.msa.svc.cluster.local:50051
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
TRANSACTION_SERVICE_ADDR=dns:///transaction-service-headless.msa.svc.cluster.local:50053
GRPC_CALL_TIMEOUT=32s
REQUEST_TIMEOUT=35s
HTTP_WRITE_TIMEOUT=40s"

write_if_missing "env/auth-service.app.env" "APP_ENV=production
GRPC_PORT=50051
SERVICE_NAME=auth-service
BCRYPT_COST=10
JWT_SECRET=${jwt_secret}
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_REQUEST_TIMEOUT=30s
LOGIN_ADMISSION_ENABLED=true
LOGIN_MAX_CONCURRENCY=2
LOGIN_MAX_CONCURRENCY_HPA=1
LOGIN_QUEUE_TIMEOUT=2s"

write_if_missing "env/item-service.app.env" "APP_ENV=production
GRPC_PORT=50052
SERVICE_NAME=item-service
DIAGNOSTIC_LOGGING_ENABLED=false
GRPC_REQUEST_TIMEOUT=30s"

write_if_missing "env/transaction-service.app.env" "APP_ENV=production
GRPC_PORT=50053
SERVICE_NAME=transaction-service
DIAGNOSTIC_LOGGING_ENABLED=false
ITEM_SERVICE_ADDR=dns:///item-service-headless.msa.svc.cluster.local:50052
GRPC_REQUEST_TIMEOUT=30s
ITEM_VALIDATION_TIMEOUT=25s"

write_if_missing "env/k6-runner.app.env" "ADMIN_USER_EMAIL=${k6_runner_email}
ADMIN_USER_PASSWORD=${k6_runner_password}"

if is_invalid_k6_benchmark_password "$k6_runner_password_current"; then
  write_or_update_env_value "env/k6-runner.app.env" "ADMIN_USER_PASSWORD" "$benchmark_k6_runner_password"
fi

for app_env_file in \
  "env/monolith.app.env" \
  "env/api-gateway.app.env" \
  "env/auth-service.app.env" \
  "env/item-service.app.env" \
  "env/transaction-service.app.env"; do
  write_or_update_env_value "$app_env_file" "DIAGNOSTIC_LOGGING_ENABLED" "false"
done

write_or_update_env_value "env/k6-runner.app.env" "ADMIN_USER_EMAIL" "$k6_runner_email"
write_or_update_env_value "env/monolith.app.env" "BCRYPT_COST" "10"
update_if_missing_or_default "env/monolith.app.env" "HTTP_WRITE_TIMEOUT" "30s" "40s"
update_if_missing_or_default "env/monolith.app.env" "APP_REQUEST_TIMEOUT" "30s" "35s"
write_or_update_env_value "env/monolith.app.env" "LOGIN_ADMISSION_ENABLED" "true"
write_or_update_env_value "env/monolith.app.env" "LOGIN_MAX_CONCURRENCY" "8"
write_or_update_env_value "env/monolith.app.env" "LOGIN_QUEUE_TIMEOUT" "2s"
write_or_update_env_value "env/auth-service.app.env" "BCRYPT_COST" "10"
update_if_missing_or_default "env/api-gateway.app.env" "GRPC_CALL_TIMEOUT" "10s" "32s"
update_if_missing_or_default "env/api-gateway.app.env" "REQUEST_TIMEOUT" "30s" "35s"
update_if_missing_or_default "env/api-gateway.app.env" "HTTP_WRITE_TIMEOUT" "15s" "40s"
update_if_missing_or_default "env/auth-service.app.env" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
write_or_update_env_value "env/auth-service.app.env" "LOGIN_ADMISSION_ENABLED" "true"
write_or_update_env_value "env/auth-service.app.env" "LOGIN_MAX_CONCURRENCY" "2"
write_or_update_env_value "env/auth-service.app.env" "LOGIN_MAX_CONCURRENCY_HPA" "1"
write_or_update_env_value "env/auth-service.app.env" "LOGIN_QUEUE_TIMEOUT" "2s"
update_if_missing_or_default "env/item-service.app.env" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
update_if_missing_or_default "env/transaction-service.app.env" "GRPC_REQUEST_TIMEOUT" "15s" "30s"
update_if_missing_or_default "env/transaction-service.app.env" "ITEM_VALIDATION_TIMEOUT" "10s" "25s"
update_if_missing_or_default "env/api-gateway.app.env" "AUTH_SERVICE_ADDR" "auth-service.msa.svc.cluster.local:50051" "dns:///auth-service-headless.msa.svc.cluster.local:50051"
update_if_missing_or_default "env/api-gateway.app.env" "ITEM_SERVICE_ADDR" "item-service.msa.svc.cluster.local:50052" "dns:///item-service-headless.msa.svc.cluster.local:50052"
update_if_missing_or_default "env/api-gateway.app.env" "TRANSACTION_SERVICE_ADDR" "transaction-service.msa.svc.cluster.local:50053" "dns:///transaction-service-headless.msa.svc.cluster.local:50053"
update_if_missing_or_default "env/transaction-service.app.env" "ITEM_SERVICE_ADDR" "item-service.msa.svc.cluster.local:50052" "dns:///item-service-headless.msa.svc.cluster.local:50052"

echo "App env initialization complete"
