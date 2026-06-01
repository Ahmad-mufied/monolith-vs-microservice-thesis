#!/usr/bin/env bash
set -euo pipefail

mode="${HETZNER_MODE:-sequential}"
mkdir -p env/kubeconfig

fetch_kubeconfig() {
  local stack="$1"
  local output_name="$2"
  local context="$3"
  local path="env/kubeconfig/${context}.yaml"
  local command

  command="$(terraform -chdir="$stack" output -raw "$output_name")"
  if [ -z "$command" ]; then
    echo "missing kubeconfig fetch command output: $stack $output_name" >&2
    return 1
  fi

  eval "$command" > "$path"
  chmod 600 "$path"
  KUBECONFIG="$path" kubectl config rename-context default "$context" >/dev/null 2>&1 || true
  KUBECONFIG="$path" kubectl --context="$context" get nodes
  mkdir -p "$HOME/.kube"
  if [ -f "$HOME/.kube/config" ]; then
    KUBECONFIG="$HOME/.kube/config:$path" kubectl config view --flatten > "$path.merged"
  else
    KUBECONFIG="$path" kubectl config view --flatten > "$path.merged"
  fi
  mv "$path.merged" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
  echo "wrote kubeconfig: $path"
  echo "merged context into: $HOME/.kube/config"
}

case "$mode" in
  sequential)
    fetch_kubeconfig infra/terraform/hetzner-experiment-sequential kubeconfig_fetch_command benchmark
    ;;
  parallel)
    fetch_kubeconfig infra/terraform/hetzner-experiment monolith_kubeconfig_fetch_command monolith
    fetch_kubeconfig infra/terraform/hetzner-experiment msa_kubeconfig_fetch_command msa
    ;;
  *)
    echo "HETZNER_MODE must be sequential or parallel" >&2
    exit 1
    ;;
esac
