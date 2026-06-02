#!/usr/bin/env bash
set -euo pipefail

stack="${VULTR_TERRAFORM_STACK:-${1:-}}"
if [ -z "${VULTR_TERRAFORM_STACK:-}" ] && [ "$#" -gt 0 ]; then
  shift
fi

case "$stack" in
  shared|sequential|parallel) ;;
  *)
    echo "usage: VULTR_TERRAFORM_STACK=<shared|sequential|parallel> $0 [terraform args...]" >&2
    echo "or: $0 <shared|sequential|parallel> [terraform args...]" >&2
    exit 1
    ;;
esac

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

terraform_dir="infra/terraform/vultr-${stack}"
if [ "$stack" = "sequential" ]; then
  terraform_dir="infra/terraform/vultr-sequential"
elif [ "$stack" = "parallel" ]; then
  terraform_dir="infra/terraform/vultr-parallel"
fi

terraform_command="${1:-}"
if [[ "$terraform_command" != "output" && "$stack" != "shared" ]]; then
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
echo "  stack : $stack"
echo "  dir   : $terraform_dir"
echo ""

terraform -chdir="$terraform_dir" "$@"
