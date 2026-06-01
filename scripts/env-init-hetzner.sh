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
    for url in "https://api.ipify.org" "https://checkip.amazonaws.com" "https://ifconfig.me/ip"; do
      ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
      [ -n "$ip" ] && break
    done
  fi
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s/32\n' "$ip"
}

read_env_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

write_if_missing() {
  local file="$1"
  local content="$2"
  if [ -f "$file" ]; then
    echo "skip $file (already exists)"
    return
  fi
  printf '%s\n' "$content" >"$file"
  echo "created $file"
}

write_or_update_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [ ! -f "$file" ]; then
    printf '%s=%s\n' "$key" "$value" >"$file"
    echo "created $file"
    return
  fi
  if grep -q -E "^${key}=" "$file"; then
    perl -0pi -e "s#^${key}=.*#${key}=${value}#m" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
  echo "updated $file"
}

operator_cidr="$(read_env_value env/hetzner.env OPERATOR_CIDRS)"
operator_cidr="${operator_cidr:-$(detect_public_ip_cidr || true)}"
operator_cidr="${operator_cidr:-REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR}"
postgres_password="$(read_env_value env/hetzner.env POSTGRES_PASSWORD)"
postgres_password="${postgres_password:-$(random_hex 24)}"
operator_ssh_key="$(read_env_value env/hetzner.env OPERATOR_SSH_PUBLIC_KEY)"
if [ -z "$operator_ssh_key" ] && [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
  operator_ssh_key="$(cat "$HOME/.ssh/id_ed25519.pub")"
fi
operator_ssh_key="${operator_ssh_key:-REPLACE_WITH_OPERATOR_SSH_PUBLIC_KEY}"

write_if_missing "env/hetzner.env" "HCLOUD_TOKEN=replace-me
PROJECT=skripsi
HCLOUD_LOCATION=sin
HCLOUD_NETWORK_ZONE=ap-southeast
OPERATOR_CIDRS=${operator_cidr}
OPERATOR_SSH_PUBLIC_KEY=${operator_ssh_key}
POSTGRES_PASSWORD=${postgres_password}
HETZNER_SEQUENTIAL_CLUSTER_NAME=skripsi-hetzner-benchmark
HETZNER_MONOLITH_CLUSTER_NAME=skripsi-hetzner-monolith
HETZNER_MSA_CLUSTER_NAME=skripsi-hetzner-msa
HETZNER_CONTROL_PLANE_SERVER_TYPE=ccx13
HETZNER_APP_SERVER_TYPE=ccx43
HETZNER_TESTING_SERVER_TYPE=ccx23
HETZNER_POSTGRES_SERVER_TYPE=ccx33
DOCKERHUB_NAMESPACE=replace-me
AWS_REGION=ap-southeast-1
S3_BUCKET=skripsi-benchmark-results"

write_or_update_env_value "env/hetzner.env" "POSTGRES_PASSWORD" "$postgres_password"
write_or_update_env_value "env/hetzner.env" "OPERATOR_CIDRS" "$operator_cidr"
write_or_update_env_value "env/hetzner.env" "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"

echo "Hetzner env initialization complete"
