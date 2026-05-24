#!/usr/bin/env bash
# Run k6 benchmark jobs on both clusters simultaneously.
# Both jobs start within seconds of each other for aligned Datadog time-series.
set -euo pipefail

SCENARIO="${SCENARIO:?SCENARIO is required (login|create-transaction|enriched-transactions|mixed-workload)}"
TARGET_RPS="${TARGET_RPS:?TARGET_RPS is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
ATTEMPT="${ATTEMPT:-attempt-01}"
SCALING_MODE="${SCALING_MODE:-fixed}"
K6_PROFILE="${K6_PROFILE:-steady}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"

MONOLITH_NAMESPACE="benchmark"
MSA_NAMESPACE="benchmark"
MONOLITH_JOB="k6-benchmark-monolith"
MICROSERVICES_JOB="k6-benchmark-microservices"

S3_MONOLITH="s3://${S3_BUCKET}/experiments/${RUN_ID}/monolith/${SCENARIO}/${TARGET_RPS}rps/${ATTEMPT}"
S3_MICROSERVICES="s3://${S3_BUCKET}/experiments/${RUN_ID}/microservices/${SCENARIO}/${TARGET_RPS}rps/${ATTEMPT}"

echo "=== Parallel Benchmark Run ==="
echo "  scenario     : $SCENARIO"
echo "  target_rps   : $TARGET_RPS"
echo "  run_id       : $RUN_ID"
echo "  attempt      : $ATTEMPT"
echo "  scaling_mode : $SCALING_MODE"
echo "  k6_profile   : $K6_PROFILE"
echo "  duration     : $TEST_DURATION"
echo ""

# ─── Validate contexts ────────────────────────────────────────────────────────

kubectl --context=monolith get nodes > /dev/null 2>&1 || { echo "ERROR: monolith context not available"; exit 1; }
kubectl --context=msa get nodes > /dev/null 2>&1 || { echo "ERROR: msa context not available"; exit 1; }

# ─── Clean up previous jobs ───────────────────────────────────────────────────

kubectl --context=monolith delete job "$MONOLITH_JOB" -n "$MONOLITH_NAMESPACE" --ignore-not-found
kubectl --context=msa delete job "$MICROSERVICES_JOB" -n "$MSA_NAMESPACE" --ignore-not-found

# ─── Patch and apply both jobs simultaneously ─────────────────────────────────

resources_configuration_json() {
  local architecture="$1"
  local scaling_mode="$2"

  if [ "$architecture" = "monolith" ]; then
    if [ "$scaling_mode" = "hpa" ]; then
      printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"min_replicas":1,"max_replicas":4,"target_cpu_utilization":70}'
      return 0
    fi

    printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"replica_count":1}'
    return 0
  fi

  if [ "$scaling_mode" = "hpa" ]; then
    printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"4000m","memory":"4096Mi"},"services":{"api-gateway":{"cpu_request":"100m","cpu_limit":"250m","memory_request":"256Mi","memory_limit":"384Mi","min_replicas":1,"max_replicas":9,"target_cpu_utilization":70},"auth-service":{"cpu_request":"250m","cpu_limit":"1000m","memory_request":"256Mi","memory_limit":"768Mi","min_replicas":1,"max_replicas":3,"target_cpu_utilization":70},"item-service":{"cpu_request":"100m","cpu_limit":"250m","memory_request":"256Mi","memory_limit":"384Mi","min_replicas":1,"max_replicas":9,"target_cpu_utilization":70},"transaction-service":{"cpu_request":"150m","cpu_limit":"500m","memory_request":"256Mi","memory_limit":"512Mi","min_replicas":1,"max_replicas":5,"target_cpu_utilization":70}}}'
    return 0
  fi

  printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"4000m","memory":"4096Mi"},"services":{"api-gateway":{"cpu_request":"100m","cpu_limit":"250m","memory_request":"256Mi","memory_limit":"384Mi","replica_count":1},"auth-service":{"cpu_request":"250m","cpu_limit":"1000m","memory_request":"256Mi","memory_limit":"768Mi","replica_count":1},"item-service":{"cpu_request":"100m","cpu_limit":"250m","memory_request":"256Mi","memory_limit":"384Mi","replica_count":1},"transaction-service":{"cpu_request":"150m","cpu_limit":"500m","memory_request":"256Mi","memory_limit":"512Mi","replica_count":1}}}'
}

patch_and_apply() {
  local context="$1"
  local manifest="$2"
  local s3_uri="$3"
  local architecture="$4"
  local resources_json
  local rendered_manifest

  resources_json="$(resources_configuration_json "$architecture" "$SCALING_MODE")"
  rendered_manifest="$(
    sed \
      -e "/name: K6_SCRIPT/{n; s|value:.*|value: ${SCENARIO}.js|}" \
      -e "/name: K6_PROFILE/{n; s|value:.*|value: ${K6_PROFILE}|}" \
      -e "/name: ARCHITECTURE/{n; s|value:.*|value: ${architecture}|}" \
      -e "/name: SCENARIO_NAME/{n; s|value:.*|value: ${SCENARIO}|}" \
      -e "/name: TARGET_RPS/{n; s|value:.*|value: \"${TARGET_RPS}\"|}" \
      -e "/name: RUN_ID/{n; s|value:.*|value: ${RUN_ID}|}" \
      -e "/name: ATTEMPT/{n; s|value:.*|value: ${ATTEMPT}|}" \
      -e "/name: TEST_DURATION/{n; s|value:.*|value: ${TEST_DURATION}|}" \
      -e "/name: DATADOG_ENABLED/{n; s|value:.*|value: \"${DATADOG_ENABLED}\"|}" \
      -e "/name: DATADOG_ENV/{n; s|value:.*|value: ${DATADOG_ENV}|}" \
      -e "/name: S3_URI/{n; s|value:.*|value: ${s3_uri}|}" \
      -e "/name: RESOURCES_CONFIGURATION_JSON/{n; s|value:.*|value: '${resources_json}'|}" \
      "$manifest"
  )"

  if grep -Eq 'REPLACE_WITH_ECR_IMAGE|replace-me' <<<"$rendered_manifest"; then
    echo "ERROR: benchmark manifest still contains unresolved placeholders after patching: $manifest" >&2
    return 1
  fi

  kubectl --context="$context" apply -f - <<EOF
$rendered_manifest
EOF
}

run_submission() {
  local result_file="$1"
  shift

  if patch_and_apply "$@"; then
    printf 'SUCCESS\n' >"$result_file"
  else
    printf 'FAILED\n' >"$result_file"
    return 1
  fi
}

echo "Starting both k6 jobs simultaneously..."
mono_submit_result_file="$(mktemp)"
msa_submit_result_file="$(mktemp)"
rm -f "$mono_submit_result_file" "$msa_submit_result_file"
trap 'rm -f "$mono_submit_result_file" "$msa_submit_result_file"' EXIT

run_submission "$mono_submit_result_file" monolith \
  deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml \
  "$S3_MONOLITH" \
  monolith &
mono_submit_pid=$!

run_submission "$msa_submit_result_file" msa \
  deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml \
  "$S3_MICROSERVICES" \
  microservices &
msa_submit_pid=$!

while true; do
  if [[ -f "$mono_submit_result_file" ]]; then
    mono_submit_result="$(<"$mono_submit_result_file")"
    if [[ "$mono_submit_result" != "SUCCESS" ]]; then
      echo "ERROR: monolith benchmark job submission failed" >&2
      kill "$msa_submit_pid" 2>/dev/null || true
      wait "$msa_submit_pid" 2>/dev/null || true
      exit 1
    fi
  fi

  if [[ -f "$msa_submit_result_file" ]]; then
    msa_submit_result="$(<"$msa_submit_result_file")"
    if [[ "$msa_submit_result" != "SUCCESS" ]]; then
      echo "ERROR: microservices benchmark job submission failed" >&2
      kill "$mono_submit_pid" 2>/dev/null || true
      wait "$mono_submit_pid" 2>/dev/null || true
      exit 1
    fi
  fi

  if [[ -f "$mono_submit_result_file" && -f "$msa_submit_result_file" ]]; then
    break
  fi

  sleep 1
done

wait "$mono_submit_pid"
wait "$msa_submit_pid"
echo "Both jobs submitted."

# ─── Monitor both jobs ────────────────────────────────────────────────────────

echo ""
echo "Waiting for both jobs to complete (timeout: 60m)..."
monitor_timeout_seconds=$((60 * 60))
progress_interval_seconds=15
monitor_start_epoch="$(date +%s)"

job_progress_line() {
  local context="$1"
  local namespace="$2"
  local job_name="$3"
  local label="$4"
  local job_summary pod_summary

  job_summary="$(
    kubectl --context="$context" get job "$job_name" -n "$namespace" \
      -o jsonpath='{.status.active}{"|"}{.status.succeeded}{"|"}{.status.failed}' 2>/dev/null || true
  )"
  pod_summary="$(
    kubectl --context="$context" get pods -n "$namespace" -l job-name="$job_name" \
      -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.status.phase}{" "}{end}' 2>/dev/null || true
  )"

  if [ -z "$job_summary" ]; then
    printf '  - %s : missing job object\n' "$label"
    return 0
  fi

  IFS='|' read -r active_count succeeded_count failed_count <<EOF
$job_summary
EOF
  active_count="${active_count:-0}"
  succeeded_count="${succeeded_count:-0}"
  failed_count="${failed_count:-0}"
  pod_summary="${pod_summary:-no-pod-yet}"

  printf '  - %s : active=%s succeeded=%s failed=%s pods=[%s]\n' \
    "$label" \
    "$active_count" \
    "$succeeded_count" \
    "$failed_count" \
    "$pod_summary"
}

job_terminal_state() {
  local context="$1"
  local namespace="$2"
  local job_name="$3"
  local succeeded_count failed_count

  succeeded_count="$(
    kubectl --context="$context" get job "$job_name" -n "$namespace" \
      -o jsonpath='{.status.succeeded}' 2>/dev/null || true
  )"
  failed_count="$(
    kubectl --context="$context" get job "$job_name" -n "$namespace" \
      -o jsonpath='{.status.failed}' 2>/dev/null || true
  )"

  succeeded_count="${succeeded_count:-0}"
  failed_count="${failed_count:-0}"

  if [ "$succeeded_count" -ge 1 ]; then
    printf 'COMPLETE'
    return 0
  fi

  if [ "$failed_count" -ge 1 ]; then
    printf 'FAILED'
    return 0
  fi

  printf 'RUNNING'
}

MONO_STATE="RUNNING"
MICROSERVICES_STATE="RUNNING"
last_progress_epoch=0

while true; do
  now_epoch="$(date +%s)"
  elapsed_seconds=$((now_epoch - monitor_start_epoch))

  MONO_STATE="$(job_terminal_state monolith "$MONOLITH_NAMESPACE" "$MONOLITH_JOB")"
  MICROSERVICES_STATE="$(job_terminal_state msa "$MSA_NAMESPACE" "$MICROSERVICES_JOB")"

  if [ "$elapsed_seconds" -eq 0 ] || [ $((now_epoch - last_progress_epoch)) -ge "$progress_interval_seconds" ]; then
    printf '[progress] elapsed=%ss\n' "$elapsed_seconds"
    job_progress_line monolith "$MONOLITH_NAMESPACE" "$MONOLITH_JOB" "monolith"
    job_progress_line msa "$MSA_NAMESPACE" "$MICROSERVICES_JOB" "microservices"
    last_progress_epoch="$now_epoch"
  fi

  if [ "$MONO_STATE" != "RUNNING" ] && [ "$MICROSERVICES_STATE" != "RUNNING" ]; then
    break
  fi

  if [ "$elapsed_seconds" -ge "$monitor_timeout_seconds" ]; then
    if [ "$MONO_STATE" = "RUNNING" ]; then
      MONO_STATE="TIMEOUT"
    fi
    if [ "$MICROSERVICES_STATE" = "RUNNING" ]; then
      MICROSERVICES_STATE="TIMEOUT"
    fi
    break
  fi

  sleep 5
done

echo ""
echo "=== Results ==="
echo "  monolith job : $MONO_STATE"
echo "  microservices job : $MICROSERVICES_STATE"
echo ""
echo "  monolith S3  : $S3_MONOLITH"
echo "  microservices S3 : $S3_MICROSERVICES"

if [ "$MONO_STATE" != "COMPLETE" ] || [ "$MICROSERVICES_STATE" != "COMPLETE" ]; then
  echo ""
  echo "One or more jobs failed. Check logs:"
  echo "  kubectl --context=monolith logs job/$MONOLITH_JOB -n $MONOLITH_NAMESPACE"
  echo "  kubectl --context=msa logs job/$MICROSERVICES_JOB -n $MSA_NAMESPACE"
  exit 1
fi

echo ""
echo "Both jobs completed successfully."
