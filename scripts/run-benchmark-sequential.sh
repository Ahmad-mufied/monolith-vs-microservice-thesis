#!/usr/bin/env bash
# Run one k6 benchmark job for one architecture on the sequential cluster.
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
source scripts/lib/benchmark-aws-credentials.sh

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
source scripts/lib/sequential-benchmark-setup.sh

ARCHITECTURE="${ARCHITECTURE:?ARCHITECTURE is required (monolith|microservices)}"
SCENARIO="${SCENARIO:?SCENARIO is required (login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items)}"
TARGET_RPS="${TARGET_RPS:?TARGET_RPS is required}"
RUN_ID="${RUN_ID:?RUN_ID is required}"
ATTEMPT="${ATTEMPT:-attempt-01}"
SCALING_MODE="${SCALING_MODE:-fixed}"
K6_PROFILE="${K6_PROFILE:-steady}"
ALLOW_NONSTANDARD_SCALING_PROFILE="${ALLOW_NONSTANDARD_SCALING_PROFILE:-false}"
SKIP_BENCHMARK_PREFLIGHT="${SKIP_BENCHMARK_PREFLIGHT:-false}"
SKIP_SCENARIO_DATA_SETUP="${SKIP_SCENARIO_DATA_SETUP:-false}"
TEST_DURATION="${TEST_DURATION:-5m}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"
DATADOG_ENABLED="${DATADOG_ENABLED:-true}"
DATADOG_ENV="${DATADOG_ENV:-benchmark}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
AWS_REGION="${AWS_REGION:-ap-southeast-1}"
ECR_NAMESPACE="${ECR_NAMESPACE:-skripsi}"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aws}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
SEQUENTIAL_CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"
SEQUENTIAL_CLUSTER_NAME="${SEQUENTIAL_CLUSTER_NAME:-$(provider_default_cluster_name sequential)}"
ARCHITECTURE_ORDER="${ARCHITECTURE_ORDER:-monolith microservices}"
RENDER_ROOT="$(mktemp -d)"
INSPECTION_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$RENDER_ROOT" "$INSPECTION_ROOT"
}
trap cleanup EXIT

case "$SCENARIO" in
  login|create-transaction|enriched-transactions|concurrent-mixed-workload|mixed-workload|sync-items) ;;
  *)
    echo "ERROR: unsupported SCENARIO '$SCENARIO'" >&2
    exit 1
    ;;
esac

if ! [[ "$TARGET_RPS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: TARGET_RPS must be a non-negative integer, got '$TARGET_RPS'" >&2
  exit 1
fi

case "$ARCHITECTURE" in
  monolith)
    JOB_NAME="k6-benchmark-monolith"
    MANIFEST_NAME="k6-benchmark-monolith-job.yaml"
    BASE_URL="http://monolith.mono.svc.cluster.local:8080"
    ;;
  microservices)
    JOB_NAME="k6-benchmark-microservices"
    MANIFEST_NAME="k6-benchmark-microservices-job.yaml"
    BASE_URL="http://api-gateway.msa.svc.cluster.local:8080"
    ;;
  *)
    echo "ERROR: unsupported ARCHITECTURE '$ARCHITECTURE' (expected: monolith|microservices)" >&2
    exit 1
    ;;
esac

case "$ALLOW_NONSTANDARD_SCALING_PROFILE" in
  true|false) ;;
  *)
    echo "ERROR: invalid ALLOW_NONSTANDARD_SCALING_PROFILE value '$ALLOW_NONSTANDARD_SCALING_PROFILE' (expected: true|false)" >&2
    exit 1
    ;;
esac

case "$SKIP_SCENARIO_DATA_SETUP" in
  true|false) ;;
  *)
    echo "ERROR: invalid SKIP_SCENARIO_DATA_SETUP value '$SKIP_SCENARIO_DATA_SETUP' (expected: true|false)" >&2
    exit 1
    ;;
esac

if [ "$ALLOW_NONSTANDARD_SCALING_PROFILE" != "true" ]; then
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
fi

S3_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}/${ARCHITECTURE}/${SCENARIO}/${TARGET_RPS}rps/${ATTEMPT}"
S3_RUN_URI="s3://${S3_BUCKET}/experiments/${RUN_ID}"

echo "=== Sequential Benchmark Run ==="
echo "  context       : $SEQUENTIAL_CONTEXT"
echo "  architecture  : $ARCHITECTURE"
echo "  scenario      : $SCENARIO"
echo "  target_rps    : $TARGET_RPS"
echo "  run_id        : $RUN_ID"
echo "  attempt       : $ATTEMPT"
echo "  scaling_mode  : $SCALING_MODE"
echo "  k6_profile    : $K6_PROFILE"
echo "  duration      : $(benchmark_duration_log_value "$K6_PROFILE" "$TEST_DURATION")"
echo "  image_tag     : $IMAGE_TAG"
echo "  provider      : $CLOUD_PROVIDER"
echo "  report_s3_uri : $S3_RUN_URI"
echo ""

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ]; then
  BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_or_die "$S3_BUCKET" "sequential benchmark bootstrap" "false"
fi

# --- Auto-detect whether the target architecture needs deploying ---

check_deployment_ready() {
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
  [ "$desired" -ge 1 ] && [ "$ready" -ge "$desired" ] && [[ "$image" == *":${IMAGE_TAG}" ]]
}

check_scaled_down() {
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

check_scaling_mode_matches() {
  local architecture="$1"
  local hpa_count

  case "$architecture:$SCALING_MODE" in
    monolith:fixed)
      ! kubectl --context="$SEQUENTIAL_CONTEXT" get hpa monolith -n mono >/dev/null 2>&1
      ;;
    monolith:hpa)
      ! kubectl --context="$SEQUENTIAL_CONTEXT" get hpa monolith -n mono >/dev/null 2>&1
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

architecture_already_deployed() {
  local architecture="$1"
  local svc

  check_scaling_mode_matches "$architecture" || return 1

  if [ "$architecture" = "monolith" ]; then
    check_scaled_down msa api-gateway || return 1
    check_scaled_down msa auth-service || return 1
    check_scaled_down msa item-service || return 1
    check_scaled_down msa transaction-service || return 1
    check_deployment_ready mono monolith monolith
    return
  fi

  check_scaled_down mono monolith || return 1
  for svc in api-gateway auth-service item-service transaction-service; do
    check_deployment_ready msa "$svc" "$svc" || return 1
  done
}

render_provider_manifests "$RENDER_ROOT"
MANIFEST="$RENDER_ROOT/deployments/k8s/benchmark/$MANIFEST_NAME"
bash scripts/validate-cloud-assets.sh deploy "$RENDER_ROOT"

if architecture_already_deployed "$ARCHITECTURE"; then
  echo "Architecture ${ARCHITECTURE} is already deployed with IMAGE_TAG=${IMAGE_TAG} and SCALING_MODE=${SCALING_MODE}; skipping deploy."
  if [ "$SKIP_SCENARIO_DATA_SETUP" = "true" ]; then
    echo "=== Skipping scenario data setup for ${SCENARIO} because the sequential suite already prepared it ==="
  else
    echo "=== Running scenario data setup for ${SCENARIO} ==="
    run_scenario_data_setup "$ARCHITECTURE" "$SCENARIO"
  fi
else
  echo "=== Deploying ${ARCHITECTURE} (${SCALING_MODE}) ==="
  ARCHITECTURE="$ARCHITECTURE" \
    SCALING_MODE="$SCALING_MODE" \
    IMAGE_TAG="$IMAGE_TAG" \
    AWS_REGION="$AWS_REGION" \
    ECR_NAMESPACE="$ECR_NAMESPACE" \
    CLOUD_PROVIDER="$CLOUD_PROVIDER" \
    DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" \
    bash scripts/deploy-sequential-architecture.sh
  setup_class="$(scenario_setup_class "$SCENARIO")"
  if [ "$setup_class" = "enrichment" ]; then
    echo "=== Preparing enrichment data for ${SCENARIO} ==="
    prepare_enrichment_active "$ARCHITECTURE"
  fi
fi

resources_json="$(resources_configuration_json "$ARCHITECTURE" "$SCALING_MODE")"
provider_region="${VULTR_REGION:-$AWS_REGION}"
rendered_manifest="$(
  sed \
    -e "/name: BASE_URL/{n; s|value:.*|value: ${BASE_URL}|}" \
    -e "/name: K6_SCRIPT/{n; s|value:.*|value: ${SCENARIO}.js|}" \
    -e "/name: K6_PROFILE/{n; s|value:.*|value: ${K6_PROFILE}|}" \
    -e "/name: ARCHITECTURE/{n; s|value:.*|value: ${ARCHITECTURE}|}" \
    -e "/name: EXECUTION_MODE/{n; s|value:.*|value: sequential|}" \
    -e "/name: ARCHITECTURE_ORDER/{n; s|value:.*|value: ${ARCHITECTURE_ORDER}|}" \
    -e "/name: TERRAFORM_STACK/{n; s|value:.*|value: $(provider_sequential_stack_name)|}" \
    -e "/name: CLUSTER_NAME/{n; s|value:.*|value: ${SEQUENTIAL_CLUSTER_NAME}|}" \
    -e "/name: SCENARIO_NAME/{n; s|value:.*|value: ${SCENARIO}|}" \
    -e "/name: TARGET_RPS/{n; s|value:.*|value: \"${TARGET_RPS}\"|}" \
    -e "/name: RUN_ID/{n; s|value:.*|value: ${RUN_ID}|}" \
    -e "/name: ATTEMPT/{n; s|value:.*|value: ${ATTEMPT}|}" \
    -e "/name: TEST_DURATION/{n; s|value:.*|value: ${TEST_DURATION}|}" \
    -e "/name: DATADOG_ENABLED/{n; s|value:.*|value: \"${DATADOG_ENABLED}\"|}" \
    -e "/name: DATADOG_ENV/{n; s|value:.*|value: ${DATADOG_ENV}|}" \
    -e "/name: S3_URI/{n; s|value:.*|value: ${S3_URI}|}" \
    -e "/name: INFRA_CONFIGURATION_JSON/{n; s|value:.*|value: '{\"provider\":\"${CLOUD_PROVIDER}\",\"region\":\"${provider_region}\",\"cluster\":\"${SEQUENTIAL_CLUSTER_NAME}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\",\"execution_mode\":\"sequential\"}'|}" \
    -e "/name: RESOURCES_CONFIGURATION_JSON/{n; s|value:.*|value: '${resources_json}'|}" \
    "$MANIFEST"
)"

if grep -Eq 'REPLACE_WITH_ECR_IMAGE|replace-me' <<<"$rendered_manifest"; then
  echo "ERROR: benchmark manifest still contains unresolved placeholders after patching: $MANIFEST" >&2
  exit 1
fi

kubectl --context="$SEQUENTIAL_CONTEXT" delete job "$JOB_NAME" -n benchmark --ignore-not-found
if kubectl --context="$SEQUENTIAL_CONTEXT" get job "$JOB_NAME" -n benchmark >/dev/null 2>&1; then
  kubectl --context="$SEQUENTIAL_CONTEXT" wait --for=delete "job/${JOB_NAME}" -n benchmark --timeout=120s
fi
kubectl --context="$SEQUENTIAL_CONTEXT" apply -f - <<EOF
$rendered_manifest
EOF

echo "Waiting for job to complete (timeout: 60m)..."
monitor_timeout_seconds=$((60 * 60))
monitor_start_epoch="$(date +%s)"
terminal_state="RUNNING"
while true; do
  succeeded_count="$(kubectl --context="$SEQUENTIAL_CONTEXT" get job "$JOB_NAME" -n benchmark -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed_count="$(kubectl --context="$SEQUENTIAL_CONTEXT" get job "$JOB_NAME" -n benchmark -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  succeeded_count="${succeeded_count:-0}"
  failed_count="${failed_count:-0}"
  if [ "$succeeded_count" -ge 1 ]; then
    terminal_state="COMPLETE"
    break
  fi
  if [ "$failed_count" -ge 1 ]; then
    terminal_state="FAILED"
    break
  fi
  if [ $(( $(date +%s) - monitor_start_epoch )) -ge "$monitor_timeout_seconds" ]; then
    terminal_state="TIMEOUT"
    break
  fi
  sleep 5
done

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ]; then
  if ! BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_check "$S3_BUCKET" "sequential benchmark result inspection" "true"; then
    echo "ERROR: benchmark job finished but local AWS or EKS auth expired before result inspection." >&2
    exit 1
  fi
fi

fetch_s3_artifact() {
  local artifact_name="$1"
  benchmark_aws s3 cp "${S3_URI%/}/${artifact_name}" - 2>/dev/null || true
}

thresholds_json="$(fetch_s3_artifact thresholds.json)"
result_status_json="$(fetch_s3_artifact result-status.json)"

final_class="INVALID"
reason="job terminated without usable benchmark result artifacts"
if [ "$terminal_state" = "TIMEOUT" ]; then
  final_class="TIMEOUT"
  reason="benchmark job exceeded 60m orchestration timeout"
elif [ -n "$result_status_json" ] && jq -e . >/dev/null 2>&1 <<<"$result_status_json"; then
  s3_exit_code="$(jq -r '.s3_exit_code // "null"' <<<"$result_status_json")"
  k6_exit_code="$(jq -r '.k6_exit_code // "null"' <<<"$result_status_json")"
  classification_hint="$(jq -r '.classification_hint // "unknown"' <<<"$result_status_json")"
  if [ "$s3_exit_code" != "null" ] && [ "$s3_exit_code" != "0" ]; then
    final_class="INVALID"
    reason="S3 upload failed after k6 execution"
  elif [ "$classification_hint" = "runtime_failed" ] || { [ "$k6_exit_code" != "null" ] && [ "$k6_exit_code" != "0" ] && [ "$k6_exit_code" != "99" ]; }; then
    final_class="INVALID"
    reason="k6 exited with a non-threshold runtime failure (exit code: ${k6_exit_code})"
  elif [ -n "$thresholds_json" ] && jq -e '[.. | objects | select(has("ok")) | .ok] | any(. == false)' >/dev/null 2>&1 <<<"$thresholds_json"; then
    final_class="OVERLOAD"
    reason="k6 completed but one or more thresholds failed"
  elif [ "$k6_exit_code" = "0" ] && [ -n "$thresholds_json" ] && jq -e '[.. | objects | select(has("ok")) | .ok] | all(. == true)' >/dev/null 2>&1 <<<"$thresholds_json"; then
    final_class="PASS"
    reason="k6 completed and all thresholds passed"
  elif [ "$classification_hint" = "threshold_failed" ]; then
    final_class="OVERLOAD"
    reason="k6 reported threshold failure"
  fi
fi

echo "=== Result ==="
echo "Report generator source:"
echo "  $S3_RUN_URI"
echo "${ARCHITECTURE}: ${final_class}"
echo "  reason : ${reason}"
echo "  S3 URI : ${S3_URI}"

if [ "$final_class" = "PASS" ]; then
  exit 0
fi

exit 1
