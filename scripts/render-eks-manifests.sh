#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
ECR_NAMESPACE="${ECR_NAMESPACE:?ECR_NAMESPACE is required}"

OUTPUT_DIR="${OUTPUT_DIR:-$(mktemp -d)}"
MANIFEST_ROOT="$OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/deployments/k8s"
rm -rf "$OUTPUT_DIR/deployments/k8s/eks" "$OUTPUT_DIR/deployments/k8s/benchmark"
cp -R deployments/k8s/eks "$OUTPUT_DIR/deployments/k8s/"
cp -R deployments/k8s/benchmark "$OUTPUT_DIR/deployments/k8s/"

IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
MANIFEST_ROOT="$MANIFEST_ROOT" \
bash scripts/eks-update-manifests.sh >/dev/null

echo "$OUTPUT_DIR"
