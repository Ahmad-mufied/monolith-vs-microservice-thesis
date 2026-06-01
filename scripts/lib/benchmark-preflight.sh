#!/usr/bin/env bash

benchmark_preflight_check() {
  local s3_bucket="$1"
  local context_label="${2:-benchmark preflight}"
  local quiet="${3:-false}"
  local aws_error_file
  local s3_error_file
  local context_error_file
  local contexts="${BENCHMARK_PREFLIGHT_CONTEXTS:-monolith msa}"
  local context

  aws_error_file="$(mktemp)"
  s3_error_file="$(mktemp)"
  context_error_file="$(mktemp)"

  cleanup_benchmark_preflight_files() {
    rm -f "$aws_error_file" "$s3_error_file" "$context_error_file"
  }

  if [ "$quiet" != "true" ]; then
    echo "=== Benchmark Preflight ==="
    echo "  phase        : $context_label"
    echo "  s3_bucket    : $s3_bucket"
  fi

  if ! aws sts get-caller-identity >/dev/null 2>"$aws_error_file"; then
    echo "ERROR: AWS session is not valid for ${context_label}." >&2
    cat "$aws_error_file" >&2
    echo "Fix: refresh AWS auth first, for example with 'aws login' or 'aws sso login --profile <profile>'." >&2
    cleanup_benchmark_preflight_files
    return 1
  fi

  if ! aws s3api head-bucket --bucket "$s3_bucket" >/dev/null 2>"$s3_error_file"; then
    echo "ERROR: S3 access check failed for bucket '${s3_bucket}' during ${context_label}." >&2
    cat "$s3_error_file" >&2
    echo "Fix: confirm the benchmark bucket exists and the current AWS session can read it before continuing." >&2
    cleanup_benchmark_preflight_files
    return 1
  fi

  for context in $contexts; do
    : > "$context_error_file"
    if ! kubectl --context="$context" get nodes >/dev/null 2>"$context_error_file"; then
      echo "ERROR: kubectl context '${context}' is not ready for ${context_label}." >&2
      cat "$context_error_file" >&2
      echo "Fix: refresh the Kubernetes credential path for the active provider and verify 'kubectl --context=${context} get nodes' succeeds." >&2
      cleanup_benchmark_preflight_files
      return 1
    fi
  done

  if [ "$quiet" != "true" ]; then
    echo "  aws_session  : ok"
    echo "  s3_access    : ok"
    echo "  contexts     : ${contexts}"
    echo ""
  fi

  cleanup_benchmark_preflight_files
  return 0
}

benchmark_preflight_or_die() {
  local s3_bucket="$1"
  local context_label="${2:-benchmark preflight}"
  local quiet="${3:-false}"

  benchmark_preflight_check "$s3_bucket" "$context_label" "$quiet" || exit 1
}
