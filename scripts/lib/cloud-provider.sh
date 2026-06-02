#!/usr/bin/env bash

normalize_cloud_provider() {
  local provider="${1:-${CLOUD_PROVIDER:-aws}}"
  case "$provider" in
    aws|eks)
      printf 'aws'
      ;;
    hetzner)
      printf 'hetzner'
      ;;
    vultr)
      printf 'vultr'
      ;;
    *)
      echo "ERROR: unsupported CLOUD_PROVIDER '$provider' (expected: aws|hetzner|vultr)" >&2
      return 1
      ;;
  esac
}

load_cloud_provider_env() {
  CLOUD_PROVIDER="$(normalize_cloud_provider "${CLOUD_PROVIDER:-aws}")" || return 1
  case "$CLOUD_PROVIDER" in
    hetzner)
      if [ -f env/hetzner.env ]; then
        set -a
        source env/hetzner.env
        set +a
      fi
      ;;
    vultr)
      if [ -f env/vultr.env ]; then
        set -a
        source env/vultr.env
        set +a
      fi
      ;;
  esac
  export CLOUD_PROVIDER
}

render_provider_manifests() {
  local output_dir="$1"
  : "${IMAGE_TAG:?IMAGE_TAG is required}"
  : "${CLOUD_PROVIDER:?CLOUD_PROVIDER is required}"

  case "$CLOUD_PROVIDER" in
    aws)
      IMAGE_TAG="$IMAGE_TAG" AWS_REGION="${AWS_REGION:-ap-southeast-1}" ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}" OUTPUT_DIR="$output_dir" bash scripts/render-eks-manifests.sh >/dev/null
      ;;
    hetzner)
      : "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required for CLOUD_PROVIDER=hetzner}"
      IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" OUTPUT_DIR="$output_dir" bash scripts/render-hetzner-manifests.sh >/dev/null
      ;;
    vultr)
      : "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required for CLOUD_PROVIDER=vultr}"
      IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" OUTPUT_DIR="$output_dir" bash scripts/render-vultr-manifests.sh >/dev/null
      ;;
    *)
      echo "ERROR: unsupported CLOUD_PROVIDER '$CLOUD_PROVIDER'" >&2
      return 1
      ;;
  esac
}

provider_parallel_stack_name() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'aws-parallel' ;;
    hetzner) printf 'hetzner-parallel' ;;
    vultr) printf 'vultr-parallel' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_sequential_stack_name() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'aws-sequential' ;;
    hetzner) printf 'hetzner-sequential' ;;
    vultr) printf 'vultr-sequential' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_parallel_destroy_target() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'eks-destroy-confirmed' ;;
    hetzner) printf 'hetzner-parallel-destroy-confirmed' ;;
    vultr) printf 'vultr-parallel-destroy-confirmed' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_sequential_destroy_target() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'eks-sequential-destroy-confirmed' ;;
    hetzner) printf 'hetzner-sequential-destroy-confirmed' ;;
    vultr) printf 'vultr-sequential-destroy-confirmed' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_default_run_prefix() {
  local execution_mode="$1"
  case "${CLOUD_PROVIDER:-aws}:$execution_mode" in
    aws:parallel) printf 'eks' ;;
    aws:sequential) printf 'eks-sequential' ;;
    hetzner:parallel) printf 'hetzner' ;;
    hetzner:sequential) printf 'hetzner-sequential' ;;
    vultr:parallel) printf 'vultr' ;;
    vultr:sequential) printf 'vultr-sequential' ;;
    *) echo "ERROR: unsupported provider/execution mode '${CLOUD_PROVIDER:-}:${execution_mode}'" >&2; return 1 ;;
  esac
}

provider_default_cluster_name() {
  local architecture="${1:-}"
  case "${CLOUD_PROVIDER:-aws}:$architecture" in
    aws:monolith) printf 'skripsi-monolith' ;;
    aws:microservices|aws:msa) printf 'skripsi-msa' ;;
    aws:sequential|"aws:") printf '%s' "${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}" ;;
    hetzner:monolith) printf '%s' "${HETZNER_MONOLITH_CLUSTER_NAME:-skripsi-hetzner-monolith}" ;;
    hetzner:microservices|hetzner:msa) printf '%s' "${HETZNER_MSA_CLUSTER_NAME:-skripsi-hetzner-msa}" ;;
    hetzner:sequential|"hetzner:") printf '%s' "${HETZNER_SEQUENTIAL_CLUSTER_NAME:-skripsi-hetzner-benchmark}" ;;
    vultr:monolith) printf '%s' "${VULTR_MONOLITH_CLUSTER_NAME:-skripsi-vultr-monolith}" ;;
    vultr:microservices|vultr:msa) printf '%s' "${VULTR_MSA_CLUSTER_NAME:-skripsi-vultr-msa}" ;;
    vultr:sequential|"vultr:") printf '%s' "${VULTR_SEQUENTIAL_CLUSTER_NAME:-skripsi-vultr-benchmark}" ;;
    *) echo "ERROR: unsupported provider/architecture '${CLOUD_PROVIDER:-}:${architecture}'" >&2; return 1 ;;
  esac
}
