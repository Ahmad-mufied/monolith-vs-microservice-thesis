#!/usr/bin/env bash

load_vultr_s3_credentials() {
  local writer_dir="${TERRAFORM_AWS_S3_WRITER_DIR:-infra/terraform/aws-s3-writer}"
  local access_key_id="${AWS_ACCESS_KEY_ID:-}"
  local secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"

  if [[ -n "$access_key_id" && -n "$secret_access_key" ]]; then
    return 0
  fi

  if [[ -n "$access_key_id" || -n "$secret_access_key" ]]; then
    echo "WARN: ignoring incomplete Vultr AWS S3 writer credential pair from env; loading both values from Terraform." >&2
    access_key_id=""
    secret_access_key=""
  fi

  if command -v terraform >/dev/null 2>&1 && [[ -d "$writer_dir" ]]; then
    access_key_id="$(terraform -chdir="$writer_dir" output -raw vultr_k6_s3_access_key_id 2>/dev/null || true)"
    secret_access_key="$(terraform -chdir="$writer_dir" output -raw vultr_k6_s3_secret_access_key 2>/dev/null || true)"
  fi

  if [[ -z "$access_key_id" || -z "$secret_access_key" ]]; then
    echo "ERROR: Vultr k6 S3 writer credentials are unavailable." >&2
    echo "Fix: run 'make aws-s3-writer-apply' or set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in env/vultr.env." >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
}
