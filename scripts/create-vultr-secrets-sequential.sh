#!/usr/bin/env bash
set -euo pipefail

context="${VULTR_CONTEXT:-benchmark}"
export VULTR_CONTEXT="$context"

err_file="$(mktemp)"
if ! postgres_ip="$(terraform -chdir=infra/terraform/vultr-experiment-sequential output -raw postgres_private_ip 2>"$err_file")"; then
  echo "ERROR: failed to read sequential PostgreSQL private IP from Terraform output 'postgres_private_ip'" >&2
  sed 's/^/  terraform: /' "$err_file" >&2
  rm -f "$err_file"
  exit 1
fi
rm -f "$err_file"

if [ -z "$postgres_ip" ]; then
  echo "ERROR: Terraform output 'postgres_private_ip' for sequential PostgreSQL private IP is empty" >&2
  exit 1
fi

export VULTR_SEQUENTIAL_POSTGRES_IP="$postgres_ip"

bash scripts/create-vultr-secrets-monolith.sh
bash scripts/create-vultr-secrets-microservices.sh

echo "Vultr sequential secrets created in context: $context"
