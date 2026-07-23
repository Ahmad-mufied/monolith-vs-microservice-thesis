#!/usr/bin/env bash

OPERATOR_PROFILE_FILE="${OPERATOR_PROFILE_FILE:-env/operator-profile.env}"
OPERATOR_PROFILE_VERSION="1"

operator_profile_missing_message() {
  echo "operator profile is missing; run: make env-init PLATFORM=<eks|vultr> EXECUTION_MODE=<parallel|sequential>" >&2
}

normalize_operator_platform() {
  local platform="${1:-}"
  case "$platform" in
    eks|aws)
      printf 'eks\n'
      ;;
    vultr)
      printf 'vultr\n'
      ;;
    oci|oracle)
      printf 'oci\n'
      ;;
    *)
      echo "ERROR: unsupported PLATFORM '$platform' (expected: eks|vultr|oci)" >&2
      return 1
      ;;
  esac
}

platform_to_cloud_provider() {
  local platform="$1"
  case "$platform" in
    eks) printf 'aws\n' ;;
    vultr) printf 'vultr\n' ;;
    oci) printf 'oci\n' ;;
    *)
      echo "ERROR: unsupported PLATFORM '$platform'" >&2
      return 1
      ;;
  esac
}

platform_to_image_registry() {
  local platform="$1"
  case "$platform" in
    eks) printf 'ecr\n' ;;
    vultr|oci) printf 'dockerhub\n' ;;
    *)
      echo "ERROR: unsupported PLATFORM '$platform'" >&2
      return 1
      ;;
  esac
}

platform_to_result_storage() {
  local platform="$1"
  case "$platform" in
    eks|vultr|oci) printf 'aws-s3\n' ;;
    *)
      echo "ERROR: unsupported PLATFORM '$platform'" >&2
      return 1
      ;;
  esac
}

validate_execution_mode() {
  local execution_mode="${1:-}"
  case "$execution_mode" in
    parallel|sequential)
      ;;
    *)
      echo "ERROR: unsupported EXECUTION_MODE '$execution_mode' (expected: parallel|sequential)" >&2
      return 1
      ;;
  esac
}

write_operator_profile() {
  local platform="$1"
  local execution_mode="$2"
  local cloud_provider="$3"
  local image_registry="$4"
  local result_storage="$5"

  mkdir -p "$(dirname "$OPERATOR_PROFILE_FILE")"
  cat >"$OPERATOR_PROFILE_FILE" <<EOF
PROFILE_VERSION=${OPERATOR_PROFILE_VERSION}
PLATFORM=${platform}
CLOUD_PROVIDER=${cloud_provider}
EXECUTION_MODE=${execution_mode}
IMAGE_REGISTRY=${image_registry}
RESULT_STORAGE=${result_storage}
EOF
}

load_operator_profile_env() {
  if [[ ! -f "$OPERATOR_PROFILE_FILE" ]]; then
    operator_profile_missing_message
    return 1
  fi

  set -a
  source "$OPERATOR_PROFILE_FILE"
  set +a

  : "${PROFILE_VERSION:?PROFILE_VERSION must be set in $OPERATOR_PROFILE_FILE}"
  : "${PLATFORM:?PLATFORM must be set in $OPERATOR_PROFILE_FILE}"
  : "${CLOUD_PROVIDER:?CLOUD_PROVIDER must be set in $OPERATOR_PROFILE_FILE}"
  : "${EXECUTION_MODE:?EXECUTION_MODE must be set in $OPERATOR_PROFILE_FILE}"
  : "${IMAGE_REGISTRY:?IMAGE_REGISTRY must be set in $OPERATOR_PROFILE_FILE}"
  : "${RESULT_STORAGE:?RESULT_STORAGE must be set in $OPERATOR_PROFILE_FILE}"

  if [[ "$PROFILE_VERSION" != "$OPERATOR_PROFILE_VERSION" ]]; then
    echo "ERROR: unsupported PROFILE_VERSION '$PROFILE_VERSION' in $OPERATOR_PROFILE_FILE" >&2
    return 1
  fi

  PLATFORM="$(normalize_operator_platform "$PLATFORM")" || return 1
  validate_execution_mode "$EXECUTION_MODE" || return 1

  local expected_cloud_provider expected_image_registry expected_result_storage
  expected_cloud_provider="$(platform_to_cloud_provider "$PLATFORM")" || return 1
  expected_image_registry="$(platform_to_image_registry "$PLATFORM")" || return 1
  expected_result_storage="$(platform_to_result_storage "$PLATFORM")" || return 1

  if [[ "$CLOUD_PROVIDER" != "$expected_cloud_provider" ]]; then
    echo "ERROR: operator profile mismatch: PLATFORM=$PLATFORM requires CLOUD_PROVIDER=$expected_cloud_provider, found $CLOUD_PROVIDER" >&2
    return 1
  fi
  if [[ "$IMAGE_REGISTRY" != "$expected_image_registry" ]]; then
    echo "ERROR: operator profile mismatch: PLATFORM=$PLATFORM requires IMAGE_REGISTRY=$expected_image_registry, found $IMAGE_REGISTRY" >&2
    return 1
  fi
  if [[ "$RESULT_STORAGE" != "$expected_result_storage" ]]; then
    echo "ERROR: operator profile mismatch: PLATFORM=$PLATFORM requires RESULT_STORAGE=$expected_result_storage, found $RESULT_STORAGE" >&2
    return 1
  fi

  export PROFILE_VERSION PLATFORM CLOUD_PROVIDER EXECUTION_MODE IMAGE_REGISTRY RESULT_STORAGE
}

show_operator_profile() {
  load_operator_profile_env || return 1
  cat <<EOF
PROFILE_VERSION=$PROFILE_VERSION
PLATFORM=$PLATFORM
CLOUD_PROVIDER=$CLOUD_PROVIDER
EXECUTION_MODE=$EXECUTION_MODE
IMAGE_REGISTRY=$IMAGE_REGISTRY
RESULT_STORAGE=$RESULT_STORAGE
PROFILE_FILE=$OPERATOR_PROFILE_FILE
EOF
}
