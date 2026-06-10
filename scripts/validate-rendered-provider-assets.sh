#!/usr/bin/env bash
set -euo pipefail

provider="${1:?provider is required}"
render_root="${2:?render root is required}"

if [ ! -d "$render_root/deployments/k8s" ]; then
  echo "ERROR: rendered root is missing deployments/k8s: $render_root" >&2
  exit 1
fi

case "$provider" in
  vultr|aws) ;;
  *) echo "ERROR: unsupported provider '$provider'" >&2; exit 1 ;;
esac

if rg -n -g '!**/*example*' 'replace-me\.dkr\.ecr|amazonaws\.com/skripsi' "$render_root/deployments/k8s" >/tmp/render-provider-placeholders.txt; then
  cat /tmp/render-provider-placeholders.txt >&2
  echo "ERROR: rendered manifests still contain ECR placeholders" >&2
  rm -f /tmp/render-provider-placeholders.txt
  exit 1
fi
rm -f /tmp/render-provider-placeholders.txt

if [ "$provider" = "vultr" ]; then
  if rg -n '"provider":"(aws|eks)"|provider: (aws|eks)' "$render_root/deployments/k8s" >/tmp/render-provider-stale.txt; then
    cat /tmp/render-provider-stale.txt >&2
    echo "ERROR: rendered Vultr manifests contain stale provider metadata" >&2
    rm -f /tmp/render-provider-stale.txt
    exit 1
  fi
  if ! rg -n 'docker\.io/.+/(monolith|api-gateway|auth-service|item-service|transaction-service|seed-runner|k6-runner):' "$render_root/deployments/k8s" >/dev/null; then
    echo "ERROR: rendered Vultr manifests do not contain Docker Hub image references" >&2
    exit 1
  fi
  if find "$render_root/deployments/k8s/cloud" -path '*/overlays/fixed/*hpa*.yaml' -print | grep -q .; then
    echo "ERROR: fixed overlay unexpectedly contains HPA manifests" >&2
    exit 1
  fi
  for expected in \
    "$render_root/deployments/k8s/cloud/monolith/overlays/hpa/hpa.yaml" \
    "$render_root/deployments/k8s/cloud/microservices/overlays/hpa/api-gateway-hpa.yaml" \
    "$render_root/deployments/k8s/cloud/microservices/overlays/hpa/auth-service-hpa.yaml" \
    "$render_root/deployments/k8s/cloud/microservices/overlays/hpa/item-service-hpa.yaml" \
    "$render_root/deployments/k8s/cloud/microservices/overlays/hpa/transaction-service-hpa.yaml"; do
    [ -f "$expected" ] || { echo "ERROR: missing expected HPA manifest: $expected" >&2; exit 1; }
  done
fi
