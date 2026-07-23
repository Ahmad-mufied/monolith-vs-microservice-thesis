#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
if [[ -z "$action" ]]; then
  echo "usage: $0 <action>" >&2
  exit 1
fi
shift || true

source scripts/lib/operator-profile.sh
source scripts/lib/cloud-provider.sh

if [[ "$action" != report-* ]]; then
  load_operator_profile_env
  load_cloud_provider_env
fi

run_deprecated_target() {
  local replacement="$1"
  echo "ERROR: deprecated command. Re-run with: $replacement" >&2
  exit 1
}

require_sequential_architecture() {
  case "${ARCHITECTURE:-}" in
    monolith|microservices) ;;
    *)
      echo "ERROR: ARCHITECTURE must be set to monolith or microservices when EXECUTION_MODE=sequential" >&2
      exit 1
      ;;
  esac
}

reject_parallel_architecture() {
  if [[ -n "${ARCHITECTURE:-}" ]]; then
    echo "ERROR: ARCHITECTURE must not be set when EXECUTION_MODE=parallel" >&2
    exit 1
  fi
}

dispatch_render_tfvars() {
  case "$PLATFORM" in
    eks) bash scripts/render-eks-tfvars.sh ;;
    vultr) bash scripts/render-vultr-tfvars.sh ;;
    oci) bash scripts/render-oci-tfvars.sh ;;
  esac
}

dispatch_shared_terraform() {
  local terraform_action="$1"
  shift || true
  if [[ "$terraform_action" == "plan" && "$#" -eq 0 ]]; then
    set -- -out=tfplan
  fi
  case "$PLATFORM" in
    eks)
      case "$terraform_action" in
        plan|apply|destroy)
          cd infra/terraform/aws-shared
          AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" terraform init
          AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" terraform "$terraform_action" "$@"
          ;;
      esac
      ;;
    vultr)
      dispatch_vultr_terraform "$terraform_action" "$@"
      ;;
    oci)
      dispatch_oci_terraform "$terraform_action" "$@"
      ;;
  esac
}

dispatch_experiment_terraform() {
  local terraform_action="$1"
  shift || true

  if [[ "$terraform_action" == "plan" && "$#" -eq 0 ]]; then
    set -- -out=tfplan
  fi

  case "$PLATFORM" in
    vultr)
      dispatch_vultr_terraform "$terraform_action" "$@"
      ;;
    oci)
      dispatch_oci_terraform "$terraform_action" "$@"
      ;;
    eks)
      case "${EXECUTION_MODE}" in
        parallel)
          TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-parallel.sh init
          TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-parallel.sh "$terraform_action" "$@"
          ;;
        sequential)
          TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-sequential.sh init
          TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-sequential.sh "$terraform_action" "$@"
          ;;
      esac
      ;;
  esac
}

dispatch_vultr_terraform() {
  local terraform_action="$1"
  shift || true

  if [[ "$terraform_action" == "plan" && "$#" -eq 0 ]]; then
    set -- -out=tfplan
  fi

  if [[ "$terraform_action" == "apply" ]]; then
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh init
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh apply
  fi

  bash scripts/terraform-vultr.sh init
  bash scripts/terraform-vultr.sh "$terraform_action" "$@"
}

dispatch_oci_terraform() {
  local terraform_action="$1"
  shift || true

  bash scripts/render-oci-tfvars.sh

  if [[ "$terraform_action" == "plan" && "$#" -eq 0 ]]; then
    set -- -out=tfplan
  fi

  if [[ "$terraform_action" == "apply" ]] && [[ -n "${AWS_PROFILE:-}" || -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh init
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh apply
  fi

  cd infra/terraform/oci
  terraform init -upgrade
  terraform "$terraform_action" "$@"
}

dispatch_setup_contexts() {
  case "${PLATFORM}:${EXECUTION_MODE}" in
    eks:parallel) bash scripts/setup-eks-contexts.sh ;;
    eks:sequential) bash scripts/setup-eks-contexts-sequential.sh ;;
    vultr:parallel) VULTR_MODE=parallel bash scripts/setup-vultr-contexts.sh ;;
    vultr:sequential) VULTR_MODE=sequential bash scripts/setup-vultr-contexts.sh ;;
    oci:*) echo "OCI contexts setup: merge OKE cluster kubeconfigs into local ~/.kube/config" ;;
  esac
}

dispatch_create_secrets() {
  case "${PLATFORM}:${EXECUTION_MODE}" in
    eks:parallel)
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/create-eks-secrets-monolith.sh
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/create-eks-secrets-microservices.sh
      ;;
    eks:sequential)
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/create-eks-secrets-sequential.sh
      ;;
    vultr:parallel)
      bash scripts/create-vultr-secrets-monolith.sh
      bash scripts/create-vultr-secrets-microservices.sh
      ;;
    vultr:sequential)
      bash scripts/create-vultr-secrets-sequential.sh
      ;;
    oci:*)
      bash scripts/create-oci-secrets.sh
      ;;
  esac
}

dispatch_preflight_check() {
  case "$PLATFORM" in
    eks) bash scripts/benchmark-preflight-check.sh ;;
    vultr) bash scripts/vultr-preflight-check.sh ;;
    oci) echo "OCI preflight check complete" ;;
  esac
}

dispatch_measure_resource_baseline() {
  case "$PLATFORM" in
    eks|oci)
      echo "measure-resource-baseline is not required for PLATFORM=$PLATFORM"
      ;;
    vultr)
      bash scripts/measure-vultr-resource-baseline.sh
      ;;
  esac
}

dispatch_render_manifests() {
  local render_dir
  render_dir="$(mktemp -d)"
  trap 'rm -rf "$render_dir"' EXIT
  case "$PLATFORM" in
    eks)
      IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" AWS_REGION="${AWS_REGION:-ap-southeast-1}" ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}" OUTPUT_DIR="$render_dir" bash scripts/render-eks-manifests.sh >/dev/null
      bash scripts/validate-cloud-assets.sh deploy "$render_dir"
      echo "Rendered manifests to $render_dir"
      trap - EXIT
      ;;
    vultr)
      IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" OUTPUT_DIR="$render_dir" bash scripts/render-vultr-manifests.sh >/dev/null
      bash scripts/validate-cloud-assets.sh deploy "$render_dir"
      bash scripts/validate-rendered-provider-assets.sh vultr "$render_dir"
      echo "Rendered manifests to $render_dir"
      trap - EXIT
      ;;
    oci)
      IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" OUTPUT_DIR="$render_dir" bash scripts/render-oci-manifests.sh >/dev/null
      bash scripts/validate-cloud-assets.sh deploy "$render_dir"
      echo "Rendered manifests to $render_dir"
      trap - EXIT
      ;;
  esac
}

dispatch_deploy_workloads() {
  : "${SCALING_MODE:?SCALING_MODE is required}"
  case "$EXECUTION_MODE" in
    parallel)
      reject_parallel_architecture
      case "$PLATFORM" in
        eks)
          IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" AWS_REGION="${AWS_REGION:-ap-southeast-1}" ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}" make --no-print-directory ecr-check-tag
          CLOUD_PROVIDER=aws SCALING_MODE="$SCALING_MODE" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" AWS_REGION="${AWS_REGION:-ap-southeast-1}" ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}" bash scripts/deploy-all-clusters.sh
          ;;
        vultr)
          IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}" bash scripts/dockerhub-public-image-check.sh
          CLOUD_PROVIDER="$CLOUD_PROVIDER" SCALING_MODE="$SCALING_MODE" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/deploy-all-clusters.sh
          ;;
        oci)
          IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}" bash scripts/dockerhub-public-image-check.sh || true
          CLOUD_PROVIDER="$CLOUD_PROVIDER" SCALING_MODE="$SCALING_MODE" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/deploy-all-clusters.sh
          ;;
      esac
      ;;
    sequential)
      require_sequential_architecture
      CLOUD_PROVIDER="$CLOUD_PROVIDER" ARCHITECTURE="$ARCHITECTURE" SCALING_MODE="$SCALING_MODE" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" AWS_REGION="${AWS_REGION:-ap-southeast-1}" ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}" bash scripts/deploy-sequential-architecture.sh
      ;;
  esac
}

dispatch_run_benchmark_case() {
  : "${SCENARIO:?SCENARIO is required}"
  : "${TARGET_RPS:?TARGET_RPS is required}"
  : "${RUN_ID:?RUN_ID is required}"

  case "$EXECUTION_MODE" in
    parallel)
      reject_parallel_architecture
      CLOUD_PROVIDER="$CLOUD_PROVIDER" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/run-benchmark-parallel.sh
      ;;
    sequential)
      require_sequential_architecture
      CLOUD_PROVIDER="$CLOUD_PROVIDER" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/run-benchmark-sequential.sh
      ;;
  esac
}

dispatch_run_benchmark_suite() {
  : "${SCALING_MODE:?SCALING_MODE is required}"
  case "$EXECUTION_MODE" in
    parallel)
      CLOUD_PROVIDER="$CLOUD_PROVIDER" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/run-benchmark-suite.sh
      ;;
    sequential)
      CLOUD_PROVIDER="$CLOUD_PROVIDER" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" bash scripts/run-benchmark-suite-sequential.sh
      ;;
  esac
}

dispatch_run_benchmark_arch_suite() {
  : "${ARCHITECTURE:?ARCHITECTURE is required}"
  : "${SCALING_MODE:?SCALING_MODE is required}"

  case "$EXECUTION_MODE" in
    sequential)
      CLOUD_PROVIDER="$CLOUD_PROVIDER" IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" EXECUTION_MODE="$EXECUTION_MODE" bash scripts/run-benchmark-arch-suite.sh
      ;;
    parallel)
      echo "ERROR: run-benchmark-arch-suite currently supports EXECUTION_MODE=sequential only" >&2
      exit 1
      ;;
    *)
      echo "ERROR: unsupported EXECUTION_MODE '$EXECUTION_MODE' for run-benchmark-arch-suite (expected: sequential)" >&2
      exit 1
      ;;
  esac
}

dispatch_verify_live_mode() {
  : "${SCALING_MODE:?SCALING_MODE is required}"
  EXECUTION_MODE="$EXECUTION_MODE" ARCHITECTURE="${ARCHITECTURE:-}" bash scripts/verify-live-mode.sh
}

case "$action" in
  profile-show)
    show_operator_profile
    ;;
  render-tfvars)
    dispatch_render_tfvars "$@"
    ;;
  shared-plan)
    dispatch_shared_terraform plan "$@"
    ;;
  shared-apply)
    dispatch_shared_terraform apply "$@"
    ;;
  shared-destroy-confirmed)
    S3_BENCHMARK_DATA_VERIFIED=true dispatch_shared_terraform destroy "$@"
    ;;
  experiment-plan)
    dispatch_experiment_terraform plan "$@"
    ;;
  experiment-apply)
    dispatch_experiment_terraform apply "$@"
    ;;
  experiment-destroy-confirmed)
    S3_BENCHMARK_DATA_VERIFIED=true dispatch_experiment_terraform destroy "$@"
    ;;
  setup-contexts)
    dispatch_setup_contexts
    ;;
  create-secrets)
    dispatch_create_secrets
    ;;
  preflight-check)
    dispatch_preflight_check
    ;;
  measure-resource-baseline)
    dispatch_measure_resource_baseline
    ;;
  render-manifests)
    dispatch_render_manifests
    ;;
  verify-live-mode)
    dispatch_verify_live_mode
    ;;
  deploy-workloads)
    dispatch_deploy_workloads
    ;;
  run-benchmark-case)
    dispatch_run_benchmark_case
    ;;
  run-benchmark-suite)
    dispatch_run_benchmark_suite
    ;;
  run-benchmark-arch-suite)
    dispatch_run_benchmark_arch_suite
    ;;
  report-setup)
    uv sync --project tools/report-generator
    ;;
  report-k6)
    uv run --project tools/report-generator k6-report-generator "$@"
    ;;
  report-datadog)
    uv run --project tools/report-generator datadog-reporter "$@"
    ;;
  report-consolidate)
    uv run --project tools/report-generator report-generator consolidate --config tools/report-generator/report-generator.toml "$@"
    ;;
  *)
    echo "ERROR: unsupported operator action '$action'" >&2
    exit 1
    ;;
esac
