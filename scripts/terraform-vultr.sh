#!/usr/bin/env bash
set -euo pipefail

env_file="env/vultr.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init PLATFORM=vultr EXECUTION_MODE=<parallel|sequential>" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${VULTR_API_KEY:?VULTR_API_KEY must be set in env/vultr.env}"
export VULTR_API_KEY

terraform_dir="infra/terraform/vultr"

terraform_command="${1:-}"
if [[ "$terraform_command" != "output" ]]; then
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/vultr.env}"
  export TF_VAR_postgres_password="$POSTGRES_PASSWORD"
fi

if [[ "$terraform_command" == "destroy" ]]; then
  : "${S3_BENCHMARK_DATA_VERIFIED:?Refusing destroy. Verify benchmark data exists in S3, then rerun with S3_BENCHMARK_DATA_VERIFIED=true}"
  if [[ "$S3_BENCHMARK_DATA_VERIFIED" != "true" ]]; then
    echo "S3_BENCHMARK_DATA_VERIFIED must be true to run Vultr terraform destroy" >&2
    exit 1
  fi
fi

echo "=== Vultr Terraform ==="
echo "  dir   : $terraform_dir"
echo ""

terraform -chdir="$terraform_dir" "$@"
