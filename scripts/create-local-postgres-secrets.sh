#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f env/postgres.env ]]; then
  echo "missing env/postgres.env; run: make env-init-base" >&2
  exit 1
fi

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

set -a
source env/postgres.env
set +a

if [[ -z "${POSTGRES_USER:-}" ]]; then
  echo "POSTGRES_USER must be non-empty in env/postgres.env" >&2
  exit 1
fi

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  echo "POSTGRES_PASSWORD must be non-empty in env/postgres.env" >&2
  exit 1
fi

encoded_user="$(url_encode "$POSTGRES_USER")"
encoded_pass="$(url_encode "$POSTGRES_PASSWORD")"

tmp_db_bootstrap_env="$(mktemp /tmp/db-bootstrap-k8s-env.XXXXXX)"
trap 'rm -f "$tmp_db_bootstrap_env"' EXIT

cat >"$tmp_db_bootstrap_env" <<BOOTSTRAPEOF
BOOTSTRAP_DATABASE_URL=postgres://${encoded_user}:${encoded_pass}@postgres.local-database.svc.cluster.local:5432/bootstrap?sslmode=disable
BOOTSTRAPEOF

kubectl apply -f deployments/k8s/namespaces/local.yaml

kubectl create secret generic postgres-local-env \
  --namespace local-database \
  --from-env-file env/postgres.env \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic db-bootstrap-env \
  --namespace local-database \
  --from-env-file "$tmp_db_bootstrap_env" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "local PostgreSQL Kubernetes secrets created"
