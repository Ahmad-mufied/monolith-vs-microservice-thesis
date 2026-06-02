#!/usr/bin/env bash

warn_legacy_env_file() {
  local legacy_path="$1"
  local preferred_path="$2"
  local label="$3"

  echo "WARN: using legacy ${label} file '${legacy_path}'; migrate to '${preferred_path}' via make env-init-app" >&2
}

resolve_env_file() {
  local preferred_path="$1"
  local legacy_path="$2"
  local label="$3"

  if [[ -f "$preferred_path" ]]; then
    printf '%s\n' "$preferred_path"
    return 0
  fi

  if [[ -f "$legacy_path" ]]; then
    warn_legacy_env_file "$legacy_path" "$preferred_path" "$label"
    printf '%s\n' "$legacy_path"
    return 0
  fi

  return 1
}

read_env_value_from_file() {
  local file="$1"
  local key="$2"

  grep -E "^${key}=" "$file" | head -n 1 | cut -d= -f2- || true
}

resolve_app_env_file() {
  local service="$1"

  case "$service" in
    monolith)
      resolve_env_file "env/monolith.app.env" "env/monolith.eks.env" "monolith app env"
      ;;
    api-gateway)
      resolve_env_file "env/api-gateway.app.env" "env/api-gateway.eks.env" "api-gateway app env"
      ;;
    auth-service)
      resolve_env_file "env/auth-service.app.env" "env/auth-service.eks.env" "auth-service app env"
      ;;
    item-service)
      resolve_env_file "env/item-service.app.env" "env/item-service.eks.env" "item-service app env"
      ;;
    transaction-service)
      resolve_env_file "env/transaction-service.app.env" "env/transaction-service.eks.env" "transaction-service app env"
      ;;
    k6-runner)
      resolve_env_file "env/k6-runner.app.env" "env/k6-runner.eks.env" "k6-runner app env"
      ;;
    *)
      echo "unknown app env service '$service'" >&2
      return 1
      ;;
  esac
}

resolve_datadog_env_file() {
  resolve_env_file "env/datadog.shared.env" "env/datadog.eks.env" "Datadog shared env"
}

resolve_image_tag_env_file() {
  resolve_env_file "env/image-tag.env" "env/image-tag.eks.env" "shared image tag env"
}
