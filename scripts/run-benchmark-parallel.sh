#!/usr/bin/env bash
# Run k6 benchmark jobs on both clusters simultaneously.
# Both jobs start within seconds of each other for aligned Datadog time-series.
set -euo pipefail

source scripts/lib/shared-env.sh

explicit_aws_region="${AWS_REGION:-}"
explicit_ecr_namespace="${ECR_NAMESPACE:-}"
explicit_s3_bucket="${S3_BUCKET:-}"

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

source scripts/lib/cloud-provider.sh
load_cloud_provider_env

if [ -n "$explicit_aws_region" ]; then
  AWS_REGION="$explicit_aws_region"
fi

if [ -n "$explicit_ecr_namespace" ]; then
  ECR_NAMESPACE="$explicit_ecr_namespace"
fi

if [ -n "$explicit_s3_bucket" ]; then
  S3_BUCKET="$explicit_s3_bucket"
fi

image_tag_env_file="$(resolve_image_tag_env_file || true)"
if [ -z "${IMAGE_TAG:-}" ] && [ -n "$image_tag_env_file" ]; then
  set -a
  source "$image_tag_env_file"
  set +a
fi

source scripts/lib/resource-configuration.sh
source scripts/lib/benchmark-preflight.sh

SCENARIO="${SCENARIO:?SCENARIO is required (login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items)}"
TARGET_RPS="${TARGET_RPS:?TARGET_RPS is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
ATTEMPT="${ATTEMPT:-attempt-01}"
SCALING_MODE="${SCALING_MODE:-fixed}"
K6_PROFILE="${K6_PROFILE:-steady}"
ALLOW_NONSTANDARD_SCALING_PROFILE="${ALLOW_NONSTANDARD_SCALING_PROFILE:-false}"
SKIP_BENCHMARK_PREFLIGHT="${SKIP_BENCHMARK_PREFLIGHT:-false}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
RENDER_ROOT="$(mktemp -d)"
INSPECTION_ROOT="$(mktemp -d)"

MONOLITH_NAMESPACE="benchmark"
MSA_NAMESPACE="benchmark"
MONOLITH_JOB="k6-benchmark-monolith"
MICROSERVICES_JOB="k6-benchmark-microservices"
MONOLITH_MANIFEST=""
MICROSERVICES_MANIFEST=""

cleanup() {
  rm -rf "$RENDER_ROOT"
  rm -rf "$INSPECTION_ROOT"
  rm -f "${mono_submit_result_file:-}" "${msa_submit_result_file:-}"
}
trap cleanup EXIT

S3_MONOLITH="s3://${S3_BUCKET}/experiments/${RUN_ID}/monolith/${SCENARIO}/${TARGET_RPS}rps/${ATTEMPT}"
S3_MICROSERVICES="s3://${S3_BUCKET}/experiments/${RUN_ID}/microservices/${SCENARIO}/${TARGET_RPS}rps/${ATTEMPT}"
S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"

echo "=== Parallel Benchmark Run ==="
echo "  scenario     : $SCENARIO"
echo "  target_rps   : $TARGET_RPS"
echo "  run_id       : $RUN_ID"
echo "  attempt      : $ATTEMPT"
echo "  scaling_mode : $SCALING_MODE"
echo "  k6_profile   : $K6_PROFILE"
echo "  duration     : $TEST_DURATION"
echo "  image_tag    : $IMAGE_TAG"
echo "  provider     : $CLOUD_PROVIDER"
echo "  report_s3_uri: $S3_RUN_URI"
echo ""

case "$ALLOW_NONSTANDARD_SCALING_PROFILE" in
  true|false) ;;
  *)
    echo "ERROR: invalid ALLOW_NONSTANDARD_SCALING_PROFILE value '$ALLOW_NONSTANDARD_SCALING_PROFILE' (expected: true|false)" >&2
    exit 1
    ;;
esac

case "$SKIP_BENCHMARK_PREFLIGHT" in
  true|false) ;;
  *)
    echo "ERROR: invalid SKIP_BENCHMARK_PREFLIGHT value '$SKIP_BENCHMARK_PREFLIGHT' (expected: true|false)" >&2
    exit 1
    ;;
esac

if [ "$ALLOW_NONSTANDARD_SCALING_PROFILE" != "true" ]; then
  case "$SCALING_MODE:$K6_PROFILE" in
    fixed:steady|fixed:ramp|fixed:smoke|hpa:hpa) ;;
    fixed:hpa)
      echo "ERROR: K6_PROFILE=hpa must not be used with SCALING_MODE=fixed. Set ALLOW_NONSTANDARD_SCALING_PROFILE=true only for a deliberate nonstandard experiment." >&2
      exit 1
      ;;
    hpa:steady|hpa:ramp|hpa:smoke)
      echo "ERROR: SCALING_MODE=hpa requires K6_PROFILE=hpa for the standard autoscaling experiment. Set ALLOW_NONSTANDARD_SCALING_PROFILE=true only for a deliberate nonstandard experiment." >&2
      exit 1
      ;;
  esac
fi

run_parallel_preflight() {
  local context_label="$1"
  local quiet="${2:-false}"

  if [ "$SKIP_BENCHMARK_PREFLIGHT" = "true" ]; then
    if [ "$quiet" != "true" ]; then
      echo "=== Benchmark Preflight ==="
      echo "  phase        : $context_label"
      echo "  status       : skipped (SKIP_BENCHMARK_PREFLIGHT=true)"
      echo ""
    fi
    return 0
  fi

  benchmark_preflight_or_die "$S3_BUCKET" "$context_label" "$quiet"
}

run_parallel_preflight "parallel benchmark bootstrap"

render_provider_manifests "$RENDER_ROOT"
MONOLITH_MANIFEST="$RENDER_ROOT/deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml"
MICROSERVICES_MANIFEST="$RENDER_ROOT/deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml"
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

# ─── Clean up previous jobs ───────────────────────────────────────────────────

kubectl --context=monolith delete job "$MONOLITH_JOB" -n "$MONOLITH_NAMESPACE" --ignore-not-found
kubectl --context=msa delete job "$MICROSERVICES_JOB" -n "$MSA_NAMESPACE" --ignore-not-found

# ─── Patch and apply both jobs simultaneously ─────────────────────────────────

patch_and_apply() {
  local context="$1"
  local manifest="$2"
  local s3_uri="$3"
  local architecture="$4"
  local resources_json
  local rendered_manifest
  local terraform_stack
  local cluster_name
  local provider_region
  local infra_json

  resources_json="$(resources_configuration_json "$architecture" "$SCALING_MODE")"
  terraform_stack="$(provider_parallel_stack_name)"
  cluster_name="$(provider_default_cluster_name "$architecture")"
  provider_region="${VULTR_REGION:-$AWS_REGION}"
  infra_json="{\"provider\":\"${CLOUD_PROVIDER}\",\"region\":\"${provider_region}\",\"cluster\":\"${cluster_name}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\",\"execution_mode\":\"parallel\"}"
  rendered_manifest="$(
    sed \
      -e "/name: K6_SCRIPT/{n; s|value:.*|value: ${SCENARIO}.js|}" \
      -e "/name: K6_PROFILE/{n; s|value:.*|value: ${K6_PROFILE}|}" \
      -e "/name: ARCHITECTURE/{n; s|value:.*|value: ${architecture}|}" \
      -e "/name: EXECUTION_MODE/{n; s|value:.*|value: parallel|}" \
      -e "/name: TERRAFORM_STACK/{n; s|value:.*|value: ${terraform_stack}|}" \
      -e "/name: CLUSTER_NAME/{n; s|value:.*|value: ${cluster_name}|}" \
      -e "/name: SCENARIO_NAME/{n; s|value:.*|value: ${SCENARIO}|}" \
      -e "/name: TARGET_RPS/{n; s|value:.*|value: \"${TARGET_RPS}\"|}" \
      -e "/name: RUN_ID/{n; s|value:.*|value: ${RUN_ID}|}" \
      -e "/name: ATTEMPT/{n; s|value:.*|value: ${ATTEMPT}|}" \
      -e "/name: TEST_DURATION/{n; s|value:.*|value: ${TEST_DURATION}|}" \
      -e "/name: DATADOG_ENABLED/{n; s|value:.*|value: \"${DATADOG_ENABLED}\"|}" \
      -e "/name: DATADOG_ENV/{n; s|value:.*|value: ${DATADOG_ENV}|}" \
      -e "/name: S3_URI/{n; s|value:.*|value: ${s3_uri}|}" \
      -e "/name: INFRA_CONFIGURATION_JSON/{n; s|value:.*|value: '${infra_json}'|}" \
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

fetch_s3_artifact() {
  local s3_uri="$1"
  local artifact_name="$2"

  aws s3 cp "${s3_uri%/}/${artifact_name}" - 2>/dev/null || true
}

job_pod_state_json() {
  local context="$1"
  local namespace="$2"
  local job_name="$3"
  local pods_json

  pods_json="$(
    kubectl --context="$context" get pods -n "$namespace" -l "job-name=${job_name}" -o json 2>/dev/null || true
  )"

  if [ -z "$pods_json" ]; then
    jq -cn '{pod_name:null,pod_phase:null,container_exit_code:null,container_reason:null}'
    return 0
  fi

  jq -c '
    if (.items | length) == 0 then
      {pod_name:null,pod_phase:null,container_exit_code:null,container_reason:null}
    else
      {
        pod_name: (.items[0].metadata.name // null),
        pod_phase: (.items[0].status.phase // null),
        container_exit_code: (.items[0].status.containerStatuses[0].state.terminated.exitCode // null),
        container_reason: (
          .items[0].status.containerStatuses[0].state.terminated.reason //
          .items[0].status.containerStatuses[0].state.waiting.reason //
          null
        )
      }
    end
  ' <<<"$pods_json"
}

job_log_tail() {
  local context="$1"
  local namespace="$2"
  local job_name="$3"

  kubectl --context="$context" logs "job/${job_name}" -n "$namespace" --tail=40 2>/dev/null || true
}

extract_result_status_from_logs() {
  local logs="$1"

  sed -n 's/^RESULT_STATUS_JSON=//p' <<<"$logs" | tail -n 1
}

threshold_status_from_json() {
  local thresholds_json="$1"

  if [ -z "$thresholds_json" ]; then
    printf 'UNKNOWN'
    return 0
  fi

  if jq -e '([.. | objects | select(has("ok")) | .ok] | length) == 0' >/dev/null 2>&1 <<<"$thresholds_json"; then
    printf 'UNKNOWN'
    return 0
  fi

  if jq -e '[.. | objects | select(has("ok")) | .ok] | any(. == false)' >/dev/null 2>&1 <<<"$thresholds_json"; then
    printf 'OVERLOAD'
    return 0
  fi

  if jq -e '[.. | objects | select(has("ok")) | .ok] | all(. == true)' >/dev/null 2>&1 <<<"$thresholds_json"; then
    printf 'PASS'
    return 0
  fi

  printf 'UNKNOWN'
}

inspect_architecture_result() {
  local context="$1"
  local namespace="$2"
  local job_name="$3"
  local label="$4"
  local s3_uri="$5"
  local terminal_state="$6"
  local output_file="$7"

  local pod_state_json
  local logs_tail
  local result_status_json
  local result_status_source="missing"
  local thresholds_json
  local thresholds_source="missing"
  local threshold_class="UNKNOWN"
  local final_class="$terminal_state"
  local reason=""
  local log_excerpt=""

  pod_state_json="$(job_pod_state_json "$context" "$namespace" "$job_name")"
  logs_tail="$(job_log_tail "$context" "$namespace" "$job_name")"
  log_excerpt="$(printf '%s' "$logs_tail" | tail -n 10)"

  result_status_json="$(fetch_s3_artifact "$s3_uri" result-status.json)"
  if [ -n "$result_status_json" ] && jq -e . >/dev/null 2>&1 <<<"$result_status_json"; then
    result_status_source="s3"
  else
    result_status_json="$(extract_result_status_from_logs "$logs_tail")"
    if [ -n "$result_status_json" ] && jq -e . >/dev/null 2>&1 <<<"$result_status_json"; then
      result_status_source="logs"
    else
      result_status_json=''
    fi
  fi

  thresholds_json="$(fetch_s3_artifact "$s3_uri" thresholds.json)"
  if [ -n "$thresholds_json" ] && jq -e . >/dev/null 2>&1 <<<"$thresholds_json"; then
    thresholds_source="s3"
    threshold_class="$(threshold_status_from_json "$thresholds_json")"
  else
    thresholds_json=''
  fi

  if [ "$terminal_state" = "TIMEOUT" ]; then
    final_class="TIMEOUT"
    reason="benchmark job exceeded 60m orchestration timeout"
  elif [ -n "$result_status_json" ]; then
    local s3_exit_code
    local k6_exit_code
    local artifacts_generated
    local thresholds_file_present
    local summary_file_present
    local classification_hint

    s3_exit_code="$(jq -r '.s3_exit_code // "null"' <<<"$result_status_json")"
    k6_exit_code="$(jq -r '.k6_exit_code // "null"' <<<"$result_status_json")"
    artifacts_generated="$(jq -r '.artifacts_generated // false' <<<"$result_status_json")"
    thresholds_file_present="$(jq -r '.thresholds_file_present // false' <<<"$result_status_json")"
    summary_file_present="$(jq -r '.summary_file_present // false' <<<"$result_status_json")"
    classification_hint="$(jq -r '.classification_hint // "unknown"' <<<"$result_status_json")"

    if [ "$s3_exit_code" != "null" ] && [ "$s3_exit_code" != "0" ]; then
      final_class="INVALID"
      reason="S3 upload failed after k6 execution"
    elif [ "$classification_hint" = "runtime_failed" ] || { [ "$k6_exit_code" != "null" ] && [ "$k6_exit_code" != "0" ] && [ "$k6_exit_code" != "99" ]; }; then
      final_class="INVALID"
      reason="k6 exited with a non-threshold runtime failure (exit code: ${k6_exit_code})"
    elif [ "$threshold_class" = "OVERLOAD" ]; then
      final_class="OVERLOAD"
      reason="k6 completed but one or more thresholds failed"
    elif [ "$k6_exit_code" = "0" ] && [ "$threshold_class" = "PASS" ]; then
      final_class="PASS"
      reason="k6 completed and all thresholds passed"
    elif [ "$classification_hint" = "threshold_failed" ] && [ "$thresholds_file_present" = "true" ]; then
      final_class="OVERLOAD"
      reason="k6 reported threshold failure but thresholds.json could not be re-read from S3"
    elif [ "$k6_exit_code" = "0" ] && [ "$artifacts_generated" = "true" ] && [ "$summary_file_present" = "true" ]; then
      final_class="INVALID"
      reason="k6 exited successfully but required threshold artifacts could not be verified"
    else
      final_class="INVALID"
      reason="job failed before benchmark artifacts were fully produced"
    fi
  elif [ "$threshold_class" = "OVERLOAD" ]; then
    final_class="OVERLOAD"
    reason="threshold artifacts show benchmark overload"
  elif [ "$terminal_state" = "COMPLETE" ] && [ "$threshold_class" = "PASS" ]; then
    final_class="PASS"
    reason="threshold artifacts show all benchmark thresholds passed"
  else
    final_class="INVALID"
    reason="job terminated without usable benchmark result artifacts"
  fi

  jq -n \
    --arg label "$label" \
    --arg terminal_state "$terminal_state" \
    --arg final_class "$final_class" \
    --arg reason "$reason" \
    --arg s3_uri "$s3_uri" \
    --arg result_status_source "$result_status_source" \
    --arg thresholds_source "$thresholds_source" \
    --arg threshold_class "$threshold_class" \
    --arg logs_hint "$log_excerpt" \
    --argjson pod_state "$pod_state_json" \
    --argjson result_status "$(if [ -n "$result_status_json" ]; then printf '%s' "$result_status_json"; else printf 'null'; fi)" \
    '{
      label: $label,
      terminal_state: $terminal_state,
      final_class: $final_class,
      reason: $reason,
      s3_uri: $s3_uri,
      pod_state: $pod_state,
      result_status_source: $result_status_source,
      result_status: $result_status,
      thresholds_source: $thresholds_source,
      threshold_class: $threshold_class,
      logs_hint: $logs_hint
    }' >"$output_file"
}

print_architecture_summary() {
  local result_file="$1"
  local context="$2"
  local namespace="$3"
  local job_name="$4"

  local label final_class reason s3_uri pod_name pod_phase exit_code container_reason thresholds_source result_status_source
  local logs_hint

  label="$(jq -r '.label' "$result_file")"
  final_class="$(jq -r '.final_class' "$result_file")"
  reason="$(jq -r '.reason' "$result_file")"
  s3_uri="$(jq -r '.s3_uri' "$result_file")"
  pod_name="$(jq -r '.pod_state.pod_name // "n/a"' "$result_file")"
  pod_phase="$(jq -r '.pod_state.pod_phase // "n/a"' "$result_file")"
  exit_code="$(jq -r '.pod_state.container_exit_code // "n/a"' "$result_file")"
  container_reason="$(jq -r '.pod_state.container_reason // "n/a"' "$result_file")"
  thresholds_source="$(jq -r '.thresholds_source' "$result_file")"
  result_status_source="$(jq -r '.result_status_source' "$result_file")"
  logs_hint="$(jq -r '.logs_hint // ""' "$result_file")"

  echo "${label}: ${final_class}"
  echo "  reason               : ${reason}"
  echo "  kubernetes job state : $(jq -r '.terminal_state' "$result_file")"
  echo "  pod                  : ${pod_name}"
  echo "  pod phase            : ${pod_phase}"
  echo "  container exit code  : ${exit_code}"
  echo "  container reason     : ${container_reason}"
  echo "  result-status source : ${result_status_source}"
  echo "  thresholds source    : ${thresholds_source}"
  echo "  S3 URI               : ${s3_uri}"

  if [ "$final_class" = "INVALID" ] || [ "$final_class" = "TIMEOUT" ]; then
    echo "  inspect logs         : kubectl --context=${context} logs job/${job_name} -n ${namespace}"
    if [ -n "$logs_hint" ]; then
      echo "  log excerpt          :"
      while IFS= read -r line; do
        echo "    ${line}"
      done <<<"$logs_hint"
    fi
  fi
}

echo "Starting both k6 jobs simultaneously..."
mono_submit_result_file="$(mktemp)"
msa_submit_result_file="$(mktemp)"
rm -f "$mono_submit_result_file" "$msa_submit_result_file"

run_submission "$mono_submit_result_file" monolith \
  "$MONOLITH_MANIFEST" \
  "$S3_MONOLITH" \
  monolith &
mono_submit_pid=$!

run_submission "$msa_submit_result_file" msa \
  "$MICROSERVICES_MANIFEST" \
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
if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ] && ! benchmark_preflight_check "$S3_BUCKET" "parallel benchmark result inspection" "true"; then
  echo "ERROR: benchmark jobs finished but local AWS or EKS auth expired before result inspection." >&2
  echo "Fix: refresh auth, verify S3 artifacts for this attempt, then rerun the inspection workflow or the benchmark case if needed." >&2
  exit 1
fi

mono_result_file="$INSPECTION_ROOT/monolith-result.json"
msa_result_file="$INSPECTION_ROOT/microservices-result.json"

inspect_architecture_result monolith "$MONOLITH_NAMESPACE" "$MONOLITH_JOB" "monolith" "$S3_MONOLITH" "$MONO_STATE" "$mono_result_file"
inspect_architecture_result msa "$MSA_NAMESPACE" "$MICROSERVICES_JOB" "microservices" "$S3_MICROSERVICES" "$MICROSERVICES_STATE" "$msa_result_file"

echo "=== Results ==="
echo "Report generator source:"
echo "  $S3_RUN_URI"
echo ""
print_architecture_summary "$mono_result_file" monolith "$MONOLITH_NAMESPACE" "$MONOLITH_JOB"
echo ""
print_architecture_summary "$msa_result_file" msa "$MSA_NAMESPACE" "$MICROSERVICES_JOB"

mono_final_class="$(jq -r '.final_class' "$mono_result_file")"
msa_final_class="$(jq -r '.final_class' "$msa_result_file")"

if [ "$mono_final_class" = "PASS" ] && [ "$msa_final_class" = "PASS" ]; then
  echo ""
  echo "Both jobs completed successfully."
  echo "Report generator source:"
  echo "  $S3_RUN_URI"
  exit 0
fi

echo ""
echo "One or more jobs did not finish with PASS."
echo "Report generator source:"
echo "  $S3_RUN_URI"
exit 1
