#!/usr/bin/env bash
set -euo pipefail

CONTEXT="${1:?kubectl context is required}"
K8S="kubectl --context=${CONTEXT}"
METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"

echo "Installing metrics-server on context: ${CONTEXT}"
$K8S apply -f "$METRICS_SERVER_MANIFEST_URL"

$K8S patch deployment metrics-server -n kube-system --type=json -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args",
    "value": [
      "--cert-dir=/tmp",
      "--secure-port=10250",
      "--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP",
      "--kubelet-use-node-status-port",
      "--metric-resolution=15s",
      "--kubelet-insecure-tls"
    ]
  }
]'

$K8S rollout status deployment/metrics-server -n kube-system --timeout=300s
echo "metrics-server ready on context: ${CONTEXT}"
