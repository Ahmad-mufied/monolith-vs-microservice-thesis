#!/usr/bin/env bash
# Deploy exactly one architecture on the single sequential EKS cluster.
set -euo pipefail

DATADOG_SITE_EXPLICIT_OVERRIDE=""
if [ "${DATADOG_SITE+x}" = "x" ]; then
  DATADOG_SITE_EXPLICIT_OVERRIDE="$DATADOG_SITE"
fi

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

if [ -z "${IMAGE_TAG:-}" ] && [ -f env/image-tag.eks.env ]; then
  set -a
  source env/image-tag.eks.env
  set +a
fi

ARCHITECTURE="${ARCHITECTURE:?ARCHITECTURE is required (monolith|microservices)}"
CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"
K8S="kubectl --context=$CONTEXT"
SCALING_MODE="${SCALING_MODE:-fixed}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
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

scale_down_monolith() {
  $K8S delete hpa monolith -n mono --ignore-not-found
  if $K8S get deployment monolith -n mono >/dev/null 2>&1; then
    $K8S scale deployment monolith -n mono --replicas=0
    $K8S rollout status deployment/monolith -n mono --timeout=300s
  fi
}

scale_down_microservices() {
  local svc
  for svc in api-gateway auth-service item-service transaction-service; do
    $K8S delete hpa "$svc" -n msa --ignore-not-found
  done
  for svc in api-gateway auth-service item-service transaction-service; do
    if $K8S get deployment "$svc" -n msa >/dev/null 2>&1; then
      $K8S scale deployment "$svc" -n msa --replicas=0
      $K8S rollout status "deployment/${svc}" -n msa --timeout=300s
    fi
  done
}

install_datadog_if_configured() {
  DATADOG_API_KEY="${DATADOG_API_KEY:-}"
  DATADOG_CHART_VERSION="${DATADOG_CHART_VERSION:-3.134.0}"
  if [ -f env/datadog.eks.env ]; then
    set -a
    source env/datadog.eks.env
    set +a
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
echo ""

IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-eks-manifests.sh >/dev/null
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

$K8S apply -f deployments/k8s/namespaces/local.yaml
$K8S apply -f deployments/k8s/benchmark/namespace.yaml
$K8S apply -f deployments/k8s/benchmark/k6-runner-rbac.yaml

case "$ARCHITECTURE" in
  monolith)
    rendered_job_dir="$RENDER_ROOT/deployments/k8s/eks/monolith"
    rendered_overlay_dir="$rendered_job_dir/overlays/$SCALING_MODE"

    require_secret benchmark db-bootstrap-env "BOOTSTRAP_DATABASE_URL"
    require_secret mono monolith-env "DATABASE_URL, JWT_SECRET, and application config"

    scale_down_microservices

    $K8S delete job db-bootstrap-job -n benchmark --ignore-not-found
    $K8S apply -f deployments/k8s/benchmark/monolith/db-bootstrap-job.yaml
    $K8S wait --for=condition=complete job/db-bootstrap-job -n benchmark --timeout=120s

    scale_down_monolith

    $K8S delete job monolith-migration-job -n mono --ignore-not-found
    $K8S apply -f "$rendered_job_dir/migration-job.yaml"
    $K8S wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s

    $K8S delete job reset-monolith-data-job -n mono --ignore-not-found
    $K8S apply -f "$rendered_job_dir/reset-monolith-data-job.yaml"
    $K8S wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

    $K8S delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
    $K8S apply -f "$rendered_job_dir/seed-monolith-benchmark-data-job.yaml"
    $K8S wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

    $K8S apply -k "$rendered_overlay_dir"
    if [ "$SCALING_MODE" = "hpa" ]; then
      bash scripts/install-metrics-server.sh "$CONTEXT"
    else
      $K8S delete hpa monolith -n mono --ignore-not-found
    fi
    $K8S rollout status deployment/monolith -n mono --timeout=300s
    ;;
  microservices)
    rendered_job_dir="$RENDER_ROOT/deployments/k8s/eks/microservices"
    rendered_overlay_dir="$rendered_job_dir/overlays/$SCALING_MODE"

    require_secret benchmark db-bootstrap-env "BOOTSTRAP_DATABASE_URL"
    require_secret msa api-gateway-secret "JWT_SECRET and service addresses"
    require_secret msa auth-service-secret "DATABASE_URL and JWT_SECRET"
    require_secret msa item-service-secret "DATABASE_URL"
    require_secret msa transaction-service-secret "DATABASE_URL and service addresses"

    scale_down_monolith

    $K8S delete job db-bootstrap-job -n benchmark --ignore-not-found
    $K8S apply -f deployments/k8s/benchmark/microservices/db-bootstrap-job.yaml
    $K8S wait --for=condition=complete job/db-bootstrap-job -n benchmark --timeout=120s

    scale_down_microservices

    for svc in auth item transaction; do
      $K8S delete job "${svc}-migration-job" -n msa --ignore-not-found
      $K8S apply -f "${rendered_job_dir}/${svc}-migration-job.yaml"
    done
    for svc in auth item transaction; do
      $K8S wait --for=condition=complete job/"${svc}-migration-job" -n msa --timeout=180s
    done

    $K8S delete job reset-microservices-data-job -n msa --ignore-not-found
    $K8S apply -f "$rendered_job_dir/reset-microservices-data-job.yaml"
    $K8S wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

    $K8S delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
    $K8S apply -f "$rendered_job_dir/seed-microservices-benchmark-data-job.yaml"
    $K8S wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

    $K8S apply -k "$rendered_overlay_dir"
    if [ "$SCALING_MODE" = "hpa" ]; then
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
