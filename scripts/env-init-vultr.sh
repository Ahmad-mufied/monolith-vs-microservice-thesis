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
  [ -n "$ip" ] || return 1
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32\n' "$ip"
    return
  fi
  if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
    printf '%s/128\n' "$ip"
    return
  fi
  return 1
}

read_env_value() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  bash -c 'set -a; source "$1" >/dev/null 2>&1; key="$2"; printf "%s" "${!key-}"' _ "$file" "$key"
}

format_env_assignment() {
  local key="$1"
  local value="$2"
  printf '%s=%q\n' "$key" "$value"
}

write_or_update_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local line tmp existing_line
  line="$(format_env_assignment "$key" "$value")"
  if [ ! -f "$file" ]; then
    printf '%s\n' "$line" >"$file"
    return
  fi
  if grep -q -E "^${key}=" "$file"; then
    tmp="$(mktemp)"
    while IFS= read -r existing_line || [ -n "$existing_line" ]; do
      if [[ "$existing_line" == "${key}="* ]]; then
        printf '%s\n' "$line" >>"$tmp"
      else
        printf '%s\n' "$existing_line" >>"$tmp"
      fi
    done <"$file"
    mv "$tmp" "$file"
  else
    printf '%s\n' "$line" >>"$file"
  fi
}

detect_ssh_public_key() {
  local key_path key_line
  if command -v ssh-add >/dev/null 2>&1; then
    key_line="$(ssh-add -L 2>/dev/null | awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ {print; exit}' || true)"
    if [ -n "$key_line" ]; then
      printf '%s\n' "$key_line"
      return 0
    fi
  fi
  for key_path in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [ -f "$key_path" ]; then
      key_line="$(awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)/ {print; exit}' "$key_path")"
      if [ -n "$key_line" ]; then
        printf '%s\n' "$key_line"
        return 0
      fi
    fi
  done
  return 1
}

env_file="env/vultr.env"
operator_cidr="$(read_env_value "$env_file" OPERATOR_CIDRS)"
operator_cidr_source="$(read_env_value "$env_file" OPERATOR_CIDRS_SOURCE)"
detected_public_ip_cidr="$(detect_public_ip_cidr || true)"
operator_cidr="${operator_cidr:-REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR}"
operator_cidr_source="${operator_cidr_source:-auto}"
if [[ "$operator_cidr_source" == "auto" && -n "$detected_public_ip_cidr" ]]; then
  operator_cidr="$detected_public_ip_cidr"
fi

operator_ssh_key="$(read_env_value "$env_file" OPERATOR_SSH_PUBLIC_KEY)"
operator_ssh_key_source="$(read_env_value "$env_file" OPERATOR_SSH_PUBLIC_KEY_SOURCE)"
detected_operator_ssh_key="$(detect_ssh_public_key || true)"
operator_ssh_key="${operator_ssh_key:-REPLACE_WITH_OPERATOR_SSH_PUBLIC_KEY}"
operator_ssh_key_source="${operator_ssh_key_source:-auto}"
if [[ "$operator_ssh_key_source" == "auto" && -n "$detected_operator_ssh_key" ]]; then
  operator_ssh_key="$detected_operator_ssh_key"
fi

postgres_password="$(read_env_value "$env_file" POSTGRES_PASSWORD)"
postgres_password="${postgres_password:-$(random_hex 24)}"

if [ ! -f "$env_file" ]; then
  {
    format_env_assignment "VULTR_API_KEY" "replace-me"
    format_env_assignment "PROJECT" "skripsi"
    format_env_assignment "VULTR_REGION" "sgp"
    format_env_assignment "VULTR_VPC_CIDR" "10.20.0.0/16"
    format_env_assignment "OPERATOR_CIDRS" "$operator_cidr"
    format_env_assignment "OPERATOR_CIDRS_SOURCE" "$operator_cidr_source"
    format_env_assignment "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"
    format_env_assignment "OPERATOR_SSH_PUBLIC_KEY_SOURCE" "$operator_ssh_key_source"
    format_env_assignment "POSTGRES_PASSWORD" "$postgres_password"
    format_env_assignment "VULTR_SEQUENTIAL_CLUSTER_NAME" "skripsi-vultr-benchmark"
    format_env_assignment "VULTR_MONOLITH_CLUSTER_NAME" "skripsi-vultr-monolith"
    format_env_assignment "VULTR_MSA_CLUSTER_NAME" "skripsi-vultr-msa"
    format_env_assignment "VULTR_KUBERNETES_VERSION" "v1.33.0+1"
    format_env_assignment "VULTR_APP_NODE_PLAN" "voc-c-8c-16gb-150s-amd"
    format_env_assignment "VULTR_APP_NODE_COUNT" "1"
    format_env_assignment "VULTR_TESTING_NODE_PLAN" "vc2-2c-4gb"
    format_env_assignment "VULTR_POSTGRES_PLAN" "voc-c-2c-4gb-50s-amd"
    format_env_assignment "VULTR_POSTGRES_OS_ID" "1743"
    format_env_assignment "DOCKERHUB_NAMESPACE" "replace-me"
    format_env_assignment "AWS_REGION" "ap-southeast-1"
    format_env_assignment "S3_BUCKET" "skripsi-benchmark-results"
  } >"$env_file"
  echo "created $env_file"
fi

write_or_update_env_value "$env_file" "POSTGRES_PASSWORD" "$postgres_password"
write_or_update_env_value "$env_file" "OPERATOR_CIDRS" "$operator_cidr"
write_or_update_env_value "$env_file" "OPERATOR_CIDRS_SOURCE" "$operator_cidr_source"
write_or_update_env_value "$env_file" "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"
write_or_update_env_value "$env_file" "OPERATOR_SSH_PUBLIC_KEY_SOURCE" "$operator_ssh_key_source"

current_vultr_api_key="$(read_env_value "$env_file" VULTR_API_KEY)"
current_dockerhub_namespace="$(read_env_value "$env_file" DOCKERHUB_NAMESPACE)"

echo "Vultr env initialization complete"
echo "  file: $env_file"
if [ "$current_vultr_api_key" = "replace-me" ] || [ "$current_dockerhub_namespace" = "replace-me" ]; then
  echo "  next: edit VULTR_API_KEY and DOCKERHUB_NAMESPACE if they are still placeholders"
else
  echo "  next: run make preflight-check after generic env-init stores the operator profile"
fi
