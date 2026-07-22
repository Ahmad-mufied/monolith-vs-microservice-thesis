#!/usr/bin/env bash
set -euo pipefail
umask 077

env_file="env/vultr.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init PLATFORM=vultr EXECUTION_MODE=parallel or EXECUTION_MODE=sequential" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${VULTR_API_KEY:?VULTR_API_KEY must be set in env/vultr.env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/vultr.env}"
: "${OPERATOR_CIDRS:?OPERATOR_CIDRS must be set in env/vultr.env}"
: "${OPERATOR_SSH_PUBLIC_KEY:?OPERATOR_SSH_PUBLIC_KEY must be set in env/vultr.env}"
: "${VULTR_KUBERNETES_VERSION:?VULTR_KUBERNETES_VERSION must be set in env/vultr.env}"

if [ "$VULTR_API_KEY" = "replace-me" ]; then
  echo "VULTR_API_KEY is still the placeholder 'replace-me'" >&2
  exit 1
fi

validate_operator_cidrs() {
  local raw="$1" entry trimmed
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

format_hcl_list() {
  local raw="$1" output="" entry trimmed
  IFS=',' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    trimmed="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$entry")"
    [ -z "$trimmed" ] && continue
    [ -n "$output" ] && output+=", "
    output+="\"$trimmed\""
  done
  printf '[%s]' "$output"
}

validate_operator_cidrs "$OPERATOR_CIDRS"
case "$OPERATOR_SSH_PUBLIC_KEY" in
  ssh-*) ;;
  *) echo "OPERATOR_SSH_PUBLIC_KEY must be a real SSH public key" >&2; exit 1 ;;
esac

vultr_app_node_count="${VULTR_APP_NODE_COUNT:-1}"
if ! [[ "$vultr_app_node_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "VULTR_APP_NODE_COUNT must be a positive whole number" >&2
  exit 1
fi

operator_cidrs_hcl="$(format_hcl_list "$OPERATOR_CIDRS")"
vpc_cidr="${VULTR_VPC_CIDR:-10.20.0.0/16}"
vpc_subnet="${vpc_cidr%/*}"
vpc_mask="${vpc_cidr#*/}"

execution_mode="${EXECUTION_MODE:-sequential}"

resolve_kubernetes_version() {
  local config_version="$VULTR_KUBERNETES_VERSION"
  
  if ! command -v jq >/dev/null 2>&1; then
    echo "$config_version"
    return 0
  fi
  
  update_env_version() {
    local version="$1"
    local temp_file
    temp_file=$(mktemp)
    sed "s|^VULTR_KUBERNETES_VERSION=.*|VULTR_KUBERNETES_VERSION=$version|" "$env_file" > "$temp_file"
    cat "$temp_file" > "$env_file"
    rm -f "$temp_file"
  }
  
  local api_response
  if api_response=$(curl -s -f --max-time 10 -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/kubernetes/versions 2>/dev/null); then
    local available_versions
    available_versions=$(echo "$api_response" | jq -r '.versions[]' 2>/dev/null || true)
    
    if [ -n "$available_versions" ]; then
      if echo "$available_versions" | grep -Fq "$config_version"; then
        echo "$config_version"
        return 0
      fi
      
      local minor_prefix
      minor_prefix=$(echo "$config_version" | grep -oE '^v1\.[0-9]+' || true)
      
      if [ -n "$minor_prefix" ]; then
        local match
        match=$(echo "$available_versions" | grep -E "^${minor_prefix}" | head -n 1 || true)
        if [ -n "$match" ]; then
          echo "WARN: Configured Vultr Kubernetes version '$config_version' is no longer supported by the Vultr API." >&2
          echo "WARN: Automatically switching to the closest available version in minor release '${minor_prefix}': '$match'" >&2
          
          # Auto-update env/vultr.env so it stays in sync
          update_env_version "$match"
          echo "INFO: Updated VULTR_KUBERNETES_VERSION to $match in $env_file" >&2
          
          echo "$match"
          return 0
        fi
      fi
      
      local absolute_latest
      absolute_latest=$(echo "$available_versions" | head -n 1 || true)
      if [ -n "$absolute_latest" ]; then
        echo "WARN: Configured Vultr Kubernetes version '$config_version' is not supported and no matching minor release was found." >&2
        echo "WARN: Switching to the latest available version on Vultr: '$absolute_latest'" >&2
        
        update_env_version "$absolute_latest"
        echo "$absolute_latest"
        return 0
      fi
    fi
  fi
  
  echo "$config_version"
}

resolved_k8s_version=$(resolve_kubernetes_version)

if [ "$execution_mode" = "parallel" ]; then
  cluster_names_hcl="{ monolith = \"${VULTR_MONOLITH_CLUSTER_NAME:-skripsi-vultr-monolith}\", msa = \"${VULTR_MSA_CLUSTER_NAME:-skripsi-vultr-msa}\" }"
else
  cluster_names_hcl="{ sequential = \"${VULTR_SEQUENTIAL_CLUSTER_NAME:-skripsi-vultr-benchmark}\" }"
fi

cat > infra/terraform/vultr/terraform.tfvars <<EOF
project                 = "${PROJECT:-skripsi}"
region                  = "${VULTR_REGION:-sgp}"
execution_mode          = "${execution_mode}"
vpc_subnet              = "${vpc_subnet}"
vpc_subnet_mask         = ${vpc_mask}
operator_cidrs          = ${operator_cidrs_hcl}
operator_ssh_public_key = "${OPERATOR_SSH_PUBLIC_KEY}"
kubernetes_version      = "${resolved_k8s_version}"
cluster_names           = ${cluster_names_hcl}
app_node_plan           = "${VULTR_APP_NODE_PLAN:-voc-c-8c-16gb-150s-amd}"
app_node_count          = ${vultr_app_node_count}
testing_node_plan       = "${VULTR_TESTING_NODE_PLAN:-vc2-2c-4gb}"
postgres_plan           = "${VULTR_POSTGRES_PLAN:-voc-c-2c-4gb-50s-amd}"
postgres_os_id          = ${VULTR_POSTGRES_OS_ID:-1743}
EOF

echo "Rendered Vultr Terraform tfvars (execution_mode=${execution_mode})"
echo "POSTGRES_PASSWORD is kept in env/vultr.env and passed by scripts/terraform-vultr.sh as TF_VAR_postgres_password"
