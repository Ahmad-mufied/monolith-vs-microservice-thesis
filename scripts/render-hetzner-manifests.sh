#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"
HETZNER_RESOURCE_BASELINE_ENV="${HETZNER_RESOURCE_BASELINE_ENV:-env/hetzner-resource-baseline.env}"
SKIP_HETZNER_RESOURCE_BASELINE="${SKIP_HETZNER_RESOURCE_BASELINE:-false}"

if [ "$SKIP_HETZNER_RESOURCE_BASELINE" != "true" ]; then
  if [ ! -f "$HETZNER_RESOURCE_BASELINE_ENV" ]; then
    echo "missing $HETZNER_RESOURCE_BASELINE_ENV; run: make hetzner-measure-resource-baseline" >&2
    exit 1
  fi
  set -a
  source "$HETZNER_RESOURCE_BASELINE_ENV"
  set +a
  : "${HETZNER_APP_CPU_QUOTA:?HETZNER_APP_CPU_QUOTA must be set in $HETZNER_RESOURCE_BASELINE_ENV}"
  : "${HETZNER_APP_MEMORY_QUOTA:?HETZNER_APP_MEMORY_QUOTA must be set in $HETZNER_RESOURCE_BASELINE_ENV}"
fi

output_dir_owned="false"
if [[ -z "${OUTPUT_DIR+x}" ]]; then
  OUTPUT_DIR="$(mktemp -d)"
  output_dir_owned="true"
fi
[[ -n "${OUTPUT_DIR:-}" ]] || {
  echo "OUTPUT_DIR must not be empty" >&2
  exit 1
}

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

registry_base="docker.io/${DOCKERHUB_NAMESPACE}"

patch_kustomize_image() {
  local file="$1"
  local placeholder_name="$2"
  local repo="$3"
  perl -0pi -e "s{(-\\s+name:\\s+\\Q${placeholder_name}\\E\\n\\s+newName:\\s+).*?(\\n\\s+newTag:\\s+).*?\$}{\${1}${registry_base}/${repo}\${2}${IMAGE_TAG}}mg" "$file"
}

patch_image_file() {
  local file="$1"
  local repo="$2"
  perl -0pi -e "s{image:\\s*REPLACE_WITH_ECR_IMAGE}{image: ${registry_base}/${repo}:${IMAGE_TAG}}g" "$file"
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

scale_cpu() {
  local current="${1%m}"
  local quota="${HETZNER_APP_CPU_QUOTA%m}"
  awk -v current="$current" -v quota="$quota" 'BEGIN { value = int((current * quota / 15800) / 10) * 10; if (value < 10) value = 10; printf "%dm", value }'
}

scale_memory() {
  local current="${1%Mi}"
  local quota="${HETZNER_APP_MEMORY_QUOTA%Mi}"
  awk -v current="$current" -v quota="$quota" 'BEGIN { value = int((current * quota / 27648) / 16) * 16; if (value < 64) value = 64; printf "%dMi", value }'
}

replace_resource_value() {
  local file="$1"
  local old="$2"
  local new="$3"
  perl -0pi -e "s{\\Q${old}\\E}{${new}}g" "$file"
}

patch_resource_baseline() {
  [ "$SKIP_HETZNER_RESOURCE_BASELINE" = "true" ] && return 0

  local file
  for file in \
    "$manifest_root/deployments/k8s/eks/monolith/overlays/fixed/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/monolith/overlays/hpa/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/microservices/overlays/fixed/resourcequota.yaml" \
    "$manifest_root/deployments/k8s/eks/microservices/overlays/hpa/resourcequota.yaml"; do
    perl -0pi -e "s{requests\\.cpu:\\s*\"[^\"]+\"}{requests.cpu: \"${HETZNER_APP_CPU_QUOTA}\"}g; s{limits\\.cpu:\\s*\"[^\"]+\"}{limits.cpu: \"${HETZNER_APP_CPU_QUOTA}\"}g; s{requests\\.memory:\\s*\"[^\"]+\"}{requests.memory: \"${HETZNER_APP_MEMORY_QUOTA}\"}g; s{limits\\.memory:\\s*\"[^\"]+\"}{limits.memory: \"${HETZNER_APP_MEMORY_QUOTA}\"}g" "$file"
  done

  for file in "$manifest_root"/deployments/k8s/eks/{monolith/overlays/fixed,monolith/overlays/hpa,microservices/overlays/fixed,microservices/overlays/hpa}/*patch.yaml; do
    [ -f "$file" ] || continue
    while IFS= read -r value; do
      replace_resource_value "$file" "$value" "$(scale_cpu "$value")"
    done < <(rg -o '[0-9]+m' "$file" | sort -rnu)
    while IFS= read -r value; do
      replace_resource_value "$file" "$value" "$(scale_memory "$value")"
    done < <(rg -o '[0-9]+Mi' "$file" | sort -rnu)
  done
}

manifest_root="$OUTPUT_DIR"
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
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"hetzner\",\"location\":\"sin\",\"cluster\":\"skripsi-hetzner\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\"}'"
patch_value_line "$manifest_root/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml" "INFRA_CONFIGURATION_JSON" "'{\"provider\":\"hetzner\",\"location\":\"sin\",\"cluster\":\"skripsi-hetzner\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\"}'"

if rg -n 'replace-me\.dkr\.ecr|amazonaws\.com/skripsi' "$OUTPUT_DIR/deployments/k8s" >/tmp/hetzner-render-check.txt; then
  cat /tmp/hetzner-render-check.txt >&2
  echo "ERROR: rendered Hetzner manifests still contain AWS/ECR placeholders" >&2
  exit 1
fi
rm -f /tmp/hetzner-render-check.txt

trap - ERR
echo "$OUTPUT_DIR"
