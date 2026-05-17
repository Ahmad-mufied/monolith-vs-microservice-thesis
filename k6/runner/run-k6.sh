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

cat > "$METADATA_PATH" <<EOF
{
  "run_id": "${RUN_ID:-local-run}",
  "attempt": "${ATTEMPT:-attempt-01}",
  "architecture": "${ARCHITECTURE:-unknown}",
  "scenario_name": "${SCENARIO_NAME:-unknown}",
  "k6_script": "k6/scripts/${K6_SCRIPT}",
  "k6_profile": "${K6_PROFILE:-steady}",
  "target_rps": ${TARGET_RPS:-0},
  "duration": "${DURATION:-}",
  "base_url": "${BASE_URL:-}",
  "dataset": "${DATASET:-}",
  "dataset_version": "${DATASET_VERSION:-}",
  "git_commit": "${GIT_COMMIT:-}",
  "image_tag": "${IMAGE_TAG:-}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

set +e
k6 run --out "json=$RAW_PATH" "$K6_ROOT/scripts/$K6_SCRIPT" > "$STDOUT_PATH" 2>&1
STATUS=$?
set -e

cat "$STDOUT_PATH"

if [ -f "$RAW_PATH" ]; then
  gzip -f "$RAW_PATH"
fi

if [ -f "$METADATA_PARTIAL_PATH" ] && [ "$METADATA_PARTIAL_PATH" != "$RESULT_DIR/metadata.partial.json" ]; then
  cp "$METADATA_PARTIAL_PATH" "$RESULT_DIR/metadata.partial.json"
fi

echo "Generated result files:"
find "$RESULT_DIR" -maxdepth 1 -type f -print | sort

if [ -n "${S3_URI:-}" ]; then
  aws s3 sync "$RESULT_DIR" "$S3_URI/"
  echo "Uploaded k6 results to $S3_URI/"
fi

exit "$STATUS"
