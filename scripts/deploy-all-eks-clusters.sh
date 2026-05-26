#!/usr/bin/env bash
set -euo pipefail

if [ -z "${IMAGE_TAG:-}" ] && [ -f env/image-tag.eks.env ]; then
  set -a
  source env/image-tag.eks.env
  set +a
fi

SCALING_MODE="${SCALING_MODE:-fixed}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"

for context in monolith msa; do
  if ! kubectl config get-contexts "$context" >/dev/null 2>&1; then
    echo "missing kubectl context '$context'; run: make eks-setup-contexts" >&2
    exit 1
  fi
done

echo "=== Deploying both EKS architectures ==="
echo "  scaling_mode : $SCALING_MODE"
echo "  image_tag    : $IMAGE_TAG"
echo ""

SCALING_MODE="$SCALING_MODE" \
IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
bash scripts/deploy-monolith-cluster.sh

echo ""

SCALING_MODE="$SCALING_MODE" \
IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
bash scripts/deploy-msa-cluster.sh

echo ""
echo "Both EKS architectures deployed with SCALING_MODE=$SCALING_MODE"
