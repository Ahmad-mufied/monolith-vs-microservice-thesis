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
source scripts/lib/resource-configuration.sh
source scripts/lib/benchmark-preflight.sh
source scripts/lib/benchmark-timing.sh

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

trim_whitespace() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"
}

validate_architecture_order() {
  local architecture seen_monolith=false seen_microservices=false count=0
  for architecture in $ARCHITECTURE_ORDER; do
    count=$((count + 1))
    case "$architecture" in
      monolith)
        if [ "$seen_monolith" = "true" ]; then
          echo "ERROR: ARCHITECTURE_ORDER must not contain duplicate monolith entries" >&2
          exit 1
        fi
        seen_monolith=true
        ;;
      microservices)
        if [ "$seen_microservices" = "true" ]; then
          echo "ERROR: ARCHITECTURE_ORDER must not contain duplicate microservices entries" >&2
          exit 1
        fi
        seen_microservices=true
        ;;
      *)
        echo "ERROR: unsupported architecture in ARCHITECTURE_ORDER: $architecture" >&2
        exit 1
        ;;
    esac
  done
  if [ "$count" -ne 2 ] || [ "$seen_monolith" != "true" ] || [ "$seen_microservices" != "true" ]; then
    echo "ERROR: ARCHITECTURE_ORDER must include exactly both monolith and microservices" >&2
    exit 1
  fi
}

validate_seconds_value() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be an integer number of seconds, got '$value'" >&2
    exit 1
  fi
}

validate_supported_scenario() {
  case "$1" in
    login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items) ;;
    *)
      echo "ERROR: unsupported scenario '$1'" >&2
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

  attempt_timing_json="$(
    resolve_attempt_timing_json \
      "$s3_uri" \
      "$case_started_at_utc" \
      "$case_finished_at_utc" \
      "sequential ${architecture} ${s3_uri##*/}"
  )"
  case_timing_source="$(normalize_case_timing_source "$(jq -r '.timing_source' <<<"$attempt_timing_json")")"

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

scale_down_active() {
  local architecture="$1"
  local svc
  if [ "$architecture" = "monolith" ]; then
    kubectl --context="$SEQUENTIAL_CONTEXT" delete hpa monolith -n mono --ignore-not-found
    kubectl --context="$SEQUENTIAL_CONTEXT" scale deployment monolith -n mono --replicas=0
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status deployment/monolith -n mono --timeout=300s
    return
  fi
  for svc in api-gateway auth-service item-service transaction-service; do
    kubectl --context="$SEQUENTIAL_CONTEXT" delete hpa "$svc" -n msa --ignore-not-found
  done
  for svc in api-gateway auth-service item-service transaction-service; do
    kubectl --context="$SEQUENTIAL_CONTEXT" scale deployment "$svc" -n msa --replicas=0
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${svc}" -n msa --timeout=300s
  done
}

restore_active() {
  local architecture="$1"
  local svc
  if [ "$architecture" = "monolith" ]; then
    kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/eks/monolith/overlays/$SCALING_MODE"
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status deployment/monolith -n mono --timeout=300s
    return
  fi
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -k "$RENDER_ROOT/deployments/k8s/eks/microservices/overlays/$SCALING_MODE"
  for svc in auth-service item-service transaction-service api-gateway; do
    kubectl --context="$SEQUENTIAL_CONTEXT" rollout status "deployment/${svc}" -n msa --timeout=300s
  done
}

recreate_job() {
  local namespace="$1"
  local job_name="$2"
  local manifest="$3"
  local complete_timeout="$4"

  kubectl --context="$SEQUENTIAL_CONTEXT" delete job "$job_name" -n "$namespace" --ignore-not-found
  if kubectl --context="$SEQUENTIAL_CONTEXT" get job "$job_name" -n "$namespace" >/dev/null 2>&1; then
    kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=delete "job/${job_name}" -n "$namespace" --timeout=120s
  fi
  kubectl --context="$SEQUENTIAL_CONTEXT" apply -f "$manifest"
  kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=condition=complete "job/${job_name}" -n "$namespace" --timeout="$complete_timeout"
}

reset_seed_active() {
  local architecture="$1"
  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono reset-monolith-data-job "$RENDER_ROOT/deployments/k8s/eks/monolith/reset-monolith-data-job.yaml" 120s
    recreate_job mono seed-monolith-benchmark-data-job "$RENDER_ROOT/deployments/k8s/eks/monolith/seed-monolith-benchmark-data-job.yaml" 300s
  else
    recreate_job msa reset-microservices-data-job "$RENDER_ROOT/deployments/k8s/eks/microservices/reset-microservices-data-job.yaml" 120s
    recreate_job msa seed-microservices-benchmark-data-job "$RENDER_ROOT/deployments/k8s/eks/microservices/seed-microservices-benchmark-data-job.yaml" 300s
  fi
  restore_active "$architecture"
}

prepare_enrichment_active() {
  local architecture="$1"
  scale_down_active "$architecture"
  if [ "$architecture" = "monolith" ]; then
    recreate_job mono prepare-monolith-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/eks/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml" 600s
  else
    recreate_job msa prepare-microservices-enrichment-benchmark-data-job "$RENDER_ROOT/deployments/k8s/eks/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml" 600s
  fi
  restore_active "$architecture"
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
    echo "ERROR: K6_PROFILE=hpa must not be used with SCALING_MODE=fixed." >&2
    exit 1
    ;;
  hpa:steady|hpa:ramp|hpa:smoke)
    echo "ERROR: SCALING_MODE=hpa requires K6_PROFILE=hpa for the standard autoscaling experiment." >&2
    exit 1
    ;;
esac

if [ -z "$RUN_ID" ]; then
  run_prefix="$(provider_default_run_prefix sequential)"
  if [ -n "$EXPERIMENT_NAME" ]; then
    RUN_ID="${run_prefix}-${SCALING_MODE}-${EXPERIMENT_NAME}"
  else
    RUN_ID="${run_prefix}-${SCALING_MODE}-$(date +%Y%m%d-%H%M)"
  fi
fi

S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"
SUITE_STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

validate_architecture_order
validate_seconds_value "INTER_CASE_DELAY" "$INTER_CASE_DELAY"
validate_seconds_value "ARCHITECTURE_SWITCH_DELAY" "$ARCHITECTURE_SWITCH_DELAY"
build_matrix_file

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ]; then
  BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_or_die "$S3_BUCKET" "sequential suite bootstrap" "false"
fi

render_provider_manifests "$RENDER_ROOT"
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

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
aws s3 cp "$manifest_path" "${S3_RUN_URI}/_suite/manifest.json" >/dev/null

suite_failed=0
total_cases=0
while IFS=$'\t' read -r scenario scenario_rps_levels; do
  for _ in $scenario_rps_levels; do
    total_cases=$((total_cases + 1))
  done
done < "$MATRIX_TSV"

architecture_index=0
architecture_count="$(wc -w <<<"$ARCHITECTURE_ORDER" | tr -d '[:space:]')"
for architecture in $ARCHITECTURE_ORDER; do
  architecture_index=$((architecture_index + 1))
  phase_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "=== Sequential Architecture: ${architecture} ==="
  ARCHITECTURE="$architecture" SCALING_MODE="$SCALING_MODE" IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" CLOUD_PROVIDER="$CLOUD_PROVIDER" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" bash scripts/deploy-sequential-architecture.sh

  completed_architecture_cases=0
  while IFS=$'\t' read -r scenario scenario_rps_levels; do
    [ -z "$scenario" ] && continue

    # Check if we can skip the setup for this scenario (if all its target RPS levels are already in S3)
    skip_scenario_setup=true
    for target_rps in $scenario_rps_levels; do
      case_s3_uri="${S3_RUN_URI}/${architecture}/${scenario}/${target_rps}rps/${ATTEMPT}"
      if ! aws s3 ls "${case_s3_uri}/result-status.json" >/dev/null 2>&1; then
        skip_scenario_setup=false
        break
      fi
    done

    if [ "$scenario" = "login" ] && [ "$skip_scenario_setup" = "false" ]; then
      reset_seed_active "$architecture"
    fi
    if { [ "$scenario" = "enriched-transactions" ] || [ "$scenario" = "mixed-workload" ]; } && [ "$skip_scenario_setup" = "false" ]; then
      reset_seed_active "$architecture"
      prepare_enrichment_active "$architecture"
    fi

    for target_rps in $scenario_rps_levels; do
      case_s3_uri="${S3_RUN_URI}/${architecture}/${scenario}/${target_rps}rps/${ATTEMPT}"

      echo "Checking if case already exists in S3: ${architecture}/${scenario}/${target_rps}rps"
      result_status_json="$(aws s3 cp "${case_s3_uri}/result-status.json" - 2>/dev/null || true)"
      if [ -n "$result_status_json" ] && jq -e . >/dev/null 2>&1 <<<"$result_status_json"; then
        echo "=== Case already completed in S3: ${architecture}/${scenario}/${target_rps}rps (SKIPPING RUN) ==="
        k6_exit_code="$(jq -r '.k6_exit_code // "null"' <<<"$result_status_json")"
        s3_exit_code="$(jq -r '.s3_exit_code // "null"' <<<"$result_status_json")"
        classification_hint="$(jq -r '.classification_hint // "unknown"' <<<"$result_status_json")"
        
        # Download thresholds.json if it exists to classify properly
        thresholds_json="$(aws s3 cp "${case_s3_uri}/thresholds.json" - 2>/dev/null || true)"
        
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
        continue
      fi

      if [ "$scenario" = "create-transaction" ] || [ "$scenario" = "sync-items" ] || [ "$scenario" = "concurrent-mixed-workload" ] || [ "$scenario" = "mixed-workload" ]; then
        reset_seed_active "$architecture"
        if [ "$scenario" = "concurrent-mixed-workload" ] || [ "$scenario" = "mixed-workload" ]; then
          prepare_enrichment_active "$architecture"
        fi
      fi

      case_started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
      IMAGE_TAG="$IMAGE_TAG" \
      bash scripts/run-benchmark-sequential.sh
      case_exit_code=$?
      set -e
      case_finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
      if [ "$INTER_CASE_DELAY" != "0" ] && [ "$completed_architecture_cases" -lt "$total_cases" ]; then
        sleep "$INTER_CASE_DELAY"
      fi
    done
  done < "$MATRIX_TSV"

  phase_finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn \
    --arg architecture "$architecture" \
    --arg started_at_utc "$phase_started_at_utc" \
    --arg finished_at_utc "$phase_finished_at_utc" \
    --argjson case_count "$completed_architecture_cases" \
    --argjson architecture_index "$architecture_index" \
    --argjson architecture_count "$architecture_count" \
    --argjson next_switch_delay_seconds "$ARCHITECTURE_SWITCH_DELAY" \
    '{architecture:$architecture, architecture_index:$architecture_index, architecture_count:$architecture_count, case_count:$case_count, started_at_utc:$started_at_utc, finished_at_utc:$finished_at_utc, next_switch_delay_seconds:(if $architecture_index < $architecture_count then $next_switch_delay_seconds else 0 end)}' >> "$PHASES_JSONL"

  if [ "$architecture_index" -lt "$architecture_count" ] && [ "$ARCHITECTURE_SWITCH_DELAY" != "0" ]; then
    echo "Waiting ${ARCHITECTURE_SWITCH_DELAY}s before switching to the next architecture for cleaner Datadog windows..."
    sleep "$ARCHITECTURE_SWITCH_DELAY"
  fi
done

summary_path="$SUITE_WORKDIR/summary.json"
finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
suite_status="pass"
if [ "$suite_failed" -ne 0 ]; then
  suite_status="completed_with_non_pass_cases"
fi

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
aws s3 cp "$summary_path" "${S3_RUN_URI}/_suite/summary.json" >/dev/null

if [ "$AUTO_DESTROY_CONFIRMED" = "true" ]; then
  make "$(provider_sequential_destroy_target)"
fi

echo "=== Sequential Benchmark Suite Complete ==="
echo "  run_id       : $RUN_ID"
echo "  suite_status : $suite_status"
echo "  report_s3_uri: $S3_RUN_URI"

if [ "$suite_failed" -ne 0 ]; then
  exit 1
fi
