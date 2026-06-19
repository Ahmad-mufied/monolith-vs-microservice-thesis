#!/usr/bin/env bash
# Full deployment flow for the monolith application.
# Run after terraform apply and setup-eks-contexts.sh.
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

image_tag_env_file="$(resolve_image_tag_env_file || true)"
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$image_tag_env_file" ]; then
  set -a
  source "$image_tag_env_file"
  set +a
fi

CONTEXT="monolith"
K8S="kubectl --context=$CONTEXT"
SCALING_MODE="${SCALING_MODE:-fixed}"
MONOLITH_EFFECTIVE_SCALING_MODE="fixed"
APP_JOB_DIR="deployments/k8s/cloud/monolith"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
RENDER_ROOT="$(mktemp -d)"
RENDERED_APP_JOB_DIR=""
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
  EXECUTION_MODE=parallel \
  SCALING_MODE="$SCALING_MODE" \
  CLOUD_PROVIDER="$CLOUD_PROVIDER" \
  bash scripts/operator-dispatch.sh create-secrets
}

annotate_monolith_rendered_manifests() {
  shared_annotate_monolith_rendered_manifests "$RENDERED_APP_JOB_DIR" "$CONTEXT"
}

echo "=== Deploying monolith cluster (context: $CONTEXT) ==="

echo "Rendering cloud manifests with IMAGE_TAG=$IMAGE_TAG"
render_provider_manifests "$RENDER_ROOT"
RENDERED_APP_JOB_DIR="$RENDER_ROOT/$APP_JOB_DIR"
RENDERED_MONOLITH_OVERLAY_DIR="$RENDERED_APP_JOB_DIR/overlays/$MONOLITH_EFFECTIVE_SCALING_MODE"
bash scripts/validate-cloud-assets.sh deploy "$RENDER_ROOT"

# Namespaces
$K8S apply -f deployments/k8s/namespaces/local.yaml
$K8S apply -f deployments/k8s/benchmark/namespace.yaml
$K8S apply -f deployments/k8s/benchmark/k6-runner-rbac.yaml
sync_runtime_secrets

# Required secrets
echo "Verifying required secrets..."
require_secret benchmark db-bootstrap-env "BOOTSTRAP_DATABASE_URL"
require_secret mono monolith-env "DATABASE_URL, JWT_SECRET, and application config"
echo "Required secrets are present."

# DB bootstrap
$K8S delete job db-bootstrap-job -n benchmark --ignore-not-found
$K8S apply -f deployments/k8s/benchmark/monolith/db-bootstrap-job.yaml
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
$K8S apply -f "$RENDERED_APP_JOB_DIR/migration-job.yaml"
$K8S wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s
echo "Migration complete"

# Seed
$K8S delete job reset-monolith-data-job -n mono --ignore-not-found
$K8S apply -f "$RENDERED_APP_JOB_DIR/reset-monolith-data-job.yaml"
$K8S wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

$K8S delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
$K8S apply -f "$RENDERED_APP_JOB_DIR/seed-monolith-benchmark-data-job.yaml"
$K8S wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s
echo "Seed complete"

# Deploy application
annotate_monolith_rendered_manifests
$K8S apply -k "$RENDERED_MONOLITH_OVERLAY_DIR"

# Resource management
$K8S delete hpa monolith -n mono --ignore-not-found
if [ "$SCALING_MODE" = "hpa" ]; then
  echo "Monolith stays in fixed mode while supplemental SCALING_MODE=hpa is used for microservices autoscaling."
else
  echo "Fixed replica mode applied"
fi

$K8S rollout status deployment/monolith -n mono --timeout=300s

# Datadog
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
