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
operator_cidr_source="$(read_env_value env/hetzner.env OPERATOR_CIDRS_SOURCE)"
detected_public_ip_cidr="$(detect_public_ip_cidr || true)"
operator_cidr="${operator_cidr:-REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR}"
if [[ -z "$operator_cidr_source" ]]; then
  case "$operator_cidr" in
    ""|REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR)
      operator_cidr_source="auto"
      ;;
    *)
      operator_cidr_source="manual"
      ;;
  esac
fi
if [[ "$operator_cidr_source" == "auto" ]]; then
  if [[ -n "$detected_public_ip_cidr" ]]; then
    operator_cidr="$detected_public_ip_cidr"
  fi
elif [[ "$operator_cidr" == "REPLACE_WITH_OPERATOR_PUBLIC_IP_CIDR" && -n "$detected_public_ip_cidr" ]]; then
  operator_cidr="$detected_public_ip_cidr"
  operator_cidr_source="auto"
fi

postgres_password="$(read_env_value env/hetzner.env POSTGRES_PASSWORD)"
postgres_password="${postgres_password:-$(random_hex 24)}"
operator_ssh_key="$(read_env_value env/hetzner.env OPERATOR_SSH_PUBLIC_KEY)"
operator_ssh_key_source="$(read_env_value env/hetzner.env OPERATOR_SSH_PUBLIC_KEY_SOURCE)"
detected_operator_ssh_key=""
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
  detected_operator_ssh_key="$(cat "$HOME/.ssh/id_ed25519.pub")"
fi
operator_ssh_key="${operator_ssh_key:-REPLACE_WITH_OPERATOR_SSH_PUBLIC_KEY}"
if [[ -z "$operator_ssh_key_source" ]]; then
  case "$operator_ssh_key" in
    ""|REPLACE_WITH_OPERATOR_SSH_PUBLIC_KEY)
      operator_ssh_key_source="auto"
      ;;
    *)
      operator_ssh_key_source="manual"
      ;;
  esac
fi
if [[ "$operator_ssh_key_source" == "auto" ]]; then
  if [[ -n "$detected_operator_ssh_key" ]]; then
    operator_ssh_key="$detected_operator_ssh_key"
  fi
elif [[ "$operator_ssh_key" == "REPLACE_WITH_OPERATOR_SSH_PUBLIC_KEY" && -n "$detected_operator_ssh_key" ]]; then
  operator_ssh_key="$detected_operator_ssh_key"
  operator_ssh_key_source="auto"
fi

create_default_hetzner_env "env/hetzner.env"

write_or_update_env_value "env/hetzner.env" "POSTGRES_PASSWORD" "$postgres_password"
write_or_update_env_value "env/hetzner.env" "OPERATOR_CIDRS" "$operator_cidr"
write_or_update_env_value "env/hetzner.env" "OPERATOR_CIDRS_SOURCE" "$operator_cidr_source"
write_or_update_env_value "env/hetzner.env" "OPERATOR_SSH_PUBLIC_KEY" "$operator_ssh_key"
write_or_update_env_value "env/hetzner.env" "OPERATOR_SSH_PUBLIC_KEY_SOURCE" "$operator_ssh_key_source"

echo "Hetzner env initialization complete"
