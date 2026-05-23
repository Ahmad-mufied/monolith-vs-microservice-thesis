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

jwt_secret="$(read_env_value env/monolith.env JWT_SECRET)"
jwt_secret="${jwt_secret:-$(random_hex 32)}"

db_password="$(read_env_value env/terraform.experiment.env DB_PASSWORD)"
db_password="${db_password:-$(random_hex 24)}"
db_instance_class="$(read_env_value env/terraform.experiment.env DB_INSTANCE_CLASS)"
db_instance_class="${db_instance_class:-db.t3.micro}"

write_if_missing "env/aws-benchmark.env" "AWS_REGION=ap-southeast-1
S3_BUCKET=skripsi-benchmark-results
ECR_NAMESPACE=skripsi
DATADOG_SITE=datadoghq.com"

write_if_missing "env/terraform.shared.env" "AWS_REGION=ap-southeast-1
PROJECT=skripsi
S3_RESULTS_BUCKET=skripsi-benchmark-results"

write_if_missing "env/terraform.experiment.env" "AWS_REGION=ap-southeast-1
PROJECT=skripsi
DB_PASSWORD=${db_password}
DB_INSTANCE_CLASS=${db_instance_class}"

write_if_missing "env/datadog.eks.env" "DATADOG_API_KEY=replace-me
DATADOG_SITE=datadoghq.com"

write_if_missing "env/monolith.eks.env" "APP_ENV=production
APP_PORT=8080
SERVICE_NAME=monolith
DB_POOL_MAX_CONNS=25
DB_POOL_MIN_CONNS=2
DB_POOL_MAX_CONN_LIFETIME=5m
DB_POOL_MAX_CONN_IDLE_TIME=1m
DB_PING_TIMEOUT=5s
HTTP_READ_HEADER_TIMEOUT=5s
HTTP_READ_TIMEOUT=15s
HTTP_WRITE_TIMEOUT=30s
HTTP_IDLE_TIMEOUT=1m
HTTP_SHUTDOWN_TIMEOUT=10s
HTTP_MAX_HEADER_BYTES=1048576
BCRYPT_COST=10
JWT_SECRET=${jwt_secret}"

write_if_missing "env/api-gateway.eks.env" "APP_ENV=production
HTTP_PORT=8080
SERVICE_NAME=api-gateway
JWT_SECRET=${jwt_secret}
AUTH_SERVICE_ADDR=auth-service.msa.svc.cluster.local:50051
ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052
TRANSACTION_SERVICE_ADDR=transaction-service.msa.svc.cluster.local:50053"

write_if_missing "env/auth-service.eks.env" "APP_ENV=production
GRPC_PORT=50051
SERVICE_NAME=auth-service
BCRYPT_COST=10
JWT_SECRET=${jwt_secret}"

write_if_missing "env/item-service.eks.env" "APP_ENV=production
GRPC_PORT=50052
SERVICE_NAME=item-service"

write_if_missing "env/transaction-service.eks.env" "APP_ENV=production
GRPC_PORT=50053
SERVICE_NAME=transaction-service
ITEM_SERVICE_ADDR=item-service.msa.svc.cluster.local:50052"

write_if_missing "env/k6-runner.eks.env" "ADMIN_USER_EMAIL=benchmark-user-001@example.com
ADMIN_USER_PASSWORD=Password123!"

write_or_update_env_value "env/monolith.eks.env" "BCRYPT_COST" "10"
write_or_update_env_value "env/auth-service.eks.env" "BCRYPT_COST" "10"

echo "EKS env initialization complete"
