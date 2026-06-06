#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
ECR_NAMESPACE="${ECR_NAMESPACE:?ECR_NAMESPACE is required}"
MANIFEST_ROOT="${MANIFEST_ROOT:-.}"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_BASE="${ECR_REGISTRY}/${ECR_NAMESPACE}"

patch_image_file() {
  local file="$1"
  local repo="$2"
  local image="${ECR_BASE}/${repo}:${IMAGE_TAG}"

  perl -0pi -e "s{image:\\s*REPLACE_WITH_ECR_IMAGE}{image: ${image}}g; s{image:\\s*\\S+/\\Q${ECR_NAMESPACE}/${repo}\\E:[^\\s]+}{image: ${image}}g" "$file"
}

patch_kustomize_image() {
  local file="$1"
  local placeholder_name="$2"
  local repo="$3"
  local new_name="${ECR_BASE}/${repo}"

  perl -0pi -e "s{(-\\s+name:\\s+\\Q${placeholder_name}\\E\\n\\s+newName:\\s+).*?(\\n\\s+newTag:\\s+).*?\$}{\${1}${new_name}\${2}${IMAGE_TAG}}mg" "$file"
}

patch_datadog_version() {
  local file="$1"

  perl -0pi -e "s{tags\\.datadoghq\\.com/version:\\s*\\S+}{tags.datadoghq.com/version: ${IMAGE_TAG}}g" "$file"
}

patch_value_line() {
  local file="$1"
  local env_name="$2"
  local env_value="$3"

  perl -0pi -e "s{(-\\s+name:\\s+\\Q${env_name}\\E\\n\\s+value:\\s+).*\$}{\${1}${env_value}}mg" "$file"
}

patch_app_manifests() {
  local monolith_base="${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/base/monolith.yaml"
  local msa_base="${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/base"

  patch_datadog_version "$monolith_base"
  patch_datadog_version "${msa_base}/api-gateway.yaml"
  patch_datadog_version "${msa_base}/auth-service.yaml"
  patch_datadog_version "${msa_base}/item-service.yaml"
  patch_datadog_version "${msa_base}/transaction-service.yaml"

  patch_kustomize_image "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/overlays/fixed/kustomization.yaml" "REPLACE_WITH_MONOLITH_ECR_IMAGE" "monolith"
  patch_kustomize_image "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/overlays/hpa/kustomization.yaml" "REPLACE_WITH_MONOLITH_ECR_IMAGE" "monolith"

  local msa_overlay
  for msa_overlay in fixed hpa; do
    local kustomization="${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/overlays/${msa_overlay}/kustomization.yaml"
    patch_kustomize_image "$kustomization" "REPLACE_WITH_API_GATEWAY_ECR_IMAGE" "api-gateway"
    patch_kustomize_image "$kustomization" "REPLACE_WITH_AUTH_SERVICE_ECR_IMAGE" "auth-service"
    patch_kustomize_image "$kustomization" "REPLACE_WITH_ITEM_SERVICE_ECR_IMAGE" "item-service"
    patch_kustomize_image "$kustomization" "REPLACE_WITH_TRANSACTION_SERVICE_ECR_IMAGE" "transaction-service"
  done
}

patch_job_manifests() {
  local seed_files=(
    "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/reset-monolith-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/seed-monolith-smoke-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/seed-monolith-benchmark-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-smoke-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/reset-microservices-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/seed-microservices-smoke-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/seed-microservices-benchmark-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-smoke-data-job.yaml"
    "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml"
  )

  local file
  for file in "${seed_files[@]}"; do
    patch_image_file "$file" "seed-runner"
  done

  patch_image_file "${MANIFEST_ROOT}/deployments/k8s/cloud/monolith/migration-job.yaml" "monolith"
  patch_image_file "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/auth-migration-job.yaml" "auth-service"
  patch_image_file "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/item-migration-job.yaml" "item-service"
  patch_image_file "${MANIFEST_ROOT}/deployments/k8s/cloud/microservices/transaction-migration-job.yaml" "transaction-service"
}

patch_benchmark_manifests() {
  local monolith_manifest="${MANIFEST_ROOT}/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml"
  local microservices_manifest="${MANIFEST_ROOT}/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml"

  patch_image_file "$monolith_manifest" "k6-runner"
  patch_image_file "$microservices_manifest" "k6-runner"

  patch_value_line "$monolith_manifest" "IMAGE_TAG" "\"${IMAGE_TAG}\""
  patch_value_line "$microservices_manifest" "IMAGE_TAG" "\"${IMAGE_TAG}\""

  patch_value_line \
    "$monolith_manifest" \
    "IMAGES_JSON" \
    "'{\"monolith\":\"${ECR_BASE}/monolith:${IMAGE_TAG}\"}'"
  patch_value_line \
    "$microservices_manifest" \
    "IMAGES_JSON" \
    "'{\"api_gateway\":\"${ECR_BASE}/api-gateway:${IMAGE_TAG}\",\"auth_service\":\"${ECR_BASE}/auth-service:${IMAGE_TAG}\",\"item_service\":\"${ECR_BASE}/item-service:${IMAGE_TAG}\",\"transaction_service\":\"${ECR_BASE}/transaction-service:${IMAGE_TAG}\"}'"
}

patch_app_manifests
patch_job_manifests
patch_benchmark_manifests

echo "Patched EKS manifests with IMAGE_TAG=${IMAGE_TAG}"
