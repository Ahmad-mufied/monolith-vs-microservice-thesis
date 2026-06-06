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

load_operator_profile_env
load_cloud_provider_env

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
    hetzner) bash scripts/render-hetzner-tfvars.sh ;;
    vultr) bash scripts/render-vultr-tfvars.sh ;;
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
    hetzner)
      bash scripts/terraform-hetzner.sh shared init
      bash scripts/terraform-hetzner.sh shared "$terraform_action" "$@"
      ;;
    vultr)
      bash scripts/terraform-vultr.sh shared init
      bash scripts/terraform-vultr.sh shared "$terraform_action" "$@"
      ;;
  esac
}

dispatch_experiment_terraform() {
  local terraform_action="$1"
  shift || true

  if [[ "$terraform_action" == "plan" && "$#" -eq 0 ]]; then
    set -- -out=tfplan
  fi

  if [[ "$terraform_action" == "apply" && ( "$PLATFORM" == "hetzner" || "$PLATFORM" == "vultr" ) ]]; then
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh init
    TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-s3-writer.sh apply
  fi

  case "${PLATFORM}:${EXECUTION_MODE}" in
    eks:parallel)
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-parallel.sh init
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-parallel.sh "$terraform_action" "$@"
      ;;
    eks:sequential)
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-sequential.sh init
      TERRAFORM_AWS_PROFILE="${TERRAFORM_AWS_PROFILE:-terraform-process}" bash scripts/terraform-aws-sequential.sh "$terraform_action" "$@"
      ;;
    hetzner:parallel)
      bash scripts/terraform-hetzner.sh parallel init
      bash scripts/terraform-hetzner.sh parallel "$terraform_action" "$@"
      ;;
    hetzner:sequential)
      bash scripts/terraform-hetzner.sh sequential init
      bash scripts/terraform-hetzner.sh sequential "$terraform_action" "$@"
      ;;
    vultr:parallel)
      bash scripts/terraform-vultr.sh parallel init
      bash scripts/terraform-vultr.sh parallel "$terraform_action" "$@"
      ;;
    vultr:sequential)
      bash scripts/terraform-vultr.sh sequential init
      bash scripts/terraform-vultr.sh sequential "$terraform_action" "$@"
      ;;
  esac
}

dispatch_setup_contexts() {
  case "${PLATFORM}:${EXECUTION_MODE}" in
    eks:parallel) bash scripts/setup-eks-contexts.sh ;;
    eks:sequential) bash scripts/setup-eks-contexts-sequential.sh ;;
    hetzner:parallel) HETZNER_MODE=parallel bash scripts/setup-hetzner-contexts.sh ;;
    hetzner:sequential) HETZNER_MODE=sequential bash scripts/setup-hetzner-contexts.sh ;;
    vultr:parallel) VULTR_MODE=parallel bash scripts/setup-vultr-contexts.sh ;;
    vultr:sequential) VULTR_MODE=sequential bash scripts/setup-vultr-contexts.sh ;;
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
    hetzner:parallel)
      bash scripts/create-hetzner-secrets-monolith.sh
      bash scripts/create-hetzner-secrets-microservices.sh
      ;;
    hetzner:sequential)
      bash scripts/create-hetzner-secrets-sequential.sh
      ;;
    vultr:parallel)
      bash scripts/create-vultr-secrets-monolith.sh
      bash scripts/create-vultr-secrets-microservices.sh
      ;;
    vultr:sequential)
      bash scripts/create-vultr-secrets-sequential.sh
      ;;
  esac
}

dispatch_preflight_check() {
  case "$PLATFORM" in
    eks) bash scripts/benchmark-preflight-check.sh ;;
    hetzner) bash scripts/hetzner-preflight-check.sh ;;
    vultr) bash scripts/vultr-preflight-check.sh ;;
  esac
}

dispatch_measure_resource_baseline() {
  case "$PLATFORM" in
    eks)
      echo "measure-resource-baseline is not required for PLATFORM=eks"
      ;;
    hetzner)
      bash scripts/measure-hetzner-resource-baseline.sh
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
    hetzner)
      IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}" OUTPUT_DIR="$render_dir" bash scripts/render-hetzner-manifests.sh >/dev/null
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
        hetzner|vultr)
          IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}" DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}" bash scripts/dockerhub-public-image-check.sh
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
  *)
    echo "ERROR: unsupported operator action '$action'" >&2
    exit 1
    ;;
esac
