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
DURATION_VALUE="${TEST_DURATION:-${DURATION:-}}"
TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for value_name in TARGET_RPS_VALUE PRE_ALLOCATED_VUS_VALUE MAX_VUS_VALUE; do
  value="${!value_name}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${value_name%_VALUE} must be a non-negative integer, got: '$value'" >&2
    exit 1
  fi
done
unset value_name value

IMAGES_JSON="$(json_env_or IMAGES_JSON '[]')"
SEED_SIZE_JSON="$(json_env_or SEED_SIZE_JSON 'null')"
K6_CONFIGURATION_JSON="$(json_env_or K6_CONFIGURATION_JSON '{}')"
INFRA_CONFIGURATION_JSON="$(json_env_or INFRA_CONFIGURATION_JSON '{}')"
RESOURCES_CONFIGURATION_JSON="$(json_env_or RESOURCES_CONFIGURATION_JSON '{}')"
APP_RESOURCE_QUOTA_JSON="$(json_env_or APP_RESOURCE_QUOTA_JSON 'null')"
HPA_TARGET_CPU_JSON="$(json_env_or HPA_TARGET_CPU_JSON 'null')"

jq -n \
  --arg run_id "${RUN_ID:-local-run}" \
  --arg attempt "${ATTEMPT:-attempt-01}" \
  --arg architecture "${ARCHITECTURE:-unknown}" \
  --arg scenario_name "${SCENARIO_NAME:-unknown}" \
  --arg k6_script "k6/scripts/${K6_SCRIPT}" \
  --arg k6_profile "${K6_PROFILE:-steady}" \
  --arg duration "$DURATION_VALUE" \
  --arg base_url "${BASE_URL:-}" \
  --arg dataset "${DATASET:-}" \
  --arg dataset_version "${DATASET_VERSION:-}" \
  --arg git_commit "${GIT_COMMIT:-}" \
  --arg image_tag "${IMAGE_TAG:-}" \
  --arg timestamp_utc "$TIMESTAMP_UTC" \
  --arg app_node_pool "${APP_NODE_POOL:-}" \
  --arg testing_node_pool "${TESTING_NODE_POOL:-}" \
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
    testing_node_pool: (if $testing_node_pool == "" then null else $testing_node_pool end)
  }' > "$METADATA_PATH"

set +e
k6 run --out "json=$RAW_PATH" "$K6_ROOT/scripts/$K6_SCRIPT" > "$STDOUT_PATH" 2>&1
STATUS=$?
set -e

cat "$STDOUT_PATH"

if [ -f "$RAW_PATH" ]; then
  gzip -f "$RAW_PATH"
fi

if [ -f "$METADATA_PARTIAL_PATH" ]; then
  METADATA_MERGED_PATH="$RESULT_DIR/metadata.merged.json"
  jq -s '.[0] * .[1]' "$METADATA_PATH" "$METADATA_PARTIAL_PATH" > "$METADATA_MERGED_PATH"
  mv "$METADATA_MERGED_PATH" "$METADATA_PATH"

  if [ "$METADATA_PARTIAL_PATH" != "$RESULT_DIR/metadata.partial.json" ]; then
    cp "$METADATA_PARTIAL_PATH" "$RESULT_DIR/metadata.partial.json"
  fi
fi

echo "Generated result files:"
find "$RESULT_DIR" -maxdepth 1 -type f -print | sort

S3_STATUS=0
if [ -n "${S3_URI:-}" ]; then
  if aws s3 sync "$RESULT_DIR" "$S3_URI/"; then
    echo "Uploaded k6 results to $S3_URI/"
  else
    S3_STATUS=$?
  fi
fi

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
