#!/usr/bin/env bash

benchmark_preflight_check() {
  local s3_bucket="$1"
  local context_label="${2:-benchmark preflight}"
  local quiet="${3:-false}"
  local aws_error_file
  local s3_error_file
  local mono_error_file
  local msa_error_file

  aws_error_file="$(mktemp)"
  s3_error_file="$(mktemp)"
  mono_error_file="$(mktemp)"
  msa_error_file="$(mktemp)"

  cleanup_benchmark_preflight_files() {
    rm -f "$aws_error_file" "$s3_error_file" "$mono_error_file" "$msa_error_file"
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

  if ! kubectl --context=monolith get nodes >/dev/null 2>"$mono_error_file"; then
    echo "ERROR: kubectl context 'monolith' is not ready for ${context_label}." >&2
    cat "$mono_error_file" >&2
    echo "Fix: refresh the EKS credential path and verify 'kubectl --context=monolith get nodes' succeeds." >&2
    cleanup_benchmark_preflight_files
    return 1
  fi

  if ! kubectl --context=msa get nodes >/dev/null 2>"$msa_error_file"; then
    echo "ERROR: kubectl context 'msa' is not ready for ${context_label}." >&2
    cat "$msa_error_file" >&2
    echo "Fix: refresh the EKS credential path and verify 'kubectl --context=msa get nodes' succeeds." >&2
    cleanup_benchmark_preflight_files
    return 1
  fi

  if [ "$quiet" != "true" ]; then
    echo "  aws_session  : ok"
    echo "  s3_access    : ok"
    echo "  monolith_ctx : ok"
    echo "  msa_ctx      : ok"
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
