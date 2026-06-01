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
  bash -lc 'set -a; source "$1" >/dev/null 2>&1; key="$2"; printf "%s" "${!key-}"' _ "$file" "$key"
}

format_env_assignment() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "$key" "$value"
}

create_default_hetzner_env() {
  local file="$1"
  if [ -f "$file" ]; then
    echo "skip $file (already exists)"
    return
  fi
  {
    format_env_assignment "HCLOUD_TOKEN" "replace-me"
    format_env_assignment "PROJECT" "skripsi"
    format_env_assignment "HCLOUD_LOCATION" "sin"
    format_env_assignment "HCLOUD_NETWORK_ZONE" "ap-southeast"
    format_env_assignment "OPERATOR_CIDRS" "$operator_cidr"
    format_env_assignment "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"
    format_env_assignment "POSTGRES_PASSWORD" "$postgres_password"
    format_env_assignment "HETZNER_SEQUENTIAL_CLUSTER_NAME" "skripsi-hetzner-benchmark"
    format_env_assignment "HETZNER_MONOLITH_CLUSTER_NAME" "skripsi-hetzner-monolith"
    format_env_assignment "HETZNER_MSA_CLUSTER_NAME" "skripsi-hetzner-msa"
    format_env_assignment "HETZNER_CONTROL_PLANE_SERVER_TYPE" "ccx13"
    format_env_assignment "HETZNER_APP_SERVER_TYPE" "ccx43"
    format_env_assignment "HETZNER_TESTING_SERVER_TYPE" "ccx23"
    format_env_assignment "HETZNER_POSTGRES_SERVER_TYPE" "ccx33"
    format_env_assignment "DOCKERHUB_NAMESPACE" "replace-me"
    format_env_assignment "AWS_REGION" "ap-southeast-1"
    format_env_assignment "S3_BUCKET" "skripsi-benchmark-results"
  } >"$file"
  echo "created $file"
}

write_or_update_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local line
  line="$(format_env_assignment "$key" "$value")"
  if [ ! -f "$file" ]; then
    printf '%s\n' "$line" >"$file"
    echo "created $file"
    return
  fi
  if grep -q -E "^${key}=" "$file"; then
    local tmp
    local existing_line
    local replaced="false"
    tmp="$(mktemp)"
    while IFS= read -r existing_line || [ -n "$existing_line" ]; do
      if [[ "$existing_line" == "${key}="* ]]; then
        printf '%s\n' "$line" >>"$tmp"
        replaced="true"
        continue
      fi
      printf '%s\n' "$existing_line" >>"$tmp"
    done <"$file"
    if [ "$replaced" != "true" ]; then
      printf '%s\n' "$line" >>"$tmp"
    fi
    mv "$tmp" "$file"
  else
    printf '%s\n' "$line" >>"$file"
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

create_default_hetzner_env "env/hetzner.env"

write_or_update_env_value "env/hetzner.env" "POSTGRES_PASSWORD" "$postgres_password"
write_or_update_env_value "env/hetzner.env" "OPERATOR_CIDRS" "$operator_cidr"
write_or_update_env_value "env/hetzner.env" "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"

echo "Hetzner env initialization complete"
