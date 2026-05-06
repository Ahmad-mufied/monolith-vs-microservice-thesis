#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f env/postgres.env || ! -f env/monolith.env || ! -f env/db-bootstrap.env ]]; then
  echo "missing env files; run: make env-init" >&2
  exit 1
fi

set -a
source env/postgres.env
source env/monolith.env
set +a

tmp_monolith_env="$(mktemp /tmp/monolith-k8s-env.XXXXXX)"
trap 'rm -f "$tmp_monolith_env"' EXIT

cat >"$tmp_monolith_env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
SERVICE_NAME=${SERVICE_NAME}
DATABASE_URL=postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres.benchmark.svc.cluster.local:5432/mono_db?sslmode=disable
MONO_DATABASE_URL=${MONO_DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
DATADOG_ENABLED=${DATADOG_ENABLED}
EOF

kubectl apply -f deployments/k8s/namespaces/benchmark.yaml

kubectl create secret generic postgres-local-env \
  --namespace benchmark \
  --from-env-file env/postgres.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic db-bootstrap-env \
  --namespace benchmark \
  --from-env-file env/db-bootstrap.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic monolith-env \
  --namespace mono \
  --from-env-file "$tmp_monolith_env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "local Kubernetes secrets created"
