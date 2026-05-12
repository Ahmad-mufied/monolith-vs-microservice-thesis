#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

random_hex() {
  local bytes="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return
  fi

  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

url_encode() {
  local string="$1"
  printf '%s' "$string" | jq -sRr @uri
}

write_if_missing() {
  local file="$1"
  local content="$2"

  if [[ -f "$file" ]]; then
    echo "skip $file (already exists)"
    return
  fi

  printf "%s\n" "$content" >"$file"
  echo "created $file"
}

if [[ -f env/postgres.env ]]; then
  postgres_user="$(grep -E '^POSTGRES_USER=' env/postgres.env | cut -d= -f2- || true)"
  postgres_user="${postgres_user:-postgres}"
  postgres_password="$(grep -E '^POSTGRES_PASSWORD=' env/postgres.env | cut -d= -f2- || true)"
  if [[ -z "$postgres_password" ]]; then
    echo "env/postgres.env exists but POSTGRES_PASSWORD is empty" >&2
    exit 1
  fi
else
  postgres_user="postgres"
  postgres_password="$(random_hex 16)"
fi

encoded_postgres_user="$(url_encode "$postgres_user")"
encoded_postgres_password="$(url_encode "$postgres_password")"

write_if_missing "env/postgres.env" "POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=bootstrap"

echo "local base env initialization complete"
