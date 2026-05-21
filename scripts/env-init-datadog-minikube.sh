#!/usr/bin/env bash
set -euo pipefail
umask 077

mkdir -p env

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

write_if_missing "env/datadog.minikube.env" "DATADOG_API_KEY=replace-me
DATADOG_SITE=datadoghq.com
# DATADOG_APP_KEY=replace-me"

echo "local Datadog Minikube env initialization complete"
