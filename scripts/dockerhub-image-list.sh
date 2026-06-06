#!/usr/bin/env bash
set -euo pipefail

if [ -z "${DOCKERHUB_NAMESPACE:-}" ]; then
  for env_file in env/vultr.env env/hetzner.env; do
    if [ -f "$env_file" ]; then
      set -a
      source "$env_file"
      set +a
      if [ -n "${DOCKERHUB_NAMESPACE:-}" ]; then
        break
      fi
    fi
  done
fi

namespace="${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"
image_tag="${IMAGE_TAG:-}"
tag_limit="${DOCKERHUB_TAG_LIMIT:-5}"
time_zone="${DOCKERHUB_TIMEZONE:-${TZ:-Asia/Jakarta}}"

if [ "$namespace" = "replace-me" ]; then
  echo "DOCKERHUB_NAMESPACE is still the placeholder 'replace-me'" >&2
  exit 1
fi

if ! [[ "$tag_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "DOCKERHUB_TAG_LIMIT must be a positive integer, got '$tag_limit'" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

repos=(monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner)

tag_pushed_at_filter='.tag_last_pushed // .last_updated // (.images[0]?.last_pushed) // "unknown"'
available_blocks=()

format_time() {
  local raw="$1"

  if [ -z "$raw" ] || [ "$raw" = "unknown" ] || [ "$raw" = "null" ]; then
    printf 'unknown'
    return
  fi

  if formatted="$(TZ="$time_zone" date -d "$raw" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)"; then
    printf '%s' "$formatted"
    return
  fi

  printf '%s' "$raw"
}

if [ -n "$image_tag" ]; then
  echo "=== Docker Hub Image Tag Check ==="
else
  echo "=== Docker Hub Available Tags ==="
fi
echo "  namespace : $namespace"
if [ -n "$image_tag" ]; then
  echo "  image_tag : $image_tag"
fi
echo "  tag_limit : $tag_limit"
echo "  timezone  : $time_zone"
echo ""

missing=0
for repo in "${repos[@]}"; do
  tags_url="https://hub.docker.com/v2/repositories/${namespace}/${repo}/tags?page_size=${tag_limit}"
  tags_json="$(curl -fsS "$tags_url" 2>/dev/null || true)"

  if [ -z "$tags_json" ] || ! jq -e . >/dev/null 2>&1 <<<"$tags_json"; then
    image="docker.io/${namespace}/${repo}"
    [ -n "$image_tag" ] && image="${image}:${image_tag}"
    printf '%s\n' "$repo"
    printf '  status      : MISSING\n'
    printf '  image       : %s\n\n' "$image"
    missing=1
    continue
  fi

  available_tags_raw="$(
    jq -r '
      .results[]?
      | [.name, (.tag_last_pushed // .last_updated // (.images[0]?.last_pushed) // "unknown")]
      | @tsv
    ' <<<"$tags_json"
  )"
  available_tags=""
  while IFS=$'\t' read -r available_tag available_pushed_at; do
    [ -z "${available_tag:-}" ] && continue
    available_tags+="- ${available_tag} pushed $(format_time "${available_pushed_at:-unknown}")"$'\n'
  done <<<"$available_tags_raw"
  available_tags="${available_tags%$'\n'}"
  available_tags="${available_tags:-no tags returned}"
  image="docker.io/${namespace}/${repo}"
  available_blocks+=("${repo}"$'\n'"  image: ${image}"$'\n'"${available_tags}")

  if [ -n "$image_tag" ]; then
    image="docker.io/${namespace}/${repo}:${image_tag}"
    selected_pushed_at="$(
      jq -r --arg tag "$image_tag" '
        first(.results[]? | select(.name == $tag) | (.tag_last_pushed // .last_updated // (.images[0]?.last_pushed) // "unknown")) // ""
      ' <<<"$tags_json"
    )"
    if jq -e --arg tag "$image_tag" 'any(.results[]?; .name == $tag)' >/dev/null <<<"$tags_json"; then
      printf '%s\n' "$repo"
      printf '  status      : FOUND\n'
      printf '  image       : %s\n' "$image"
      printf '  last pushed : %s\n\n' "$(format_time "$selected_pushed_at")"
    elif docker manifest inspect "docker.io/${namespace}/${repo}:${image_tag}" >/dev/null 2>&1; then
      tag_detail_json="$(curl -fsS "https://hub.docker.com/v2/repositories/${namespace}/${repo}/tags/${image_tag}" 2>/dev/null || true)"
      selected_pushed_at="unknown"
      if [ -n "$tag_detail_json" ] && jq -e . >/dev/null 2>&1 <<<"$tag_detail_json"; then
        selected_pushed_at="$(jq -r "$tag_pushed_at_filter" <<<"$tag_detail_json")"
      fi
      printf '%s\n' "$repo"
      printf '  status      : FOUND\n'
      printf '  image       : %s\n' "$image"
      printf '  last pushed : %s\n\n' "$(format_time "$selected_pushed_at")"
    else
      printf '%s\n' "$repo"
      printf '  status      : MISSING\n'
      printf '  image       : %s\n\n' "$image"
      missing=1
    fi
  else
    continue
  fi
done

if [ -n "$image_tag" ]; then
  echo "Available tags:"
else
  echo "Tags by service:"
fi
if [ "${#available_blocks[@]}" -eq 0 ]; then
  echo "no tags returned"
else
  for block in "${available_blocks[@]}"; do
    printf '%s\n\n' "$block"
  done
fi

echo ""
echo "Next hints:"
if [ -n "$image_tag" ]; then
  if [ "$missing" -eq 0 ]; then
    echo "  pin this tag    : make pin-image-tag IMAGE_TAG=${image_tag}"
    echo "  deploy directly : ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=${image_tag} make deploy-workloads"
    echo "  suite directly  : SCALING_MODE=fixed K6_PROFILE=steady IMAGE_TAG=${image_tag} make run-benchmark-suite"
    echo "  note            : pinning sets the default; passing IMAGE_TAG explicitly is still safest for final runs"
  else
    echo "  push missing    : make dockerhub-push-all IMAGE_TAG=${image_tag}"
    echo "  do not deploy   : one or more required images are missing for this tag"
  fi
else
  echo "  check a tag     : IMAGE_TAG=<tag> make dockerhub-list-images"
  echo "  pin a tag       : make pin-image-tag IMAGE_TAG=<tag>"
  echo "  deploy with tag : ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=<tag> make deploy-workloads"
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi
