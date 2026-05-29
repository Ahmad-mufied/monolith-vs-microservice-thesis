#!/usr/bin/env bash
set -euo pipefail

explicit_s3_bucket="${S3_BUCKET:-}"

if [ -f env/aws-benchmark.env ]; then
  set -a
  source env/aws-benchmark.env
  set +a
fi

if [ -n "$explicit_s3_bucket" ]; then
  S3_BUCKET="$explicit_s3_bucket"
fi

S3_BUCKET="${S3_BUCKET:?S3_BUCKET is required}"

source scripts/lib/benchmark-preflight.sh

benchmark_preflight_or_die "$S3_BUCKET" "manual benchmark preflight" "false"
