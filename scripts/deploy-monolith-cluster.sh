#!/usr/bin/env bash
# Full deployment flow for the monolith EKS cluster.
# Run after terraform apply and setup-eks-contexts.sh.
set -euo pipefail

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

CONTEXT="monolith"
K8S="kubectl --context=$CONTEXT"
SCALING_MODE="${SCALING_MODE:-fixed}"
EKS_JOB_DIR="deployments/k8s/eks/monolith"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
RENDER_ROOT="$(mktemp -d)"
RENDERED_EKS_JOB_DIR=""
RENDERED_MONOLITH_OVERLAY_DIR=""

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

echo "=== Deploying monolith cluster (context: $CONTEXT) ==="

echo "Rendering EKS manifests with IMAGE_TAG=$IMAGE_TAG"
IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-eks-manifests.sh >/dev/null
RENDERED_EKS_JOB_DIR="$RENDER_ROOT/$EKS_JOB_DIR"
RENDERED_MONOLITH_OVERLAY_DIR="$RENDERED_EKS_JOB_DIR/overlays/$SCALING_MODE"
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

# Namespaces
$K8S apply -f deployments/k8s/namespaces/local.yaml
$K8S apply -f deployments/k8s/benchmark/namespace.yaml
$K8S apply -f deployments/k8s/benchmark/k6-runner-rbac.yaml

# Secrets (operator must create these before running this script)
echo "Ensure the following secrets exist in the cluster:"
echo "  benchmark/db-bootstrap-env  (BOOTSTRAP_DATABASE_URL)"
echo "  mono/monolith-env           (DATABASE_URL, JWT_SECRET, ...)"
echo "  datadog/datadog-secret      (api-key)"
if [ -t 0 ]; then
  read -r -p "Press Enter to continue after secrets are created..."
else
  echo "Non-interactive execution detected; continuing without prompt."
fi

# DB bootstrap
$K8S delete job db-bootstrap-job -n benchmark --ignore-not-found
$K8S apply -f deployments/k8s/monolith/db-bootstrap-job.yaml
$K8S wait --for=condition=complete job/db-bootstrap-job -n benchmark --timeout=120s
echo "DB bootstrap complete"

prepare_existing_workload_for_redeploy() {
  $K8S delete hpa monolith -n mono --ignore-not-found
  if $K8S get deployment monolith -n mono >/dev/null 2>&1; then
    $K8S scale deployment monolith -n mono --replicas=0
    if ! $K8S rollout status deployment/monolith -n mono --timeout=300s; then
      echo "Failed to scale down monolith before redeploy; aborting before migration/reset/seed." >&2
      exit 1
    fi
  fi
}

prepare_existing_workload_for_redeploy

# Migration
$K8S delete job monolith-migration-job -n mono --ignore-not-found
$K8S apply --validate=false -f "$RENDERED_EKS_JOB_DIR/migration-job.yaml"
$K8S wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s
echo "Migration complete"

# Seed
$K8S delete job reset-monolith-data-job -n mono --ignore-not-found
$K8S apply --validate=false -f "$RENDERED_EKS_JOB_DIR/reset-monolith-data-job.yaml"
$K8S wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

$K8S delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
$K8S apply --validate=false -f "$RENDERED_EKS_JOB_DIR/seed-monolith-benchmark-data-job.yaml"
$K8S wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s
echo "Seed complete"

# Deploy application
$K8S apply --validate=false -k "$RENDERED_MONOLITH_OVERLAY_DIR"

# Resource management
if [ "$SCALING_MODE" = "hpa" ]; then
  bash scripts/install-metrics-server.sh "$CONTEXT"
  echo "HPA mode applied"
else
  $K8S delete hpa monolith -n mono --ignore-not-found
  echo "Fixed replica mode applied"
fi

$K8S rollout status deployment/monolith -n mono --timeout=300s

# Datadog
DATADOG_API_KEY="${DATADOG_API_KEY:-}"
DATADOG_CHART_VERSION="${DATADOG_CHART_VERSION:-3.134.0}"
if [ -f env/datadog.eks.env ]; then
  set -a
  source env/datadog.eks.env
  set +a
fi
if has_non_placeholder_datadog_api_key "$DATADOG_API_KEY"; then
  helm repo add datadog https://helm.datadoghq.com --force-update
  helm repo update datadog
  KUBE_CONTEXT="$CONTEXT" DATADOG_NAMESPACE=datadog DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}" bash scripts/create-datadog-secret.sh
  helm upgrade --install datadog datadog/datadog \
    --version "$DATADOG_CHART_VERSION" \
    --kube-context="$CONTEXT" \
    --namespace datadog \
    --values deployments/helm/datadog/values-eks-monolith.yaml \
    --set datadog.site="${DATADOG_SITE:-datadoghq.com}"
  kubectl --context="$CONTEXT" rollout status daemonset/datadog -n datadog --timeout=300s
  echo "Datadog installed"
elif [ -n "$DATADOG_API_KEY" ]; then
  echo "Skipping Datadog install: DATADOG_API_KEY is still a placeholder value" >&2
fi

echo ""
echo "=== Monolith cluster ready ==="
$K8S get pods -n mono
