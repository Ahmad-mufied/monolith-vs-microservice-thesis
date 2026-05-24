#!/usr/bin/env bash
set -euo pipefail

CONTEXT="${1:?kubectl context is required}"
K8S="kubectl --context=${CONTEXT}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml}"
METRICS_SERVER_INSECURE_KUBELET="${METRICS_SERVER_INSECURE_KUBELET:-false}"

echo "Installing metrics-server on context: ${CONTEXT} (version: ${METRICS_SERVER_VERSION})"
$K8S apply -f "$METRICS_SERVER_MANIFEST_URL"

base_args_json='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/args",
    "value": [
      "--cert-dir=/tmp",
      "--secure-port=10250",
      "--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP",
      "--kubelet-use-node-status-port",
      "--metric-resolution=15s"
    ]
  }
]'

$K8S patch deployment metrics-server -n kube-system --type=json -p="$base_args_json"

case "${METRICS_SERVER_INSECURE_KUBELET,,}" in
  true|1|yes|on)
    echo "Enabling metrics-server kubelet insecure TLS mode"
    $K8S patch deployment metrics-server -n kube-system --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/args/-",
        "value": "--kubelet-insecure-tls"
      }
    ]'
    ;;
  *)
    echo "Keeping metrics-server kubelet TLS verification enabled"
    ;;
esac

$K8S rollout status deployment/metrics-server -n kube-system --timeout=300s
echo "metrics-server ready on context: ${CONTEXT}"
