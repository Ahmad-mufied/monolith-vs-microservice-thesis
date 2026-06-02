#!/usr/bin/env bash
set -euo pipefail

stack="${HETZNER_TERRAFORM_STACK:-${1:-}}"
if [ -z "${HETZNER_TERRAFORM_STACK:-}" ] && [ "$#" -gt 0 ]; then
  shift
fi

case "$stack" in
  shared|sequential|parallel) ;;
  *)
    echo "usage: HETZNER_TERRAFORM_STACK=<shared|sequential|parallel> $0 [terraform args...]" >&2
    echo "or: $0 <shared|sequential|parallel> [terraform args...]" >&2
    exit 1
    ;;
esac

env_file="env/hetzner.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init PLATFORM=hetzner EXECUTION_MODE=<parallel|sequential>" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN must be set in env/hetzner.env}"

terraform_dir="infra/terraform/hetzner-${stack}"
if [ "$stack" = "sequential" ]; then
  terraform_dir="infra/terraform/hetzner-sequential"
elif [ "$stack" = "parallel" ]; then
  terraform_dir="infra/terraform/hetzner-parallel"
fi

terraform_command="${1:-}"
if [[ "$terraform_command" != "output" && "$stack" != "shared" ]]; then
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in env/hetzner.env}"
  export TF_VAR_postgres_password="$POSTGRES_PASSWORD"
fi

if [[ "$terraform_command" == "destroy" ]]; then
  : "${S3_BENCHMARK_DATA_VERIFIED:?Refusing destroy. Verify benchmark data exists in S3, then rerun with S3_BENCHMARK_DATA_VERIFIED=true}"
  if [[ "$S3_BENCHMARK_DATA_VERIFIED" != "true" ]]; then
    echo "S3_BENCHMARK_DATA_VERIFIED must be true to run Hetzner terraform destroy" >&2
    exit 1
  fi
fi

echo "=== Hetzner Terraform ==="
echo "  stack : $stack"
echo "  dir   : $terraform_dir"
echo ""

terraform -chdir="$terraform_dir" "$@"
