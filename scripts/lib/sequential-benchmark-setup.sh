#!/usr/bin/env bash
# Shared helpers for sequential benchmark scenario setup and Kubernetes job management.
# Expects: SEQUENTIAL_CONTEXT, RENDER_ROOT, SCALING_MODE set by caller.

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
      echo "ERROR: unknown scenario '$scenario'" >&2
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

  kubectl --context="$SEQUENTIAL_CONTEXT" delete job "$job_name" -n "$namespace" --ignore-not-found
  if kubectl --context="$SEQUENTIAL_CONTEXT" get job "$job_name" -n "$namespace" >/dev/null 2>&1; then
    kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=delete "job/${job_name}" -n "$namespace" --timeout=120s
  fi
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -f "$manifest"
  kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=condition=complete "job/${job_name}" -n "$namespace" --timeout="$complete_timeout"
}

# Scale down a single deployment.
scale_down_deployment() {
  local namespace="$1"
  local deployment="$2"

  kubectl --context="$SEQUENTIAL_CONTEXT" delete hpa "$deployment" -n "$namespace" --ignore-not-found
  if kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
    kubectl --context="$SEQUENTIAL_CONTEXT" scale deployment "$deployment" -n "$namespace" --replicas=0
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${deployment}" -n "$namespace" --timeout=300s
  fi
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

  if [ "$architecture" = "monolith" ]; then
    kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/cloud/monolith/overlays/$SCALING_MODE"
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status deployment/monolith -n mono --timeout=300s
    return
  fi
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/cloud/microservices/overlays/$SCALING_MODE"
  for svc in auth-service item-service transaction-service api-gateway; do
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${svc}" -n msa --timeout=300s
  done
}

# Reset and seed benchmark data for one architecture.
# Args: architecture
reset_seed_active() {
  local architecture="$1"

  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono reset-monolith-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/reset-monolith-data-job.yaml" 120s
    recreate_job mono seed-monolith-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/seed-monolith-benchmark-data-job.yaml" 300s
  else
    recreate_job msa reset-microservices-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/reset-microservices-data-job.yaml" 120s
    recreate_job msa seed-microservices-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/seed-microservices-benchmark-data-job.yaml" 300s
  fi
  restore_active "$architecture"
}

# Prepare enrichment data for one architecture (for enriched-transactions and mixed-workload).
# Args: architecture
prepare_enrichment_active() {
  local architecture="$1"

  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono prepare-monolith-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml" 600s
  else
    recreate_job msa prepare-microservices-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/cloud/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml" 600s
  fi
  restore_active "$architecture"
}

# Run scenario-appropriate data setup for one architecture.
# Args: architecture scenario
run_scenario_data_setup() {
  local architecture="$1"
  local scenario="$2"
  local setup_class

  setup_class="$(scenario_setup_class "$scenario")"
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
}
