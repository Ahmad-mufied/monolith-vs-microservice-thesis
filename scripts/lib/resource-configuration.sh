#!/usr/bin/env bash

resources_configuration_json() {
  local architecture="$1"
  local scaling_mode="$2"
  local provider="${CLOUD_PROVIDER:-aws}"
  local baseline_env="${HETZNER_RESOURCE_BASELINE_ENV:-env/hetzner-resource-baseline.env}"
  if [ "$provider" = "vultr" ]; then
    baseline_env="${VULTR_RESOURCE_BASELINE_ENV:-env/vultr-resource-baseline.env}"
  fi

  if [ "$provider" = "hetzner" ] || [ "$provider" = "vultr" ]; then
    if [ ! -f "$baseline_env" ]; then
      echo "ERROR: missing $baseline_env; run the provider resource baseline measurement target first" >&2
      return 1
    fi

    set -a
    source "$baseline_env"
    set +a
  fi

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

  if [ "$provider" = "vultr" ]; then
    local cpu_quota memory_quota app_node_count allocatable_cpu allocatable_memory
    : "${VULTR_APP_CPU_QUOTA:?VULTR_APP_CPU_QUOTA must be set in $baseline_env}"
    : "${VULTR_APP_MEMORY_QUOTA:?VULTR_APP_MEMORY_QUOTA must be set in $baseline_env}"
    cpu_quota="$VULTR_APP_CPU_QUOTA"
    memory_quota="$VULTR_APP_MEMORY_QUOTA"
    app_node_count="${VULTR_APP_NODE_COUNT:-1}"
    allocatable_cpu="${VULTR_APP_ALLOCATABLE_CPU:-unknown}"
    allocatable_memory="${VULTR_APP_ALLOCATABLE_MEMORY:-unknown}"

    if [ "$architecture" = "monolith" ]; then
      if [ "$scaling_mode" = "hpa" ]; then
        jq -cn \
          --arg provider "$provider" \
          --arg architecture "$architecture" \
          --arg autoscaling_mode "$scaling_mode" \
          --arg cpu "$cpu_quota" \
          --arg memory "$memory_quota" \
          --arg app_node_count "$app_node_count" \
          --arg allocatable_cpu "$allocatable_cpu" \
          --arg allocatable_memory "$allocatable_memory" \
          '{
            provider: $provider,
            architecture: $architecture,
            autoscaling_mode: $autoscaling_mode,
            hpa_enabled: true,
            namespace_resource_quota: {cpu: $cpu, memory: $memory},
            measured_app_node_count: ($app_node_count | tonumber),
            measured_app_allocatable: {cpu: $allocatable_cpu, memory: $allocatable_memory},
            resource_profile: "vultr-equal-split",
            cpu_request: "970m",
            cpu_limit: "1950m",
            memory_request: "1920Mi",
            memory_limit: "3840Mi",
            min_replicas: 1,
            max_replicas: 4,
            target_cpu_utilization: 70
          }'
        return 0
      fi

      jq -cn \
        --arg provider "$provider" \
        --arg architecture "$architecture" \
        --arg autoscaling_mode "$scaling_mode" \
        --arg cpu "$cpu_quota" \
        --arg memory "$memory_quota" \
        --arg app_node_count "$app_node_count" \
        --arg allocatable_cpu "$allocatable_cpu" \
        --arg allocatable_memory "$allocatable_memory" \
        '{
          provider: $provider,
          architecture: $architecture,
          autoscaling_mode: $autoscaling_mode,
          hpa_enabled: false,
          namespace_resource_quota: {cpu: $cpu, memory: $memory},
          measured_app_node_count: ($app_node_count | tonumber),
          measured_app_allocatable: {cpu: $allocatable_cpu, memory: $allocatable_memory},
          resource_profile: "vultr-equal-split",
          cpu_request: "3900m",
          cpu_limit: "7800m",
          memory_request: "7680Mi",
          memory_limit: "15360Mi",
          replica_count: 1
        }'
      return 0
    fi

    jq -cn \
      --arg provider "$provider" \
      --arg architecture "$architecture" \
      --arg autoscaling_mode "$scaling_mode" \
      --arg cpu "$cpu_quota" \
      --arg memory "$memory_quota" \
      --arg app_node_count "$app_node_count" \
      --arg allocatable_cpu "$allocatable_cpu" \
      --arg allocatable_memory "$allocatable_memory" \
      '{
        provider: $provider,
        architecture: $architecture,
        autoscaling_mode: $autoscaling_mode,
        hpa_enabled: ($autoscaling_mode == "hpa"),
        namespace_resource_quota: {cpu: $cpu, memory: $memory},
        measured_app_node_count: ($app_node_count | tonumber),
        measured_app_allocatable: {cpu: $allocatable_cpu, memory: $allocatable_memory},
        resource_profile: "vultr-equal-split",
        allocation_method: (if $autoscaling_mode == "hpa" then "equal per-pod baseline with shared namespace headroom" else "equal per-service split from measured architecture ceiling" end),
        services: {
          "api-gateway": {
            cpu_request: (if $autoscaling_mode == "hpa" then "500m" else "980m" end),
            cpu_limit: (if $autoscaling_mode == "hpa" then "975m" else "1950m" end),
            memory_request: (if $autoscaling_mode == "hpa" then "960Mi" else "1920Mi" end),
            memory_limit: (if $autoscaling_mode == "hpa" then "1920Mi" else "3840Mi" end),
            min_replicas: (if $autoscaling_mode == "hpa" then 1 else null end),
            max_replicas: (if $autoscaling_mode == "hpa" then 4 else null end),
            target_cpu_utilization: (if $autoscaling_mode == "hpa" then 70 else null end),
            replica_count: (if $autoscaling_mode == "fixed" then 1 else null end)
          },
          "auth-service": {
            cpu_request: (if $autoscaling_mode == "hpa" then "500m" else "980m" end),
            cpu_limit: (if $autoscaling_mode == "hpa" then "975m" else "1950m" end),
            memory_request: (if $autoscaling_mode == "hpa" then "960Mi" else "1920Mi" end),
            memory_limit: (if $autoscaling_mode == "hpa" then "1920Mi" else "3840Mi" end),
            min_replicas: (if $autoscaling_mode == "hpa" then 1 else null end),
            max_replicas: (if $autoscaling_mode == "hpa" then 4 else null end),
            target_cpu_utilization: (if $autoscaling_mode == "hpa" then 70 else null end),
            replica_count: (if $autoscaling_mode == "fixed" then 1 else null end)
          },
          "item-service": {
            cpu_request: (if $autoscaling_mode == "hpa" then "500m" else "980m" end),
            cpu_limit: (if $autoscaling_mode == "hpa" then "975m" else "1950m" end),
            memory_request: (if $autoscaling_mode == "hpa" then "960Mi" else "1920Mi" end),
            memory_limit: (if $autoscaling_mode == "hpa" then "1920Mi" else "3840Mi" end),
            min_replicas: (if $autoscaling_mode == "hpa" then 1 else null end),
            max_replicas: (if $autoscaling_mode == "hpa" then 4 else null end),
            target_cpu_utilization: (if $autoscaling_mode == "hpa" then 70 else null end),
            replica_count: (if $autoscaling_mode == "fixed" then 1 else null end)
          },
          "transaction-service": {
            cpu_request: (if $autoscaling_mode == "hpa" then "500m" else "980m" end),
            cpu_limit: (if $autoscaling_mode == "hpa" then "975m" else "1950m" end),
            memory_request: (if $autoscaling_mode == "hpa" then "960Mi" else "1920Mi" end),
            memory_limit: (if $autoscaling_mode == "hpa" then "1920Mi" else "3840Mi" end),
            min_replicas: (if $autoscaling_mode == "hpa" then 1 else null end),
            max_replicas: (if $autoscaling_mode == "hpa" then 4 else null end),
            target_cpu_utilization: (if $autoscaling_mode == "hpa" then 70 else null end),
            replica_count: (if $autoscaling_mode == "fixed" then 1 else null end)
          }
        }
      }'
    return 0
  fi

  if [ "$provider" = "hetzner" ]; then
    local cpu_quota memory_quota app_node_count allocatable_cpu allocatable_memory resource_profile
    : "${HETZNER_APP_CPU_QUOTA:?HETZNER_APP_CPU_QUOTA must be set in $baseline_env}"
    : "${HETZNER_APP_MEMORY_QUOTA:?HETZNER_APP_MEMORY_QUOTA must be set in $baseline_env}"
    cpu_quota="$HETZNER_APP_CPU_QUOTA"
    memory_quota="$HETZNER_APP_MEMORY_QUOTA"
    app_node_count="${HETZNER_APP_NODE_COUNT:-2}"
    allocatable_cpu="${HETZNER_APP_ALLOCATABLE_CPU:-unknown}"
    allocatable_memory="${HETZNER_APP_ALLOCATABLE_MEMORY:-unknown}"
    resource_profile="hetzner-measurement-derived"
    jq -cn \
      --arg provider "$provider" \
      --arg architecture "$architecture" \
      --arg autoscaling_mode "$scaling_mode" \
      --arg cpu "$cpu_quota" \
      --arg memory "$memory_quota" \
      --arg app_node_count "$app_node_count" \
      --arg allocatable_cpu "$allocatable_cpu" \
      --arg allocatable_memory "$allocatable_memory" \
      --arg resource_profile "$resource_profile" \
      '{
        provider: $provider,
        architecture: $architecture,
        autoscaling_mode: $autoscaling_mode,
        hpa_enabled: ($autoscaling_mode == "hpa"),
        namespace_resource_quota: {cpu: $cpu, memory: $memory},
        measured_app_node_count: ($app_node_count | tonumber),
        measured_app_allocatable: {cpu: $allocatable_cpu, memory: $allocatable_memory},
        resource_profile: $resource_profile
      }'
    return 0
  fi

  if [ "$architecture" = "monolith" ]; then
    if [ "$scaling_mode" = "hpa" ]; then
      printf '%s' '{"autoscaling_mode":"hpa","hpa_enabled":true,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"1975m","cpu_limit":"3950m","memory_request":"3456Mi","memory_limit":"6912Mi","min_replicas":1,"max_replicas":4,"target_cpu_utilization":70}'
      return 0
    fi

    printf '%s' '{"autoscaling_mode":"fixed","hpa_enabled":false,"namespace_resource_quota":{"cpu":"15800m","memory":"27648Mi"},"cpu_request":"7900m","cpu_limit":"15800m","memory_request":"13824Mi","memory_limit":"27648Mi","replica_count":1}'
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
