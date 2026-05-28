#!/usr/bin/env bash
# Run the full benchmark matrix for one scaling mode.
set -euo pipefail

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

if [ -z "${IMAGE_TAG:-}" ] && [ -f env/image-tag.eks.env ]; then
  set -a
  source env/image-tag.eks.env
  set +a
fi

source scripts/lib/resource-configuration.sh

SCALING_MODE="${SCALING_MODE:-fixed}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
SCENARIOS="${SCENARIOS:-login create-transaction enriched-transactions}"
RPS_LEVELS="${RPS_LEVELS:-1000 2500 5000 7500 10000}"
INTER_CASE_DELAY="${INTER_CASE_DELAY:-0}"
MAX_INTER_CASE_DELAY=86400
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"
K6_PROFILE="${K6_PROFILE:-}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-}"
RUN_ID="${RUN_ID:-}"
ATTEMPT="${ATTEMPT:-}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
SUITE_WORKDIR="$(mktemp -d)"
SUITE_CASES_JSONL="$SUITE_WORKDIR/cases.jsonl"
RENDER_ROOT="$SUITE_WORKDIR/rendered"
RENDERED_EKS_MONOLITH_DIR="$RENDER_ROOT/deployments/k8s/eks/monolith"
RENDERED_EKS_MICROSERVICES_DIR="$RENDER_ROOT/deployments/k8s/eks/microservices"
RENDERED_MONOLITH_OVERLAY_DIR="$RENDERED_EKS_MONOLITH_DIR/overlays/$SCALING_MODE"
RENDERED_MICROSERVICES_OVERLAY_DIR="$RENDERED_EKS_MICROSERVICES_DIR/overlays/$SCALING_MODE"

cleanup() {
  rm -rf "$SUITE_WORKDIR"
}
trap cleanup EXIT
: > "$SUITE_CASES_JSONL"

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

validate_matrix_inputs() {
  local normalized_inter_case_delay
  local sanitized_experiment_name

  case "$SCALING_MODE" in
    fixed|hpa) ;;
    *)
      echo "ERROR: unsupported SCALING_MODE '$SCALING_MODE' (expected: fixed|hpa)" >&2
      return 1
      ;;
  esac

  if [ -z "${SCENARIOS//[[:space:]]/}" ]; then
    echo "ERROR: SCENARIOS must contain at least one scenario" >&2
    return 1
  fi

  for scenario in $SCENARIOS; do
    case "$scenario" in
      login|create-transaction|enriched-transactions|mixed-workload) ;;
      *)
        echo "ERROR: unsupported scenario '$scenario' (expected: login|create-transaction|enriched-transactions|mixed-workload)" >&2
        return 1
        ;;
    esac
  done

  if [ -z "${RPS_LEVELS//[[:space:]]/}" ]; then
    echo "ERROR: RPS_LEVELS must contain at least one positive integer" >&2
    return 1
  fi

  for target_rps in $RPS_LEVELS; do
    if ! [[ "$target_rps" =~ ^[1-9][0-9]*$ ]]; then
      echo "ERROR: invalid RPS_LEVELS value '$target_rps' (expected: positive integer)" >&2
      return 1
    fi
  done

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
}

validate_matrix_inputs
INTER_CASE_DELAY="$(normalize_nonnegative_integer "$INTER_CASE_DELAY")"
if [ -n "$EXPERIMENT_NAME" ]; then
  EXPERIMENT_NAME="$(sanitize_experiment_name "$EXPERIMENT_NAME")"
fi

if [ -z "$K6_PROFILE" ]; then
  if [ "$SCALING_MODE" = "hpa" ]; then
    K6_PROFILE="hpa"
  else
    K6_PROFILE="steady"
  fi
fi

if [ -z "$RUN_ID" ]; then
  if [ -n "$EXPERIMENT_NAME" ]; then
    RUN_ID="eks-${SCALING_MODE}-${EXPERIMENT_NAME}"
  else
    RUN_ID="eks-${SCALING_MODE}-$(date +%Y%m%d-%H%M)"
  fi
fi

S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"
SUITE_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

words_json_array() {
  local words="$1"
  jq -cn --arg words "$words" '$words | [scan("\\S+")]'
}

word_count() {
  local words="$1"
  set -- $words
  printf '%s' "$#"
}

next_attempt_from_s3() {
  local run_uri="$1"
  local listing
  local listing_error
  local latest
  local next

  listing_error="$(mktemp)"
  if ! listing="$(aws s3 ls "$run_uri/" --recursive 2>"$listing_error")"; then
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

  latest="$(sed -n 's|.*/attempt-\([0-9][0-9]*\)/.*|\1|p' <<<"$listing" | sort -n | tail -n 1)"

  if [ -z "$latest" ]; then
    printf 'attempt-01'
    return 0
  fi

  next=$((10#$latest + 1))
  printf 'attempt-%02d' "$next"
}

reset_and_seed_benchmark_data() {
  scale_down_app_workloads_for_data_reset

  kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/reset-monolith-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

  kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/reset-microservices-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

  kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
  kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/seed-monolith-benchmark-data-job.yaml"
  kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

  kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
  kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/seed-microservices-benchmark-data-job.yaml"
  kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

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
  bash scripts/run-benchmark-parallel.sh
}

upload_suite_manifest() {
  local manifest_path="$SUITE_WORKDIR/manifest.json"
  local resource_configuration_json

  resource_configuration_json="$(suite_resource_configuration_json "$SCALING_MODE")"
  jq -n \
    --arg experiment_name "$EXPERIMENT_NAME" \
    --arg run_id "$RUN_ID" \
    --arg attempt "$ATTEMPT" \
    --arg scaling_mode "$SCALING_MODE" \
    --arg k6_profile "$K6_PROFILE" \
    --arg test_duration "$TEST_DURATION" \
    --argjson inter_case_delay "$INTER_CASE_DELAY" \
    --arg s3_run_uri "$S3_RUN_URI" \
    --arg started_at_utc "$SUITE_STARTED_AT_UTC" \
    --argjson resource_configuration "$resource_configuration_json" \
    --argjson scenarios "$(words_json_array "$SCENARIOS")" \
    --argjson rps_levels "$(words_json_array "$RPS_LEVELS")" \
    '{
      experiment_name: (if $experiment_name == "" then null else $experiment_name end),
      run_id: $run_id,
      attempt: $attempt,
      scaling_mode: $scaling_mode,
      k6_profile: $k6_profile,
      test_duration: $test_duration,
      inter_case_delay: $inter_case_delay,
      scenarios: $scenarios,
      rps_levels: ($rps_levels | map(tonumber)),
      resource_configuration: $resource_configuration,
      s3_run_uri: $s3_run_uri,
      started_at_utc: $started_at_utc
    }' > "$manifest_path"

  aws s3 cp "$manifest_path" "${S3_RUN_URI}/_suite/manifest.json" >/dev/null
}

append_case_summary() {
  local scenario="$1"
  local target_rps="$2"
  local status="$3"
  local exit_code="$4"

  jq -cn \
    --arg scenario "$scenario" \
    --argjson target_rps "$target_rps" \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg monolith_uri "${S3_RUN_URI}/monolith/${scenario}/${target_rps}rps/${ATTEMPT}" \
    --arg microservices_uri "${S3_RUN_URI}/microservices/${scenario}/${target_rps}rps/${ATTEMPT}" \
    '{
      scenario: $scenario,
      target_rps: $target_rps,
      status: $status,
      exit_code: $exit_code,
      monolith_s3_uri: $monolith_uri,
      microservices_s3_uri: $microservices_uri
    }' >> "$SUITE_CASES_JSONL"
}

upload_suite_summary() {
  local suite_status="$1"
  local summary_path="$SUITE_WORKDIR/summary.json"
  local finished_at_utc
  local resource_configuration_json

  finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  resource_configuration_json="$(suite_resource_configuration_json "$SCALING_MODE")"
  jq -s \
    --arg experiment_name "$EXPERIMENT_NAME" \
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
    '{
      experiment_name: (if $experiment_name == "" then null else $experiment_name end),
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
      resource_configuration: $resource_configuration,
      cases: .
    }' "$SUITE_CASES_JSONL" > "$summary_path"

  aws s3 cp "$summary_path" "${S3_RUN_URI}/_suite/summary.json" >/dev/null
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

if [ -z "$ATTEMPT" ]; then
  ATTEMPT="$(next_attempt_from_s3 "$S3_RUN_URI")"
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
echo "  scenarios    : $SCENARIOS"
echo "  rps_levels   : $RPS_LEVELS"
echo "  case_delay   : ${INTER_CASE_DELAY}s"
echo "  report_s3_uri: $S3_RUN_URI"
echo ""

suite_failed=0
scenario_count="$(word_count "$SCENARIOS")"
rps_count="$(word_count "$RPS_LEVELS")"
total_cases=$((scenario_count * rps_count))
completed_cases=0
IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-eks-manifests.sh >/dev/null
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"
upload_suite_manifest

for scenario in $SCENARIOS; do
  echo "=== Scenario: ${scenario} ==="

  if [ "$scenario" = "login" ]; then
    reset_and_seed_benchmark_data
  fi

  if [ "$scenario" = "enriched-transactions" ]; then
    reset_and_seed_benchmark_data
    bash scripts/prepare-enrichment-benchmark.sh
  fi

  for target_rps in $RPS_LEVELS; do
    echo ""
    echo "=== Suite Case ==="
    echo "  scenario   : $scenario"
    echo "  target_rps : $target_rps"
    echo "  attempt    : $ATTEMPT"

    if [ "$scenario" = "create-transaction" ]; then
      reset_and_seed_benchmark_data
    fi

    set +e
    run_parallel_case "$scenario" "$target_rps"
    case_exit_code=$?
    set -e

    if [ "$case_exit_code" -ne 0 ]; then
      suite_failed=1
      append_case_summary "$scenario" "$target_rps" "non_pass" "$case_exit_code"
      echo "Suite case did not finish with PASS. Continuing to preserve remaining matrix coverage."
    else
      append_case_summary "$scenario" "$target_rps" "pass" "$case_exit_code"
    fi

    completed_cases=$((completed_cases + 1))
    maybe_wait_between_cases "$completed_cases" "$total_cases"
  done
done

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
  echo "  suite_status : completed_with_non_pass_cases"
  exit 1
fi

upload_suite_summary "pass"
echo "  suite_status : pass"
