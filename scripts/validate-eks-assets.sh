#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-deploy}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

check_no_local_images() {
  if rg -n ':local|imagePullPolicy:\s+Never' deployments/k8s/eks deployments/k8s/benchmark > /tmp/eks-asset-local-check.txt; then
    cat /tmp/eks-asset-local-check.txt >&2
    fail "EKS manifests still contain local-only images or imagePullPolicy Never"
  fi
}

check_no_unpatched_ecr_placeholders() {
  if rg -n 'REPLACE_WITH_ECR_IMAGE|replace-me\.dkr\.ecr' deployments/k8s/eks deployments/k8s/benchmark > /tmp/eks-asset-ecr-check.txt; then
    cat /tmp/eks-asset-ecr-check.txt >&2
    fail "EKS manifests still contain unresolved ECR placeholders"
  fi
}

check_benchmark_runtime_placeholders() {
  if rg -n 's3://replace-me|value:\s+eks-run-001|value:\s+attempt-01|value:\s+login\.js|value:\s+login$' deployments/k8s/benchmark > /tmp/eks-asset-benchmark-check.txt; then
    cat /tmp/eks-asset-benchmark-check.txt >&2
    fail "Benchmark manifests still contain runtime placeholder values; rerun the benchmark launcher with real inputs"
  fi
}

check_no_local_images
check_no_unpatched_ecr_placeholders

if [ "$MODE" = "benchmark-rendered" ]; then
  check_benchmark_runtime_placeholders
fi
