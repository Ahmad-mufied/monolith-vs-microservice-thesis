#!/usr/bin/env bash

resources_configuration_json() {
  local architecture="$1"
  local scaling_mode="$2"

  case "$architecture" in
    monolith|microservices) ;;
    *)
      echo "ERROR: unsupported architecture '$architecture' (expected: monolith|microservices)" >&2
      return 1
      ;;
  esac

  case "$scaling_mode" in
    fixed|hpa) ;;
    *)
      echo "ERROR: unsupported scaling_mode '$scaling_mode' (expected: fixed|hpa)" >&2
      return 1
      ;;
  esac

  if [ "$architecture" = "monolith" ]; then
    if [ "$scaling_mode" = "hpa" ]; then
      printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"1975m","cpu_limit":"3950m","memory_request":"3456Mi","memory_limit":"6912Mi","min_replicas":2,"max_replicas":4,"target_cpu_utilization":70}'
      return 0
    fi

    printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"3950m","cpu_limit":"7900m","memory_request":"6912Mi","memory_limit":"13824Mi","replica_count":2}'
    return 0
  fi

  if [ "$scaling_mode" = "hpa" ]; then
    printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"services":{"api-gateway":{"cpu_request":"200m","cpu_limit":"500m","memory_request":"432Mi","memory_limit":"864Mi","min_replicas":1,"max_replicas":5,"target_cpu_utilization":70},"auth-service":{"cpu_request":"2000m","cpu_limit":"3500m","memory_request":"3456Mi","memory_limit":"5184Mi","min_replicas":1,"max_replicas":2,"target_cpu_utilization":70},"item-service":{"cpu_request":"200m","cpu_limit":"460m","memory_request":"432Mi","memory_limit":"864Mi","min_replicas":1,"max_replicas":5,"target_cpu_utilization":70},"transaction-service":{"cpu_request":"800m","cpu_limit":"2000m","memory_request":"3024Mi","memory_limit":"5184Mi","min_replicas":1,"max_replicas":2,"target_cpu_utilization":70}}}'
    return 0
  fi

  printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"services":{"api-gateway":{"cpu_request":"750m","cpu_limit":"2500m","memory_request":"864Mi","memory_limit":"3456Mi","replica_count":1},"auth-service":{"cpu_request":"2500m","cpu_limit":"7000m","memory_request":"3456Mi","memory_limit":"10368Mi","replica_count":1},"item-service":{"cpu_request":"750m","cpu_limit":"2300m","memory_request":"1296Mi","memory_limit":"3456Mi","replica_count":1},"transaction-service":{"cpu_request":"1000m","cpu_limit":"4000m","memory_request":"3024Mi","memory_limit":"10368Mi","replica_count":1}}}'
}

suite_resource_configuration_json() {
  local scaling_mode="$1"
  local monolith_json
  local microservices_json

  monolith_json="$(resources_configuration_json monolith "$scaling_mode")"
  microservices_json="$(resources_configuration_json microservices "$scaling_mode")"

  jq -cn \
    --argjson monolith "$monolith_json" \
    --argjson microservices "$microservices_json" \
    '{monolith: $monolith, microservices: $microservices}'
}
