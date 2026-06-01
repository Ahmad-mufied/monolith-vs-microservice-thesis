#!/usr/bin/env bash
set -euo pipefail

context="${HETZNER_CONTEXT:-benchmark}"
output_env="${HETZNER_RESOURCE_BASELINE_ENV:-env/hetzner-resource-baseline.env}"
output_json="${HETZNER_RESOURCE_BASELINE_JSON:-env/hetzner-resource-baseline.json}"
safety_cpu_m="${HETZNER_RESOURCE_SAFETY_CPU_M:-500}"
safety_memory_mi="${HETZNER_RESOURCE_SAFETY_MEMORY_MI:-2048}"

mkdir -p "$(dirname "$output_env")"

nodes_json="$(kubectl --context="$context" get nodes -l node-group=app -o json)"
node_count="$(jq '.items | length' <<<"$nodes_json")"
if [ "$node_count" -lt 1 ]; then
  echo "ERROR: no app nodes found in context '$context'" >&2
  exit 1
fi

cpu_to_millicores() {
  local value="$1"
  if [[ "$value" == *m ]]; then
    printf '%s\n' "${value%m}"
  else
    awk -v v="$value" 'BEGIN { printf "%.0f\n", v * 1000 }'
  fi
}

memory_to_mi() {
  local value="$1"
  if [[ "$value" == *Ki ]]; then
    awk -v v="${value%Ki}" 'BEGIN { printf "%.0f\n", v / 1024 }'
  elif [[ "$value" == *Mi ]]; then
    printf '%s\n' "${value%Mi}"
  elif [[ "$value" == *Gi ]]; then
    awk -v v="${value%Gi}" 'BEGIN { printf "%.0f\n", v * 1024 }'
  else
    awk -v v="$value" 'BEGIN { printf "%.0f\n", v / 1024 / 1024 }'
  fi
}

total_cpu_m=0
total_memory_mi=0
while IFS=$'\t' read -r cpu memory; do
  total_cpu_m=$((total_cpu_m + $(cpu_to_millicores "$cpu")))
  total_memory_mi=$((total_memory_mi + $(memory_to_mi "$memory")))
done < <(jq -r '.items[] | [.status.allocatable.cpu, .status.allocatable.memory] | @tsv' <<<"$nodes_json")

app_cpu_quota_m=$((total_cpu_m - safety_cpu_m))
app_memory_quota_mi=$((total_memory_mi - safety_memory_mi))
app_cpu_quota_m=$((app_cpu_quota_m / 100 * 100))
app_memory_quota_mi=$((app_memory_quota_mi / 1024 * 1024))

if [ "$app_cpu_quota_m" -le 0 ] || [ "$app_memory_quota_mi" -le 0 ]; then
  echo "ERROR: derived invalid resource quota cpu=${app_cpu_quota_m}m memory=${app_memory_quota_mi}Mi" >&2
  exit 1
fi

cat > "$output_env" <<EOF
HETZNER_APP_CPU_QUOTA=${app_cpu_quota_m}m
HETZNER_APP_MEMORY_QUOTA=${app_memory_quota_mi}Mi
HETZNER_APP_NODE_COUNT=${node_count}
HETZNER_APP_ALLOCATABLE_CPU=${total_cpu_m}m
HETZNER_APP_ALLOCATABLE_MEMORY=${total_memory_mi}Mi
HETZNER_RESOURCE_SAFETY_CPU=${safety_cpu_m}m
HETZNER_RESOURCE_SAFETY_MEMORY=${safety_memory_mi}Mi
EOF

jq -n \
  --arg context "$context" \
  --argjson app_node_count "$node_count" \
  --arg allocatable_cpu "${total_cpu_m}m" \
  --arg allocatable_memory "${total_memory_mi}Mi" \
  --arg cpu_quota "${app_cpu_quota_m}m" \
  --arg memory_quota "${app_memory_quota_mi}Mi" \
  --arg safety_cpu "${safety_cpu_m}m" \
  --arg safety_memory "${safety_memory_mi}Mi" \
  --argjson nodes "$nodes_json" \
  '{
    provider: "hetzner",
    context: $context,
    app_node_count: $app_node_count,
    app_allocatable: {cpu: $allocatable_cpu, memory: $allocatable_memory},
    safety_margin: {cpu: $safety_cpu, memory: $safety_memory},
    app_resource_quota: {cpu: $cpu_quota, memory: $memory_quota},
    raw_nodes: $nodes
  }' > "$output_json"

echo "Wrote Hetzner resource baseline:"
echo "  $output_env"
echo "  $output_json"
cat "$output_env"
