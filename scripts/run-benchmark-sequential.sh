#!/usr/bin/env bash
# Run one k6 benchmark job for one architecture on the sequential cluster.
set -euo pipefail

explicit_aws_region="${AWS_REGION:-}"
explicit_ecr_namespace="${ECR_NAMESPACE:-}"
explicit_s3_bucket="${S3_BUCKET:-}"

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

if [ "${CLOUD_PROVIDER:-aws}" = "hetzner" ] && [ -f env/hetzner.env ]; then
  set -a
  source env/hetzner.env
  set +a
fi

if [ -n "$explicit_aws_region" ]; then
  AWS_REGION="$explicit_aws_region"
fi
if [ -n "$explicit_ecr_namespace" ]; then
  ECR_NAMESPACE="$explicit_ecr_namespace"
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
source scripts/lib/benchmark-preflight.sh

ARCHITECTURE="${ARCHITECTURE:?ARCHITECTURE is required (monolith|microservices)}"
SCENARIO="${SCENARIO:?SCENARIO is required (login|create-transaction|enriched-transactions|mixed-workload|sync-items)}"
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
SEQUENTIAL_CONTEXT="${SEQUENTIAL_CONTEXT:-benchmark}"
SEQUENTIAL_CLUSTER_NAME="${SEQUENTIAL_CLUSTER_NAME:-${HETZNER_SEQUENTIAL_CLUSTER_NAME:-skripsi-benchmark}}"
ARCHITECTURE_ORDER="${ARCHITECTURE_ORDER:-monolith microservices}"
RENDER_ROOT="$(mktemp -d)"
INSPECTION_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$RENDER_ROOT" "$INSPECTION_ROOT"
}
trap cleanup EXIT

case "$SCENARIO" in
  login|create-transaction|enriched-transactions|mixed-workload|sync-items) ;;
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
echo "  duration      : $TEST_DURATION"
echo "  image_tag     : $IMAGE_TAG"
echo "  provider      : $CLOUD_PROVIDER"
echo "  report_s3_uri : $S3_RUN_URI"
echo ""

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ]; then
  BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_or_die "$S3_BUCKET" "sequential benchmark bootstrap" "false"
fi

if [ "$CLOUD_PROVIDER" = "hetzner" ]; then
  : "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required for CLOUD_PROVIDER=hetzner}"
  IMAGE_TAG="$IMAGE_TAG" DOCKERHUB_NAMESPACE="$DOCKERHUB_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-hetzner-manifests.sh >/dev/null
else
  IMAGE_TAG="$IMAGE_TAG" AWS_REGION="$AWS_REGION" ECR_NAMESPACE="$ECR_NAMESPACE" OUTPUT_DIR="$RENDER_ROOT" bash scripts/render-eks-manifests.sh >/dev/null
fi
MANIFEST="$RENDER_ROOT/deployments/k8s/benchmark/$MANIFEST_NAME"
bash scripts/validate-eks-assets.sh deploy "$RENDER_ROOT"

resources_json="$(resources_configuration_json "$ARCHITECTURE" "$SCALING_MODE")"
rendered_manifest="$(
  sed \
    -e "/name: BASE_URL/{n; s|value:.*|value: ${BASE_URL}|}" \
    -e "/name: K6_SCRIPT/{n; s|value:.*|value: ${SCENARIO}.js|}" \
    -e "/name: K6_PROFILE/{n; s|value:.*|value: ${K6_PROFILE}|}" \
    -e "/name: ARCHITECTURE/{n; s|value:.*|value: ${ARCHITECTURE}|}" \
    -e "/name: EXECUTION_MODE/{n; s|value:.*|value: sequential|}" \
    -e "/name: ARCHITECTURE_ORDER/{n; s|value:.*|value: ${ARCHITECTURE_ORDER}|}" \
    -e "/name: TERRAFORM_STACK/{n; s|value:.*|value: $([ "$CLOUD_PROVIDER" = "hetzner" ] && printf 'hetzner-experiment-sequential' || printf 'experiment-sequential')|}" \
    -e "/name: CLUSTER_NAME/{n; s|value:.*|value: ${SEQUENTIAL_CLUSTER_NAME}|}" \
    -e "/name: SCENARIO_NAME/{n; s|value:.*|value: ${SCENARIO}|}" \
    -e "/name: TARGET_RPS/{n; s|value:.*|value: \"${TARGET_RPS}\"|}" \
    -e "/name: RUN_ID/{n; s|value:.*|value: ${RUN_ID}|}" \
    -e "/name: ATTEMPT/{n; s|value:.*|value: ${ATTEMPT}|}" \
    -e "/name: TEST_DURATION/{n; s|value:.*|value: ${TEST_DURATION}|}" \
    -e "/name: DATADOG_ENABLED/{n; s|value:.*|value: \"${DATADOG_ENABLED}\"|}" \
    -e "/name: DATADOG_ENV/{n; s|value:.*|value: ${DATADOG_ENV}|}" \
    -e "/name: S3_URI/{n; s|value:.*|value: ${S3_URI}|}" \
    -e "/name: INFRA_CONFIGURATION_JSON/{n; s|value:.*|value: '{\"provider\":\"${CLOUD_PROVIDER}\",\"region\":\"${AWS_REGION}\",\"cluster\":\"${SEQUENTIAL_CLUSTER_NAME}\",\"app_node_pool\":\"app-nodes\",\"testing_node_pool\":\"testing-nodes\",\"postgres_version\":\"18\",\"execution_mode\":\"sequential\"}'|}" \
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

if [ "$SKIP_BENCHMARK_PREFLIGHT" != "true" ] && ! BENCHMARK_PREFLIGHT_CONTEXTS="$SEQUENTIAL_CONTEXT" benchmark_preflight_check "$S3_BUCKET" "sequential benchmark result inspection" "true"; then
  echo "ERROR: benchmark job finished but local AWS or EKS auth expired before result inspection." >&2
  exit 1
fi

fetch_s3_artifact() {
  local artifact_name="$1"
  aws s3 cp "${S3_URI%/}/${artifact_name}" - 2>/dev/null || true
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
