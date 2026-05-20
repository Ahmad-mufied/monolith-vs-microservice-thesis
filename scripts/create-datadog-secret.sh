#!/usr/bin/env bash
set -euo pipefail

namespace="${DATADOG_NAMESPACE:-datadog}"
secret_name="${DATADOG_SECRET_NAME:-datadog-secret}"
site="${DATADOG_SITE:-datadoghq.com}"
app_key="${DATADOG_APP_KEY:-}"

if [[ -z "${DATADOG_API_KEY:-}" ]]; then
  echo "DATADOG_API_KEY must be set in the environment" >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

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

kubectl "${secret_args[@]}" | kubectl apply -f -

echo "Datadog Kubernetes secret created in namespace $namespace"
