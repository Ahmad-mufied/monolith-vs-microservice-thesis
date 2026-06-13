#!/usr/bin/env bash

source scripts/lib/benchmark-aws-credentials.sh

benchmark_preflight_check() {
  local s3_bucket="$1"
  local context_label="${2:-benchmark preflight}"
  local quiet="${3:-false}"
  local aws_error_file
  local s3_error_file
  local context_error_file
  local contexts="${BENCHMARK_PREFLIGHT_CONTEXTS:-monolith msa}"
  local context
  local auth_label
  local auth_fix_hint

  aws_error_file="$(mktemp)"
  s3_error_file="$(mktemp)"
  context_error_file="$(mktemp)"
  auth_label="$(benchmark_aws_auth_label)"
  auth_fix_hint="$(benchmark_aws_auth_fix_hint)"

  cleanup_benchmark_preflight_files() {
    rm -f "$aws_error_file" "$s3_error_file" "$context_error_file"
  }

  if [ "$quiet" != "true" ]; then
    echo "=== Benchmark Preflight ==="
    echo "  phase        : $context_label"
    echo "  s3_bucket    : $s3_bucket"
  fi

  if ! benchmark_aws sts get-caller-identity >/dev/null 2>"$aws_error_file"; then
    echo "ERROR: ${auth_label} is not valid for ${context_label}." >&2
    cat "$aws_error_file" >&2
    echo "Fix: ${auth_fix_hint}" >&2
    cleanup_benchmark_preflight_files
    return 1
  fi

  if ! benchmark_aws s3api list-objects-v2 --bucket "$s3_bucket" --prefix "experiments/" --max-items 1 >/dev/null 2>"$s3_error_file"; then
    echo "ERROR: S3 access check failed for bucket '${s3_bucket}' during ${context_label}." >&2
    cat "$s3_error_file" >&2
    echo "Fix: confirm the benchmark bucket exists and the active benchmark credentials can read it before continuing." >&2
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
    echo "  aws_auth     : ok (${auth_label})"
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
