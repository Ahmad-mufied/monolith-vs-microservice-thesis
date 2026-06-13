#!/usr/bin/env bash
# Run the full benchmark matrix for one scaling mode.
set -euo pipefail

source scripts/lib/shared-env.sh

explicit_aws_region="${AWS_REGION:-}"
explicit_s3_bucket="${S3_BUCKET:-}"

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

if [ -n "$explicit_aws_region" ]; then
  AWS_REGION="$explicit_aws_region"
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

SCALING_MODE="${SCALING_MODE:-fixed}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
SCENARIOS="${SCENARIOS:-login create-transaction enriched-transactions}"
RPS_LEVELS="${RPS_LEVELS:-1000 2500 5000 7500 10000}"
SCENARIO_RPS_MATRIX="${SCENARIO_RPS_MATRIX:-}"
INTER_CASE_DELAY="${INTER_CASE_DELAY:-0}"
MAX_INTER_CASE_DELAY=86400
AUTO_DESTROY_CONFIRMED="${AUTO_DESTROY_CONFIRMED:-false}"
ALLOW_NONSTANDARD_SCALING_PROFILE="${ALLOW_NONSTANDARD_SCALING_PROFILE:-false}"
SKIP_BENCHMARK_PREFLIGHT="${SKIP_BENCHMARK_PREFLIGHT:-false}"
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"
K6_PROFILE="${K6_PROFILE:-}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-}"
RUN_ID="${RUN_ID:-}"
ATTEMPT="${ATTEMPT:-}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
SUITE_WORKDIR="$(mktemp -d)"
SUITE_CASES_JSONL="$SUITE_WORKDIR/cases.jsonl"
SUITE_MATRIX_TSV="$SUITE_WORKDIR/scenario-rps-matrix.tsv"
RENDER_ROOT="$SUITE_WORKDIR/rendered"
RENDERED_APP_MONOLITH_DIR="$RENDER_ROOT/deployments/k8s/cloud/monolith"
RENDERED_APP_MICROSERVICES_DIR="$RENDER_ROOT/deployments/k8s/cloud/microservices"
RENDERED_MONOLITH_OVERLAY_DIR="$RENDERED_APP_MONOLITH_DIR/overlays/$SCALING_MODE"
RENDERED_MICROSERVICES_OVERLAY_DIR="$RENDERED_APP_MICROSERVICES_DIR/overlays/$SCALING_MODE"

cleanup() {
  rm -rf "$SUITE_WORKDIR"
}
trap cleanup EXIT
: > "$SUITE_CASES_JSONL"
: > "$SUITE_MATRIX_TSV"

normalize_nonnegative_integer() {
  local value="$1"

  value="$(sed 's/^0*//' <<<"$value")"
  if [ -z "$value" ]; then
    printf '0'
    return 0
  fi

  printf '%s' "$value"
}

integer_greater_than() {
  local left="$1"
  local right="$2"

  if [ "${#left}" -gt "${#right}" ]; then
    return 0
  fi

  if [ "${#left}" -lt "${#right}" ]; then
    return 1
  fi

  [[ "$left" > "$right" ]]
}

sanitize_experiment_name() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  printf '%s' "$value"
}

sanitize_run_id_component() {
  local label="$1"
  local value="$2"
  local sanitized

  sanitized="$(sanitize_experiment_name "$value")"
  if [ -z "$sanitized" ]; then
    echo "ERROR: ${label} '$value' does not contain any usable slug characters" >&2
    return 1
  fi

  printf '%s' "$sanitized"
}

trim_whitespace() {
  local value="$1"

  value="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$value")"
  printf '%s' "$value"
}

validate_supported_scenario() {
  local scenario="$1"

  case "$scenario" in
    login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items) ;;
    *)
      echo "ERROR: unsupported scenario '$scenario' (expected: login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items)" >&2
      return 1
      ;;
  esac
}

validate_rps_words() {
  local rps_words="$1"
  local target_rps

  if [ -z "${rps_words//[[:space:]]/}" ]; then
    echo "ERROR: RPS list must contain at least one positive integer" >&2
    return 1
  fi

  for target_rps in $rps_words; do
    if ! [[ "$target_rps" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: invalid RPS value '$target_rps' (expected: positive integer)" >&2
      return 1
    fi
  done
}

parse_rps_csv_to_words() {
  local rps_csv="$1"
  local normalized

  normalized="$(printf '%s' "$rps_csv" | tr ',' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  printf '%s' "$normalized"
}

validate_matrix_inputs() {
  local normalized_inter_case_delay
  local sanitized_experiment_name
  local matrix_entry
  local matrix_entry_count=0
  local scenario
  local rps_csv
  local rps_words

  case "$SCALING_MODE" in
    fixed|hpa) ;;
    *)
      echo "ERROR: unsupported SCALING_MODE '$SCALING_MODE' (expected: fixed|hpa)" >&2
      return 1
      ;;
  esac

  if [ -n "${SCENARIO_RPS_MATRIX//[[:space:]]/}" ]; then
    while IFS= read -r matrix_entry; do
      matrix_entry="$(trim_whitespace "$matrix_entry")"
      if [ -z "$matrix_entry" ]; then
        continue
      fi

      if [[ "$matrix_entry" != *:* ]]; then
        echo "ERROR: invalid SCENARIO_RPS_MATRIX entry '$matrix_entry' (expected: scenario:rps1,rps2,...)" >&2
        return 1
      fi

      scenario="$(trim_whitespace "${matrix_entry%%:*}")"
      rps_csv="$(trim_whitespace "${matrix_entry#*:}")"
      validate_supported_scenario "$scenario" || return 1
      rps_words="$(parse_rps_csv_to_words "$rps_csv")"
      validate_rps_words "$rps_words" || return 1
      matrix_entry_count=$((matrix_entry_count + 1))
    done < <(tr ';' '\n' <<<"$SCENARIO_RPS_MATRIX")

    if [ "$matrix_entry_count" -eq 0 ]; then
      echo "ERROR: SCENARIO_RPS_MATRIX must contain at least one scenario:rps entry" >&2
      return 1
    fi
  else
    if [ -z "${SCENARIOS//[[:space:]]/}" ]; then
      echo "ERROR: SCENARIOS must contain at least one scenario" >&2
      return 1
    fi

    for scenario in $SCENARIOS; do
      validate_supported_scenario "$scenario" || return 1
    done

    validate_rps_words "$RPS_LEVELS" || return 1
  fi

  if ! [[ "$INTER_CASE_DELAY" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid INTER_CASE_DELAY value '$INTER_CASE_DELAY' (expected: non-negative integer seconds, e.g. 300 for 5 minutes)" >&2
    return 1
  fi

  normalized_inter_case_delay="$(normalize_nonnegative_integer "$INTER_CASE_DELAY")"
  if integer_greater_than "$normalized_inter_case_delay" "$MAX_INTER_CASE_DELAY"; then
    echo "ERROR: invalid INTER_CASE_DELAY value '$INTER_CASE_DELAY' (maximum: ${MAX_INTER_CASE_DELAY} seconds)" >&2
    return 1
  fi

  if [ -n "$EXPERIMENT_NAME" ]; then
    sanitized_experiment_name="$(sanitize_experiment_name "$EXPERIMENT_NAME")"
    if [ -z "$sanitized_experiment_name" ]; then
      echo "ERROR: EXPERIMENT_NAME '$EXPERIMENT_NAME' does not contain any usable slug characters" >&2
      return 1
    fi
  fi

  case "$AUTO_DESTROY_CONFIRMED" in
    true|false) ;;
    *)
      echo "ERROR: invalid AUTO_DESTROY_CONFIRMED value '$AUTO_DESTROY_CONFIRMED' (expected: true|false)" >&2
      return 1
      ;;
  esac

  case "$ALLOW_NONSTANDARD_SCALING_PROFILE" in
    true|false) ;;
    *)
      echo "ERROR: invalid ALLOW_NONSTANDARD_SCALING_PROFILE value '$ALLOW_NONSTANDARD_SCALING_PROFILE' (expected: true|false)" >&2
      return 1
      ;;
  esac

  case "$SKIP_BENCHMARK_PREFLIGHT" in
    true|false) ;;
    *)
      echo "ERROR: invalid SKIP_BENCHMARK_PREFLIGHT value '$SKIP_BENCHMARK_PREFLIGHT' (expected: true|false)" >&2
      return 1
      ;;
  esac

  if [ "$AUTO_DESTROY_CONFIRMED" = "true" ] && [ -z "$RUN_ID" ] && [ -z "$EXPERIMENT_NAME" ]; then
    echo "ERROR: AUTO_DESTROY_CONFIRMED=true requires EXPERIMENT_NAME or RUN_ID so the unattended run has a stable identifier" >&2
    return 1
  fi
}

validate_matrix_inputs
INTER_CASE_DELAY="$(normalize_nonnegative_integer "$INTER_CASE_DELAY")"
if [ -n "$EXPERIMENT_NAME" ]; then
  EXPERIMENT_NAME="$(sanitize_run_id_component "EXPERIMENT_NAME" "$EXPERIMENT_NAME")"
fi

if [ -z "$K6_PROFILE" ]; then
  if [ "$SCALING_MODE" = "hpa" ]; then
    K6_PROFILE="hpa"
  else
    K6_PROFILE="steady"
  fi
fi

validate_scaling_profile_pairing() {
  if [ "$ALLOW_NONSTANDARD_SCALING_PROFILE" = "true" ]; then
    return 0
  fi

  case "$SCALING_MODE:$K6_PROFILE" in
    fixed:steady|fixed:ramp|fixed:smoke|hpa:hpa)
      return 0
      ;;
    fixed:hpa)
      echo "ERROR: K6_PROFILE=hpa must not be used with SCALING_MODE=fixed. Use SCALING_MODE=hpa with HPA overlays, or set ALLOW_NONSTANDARD_SCALING_PROFILE=true only if you are intentionally running a nonstandard experiment." >&2
      return 1
      ;;
    hpa:steady|hpa:ramp|hpa:smoke)
      echo "ERROR: SCALING_MODE=hpa requires K6_PROFILE=hpa for the standard autoscaling experiment. Set ALLOW_NONSTANDARD_SCALING_PROFILE=true only if you intentionally want a nonstandard pairing." >&2
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

validate_scaling_profile_pairing

run_suite_preflight() {
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

if [ -z "$RUN_ID" ]; then
  sanitized_image_tag=""
  run_prefix="$(provider_default_run_prefix parallel)"
  if [ -n "$EXPERIMENT_NAME" ]; then
    sanitized_image_tag="$(sanitize_run_id_component "IMAGE_TAG" "$IMAGE_TAG")"
    RUN_ID="${run_prefix}-${SCALING_MODE}-${EXPERIMENT_NAME}-${sanitized_image_tag}"
  else
    RUN_ID="${run_prefix}-${SCALING_MODE}-$(date +%Y%m%d-%H%M)"
  fi
fi

S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"
SUITE_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EFFECTIVE_SCENARIOS=""
EFFECTIVE_RPS_LEVELS=""
TOTAL_CASES=0

words_json_array() {
  local words="$1"
  jq -cn --arg words "$words" '$words | [scan("\\S+")]'
}

word_count() {
  local words="$1"
  set -- $words
  printf '%s' "$#"
}

build_suite_matrix_file() {
  local matrix_entry
  local scenario
  local rps_csv
  local rps_words

  : > "$SUITE_MATRIX_TSV"

  if [ -n "${SCENARIO_RPS_MATRIX//[[:space:]]/}" ]; then
    while IFS= read -r matrix_entry; do
      matrix_entry="$(trim_whitespace "$matrix_entry")"
      if [ -z "$matrix_entry" ]; then
        continue
      fi

      scenario="$(trim_whitespace "${matrix_entry%%:*}")"
      rps_csv="$(trim_whitespace "${matrix_entry#*:}")"
      rps_words="$(parse_rps_csv_to_words "$rps_csv")"
      printf '%s\t%s\n' "$scenario" "$rps_words" >> "$SUITE_MATRIX_TSV"
    done < <(tr ';' '\n' <<<"$SCENARIO_RPS_MATRIX")
    return 0
  fi

  for scenario in $SCENARIOS; do
    printf '%s\t%s\n' "$scenario" "$RPS_LEVELS" >> "$SUITE_MATRIX_TSV"
  done
}

derive_effective_suite_metadata() {
  local scenario
  local rps_words
  local target_rps
  local scenarios_accumulator=""
  local rps_union_accumulator=""

  EFFECTIVE_SCENARIOS=""
  EFFECTIVE_RPS_LEVELS=""
  TOTAL_CASES=0

  while IFS=$'\t' read -r scenario rps_words; do
    [ -z "$scenario" ] && continue
    scenarios_accumulator="${scenarios_accumulator}${scenario}"$'\n'
    for target_rps in $rps_words; do
      TOTAL_CASES=$((TOTAL_CASES + 1))
      rps_union_accumulator="${rps_union_accumulator}${target_rps}"$'\n'
    done
  done < "$SUITE_MATRIX_TSV"

  EFFECTIVE_SCENARIOS="$(printf '%s' "$scenarios_accumulator" | awk 'NF && !seen[$0]++' | paste -sd' ' -)"
  EFFECTIVE_RPS_LEVELS="$(printf '%s' "$rps_union_accumulator" | awk 'NF' | sort -n -u | paste -sd' ' -)"
}

scenario_rps_matrix_json() {
  jq -Rs '
    split("\n")
    | map(select(length > 0))
    | map(
        split("\t") as $parts
        | {
            scenario: $parts[0],
            rps_levels: (($parts[1] // "") | split(" ") | map(select(length > 0) | tonumber))
          }
      )
  ' < "$SUITE_MATRIX_TSV"
}

case_timing_source_from_architecture_sources() {
  local all_attempt_metadata=true
  local all_orchestrator=true
  local source

  for source in "$@"; do
    if [ "$source" != "attempt_metadata" ] && [ "$source" != "datadog_artifact" ]; then
      all_attempt_metadata=false
    fi
    if [ "$source" != "orchestrator" ] && [ "$source" != "attempt_metadata_partial" ]; then
      all_orchestrator=false
    fi
  done

  if [ "$all_attempt_metadata" = true ]; then
    printf 'attempt_metadata'
    return 0
  fi

  if [ "$all_orchestrator" = true ]; then
    printf 'orchestrator'
    return 0
  fi

  printf 'mixed'
}

parallel_case_timing_json() {
  local scenario="$1"
  local target_rps="$2"
  local case_started_at_utc="$3"
  local case_finished_at_utc="$4"
  local monolith_uri="${S3_RUN_URI}/monolith/${scenario}/${target_rps}rps/${ATTEMPT}"
  local microservices_uri="${S3_RUN_URI}/microservices/${scenario}/${target_rps}rps/${ATTEMPT}"
  local monolith_timing_json
  local microservices_timing_json
  local monolith_started_at_utc
  local monolith_finished_at_utc
  local monolith_timing_source
  local microservices_started_at_utc
  local microservices_finished_at_utc
  local microservices_timing_source
  local case_started_from_attempts
  local case_finished_from_attempts
  local case_timing_source

  monolith_timing_json="$(
    resolve_attempt_timing_json \
      "$monolith_uri" \
      "$case_started_at_utc" \
      "$case_finished_at_utc" \
      "parallel ${scenario} ${target_rps}rps monolith"
  )"
  microservices_timing_json="$(
    resolve_attempt_timing_json \
      "$microservices_uri" \
      "$case_started_at_utc" \
      "$case_finished_at_utc" \
      "parallel ${scenario} ${target_rps}rps microservices"
  )"

  monolith_started_at_utc="$(jq -r '.started_at_utc' <<<"$monolith_timing_json")"
  monolith_finished_at_utc="$(jq -r '.finished_at_utc' <<<"$monolith_timing_json")"
  monolith_timing_source="$(jq -r '.timing_source' <<<"$monolith_timing_json")"
  microservices_started_at_utc="$(jq -r '.started_at_utc' <<<"$microservices_timing_json")"
  microservices_finished_at_utc="$(jq -r '.finished_at_utc' <<<"$microservices_timing_json")"
  microservices_timing_source="$(jq -r '.timing_source' <<<"$microservices_timing_json")"

  case_started_from_attempts="$(
    jq -nr \
      --arg monolith "$monolith_started_at_utc" \
      --arg microservices "$microservices_started_at_utc" \
      '[ $monolith, $microservices ] | sort | .[0]'
  )"
  case_finished_from_attempts="$(
    jq -nr \
      --arg monolith "$monolith_finished_at_utc" \
      --arg microservices "$microservices_finished_at_utc" \
      '[ $monolith, $microservices ] | sort | .[1]'
  )"
  case_timing_source="$(
    case_timing_source_from_architecture_sources \
      "$monolith_timing_source" \
      "$microservices_timing_source"
  )"

  jq -cn \
    --arg started_at_utc "${case_started_from_attempts:-$case_started_at_utc}" \
    --arg finished_at_utc "${case_finished_from_attempts:-$case_finished_at_utc}" \
    --arg timing_source "$case_timing_source" \
    --argjson monolith "$monolith_timing_json" \
    --argjson microservices "$microservices_timing_json" \
    '{
      started_at_utc: $started_at_utc,
      finished_at_utc: $finished_at_utc,
      timing_source: $timing_source,
      architectures: {
        monolith: $monolith,
        microservices: $microservices
      }
    }'
}

next_attempt_from_s3() {
  local run_uri="$1"
  local scenario_filter="${2:-}"
  local listing
  local listing_error
  local latest
  local next

  listing_error="$(mktemp)"
  if ! listing="$(benchmark_aws s3 ls "$run_uri/" --recursive 2>"$listing_error")"; then
    if [ -s "$listing_error" ]; then
      cat "$listing_error" >&2
      rm -f "$listing_error"
      echo "ERROR: unable to inspect S3 prefix for automatic attempt selection: $run_uri" >&2
      return 1
    fi

    rm -f "$listing_error"
    printf 'attempt-01'
    return 0
  fi
  rm -f "$listing_error"

  if [ -z "$listing" ]; then
    printf 'attempt-01'
    return 0
  fi

  if [ -n "$scenario_filter" ]; then
    local pre_filter_count
    pre_filter_count="$(wc -l <<<"$listing" | tr -d '[:space:]')"
    listing="$(grep "/${scenario_filter}/" <<<"$listing" || true)"
    local post_filter_count
    post_filter_count="$(wc -l <<<"$listing" | tr -d '[:space:]')"
    echo "  attempt search : scenario='${scenario_filter}' matched ${post_filter_count}/${pre_filter_count} S3 entries" >&2
  fi

  if [ -z "$listing" ]; then
    printf 'attempt-01'
    return 0
  fi

  latest="$(sed -n 's|.*/attempt-\([0-9][0-9]*\)/.*|\1|p' <<<"$listing" | sort -n | tail -n 1)"

  if [ -z "$latest" ]; then
    printf 'attempt-01'
    return 0
  fi

  next=$((10#$latest + 1))
  printf 'attempt-%02d' "$next"
}

next_attempt_from_s3_per_rps() {
  local run_uri="$1"
  local scenario="$2"
  local rps_words="$3"
  local listing
  local listing_error
  local max_attempt=0
  local all_have_max=true
  local rps
  local rps_dir
  local attempt_num

  listing_error="$(mktemp)"
  if ! listing="$(benchmark_aws s3 ls "$run_uri/" --recursive 2>"$listing_error")"; then
    if [ -s "$listing_error" ]; then
      cat "$listing_error" >&2
      rm -f "$listing_error"
      echo "ERROR: unable to inspect S3 prefix for automatic attempt selection: $run_uri" >&2
      return 1
    fi

    rm -f "$listing_error"
    printf 'attempt-01'
    return 0
  fi
  rm -f "$listing_error"

  if [ -z "$listing" ]; then
    printf 'attempt-01'
    return 0
  fi

  local scenario_listing
  scenario_listing="$(grep "/${scenario}/" <<<"$listing" || true)"

  if [ -z "$scenario_listing" ]; then
    echo "  attempt search : scenario='${scenario}' no existing entries → attempt-01" >&2
    printf 'attempt-01'
    return 0
  fi

  for rps in $rps_words; do
    rps_dir="${rps}rps"
    local rps_attempts
    rps_attempts="$(grep "/${rps_dir}/" <<<"$scenario_listing" | sed -n 's|.*/attempt-\([0-9][0-9]*\)/.*|\1|p' | sort -n | tail -n 1)"

    if [ -z "$rps_attempts" ]; then
      all_have_max=false
    else
      attempt_num=$((10#$rps_attempts))
      if [ "$attempt_num" -gt "$max_attempt" ]; then
        max_attempt=$attempt_num
      fi
    fi
  done

  if [ "$max_attempt" -eq 0 ]; then
    echo "  attempt search : scenario='${scenario}' rps='${rps_words}' no attempts found → attempt-01" >&2
    printf 'attempt-01'
    return 0
  fi

  # Second pass: verify every RPS actually has max_attempt, not just any attempt.
  # Without this, a mix of attempt-01 and attempt-02 would incorrectly return
  # attempt-03 (new run) instead of attempt-02 (continuation).
  for rps in $rps_words; do
    rps_dir="${rps}rps"
    local rps_attempts
    rps_attempts="$(grep "/${rps_dir}/" <<<"$scenario_listing" | sed -n 's|.*/attempt-\([0-9][0-9]*\)/.*|\1|p' | sort -n | tail -n 1)"
    if [ -z "$rps_attempts" ] || [ $((10#$rps_attempts)) -ne "$max_attempt" ]; then
      all_have_max=false
      break
    fi
  done

  if [ "$all_have_max" = false ]; then
    echo "  attempt search : scenario='${scenario}' rps='${rps_words}' some RPS missing attempt-$(printf '%02d' "$max_attempt") → attempt-$(printf '%02d' "$max_attempt") (continuation)" >&2
    printf 'attempt-%02d' "$max_attempt"
    return 0
  fi

  local next=$((max_attempt + 1))
  echo "  attempt search : scenario='${scenario}' rps='${rps_words}' all RPS have attempt-$(printf '%02d' "$max_attempt") → attempt-$(printf '%02d' "$next") (new run)" >&2
  printf 'attempt-%02d' "$next"
}

next_attempt_for_suite() {
  local run_uri="$1"
  local matrix_tsv="$2"
  local scenario
  local rps_words
  local suite_max=0

  while IFS=$'\t' read -r scenario rps_words; do
    [ -z "$scenario" ] && continue

    local case_attempt
    case_attempt="$(next_attempt_from_s3_per_rps "$run_uri" "$scenario" "$rps_words" 2>/dev/null)"
    local case_num=$((10#$(sed 's/attempt-//' <<<"$case_attempt")))

    if [ "$case_num" -gt "$suite_max" ]; then
      suite_max=$case_num
    fi
  done < "$matrix_tsv"

  if [ "$suite_max" -eq 0 ]; then
    printf 'attempt-01'
  else
    printf 'attempt-%02d' "$suite_max"
  fi
}

reset_and_seed_benchmark_data() {
  scale_down_app_workloads_for_data_reset

  kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_APP_MONOLITH_DIR/reset-monolith-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

  kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_APP_MICROSERVICES_DIR/reset-microservices-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

  kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_APP_MONOLITH_DIR/seed-monolith-benchmark-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

  kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_APP_MICROSERVICES_DIR/seed-microservices-benchmark-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

  restore_app_workloads_after_data_reset
}

reset_seed_and_prepare_enrichment_data() {
  scale_down_app_workloads_for_data_reset

  kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_APP_MONOLITH_DIR/reset-monolith-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

  kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_APP_MICROSERVICES_DIR/reset-microservices-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

  kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_APP_MONOLITH_DIR/seed-monolith-benchmark-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

  kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_APP_MICROSERVICES_DIR/seed-microservices-benchmark-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

  MONOLITH_PREPARE_MANIFEST_PATH="$RENDERED_APP_MONOLITH_DIR/prepare-monolith-enrichment-benchmark-data-job.yaml" \
  MICROSERVICES_PREPARE_MANIFEST_PATH="$RENDERED_APP_MICROSERVICES_DIR/prepare-microservices-enrichment-benchmark-data-job.yaml" \
  PREPARE_ENRICHMENT_TIMEOUT="600s" \
  bash scripts/prepare-enrichment-benchmark.sh

  restore_app_workloads_after_data_reset
}

scale_down_app_workloads_for_data_reset() {
  local svc

  kubectl --context=monolith delete hpa monolith -n mono --ignore-not-found
  if kubectl --context=monolith get deployment monolith -n mono >/dev/null 2>&1; then
    kubectl --context=monolith scale deployment monolith -n mono --replicas=0
    kubectl --context=monolith rollout status deployment/monolith -n mono --timeout=300s
  fi

  for svc in api-gateway auth-service item-service transaction-service; do
    kubectl --context=msa delete hpa "$svc" -n msa --ignore-not-found
  done

  for svc in api-gateway auth-service item-service transaction-service; do
    if kubectl --context=msa get deployment "$svc" -n msa >/dev/null 2>&1; then
      kubectl --context=msa scale deployment "$svc" -n msa --replicas=0
      kubectl --context=msa rollout status "deployment/${svc}" -n msa --timeout=300s
    fi
  done
}

restore_app_workloads_after_data_reset() {
  local svc

  kubectl --context=monolith apply -k "$RENDERED_MONOLITH_OVERLAY_DIR"
  kubectl --context=monolith rollout status deployment/monolith -n mono --timeout=300s

  kubectl --context=msa apply -k "$RENDERED_MICROSERVICES_OVERLAY_DIR"
  for svc in auth-service item-service transaction-service api-gateway; do
    kubectl --context=msa rollout status "deployment/${svc}" -n msa --timeout=300s
  done

  verify_live_scaling_mode_state
}

verify_live_scaling_mode_state() {
  local mono_hpa_present=0
  local msa_hpa_count=0

  if kubectl --context=monolith get hpa monolith -n mono >/dev/null 2>&1; then
    mono_hpa_present=1
  fi

  msa_hpa_count="$(
    kubectl --context=msa get hpa -n msa --no-headers 2>/dev/null | wc -l | tr -d '[:space:]'
  )"
  msa_hpa_count="${msa_hpa_count:-0}"

  if [ "$SCALING_MODE" = "hpa" ]; then
    if [ "$mono_hpa_present" -ne 1 ]; then
      echo "ERROR: expected monolith HPA to exist for SCALING_MODE=hpa, but none was found in namespace mono" >&2
      return 1
    fi
    if [ "$msa_hpa_count" -lt 4 ]; then
      echo "ERROR: expected microservices HPAs to exist for SCALING_MODE=hpa, but found only ${msa_hpa_count} HPA object(s) in namespace msa" >&2
      return 1
    fi
  else
    if [ "$mono_hpa_present" -ne 0 ]; then
      echo "ERROR: found monolith HPA while SCALING_MODE=fixed. Redeploy fixed overlays before running the fixed benchmark suite." >&2
      return 1
    fi
    if [ "$msa_hpa_count" -ne 0 ]; then
      echo "ERROR: found ${msa_hpa_count} microservices HPA object(s) while SCALING_MODE=fixed. Redeploy fixed overlays before running the fixed benchmark suite." >&2
      return 1
    fi
  fi
}

run_parallel_case() {
  local scenario="$1"
  local target_rps="$2"

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
  CLOUD_PROVIDER="$CLOUD_PROVIDER" \
  DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
  IMAGE_TAG="$IMAGE_TAG" \
  bash scripts/run-benchmark-parallel.sh
}

upload_suite_manifest() {
  local manifest_path="$SUITE_WORKDIR/manifest.json"
  local resource_configuration_json

  run_suite_preflight "suite manifest upload" "true"

  resource_configuration_json="$(suite_resource_configuration_json "$SCALING_MODE")"
  jq -n \
    --arg experiment_name "$EXPERIMENT_NAME" \
    --arg provider "$CLOUD_PROVIDER" \
    --arg terraform_stack "$(provider_parallel_stack_name)" \
    --arg run_id "$RUN_ID" \
    --arg attempt "$ATTEMPT" \
    --arg scaling_mode "$SCALING_MODE" \
    --arg k6_profile "$K6_PROFILE" \
    --arg test_duration "$TEST_DURATION" \
    --argjson inter_case_delay "$INTER_CASE_DELAY" \
    --arg s3_run_uri "$S3_RUN_URI" \
    --arg started_at_utc "$SUITE_STARTED_AT_UTC" \
    --argjson resource_configuration "$resource_configuration_json" \
    --argjson scenarios "$(words_json_array "$EFFECTIVE_SCENARIOS")" \
    --argjson rps_levels "$(words_json_array "$EFFECTIVE_RPS_LEVELS")" \
    --argjson scenario_rps_matrix "$(scenario_rps_matrix_json)" \
    '{
      experiment_name: (if $experiment_name == "" then null else $experiment_name end),
      provider: $provider,
      execution_mode: "parallel",
      terraform_stack: $terraform_stack,
      run_id: $run_id,
      attempt: $attempt,
      scaling_mode: $scaling_mode,
      k6_profile: $k6_profile,
      test_duration: $test_duration,
      inter_case_delay: $inter_case_delay,
      scenarios: $scenarios,
      rps_levels: ($rps_levels | map(tonumber)),
      scenario_rps_matrix: $scenario_rps_matrix,
      resource_configuration: $resource_configuration,
      s3_run_uri: $s3_run_uri,
      started_at_utc: $started_at_utc
    }' > "$manifest_path"

  benchmark_aws s3 cp "$manifest_path" "${S3_RUN_URI}/_suite/manifest.json" >/dev/null
}

append_case_summary() {
  local scenario="$1"
  local target_rps="$2"
  local status="$3"
  local exit_code="$4"
  local timing_json="$5"

  jq -cn \
    --arg scenario "$scenario" \
    --argjson target_rps "$target_rps" \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg monolith_uri "${S3_RUN_URI}/monolith/${scenario}/${target_rps}rps/${ATTEMPT}" \
    --arg microservices_uri "${S3_RUN_URI}/microservices/${scenario}/${target_rps}rps/${ATTEMPT}" \
    --argjson timing "$timing_json" \
    '{
      scenario: $scenario,
      target_rps: $target_rps,
      status: $status,
      exit_code: $exit_code,
      monolith_s3_uri: $monolith_uri,
      microservices_s3_uri: $microservices_uri
    } + $timing' >> "$SUITE_CASES_JSONL"
}

upload_suite_summary() {
  local suite_status="$1"
  local summary_path="$SUITE_WORKDIR/summary.json"
  local finished_at_utc
  local resource_configuration_json

  finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resource_configuration_json="$(suite_resource_configuration_json "$SCALING_MODE")"
  run_suite_preflight "suite summary upload" "true"
  jq -s \
    --arg experiment_name "$EXPERIMENT_NAME" \
    --arg provider "$CLOUD_PROVIDER" \
    --arg terraform_stack "$(provider_parallel_stack_name)" \
    --arg run_id "$RUN_ID" \
    --arg attempt "$ATTEMPT" \
    --arg scaling_mode "$SCALING_MODE" \
    --arg k6_profile "$K6_PROFILE" \
    --arg test_duration "$TEST_DURATION" \
    --argjson inter_case_delay "$INTER_CASE_DELAY" \
    --arg s3_run_uri "$S3_RUN_URI" \
    --arg suite_status "$suite_status" \
    --arg started_at_utc "$SUITE_STARTED_AT_UTC" \
    --arg finished_at_utc "$finished_at_utc" \
    --argjson resource_configuration "$resource_configuration_json" \
    --argjson scenarios "$(words_json_array "$EFFECTIVE_SCENARIOS")" \
    --argjson rps_levels "$(words_json_array "$EFFECTIVE_RPS_LEVELS")" \
    --argjson scenario_rps_matrix "$(scenario_rps_matrix_json)" \
    '{
      experiment_name: (if $experiment_name == "" then null else $experiment_name end),
      provider: $provider,
      execution_mode: "parallel",
      terraform_stack: $terraform_stack,
      run_id: $run_id,
      attempt: $attempt,
      scaling_mode: $scaling_mode,
      k6_profile: $k6_profile,
      test_duration: $test_duration,
      inter_case_delay: $inter_case_delay,
      s3_run_uri: $s3_run_uri,
      suite_status: $suite_status,
      started_at_utc: $started_at_utc,
      finished_at_utc: $finished_at_utc,
      scenarios: $scenarios,
      rps_levels: ($rps_levels | map(tonumber)),
      scenario_rps_matrix: $scenario_rps_matrix,
      resource_configuration: $resource_configuration,
      cases: .
    }' "$SUITE_CASES_JSONL" > "$summary_path"

  benchmark_aws s3 cp "$summary_path" "${S3_RUN_URI}/_suite/summary.json" >/dev/null
}

maybe_destroy_experiment_stack() {
  if [ "$AUTO_DESTROY_CONFIRMED" != "true" ]; then
    return 0
  fi

  echo ""
  echo "=== Auto Destroy ==="
  echo "  mode           : confirmed"
  destroy_target="$(provider_parallel_destroy_target)"
  echo "  command        : make ${destroy_target}"
  echo "  reason         : suite finished and suite summary is already uploaded to S3"
  echo "  run_id         : $RUN_ID"
  echo "  attempt        : $ATTEMPT"

  make "$destroy_target"
}

maybe_wait_between_cases() {
  local completed_cases="$1"
  local total_cases="$2"

  if [ "$INTER_CASE_DELAY" -eq 0 ]; then
    return 0
  fi

  if [ "$completed_cases" -ge "$total_cases" ]; then
    return 0
  fi

  echo ""
  echo "=== Inter-case delay ==="
  echo "  seconds        : $INTER_CASE_DELAY"
  echo "  completed_case : ${completed_cases}/${total_cases}"
  echo "  purpose        : let app pods, HPA metrics, database, and Datadog telemetry stabilize"
  sleep "$INTER_CASE_DELAY"
}

build_suite_matrix_file
derive_effective_suite_metadata

if [ -z "$ATTEMPT" ]; then
  ATTEMPT="$(next_attempt_for_suite "$S3_RUN_URI" "$SUITE_MATRIX_TSV")"
fi

echo "=== Benchmark Suite ==="
if [ -n "$EXPERIMENT_NAME" ]; then
  echo "  experiment   : $EXPERIMENT_NAME"
fi
echo "  run_id       : $RUN_ID"
echo "  attempt      : $ATTEMPT"
echo "  scaling_mode : $SCALING_MODE"
echo "  k6_profile   : $K6_PROFILE"
echo "  duration     : $TEST_DURATION"
echo "  scenarios    : $EFFECTIVE_SCENARIOS"
if [ -n "${SCENARIO_RPS_MATRIX//[[:space:]]/}" ]; then
  echo "  rps_matrix   : $SCENARIO_RPS_MATRIX"
  echo "  rps_levels   : $EFFECTIVE_RPS_LEVELS (union)"
else
  echo "  rps_levels   : $EFFECTIVE_RPS_LEVELS"
fi
echo "  case_count   : $TOTAL_CASES"
echo "  case_delay   : ${INTER_CASE_DELAY}s"
echo "  auto_destroy : $AUTO_DESTROY_CONFIRMED"
echo "  report_s3_uri: $S3_RUN_URI"
echo ""

run_suite_preflight "suite bootstrap preflight"

suite_failed=0
completed_cases=0
render_provider_manifests "$RENDER_ROOT"
bash scripts/validate-cloud-assets.sh deploy "$RENDER_ROOT"
verify_live_scaling_mode_state
upload_suite_manifest

while IFS=$'\t' read -r scenario scenario_rps_levels; do
  [ -z "$scenario" ] && continue
  echo "=== Scenario: ${scenario} ==="

  if [ "$scenario" = "login" ]; then
    reset_and_seed_benchmark_data
  fi

  if [ "$scenario" = "enriched-transactions" ]; then
    reset_seed_and_prepare_enrichment_data
  fi

  for target_rps in $scenario_rps_levels; do
    echo ""
    echo "=== Suite Case ==="
    echo "  scenario   : $scenario"
    echo "  target_rps : $target_rps"
    echo "  attempt    : $ATTEMPT"

    run_suite_preflight "suite case ${scenario} ${target_rps}rps" "true"

    if [ "$scenario" = "create-transaction" ] || [ "$scenario" = "sync-items" ]; then
      reset_and_seed_benchmark_data
    fi
    if [ "$scenario" = "concurrent-mixed-workload" ]; then
      reset_seed_and_prepare_enrichment_data
    fi

    case_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    run_parallel_case "$scenario" "$target_rps"
    case_exit_code=$?
    set -e
    case_finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case_timing_json="$(
      parallel_case_timing_json \
        "$scenario" \
        "$target_rps" \
        "$case_started_at_utc" \
        "$case_finished_at_utc"
    )"

    if [ "$case_exit_code" -ne 0 ]; then
      suite_failed=1
      append_case_summary "$scenario" "$target_rps" "non_pass" "$case_exit_code" "$case_timing_json"
      echo "Suite case did not finish with PASS. Continuing to preserve remaining matrix coverage."
    else
      append_case_summary "$scenario" "$target_rps" "pass" "$case_exit_code" "$case_timing_json"
    fi

    completed_cases=$((completed_cases + 1))
    maybe_wait_between_cases "$completed_cases" "$TOTAL_CASES"
  done
done < "$SUITE_MATRIX_TSV"

echo ""
echo "=== Benchmark Suite Complete ==="
if [ -n "$EXPERIMENT_NAME" ]; then
  echo "  experiment   : $EXPERIMENT_NAME"
fi
echo "  run_id       : $RUN_ID"
echo "  attempt      : $ATTEMPT"
echo "  report_s3_uri: $S3_RUN_URI"

if [ "$suite_failed" -ne 0 ]; then
  upload_suite_summary "completed_with_non_pass_cases"
  maybe_destroy_experiment_stack
  echo "  suite_status : completed_with_non_pass_cases"
  exit 1
fi

upload_suite_summary "pass"
maybe_destroy_experiment_stack
echo "  suite_status : pass"
