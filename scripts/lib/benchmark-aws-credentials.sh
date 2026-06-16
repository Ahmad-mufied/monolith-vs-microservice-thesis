#!/usr/bin/env bash

BENCHMARK_AWS_ENV_PREPARED_FOR=""

benchmark_aws_provider() {
  printf '%s' "${CLOUD_PROVIDER:-aws}"
}

benchmark_aws_auth_label() {
  case "$(benchmark_aws_provider)" in
    aws)
      printf 'AWS session'
      ;;
    vultr)
      printf 'Vultr AWS S3 writer credentials'
      ;;
    *)
      printf 'AWS credentials'
      ;;
  esac
}

benchmark_aws_auth_fix_hint() {
  case "$(benchmark_aws_provider)" in
    aws)
      printf "%s" "refresh AWS auth first, for example with 'aws login' or 'aws sso login --profile <profile>'."
      ;;
    vultr)
      printf "%s" "run 'make aws-s3-writer-apply' if the writer is missing, or set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for Vultr benchmarking before retrying."
      ;;
    *)
      printf "%s" "configure valid AWS credentials for the active benchmark provider before retrying."
      ;;
  esac
}

prepare_benchmark_aws_env() {
  local provider

  provider="$(benchmark_aws_provider)"
  if [[ "$BENCHMARK_AWS_ENV_PREPARED_FOR" = "$provider" ]]; then
    return 0
  fi

  case "$provider" in
    aws)
      BENCHMARK_AWS_ENV_PREPARED_FOR="$provider"
      return 0
      ;;
    vultr)
      source scripts/lib/vultr-s3-credentials.sh
      load_vultr_s3_credentials || return 1
      export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
      BENCHMARK_AWS_ENV_PREPARED_FOR="$provider"
      return 0
      ;;
    *)
      echo "ERROR: unsupported CLOUD_PROVIDER '$provider' for benchmark AWS operations" >&2
      return 1
      ;;
  esac
}

benchmark_aws() {
  prepare_benchmark_aws_env || return 1

  local max_attempts=10
  local attempt=1
  local delay=3
  local exit_code=0
  local stderr_tmp
  stderr_tmp="$(mktemp)"

  while [ $attempt -le $max_attempts ]; do
    exit_code=0
    aws "$@" 2>"$stderr_tmp" || exit_code=$?

    if [ $exit_code -eq 0 ]; then
      rm -f "$stderr_tmp"
      return 0
    fi

    local stderr_content
    stderr_content="$(cat "$stderr_tmp")"
    echo "$stderr_content" >&2

    # Check if the error is a transient network/connection issue
    if [[ "$stderr_content" =~ "Could not connect to the endpoint URL" ]] || \
       [[ "$stderr_content" =~ "lookup" ]] || \
       [[ "$stderr_content" =~ "connection refused" ]] || \
       [[ "$stderr_content" =~ "Connection timeout" ]] || \
       [[ "$stderr_content" =~ "EOF" ]]; then
      
      if [ $attempt -lt $max_attempts ]; then
        echo "WARNING: Transient AWS CLI failure detected (exit code: $exit_code). Retrying in ${delay}s (Attempt ${attempt}/${max_attempts})..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        continue
      fi
    fi

    rm -f "$stderr_tmp"
    return $exit_code
  done
}
