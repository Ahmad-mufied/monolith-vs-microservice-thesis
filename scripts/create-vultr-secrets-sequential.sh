#!/usr/bin/env bash
set -euo pipefail

context="${VULTR_CONTEXT:-benchmark}"
export VULTR_CONTEXT="$context"

postgres_ip="$(terraform -chdir=infra/terraform/vultr-experiment-sequential output -raw postgres_private_ip)"
export VULTR_SEQUENTIAL_POSTGRES_IP="$postgres_ip"

bash scripts/create-vultr-secrets-monolith.sh
bash scripts/create-vultr-secrets-microservices.sh

echo "Vultr sequential secrets created in context: $context"
