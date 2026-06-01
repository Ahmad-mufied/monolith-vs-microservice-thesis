#!/usr/bin/env bash
set -euo pipefail

env_file="env/terraform.experiment.env"
terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_command="${1:-}"
tf_dir="infra/terraform/experiment-sequential"

if [[ ! -f "$env_file" ]]; then
  echo "missing $env_file; run: make env-init-eks" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

if [[ "$terraform_command" != "output" ]]; then
  : "${DB_PASSWORD:?DB_PASSWORD must be set in env/terraform.experiment.env}"
fi

if [[ "$terraform_command" == "plan" || "$terraform_command" == "apply" ]]; then
  cluster_name="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}"
  rds_identifier="${cluster_name}-postgres"

  state_list="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$tf_dir" state list 2>/dev/null || true)"
  state_tracks_cluster=false
  state_tracks_rds=false
  if grep -Fq 'module.sequential_cluster.module.eks.aws_eks_cluster.this[0]' <<<"$state_list"; then
    state_tracks_cluster=true
  fi
  if grep -Fq 'module.sequential_cluster.aws_db_instance.postgres' <<<"$state_list"; then
    state_tracks_rds=true
  fi

  if [[ "$state_tracks_cluster" == "false" ]] && AWS_PROFILE="$terraform_aws_profile" aws eks describe-cluster --name "$cluster_name" --region "${AWS_REGION:-ap-southeast-1}" >/dev/null 2>&1; then
    echo "Refusing apply: EKS cluster '$cluster_name' exists in AWS but is not tracked in sequential Terraform state." >&2
    echo "Import or destroy the orphaned resource before applying to avoid duplicate-name drift." >&2
    exit 1
  fi

  if [[ "$state_tracks_rds" == "false" ]] && AWS_PROFILE="$terraform_aws_profile" aws rds describe-db-instances --db-instance-identifier "$rds_identifier" --region "${AWS_REGION:-ap-southeast-1}" >/dev/null 2>&1; then
    echo "Refusing apply: RDS instance '$rds_identifier' exists in AWS but is not tracked in sequential Terraform state." >&2
    echo "Import or destroy the orphaned resource before applying to avoid duplicate-name drift." >&2
    exit 1
  fi
fi

if [[ "$terraform_command" == "destroy" ]]; then
  : "${S3_BENCHMARK_DATA_VERIFIED:?Refusing destroy. Verify benchmark data exists in S3, then rerun with S3_BENCHMARK_DATA_VERIFIED=true}"
  if [[ "$S3_BENCHMARK_DATA_VERIFIED" != "true" ]]; then
    echo "S3_BENCHMARK_DATA_VERIFIED must be true to run terraform destroy" >&2
    exit 1
  fi
fi

AWS_PROFILE="$terraform_aws_profile" \
TF_VAR_db_password="${DB_PASSWORD:-}" \
TF_VAR_sequential_cluster_name="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}" \
terraform -chdir="$tf_dir" "$@"
