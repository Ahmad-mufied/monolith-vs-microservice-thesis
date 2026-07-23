#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/shared-env.sh

if [ -f env/oci.env ]; then
  set -a
  source env/oci.env
  set +a
fi

image_tag_env_file="$(resolve_image_tag_env_file || true)"
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$image_tag_env_file" ]; then
  set -a
  source "$image_tag_env_file"
  set +a
fi

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
OCI_REGION="${OCI_REGION:-ap-kulai-2}"
OCIR_NAMESPACE="${OCIR_NAMESPACE:-}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-ahmadmufied}"

if [ -n "$OCIR_NAMESPACE" ]; then
  registry_base="${OCI_REGION}.ocir.io/${OCIR_NAMESPACE}"
else
  registry_base="docker.io/${DOCKERHUB_NAMESPACE}"
fi

output_dir_owned="false"
check_file=""
if [[ -z "${OUTPUT_DIR+x}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
  output_dir_owned="true"
fi
[[ -n "${OUTPUT_DIR:-}" ]] || { echo "OUTPUT_DIR must not be empty" >&2; exit 1; }

cleanup() {
  if [[ -n "$check_file" && -f "$check_file" ]]; then
    rm -f "$check_file"
  fi
  if [[ "$output_dir_owned" == "true" && -d "$OUTPUT_DIR" ]]; then
    rm -rf "$OUTPUT_DIR"
  fi
}
trap cleanup ERR

mkdir -p "$OUTPUT_DIR/deployments/k8s"
rm -rf "$OUTPUT_DIR/deployments/k8s/cloud" "$OUTPUT_DIR/deployments/k8s/benchmark"
cp -R deployments/k8s/cloud "$OUTPUT_DIR/deployments/k8s/"
cp -R deployments/k8s/benchmark "$OUTPUT_DIR/deployments/k8s/"

manifest_root="$OUTPUT_DIR"

patch_kustomize_image() {
  local file="$1" placeholder_name="$2" repo="$3"
  perl -0pi -e "s{(-\\s+name:\\s+\\Q${placeholder_name}\\E\\n\\s+newName:\\s+).*?(\\n\\s+newTag:\\s+).*?\$}{\${1}${registry_base}/${repo}\${2}${IMAGE_TAG}}mg" "$file"
}

patch_image_file() {
  local file="$1" repo="$2"
  perl -0pi -e "s{image:\\s*REPLACE_WITH_ECR_IMAGE}{image: ${registry_base}/${repo}:${IMAGE_TAG}}g" "$file"
}

patch_datadog_version() {
  local file="$1"
  perl -0pi -e "s{tags\\.datadoghq\\.com/version:\\s*\\S+}{tags.datadoghq.com/version: ${IMAGE_TAG}}g" "$file"
}

patch_value_line() {
  local file="$1" env_name="$2" env_value="$3"
  perl -0pi -e "s{(-\\s+name:\\s+\\Q${env_name}\\E\\n\\s+value:\\s+).*\$}{\${1}${env_value}}mg" "$file"
}

patch_datadog_version "$manifest_root/deployments/k8s/cloud/monolith/base/monolith.yaml"
for svc in api-gateway auth-service item-service transaction-service; do
  patch_datadog_version "$manifest_root/deployments/k8s/cloud/microservices/base/${svc}.yaml"
done

for overlay in fixed hpa; do
  patch_kustomize_image "$manifest_root/deployments/k8s/cloud/monolith/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_MONOLITH_ECR_IMAGE" "monolith"
  patch_kustomize_image "$manifest_root/deployments/k8s/cloud/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_API_GATEWAY_ECR_IMAGE" "api-gateway"
  patch_kustomize_image "$manifest_root/deployments/k8s/cloud/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_AUTH_SERVICE_ECR_IMAGE" "auth-service"
  patch_kustomize_image "$manifest_root/deployments/k8s/cloud/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_ITEM_SERVICE_ECR_IMAGE" "item-service"
  patch_kustomize_image "$manifest_root/deployments/k8s/cloud/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_TRANSACTION_SERVICE_ECR_IMAGE" "transaction-service"
done

for file in \
  "$manifest_root/deployments/k8s/cloud/monolith/reset-monolith-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/monolith/seed-monolith-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/monolith/seed-monolith-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/microservices/reset-microservices-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/microservices/seed-microservices-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/microservices/seed-microservices-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml"; do
  patch_image_file "$file" "seed-runner"
done

patch_image_file "$manifest_root/deployments/k8s/cloud/monolith/migration-job.yaml" "monolith"
patch_image_file "$manifest_root/deployments/k8s/cloud/microservices/auth-migration-job.yaml" "auth-service"
patch_image_file "$manifest_root/deployments/k8s/cloud/microservices/item-migration-job.yaml" "item-service"
patch_image_file "$manifest_root/deployments/k8s/cloud/microservices/transaction-migration-job.yaml" "transaction-service"

patch_image_file "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "k6-runner"
patch_image_file "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "k6-runner"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "IMAGE_TAG" "\"${IMAGE_TAG}\""
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "IMAGE_TAG" "\"${IMAGE_TAG}\""
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "IMAGES_JSON" "'{\"monolith\":\"${registry_base}/monolith:${IMAGE_TAG}\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "IMAGES_JSON" "'{\"api_gateway\":\"${registry_base}/api-gateway:${IMAGE_TAG}\",\"auth_service\":\"${registry_base}/auth-service:${IMAGE_TAG}\",\"item_service\":\"${registry_base}/item-service:${IMAGE_TAG}\",\"transaction_service\":\"${registry_base}/transaction-service:${IMAGE_TAG}\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"oci\",\"region\":\"${OCI_REGION:-ap-johor-1}\",\"cluster\":\"${OCI_MONOLITH_CLUSTER_NAME:-skripsi-oci-monolith}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"14\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"oci\",\"region\":\"${OCI_REGION:-ap-johor-1}\",\"cluster\":\"${OCI_MSA_CLUSTER_NAME:-skripsi-oci-msa}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"14\"}'"

trap - ERR
echo "$OUTPUT_DIR"
