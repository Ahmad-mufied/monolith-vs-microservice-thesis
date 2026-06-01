#!/usr/bin/env bash
set -euo pipefail

mode="${VULTR_MODE:-sequential}"
mkdir -p env/kubeconfig

write_kubeconfig() {
  local stack="$1"
  local output_name="$2"
  local context="$3"
  local expected_cluster="$4"
  local path="env/kubeconfig/${context}.yaml"

  terraform -chdir="$stack" output -raw "$output_name" | base64 -d > "$path"
  chmod 600 "$path"
  KUBECONFIG="$path" kubectl config rename-context "$(KUBECONFIG="$path" kubectl config current-context)" "$context" >/dev/null 2>&1 || true
  KUBECONFIG="$path" kubectl --context="$context" get nodes >/dev/null

  app_count="$(KUBECONFIG="$path" kubectl --context="$context" get nodes -l node-group=app --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  testing_count="$(KUBECONFIG="$path" kubectl --context="$context" get nodes -l node-group=testing --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [ "${app_count:-0}" -lt 1 ]; then
    echo "ERROR: context '$context' has no node-group=app nodes" >&2
    exit 1
  fi
  if [ "${testing_count:-0}" -lt 1 ]; then
    echo "ERROR: context '$context' has no node-group=testing nodes" >&2
    exit 1
  fi
  if ! KUBECONFIG="$path" kubectl --context="$context" get nodes -l node-group=testing -o json | jq -e '.items[] | select((.spec.taints // [])[]? | .key == "workload" and .value == "benchmark" and .effect == "NoSchedule")' >/dev/null; then
    echo "ERROR: context '$context' testing nodes are missing workload=benchmark:NoSchedule taint" >&2
    exit 1
  fi

  mkdir -p "$HOME/.kube"
  if [ -f "$HOME/.kube/config" ]; then
    KUBECONFIG="$HOME/.kube/config:$path" kubectl config view --flatten > "$path.merged"
  else
    KUBECONFIG="$path" kubectl config view --flatten > "$path.merged"
  fi
  mv "$path.merged" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  echo "wrote kubeconfig for $expected_cluster: $path"
}

case "$mode" in
  sequential)
    expected_cluster="$(terraform -chdir=infra/terraform/vultr-experiment-sequential output -raw sequential_cluster_name)"
    write_kubeconfig infra/terraform/vultr-experiment-sequential sequential_kube_config benchmark "$expected_cluster"
    ;;
  parallel)
    mono_cluster="$(terraform -chdir=infra/terraform/vultr-experiment output -raw monolith_cluster_name)"
    msa_cluster="$(terraform -chdir=infra/terraform/vultr-experiment output -raw msa_cluster_name)"
    write_kubeconfig infra/terraform/vultr-experiment monolith_kube_config monolith "$mono_cluster"
    write_kubeconfig infra/terraform/vultr-experiment msa_kube_config msa "$msa_cluster"
    ;;
  *)
    echo "VULTR_MODE must be sequential or parallel" >&2
    exit 1
    ;;
esac

