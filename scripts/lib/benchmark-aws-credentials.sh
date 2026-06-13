#!/usr/bin/env bash

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
  case "$provider" in
    aws)
      return 0
      ;;
    vultr)
      source scripts/lib/vultr-s3-credentials.sh
      load_vultr_s3_credentials
      export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
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
  aws "$@"
}
