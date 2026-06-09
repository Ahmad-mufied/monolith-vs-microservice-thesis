#!/usr/bin/env bash

load_hetzner_s3_credentials() {
  local writer_dir="${TERRAFORM_AWS_S3_WRITER_DIR:-infra/terraform/aws-s3-writer}"
  local shared_dir="${TERRAFORM_AWS_SHARED_DIR:-infra/terraform/aws-shared}"
  local access_key_id="${AWS_ACCESS_KEY_ID:-}"
  local secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"

  if [[ -n "$access_key_id" && -n "$secret_access_key" ]]; then
    return 0
  fi

  if [[ -n "$access_key_id" || -n "$secret_access_key" ]]; then
    echo "WARN: ignoring incomplete Hetzner AWS S3 writer credential pair from env; loading both values from Terraform." >&2
    access_key_id=""
    secret_access_key=""
  fi

  if ! command -v terraform >/dev/null 2>&1; then
    echo "ERROR: terraform is required to load Hetzner k6 S3 writer credentials when env credentials are absent." >&2
    return 1
  fi

  if [[ -d "$writer_dir" ]]; then
    access_key_id="$(terraform -chdir="$writer_dir" output -raw hetzner_k6_s3_access_key_id 2>/dev/null || true)"
    secret_access_key="$(terraform -chdir="$writer_dir" output -raw hetzner_k6_s3_secret_access_key 2>/dev/null || true)"
  fi

  if [[ (-z "$access_key_id" || -z "$secret_access_key") && -d "$shared_dir" ]]; then
    access_key_id="$(terraform -chdir="$shared_dir" output -raw hetzner_k6_s3_access_key_id 2>/dev/null || true)"
    secret_access_key="$(terraform -chdir="$shared_dir" output -raw hetzner_k6_s3_secret_access_key 2>/dev/null || true)"
  fi

  if [[ -z "$access_key_id" || -z "$secret_access_key" ]]; then
    echo "ERROR: Hetzner k6 S3 writer credentials are unavailable." >&2
    echo "Fix: run 'make aws-s3-writer-apply', ensure legacy shared Hetzner outputs exist, or set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in env/hetzner.env." >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
}
