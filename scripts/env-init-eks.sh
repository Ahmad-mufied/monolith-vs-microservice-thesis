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

detect_public_ip_cidr() {
  local ip=""

  if command -v curl >/dev/null 2>&1; then
    for url in \
      "https://checkip.amazonaws.com" \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip"; do
      ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "$ip" ]]; then
        break
      fi
    done
  fi

  if [[ -z "$ip" ]]; then
    return 1
  fi

  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local o1="" o2="" o3="" o4="" octet=""
    IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
      if ((octet < 0 || octet > 255)); then
        return 1
      fi
    done
    printf "%s/32\n" "$ip"
    return
  fi

  if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
    printf "%s/128\n" "$ip"
    return
  fi

  return 1
}

read_env_value() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return 0
  fi

  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
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
cluster_endpoint_public_access_cidrs="$(read_env_value env/terraform.experiment.env CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS)"
cluster_endpoint_public_access_cidrs="${cluster_endpoint_public_access_cidrs:-REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR}"
cluster_endpoint_public_access_cidrs_source="$(read_env_value env/terraform.experiment.env CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE)"
detected_public_ip_cidr="$(detect_public_ip_cidr || true)"

if [[ -z "$cluster_endpoint_public_access_cidrs_source" ]]; then
  case "$cluster_endpoint_public_access_cidrs" in
    ""|REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR)
      cluster_endpoint_public_access_cidrs_source="auto"
      ;;
    *)
      cluster_endpoint_public_access_cidrs_source="manual"
      ;;
  esac
fi

if [[ "$cluster_endpoint_public_access_cidrs_source" == "auto" ]]; then
  if [[ -n "$detected_public_ip_cidr" ]]; then
    cluster_endpoint_public_access_cidrs="$detected_public_ip_cidr"
  fi
elif [[ "$cluster_endpoint_public_access_cidrs" == "REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR" && -n "$detected_public_ip_cidr" ]]; then
  cluster_endpoint_public_access_cidrs="$detected_public_ip_cidr"
  cluster_endpoint_public_access_cidrs_source="auto"
fi

write_if_missing "env/aws-benchmark.env" "AWS_REGION=ap-southeast-1
S3_BUCKET=skripsi-benchmark-results
ECR_NAMESPACE=skripsi"

write_if_missing "env/terraform.shared.env" "AWS_REGION=ap-southeast-1
PROJECT=skripsi
S3_RESULTS_BUCKET=skripsi-benchmark-results"

write_if_missing "env/terraform.experiment.env" "AWS_REGION=ap-southeast-1
PROJECT=skripsi
DB_PASSWORD=${db_password}
DB_INSTANCE_CLASS=${db_instance_class}
CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS=${cluster_endpoint_public_access_cidrs}
CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=${cluster_endpoint_public_access_cidrs_source}"

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

k6_runner_email="$(read_env_value env/k6-runner.eks.env ADMIN_USER_EMAIL)"
k6_runner_email="${k6_runner_email:-benchmark-user-001@example.com}"
k6_runner_password="$(read_env_value env/k6-runner.eks.env ADMIN_USER_PASSWORD)"
benchmark_k6_runner_password="Password123!"

write_if_missing "env/k6-runner.eks.env" "ADMIN_USER_EMAIL=${k6_runner_email}
ADMIN_USER_PASSWORD=${benchmark_k6_runner_password}"

if is_invalid_k6_benchmark_password "$k6_runner_password" || [[ "$k6_runner_password" != "$benchmark_k6_runner_password" ]]; then
  write_or_update_env_value "env/k6-runner.eks.env" "ADMIN_USER_PASSWORD" "$benchmark_k6_runner_password"
fi

write_or_update_env_value "env/k6-runner.eks.env" "ADMIN_USER_EMAIL" "$k6_runner_email"

write_or_update_env_value "env/monolith.eks.env" "BCRYPT_COST" "10"
write_or_update_env_value "env/auth-service.eks.env" "BCRYPT_COST" "10"
write_or_update_env_value "env/terraform.experiment.env" "CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS" "$cluster_endpoint_public_access_cidrs"
write_or_update_env_value "env/terraform.experiment.env" "CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE" "$cluster_endpoint_public_access_cidrs_source"

if [[ "$cluster_endpoint_public_access_cidrs_source" == "auto" ]]; then
  if [[ -n "$detected_public_ip_cidr" ]]; then
    echo "using detected operator public CIDR: $detected_public_ip_cidr"
  else
    echo "warning: could not detect operator public IP automatically; update CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS manually before make eks-render-tfvars" >&2
  fi
fi

echo "EKS env initialization complete"
