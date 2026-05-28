#!/usr/bin/env bash

resources_configuration_json() {
  local architecture="$1"
  local scaling_mode="$2"

  if [ "$architecture" = "monolith" ]; then
    if [ "$scaling_mode" = "hpa" ]; then
      printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"1975m","cpu_limit":"3950m","memory_request":"3456Mi","memory_limit":"6912Mi","min_replicas":2,"max_replicas":4,"target_cpu_utilization":70}'
      return 0
    fi

    printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"3950m","cpu_limit":"7900m","memory_request":"6912Mi","memory_limit":"13824Mi","replica_count":2}'
    return 0
  fi

  if [ "$scaling_mode" = "hpa" ]; then
    printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"services":{"api-gateway":{"cpu_request":"250m","cpu_limit":"500m","memory_request":"432Mi","memory_limit":"864Mi","min_replicas":1,"max_replicas":4,"target_cpu_utilization":70},"auth-service":{"cpu_request":"500m","cpu_limit":"1000m","memory_request":"864Mi","memory_limit":"1728Mi","min_replicas":1,"max_replicas":4,"target_cpu_utilization":70},"item-service":{"cpu_request":"250m","cpu_limit":"500m","memory_request":"432Mi","memory_limit":"864Mi","min_replicas":1,"max_replicas":6,"target_cpu_utilization":70},"transaction-service":{"cpu_request":"850m","cpu_limit":"1700m","memory_request":"1512Mi","memory_limit":"3024Mi","min_replicas":1,"max_replicas":4,"target_cpu_utilization":70}}}'
    return 0
  fi

  printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"services":{"api-gateway":{"cpu_request":"500m","cpu_limit":"2000m","memory_request":"864Mi","memory_limit":"3456Mi","replica_count":1},"auth-service":{"cpu_request":"1500m","cpu_limit":"4000m","memory_request":"2592Mi","memory_limit":"6912Mi","replica_count":1},"item-service":{"cpu_request":"1000m","cpu_limit":"3000m","memory_request":"1728Mi","memory_limit":"5184Mi","replica_count":1},"transaction-service":{"cpu_request":"2000m","cpu_limit":"6800m","memory_request":"3456Mi","memory_limit":"12096Mi","replica_count":1}}}'
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
