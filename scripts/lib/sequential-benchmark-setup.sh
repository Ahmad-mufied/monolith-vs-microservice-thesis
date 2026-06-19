#!/usr/bin/env bash
# Shared helpers for sequential benchmark scenario setup and Kubernetes job management.
# Expects: SEQUENTIAL_CONTEXT, RENDER_ROOT, SCALING_MODE set by caller.

log_setup_timestamp() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

log_setup_info() {
  printf '[%s] %s\n' "$(log_setup_timestamp)" "$*"
}

log_setup_warn() {
  printf '[%s] WARNING: %s\n' "$(log_setup_timestamp)" "$*" >&2
}

log_setup_error() {
  printf '[%s] ERROR: %s\n' "$(log_setup_timestamp)" "$*" >&2
}

# Classify a k6 scenario by its data-setup requirements.
# Outputs: "readonly", "mutating", or "enrichment"
scenario_setup_class() {
  local scenario="$1"
  case "$scenario" in
    login)
      printf 'readonly'
      ;;
    create-transaction|sync-items)
      printf 'mutating'
      ;;
    enriched-transactions|concurrent-mixed-workload|mixed-workload)
      printf 'enrichment'
      ;;
    *)
      log_setup_error "unknown scenario '$scenario'"
      return 1
      ;;
  esac
}

# Classify whether scenario setup can be reused across multiple RPS levels in
# sequential suite mode.
# Outputs: "per_scenario" or "per_case"
scenario_setup_reuse_scope() {
  local scenario="$1"
  case "$scenario" in
    login|enriched-transactions)
      printf 'per_scenario'
      ;;
    create-transaction|sync-items|concurrent-mixed-workload|mixed-workload)
      printf 'per_case'
      ;;
    *)
      log_setup_error "unknown scenario '$scenario'"
      return 1
      ;;
  esac
}

# Delete a Kubernetes job, wait for deletion, apply new manifest, wait for completion.
# Args: namespace job_name manifest_path timeout
recreate_job() {
  local namespace="$1"
  local job_name="$2"
  local manifest="$3"
  local complete_timeout="$4"

  if [ ! -f "$manifest" ]; then
    log_setup_error "required benchmark setup manifest does not exist: $manifest"
    return 1
  fi

  log_setup_info "Recreating Kubernetes job ${namespace}/${job_name} from ${manifest##*/} (timeout: ${complete_timeout})..."
  kubectl --context="$SEQUENTIAL_CONTEXT" delete job "$job_name" -n "$namespace" --ignore-not-found
  if kubectl --context="$SEQUENTIAL_CONTEXT" get job "$job_name" -n "$namespace" >/dev/null 2>&1; then
    log_setup_info "Waiting for previous job ${namespace}/${job_name} deletion..."
    kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=delete "job/${job_name}" -n "$namespace" --timeout=120s
  fi
  log_setup_info "Applying manifest for ${namespace}/${job_name}..."
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -f "$manifest"
  log_setup_info "Waiting for ${namespace}/${job_name} completion..."
  kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=condition=complete "job/${job_name}" -n "$namespace" --timeout="$complete_timeout"
  log_setup_info "Kubernetes job ${namespace}/${job_name} completed."
}

# Scale down a single deployment.
scale_down_deployment() {
  local namespace="$1"
  local deployment="$2"

  log_setup_info "Scaling down deployment ${namespace}/${deployment}..."
  kubectl --context="$SEQUENTIAL_CONTEXT" delete hpa "$deployment" -n "$namespace" --ignore-not-found
  if kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
    kubectl --context="$SEQUENTIAL_CONTEXT" scale deployment "$deployment" -n "$namespace" --replicas=0
    log_setup_info "Waiting for deployment ${namespace}/${deployment} to scale down..."
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${deployment}" -n "$namespace" --timeout=300s
  fi
  log_setup_info "Deployment ${namespace}/${deployment} is scaled down or absent."
}

# Scale down the active architecture (both mono and msa handled).
# Args: architecture
scale_down_active() {
  local architecture="$1"
  local svc

  if [ "$architecture" = "monolith" ]; then
    scale_down_deployment mono monolith
    return
  fi
  for svc in api-gateway auth-service item-service transaction-service; do
    scale_down_deployment msa "$svc"
  done
}

# Apply the Kustomize overlay and wait for rollout.
# Args: architecture
restore_active() {
  local architecture="$1"
  local svc
  local overlay_scaling_mode="$SCALING_MODE"

  if [ "$architecture" = "monolith" ]; then
    overlay_scaling_mode="fixed"
    log_setup_info "Restoring active ${architecture} workloads with requested=${SCALING_MODE}, effective=${overlay_scaling_mode} overlay..."
    kubectl --context="$SEQUENTIAL_CONTEXT" delete hpa monolith -n mono --ignore-not-found
    shared_annotate_monolith_rendered_manifests "$RENDER_ROOT/deployments/k8s/cloud/monolith" "$SEQUENTIAL_CONTEXT"
    kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/cloud/monolith/overlays/$overlay_scaling_mode"
    log_setup_info "Waiting for deployment mono/monolith rollout..."
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status deployment/monolith -n mono --timeout=300s
    log_setup_info "Active ${architecture} workloads restored."
    return
  fi
  log_setup_info "Restoring active ${architecture} workloads with ${overlay_scaling_mode} overlay..."
  shared_annotate_microservices_rendered_manifests "$RENDER_ROOT/deployments/k8s/cloud/microservices" "$SEQUENTIAL_CONTEXT"
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/cloud/microservices/overlays/$overlay_scaling_mode"
  for svc in auth-service item-service transaction-service api-gateway; do
    log_setup_info "Waiting for deployment msa/${svc} rollout..."
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${svc}" -n msa --timeout=300s
  done
  log_setup_info "Active ${architecture} workloads restored."
}

# Reset and seed benchmark data for one architecture.
# Args: architecture
reset_seed_active() {
  local architecture="$1"

  log_setup_info "Starting reset + seed workflow for ${architecture}..."
  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono reset-monolith-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/reset-monolith-data-job.yaml" 120s
    recreate_job mono seed-monolith-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/seed-monolith-benchmark-data-job.yaml" 300s
  else
    recreate_job msa reset-microservices-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/reset-microservices-data-job.yaml" 120s
    recreate_job msa seed-microservices-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/seed-microservices-benchmark-data-job.yaml" 300s
  fi
  restore_active "$architecture"
  log_setup_info "Reset + seed workflow finished for ${architecture}."
}

# Prepare enrichment data for one architecture (for enriched-transactions and mixed-workload).
# Args: architecture
prepare_enrichment_active() {
  local architecture="$1"

  log_setup_info "Starting enrichment preparation workflow for ${architecture}..."
  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono prepare-monolith-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml" 600s
  else
    recreate_job msa prepare-microservices-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml" 600s
  fi
  restore_active "$architecture"
  log_setup_info "Enrichment preparation workflow finished for ${architecture}."
}

# Run scenario-appropriate data setup for one architecture.
# Args: architecture scenario
run_scenario_data_setup() {
  local architecture="$1"
  local scenario="$2"
  local setup_class

  setup_class="$(scenario_setup_class "$scenario")"
  log_setup_info "Running scenario data setup for ${architecture}/${scenario} (class: ${setup_class})..."
  case "$setup_class" in
    readonly)
      reset_seed_active "$architecture"
      ;;
    mutating)
      reset_seed_active "$architecture"
      ;;
    enrichment)
      reset_seed_active "$architecture"
      prepare_enrichment_active "$architecture"
      ;;
  esac
  log_setup_info "Scenario data setup completed for ${architecture}/${scenario}."
}
