#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

source scripts/lib/shared-env.sh

# 1. Make sure app env has been initialized
if [[ ! -f env/values.yaml ]]; then
  echo "values.yaml not found, running env-init-app first..."
  bash scripts/env-init-app.sh
fi

if [[ ! -f env/postgres.env ]]; then
  echo "missing env/postgres.env; run: make env-init-base" >&2
  exit 1
fi

# 2. Generate local microservices env files from values.yaml
generate_env_from_yaml ".local.microservices.api-gateway" "env/api-gateway.env"
generate_env_from_yaml ".local.microservices.auth-service" "env/auth-service.env"
generate_env_from_yaml ".local.microservices.item-service" "env/item-service.env"
generate_env_from_yaml ".local.microservices.transaction-service" "env/transaction-service.env"

# 3. Generate Docker Compose env files from values.yaml
generate_env_from_yaml ".compose.microservices.api-gateway" "env/api-gateway.compose.env"
generate_env_from_yaml ".compose.microservices.auth-service" "env/auth-service.compose.env"
generate_env_from_yaml ".compose.microservices.item-service" "env/item-service.compose.env"
generate_env_from_yaml ".compose.microservices.transaction-service" "env/transaction-service.compose.env"

echo "local microservices env initialization complete"
