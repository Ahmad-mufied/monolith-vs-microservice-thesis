#!/usr/bin/env bash
# Full deployment flow for the MSA EKS cluster.
# Run after terraform apply and setup-eks-contexts.sh.
set -euo pipefail

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

CONTEXT="msa"
K8S="kubectl --context=$CONTEXT"
SCALING_MODE="${SCALING_MODE:-fixed}"
EKS_JOB_DIR="deployments/k8s/eks/microservices"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
RENDER_ROOT="$(mktemp -d)"
RENDERED_EKS_JOB_DIR=""
RENDERED_MSA_OVERLAY_DIR=""

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

echo "=== Deploying MSA cluster (context: $CONTEXT) ==="

echo "Rendering EKS manifests with IMAGE_TAG=$IMAGE_TAG"
IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-eks-manifests.sh >/dev/null
RENDERED_EKS_JOB_DIR="$RENDER_ROOT/$EKS_JOB_DIR"
RENDERED_MSA_OVERLAY_DIR="$RENDERED_EKS_JOB_DIR/overlays/$SCALING_MODE"
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

# Namespaces
$K8S apply -f deployments/k8s/namespaces/local.yaml
$K8S apply -f deployments/k8s/benchmark/namespace.yaml
$K8S apply -f deployments/k8s/benchmark/k6-runner-rbac.yaml

echo "Ensure the following secrets exist in the cluster:"
echo "  benchmark/db-bootstrap-env        (BOOTSTRAP_DATABASE_URL)"
echo "  msa/api-gateway-secret            (JWT_SECRET, service addresses)"
echo "  msa/auth-service-secret           (DATABASE_URL, JWT_SECRET)"
echo "  msa/item-service-secret           (DATABASE_URL)"
echo "  msa/transaction-service-secret    (DATABASE_URL, service addresses)"
echo "  datadog/datadog-secret            (api-key)"
if [ -t 0 ]; then
  read -r -p "Press Enter to continue after secrets are created..."
else
  echo "Non-interactive execution detected; continuing without prompt."
fi

# DB bootstrap
$K8S delete job db-bootstrap-job -n benchmark --ignore-not-found
$K8S apply -f deployments/k8s/benchmark/microservices/db-bootstrap-job.yaml
$K8S wait --for=condition=complete job/db-bootstrap-job -n benchmark --timeout=120s
echo "DB bootstrap complete"

prepare_existing_workloads_for_redeploy() {
  local svc
  for svc in api-gateway auth-service item-service transaction-service; do
    $K8S delete hpa "$svc" -n msa --ignore-not-found
  done
  for svc in api-gateway auth-service item-service transaction-service; do
    if $K8S get deployment "$svc" -n msa >/dev/null 2>&1; then
      $K8S scale deployment "$svc" -n msa --replicas=0
      if ! $K8S rollout status "deployment/${svc}" -n msa --timeout=300s; then
        echo "Failed to scale down ${svc} before redeploy; aborting before migrations/reset/seed." >&2
        exit 1
      fi
    fi
  done
}

prepare_existing_workloads_for_redeploy

# Migrations (parallel)
for svc in auth item transaction; do
  $K8S delete job "${svc}-migration-job" -n msa --ignore-not-found
  $K8S apply -f "${RENDERED_EKS_JOB_DIR}/${svc}-migration-job.yaml"
done
for svc in auth item transaction; do
  $K8S wait --for=condition=complete job/"${svc}-migration-job" -n msa --timeout=180s
done
echo "Migrations complete"

# Seed
$K8S delete job reset-microservices-data-job -n msa --ignore-not-found
$K8S apply -f "$RENDERED_EKS_JOB_DIR/reset-microservices-data-job.yaml"
$K8S wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

$K8S delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
$K8S apply -f "$RENDERED_EKS_JOB_DIR/seed-microservices-benchmark-data-job.yaml"
$K8S wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s
echo "Seed complete"

# Deploy services
$K8S apply -k "$RENDERED_MSA_OVERLAY_DIR"

# Resource management
if [ "$SCALING_MODE" = "hpa" ]; then
  bash scripts/install-metrics-server.sh "$CONTEXT"
  echo "HPA mode applied"
else
  for svc in api-gateway auth-service item-service transaction-service; do
    $K8S delete hpa "$svc" -n msa --ignore-not-found
  done
  echo "Fixed replica mode applied"
fi

for svc in auth-service item-service transaction-service api-gateway; do
  $K8S rollout status "deployment/${svc}" -n msa --timeout=300s
done

# Datadog
DATADOG_API_KEY="${DATADOG_API_KEY:-}"
DATADOG_CHART_VERSION="${DATADOG_CHART_VERSION:-3.134.0}"
if [ -f env/datadog.eks.env ]; then
  DATADOG_SITE_OVERRIDE="${DATADOG_SITE:-}"
  set -a
  source env/datadog.eks.env
  set +a
  if [ -n "$DATADOG_SITE_OVERRIDE" ]; then
    DATADOG_SITE="$DATADOG_SITE_OVERRIDE"
  fi
fi
if has_non_placeholder_datadog_api_key "$DATADOG_API_KEY"; then
  helm repo add datadog https://helm.datadoghq.com --force-update
  helm repo update datadog
  KUBE_CONTEXT="$CONTEXT" DATADOG_NAMESPACE=datadog DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}" bash scripts/create-datadog-secret.sh
  helm upgrade --install datadog datadog/datadog \
    --version "$DATADOG_CHART_VERSION" \
    --kube-context="$CONTEXT" \
    --namespace datadog \
    --values deployments/helm/datadog/values-eks-msa.yaml \
    --set datadog.site="${DATADOG_SITE:-datadoghq.com}"
  kubectl --context="$CONTEXT" rollout status daemonset/datadog -n datadog --timeout=300s
  echo "Datadog installed"
elif [ -n "$DATADOG_API_KEY" ]; then
  echo "Skipping Datadog install: DATADOG_API_KEY is still a placeholder value" >&2
fi

echo ""
echo "=== MSA cluster ready ==="
$K8S get pods -n msa
