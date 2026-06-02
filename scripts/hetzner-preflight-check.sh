#!/usr/bin/env bash
set -euo pipefail

env_file="env/hetzner.env"
if [ ! -f "$env_file" ]; then
  echo "missing $env_file; run: make env-init-hetzner" >&2
  exit 1
fi

set -a
source "$env_file"
set +a

source scripts/lib/hetzner-s3-credentials.sh
load_hetzner_s3_credentials

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN must be set in env/hetzner.env}"
: "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE must be set in env/hetzner.env}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set in env/hetzner.env, Terraform aws-s3-writer output hetzner_k6_s3_access_key_id, or legacy shared output hetzner_k6_s3_access_key_id}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set in env/hetzner.env, Terraform aws-s3-writer output hetzner_k6_s3_secret_access_key, or legacy shared output hetzner_k6_s3_secret_access_key}"
: "${AWS_REGION:?AWS_REGION must be set in env/hetzner.env}"
: "${S3_BUCKET:?S3_BUCKET must be set in env/hetzner.env}"

contexts="${HETZNER_PREFLIGHT_CONTEXTS:-benchmark}"
image_tag="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"

echo "=== Hetzner Preflight ==="
echo "  contexts          : $contexts"
echo "  dockerhub_ns      : $DOCKERHUB_NAMESPACE"
echo "  image_tag         : $image_tag"
echo "  s3_bucket         : $S3_BUCKET"
echo ""

if command -v hcloud >/dev/null 2>&1; then
  HCLOUD_TOKEN="$HCLOUD_TOKEN" hcloud server-type list >/dev/null
else
  echo "warning: hcloud CLI not found; skipping server type availability check" >&2
fi

AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
AWS_REGION="$AWS_REGION" \
aws sts get-caller-identity >/dev/null

AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
AWS_REGION="$AWS_REGION" \
aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null

for context in $contexts; do
  kubectl --context="$context" get nodes >/dev/null
  kubectl --context="$context" get nodes -l node-group=app --no-headers | grep -q .
  kubectl --context="$context" get nodes -l node-group=testing --no-headers | grep -q .
  kubectl --context="$context" describe nodes -l node-group=testing | grep -q 'workload=benchmark:NoSchedule'
done

for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  if ! docker manifest inspect "docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${image_tag}" >/dev/null 2>&1; then
    echo "ERROR: Docker Hub image is missing or inaccessible: docker.io/${DOCKERHUB_NAMESPACE}/${repo}:${image_tag}" >&2
    exit 1
  fi
done

echo "Hetzner preflight passed"
