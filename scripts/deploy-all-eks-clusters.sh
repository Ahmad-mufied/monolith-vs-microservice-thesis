#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

image_tag_env_file="$(resolve_image_tag_env_file || true)"
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$image_tag_env_file" ]; then
  set -a
  source "$image_tag_env_file"
  set +a
fi

source scripts/lib/cloud-provider.sh
load_cloud_provider_env

SCALING_MODE="${SCALING_MODE:-fixed}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"

case "$SCALING_MODE" in
  fixed|hpa) ;;
  *) echo "ERROR: unsupported SCALING_MODE '$SCALING_MODE' (expected: fixed|hpa)" >&2; exit 1 ;;
esac

for context in monolith msa; do
  if ! kubectl config get-contexts "$context" >/dev/null 2>&1; then
    echo "missing kubectl context '$context'; run: make eks-setup-contexts" >&2
    exit 1
  fi
done

echo "=== Deploying both benchmark architectures ==="
echo "  scaling_mode : $SCALING_MODE"
echo "  image_tag    : $IMAGE_TAG"
echo "  provider     : $CLOUD_PROVIDER"
echo ""

SCALING_MODE="$SCALING_MODE" \
IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
CLOUD_PROVIDER="$CLOUD_PROVIDER" \
bash scripts/deploy-monolith-cluster.sh

echo ""

SCALING_MODE="$SCALING_MODE" \
IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
CLOUD_PROVIDER="$CLOUD_PROVIDER" \
bash scripts/deploy-msa-cluster.sh

echo ""
echo "Both benchmark architectures deployed with SCALING_MODE=$SCALING_MODE"
