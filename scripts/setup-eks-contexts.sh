#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-1}"

echo "Setting up kubectl contexts for both EKS clusters..."

aws eks update-kubeconfig \
  --name skripsi-monolith \
  --region "$AWS_REGION" \
  --alias monolith

aws eks update-kubeconfig \
  --name skripsi-msa \
  --region "$AWS_REGION" \
  --alias msa

echo ""
echo "Available contexts:"
kubectl config get-contexts

echo ""
echo "Test monolith cluster:"
kubectl --context=monolith get nodes

echo ""
echo "Test msa cluster:"
kubectl --context=msa get nodes
