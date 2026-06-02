#!/usr/bin/env bash
set -euo pipefail

terraform_dir="${TERRAFORM_AWS_S3_WRITER_DIR:-infra/terraform/aws-s3-writer}"
terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"

explicit_project="${PROJECT:-}"
explicit_aws_region="${AWS_REGION:-}"
explicit_s3_bucket="${S3_RESULTS_BUCKET:-${S3_BUCKET:-}}"

for env_file in env/vultr.env env/hetzner.env env/terraform.shared.env; do
  if [ -f "$env_file" ]; then
    set -a
    source "$env_file"
    set +a
  fi
done

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE="$terraform_aws_profile"

project="${explicit_project:-${PROJECT:-skripsi}}"
aws_region="${explicit_aws_region:-${AWS_REGION:-ap-southeast-1}}"
s3_results_bucket="${explicit_s3_bucket:-${S3_RESULTS_BUCKET:-${S3_BUCKET:-}}}"

: "${s3_results_bucket:?S3_BUCKET or S3_RESULTS_BUCKET must be set before running aws-s3-writer Terraform}"

case "$s3_results_bucket" in
  ""|replace-me|REPLACE_WITH_*)
    echo "S3 bucket is still empty or a placeholder: $s3_results_bucket" >&2
    exit 1
    ;;
esac

terraform_command="${1:-}"
if [[ "$terraform_command" == "destroy" ]]; then
  : "${S3_BENCHMARK_DATA_VERIFIED:?Refusing destroy. Verify benchmark data exists in S3, then rerun with S3_BENCHMARK_DATA_VERIFIED=true}"
  if [[ "$S3_BENCHMARK_DATA_VERIFIED" != "true" ]]; then
    echo "S3_BENCHMARK_DATA_VERIFIED must be true to run aws-s3-writer destroy" >&2
    exit 1
  fi
fi

export TF_VAR_project="$project"
export TF_VAR_aws_region="$aws_region"
export TF_VAR_s3_results_bucket="$s3_results_bucket"

echo "=== AWS S3 Writer Terraform ==="
echo "  dir        : $terraform_dir"
echo "  region     : $aws_region"
echo "  project    : $project"
echo "  s3_bucket  : $s3_results_bucket"
echo ""

terraform -chdir="$terraform_dir" "$@"
