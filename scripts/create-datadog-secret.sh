#!/usr/bin/env bash
set -euo pipefail

namespace="${DATADOG_NAMESPACE:-datadog}"
secret_name="${DATADOG_SECRET_NAME:-datadog-secret}"
site="${DATADOG_SITE:-datadoghq.com}"
app_key="${DATADOG_APP_KEY:-}"
kube_context="${KUBE_CONTEXT:-}"

if [[ -z "${DATADOG_API_KEY:-}" && -f env/datadog.eks.env ]]; then
  set -a
  source env/datadog.eks.env
  set +a
  site="${DATADOG_SITE:-$site}"
fi

if [[ -z "${DATADOG_API_KEY:-}" ]]; then
  echo "DATADOG_API_KEY must be set in the environment" >&2
  exit 1
fi

context_args=()
if [[ -n "$kube_context" ]]; then
  context_args=(--context="$kube_context")
fi

kubectl "${context_args[@]}" create namespace "$namespace" --dry-run=client -o yaml \
  | kubectl "${context_args[@]}" apply -f -

secret_args=(
  create secret generic "$secret_name"
  --namespace "$namespace"
  --from-literal=api-key="$DATADOG_API_KEY"
  --from-literal=site="$site"
  --dry-run=client
  -o yaml
)

if [[ -n "$app_key" ]]; then
  secret_args+=(--from-literal=app-key="$app_key")
fi

kubectl "${context_args[@]}" "${secret_args[@]}" | kubectl "${context_args[@]}" apply -f -

echo "Datadog Kubernetes secret created in namespace $namespace${kube_context:+ (context: $kube_context)}"
