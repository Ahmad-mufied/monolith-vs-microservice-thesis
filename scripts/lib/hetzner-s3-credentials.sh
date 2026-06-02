#!/usr/bin/env bash

load_hetzner_s3_credentials() {
  local writer_dir="${TERRAFORM_AWS_S3_WRITER_DIR:-infra/terraform/aws-s3-writer}"
  local shared_dir="${TERRAFORM_AWS_SHARED_DIR:-infra/terraform/shared}"
  local terraform_aws_profile="${TERRAFORM_AWS_PROFILE:-terraform-process}"
  local access_key_id="${AWS_ACCESS_KEY_ID:-}"
  local secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"

  if [[ -n "$access_key_id" && -n "$secret_access_key" ]]; then
    return 0
  fi

  if ! command -v terraform >/dev/null 2>&1; then
    return 0
  fi

  if [[ -d "$writer_dir" ]]; then
    if [[ -z "$access_key_id" ]]; then
      access_key_id="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$writer_dir" output -raw hetzner_k6_s3_access_key_id 2>/dev/null || true)"
    fi
    if [[ -z "$access_key_id" ]]; then
      access_key_id="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$writer_dir" output -raw external_k6_s3_access_key_id 2>/dev/null || true)"
    fi

    if [[ -z "$secret_access_key" ]]; then
      secret_access_key="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$writer_dir" output -raw hetzner_k6_s3_secret_access_key 2>/dev/null || true)"
    fi
    if [[ -z "$secret_access_key" ]]; then
      secret_access_key="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$writer_dir" output -raw external_k6_s3_secret_access_key 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$access_key_id" && -d "$shared_dir" ]]; then
    access_key_id="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$shared_dir" output -raw hetzner_k6_s3_access_key_id 2>/dev/null || true)"
  fi

  if [[ -z "$secret_access_key" && -d "$shared_dir" ]]; then
    secret_access_key="$(AWS_PROFILE="$terraform_aws_profile" terraform -chdir="$shared_dir" output -raw hetzner_k6_s3_secret_access_key 2>/dev/null || true)"
  fi

  export AWS_ACCESS_KEY_ID="$access_key_id"
  export AWS_SECRET_ACCESS_KEY="$secret_access_key"
}
