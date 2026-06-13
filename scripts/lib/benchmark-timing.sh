#!/usr/bin/env bash

warn_benchmark_timing() {
  local label="$1"
  local message="$2"

  echo "WARNING: benchmark timing fallback for ${label}: ${message}" >&2
}

fetch_benchmark_timing_s3_artifact() {
  local s3_uri="$1"
  local artifact_name="$2"
  local output
  local error_file

  error_file="$(mktemp)"
  if output="$(benchmark_aws s3 cp "${s3_uri%/}/${artifact_name}" - 2>"$error_file")"; then
    rm -f "$error_file"
    printf '%s' "$output"
    return 0
  fi

  if [ -s "$error_file" ]; then
    cat "$error_file" >&2
  fi
  rm -f "$error_file"
  return 1
}

resolve_attempt_timing_json() {
  local s3_uri="$1"
  local fallback_start="$2"
  local fallback_end="$3"
  local label="${4:-attempt}"
  local metadata_json=""
  local datadog_json=""
  local metadata_valid=false
  local datadog_valid=false
  local start=""
  local finish=""
  local source="orchestrator"

  if metadata_json="$(fetch_benchmark_timing_s3_artifact "$s3_uri" metadata.json)"; then
    if jq -e . >/dev/null 2>&1 <<<"$metadata_json"; then
      metadata_valid=true
    else
      warn_benchmark_timing "$label" "metadata.json is not valid JSON; falling back"
      metadata_json=""
    fi
  else
    warn_benchmark_timing "$label" "metadata.json could not be fetched from ${s3_uri}; falling back"
  fi

  if datadog_json="$(fetch_benchmark_timing_s3_artifact "$s3_uri" datadog-time-window.json)"; then
    if jq -e . >/dev/null 2>&1 <<<"$datadog_json"; then
      datadog_valid=true
    else
      warn_benchmark_timing "$label" "datadog-time-window.json is not valid JSON; ignoring artifact"
      datadog_json=""
    fi
  fi

  if [ "$metadata_valid" = true ]; then
    start="$(jq -r '.datadog.time_window_start // empty' <<<"$metadata_json")"
    finish="$(jq -r '.datadog.time_window_end // empty' <<<"$metadata_json")"
    if [ -n "$start" ] && [ -n "$finish" ]; then
      source="attempt_metadata"
    fi
  fi

  if [ "$source" != "attempt_metadata" ] && [ "$datadog_valid" = true ]; then
    local d_start
    local d_finish
    d_start="$(jq -r '.time_window_start // empty' <<<"$datadog_json")"
    d_finish="$(jq -r '.time_window_end // empty' <<<"$datadog_json")"
    if [ -n "$d_start" ] && [ -n "$d_finish" ]; then
      start="$d_start"
      finish="$d_finish"
      source="datadog_artifact"
    fi
  fi

  if [ "$source" != "attempt_metadata" ] && [ "$source" != "datadog_artifact" ] && [ "$metadata_valid" = true ]; then
    start="$(jq -r '.timestamp_utc // empty' <<<"$metadata_json")"
    if [ -n "$start" ]; then
      finish="$fallback_end"
      source="attempt_metadata_partial"
      warn_benchmark_timing "$label" "using metadata timestamp_utc plus orchestrator finish time"
    fi
  fi

  if [ -z "$start" ] || [ -z "$finish" ]; then
    start="$fallback_start"
    finish="$fallback_end"
    source="orchestrator"
    warn_benchmark_timing "$label" "using orchestrator start/end timestamps"
  fi

  jq -cn \
    --arg started_at_utc "$start" \
    --arg finished_at_utc "$finish" \
    --arg timing_source "$source" \
    '{
      started_at_utc: $started_at_utc,
      finished_at_utc: $finished_at_utc,
      timing_source: $timing_source
    }'
}
