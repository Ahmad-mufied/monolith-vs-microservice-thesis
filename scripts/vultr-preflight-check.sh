#!/usr/bin/env bash
set -euo pipefail

env_file="env/vultr.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init-vultr" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

source scripts/lib/vultr-s3-credentials.sh
load_vultr_s3_credentials

: "${VULTR_API_KEY:?VULTR_API_KEY must be set in env/vultr.env}"
: "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE must be set in env/vultr.env}"
: "${AWS_REGION:?AWS_REGION must be set in env/vultr.env}"
: "${S3_BUCKET:?S3_BUCKET must be set in env/vultr.env}"

if [ "$VULTR_API_KEY" = "replace-me" ] || [ "$DOCKERHUB_NAMESPACE" = "replace-me" ]; then
  echo "ERROR: Vultr preflight found placeholder VULTR_API_KEY or DOCKERHUB_NAMESPACE" >&2
  exit 1
fi

echo "=== Vultr Preflight ==="
echo "  region          : ${VULTR_REGION:-sgp}"
echo "  dockerhub_ns    : $DOCKERHUB_NAMESPACE"
echo "  s3_bucket       : $S3_BUCKET"

aws sts get-caller-identity >/dev/null
aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "ERROR: Vultr k6 S3 writer credentials are not available." >&2
  echo "Fix: run 'make aws-s3-writer-apply' or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY manually in env/vultr.env." >&2
  exit 1
fi

if [ -f env/vultr-resource-baseline.env ]; then
  source env/vultr-resource-baseline.env
  : "${VULTR_APP_CPU_QUOTA:?VULTR_APP_CPU_QUOTA missing in env/vultr-resource-baseline.env}"
  : "${VULTR_APP_MEMORY_QUOTA:?VULTR_APP_MEMORY_QUOTA missing in env/vultr-resource-baseline.env}"
else
  echo "WARN: env/vultr-resource-baseline.env not found yet; run make vultr-measure-resource-baseline after cluster creation" >&2
fi

image_tag="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  if ! docker manifest inspect "docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${image_tag}" >/dev/null 2>&1; then
    echo "ERROR: Docker Hub image is missing or inaccessible: docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${image_tag}" >&2
    exit 1
  fi
done

echo "Vultr preflight passed"
