#!/usr/bin/env bash
set -euo pipefail

mode="${VULTR_MODE:-sequential}"
node_ready_timeout_seconds="${VULTR_NODE_READY_TIMEOUT_SECONDS:-900}"
node_ready_poll_seconds="${VULTR_NODE_READY_POLL_SECONDS:-10}"
mkdir -p env/kubeconfig

validate_positive_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${name} must be a positive integer, got '$value'" >&2
    exit 1
  fi
}

validate_positive_integer VULTR_NODE_READY_TIMEOUT_SECONDS "$node_ready_timeout_seconds"
validate_positive_integer VULTR_NODE_READY_POLL_SECONDS "$node_ready_poll_seconds"

node_group_count() {
  local kubeconfig_path="$1"
  local context="$2"
  local node_group="$3"

  KUBECONFIG="$kubeconfig_path" kubectl --context="$context" get nodes -l "node-group=${node_group}" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]'
}

testing_nodes_have_benchmark_taint() {
  local kubeconfig_path="$1"
  local context="$2"

  KUBECONFIG="$kubeconfig_path" kubectl --context="$context" get nodes -l node-group=testing -o json 2>/dev/null |
    jq -e '.items | length > 0 and all(.[]; any((.spec.taints // [])[]?; .key == "workload" and .value == "benchmark" and .effect == "NoSchedule"))' >/dev/null
}

wait_for_node_groups() {
  local kubeconfig_path="$1"
  local context="$2"
  local started_at
  local app_count
  local testing_count

  started_at="$(date +%s)"
  echo "Waiting for context '$context' node groups (timeout: ${node_ready_timeout_seconds}s)..."

  while true; do
    app_count="$(node_group_count "$kubeconfig_path" "$context" app)"
    testing_count="$(node_group_count "$kubeconfig_path" "$context" testing)"

    if [ "${app_count:-0}" -ge 1 ] && [ "${testing_count:-0}" -ge 1 ] && testing_nodes_have_benchmark_taint "$kubeconfig_path" "$context"; then
      echo "context '$context' node groups ready: app=${app_count}, testing=${testing_count}"
      return 0
    fi

    if [ $(( $(date +%s) - started_at )) -ge "$node_ready_timeout_seconds" ]; then
      echo "ERROR: context '$context' node groups not ready after ${node_ready_timeout_seconds}s (app=${app_count:-0}, testing=${testing_count:-0})" >&2
      echo "Hint: VKE may still be attaching/registering node pools. Retry: make setup-contexts" >&2
      return 1
    fi

    echo "context '$context' waiting for nodes: app=${app_count:-0}, testing=${testing_count:-0}"
    sleep "$node_ready_poll_seconds"
  done
}

write_kubeconfig() {
  local stack="$1"
  local output_name="$2"
  local context="$3"
  local expected_cluster="$4"
  local path="env/kubeconfig/${context}.yaml"
  local old_umask

  old_umask="$(umask)"
  umask 077
  terraform -chdir="$stack" output -raw "$output_name" | base64 -d > "$path"
  umask "$old_umask"
  chmod 600 "$path"

  if [ -f "$HOME/.kube/config" ]; then
    local old_cluster
    old_cluster="$(KUBECONFIG="$HOME/.kube/config" kubectl config view -o jsonpath="{.contexts[?(@.name=='$context')].context.cluster}" 2>/dev/null || true)"
    KUBECONFIG="$HOME/.kube/config" kubectl config delete-context "$context" >/dev/null 2>&1 || true
    KUBECONFIG="$HOME/.kube/config" kubectl config delete-user admin >/dev/null 2>&1 || true
    if [ -n "$old_cluster" ]; then
      KUBECONFIG="$HOME/.kube/config" kubectl config delete-cluster "$old_cluster" >/dev/null 2>&1 || true
    fi
  fi

  KUBECONFIG="$path" kubectl config rename-context "$(KUBECONFIG="$path" kubectl config current-context)" "$context" >/dev/null 2>&1 || true
  KUBECONFIG="$path" kubectl --context="$context" get nodes >/dev/null
  wait_for_node_groups "$path" "$context"

  mkdir -p "$HOME/.kube"
  old_umask="$(umask)"
  umask 077
  if [ -f "$HOME/.kube/config" ]; then
    KUBECONFIG="$HOME/.kube/config:$path" kubectl config view --flatten > "$path.merged"
  else
    KUBECONFIG="$path" kubectl config view --flatten > "$path.merged"
  fi
  umask "$old_umask"
  mv "$path.merged" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  echo "wrote kubeconfig for $expected_cluster: $path"
}

case "$mode" in
  sequential)
    expected_cluster="$(terraform -chdir=infra/terraform/vultr output -raw sequential_cluster_name)"
    write_kubeconfig infra/terraform/vultr sequential_kube_config benchmark "$expected_cluster"
    ;;
  parallel)
    mono_cluster="$(terraform -chdir=infra/terraform/vultr output -raw monolith_cluster_name)"
    msa_cluster="$(terraform -chdir=infra/terraform/vultr output -raw msa_cluster_name)"
    write_kubeconfig infra/terraform/vultr monolith_kube_config monolith "$mono_cluster"
    write_kubeconfig infra/terraform/vultr msa_kube_config msa "$msa_cluster"
    ;;
  *)
    echo "VULTR_MODE must be sequential or parallel" >&2
    exit 1
    ;;
esac
