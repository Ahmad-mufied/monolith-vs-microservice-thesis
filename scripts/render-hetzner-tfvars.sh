#!/usr/bin/env bash
set -euo pipefail
umask 077

env_file="env/hetzner.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init-hetzner" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN must be set in env/hetzner.env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/hetzner.env}"
: "${OPERATOR_CIDRS:?OPERATOR_CIDRS must be set in env/hetzner.env}"
: "${OPERATOR_SSH_PUBLIC_KEY:?OPERATOR_SSH_PUBLIC_KEY must be set in env/hetzner.env}"

if [ "$HCLOUD_TOKEN" = "replace-me" ]; then
  echo "HCLOUD_TOKEN is still the placeholder 'replace-me'" >&2
  exit 1
fi

validate_operator_cidrs() {
  local raw="$1"
  local entry trimmed
  IFS=',' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    trimmed="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$entry")"
    case "$trimmed" in
      ""|REPLACE_WITH_*|0.0.0.0/0|::/0)
        echo "OPERATOR_CIDRS must contain explicit CIDR(s), not placeholders or world-open ranges" >&2
        exit 1
        ;;
    esac
  done
}

validate_operator_cidrs "$OPERATOR_CIDRS"

case "$OPERATOR_SSH_PUBLIC_KEY" in
  ssh-*) ;;
  *)
    echo "OPERATOR_SSH_PUBLIC_KEY must be a real SSH public key" >&2
    exit 1
    ;;
esac

format_hcl_list() {
  local raw="$1"
  local output=""
  local entry trimmed
  IFS=',' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    trimmed="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$entry")"
    [ -z "$trimmed" ] && continue
    [ -n "$output" ] && output+=", "
    output+="\"$trimmed\""
  done
  printf '[%s]' "$output"
}

operator_cidrs_hcl="$(format_hcl_list "$OPERATOR_CIDRS")"

cat > infra/terraform/hetzner-shared/terraform.tfvars <<EOF
hcloud_token            = "${HCLOUD_TOKEN}"
project                 = "${PROJECT:-skripsi}"
operator_cidrs          = ${operator_cidrs_hcl}
operator_ssh_public_key = "${OPERATOR_SSH_PUBLIC_KEY}"
network_zone            = "${HCLOUD_NETWORK_ZONE:-ap-southeast}"
EOF

cat > infra/terraform/hetzner-experiment-sequential/terraform.tfvars <<EOF
hcloud_token              = "${HCLOUD_TOKEN}"
project                   = "${PROJECT:-skripsi}"
location                  = "${HCLOUD_LOCATION:-sin}"
sequential_cluster_name   = "${HETZNER_SEQUENTIAL_CLUSTER_NAME:-skripsi-hetzner-benchmark}"
control_plane_server_type = "${HETZNER_CONTROL_PLANE_SERVER_TYPE:-ccx13}"
app_server_type           = "${HETZNER_APP_SERVER_TYPE:-ccx43}"
testing_server_type       = "${HETZNER_TESTING_SERVER_TYPE:-ccx23}"
postgres_server_type      = "${HETZNER_POSTGRES_SERVER_TYPE:-ccx33}"
EOF

cat > infra/terraform/hetzner-experiment/terraform.tfvars <<EOF
hcloud_token              = "${HCLOUD_TOKEN}"
project                   = "${PROJECT:-skripsi}"
location                  = "${HCLOUD_LOCATION:-sin}"
monolith_cluster_name     = "${HETZNER_MONOLITH_CLUSTER_NAME:-skripsi-hetzner-monolith}"
msa_cluster_name          = "${HETZNER_MSA_CLUSTER_NAME:-skripsi-hetzner-msa}"
control_plane_server_type = "${HETZNER_CONTROL_PLANE_SERVER_TYPE:-ccx13}"
app_server_type           = "${HETZNER_APP_SERVER_TYPE:-ccx43}"
testing_server_type       = "${HETZNER_TESTING_SERVER_TYPE:-ccx23}"
postgres_server_type      = "${HETZNER_POSTGRES_SERVER_TYPE:-ccx33}"
EOF

echo "Rendered Hetzner Terraform tfvars files"
