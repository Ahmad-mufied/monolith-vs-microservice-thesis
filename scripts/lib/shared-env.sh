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

# Robust kubectl wrapper with retries for transient connection/DNS issues
kubectl() {
  local max_attempts=3
  local attempt=1
  local delay=3
  local exit_code=0

  # We use a temporary file to capture stderr so we can inspect it and print it correctly
  local stderr_tmp
  stderr_tmp="$(mktemp)"

  while [ $attempt -le $max_attempts ]; do
    # Run the real kubectl command, redirecting stderr to a temp file, preserving stdout
    command kubectl "$@" 2>"$stderr_tmp"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
      cat "$stderr_tmp" >&2
      rm -f "$stderr_tmp"
      return 0
    fi

    # Inspect stderr for transient network/DNS issues
    local stderr_content
    stderr_content="$(cat "$stderr_tmp")"
    
    # We always print the stderr to the actual stderr
    echo "$stderr_content" >&2

    # Check if the error is a transient/connection issue
    if [[ "$stderr_content" =~ "dial tcp" ]] || \
       [[ "$stderr_content" =~ "lookup" ]] || \
       [[ "$stderr_content" =~ "connection refused" ]] || \
       [[ "$stderr_content" =~ "timeout" ]] || \
       [[ "$stderr_content" =~ "EOF" ]]; then
      
      if [ $attempt -lt $max_attempts ]; then
        echo "WARNING: Transient kubectl failure detected (exit code: $exit_code). Retrying in ${delay}s (Attempt ${attempt}/${max_attempts})..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        continue
      fi
    fi

    # For other errors or if we exhausted attempts, clean up and exit
    rm -f "$stderr_tmp"
    return $exit_code
  done
}
export -f kubectl
