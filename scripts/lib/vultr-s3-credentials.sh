#!/usr/bin/env bash

load_vultr_s3_credentials() {
  local writer_dir="${TERRAFORM_AWS_S3_WRITER_DIR:-infra/terraform/aws-s3-writer}"
  local env_access_key_id="${AWS_ACCESS_KEY_ID:-}"
  local env_secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"
  local env_session_token="${AWS_SESSION_TOKEN:-}"
  local access_key_id=""
  local secret_access_key=""
  local session_token=""

  if command -v terraform >/dev/null 2>&1 && [[ -d "$writer_dir" ]]; then
    access_key_id="$(terraform -chdir="$writer_dir" output -raw vultr_k6_s3_access_key_id 2>/dev/null || true)"
    secret_access_key="$(terraform -chdir="$writer_dir" output -raw vultr_k6_s3_secret_access_key 2>/dev/null || true)"
  fi

  if [[ -z "$access_key_id" || -z "$secret_access_key" ]]; then
    if [[ -n "$env_access_key_id" && -n "$env_secret_access_key" ]]; then
      access_key_id="$env_access_key_id"
      secret_access_key="$env_secret_access_key"
      session_token="$env_session_token"
    elif [[ -n "$env_access_key_id" || -n "$env_secret_access_key" ]]; then
      echo "ERROR: incomplete Vultr AWS credential pair in env; set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY or restore the Terraform aws-s3-writer output." >&2
      return 1
    elif [[ -n "$env_session_token" ]]; then
      echo "WARN: ignoring standalone AWS_SESSION_TOKEN for Vultr benchmark credentials; neither Terraform writer output nor a complete env credential pair is available." >&2
    fi
  fi

  if [[ -z "$access_key_id" || -z "$secret_access_key" ]]; then
    echo "ERROR: Vultr k6 S3 writer credentials are unavailable." >&2
    echo "Fix: run 'make aws-s3-writer-apply' or set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in env/vultr.env." >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
  if [[ -n "$session_token" ]]; then
    export AWS_SESSION_TOKEN="$session_token"
  else
    unset AWS_SESSION_TOKEN
  fi
}
