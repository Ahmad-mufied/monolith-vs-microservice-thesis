#!/usr/bin/env bash
# Run the benchmark matrix on one architecture at a time.
set -euo pipefail

source scripts/lib/shared-env.sh

explicit_s3_bucket="${S3_BUCKET:-}"
if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
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

source scripts/lib/cloud-provider.sh
load_cloud_provider_env
source scripts/lib/benchmark-aws-credentials.sh
source scripts/lib/resource-configuration.sh
source scripts/lib/benchmark-preflight.sh
source scripts/lib/benchmark-timing.sh
source scripts/lib/sequential-benchmark-setup.sh

SCALING_MODE="${SCALING_MODE:-fixed}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
SCENARIOS="${SCENARIOS:-login create-transaction enriched-transactions}"
RPS_LEVELS="${RPS_LEVELS:-1000 2500 5000 7500 10000}"
SCENARIO_RPS_MATRIX="${SCENARIO_RPS_MATRIX:-}"
ARCHITECTURE_ORDER="${ARCHITECTURE_ORDER:-monolith microservices}"
INTER_CASE_DELAY="${INTER_CASE_DELAY:-0}"
ARCHITECTURE_SWITCH_DELAY="${ARCHITECTURE_SWITCH_DELAY:-300}"
AUTO_DESTROY_CONFIRMED="${AUTO_DESTROY_CONFIRMED:-false}"
SKIP_BENCHMARK_PREFLIGHT="${SKIP_BENCHMARK_PREFLIGHT:-false}"
SEQUENTIAL_RESUME_SKIP_READY_DEPLOY="${SEQUENTIAL_RESUME_SKIP_READY_DEPLOY:-true}"
SEQUENTIAL_CASE_OVERHEAD_SECONDS="${SEQUENTIAL_CASE_OVERHEAD_SECONDS:-180}"
SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS="${SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS:-120}"
SEQUENTIAL_RETRY_BUFFER_SECONDS="${SEQUENTIAL_RETRY_BUFFER_SECONDS:-0}"
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"
K6_PROFILE="${K6_PROFILE:-}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-}"
RUN_ID="${RUN_ID:-}"
ATTEMPT="${ATTEMPT:-attempt-01}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
SEQUENTIAL_CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"
SUITE_WORKDIR="$(mktemp -d)"
MATRIX_TSV="$SUITE_WORKDIR/scenario-rps-matrix.tsv"
CASES_JSONL="$SUITE_WORKDIR/cases.jsonl"
PHASES_JSONL="$SUITE_WORKDIR/architecture-phases.jsonl"
RENDER_ROOT="$SUITE_WORKDIR/rendered"

cleanup() {
  rm -rf "$SUITE_WORKDIR"
}
trap cleanup EXIT
: > "$CASES_JSONL"
: > "$PHASES_JSONL"
declare -A CASE_RESULT_STATUS_CACHE=()

log_timestamp() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

log_info() {
  printf '[%s] %s\n' "$(log_timestamp)" "$*"
}

log_warn() {
  printf '[%s] WARNING: %s\n' "$(log_timestamp)" "$*" >&2
}

log_error() {
  printf '[%s] ERROR: %s\n' "$(log_timestamp)" "$*" >&2
}

trim_whitespace() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"
}

sanitize_run_id_component() {
  local label="$1"
  local value="$2"
  local sanitized

  sanitized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  if [ -z "$sanitized" ]; then
    log_error "${label} '$value' does not contain any usable slug characters"
    exit 1
  fi

  printf '%s' "$sanitized"
}

validate_architecture_order() {
  local architecture seen_monolith=false seen_microservices=false count=0
  for architecture in $ARCHITECTURE_ORDER; do
    count=$((count + 1))
    case "$architecture" in
      monolith)
        if [ "$seen_monolith" = "true" ]; then
          log_error "ARCHITECTURE_ORDER must not contain duplicate monolith entries"
          exit 1
        fi
        seen_monolith=true
        ;;
      microservices)
        if [ "$seen_microservices" = "true" ]; then
          log_error "ARCHITECTURE_ORDER must not contain duplicate microservices entries"
          exit 1
        fi
        seen_microservices=true
        ;;
      *)
        log_error "unsupported architecture in ARCHITECTURE_ORDER: $architecture"
        exit 1
        ;;
    esac
  done
  if [ "$count" -ne 2 ] || [ "$seen_monolith" != "true" ] || [ "$seen_microservices" != "true" ]; then
    log_error "ARCHITECTURE_ORDER must include exactly both monolith and microservices"
    exit 1
  fi
}

validate_seconds_value() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_error "${name} must be an integer number of seconds, got '$value'"
    exit 1
  fi
}

duration_to_seconds() {
  local value="$1"
  local remainder="$value"
  local total=0
  local number unit

  if [ -z "$value" ]; then
    log_error "duration must not be empty"
    return 1
  fi

  while [[ "$remainder" =~ ^([0-9]+)(ms|s|m|h)(.*)$ ]]; do
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    remainder="${BASH_REMATCH[3]}"
    case "$unit" in
      ms)
        if [ "$number" -gt 0 ]; then
          total=$((total + 1))
        fi
        ;;
      s) total=$((total + number)) ;;
      m) total=$((total + (number * 60))) ;;
      h) total=$((total + (number * 3600))) ;;
    esac
  done

  if [ -n "$remainder" ]; then
    log_error "unsupported duration '$value' (expected k6-style values like 30s, 5m, 1h, or 1m30s)"
    return 1
  fi

  printf '%s\n' "$total"
}

format_duration() {
  local seconds="$1"
  local hours minutes remaining

  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  remaining=$((seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf '%dh%02dm%02ds' "$hours" "$minutes" "$remaining"
  elif [ "$minutes" -gt 0 ]; then
    printf '%dm%02ds' "$minutes" "$remaining"
  else
    printf '%ds' "$remaining"
  fi
}

format_eta_epoch() {
  local epoch="$1"

  date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z'
}

custom_ramp_stages_seconds() {
  local total=0
  local duration seconds

  while IFS= read -r duration; do
    [ -z "$duration" ] && continue
    seconds="$(duration_to_seconds "$duration")"
    total=$((total + seconds))
  done < <(jq -r '.[].duration // empty' <<<"$RAMP_STAGES_JSON")

  printf '%s\n' "$total"
}

estimate_case_duration_seconds() {
  local seconds

  if [ -n "${RAMP_STAGES_JSON:-}" ]; then
    custom_ramp_stages_seconds
    return
  fi

  case "$K6_PROFILE" in
    hpa)
      seconds=0
      seconds=$((seconds + $(duration_to_seconds "${HPA_RAMP_UP_1:-2m}")))
      seconds=$((seconds + $(duration_to_seconds "${HPA_RAMP_UP_2:-2m}")))
      seconds=$((seconds + $(duration_to_seconds "${HPA_RAMP_UP_3:-3m}")))
      seconds=$((seconds + $(duration_to_seconds "${HPA_HOLD:-5m}")))
      seconds=$((seconds + $(duration_to_seconds "${HPA_RAMP_DOWN:-1m}")))
      printf '%s\n' "$seconds"
      ;;
    ramp)
      seconds=0
      seconds=$((seconds + $(duration_to_seconds "${RAMP_UP_DURATION:-1m}")))
      seconds=$((seconds + $(duration_to_seconds "$TEST_DURATION")))
      seconds=$((seconds + $(duration_to_seconds "${RAMP_DOWN_DURATION:-30s}")))
      printf '%s\n' "$seconds"
      ;;
    smoke|steady)
      duration_to_seconds "$TEST_DURATION"
      ;;
    *)
      log_error "unsupported K6_PROFILE '$K6_PROFILE' for ETA calculation"
      return 1
      ;;
  esac
}

print_case_eta() {
  local architecture="$1"
  local scenario="$2"
  local target_rps="$3"
  local suite_case_number="$4"
  local suite_total_cases="$5"
  local scenario_case_number="$6"
  local scenario_total_cases="$7"
  local completed_architecture_cases="$8"
  local total_architecture_cases="$9"
  local architecture_index="${10}"
  local architecture_count="${11}"
  local case_seconds="${12}"
  local k6_case_seconds="${13}"
  local eta_mode="${14}"
  local pending_scenario_cases="${15}"
  local pending_current_architecture_cases="${16}"
  local pending_future_architecture_cases="${17}"
  local scenario_remaining_case_seconds="${18}"
  local suite_remaining_case_seconds="${19}"
  local now_epoch case_eta_epoch scenario_eta_epoch suite_eta_epoch
  local suite_pending_cases suite_remaining_delay_seconds

  now_epoch="$(date +%s)"
  case_eta_epoch=$((now_epoch + case_seconds))

  scenario_eta_epoch=$((now_epoch + scenario_remaining_case_seconds))
  if [ "$pending_scenario_cases" -gt 1 ]; then
    scenario_eta_epoch=$((scenario_eta_epoch + ((pending_scenario_cases - 1) * INTER_CASE_DELAY)))
  fi

  suite_pending_cases=$((pending_current_architecture_cases + pending_future_architecture_cases))
  suite_remaining_delay_seconds=0
  if [ "$pending_current_architecture_cases" -gt 1 ]; then
    suite_remaining_delay_seconds=$((suite_remaining_delay_seconds + ((pending_current_architecture_cases - 1) * INTER_CASE_DELAY)))
  fi
  if [ "$pending_future_architecture_cases" -gt 0 ]; then
    suite_remaining_delay_seconds=$((suite_remaining_delay_seconds + ARCHITECTURE_SWITCH_DELAY))
    if [ "$pending_future_architecture_cases" -gt 1 ]; then
      suite_remaining_delay_seconds=$((suite_remaining_delay_seconds + ((pending_future_architecture_cases - 1) * INTER_CASE_DELAY)))
    fi
  fi
  suite_eta_epoch=$((now_epoch + suite_remaining_case_seconds + suite_remaining_delay_seconds))

  log_info "=== Sequential ETA ==="
  log_info "  case          : ${suite_case_number}/${suite_total_cases} ${architecture}/${scenario}/${target_rps}rps"
  log_info "  scenario      : ${scenario_case_number}/${scenario_total_cases} (${scenario})"
  log_info "  est_case      : $(format_duration "$case_seconds") -> $(format_eta_epoch "$case_eta_epoch")"
  log_info "  est_scenario  : $(format_eta_epoch "$scenario_eta_epoch")"
  log_info "  est_suite     : $(format_eta_epoch "$suite_eta_epoch")"
  log_info "  pending       : scenario=${pending_scenario_cases}, architecture=${pending_current_architecture_cases}, future_architecture=${pending_future_architecture_cases}"
  log_info "  eta_basis     : k6=$(format_duration "$k6_case_seconds") + full_overhead=$(format_duration "$SEQUENTIAL_CASE_OVERHEAD_SECONDS") or reused_overhead=$(format_duration "$SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS") + retry_buffer=$(format_duration "$SEQUENTIAL_RETRY_BUFFER_SECONDS") + configured delays"
  log_info "  eta_mode      : $eta_mode"
}

validate_supported_scenario() {
  case "$1" in
    login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items) ;;
    *)
      log_error "unsupported scenario '$1'"
      exit 1
      ;;
  esac
}

build_matrix_file() {
  local matrix_entry scenario rps_csv rps_words
  : > "$MATRIX_TSV"
  if [ -n "${SCENARIO_RPS_MATRIX//[[:space:]]/}" ]; then
    while IFS= read -r matrix_entry; do
      matrix_entry="$(trim_whitespace "$matrix_entry")"
      [ -z "$matrix_entry" ] && continue
      scenario="$(trim_whitespace "${matrix_entry%%:*}")"
      rps_csv="$(trim_whitespace "${matrix_entry#*:}")"
      validate_supported_scenario "$scenario"
      rps_words="$(tr ',' ' ' <<<"$rps_csv" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
      printf '%s\t%s\n' "$scenario" "$rps_words" >> "$MATRIX_TSV"
    done < <(tr ';' '\n' <<<"$SCENARIO_RPS_MATRIX")
  else
    for scenario in $SCENARIOS; do
      validate_supported_scenario "$scenario"
      printf '%s\t%s\n' "$scenario" "$RPS_LEVELS" >> "$MATRIX_TSV"
    done
  fi
}

words_json_array() {
  jq -cn --arg words "$1" '$words | [scan("\\S+")]'
}

matrix_json() {
  jq -Rs '
    split("\n")
    | map(select(length > 0))
    | map(split("\t") as $parts | {scenario:$parts[0], rps_levels:(($parts[1] // "") | split(" ") | map(select(length > 0) | tonumber))})
  ' < "$MATRIX_TSV"
}

case_result_cache_key() {
  printf '%s|%s|%s' "$1" "$2" "$3"
}

set_case_result_status_cache() {
  local key

  key="$(case_result_cache_key "$1" "$2" "$3")"
  CASE_RESULT_STATUS_CACHE["$key"]="$4"
}

case_result_present_in_s3_uncached() {
  local architecture="$1"
  local scenario="$2"
  local target_rps="$3"
  local case_s3_uri="${S3_RUN_URI}/${architecture}/${scenario}/${target_rps}rps/${ATTEMPT}"

  if benchmark_aws s3 ls "${case_s3_uri}/result-status.json" >/dev/null 2>&1; then
    set_case_result_status_cache "$architecture" "$scenario" "$target_rps" "present"
    return 0
  fi

  set_case_result_status_cache "$architecture" "$scenario" "$target_rps" "missing"
  return 1
}

prime_case_result_status_cache() {
  local architecture scenario scenario_rps_levels target_rps
  local result_status_listing object_key relative_key
  local matched_architecture matched_scenario matched_rps matched_attempt
  local s3_run_key_prefix="experiments/${RUN_ID}/"

  CASE_RESULT_STATUS_CACHE=()

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue
    for architecture in $ARCHITECTURE_ORDER; do
      for target_rps in $scenario_rps_levels; do
        set_case_result_status_cache "$architecture" "$scenario" "$target_rps" "missing"
      done
    done
  done < "$MATRIX_TSV"

  if ! result_status_listing="$(benchmark_aws s3 ls "${S3_RUN_URI}/" --recursive 2>/dev/null)"; then
    log_warn "initial S3 result-status cache warmup failed; falling back to on-demand checks."
    CASE_RESULT_STATUS_CACHE=()
    return 1
  fi

  while IFS= read -r object_line; do
    [ -z "$object_line" ] && continue
    object_key="${object_line##* }"
    relative_key="${object_key#${s3_run_key_prefix}}"
    if [[ "$relative_key" =~ ^([^/]+)/([^/]+)/([0-9]+)rps/([^/]+)/result-status\.json$ ]]; then
      matched_architecture="${BASH_REMATCH[1]}"
      matched_scenario="${BASH_REMATCH[2]}"
      matched_rps="${BASH_REMATCH[3]}"
      matched_attempt="${BASH_REMATCH[4]}"
      if [ "$matched_attempt" = "$ATTEMPT" ]; then
        set_case_result_status_cache "$matched_architecture" "$matched_scenario" "$matched_rps" "present"
      fi
    fi
  done <<<"$result_status_listing"
}

architecture_has_pending_cases() {
  local architecture="$1"
  local scenario scenario_rps_levels target_rps

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue
    for target_rps in $scenario_rps_levels; do
      if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        return 0
      fi
    done
  done < "$MATRIX_TSV"

  return 1
}

case_missing_in_s3() {
  local architecture="$1"
  local scenario="$2"
  local target_rps="$3"
  local key cached_status

  key="$(case_result_cache_key "$architecture" "$scenario" "$target_rps")"
  cached_status="${CASE_RESULT_STATUS_CACHE[$key]:-}"

  case "$cached_status" in
    missing)
      return 0
      ;;
    present)
      return 1
      ;;
  esac

  if case_result_present_in_s3_uncached "$architecture" "$scenario" "$target_rps"; then
    return 1
  fi

  return 0
}

scenario_has_pending_cases() {
  local architecture="$1"
  local current_scenario="$2"
  local scenario scenario_rps_levels target_rps

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ "$scenario" = "$current_scenario" ] || continue
    for target_rps in $scenario_rps_levels; do
      if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        return 0
      fi
    done
  done < "$MATRIX_TSV"

  return 1
}

count_pending_scenario_cases() {
  local architecture="$1"
  local current_scenario="$2"
  local scenario scenario_rps_levels target_rps
  local count=0

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ "$scenario" = "$current_scenario" ] || continue
    for target_rps in $scenario_rps_levels; do
      if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        count=$((count + 1))
      fi
    done
  done < "$MATRIX_TSV"

  printf '%s\n' "$count"
}

scenario_pending_case_seconds() {
  local scope="$1"
  local pending_case_count="$2"
  local setup_already_done="$3"

  if [ "$pending_case_count" -le 0 ]; then
    printf '0\n'
    return
  fi

  if [ "$scope" = "per_scenario" ]; then
    if [ "$setup_already_done" = "true" ]; then
      printf '%s\n' $((pending_case_count * REUSED_CASE_ESTIMATE_SECONDS))
      return
    fi
    printf '%s\n' $((CASE_ESTIMATE_SECONDS + ((pending_case_count - 1) * REUSED_CASE_ESTIMATE_SECONDS)))
    return
  fi

  printf '%s\n' $((pending_case_count * CASE_ESTIMATE_SECONDS))
}

count_pending_scenario_cases_from() {
  local current_scenario="$1"
  local current_target_rps="$2"
  local architecture="$3"
  local scenario scenario_rps_levels target_rps
  local count=0
  local seen_current=false

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ "$scenario" = "$current_scenario" ] || continue
    for target_rps in $scenario_rps_levels; do
      if [ "$target_rps" = "$current_target_rps" ]; then
        seen_current=true
      fi
      [ "$seen_current" = "true" ] || continue
      if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        count=$((count + 1))
      fi
    done
  done < "$MATRIX_TSV"

  printf '%s\n' "$count"
}

count_pending_architecture_cases_from() {
  local architecture="$1"
  local current_scenario="$2"
  local current_target_rps="$3"
  local scenario scenario_rps_levels target_rps
  local count=0
  local seen_current=false

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue
    for target_rps in $scenario_rps_levels; do
      if [ "$scenario" = "$current_scenario" ] && [ "$target_rps" = "$current_target_rps" ]; then
        seen_current=true
      fi
      [ "$seen_current" = "true" ] || continue
      if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        count=$((count + 1))
      fi
    done
  done < "$MATRIX_TSV"

  printf '%s\n' "$count"
}

count_pending_future_architecture_cases() {
  local current_architecture="$1"
  local architecture scenario scenario_rps_levels target_rps
  local count=0
  local seen_current_architecture=false

  for architecture in $ARCHITECTURE_ORDER; do
    if [ "$architecture" = "$current_architecture" ]; then
      seen_current_architecture=true
      continue
    fi
    [ "$seen_current_architecture" = "true" ] || continue

    while IFS=$'\t' read -r scenario scenario_rps_levels; do
      [ -z "$scenario" ] && continue
      for target_rps in $scenario_rps_levels; do
        if case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
          count=$((count + 1))
        fi
      done
    done < "$MATRIX_TSV"
  done

  printf '%s\n' "$count"
}

count_pending_architecture_case_seconds_from() {
  local architecture="$1"
  local current_scenario="$2"
  local current_target_rps="$3"
  local scenario scenario_rps_levels target_rps
  local count=0
  local seen_current=false
  local total_seconds=0
  local scope pending_case_count

  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue
    for target_rps in $scenario_rps_levels; do
      if [ "$scenario" = "$current_scenario" ] && [ "$target_rps" = "$current_target_rps" ]; then
        seen_current=true
        pending_case_count="$(count_pending_scenario_cases_from "$current_scenario" "$current_target_rps" "$architecture")"
        scope="$(scenario_setup_reuse_scope "$current_scenario")"
        total_seconds=$((total_seconds + $(scenario_pending_case_seconds "$scope" "$pending_case_count" "true")))
        break
      fi
    done

    if [ "$seen_current" = "true" ] && [ "$scenario" != "$current_scenario" ]; then
      pending_case_count="$(count_pending_scenario_cases "$architecture" "$scenario")"
      if [ "$pending_case_count" -gt 0 ]; then
        scope="$(scenario_setup_reuse_scope "$scenario")"
        total_seconds=$((total_seconds + $(scenario_pending_case_seconds "$scope" "$pending_case_count" "false")))
      fi
    fi
  done < "$MATRIX_TSV"

  printf '%s\n' "$total_seconds"
}

count_pending_future_architecture_case_seconds() {
  local current_architecture="$1"
  local architecture scenario
  local total_seconds=0
  local seen_current_architecture=false
  local pending_case_count scope

  for architecture in $ARCHITECTURE_ORDER; do
    if [ "$architecture" = "$current_architecture" ]; then
      seen_current_architecture=true
      continue
    fi
    [ "$seen_current_architecture" = "true" ] || continue

    while IFS=$'\t' read -r scenario _; do
      [ -z "$scenario" ] && continue
      pending_case_count="$(count_pending_scenario_cases "$architecture" "$scenario")"
      if [ "$pending_case_count" -le 0 ]; then
        continue
      fi
      scope="$(scenario_setup_reuse_scope "$scenario")"
      total_seconds=$((total_seconds + $(scenario_pending_case_seconds "$scope" "$pending_case_count" "false")))
    done < "$MATRIX_TSV"
  done

  printf '%s\n' "$total_seconds"
}

deployment_ready_with_image_tag() {
  local namespace="$1"
  local deployment="$2"
  local container="$3"
  local desired ready image

  if ! kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
    return 1
  fi

  desired="$(kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  image="$(kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" -o "jsonpath={.spec.template.spec.containers[?(@.name=='${container}')].image}" 2>/dev/null || true)"

  desired="${desired:-0}"
  ready="${ready:-0}"

  if ! [[ "$desired" =~ ^[0-9]+$ ]] || ! [[ "$ready" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$desired" -lt 1 ] || [ "$ready" -lt "$desired" ]; then
    return 1
  fi
  if [[ "$image" != *":${IMAGE_TAG}" ]]; then
    return 1
  fi

  return 0
}

deployment_scaled_down_or_absent() {
  local namespace="$1"
  local deployment="$2"
  local desired ready

  if ! kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" >/dev/null 2>&1; then
    return 0
  fi

  desired="$(kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(kubectl --context="$SEQUENTIAL_CONTEXT" get deployment "$deployment" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  desired="${desired:-0}"
  ready="${ready:-0}"

  [ "$desired" = "0" ] && [ "$ready" = "0" ]
}

scaling_mode_matches_live_architecture() {
  local architecture="$1"
  local hpa_count

  case "$architecture:$SCALING_MODE" in
    monolith:fixed)
      ! kubectl --context="$SEQUENTIAL_CONTEXT" get hpa monolith -n mono >/dev/null 2>&1
      ;;
    monolith:hpa)
      kubectl --context="$SEQUENTIAL_CONTEXT" get hpa monolith -n mono >/dev/null 2>&1
      ;;
    microservices:fixed)
      hpa_count="$(kubectl --context="$SEQUENTIAL_CONTEXT" get hpa -n msa -o name 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
      [ "${hpa_count:-0}" = "0" ]
      ;;
    microservices:hpa)
      hpa_count="$(kubectl --context="$SEQUENTIAL_CONTEXT" get hpa -n msa -o name 2>/dev/null | wc -l | tr -d '[:space:]' || true)"
      [ "${hpa_count:-0}" -ge 4 ]
      ;;
    *)
      return 1
      ;;
  esac
}

inactive_architecture_scaled_down() {
  local active_architecture="$1"
  local svc

  if [ "$active_architecture" = "monolith" ]; then
    for svc in api-gateway auth-service item-service transaction-service; do
      deployment_scaled_down_or_absent msa "$svc" || return 1
    done
    return 0
  fi

  deployment_scaled_down_or_absent mono monolith
}

architecture_ready_for_resume() {
  local architecture="$1"
  local svc

  scaling_mode_matches_live_architecture "$architecture" || return 1
  inactive_architecture_scaled_down "$architecture" || return 1

  if [ "$architecture" = "monolith" ]; then
    deployment_ready_with_image_tag mono monolith monolith
    return
  fi

  for svc in api-gateway auth-service item-service transaction-service; do
    deployment_ready_with_image_tag msa "$svc" "$svc" || return 1
  done
}

normalize_case_timing_source() {
  local source="$1"

  case "$source" in
    attempt_metadata|datadog_artifact)
      printf 'attempt_metadata'
      ;;
    attempt_metadata_partial|orchestrator)
      printf 'orchestrator'
      ;;
    *)
      printf 'mixed'
      ;;
  esac
}

sequential_case_timing_json() {
  local architecture="$1"
  local s3_uri="$2"
  local case_started_at_utc="$3"
  local case_finished_at_utc="$4"
  local attempt_timing_json
  local case_timing_source

  log_info "Resolving timing window for ${architecture}/${s3_uri##*/} from S3 artifacts..." >&2
  attempt_timing_json="$(
    resolve_attempt_timing_json \
      "$s3_uri" \
      "$case_started_at_utc" \
      "$case_finished_at_utc" \
      "sequential ${architecture} ${s3_uri##*/}"
  )"
  case_timing_source="$(normalize_case_timing_source "$(jq -r '.timing_source' <<<"$attempt_timing_json")")"
  log_info "Timing window resolved for ${architecture}/${s3_uri##*/} (source: ${case_timing_source})." >&2

  jq -cn \
    --arg architecture "$architecture" \
    --arg timing_source "$case_timing_source" \
    --argjson timing "$attempt_timing_json" \
    '{
      started_at_utc: $timing.started_at_utc,
      finished_at_utc: $timing.finished_at_utc,
      timing_source: $timing_source,
      architectures: {
        ($architecture): $timing
      }
    }'
}

if [ -z "$K6_PROFILE" ]; then
  if [ "$SCALING_MODE" = "hpa" ]; then
    K6_PROFILE="hpa"
  else
    K6_PROFILE="steady"
  fi
fi

case "$SCALING_MODE:$K6_PROFILE" in
  fixed:steady|fixed:ramp|fixed:smoke|hpa:hpa) ;;
  fixed:hpa)
    log_error "K6_PROFILE=hpa must not be used with SCALING_MODE=fixed."
    exit 1
    ;;
  hpa:steady|hpa:ramp|hpa:smoke)
    log_error "SCALING_MODE=hpa requires K6_PROFILE=hpa for the standard autoscaling experiment."
    exit 1
    ;;
esac

if [ -n "$EXPERIMENT_NAME" ]; then
  EXPERIMENT_NAME="$(sanitize_run_id_component "EXPERIMENT_NAME" "$EXPERIMENT_NAME")"
fi

if [ -z "$RUN_ID" ]; then
  sanitized_image_tag=""
  run_prefix="$(provider_default_run_prefix sequential)"
  if [ -n "$EXPERIMENT_NAME" ]; then
    sanitized_image_tag="$(sanitize_run_id_component "IMAGE_TAG" "$IMAGE_TAG")"
    RUN_ID="${run_prefix}-${SCALING_MODE}-${EXPERIMENT_NAME}-${sanitized_image_tag}"
  else
    RUN_ID="${run_prefix}-${SCALING_MODE}-$(date +%Y%m%d-%H%M)"
  fi
fi

S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"
SUITE_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

validate_architecture_order
validate_seconds_value "INTER_CASE_DELAY" "$INTER_CASE_DELAY"
validate_seconds_value "ARCHITECTURE_SWITCH_DELAY" "$ARCHITECTURE_SWITCH_DELAY"
validate_seconds_value "SEQUENTIAL_CASE_OVERHEAD_SECONDS" "$SEQUENTIAL_CASE_OVERHEAD_SECONDS"
validate_seconds_value "SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS" "$SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS"
validate_seconds_value "SEQUENTIAL_RETRY_BUFFER_SECONDS" "$SEQUENTIAL_RETRY_BUFFER_SECONDS"
build_matrix_file
K6_CASE_ESTIMATE_SECONDS="$(estimate_case_duration_seconds)"
CASE_ESTIMATE_SECONDS=$((K6_CASE_ESTIMATE_SECONDS + SEQUENTIAL_CASE_OVERHEAD_SECONDS + SEQUENTIAL_RETRY_BUFFER_SECONDS))
REUSED_CASE_ESTIMATE_SECONDS=$((K6_CASE_ESTIMATE_SECONDS + SEQUENTIAL_REUSED_CASE_OVERHEAD_SECONDS + SEQUENTIAL_RETRY_BUFFER_SECONDS))

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ]; then
  BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_or_die "$S3_BUCKET" "sequential suite bootstrap" "false"
fi

render_provider_manifests "$RENDER_ROOT"
bash scripts/validate-cloud-assets.sh deploy "$RENDER_ROOT"

manifest_path="$SUITE_WORKDIR/manifest.json"
jq -n \
  --arg provider "$CLOUD_PROVIDER" \
  --arg terraform_stack "$(provider_sequential_stack_name)" \
  --arg run_id "$RUN_ID" \
  --arg attempt "$ATTEMPT" \
  --arg scaling_mode "$SCALING_MODE" \
  --arg k6_profile "$K6_PROFILE" \
  --arg test_duration "$TEST_DURATION" \
  --argjson inter_case_delay_seconds "$INTER_CASE_DELAY" \
  --argjson architecture_switch_delay_seconds "$ARCHITECTURE_SWITCH_DELAY" \
  --arg s3_run_uri "$S3_RUN_URI" \
  --arg started_at_utc "$SUITE_STARTED_AT_UTC" \
  --argjson architecture_order "$(words_json_array "$ARCHITECTURE_ORDER")" \
  --argjson scenario_rps_matrix "$(matrix_json)" \
  '{provider:$provider, execution_mode:"sequential", terraform_stack:$terraform_stack, run_id:$run_id, attempt:$attempt, scaling_mode:$scaling_mode, k6_profile:$k6_profile, test_duration:$test_duration, inter_case_delay_seconds:$inter_case_delay_seconds, architecture_switch_delay_seconds:$architecture_switch_delay_seconds, architecture_order:$architecture_order, scenario_rps_matrix:$scenario_rps_matrix, s3_run_uri:$s3_run_uri, started_at_utc:$started_at_utc}' \
  > "$manifest_path"
benchmark_aws s3 cp "$manifest_path" "${S3_RUN_URI}/_suite/manifest.json" >/dev/null
log_info "Sequential suite manifest uploaded to ${S3_RUN_URI}/_suite/manifest.json"
log_info "Warming S3 result-status cache for sequential suite resume and ETA checks..."
prime_case_result_status_cache || true
log_info "Initial S3 result-status cache warmup finished."

suite_failed=0
total_cases=0
while IFS=$'\t' read -r scenario scenario_rps_levels; do
  for _ in $scenario_rps_levels; do
    total_cases=$((total_cases + 1))
  done
done < "$MATRIX_TSV"

architecture_index=0
architecture_count="$(wc -w <<<"$ARCHITECTURE_ORDER" | tr -d '[:space:]')"
total_suite_cases=$((total_cases * architecture_count))
completed_suite_cases=0
for architecture in $ARCHITECTURE_ORDER; do
  architecture_index=$((architecture_index + 1))
  phase_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_info "=== Sequential Architecture: ${architecture} ==="
  phase_has_pending_cases=false
  phase_deployed_now=false
  if architecture_has_pending_cases "$architecture"; then
    phase_has_pending_cases=true
    if [ "$SEQUENTIAL_RESUME_SKIP_READY_DEPLOY" = "true" ] && architecture_ready_for_resume "$architecture"; then
      log_info "Architecture ${architecture} is already ready with IMAGE_TAG=${IMAGE_TAG} and SCALING_MODE=${SCALING_MODE}; skipping resume redeploy."
    else
      phase_deployed_now=true
      ARCHITECTURE="$architecture" SCALING_MODE="$SCALING_MODE" IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" CLOUD_PROVIDER="$CLOUD_PROVIDER" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" bash scripts/deploy-sequential-architecture.sh
    fi
  else
    log_info "All cases for ${architecture} already exist in S3; skipping architecture deploy."
  fi

  completed_architecture_cases=0
  architecture_ran_case=false
  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue
    log_info "=== Sequential Scenario: ${architecture}/${scenario} ==="
    scenario_case_index=0
    scenario_case_count="$(wc -w <<<"$scenario_rps_levels" | tr -d '[:space:]')"
    scenario_skip_case_setup=false

    if scenario_has_pending_cases "$architecture" "$scenario"; then
      setup_reuse_scope="$(scenario_setup_reuse_scope "$scenario")"
      if [ "$setup_reuse_scope" = "per_scenario" ]; then
        setup_class="$(scenario_setup_class "$scenario")"
        log_info "=== Sequential Scenario Setup ==="
        log_info "  architecture  : $architecture"
        log_info "  scenario      : $scenario"
        log_info "  setup_scope   : $setup_reuse_scope"
        if [ "$phase_deployed_now" = "true" ] && [ "$architecture_ran_case" = "false" ]; then
          if [ "$setup_class" = "enrichment" ]; then
            log_info "  action        : prepare enrichment once using fresh deploy baseline"
            prepare_enrichment_active "$architecture"
          else
            log_info "  action        : reuse fresh deploy reset+seed baseline"
          fi
        else
          log_info "  action        : run scenario setup once before pending RPS cases"
          run_scenario_data_setup "$architecture" "$scenario"
        fi
        scenario_skip_case_setup=true
      fi
    else
      log_info "No pending RPS cases remain for ${architecture}/${scenario}; skipping scenario setup and reusing existing S3 results where available."
    fi

    for target_rps in $scenario_rps_levels; do
      scenario_case_index=$((scenario_case_index + 1))
      case_s3_uri="${S3_RUN_URI}/${architecture}/${scenario}/${target_rps}rps/${ATTEMPT}"
      log_info "--- Sequential Case Start: ${architecture}/${scenario}/${target_rps}rps (${scenario_case_index}/${scenario_case_count} in scenario) ---"

      log_info "Checking if case already exists in S3: ${architecture}/${scenario}/${target_rps}rps"
      result_status_json=""
      if ! case_missing_in_s3 "$architecture" "$scenario" "$target_rps"; then
        result_status_json="$(benchmark_aws s3 cp "${case_s3_uri}/result-status.json" - 2>/dev/null || true)"
      fi
      if [ -n "$result_status_json" ] && jq -e . >/dev/null 2>&1 <<<"$result_status_json"; then
        set_case_result_status_cache "$architecture" "$scenario" "$target_rps" "present"
        log_info "=== Case already completed in S3: ${architecture}/${scenario}/${target_rps}rps (SKIPPING RUN) ==="
        k6_exit_code="$(jq -r '.k6_exit_code // "null"' <<<"$result_status_json")"
        s3_exit_code="$(jq -r '.s3_exit_code // "null"' <<<"$result_status_json")"
        classification_hint="$(jq -r '.classification_hint // "unknown"' <<<"$result_status_json")"
        
        # Download thresholds.json if it exists to classify properly
        thresholds_json="$(benchmark_aws s3 cp "${case_s3_uri}/thresholds.json" - 2>/dev/null || true)"
        
        case_exit_code=0
        if [ "$s3_exit_code" != "0" ] || [ "$classification_hint" = "runtime_failed" ] || { [ "$k6_exit_code" != "null" ] && [ "$k6_exit_code" != "0" ] && [ "$k6_exit_code" != "99" ]; }; then
          case_exit_code=1
        elif [ -n "$thresholds_json" ] && jq -e '[.. | objects | select(has("ok")) | .ok] | any(. == false)' >/dev/null 2>&1 <<<"$thresholds_json"; then
          case_exit_code=1
        elif [ "$k6_exit_code" = "0" ] && [ -n "$thresholds_json" ] && jq -e '[.. | objects | select(has("ok")) | .ok] | all(. == true)' >/dev/null 2>&1 <<<"$thresholds_json"; then
          case_exit_code=0
        elif [ "$classification_hint" = "threshold_failed" ]; then
          case_exit_code=1
        fi
        
        case_timing_json="$(
          sequential_case_timing_json \
            "$architecture" \
            "$case_s3_uri" \
            "2026-06-04T00:00:00Z" \
            "2026-06-04T00:00:00Z"
        )"
        
        case_status="pass"
        if [ "$case_exit_code" -ne 0 ]; then
          case_status="non_pass"
          suite_failed=1
        fi

        jq -cn \
          --arg architecture "$architecture" \
          --arg scenario "$scenario" \
          --argjson target_rps "$target_rps" \
          --arg status "$case_status" \
          --argjson exit_code "$case_exit_code" \
          --arg s3_uri "$case_s3_uri" \
          --argjson timing "$case_timing_json" \
          '{architecture:$architecture, scenario:$scenario, target_rps:$target_rps, status:$status, exit_code:$exit_code, s3_uri:$s3_uri} + $timing' >> "$CASES_JSONL"
          
        completed_architecture_cases=$((completed_architecture_cases + 1))
        completed_suite_cases=$((completed_suite_cases + 1))
        log_info "--- Sequential Case End: ${architecture}/${scenario}/${target_rps}rps (reused existing S3 result) ---"
        continue
      elif [ -n "$result_status_json" ]; then
        log_warn "existing result-status.json for ${architecture}/${scenario}/${target_rps}rps is unreadable; rerunning case."
        set_case_result_status_cache "$architecture" "$scenario" "$target_rps" "missing"
      fi

      current_case_estimate_seconds="$CASE_ESTIMATE_SECONDS"
      current_eta_mode="per_case_setup"
      if [ "$scenario_skip_case_setup" = "true" ]; then
        current_case_estimate_seconds="$REUSED_CASE_ESTIMATE_SECONDS"
        current_eta_mode="per_scenario_reuse"
      fi

      pending_scenario_cases="$(count_pending_scenario_cases_from "$scenario" "$target_rps" "$architecture")"
      pending_architecture_cases="$(count_pending_architecture_cases_from "$architecture" "$scenario" "$target_rps")"
      pending_future_architecture_cases="$(count_pending_future_architecture_cases "$architecture")"
      pending_current_architecture_case_seconds="$(count_pending_architecture_case_seconds_from "$architecture" "$scenario" "$target_rps")"
      pending_future_architecture_case_seconds="$(count_pending_future_architecture_case_seconds "$architecture")"
      scenario_remaining_case_seconds="$(scenario_pending_case_seconds "$(scenario_setup_reuse_scope "$scenario")" "$pending_scenario_cases" "$scenario_skip_case_setup")"

      print_case_eta \
        "$architecture" \
        "$scenario" \
        "$target_rps" \
        "$((completed_suite_cases + 1))" \
        "$total_suite_cases" \
        "$scenario_case_index" \
        "$scenario_case_count" \
        "$completed_architecture_cases" \
        "$total_cases" \
        "$architecture_index" \
        "$architecture_count" \
        "$current_case_estimate_seconds" \
        "$K6_CASE_ESTIMATE_SECONDS" \
        "$current_eta_mode" \
        "$pending_scenario_cases" \
        "$pending_architecture_cases" \
        "$pending_future_architecture_cases" \
        "$scenario_remaining_case_seconds" \
        "$((pending_current_architecture_case_seconds + pending_future_architecture_case_seconds))"

      case_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_info "Launching sequential benchmark case runner for ${architecture}/${scenario}/${target_rps}rps..."
      set +e
      ARCHITECTURE="$architecture" \
      ARCHITECTURE_ORDER="$ARCHITECTURE_ORDER" \
      SCENARIO="$scenario" \
      TARGET_RPS="$target_rps" \
      RUN_ID="$RUN_ID" \
      ATTEMPT="$ATTEMPT" \
      SCALING_MODE="$SCALING_MODE" \
      K6_PROFILE="$K6_PROFILE" \
      TEST_DURATION="$TEST_DURATION" \
      S3_BUCKET="$S3_BUCKET" \
      DATADOG_ENABLED="$DATADOG_ENABLED" \
      DATADOG_ENV="$DATADOG_ENV" \
      AWS_REGION="$AWS_REGION" \
      ECR_NAMESPACE="$ECR_NAMESPACE" \
      CLOUD_PROVIDER="$CLOUD_PROVIDER" \
      DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
      SKIP_SCENARIO_DATA_SETUP="$scenario_skip_case_setup" \
      IMAGE_TAG="$IMAGE_TAG" \
      bash scripts/run-benchmark-sequential.sh
      case_exit_code=$?
      set -e
      case_finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_info "Sequential benchmark case runner finished for ${architecture}/${scenario}/${target_rps}rps with exit code ${case_exit_code}."
      case_timing_json="$(
        sequential_case_timing_json \
          "$architecture" \
          "$case_s3_uri" \
          "$case_started_at_utc" \
          "$case_finished_at_utc"
      )"

      case_status="pass"
      if [ "$case_exit_code" -ne 0 ]; then
        case_status="non_pass"
        suite_failed=1
      fi
      log_info "Sequential case classification for ${architecture}/${scenario}/${target_rps}rps: ${case_status}"

      jq -cn \
        --arg architecture "$architecture" \
        --arg scenario "$scenario" \
        --argjson target_rps "$target_rps" \
        --arg status "$case_status" \
        --argjson exit_code "$case_exit_code" \
        --arg s3_uri "$case_s3_uri" \
        --argjson timing "$case_timing_json" \
        '{architecture:$architecture, scenario:$scenario, target_rps:$target_rps, status:$status, exit_code:$exit_code, s3_uri:$s3_uri} + $timing' >> "$CASES_JSONL"

      log_info "Refreshing S3 result-status cache for ${architecture}/${scenario}/${target_rps}rps..."
      if ! case_result_present_in_s3_uncached "$architecture" "$scenario" "$target_rps"; then
        log_warn "result-status.json is still missing in S3 after sequential case ${architecture}/${scenario}/${target_rps}rps; future ETA checks will treat it as pending."
      else
        log_info "S3 result-status cache refreshed for ${architecture}/${scenario}/${target_rps}rps."
      fi

      completed_architecture_cases=$((completed_architecture_cases + 1))
      completed_suite_cases=$((completed_suite_cases + 1))
      architecture_ran_case=true
      log_info "--- Sequential Case End: ${architecture}/${scenario}/${target_rps}rps ---"
      if [ "$INTER_CASE_DELAY" != "0" ] && [ "$completed_architecture_cases" -lt "$total_cases" ]; then
        log_info "Waiting ${INTER_CASE_DELAY}s before the next sequential case to let the system stabilize..."
        sleep "$INTER_CASE_DELAY"
      fi
    done
  done < "$MATRIX_TSV"

  phase_finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_info "Sequential architecture phase finished for ${architecture}."
  jq -cn \
    --arg architecture "$architecture" \
    --arg started_at_utc "$phase_started_at_utc" \
    --arg finished_at_utc "$phase_finished_at_utc" \
    --argjson case_count "$completed_architecture_cases" \
    --argjson architecture_index "$architecture_index" \
    --argjson architecture_count "$architecture_count" \
    --argjson next_switch_delay_seconds "$ARCHITECTURE_SWITCH_DELAY" \
    '{architecture:$architecture, architecture_index:$architecture_index, architecture_count:$architecture_count, case_count:$case_count, started_at_utc:$started_at_utc, finished_at_utc:$finished_at_utc, next_switch_delay_seconds:(if $architecture_index < $architecture_count then $next_switch_delay_seconds else 0 end)}' >> "$PHASES_JSONL"

  if [ "$phase_has_pending_cases" = "true" ] && [ "$architecture_index" -lt "$architecture_count" ] && [ "$ARCHITECTURE_SWITCH_DELAY" != "0" ]; then
    log_info "Waiting ${ARCHITECTURE_SWITCH_DELAY}s before switching to the next architecture for cleaner Datadog windows..."
    sleep "$ARCHITECTURE_SWITCH_DELAY"
  fi
done

summary_path="$SUITE_WORKDIR/summary.json"
finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
suite_status="pass"
if [ "$suite_failed" -ne 0 ]; then
  suite_status="completed_with_non_pass_cases"
fi

log_info "Writing sequential suite summary to ${summary_path}..."
jq -s \
  --arg provider "$CLOUD_PROVIDER" \
  --arg terraform_stack "$(provider_sequential_stack_name)" \
  --arg run_id "$RUN_ID" \
  --arg attempt "$ATTEMPT" \
  --arg suite_status "$suite_status" \
  --arg s3_run_uri "$S3_RUN_URI" \
  --arg started_at_utc "$SUITE_STARTED_AT_UTC" \
  --arg finished_at_utc "$finished_at_utc" \
  --argjson architecture_order "$(words_json_array "$ARCHITECTURE_ORDER")" \
  --argjson inter_case_delay_seconds "$INTER_CASE_DELAY" \
  --argjson architecture_switch_delay_seconds "$ARCHITECTURE_SWITCH_DELAY" \
  --slurpfile phases "$PHASES_JSONL" \
  '{provider:$provider, execution_mode:"sequential", terraform_stack:$terraform_stack, run_id:$run_id, attempt:$attempt, suite_status:$suite_status, architecture_order:$architecture_order, inter_case_delay_seconds:$inter_case_delay_seconds, architecture_switch_delay_seconds:$architecture_switch_delay_seconds, s3_run_uri:$s3_run_uri, started_at_utc:$started_at_utc, finished_at_utc:$finished_at_utc, architecture_phases:$phases, cases:.}' \
  "$CASES_JSONL" > "$summary_path"
benchmark_aws s3 cp "$summary_path" "${S3_RUN_URI}/_suite/summary.json" >/dev/null
log_info "Sequential suite summary uploaded to ${S3_RUN_URI}/_suite/summary.json"

if [ "$AUTO_DESTROY_CONFIRMED" = "true" ]; then
  make "$(provider_sequential_destroy_target)"
fi

log_info "=== Sequential Benchmark Suite Complete ==="
log_info "  run_id       : $RUN_ID"
log_info "  suite_status : $suite_status"
log_info "  report_s3_uri: $S3_RUN_URI"

if [ "$suite_failed" -ne 0 ]; then
  exit 1
fi
