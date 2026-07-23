#!/usr/bin/env bash
# Deploy exactly one architecture on the single sequential cluster.
set -euo pipefail

source scripts/lib/shared-env.sh

DATADOG_SITE_EXPLICIT_OVERRIDE=""
if [ "${DATADOG_SITE+x}" = "x" ]; then
  DATADOG_SITE_EXPLICIT_OVERRIDE="$DATADOG_SITE"
fi
DATADOG_API_KEY_EXPLICIT_OVERRIDE_SET="0"
DATADOG_API_KEY_EXPLICIT_OVERRIDE_VALUE=""
if [ "${DATADOG_API_KEY+x}" = "x" ]; then
  DATADOG_API_KEY_EXPLICIT_OVERRIDE_SET="1"
  DATADOG_API_KEY_EXPLICIT_OVERRIDE_VALUE="$DATADOG_API_KEY"
fi

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

source scripts/lib/cloud-provider.sh
load_cloud_provider_env
source scripts/lib/sequential-benchmark-setup.sh

image_tag_env_file="$(resolve_image_tag_env_file || true)"
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$image_tag_env_file" ]; then
  set -a
  source "$image_tag_env_file"
  set +a
fi

ARCHITECTURE="${ARCHITECTURE:?ARCHITECTURE is required (monolith|microservices)}"
CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"
SEQUENTIAL_CONTEXT="$CONTEXT"
K8S="kubectl --context=$CONTEXT"
SCALING_MODE="${SCALING_MODE:-fixed}"
MONOLITH_EFFECTIVE_SCALING_MODE="fixed"
MICROSERVICES_EFFECTIVE_SCALING_MODE="$SCALING_MODE"
case "$SCALING_MODE" in
  fixed|hpa) ;;
  *)
    echo "ERROR: unsupported SCALING_MODE '$SCALING_MODE' (expected: fixed|hpa)" >&2
    exit 1
    ;;
esac
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
RENDER_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$RENDER_ROOT"
}
trap cleanup EXIT

has_non_placeholder_datadog_api_key() {
  local value="${1:-}"
  case "${value,,}" in
    ""|"replace-me"|"change_me"|"change-me"|"your_api_key"|"redacted"|"example")
      return 1
      ;;
  esac
  return 0
}

require_secret() {
  local namespace="$1"
  local secret_name="$2"
  local description="$3"

  if ! kubectl --context="$CONTEXT" get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
    echo "Missing required secret: ${namespace}/${secret_name} (${description})" >&2
    exit 1
  fi
}

sync_runtime_secrets() {
  PLATFORM="$PLATFORM" \
  EXECUTION_MODE=sequential \
  SCALING_MODE="$SCALING_MODE" \
  CLOUD_PROVIDER="$CLOUD_PROVIDER" \
  bash scripts/operator-dispatch.sh create-secrets
}

annotate_monolith_rendered_manifests() {
  local rendered_job_dir="$1"
  shared_annotate_monolith_rendered_manifests "$rendered_job_dir" "$CONTEXT"
}

annotate_microservices_rendered_manifests() {
  local rendered_job_dir="$1"
  shared_annotate_microservices_rendered_manifests "$rendered_job_dir" "$CONTEXT"
}

install_datadog_if_configured() {
  DATADOG_API_KEY="${DATADOG_API_KEY:-}"
  DATADOG_CHART_VERSION="${DATADOG_CHART_VERSION:-3.134.0}"
  datadog_env_file="$(resolve_datadog_env_file || true)"
  if [ -n "$datadog_env_file" ]; then
    set -a
    source "$datadog_env_file"
    set +a
  fi
  if [ "$DATADOG_API_KEY_EXPLICIT_OVERRIDE_SET" = "1" ]; then
    DATADOG_API_KEY="$DATADOG_API_KEY_EXPLICIT_OVERRIDE_VALUE"
  fi
  if [ -n "$DATADOG_SITE_EXPLICIT_OVERRIDE" ]; then
    DATADOG_SITE="$DATADOG_SITE_EXPLICIT_OVERRIDE"
  fi
  if has_non_placeholder_datadog_api_key "$DATADOG_API_KEY"; then
    helm repo add datadog https://helm.datadoghq.com --force-update
    helm repo update datadog
    KUBE_CONTEXT="$CONTEXT" DATADOG_NAMESPACE=datadog DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}" bash scripts/create-datadog-secret.sh
    helm upgrade --install datadog datadog/datadog \
      --version "$DATADOG_CHART_VERSION" \
      --kube-context="$CONTEXT" \
      --namespace datadog \
      --values deployments/helm/datadog/values-eks-sequential.yaml \
      --set datadog.site="${DATADOG_SITE:-datadoghq.com}" \
      --set datadog.clusterName="${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}"
    kubectl --context="$CONTEXT" rollout status daemonset/datadog -n datadog --timeout=300s
    echo "Datadog installed"
  elif [ -n "$DATADOG_API_KEY" ]; then
    echo "Skipping Datadog install: DATADOG_API_KEY is still a placeholder value" >&2
  fi
}

echo "=== Deploying sequential architecture ==="
echo "  context       : $CONTEXT"
echo "  architecture  : $ARCHITECTURE"
echo "  scaling_mode  : $SCALING_MODE"
echo "  image_tag     : $IMAGE_TAG"
echo "  provider      : $CLOUD_PROVIDER"
echo ""

render_provider_manifests "$RENDER_ROOT"
bash scripts/validate-cloud-assets.sh deploy "$RENDER_ROOT"

$K8S apply -f deployments/k8s/namespaces/local.yaml
$K8S apply -f deployments/k8s/benchmark/namespace.yaml
$K8S apply -f deployments/k8s/benchmark/k6-runner-rbac.yaml
sync_runtime_secrets

label_arch="monolith"
if [ "$ARCHITECTURE" = "microservices" ]; then
  label_arch="msa"
fi
echo "Labeling sequential app nodes with architecture=$label_arch..."
$K8S label nodes -l node-group=app "architecture=$label_arch" --overwrite

case "$ARCHITECTURE" in
  monolith)
    rendered_job_dir="$RENDER_ROOT/deployments/k8s/cloud/monolith"
    rendered_overlay_dir="$rendered_job_dir/overlays/$MONOLITH_EFFECTIVE_SCALING_MODE"

    require_secret benchmark db-bootstrap-env "BOOTSTRAP_DATABASE_URL"
    require_secret mono monolith-env "DATABASE_URL, JWT_SECRET, and application config"

    for svc in api-gateway auth-service item-service transaction-service; do
      scale_down_deployment msa "$svc"
    done

    recreate_job benchmark db-bootstrap-job deployments/k8s/benchmark/monolith/db-bootstrap-job.yaml 120s

    scale_down_deployment mono monolith

    recreate_job mono monolith-migration-job "$rendered_job_dir/migration-job.yaml" 180s

    recreate_job mono reset-monolith-data-job "$rendered_job_dir/reset-monolith-data-job.yaml" 120s

    recreate_job mono seed-monolith-benchmark-data-job "$rendered_job_dir/seed-monolith-benchmark-data-job.yaml" 300s

    annotate_monolith_rendered_manifests "$rendered_job_dir"
    $K8S apply -k "$rendered_overlay_dir"
    $K8S delete hpa monolith -n mono --ignore-not-found
    $K8S rollout status deployment/monolith -n mono --timeout=300s
    ;;
  microservices)
    rendered_job_dir="$RENDER_ROOT/deployments/k8s/cloud/microservices"
    rendered_overlay_dir="$rendered_job_dir/overlays/$MICROSERVICES_EFFECTIVE_SCALING_MODE"

    require_secret benchmark db-bootstrap-env "BOOTSTRAP_DATABASE_URL"
    require_secret msa api-gateway-secret "JWT_SECRET and service addresses"
    require_secret msa auth-service-secret "DATABASE_URL and JWT_SECRET"
    require_secret msa item-service-secret "DATABASE_URL"
    require_secret msa transaction-service-secret "DATABASE_URL and service addresses"

    scale_down_deployment mono monolith

    recreate_job benchmark db-bootstrap-job deployments/k8s/benchmark/microservices/db-bootstrap-job.yaml 120s

    for svc in api-gateway auth-service item-service transaction-service; do
      scale_down_deployment msa "$svc"
    done

    for svc in auth item transaction; do
      recreate_job msa "${svc}-migration-job" "${rendered_job_dir}/${svc}-migration-job.yaml" 180s
    done

    recreate_job msa reset-microservices-data-job "$rendered_job_dir/reset-microservices-data-job.yaml" 120s

    recreate_job msa seed-microservices-benchmark-data-job "$rendered_job_dir/seed-microservices-benchmark-data-job.yaml" 300s

    annotate_microservices_rendered_manifests "$rendered_job_dir"
    $K8S apply -k "$rendered_overlay_dir"
    if [ "$MICROSERVICES_EFFECTIVE_SCALING_MODE" = "hpa" ]; then
      bash scripts/install-metrics-server.sh "$CONTEXT"
    else
      for svc in api-gateway auth-service item-service transaction-service; do
        $K8S delete hpa "$svc" -n msa --ignore-not-found
      done
    fi
    for svc in auth-service item-service transaction-service api-gateway; do
      $K8S rollout status "deployment/${svc}" -n msa --timeout=300s
    done
    ;;
  *)
    echo "ERROR: unsupported ARCHITECTURE '$ARCHITECTURE' (expected: monolith|microservices)" >&2
    exit 1
    ;;
esac

install_datadog_if_configured

echo ""
echo "=== Sequential architecture ready ==="
echo "  context      : $CONTEXT"
echo "  architecture : $ARCHITECTURE"
