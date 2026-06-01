#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
SEQUENTIAL_CLUSTER_NAME="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}"
SEQUENTIAL_CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"

echo "Setting up kubectl context for sequential EKS cluster..."

aws eks update-kubeconfig \
  --name "$SEQUENTIAL_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --alias "$SEQUENTIAL_CONTEXT"

echo ""
echo "Available contexts:"
kubectl config get-contexts

echo ""
echo "Test sequential cluster:"
kubectl --context="$SEQUENTIAL_CONTEXT" get nodes
