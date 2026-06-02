#!/usr/bin/env bash
set -euo pipefail

SCALING_MODE="${SCALING_MODE:?SCALING_MODE is required (fixed|hpa)}"
EXECUTION_MODE="${EXECUTION_MODE:-parallel}"
ARCHITECTURE="${ARCHITECTURE:-}"

case "$SCALING_MODE" in
  fixed|hpa) ;;
  *) echo "ERROR: unsupported SCALING_MODE '$SCALING_MODE'" >&2; exit 1 ;;
esac

check_context_architecture() {
  local context="$1"
  local architecture="$2"
  local mono_hpa_present=0
  local msa_hpa_count=0
  local app_pods

  kubectl --context="$context" get nodes -l node-group=app >/dev/null
  kubectl --context="$context" get nodes -l node-group=testing >/dev/null

  if [ "$architecture" = "monolith" ]; then
    if kubectl --context="$context" get hpa monolith -n mono >/dev/null 2>&1; then
      mono_hpa_present=1
    fi
    if [ "$SCALING_MODE" = "hpa" ] && [ "$mono_hpa_present" -ne 1 ]; then
      echo "ERROR: expected monolith HPA in context '$context'" >&2
      exit 1
    fi
    if [ "$SCALING_MODE" = "fixed" ] && [ "$mono_hpa_present" -ne 0 ]; then
      echo "ERROR: found stale monolith HPA in fixed mode in context '$context'" >&2
      exit 1
    fi
    kubectl --context="$context" rollout status deployment/monolith -n mono --timeout=30s
    app_pods="$(kubectl --context="$context" get pods -n mono -l app=monolith -o json)"
  else
    msa_hpa_count="$(kubectl --context="$context" get hpa -n msa --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
    msa_hpa_count="${msa_hpa_count:-0}"
    if [ "$SCALING_MODE" = "hpa" ] && [ "$msa_hpa_count" -lt 4 ]; then
      echo "ERROR: expected at least 4 MSA HPAs in context '$context', found $msa_hpa_count" >&2
      exit 1
    fi
    if [ "$SCALING_MODE" = "fixed" ] && [ "$msa_hpa_count" -ne 0 ]; then
      echo "ERROR: found stale MSA HPAs in fixed mode in context '$context'" >&2
      exit 1
    fi
    for svc in auth-service item-service transaction-service api-gateway; do
      kubectl --context="$context" rollout status "deployment/${svc}" -n msa --timeout=30s
    done
    app_pods="$(kubectl --context="$context" get pods -n msa -o json)"
  fi

  if ! jq -e '.items[] | select(.spec.nodeSelector["node-group"] == "app" or (.spec.nodeName | length > 0))' >/dev/null <<<"$app_pods"; then
    echo "ERROR: unable to verify scheduled application pods in context '$context'" >&2
    exit 1
  fi
}

case "$EXECUTION_MODE" in
  parallel)
    check_context_architecture monolith monolith
    check_context_architecture msa microservices
    ;;
  sequential)
    case "$ARCHITECTURE" in
      monolith|microservices) ;;
      *) echo "ERROR: ARCHITECTURE must be monolith or microservices for sequential verification" >&2; exit 1 ;;
    esac
    check_context_architecture "${SEQUENTIAL_CONTEXT:-benchmark}" "$ARCHITECTURE"
    ;;
  *)
    echo "ERROR: unsupported EXECUTION_MODE '$EXECUTION_MODE'" >&2
    exit 1
    ;;
esac

echo "Live mode verification passed: execution_mode=$EXECUTION_MODE scaling_mode=$SCALING_MODE"

