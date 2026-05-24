#!/usr/bin/env bash
set -euo pipefail

env_file="env/terraform.experiment.env"
terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
terraform_command="${1:-}"

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

AWS_PROFILE="$terraform_aws_profile" \
TF_VAR_db_password="${DB_PASSWORD:-}" \
terraform -chdir=infra/terraform/experiment "$@"
