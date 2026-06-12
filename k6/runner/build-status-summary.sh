#!/usr/bin/env bash
set -euo pipefail

RAW_GZIP_PATH="${1:?raw gzip path is required}"
OUTPUT_PATH="${2:?output path is required}"
CONFIGURED_DURATION_SECONDS="${3:-0}"
TARGET_RPS="${4:-0}"

if [ ! -f "$RAW_GZIP_PATH" ]; then
  echo "ERROR: raw gzip file does not exist: $RAW_GZIP_PATH" >&2
  exit 1
fi

if ! [[ "$CONFIGURED_DURATION_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: configured duration seconds must be a non-negative integer, got: $CONFIGURED_DURATION_SECONDS" >&2
  exit 1
fi

if ! [[ "$TARGET_RPS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: target RPS must be a non-negative integer, got: $TARGET_RPS" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

POINTS_TSV="$WORKDIR/http-duration-points.tsv"
GROUPS_TSV="$WORKDIR/status-groups.tsv"

gzip -cd "$RAW_GZIP_PATH" \
  | jq -r '
      def status_family($status):
        if $status | test("^[1-5][0-9][0-9]$") then
          ($status[0:1] + "xx")
        else
          "unknown"
        end;

      def success_class($status):
        if $status | test("^2[0-9][0-9]$") then
          "successful_2xx"
        else
          "non_2xx"
        end;

      def rows_for_scope($scope; $status; $duration; $time; $phase; $kind; $branch):
        [
          [$scope, "status", $status, $status, $duration, $time, $phase, $kind, $branch],
          [$scope, "status_family", status_family($status), $status, $duration, $time, $phase, $kind, $branch],
          [$scope, "success_class", success_class($status), $status, $duration, $time, $phase, $kind, $branch]
        ];

      select(.type == "Point" and .metric == "http_req_duration" and (.data.value | type == "number"))
      | .data as $data
      | ($data.tags // {}) as $tags
      | ($tags.status // "unknown" | tostring) as $status
      | ($tags.benchmark_phase // "") as $benchmark_phase
      | ($tags.request_kind // "") as $request_kind
      | ($tags.composite_branch // "") as $composite_branch
      | ($data.value | tostring) as $duration
      | ($data.time // "") as $time
      | (
          rows_for_scope(
            "all_http_requests";
            $status;
            $duration;
            $time;
            $benchmark_phase;
            $request_kind;
            $composite_branch
          )
          + (
            if $benchmark_phase == "workload" or $request_kind == "workload" then
              rows_for_scope(
                "workload_http_requests";
                $status;
                $duration;
                $time;
                $benchmark_phase;
                $request_kind;
                $composite_branch
              )
            else
              []
            end
          )
        )
      | .[]
      | @tsv
    ' > "$POINTS_TSV"

if [ ! -s "$POINTS_TSV" ]; then
  jq -n \
    --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_raw_file "$(basename "$RAW_GZIP_PATH")" \
    --argjson configured_duration_seconds "$CONFIGURED_DURATION_SECONDS" \
    --argjson target_rps "$TARGET_RPS" \
    '{
      schema_version: 1,
      generated_at_utc: $generated_at_utc,
      source_raw_file: $source_raw_file,
      configured_duration_seconds: $configured_duration_seconds,
      target_rps: $target_rps,
      scopes: {}
    }' > "$OUTPUT_PATH"
  exit 0
fi

sort -t $'\t' -k1,1 -k2,2 -k3,3 -k5,5n "$POINTS_TSV" \
  | awk -F '\t' -v OFS='\t' '
      function ceil(value) {
        return value == int(value) ? value : int(value) + 1
      }

      function percentile(p, percentile_index) {
        if (count == 0) {
          return 0
        }

        percentile_index = ceil(count * p / 100)
        if (percentile_index < 1) {
          percentile_index = 1
        }
        if (percentile_index > count) {
          percentile_index = count
        }
        return values[percentile_index]
      }

      function flush_group() {
        if (count == 0) {
          return
        }

        print scope, group_type, group_key, count, values[1], sum / count, percentile(50), percentile(90), percentile(95), percentile(99), values[count], first_time, last_time

        delete values
        count = 0
        sum = 0
        first_time = ""
        last_time = ""
      }

      {
        next_scope = $1
        next_group_type = $2
        next_group_key = $3
        duration = $5 + 0
        timestamp = $6

        if (count > 0 && (next_scope != scope || next_group_type != group_type || next_group_key != group_key)) {
          flush_group()
        }

        scope = next_scope
        group_type = next_group_type
        group_key = next_group_key
        count += 1
        values[count] = duration
        sum += duration

        if (timestamp != "") {
          if (first_time == "" || timestamp < first_time) {
            first_time = timestamp
          }
          if (last_time == "" || timestamp > last_time) {
            last_time = timestamp
          }
        }
      }

      END {
        flush_group()
      }
    ' > "$GROUPS_TSV"

jq -Rn \
  --arg generated_at_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg source_raw_file "$(basename "$RAW_GZIP_PATH")" \
  --argjson configured_duration_seconds "$CONFIGURED_DURATION_SECONDS" \
  --argjson target_rps "$TARGET_RPS" '
  def number($value): ($value | tonumber);
  def is_2xx($status): ($status | test("^2[0-9][0-9]$"));
  def rps($count): (if $configured_duration_seconds == 0 then null else ($count / $configured_duration_seconds) end);
  def target_ratio($count): (if $configured_duration_seconds == 0 or $target_rps == 0 then null else (($count / $configured_duration_seconds) / $target_rps) end);

  def row_to_object:
    split("\t") as $fields
    | {
        scope: $fields[0],
        group_type: $fields[1],
        group_key: $fields[2],
        count: number($fields[3]),
        latency_ms: {
          min: number($fields[4]),
          avg: number($fields[5]),
          p50: number($fields[6]),
          p90: number($fields[7]),
          p95: number($fields[8]),
          p99: number($fields[9]),
          max: number($fields[10])
        },
        time_window_utc: {
          first_seen: (if $fields[11] == "" then null else $fields[11] end),
          last_seen: (if $fields[12] == "" then null else $fields[12] end)
        }
      };

  [inputs | select(length > 0) | row_to_object] as $rows
  | {
      schema_version: 1,
      generated_at_utc: $generated_at_utc,
      source_raw_file: $source_raw_file,
      configured_duration_seconds: $configured_duration_seconds,
      target_rps: $target_rps,
      notes: [
        "summary.json remains the original k6 aggregate summary.",
        "This derived artifact is computed from raw.json.gz http_req_duration points grouped by response status.",
        "successful_2xx_latency_ms and non_2xx_latency_ms are aggregate latency views across status codes.",
        "workload_http_requests contains only points tagged benchmark_phase=workload or request_kind=workload; it is empty for scenarios that do not use explicit workload tags."
      ],
      scopes: (
        $rows
        | group_by(.scope)
        | map(
            . as $scope_rows
            | ($scope_rows | map(select(.group_type == "status"))) as $status_rows
            | ($scope_rows | map(select(.group_type == "status_family"))) as $family_rows
            | ($scope_rows | map(select(.group_type == "success_class"))) as $success_class_rows
            | ($status_rows | map(.count) | add) as $total
            | ($success_class_rows | map(select(.group_key == "successful_2xx") | .count) | add // 0) as $success_2xx
            | ($success_class_rows | map(select(.group_key == "non_2xx") | .count) | add // 0) as $non_2xx
            | ($success_class_rows | map(select(.group_key == "successful_2xx")) | first) as $success_latency
            | ($success_class_rows | map(select(.group_key == "non_2xx")) | first) as $non_2xx_latency
            | {
                key: $scope_rows[0].scope,
                value: {
                  target_rps: $target_rps,
                  total_count: $total,
                  success_2xx_count: $success_2xx,
                  non_2xx_count: $non_2xx,
                  success_2xx_rate: (if $total == 0 then null else ($success_2xx / $total) end),
                  non_2xx_rate: (if $total == 0 then null else ($non_2xx / $total) end),
                  configured_total_rps: rps($total),
                  configured_success_2xx_rps: rps($success_2xx),
                  configured_non_2xx_rps: rps($non_2xx),
                  total_achievement_rate: target_ratio($total),
                  success_2xx_achievement_rate: target_ratio($success_2xx),
                  successful_2xx_latency_ms: ($success_latency.latency_ms // null),
                  non_2xx_latency_ms: ($non_2xx_latency.latency_ms // null),
                  status_families: (
                    $family_rows
                    | map(
                        . as $row
                        | {
                            key: $row.group_key,
                            value: {
                              count: $row.count,
                              ratio: (if $total == 0 then null else ($row.count / $total) end),
                              configured_rps: rps($row.count),
                              target_achievement_rate: target_ratio($row.count),
                              latency_ms: $row.latency_ms,
                              time_window_utc: $row.time_window_utc
                            }
                          }
                      )
                    | from_entries
                  ),
                  statuses: (
                    $status_rows
                    | map(
                        . as $row
                        | {
                            key: $row.group_key,
                            value: {
                              count: $row.count,
                              ratio: (if $total == 0 then null else ($row.count / $total) end),
                              configured_rps: rps($row.count),
                              target_achievement_rate: target_ratio($row.count),
                              is_success_2xx: is_2xx($row.group_key),
                              latency_ms: $row.latency_ms,
                              time_window_utc: $row.time_window_utc
                            }
                          }
                      )
                    | from_entries
                  )
                }
              }
          )
        | from_entries
      )
    }
' "$GROUPS_TSV" > "$OUTPUT_PATH"
