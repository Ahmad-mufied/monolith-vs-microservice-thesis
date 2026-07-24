#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$K6_ROOT/.." && pwd)"

K6_SCRIPT="${K6_SCRIPT:-smoke.js}"
RESULT_DIR="${RESULT_DIR:-$REPO_ROOT/tmp/k6-results}"
SUMMARY_PATH="${SUMMARY_PATH:-$RESULT_DIR/summary.json}"
RAW_PATH="${RAW_PATH:-$RESULT_DIR/raw.json}"
STDOUT_PATH="${STDOUT_PATH:-$RESULT_DIR/stdout.log}"
METADATA_PATH="${METADATA_PATH:-$RESULT_DIR/metadata.json}"
METADATA_PARTIAL_PATH="${METADATA_PARTIAL_PATH:-$RESULT_DIR/metadata.partial.json}"
K6_OPTIONS_PATH="${K6_OPTIONS_PATH:-$RESULT_DIR/k6-options.json}"
THRESHOLDS_PATH="${THRESHOLDS_PATH:-$RESULT_DIR/thresholds.json}"
DATADOG_TIME_WINDOW_PATH="${DATADOG_TIME_WINDOW_PATH:-$RESULT_DIR/datadog-time-window.json}"
RESULT_STATUS_PATH="${RESULT_STATUS_PATH:-$RESULT_DIR/result-status.json}"
STATUS_SUMMARY_PATH="${STATUS_SUMMARY_PATH:-$RESULT_DIR/status-summary.json}"

export SUMMARY_PATH
export METADATA_PARTIAL_PATH
export K6_OPTIONS_PATH
export THRESHOLDS_PATH

mkdir -p "$RESULT_DIR"

json_env_or() {
  local name="$1"
  local fallback="$2"
  local raw="${!name:-}"

  if [ -z "$raw" ]; then
    printf '%s' "$fallback"
    return 0
  fi

  jq -cn --arg raw "$raw" '$raw | fromjson'
}

TARGET_RPS_VALUE="${TARGET_RPS:-0}"
PRE_ALLOCATED_VUS_VALUE="${PRE_ALLOCATED_VUS:-0}"
MAX_VUS_VALUE="${MAX_VUS:-0}"
TEST_DURATION_VALUE="${TEST_DURATION:-1m}"
TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TIME_WINDOW_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DATADOG_ENABLED_VALUE="${DATADOG_ENABLED:-false}"
DATADOG_ENV_VALUE="${DATADOG_ENV:-${DD_ENV:-development}}"
K6_STATSD_ADDR_VALUE="${K6_STATSD_ADDR:-127.0.0.1:8125}"
K6_STATSD_NAMESPACE_VALUE="${K6_STATSD_NAMESPACE:-k6}"
K6_STATSD_ENABLE_TAGS_VALUE="${K6_STATSD_ENABLE_TAGS:-true}"
K6_STATSD_OUTPUT_TYPE_VALUE="${K6_STATSD_OUTPUT_TYPE:-output-statsd}"
GENERATE_STATUS_SUMMARY_IN_RUN_VALUE="${GENERATE_STATUS_SUMMARY_IN_RUN:-false}"
RUN_ID_VALUE="${RUN_ID:-local-run}"
ATTEMPT_VALUE="${ATTEMPT:-attempt-01}"
ARCHITECTURE_VALUE="${ARCHITECTURE:-unknown}"
SCENARIO_NAME_VALUE="${SCENARIO_NAME:-unknown}"
EXECUTION_MODE_VALUE="${EXECUTION_MODE:-parallel}"
ARCHITECTURE_ORDER_VALUE="${ARCHITECTURE_ORDER:-}"
TERRAFORM_STACK_VALUE="${TERRAFORM_STACK:-}"
CLUSTER_NAME_VALUE="${CLUSTER_NAME:-}"

for value_name in TARGET_RPS_VALUE PRE_ALLOCATED_VUS_VALUE MAX_VUS_VALUE; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${value_name%_VALUE} must be a non-negative integer, got: '$value'" >&2
    exit 1
  fi
done
unset value_name value

case "$GENERATE_STATUS_SUMMARY_IN_RUN_VALUE" in
  true|false) ;;
  *)
    echo "ERROR: GENERATE_STATUS_SUMMARY_IN_RUN must be true or false, got: '$GENERATE_STATUS_SUMMARY_IN_RUN_VALUE'" >&2
    exit 1
    ;;
esac

duration_seconds() {
  local raw="$1"
  local number unit

  if [[ "$raw" =~ ^([0-9]+)(ms|s|m|h)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      ms)
        echo 0
        ;;
      s)
        echo "$number"
        ;;
      m)
        echo $((number * 60))
        ;;
      h)
        echo $((number * 3600))
        ;;
    esac
    return 0
  fi

  echo 0
}

sum_stage_duration_seconds() {
  local stages_json="$1"
  local total=0
  local stage_duration=""

  while IFS= read -r stage_duration; do
    [ -z "$stage_duration" ] && continue
    total=$((total + $(duration_seconds "$stage_duration")))
  done < <(jq -r '.[]?.duration // empty' <<<"$stages_json")

  echo "$total"
}

configured_duration_seconds() {
  local profile="${K6_PROFILE:-steady}"
  local custom_stages_json="${RAMP_STAGES_JSON:-}"

  if [ -n "$custom_stages_json" ]; then
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$custom_stages_json"; then
      echo "ERROR: RAMP_STAGES_JSON must be a JSON array when set." >&2
      exit 1
    fi

    sum_stage_duration_seconds "$custom_stages_json"
    return 0
  fi

  case "$profile" in
    smoke|steady)
      duration_seconds "$TEST_DURATION_VALUE"
      ;;
    ramp|ramping-arrival-rate)
      echo $(( \
        $(duration_seconds "${RAMP_STAGE_1:-2m}") + \
        $(duration_seconds "${HOLD_STAGE_1:-2m}") + \
        $(duration_seconds "${RAMP_STAGE_2:-2m}") + \
        $(duration_seconds "${HOLD_STAGE_2:-2m}") + \
        $(duration_seconds "${RAMP_STAGE_3:-2m}") + \
        $(duration_seconds "${HOLD_STAGE_3:-2m}") + \
        $(duration_seconds "${RAMP_DOWN:-1m}") \
      ))
      ;;
    ramp-up|hpa)
      echo $(( \
        $(duration_seconds "${HPA_RAMP_UP_1:-2m}") + \
        $(duration_seconds "${HPA_RAMP_UP_2:-2m}") + \
        $(duration_seconds "${HPA_RAMP_UP_3:-3m}") + \
        $(duration_seconds "${HPA_HOLD:-5m}") + \
        $(duration_seconds "${HPA_RAMP_DOWN:-1m}") \
      ))
      ;;
    *)
      duration_seconds "$TEST_DURATION_VALUE"
      ;;
  esac
}

CONFIGURED_DURATION_SECONDS="$(configured_duration_seconds)"

IMAGES_JSON="$(json_env_or IMAGES_JSON '[]')"
SEED_SIZE_JSON="$(json_env_or SEED_SIZE_JSON 'null')"
K6_CONFIGURATION_JSON="$(json_env_or K6_CONFIGURATION_JSON '{}')"
INFRA_CONFIGURATION_JSON="$(json_env_or INFRA_CONFIGURATION_JSON '{}')"
RESOURCES_CONFIGURATION_JSON="$(json_env_or RESOURCES_CONFIGURATION_JSON '{}')"
APP_RESOURCE_QUOTA_JSON="$(json_env_or APP_RESOURCE_QUOTA_JSON 'null')"
HPA_TARGET_CPU_JSON="$(json_env_or HPA_TARGET_CPU_JSON 'null')"

jq -n \
  --arg run_id "$RUN_ID_VALUE" \
  --arg attempt "$ATTEMPT_VALUE" \
  --arg architecture "$ARCHITECTURE_VALUE" \
  --arg execution_mode "$EXECUTION_MODE_VALUE" \
  --arg architecture_order "$ARCHITECTURE_ORDER_VALUE" \
  --arg terraform_stack "$TERRAFORM_STACK_VALUE" \
  --arg cluster_name "$CLUSTER_NAME_VALUE" \
  --arg scenario_name "$SCENARIO_NAME_VALUE" \
  --arg k6_script "k6/scripts/${K6_SCRIPT}" \
  --arg k6_profile "${K6_PROFILE:-steady}" \
  --arg duration "$TEST_DURATION_VALUE" \
  --arg base_url "${BASE_URL:-}" \
  --arg dataset "${DATASET:-}" \
  --arg dataset_version "${DATASET_VERSION:-}" \
  --arg git_commit "${GIT_COMMIT:-}" \
  --arg image_tag "${IMAGE_TAG:-}" \
  --arg timestamp_utc "$TIMESTAMP_UTC" \
  --arg app_node_pool "${APP_NODE_POOL:-}" \
  --arg testing_node_pool "${TESTING_NODE_POOL:-}" \
  --arg datadog_enabled "$DATADOG_ENABLED_VALUE" \
  --arg datadog_env "$DATADOG_ENV_VALUE" \
  --arg datadog_time_window_start "$TIME_WINDOW_START_UTC" \
  --arg k6_statsd_addr "$K6_STATSD_ADDR_VALUE" \
  --arg k6_statsd_namespace "$K6_STATSD_NAMESPACE_VALUE" \
  --arg k6_statsd_enable_tags "$K6_STATSD_ENABLE_TAGS_VALUE" \
  --argjson target_rps "$TARGET_RPS_VALUE" \
  --argjson pre_allocated_vus "$PRE_ALLOCATED_VUS_VALUE" \
  --argjson max_vus "$MAX_VUS_VALUE" \
  --argjson images "$IMAGES_JSON" \
  --argjson seed_size "$SEED_SIZE_JSON" \
  --argjson k6_configuration "$K6_CONFIGURATION_JSON" \
  --argjson infra_configuration "$INFRA_CONFIGURATION_JSON" \
  --argjson resources_configuration "$RESOURCES_CONFIGURATION_JSON" \
  --argjson app_resource_quota "$APP_RESOURCE_QUOTA_JSON" \
  --argjson hpa_target_cpu "$HPA_TARGET_CPU_JSON" \
  '{
    run_id: $run_id,
    attempt: $attempt,
    execution_mode: $execution_mode,
    architecture_order: (if $architecture_order == "" then null else ($architecture_order | split(" ")) end),
    terraform_stack: (if $terraform_stack == "" then null else $terraform_stack end),
    cluster_name: (if $cluster_name == "" then null else $cluster_name end),
    architecture: $architecture,
    scenario_name: $scenario_name,
    k6_script: $k6_script,
    k6_profile: $k6_profile,
    target_rps: $target_rps,
    duration: $duration,
    base_url: $base_url,
    dataset: $dataset,
    dataset_version: $dataset_version,
    git_commit: $git_commit,
    image_tag: $image_tag,
    timestamp_utc: $timestamp_utc,
    images: $images,
    seed_size: $seed_size,
    k6_configuration: ($k6_configuration + {
      profile: $k6_profile,
      target_rps: $target_rps,
      duration: $duration,
      pre_allocated_vus: $pre_allocated_vus,
      max_vus: $max_vus
    }),
    infra_configuration: $infra_configuration,
    resources_configuration: $resources_configuration,
    app_resource_quota: $app_resource_quota,
    hpa_target_cpu: $hpa_target_cpu,
    app_node_pool: (if $app_node_pool == "" then null else $app_node_pool end),
    testing_node_pool: (if $testing_node_pool == "" then null else $testing_node_pool end),
    datadog: {
      enabled: ($datadog_enabled == "true"),
      env: $datadog_env,
      time_window_start: $datadog_time_window_start,
      time_window_end: null,
      k6_statsd_addr: $k6_statsd_addr,
      k6_statsd_namespace: $k6_statsd_namespace,
      k6_statsd_enable_tags: ($k6_statsd_enable_tags == "true")
    }
  }' > "$METADATA_PATH"

K6_OUTPUT_ARGS=(--out "json=$RAW_PATH")
K6_TAG_ARGS=(
  --tag "run_id=$RUN_ID_VALUE"
  --tag "attempt=$ATTEMPT_VALUE"
  --tag "architecture=$ARCHITECTURE_VALUE"
  --tag "benchmark_scenario=$SCENARIO_NAME_VALUE"
  --tag "execution_mode=$EXECUTION_MODE_VALUE"
)
if [ -n "$TERRAFORM_STACK_VALUE" ]; then
  K6_TAG_ARGS+=(--tag "terraform_stack=$TERRAFORM_STACK_VALUE")
fi
if [ -n "$CLUSTER_NAME_VALUE" ]; then
  K6_TAG_ARGS+=(--tag "cluster_name=$CLUSTER_NAME_VALUE")
fi
if [ "$DATADOG_ENABLED_VALUE" = "true" ]; then
  export K6_STATSD_ADDR="$K6_STATSD_ADDR_VALUE"
  export K6_STATSD_NAMESPACE="$K6_STATSD_NAMESPACE_VALUE"
  export K6_STATSD_ENABLE_TAGS="$K6_STATSD_ENABLE_TAGS_VALUE"
  K6_OUTPUT_ARGS+=(--out "$K6_STATSD_OUTPUT_TYPE_VALUE")
fi

set +e
k6 run "${K6_TAG_ARGS[@]}" "${K6_OUTPUT_ARGS[@]}" "$K6_ROOT/scripts/$K6_SCRIPT" > "$STDOUT_PATH" 2>&1
STATUS=$?
set -e

TIME_WINDOW_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$DATADOG_ENABLED_VALUE" = "true" ]; then
  jq -n \
    --arg enabled "$DATADOG_ENABLED_VALUE" \
    --arg datadog_env "$DATADOG_ENV_VALUE" \
    --arg window_start "$TIME_WINDOW_START_UTC" \
    --arg window_end "$TIME_WINDOW_END_UTC" \
    --arg k6_statsd_addr "$K6_STATSD_ADDR_VALUE" \
    --arg k6_statsd_namespace "$K6_STATSD_NAMESPACE_VALUE" \
    '{
      enabled: ($enabled == "true"),
      env: $datadog_env,
      time_window_start: $window_start,
      time_window_end: $window_end,
      k6_statsd_addr: $k6_statsd_addr,
      k6_statsd_namespace: $k6_statsd_namespace
    }' > "$DATADOG_TIME_WINDOW_PATH"

  jq --arg window_end "$TIME_WINDOW_END_UTC" '.datadog.time_window_end = $window_end' "$METADATA_PATH" > "$RESULT_DIR/metadata.datadog.json"
  mv "$RESULT_DIR/metadata.datadog.json" "$METADATA_PATH"
fi

cat "$STDOUT_PATH"

if [ -f "$RAW_PATH" ]; then
  gzip -f "$RAW_PATH"
fi

status_summary_present=false
if [ -f "${RAW_PATH}.gz" ]; then
  if [ "$GENERATE_STATUS_SUMMARY_IN_RUN_VALUE" = "true" ]; then
    if "$SCRIPT_DIR/build-status-summary.sh" "${RAW_PATH}.gz" "$STATUS_SUMMARY_PATH" "$CONFIGURED_DURATION_SECONDS" "$TARGET_RPS_VALUE"; then
      status_summary_present=true
    else
      echo "WARNING: failed to generate status-summary.json from raw k6 output" >&2
    fi
  else
    echo "INFO: deferring status-summary.json generation to offline report processing" >&2
  fi
fi

if [ -f "$METADATA_PARTIAL_PATH" ]; then
  METADATA_MERGED_PATH="$RESULT_DIR/metadata.merged.json"
  jq -s '.[0] * .[1]' "$METADATA_PATH" "$METADATA_PARTIAL_PATH" > "$METADATA_MERGED_PATH"
  mv "$METADATA_MERGED_PATH" "$METADATA_PATH"

  if [ "$METADATA_PARTIAL_PATH" != "$RESULT_DIR/metadata.partial.json" ]; then
    cp "$METADATA_PARTIAL_PATH" "$RESULT_DIR/metadata.partial.json"
  fi
fi

summary_present=false
thresholds_present=false
raw_gzip_present=false
metadata_present=false

if [ -f "$SUMMARY_PATH" ]; then
  summary_present=true
fi

if [ -f "$THRESHOLDS_PATH" ]; then
  thresholds_present=true
fi

if [ -f "${RAW_PATH}.gz" ]; then
  raw_gzip_present=true
fi

if [ -f "$METADATA_PATH" ]; then
  metadata_present=true
fi

classification_hint="runtime_failed"
if [ "$STATUS" -eq 0 ]; then
  classification_hint="pass"
elif [ "$STATUS" -eq 99 ] && [ "$summary_present" = true ] && [ "$thresholds_present" = true ]; then
  classification_hint="threshold_failed"
fi

echo "Generated result files:"
find "$RESULT_DIR" -maxdepth 1 -type f -print | sort

S3_STATUS=0
s3_upload_attempted=false

jq -n \
  --argjson k6_exit_code "$STATUS" \
  --argjson artifacts_generated "$( [ "$summary_present" = true ] && [ "$thresholds_present" = true ] && [ "$metadata_present" = true ] && printf 'true' || printf 'false' )" \
  --argjson summary_file_present "$( [ "$summary_present" = true ] && printf 'true' || printf 'false' )" \
  --argjson thresholds_file_present "$( [ "$thresholds_present" = true ] && printf 'true' || printf 'false' )" \
  --argjson metadata_file_present "$( [ "$metadata_present" = true ] && printf 'true' || printf 'false' )" \
  --argjson raw_file_present "$( [ "$raw_gzip_present" = true ] && printf 'true' || printf 'false' )" \
  --argjson status_summary_file_present "$( [ "$status_summary_present" = true ] && printf 'true' || printf 'false' )" \
  --arg status_summary_generation "$( [ "$status_summary_present" = true ] && printf 'generated_in_run' || { [ "$raw_gzip_present" = true ] && printf 'deferred'; } || printf 'not_available' )" \
  --arg classification_hint "$classification_hint" \
  '{
    k6_exit_code: $k6_exit_code,
    s3_exit_code: null,
    artifacts_generated: $artifacts_generated,
    summary_file_present: $summary_file_present,
    thresholds_file_present: $thresholds_file_present,
    metadata_file_present: $metadata_file_present,
    raw_file_present: $raw_file_present,
    status_summary_file_present: $status_summary_file_present,
    status_summary_generation: $status_summary_generation,
    classification_hint: $classification_hint
  }' > "$RESULT_STATUS_PATH"

if [ -n "${S3_URI:-}" ]; then
  s3_upload_attempted=true
  if aws s3 sync "$RESULT_DIR" "$S3_URI/" --exclude "$(basename "$RESULT_STATUS_PATH")"; then
    echo "Uploaded k6 results to $S3_URI/"
  else
    S3_STATUS=$?
  fi
fi

s3_exit_code_json=null
if [ "$s3_upload_attempted" = true ]; then
  s3_exit_code_json="$S3_STATUS"
fi

jq --argjson s3_exit_code "$s3_exit_code_json" \
  --arg classification_hint "$classification_hint" \
  '.s3_exit_code = $s3_exit_code
   | .classification_hint = (if ($s3_exit_code == null or $s3_exit_code == 0) then $classification_hint else "upload_failed" end)' \
  "$RESULT_STATUS_PATH" > "$RESULT_DIR/result-status.updated.json"
mv "$RESULT_DIR/result-status.updated.json" "$RESULT_STATUS_PATH"

if [ -n "${S3_URI:-}" ]; then
  set +e
  aws s3 cp "$RESULT_STATUS_PATH" "${S3_URI%/}/result-status.json" >/dev/null
  result_status_upload_exit=$?
  set -e

  if [ "$result_status_upload_exit" -ne 0 ]; then
    S3_STATUS="$result_status_upload_exit"
    jq --argjson s3_exit_code "$S3_STATUS" \
      '.s3_exit_code = $s3_exit_code | .classification_hint = "upload_failed"' \
      "$RESULT_STATUS_PATH" > "$RESULT_DIR/result-status.updated.json"
    mv "$RESULT_DIR/result-status.updated.json" "$RESULT_STATUS_PATH"
  fi
fi

echo "RESULT_STATUS_JSON=$(jq -c . "$RESULT_STATUS_PATH")"

if [ "$S3_STATUS" -ne 0 ]; then
  echo "ERROR: S3 upload failed (aws exit code: $S3_STATUS). k6 exit code: $STATUS" >&2
fi

if [ "$STATUS" -ne 0 ]; then
  exit "$STATUS"
fi

if [ "$S3_STATUS" -ne 0 ]; then
  exit "$S3_STATUS"
fi

exit "$STATUS"
