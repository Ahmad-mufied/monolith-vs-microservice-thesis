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

parse_seconds_duration() {
  local value="$1"

  if [[ "$value" =~ ^([0-9]+)s$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

parse_benchmark_duration_seconds() {
  local value="$1"
  local number unit

  if [[ "$value" =~ ^([0-9]+)(ms|s|m|h)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      ms)
        printf '0\n'
        ;;
      s)
        printf '%s\n' "$number"
        ;;
      m)
        printf '%s\n' "$((number * 60))"
        ;;
      h)
        printf '%s\n' "$((number * 3600))"
        ;;
    esac
    return 0
  fi

  return 1
}

format_benchmark_duration_seconds() {
  local total_seconds="$1"
  local hours minutes seconds result=""

  if ! [[ "$total_seconds" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  hours=$((total_seconds / 3600))
  minutes=$(((total_seconds % 3600) / 60))
  seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    result="${hours}h"
  fi
  if [ "$minutes" -gt 0 ]; then
    result="${result}${minutes}m"
  fi
  if [ "$seconds" -gt 0 ] || [ -z "$result" ]; then
    result="${result}${seconds}s"
  fi

  printf '%s\n' "$result"
}

benchmark_effective_duration_seconds() {
  local profile="$1"
  local test_duration="$2"
  local total_seconds=0
  local component

  case "$profile" in
    smoke|steady)
      parse_benchmark_duration_seconds "$test_duration"
      ;;
    ramp)
      for component in "${RAMP_UP_DURATION:-1m}" "$test_duration" "${RAMP_DOWN_DURATION:-30s}"; do
        total_seconds=$((total_seconds + $(parse_benchmark_duration_seconds "$component")))
      done
      printf '%s\n' "$total_seconds"
      ;;
    hpa)
      for component in "${HPA_RAMP_UP_1:-2m}" "${HPA_RAMP_UP_2:-2m}" "${HPA_RAMP_UP_3:-3m}" "${HPA_HOLD:-5m}" "${HPA_RAMP_DOWN:-1m}"; do
        total_seconds=$((total_seconds + $(parse_benchmark_duration_seconds "$component")))
      done
      printf '%s\n' "$total_seconds"
      ;;
    *)
      parse_benchmark_duration_seconds "$test_duration"
      ;;
  esac
}

benchmark_duration_log_value() {
  local profile="$1"
  local test_duration="$2"
  local effective_seconds effective_duration

  case "$profile" in
    hpa)
      effective_seconds="$(benchmark_effective_duration_seconds "$profile" "$test_duration")" || {
        printf '%s\n' "$test_duration"
        return 0
      }
      effective_duration="$(format_benchmark_duration_seconds "$effective_seconds")" || {
        printf '%s\n' "$test_duration"
        return 0
      }
      printf '%s (HPA hold stage; effective total ~%s including ramp up/down)\n' "$test_duration" "$effective_duration"
      ;;
    ramp)
      effective_seconds="$(benchmark_effective_duration_seconds "$profile" "$test_duration")" || {
        printf '%s\n' "$test_duration"
        return 0
      }
      effective_duration="$(format_benchmark_duration_seconds "$effective_seconds")" || {
        printf '%s\n' "$test_duration"
        return 0
      }
      printf '%s (steady hold stage; effective total ~%s including ramp up/down)\n' "$test_duration" "$effective_duration"
      ;;
    *)
      printf '%s\n' "$test_duration"
      ;;
  esac
}

read_secret_value_from_cluster() {
  local context="$1"
  local namespace="$2"
  local secret_name="$3"
  local key="$4"
  local encoded

  if [[ -z "$context" || -z "$namespace" || -z "$secret_name" || -z "$key" ]]; then
    return 1
  fi

  if ! encoded="$(kubectl --context="$context" get secret "$secret_name" -n "$namespace" -o go-template="{{ index .data \"$key\" }}" 2>/dev/null)"; then
    return 1
  fi
  if [[ -z "$encoded" ]]; then
    return 1
  fi

  printf '%s' "$encoded" | base64 -d
}

resolve_preserved_secret_value() {
  local explicit_value="$1"
  local context="$2"
  local namespace="$3"
  local secret_name="$4"
  local key="$5"
  local existing_value

  if [[ -n "$explicit_value" ]]; then
    printf '%s\n' "$explicit_value"
    return 0
  fi

  if existing_value="$(read_secret_value_from_cluster "$context" "$namespace" "$secret_name" "$key")"; then
    printf '%s\n' "$existing_value"
    return 0
  fi

  return 1
}

append_secret_pair() {
  local -n pairs_ref="$1"
  local key="$2"
  local value="$3"

  pairs_ref+=("$key" "$value")
}

append_secret_pair_if_set() {
  local -n pairs_ref="$1"
  local key="$2"
  local value="$3"

  if [[ -z "$value" ]]; then
    return 0
  fi

  pairs_ref+=("$key" "$value")
}

resolve_login_max_concurrency_for_mode() {
  local scaling_mode="${1:-fixed}"
  local fixed_value="$2"
  local hpa_value="$3"
  local fixed_default="$4"
  local hpa_default="$5"

  case "$scaling_mode" in
    hpa)
      if [[ -n "$hpa_value" ]]; then
        printf '%s\n' "$hpa_value"
      elif [[ -n "$fixed_value" ]]; then
        printf '%s\n' "$fixed_value"
      else
        printf '%s\n' "$hpa_default"
      fi
      ;;
    *)
      if [[ -n "$fixed_value" ]]; then
        printf '%s\n' "$fixed_value"
      else
        printf '%s\n' "$fixed_default"
      fi
      ;;
  esac
}

append_secret_pair_if_override() {
  local -n pairs_ref="$1"
  local key="$2"
  local value="$3"
  local default_value="$4"

  if [[ -z "$value" || "$value" == "$default_value" ]]; then
    return 0
  fi

  pairs_ref+=("$key" "$value")
}

apply_secret_from_pairs() {
  local context="$1"
  local namespace="$2"
  local secret_name="$3"
  shift 3

  if (( $# == 0 )) || (( $# % 2 != 0 )); then
    echo "apply_secret_from_pairs requires key/value pairs for ${namespace}/${secret_name}" >&2
    return 1
  fi

  local temp_env_file
  temp_env_file="$(mktemp)"
  chmod 600 "$temp_env_file"

  while (( $# > 0 )); do
    printf '%s=%s\n' "$1" "$2" >> "$temp_env_file"
    shift 2
  done

  kubectl --context="$context" create secret generic "$secret_name" \
    --namespace "$namespace" \
    --from-env-file="$temp_env_file" \
    --dry-run=client -o yaml | kubectl --context="$context" apply -f -

  rm -f "$temp_env_file"
}

normalize_http_write_timeout() {
  local value="$1"
  local fallback="${2:-40s}"

  # Reconcile managed HTTP write timeout values to the current runtime policy.

  case "$value" in
    ""|"30s"|"35s")
      printf '%s\n' "$fallback"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

derive_gateway_request_timeout() {
  local explicit_timeout="$1"
  local http_write_timeout="$2"
  local grpc_call_timeout="$3"
  local write_seconds grpc_seconds candidate_seconds minimum_seconds

  if [[ -n "$explicit_timeout" ]]; then
    printf '%s\n' "$explicit_timeout"
    return 0
  fi

  if ! write_seconds="$(parse_seconds_duration "$http_write_timeout")"; then
    printf '35s\n'
    return 0
  fi

  if ! grpc_seconds="$(parse_seconds_duration "$grpc_call_timeout")"; then
    printf '35s\n'
    return 0
  fi

  candidate_seconds=$((write_seconds - 5))
  minimum_seconds=$((grpc_seconds + 1))
  if (( candidate_seconds < minimum_seconds )); then
    candidate_seconds=$minimum_seconds
  fi

  if (( candidate_seconds >= write_seconds )); then
    printf '35s\n'
    return 0
  fi

  printf '%ss\n' "$candidate_seconds"
}

derive_app_request_timeout() {
  local explicit_timeout="$1"
  local http_write_timeout="$2"
  local write_seconds

  if [[ -n "$explicit_timeout" ]]; then
    printf '%s\n' "$explicit_timeout"
    return 0
  fi

  if ! write_seconds="$(parse_seconds_duration "$http_write_timeout")"; then
    printf '35s\n'
    return 0
  fi

  if (( write_seconds <= 1 )); then
    printf '35s\n'
    return 0
  fi

  if (( write_seconds <= 5 )); then
    printf '%ss\n' "$((write_seconds - 1))"
    return 0
  fi

  printf '%ss\n' "$((write_seconds - 5))"
}

derive_item_validation_timeout() {
  local explicit_timeout="$1"
  local grpc_request_timeout="$2"
  local grpc_seconds

  if [[ -n "$explicit_timeout" ]]; then
    printf '%s\n' "$explicit_timeout"
    return 0
  fi

  if ! grpc_seconds="$(parse_seconds_duration "$grpc_request_timeout")"; then
    printf '25s\n'
    return 0
  fi

  if (( grpc_seconds <= 1 )); then
    printf '0s\n'
    return 0
  fi

  if (( grpc_seconds <= 5 )); then
    printf '%ss\n' "$((grpc_seconds - 1))"
    return 0
  fi

  printf '%ss\n' "$((grpc_seconds - 5))"
}

validate_monolith_timeout_chain() {
  local app_request_timeout="$1"
  local http_write_timeout="$2"
  local app_seconds write_seconds

  if ! app_seconds="$(parse_seconds_duration "$app_request_timeout")"; then
    echo "ERROR: APP_REQUEST_TIMEOUT '$app_request_timeout' must be expressed in whole seconds (e.g. 35s)" >&2
    return 1
  fi
  if ! write_seconds="$(parse_seconds_duration "$http_write_timeout")"; then
    echo "ERROR: HTTP_WRITE_TIMEOUT '$http_write_timeout' must be expressed in whole seconds (e.g. 40s)" >&2
    return 1
  fi
  if (( app_seconds > write_seconds )); then
    echo "ERROR: APP_REQUEST_TIMEOUT (${app_request_timeout}) must not exceed HTTP_WRITE_TIMEOUT (${http_write_timeout})" >&2
    return 1
  fi
}

validate_gateway_timeout_chain() {
  local grpc_call_timeout="$1"
  local request_timeout="$2"
  local http_write_timeout="$3"
  local grpc_seconds request_seconds write_seconds

  if ! grpc_seconds="$(parse_seconds_duration "$grpc_call_timeout")"; then
    echo "ERROR: GRPC_CALL_TIMEOUT '$grpc_call_timeout' must be expressed in whole seconds (e.g. 32s)" >&2
    return 1
  fi
  if ! request_seconds="$(parse_seconds_duration "$request_timeout")"; then
    echo "ERROR: REQUEST_TIMEOUT '$request_timeout' must be expressed in whole seconds (e.g. 35s)" >&2
    return 1
  fi
  if ! write_seconds="$(parse_seconds_duration "$http_write_timeout")"; then
    echo "ERROR: HTTP_WRITE_TIMEOUT '$http_write_timeout' must be expressed in whole seconds (e.g. 40s)" >&2
    return 1
  fi
  if (( grpc_seconds >= request_seconds )); then
    echo "ERROR: GRPC_CALL_TIMEOUT (${grpc_call_timeout}) must be smaller than REQUEST_TIMEOUT (${request_timeout})" >&2
    return 1
  fi
  if (( request_seconds >= write_seconds )); then
    echo "ERROR: REQUEST_TIMEOUT (${request_timeout}) must be smaller than HTTP_WRITE_TIMEOUT (${http_write_timeout})" >&2
    return 1
  fi
}

validate_transaction_timeout_chain() {
  local grpc_request_timeout="$1"
  local item_validation_timeout="$2"
  local grpc_seconds item_seconds

  if ! grpc_seconds="$(parse_seconds_duration "$grpc_request_timeout")"; then
    echo "ERROR: GRPC_REQUEST_TIMEOUT '$grpc_request_timeout' must be expressed in whole seconds (e.g. 30s)" >&2
    return 1
  fi
  if ! item_seconds="$(parse_seconds_duration "$item_validation_timeout")"; then
    echo "ERROR: ITEM_VALIDATION_TIMEOUT '$item_validation_timeout' must be expressed in whole seconds (e.g. 25s)" >&2
    return 1
  fi
  if (( item_seconds >= grpc_seconds )); then
    echo "ERROR: ITEM_VALIDATION_TIMEOUT (${item_validation_timeout}) must be smaller than GRPC_REQUEST_TIMEOUT (${grpc_request_timeout})" >&2
    return 1
  fi
}

# Robust kubectl wrapper with retries for transient connection/DNS issues
kubectl() {
  local max_attempts=10
  local attempt=1
  local delay=3
  local exit_code=0

  # We use a temporary file to capture stderr so we can inspect it and print it correctly
  local stderr_tmp
  stderr_tmp="$(mktemp)"

  while [ $attempt -le $max_attempts ]; do
    exit_code=0
    command kubectl "$@" 2>"$stderr_tmp" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
      grep -v 'Unexpected error when reading response body.*request canceled.*while reading body' "$stderr_tmp" >&2 || true
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
