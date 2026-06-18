#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

source scripts/lib/shared-env.sh

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

# 1. Initialize postgres.env if missing
if [[ ! -f env/postgres.env ]]; then
  echo "Initializing base postgres.env first..."
  bash scripts/env-init-base.sh
fi

postgres_password="$(grep -E '^POSTGRES_PASSWORD=' env/postgres.env | cut -d= -f2- || true)"
if [[ -z "$postgres_password" ]]; then
  echo "ERROR: POSTGRES_PASSWORD not found in env/postgres.env" >&2
  exit 1
fi

# 2. Copy values.yaml.template to values.yaml if missing
if [[ ! -f env/values.yaml ]]; then
  cp env/values.yaml.template env/values.yaml
  chmod 600 env/values.yaml
  echo "Created env/values.yaml from template"
fi

# 3. Migration Helper from old .env files (runs only if values are placeholders/empty)
migrate_value_to_yaml() {
  local env_file="$1"
  local env_key="$2"
  local yaml_path="$3"

  if [[ -f "$env_file" ]]; then
    local val
    val="$(grep -E "^${env_key}=" "$env_file" | head -n 1 | cut -d= -f2- || true)"
    if [[ -n "$val" ]]; then
      local current_yaml_val
      current_yaml_val="$(read_yaml_value "$yaml_path" "env/values.yaml" || true)"
      if [[ -z "$current_yaml_val" || "$current_yaml_val" == "PLACEHOLDER_"* || "$current_yaml_val" == "replace-me" ]]; then
        # Check if it's boolean/number or string to write correctly
        if [[ "$val" =~ ^(true|false|[0-9]+)$ ]]; then
          yq -i "${yaml_path} = $val" env/values.yaml
        else
          yq -i "${yaml_path} = \"$val\"" env/values.yaml
        fi
        echo "Migrated $env_key from $env_file to $yaml_path"
      fi
    fi
  fi
}

# Migrate old app envs to cluster profile
migrate_value_to_yaml "env/monolith.app.env" "JWT_SECRET" ".cluster.monolith.JWT_SECRET"
migrate_value_to_yaml "env/api-gateway.app.env" "JWT_SECRET" ".cluster.microservices.api-gateway.JWT_SECRET"
migrate_value_to_yaml "env/auth-service.app.env" "JWT_SECRET" ".cluster.microservices.auth-service.JWT_SECRET"
migrate_value_to_yaml "env/datadog.shared.env" "DATADOG_API_KEY" ".shared.datadog.DATADOG_API_KEY"
migrate_value_to_yaml "env/datadog.shared.env" "DATADOG_SITE" ".shared.datadog.DATADOG_SITE"
migrate_value_to_yaml "env/k6-runner.app.env" "ADMIN_USER_EMAIL" ".shared.k6-runner.ADMIN_USER_EMAIL"
migrate_value_to_yaml "env/k6-runner.app.env" "ADMIN_USER_PASSWORD" ".shared.k6-runner.ADMIN_USER_PASSWORD"

# Migrate old local envs to local profile
migrate_value_to_yaml "env/monolith.env" "JWT_SECRET" ".local.monolith.JWT_SECRET"
migrate_value_to_yaml "env/api-gateway.env" "JWT_SECRET" ".local.microservices.api-gateway.JWT_SECRET"
migrate_value_to_yaml "env/auth-service.env" "JWT_SECRET" ".local.microservices.auth-service.JWT_SECRET"

# 4. Resolve / Generate fallback secrets
# JWT_SECRET
current_jwt="$(read_yaml_value ".cluster.monolith.JWT_SECRET" || true)"
if [[ -z "$current_jwt" || "$current_jwt" == "PLACEHOLDER_JWT_SECRET" ]]; then
  generated_jwt="$(random_hex 32)"
  # Replace PLACEHOLDER_JWT_SECRET everywhere recursively
  yq -i "(.. | select(. == \"PLACEHOLDER_JWT_SECRET\")) = \"$generated_jwt\"" env/values.yaml
  echo "Generated and injected new JWT_SECRET"
fi

# k6 Runner Password
current_k6_pwd="$(read_yaml_value ".shared.k6-runner.ADMIN_USER_PASSWORD" || true)"
if [[ -z "$current_k6_pwd" || "$current_k6_pwd" == "PLACEHOLDER_ADMIN_PASSWORD" ]]; then
  generated_k6_pwd="Password123!"
  yq -i ".shared.k6-runner.ADMIN_USER_PASSWORD = \"$generated_k6_pwd\"" env/values.yaml
  echo "Generated and injected default k6 runner admin password"
fi

# 5. Inject POSTGRES_PASSWORD into local/compose URLs if they still contain placeholders
yq -i ".local.monolith.DATABASE_URL = (.local.monolith.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.monolith.MONO_DATABASE_URL = (.local.monolith.MONO_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.auth-service.DATABASE_URL = (.local.microservices.auth-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.auth-service.AUTH_DATABASE_URL = (.local.microservices.auth-service.AUTH_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.item-service.DATABASE_URL = (.local.microservices.item-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.item-service.ITEM_DATABASE_URL = (.local.microservices.item-service.ITEM_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.transaction-service.DATABASE_URL = (.local.microservices.transaction-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".local.microservices.transaction-service.TRANSACTION_DATABASE_URL = (.local.microservices.transaction-service.TRANSACTION_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml

yq -i ".compose.microservices.auth-service.DATABASE_URL = (.compose.microservices.auth-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".compose.microservices.auth-service.AUTH_DATABASE_URL = (.compose.microservices.auth-service.AUTH_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".compose.microservices.item-service.DATABASE_URL = (.compose.microservices.item-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".compose.microservices.item-service.ITEM_DATABASE_URL = (.compose.microservices.item-service.ITEM_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".compose.microservices.transaction-service.DATABASE_URL = (.compose.microservices.transaction-service.DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml
yq -i ".compose.microservices.transaction-service.TRANSACTION_DATABASE_URL = (.compose.microservices.transaction-service.TRANSACTION_DATABASE_URL | sub(\"PLACEHOLDER_POSTGRES_PASSWORD\", \"$postgres_password\"))" env/values.yaml

# 6. Generate flat .env files for local/compose tool compatibility
generate_env_from_yaml ".shared.datadog" "env/datadog.shared.env"
generate_env_from_yaml ".shared.k6-runner" "env/k6-runner.app.env"
generate_env_from_yaml ".cluster.monolith" "env/monolith.app.env"
generate_env_from_yaml ".cluster.microservices.api-gateway" "env/api-gateway.app.env"
generate_env_from_yaml ".cluster.microservices.auth-service" "env/auth-service.app.env"
generate_env_from_yaml ".cluster.microservices.item-service" "env/item-service.app.env"
generate_env_from_yaml ".cluster.microservices.transaction-service" "env/transaction-service.app.env"

echo "App env initialization complete"
