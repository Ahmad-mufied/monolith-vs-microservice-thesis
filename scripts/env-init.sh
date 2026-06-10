#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/operator-profile.sh

platform="${PLATFORM:-${1:-}}"
execution_mode="${EXECUTION_MODE:-${2:-}}"

platform="$(normalize_operator_platform "$platform")"
validate_execution_mode "$execution_mode"

cloud_provider="$(platform_to_cloud_provider "$platform")"
image_registry="$(platform_to_image_registry "$platform")"
result_storage="$(platform_to_result_storage "$platform")"

bash scripts/env-init-app.sh

case "$platform" in
  eks)
    bash scripts/env-init-eks.sh
    ;;
  vultr)
    bash scripts/env-init-vultr.sh
    ;;
esac

write_operator_profile "$platform" "$execution_mode" "$cloud_provider" "$image_registry" "$result_storage"

echo "Operator profile initialization complete"
echo "  profile : $OPERATOR_PROFILE_FILE"
echo "  platform: $platform"
echo "  provider: $cloud_provider"
echo "  mode    : $execution_mode"
echo "  next    : make profile-show"
