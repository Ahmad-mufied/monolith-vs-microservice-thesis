#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
ECR_NAMESPACE="${ECR_NAMESPACE:?ECR_NAMESPACE is required}"

output_dir_owned="false"
if [[ -z "${OUTPUT_DIR+x}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
  output_dir_owned="true"
fi
[[ -n "${OUTPUT_DIR:-}" ]] || {
  echo "OUTPUT_DIR must not be empty" >&2
  exit 1
}
MANIFEST_ROOT="$OUTPUT_DIR"

cleanup() {
  if [[ "$output_dir_owned" == "true" && -d "$OUTPUT_DIR" ]]; then
    rm -rf "$OUTPUT_DIR"
  fi
}
trap cleanup ERR

mkdir -p "$OUTPUT_DIR/deployments/k8s"
rm -rf "$OUTPUT_DIR/deployments/k8s/eks" "$OUTPUT_DIR/deployments/k8s/benchmark"
cp -R deployments/k8s/eks "$OUTPUT_DIR/deployments/k8s/"
cp -R deployments/k8s/benchmark "$OUTPUT_DIR/deployments/k8s/"

IMAGE_TAG="$IMAGE_TAG" \
AWS_REGION="$AWS_REGION" \
ECR_NAMESPACE="$ECR_NAMESPACE" \
MANIFEST_ROOT="$MANIFEST_ROOT" \
bash scripts/eks-update-manifests.sh >/dev/null

trap - ERR
echo "$OUTPUT_DIR"
