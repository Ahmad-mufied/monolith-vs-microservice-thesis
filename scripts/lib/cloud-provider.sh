#!/usr/bin/env bash

normalize_cloud_provider() {
  local provider="${1:-${CLOUD_PROVIDER:-aws}}"
  case "$provider" in
    aws|eks)
      printf 'aws'
      ;;
    vultr)
      printf 'vultr'
      ;;
    oci|oracle)
      printf 'oci'
      ;;
    *)
      echo "ERROR: unsupported CLOUD_PROVIDER '$provider' (expected: aws|vultr|oci)" >&2
      return 1
      ;;
  esac
}

load_cloud_provider_env() {
  CLOUD_PROVIDER="$(normalize_cloud_provider "${CLOUD_PROVIDER:-aws}")" || return 1
  case "$CLOUD_PROVIDER" in
    vultr)
      if [ -f env/vultr.env ]; then
        set -a
        source env/vultr.env
        set +a
      fi
      ;;
    oci)
      if [ -f env/oci.env ]; then
        set -a
        source env/oci.env
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
    vultr)
      : "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required for CLOUD_PROVIDER=vultr}"
      IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" OUTPUT_DIR="$output_dir" bash scripts/render-vultr-manifests.sh >/dev/null
      ;;
    oci)
      IMAGE_TAG="$IMAGE_TAG" OUTPUT_DIR="$output_dir" bash scripts/render-oci-manifests.sh >/dev/null
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
    vultr) printf 'vultr' ;;
    oci) printf 'oci' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_sequential_stack_name() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'aws-sequential' ;;
    vultr) printf 'vultr' ;;
    oci) printf 'oci' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_parallel_destroy_target() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'eks-destroy-confirmed' ;;
    vultr) printf 'vultr-destroy-confirmed' ;;
    oci) printf 'oci-destroy-confirmed' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_sequential_destroy_target() {
  case "${CLOUD_PROVIDER:-aws}" in
    aws) printf 'eks-sequential-destroy-confirmed' ;;
    vultr) printf 'vultr-destroy-confirmed' ;;
    oci) printf 'oci-destroy-confirmed' ;;
    *) echo "ERROR: unsupported CLOUD_PROVIDER '${CLOUD_PROVIDER:-}'" >&2; return 1 ;;
  esac
}

provider_default_run_prefix() {
  local execution_mode="$1"
  case "${CLOUD_PROVIDER:-aws}:$execution_mode" in
    aws:parallel) printf 'eks' ;;
    aws:sequential) printf 'eks-sequential' ;;
    vultr:parallel) printf 'vultr' ;;
    vultr:sequential) printf 'vultr-sequential' ;;
    oci:parallel) printf 'oci' ;;
    oci:sequential) printf 'oci-sequential' ;;
    *) echo "ERROR: unsupported provider/execution mode '${CLOUD_PROVIDER:-}:${execution_mode}'" >&2; return 1 ;;
  esac
}

provider_default_cluster_name() {
  local architecture="${1:-}"
  case "${CLOUD_PROVIDER:-aws}:$architecture" in
    aws:monolith) printf 'skripsi-monolith' ;;
    aws:microservices|aws:msa) printf 'skripsi-msa' ;;
    aws:sequential|"aws:") printf '%s' "${SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}" ;;
    vultr:monolith) printf '%s' "${VULTR_MONOLITH_CLUSTER_NAME:-skripsi-vultr-monolith}" ;;
    vultr:microservices|vultr:msa) printf '%s' "${VULTR_MSA_CLUSTER_NAME:-skripsi-vultr-msa}" ;;
    vultr:sequential|"vultr:") printf '%s' "${VULTR_SEQUENTIAL_CLUSTER_NAME:-skripsi-vultr-benchmark}" ;;
    oci:monolith) printf '%s' "${OCI_MONOLITH_CLUSTER_NAME:-skripsi-oci-monolith}" ;;
    oci:microservices|oci:msa) printf '%s' "${OCI_MSA_CLUSTER_NAME:-skripsi-oci-msa}" ;;
    oci:sequential|"oci:") printf '%s' "${OCI_SEQUENTIAL_CLUSTER_NAME:-skripsi-oci-sequential}" ;;
    *) echo "ERROR: unsupported provider/architecture '${CLOUD_PROVIDER:-}:${architecture}'" >&2; return 1 ;;
  esac
}
