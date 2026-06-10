#!/usr/bin/env bash
set -euo pipefail

if [ -z "${DOCKERHUB_NAMESPACE:-}" ]; then
  env_file="env/vultr.env"
  if [ -f "$env_file" ]; then
    set -a
    source "$env_file"
    set +a
  fi
fi

namespace="${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"
image_tag="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"

echo "=== Docker Hub Public Image Check ==="
echo "  namespace : $namespace"
echo "  image_tag : $image_tag"
echo ""

required_dockerignore_patterns=(
  "env/"
  ".aws/"
  ".ssh/"
  "*.tfstate"
  ".terraform/"
  "infra/"
  "deployments/"
)

for pattern in "${required_dockerignore_patterns[@]}"; do
  if ! grep -Fxq "$pattern" .dockerignore; then
    echo "ERROR: .dockerignore is missing required pattern: $pattern" >&2
    exit 1
  fi
done

for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  image="docker.io/${namespace}/${repo}:${image_tag}"
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    echo "FOUND   $image"
  else
    echo "MISSING $image"
    missing=1
  fi
done

if [ "${missing:-0}" -ne 0 ]; then
  echo "One or more Docker Hub images are missing for IMAGE_TAG=${image_tag}" >&2
  exit 1
fi
