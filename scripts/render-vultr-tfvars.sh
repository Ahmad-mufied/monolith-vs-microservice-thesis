#!/usr/bin/env bash
set -euo pipefail
umask 077

env_file="env/vultr.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init PLATFORM=vultr EXECUTION_MODE=<parallel|sequential>" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${VULTR_API_KEY:?VULTR_API_KEY must be set in env/vultr.env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/vultr.env}"
: "${OPERATOR_CIDRS:?OPERATOR_CIDRS must be set in env/vultr.env}"
: "${OPERATOR_SSH_PUBLIC_KEY:?OPERATOR_SSH_PUBLIC_KEY must be set in env/vultr.env}"

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

operator_cidrs_hcl="$(format_hcl_list "$OPERATOR_CIDRS")"
vpc_cidr="${VULTR_VPC_CIDR:-10.20.0.0/16}"
vpc_subnet="${vpc_cidr%/*}"
vpc_mask="${vpc_cidr#*/}"

cat > infra/terraform/vultr-shared/terraform.tfvars <<EOF
project                 = "${PROJECT:-skripsi}"
region                  = "${VULTR_REGION:-sgp}"
vpc_subnet              = "${vpc_subnet}"
vpc_subnet_mask         = ${vpc_mask}
operator_cidrs          = ${operator_cidrs_hcl}
operator_ssh_public_key = "${OPERATOR_SSH_PUBLIC_KEY}"
EOF

cat > infra/terraform/vultr-parallel/terraform.tfvars <<EOF
project                   = "${PROJECT:-skripsi}"
region                    = "${VULTR_REGION:-sgp}"
kubernetes_version        = "${VULTR_KUBERNETES_VERSION:-v1.33.0+1}"
monolith_cluster_name     = "${VULTR_MONOLITH_CLUSTER_NAME:-skripsi-vultr-monolith}"
msa_cluster_name          = "${VULTR_MSA_CLUSTER_NAME:-skripsi-vultr-msa}"
app_node_plan             = "${VULTR_APP_NODE_PLAN:-voc-c-16c-32gb-300s}"
testing_node_plan         = "${VULTR_TESTING_NODE_PLAN:-vc2-4c-8gb}"
postgres_plan             = "${VULTR_POSTGRES_PLAN:-vc2-4c-8gb}"
postgres_os_id            = ${VULTR_POSTGRES_OS_ID:-1743}
EOF

cat > infra/terraform/vultr-sequential/terraform.tfvars <<EOF
project                   = "${PROJECT:-skripsi}"
region                    = "${VULTR_REGION:-sgp}"
kubernetes_version        = "${VULTR_KUBERNETES_VERSION:-v1.33.0+1}"
sequential_cluster_name   = "${VULTR_SEQUENTIAL_CLUSTER_NAME:-skripsi-vultr-benchmark}"
app_node_plan             = "${VULTR_APP_NODE_PLAN:-voc-c-16c-32gb-300s}"
testing_node_plan         = "${VULTR_TESTING_NODE_PLAN:-vc2-4c-8gb}"
postgres_plan             = "${VULTR_POSTGRES_PLAN:-vc2-4c-8gb}"
postgres_os_id            = ${VULTR_POSTGRES_OS_ID:-1743}
EOF

echo "Rendered Vultr Terraform tfvars files"
echo "POSTGRES_PASSWORD is kept in env/vultr.env and passed by scripts/terraform-vultr.sh as TF_VAR_postgres_password"
