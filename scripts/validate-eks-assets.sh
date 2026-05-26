#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-deploy}"
MANIFEST_ROOT="${2:-.}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -n "$MANIFEST_ROOT" ]] || fail "MANIFEST_ROOT must not be empty"

EKS_DIR="${MANIFEST_ROOT}/deployments/k8s/eks"
BENCHMARK_DIR="${MANIFEST_ROOT}/deployments/k8s/benchmark"

[[ -d "$EKS_DIR" ]] || fail "EKS manifest directory not found: $EKS_DIR"
[[ -d "$BENCHMARK_DIR" ]] || fail "Benchmark manifest directory not found: $BENCHMARK_DIR"

check_no_local_images() {
  if rg -n ':local|imagePullPolicy:\s+Never' "$EKS_DIR" "$BENCHMARK_DIR" > /tmp/eks-asset-local-check.txt; then
    cat /tmp/eks-asset-local-check.txt >&2
    fail "EKS manifests still contain local-only images or imagePullPolicy Never"
  fi
}

check_no_unpatched_ecr_placeholders() {
  if rg -n 'REPLACE_WITH_[A-Z_]+_ECR_IMAGE|replace-me\.dkr\.ecr' \
    "$BENCHMARK_DIR" \
    "$EKS_DIR"/monolith/base/*.yaml \
    "$EKS_DIR"/monolith/*job.yaml \
    "$EKS_DIR"/microservices/base/*.yaml \
    "$EKS_DIR"/microservices/*job.yaml > /tmp/eks-asset-ecr-check.txt; then
    cat /tmp/eks-asset-ecr-check.txt >&2
    fail "EKS manifests still contain unresolved ECR placeholders"
  fi
}

check_rendered_overlays() {
  local overlay
  for overlay in \
    "$EKS_DIR/monolith/overlays/fixed" \
    "$EKS_DIR/monolith/overlays/hpa" \
    "$EKS_DIR/microservices/overlays/fixed" \
    "$EKS_DIR/microservices/overlays/hpa"; do
    kubectl kustomize "$overlay" > /tmp/eks-kustomize-render.yaml
    if rg -n 'REPLACE_WITH_[A-Z_]+_ECR_IMAGE|replace-me\.dkr\.ecr|imagePullPolicy:\s+Never|:local' /tmp/eks-kustomize-render.yaml > /tmp/eks-overlay-check.txt; then
      cat /tmp/eks-overlay-check.txt >&2
      fail "Rendered Kustomize overlay still contains unresolved image placeholders or local-only settings: $overlay"
    fi
  done
}

check_benchmark_runtime_placeholders() {
  if rg -n 's3://replace-me|value:\s+eks-run-001|value:\s+attempt-01' "$BENCHMARK_DIR" > /tmp/eks-asset-benchmark-check.txt; then
    cat /tmp/eks-asset-benchmark-check.txt >&2
    fail "Benchmark manifests still contain runtime placeholder values; rerun the benchmark launcher with real inputs"
  fi
}

check_no_local_images
check_no_unpatched_ecr_placeholders
check_rendered_overlays

if [ "$MODE" = "benchmark-rendered" ]; then
  check_benchmark_runtime_placeholders
fi
