#!/usr/bin/env bash
set -euo pipefail
umask 077

required_files=(
  env/terraform.shared.env
  env/terraform.experiment.env
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing $file; run: make env-init PLATFORM=eks EXECUTION_MODE=<parallel|sequential>" >&2
    exit 1
  fi
done

set -a
source env/terraform.shared.env
source env/terraform.experiment.env
set +a

: "${S3_RESULTS_BUCKET:?S3_RESULTS_BUCKET must be set in env/terraform.shared.env}"
: "${CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS:?CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS must be set in env/terraform.experiment.env}"

shared_aws_region="${AWS_REGION:-ap-southeast-1}"
shared_project="${PROJECT:-skripsi}"
budget_amount="${BUDGET_AMOUNT:-30}"
budget_threshold_percent="${BUDGET_THRESHOLD_PERCENT:-100}"
budget_alert_emails="${BUDGET_ALERT_EMAILS:-}"
experiment_aws_region="${AWS_REGION:-ap-southeast-1}"
experiment_project="${PROJECT:-skripsi}"
experiment_db_instance_class="${DB_INSTANCE_CLASS:-db.t3.micro}"
experiment_cluster_version="${CLUSTER_VERSION:-1.34}"
experiment_cluster_support_type="${CLUSTER_SUPPORT_TYPE:-STANDARD}"
monolith_cluster_name="${MONOLITH_CLUSTER_NAME:-skripsi-monolith}"
msa_cluster_name="${MSA_CLUSTER_NAME:-skripsi-msa}"
sequential_cluster_name="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}"
cluster_endpoint_public_access_cidrs="${CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS}"

case "$cluster_endpoint_public_access_cidrs" in
  ""|REPLACE_WITH_*|0.0.0.0/0|::/0)
    echo "CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS must contain one or more explicit operator CIDRs, not placeholders or world-open ranges" >&2
    exit 1
    ;;
esac

if [[ ! "$experiment_cluster_version" =~ ^1\.[0-9]+$ ]]; then
  echo "CLUSTER_VERSION must be a Kubernetes minor version such as 1.34" >&2
  exit 1
fi

case "$experiment_cluster_support_type" in
  STANDARD|EXTENDED)
    ;;
  *)
    echo "CLUSTER_SUPPORT_TYPE must be STANDARD or EXTENDED" >&2
    exit 1
    ;;
esac

format_hcl_cidr_list() {
  local raw="$1"
  local -a entries=()
  local cidr trimmed output=""

  IFS=',' read -r -a entries <<< "$raw"
  for cidr in "${entries[@]}"; do
    trimmed="$(printf '%s' "$cidr" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    case "$trimmed" in
      REPLACE_WITH_*|0.0.0.0/0|::/0)
        echo "invalid CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS entry: $trimmed" >&2
        exit 1
        ;;
    esac
    if [[ -n "$output" ]]; then
      output+=", "
    fi
    output+="\"$trimmed\""
  done

  if [[ -z "$output" ]]; then
    echo "CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS must contain at least one non-empty CIDR entry" >&2
    exit 1
  fi

  printf '[%s]' "$output"
}

format_hcl_string_list() {
  local raw="$1"
  local -a entries=()
  local entry trimmed output=""

  if [[ -z "$raw" ]]; then
    echo "[]"
    return
  fi

  IFS=',' read -r -a entries <<< "$raw"
  for entry in "${entries[@]}"; do
    trimmed="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    if [[ -n "$output" ]]; then
      output+=", "
    fi
    output+="\"$trimmed\""
  done

  if [[ -z "$output" ]]; then
    echo "[]"
    return
  fi

  printf '[%s]' "$output"
}

cluster_endpoint_public_access_cidrs_hcl="$(format_hcl_cidr_list "$cluster_endpoint_public_access_cidrs")"
budget_alert_emails_hcl="$(format_hcl_string_list "$budget_alert_emails")"

cat > infra/terraform/aws-shared/terraform.tfvars <<EOF
aws_region        = "${shared_aws_region}"
project           = "${shared_project}"
monolith_cluster_name = "${monolith_cluster_name}"
msa_cluster_name = "${msa_cluster_name}"
sequential_cluster_name = "${sequential_cluster_name}"
s3_results_bucket = "${S3_RESULTS_BUCKET}"

# Budget nuclear shutdown protection
budget_amount            = ${budget_amount}
budget_threshold_percent = ${budget_threshold_percent}
budget_alert_emails      = ${budget_alert_emails_hcl}
EOF

cat > infra/terraform/aws-parallel/terraform.tfvars <<EOF
aws_region  = "${experiment_aws_region}"
project     = "${experiment_project}"
monolith_cluster_name = "${monolith_cluster_name}"
msa_cluster_name = "${msa_cluster_name}"
cluster_version = "${experiment_cluster_version}"
cluster_support_type = "${experiment_cluster_support_type}"
cluster_endpoint_public_access_cidrs = ${cluster_endpoint_public_access_cidrs_hcl}
db_instance_class = "${experiment_db_instance_class}"
EOF

cat > infra/terraform/aws-sequential/terraform.tfvars <<EOF
aws_region  = "${experiment_aws_region}"
project     = "${experiment_project}"
sequential_cluster_name = "${sequential_cluster_name}"
cluster_version = "${experiment_cluster_version}"
cluster_support_type = "${experiment_cluster_support_type}"
cluster_endpoint_public_access_cidrs = ${cluster_endpoint_public_access_cidrs_hcl}
db_instance_class = "${experiment_db_instance_class}"
EOF

echo "Rendered Terraform tfvars files:"
echo "  infra/terraform/aws-shared/terraform.tfvars"
echo "  infra/terraform/aws-parallel/terraform.tfvars"
echo "  infra/terraform/aws-sequential/terraform.tfvars"
