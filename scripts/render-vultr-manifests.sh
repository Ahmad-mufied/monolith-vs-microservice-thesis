#!/usr/bin/env bash
set -euo pipefail

if [ -f env/vultr.env ]; then
  set -a
  source env/vultr.env
  set +a
fi

if [ -z "${IMAGE_TAG:-}" ] && [ -f env/image-tag.eks.env ]; then
  set -a
  source env/image-tag.eks.env
  set +a
fi

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"
VULTR_RESOURCE_BASELINE_ENV="${VULTR_RESOURCE_BASELINE_ENV:-env/vultr-resource-baseline.env}"
SKIP_VULTR_RESOURCE_BASELINE="${SKIP_VULTR_RESOURCE_BASELINE:-false}"

if [ "$SKIP_VULTR_RESOURCE_BASELINE" != "true" ]; then
  if [ ! -f "$VULTR_RESOURCE_BASELINE_ENV" ]; then
    echo "missing $VULTR_RESOURCE_BASELINE_ENV; run: make vultr-measure-resource-baseline" >&2
    exit 1
  fi
  set -a
  source "$VULTR_RESOURCE_BASELINE_ENV"
  set +a
  : "${VULTR_APP_CPU_QUOTA:?VULTR_APP_CPU_QUOTA must be set in $VULTR_RESOURCE_BASELINE_ENV}"
  : "${VULTR_APP_MEMORY_QUOTA:?VULTR_APP_MEMORY_QUOTA must be set in $VULTR_RESOURCE_BASELINE_ENV}"
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
rm -rf "$OUTPUT_DIR/deployments/k8s/eks" "$OUTPUT_DIR/deployments/k8s/benchmark"
cp -R deployments/k8s/eks "$OUTPUT_DIR/deployments/k8s/"
cp -R deployments/k8s/benchmark "$OUTPUT_DIR/deployments/k8s/"

registry_base="docker.io/${DOCKERHUB_NAMESPACE}"
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

scale_cpu() {
  local current="${1%m}" quota="${VULTR_APP_CPU_QUOTA%m}"
  awk -v current="$current" -v quota="$quota" 'BEGIN { value = int((current * quota / 15800) / 10) * 10; if (value < 10) value = 10; printf "%dm", value }'
}

scale_memory() {
  local current="${1%Mi}" quota="${VULTR_APP_MEMORY_QUOTA%Mi}"
  awk -v current="$current" -v quota="$quota" 'BEGIN { value = int((current * quota / 27648) / 16) * 16; if (value < 64) value = 64; printf "%dMi", value }'
}

replace_resource_value() {
  local file="$1" old="$2" new="$3"
  perl -0pi -e "s{\\Q${old}\\E}{${new}}g" "$file"
}

patch_resource_baseline() {
  [ "$SKIP_VULTR_RESOURCE_BASELINE" = "true" ] && return 0
  local file
  for file in \
    "$manifest_root/deployments/k8s/eks/monolith/overlays/fixed/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/monolith/overlays/hpa/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/microservices/overlays/fixed/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/microservices/overlays/hpa/resourcequota.yaml"; do
    perl -0pi -e "s{requests\\.cpu:\\s*\"[^\"]+\"}{requests.cpu: \"${VULTR_APP_CPU_QUOTA}\"}g; s{limits\\.cpu:\\s*\"[^\"]+\"}{limits.cpu: \"${VULTR_APP_CPU_QUOTA}\"}g; s{requests\\.memory:\\s*\"[^\"]+\"}{requests.memory: \"${VULTR_APP_MEMORY_QUOTA}\"}g; s{limits\\.memory:\\s*\"[^\"]+\"}{limits.memory: \"${VULTR_APP_MEMORY_QUOTA}\"}g" "$file"
  done

  for file in "$manifest_root"/deployments/k8s/eks/{monolith/overlays/fixed,monolith/overlays/hpa,microservices/overlays/fixed,microservices/overlays/hpa}/*patch.yaml; do
    [ -f "$file" ] || continue
    while IFS= read -r value; do replace_resource_value "$file" "$value" "$(scale_cpu "$value")"; done < <(rg -o '[0-9]+m' "$file" | sort -rnu)
    while IFS= read -r value; do replace_resource_value "$file" "$value" "$(scale_memory "$value")"; done < <(rg -o '[0-9]+Mi' "$file" | sort -rnu)
  done
}

patch_resource_baseline
patch_datadog_version "$manifest_root/deployments/k8s/eks/monolith/base/monolith.yaml"
for svc in api-gateway auth-service item-service transaction-service; do
  patch_datadog_version "$manifest_root/deployments/k8s/eks/microservices/base/${svc}.yaml"
done

for overlay in fixed hpa; do
  patch_kustomize_image "$manifest_root/deployments/k8s/eks/monolith/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_MONOLITH_ECR_IMAGE" "monolith"
  patch_kustomize_image "$manifest_root/deployments/k8s/eks/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_API_GATEWAY_ECR_IMAGE" "api-gateway"
  patch_kustomize_image "$manifest_root/deployments/k8s/eks/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_AUTH_SERVICE_ECR_IMAGE" "auth-service"
  patch_kustomize_image "$manifest_root/deployments/k8s/eks/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_ITEM_SERVICE_ECR_IMAGE" "item-service"
  patch_kustomize_image "$manifest_root/deployments/k8s/eks/microservices/overlays/${overlay}/kustomization.yaml" "REPLACE_WITH_TRANSACTION_SERVICE_ECR_IMAGE" "transaction-service"
done

for file in \
  "$manifest_root/deployments/k8s/eks/monolith/reset-monolith-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/monolith/seed-monolith-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/monolith/seed-monolith-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/monolith/prepare-monolith-enrichment-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/microservices/reset-microservices-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/microservices/seed-microservices-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/microservices/seed-microservices-benchmark-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/microservices/prepare-microservices-enrichment-smoke-data-job.yaml" \
  "$manifest_root/deployments/k8s/eks/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml"; do
  patch_image_file "$file" "seed-runner"
done

patch_image_file "$manifest_root/deployments/k8s/eks/monolith/migration-job.yaml" "monolith"
patch_image_file "$manifest_root/deployments/k8s/eks/microservices/auth-migration-job.yaml" "auth-service"
patch_image_file "$manifest_root/deployments/k8s/eks/microservices/item-migration-job.yaml" "item-service"
patch_image_file "$manifest_root/deployments/k8s/eks/microservices/transaction-migration-job.yaml" "transaction-service"

patch_image_file "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "k6-runner"
patch_image_file "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "k6-runner"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "IMAGE_TAG" "\"${IMAGE_TAG}\""
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "IMAGE_TAG" "\"${IMAGE_TAG}\""
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "IMAGES_JSON" "'{\"monolith\":\"${registry_base}/monolith:${IMAGE_TAG}\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "IMAGES_JSON" "'{\"api_gateway\":\"${registry_base}/api-gateway:${IMAGE_TAG}\",\"auth_service\":\"${registry_base}/auth-service:${IMAGE_TAG}\",\"item_service\":\"${registry_base}/item-service:${IMAGE_TAG}\",\"transaction_service\":\"${registry_base}/transaction-service:${IMAGE_TAG}\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"vultr\",\"region\":\"${VULTR_REGION:-sgp}\",\"cluster\":\"${VULTR_CLUSTER_NAME:-skripsi-vultr}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"vultr\",\"region\":\"${VULTR_REGION:-sgp}\",\"cluster\":\"${VULTR_CLUSTER_NAME:-skripsi-vultr}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\"}'"

bash scripts/validate-rendered-provider-assets.sh vultr "$OUTPUT_DIR"

trap - ERR
echo "$OUTPUT_DIR"
