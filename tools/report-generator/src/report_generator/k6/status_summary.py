"""Generate status-aware derived summaries from raw k6 artifacts."""

from __future__ import annotations

import gzip
import io
import json
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, NoCredentialsError, PartialCredentialsError

from report_generator.k6.exceptions import ArtifactDiscoveryError, InvalidArtifactError
from report_generator.k6.models import AttemptArtifacts
from report_generator.k6.utils import ensure_parent, parse_duration_to_seconds, parse_s3_uri


def write_status_summary_artifacts(
    attempts: list[AttemptArtifacts],
    output_root: Path,
) -> list[Path]:
    """Materialize derived status-summary.json files under the report output."""

    written_paths: list[Path] = []
    s3_client: Any | None = None

    for attempt in attempts:
        raw_path = attempt.raw_json_gz_path
        if not raw_path:
            continue

        if s3_client is None and raw_path.startswith("s3://"):
            s3_client = _create_s3_client()

        summary = build_status_summary(attempt, s3_client=s3_client)
        output_path = (
            output_root
            / "derived-attempt-artifacts"
            / attempt.architecture
            / attempt.scenario
            / f"{attempt.target_rps}rps"
            / attempt.attempt
            / "status-summary.json"
        )
        ensure_parent(output_path)
        output_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        written_paths.append(output_path)

    return written_paths


def build_status_summary(
    attempt: AttemptArtifacts,
    *,
    s3_client: Any | None = None,
) -> dict[str, Any]:
    raw_path = attempt.raw_json_gz_path
    if not raw_path:
        raise InvalidArtifactError(f"raw.json.gz is missing for {attempt.source_uri}")

    duration = attempt.metadata.get("duration")
    if not isinstance(duration, str) or not duration:
        raise InvalidArtifactError(f"missing duration in metadata.json for {attempt.source_uri}")

    configured_duration_seconds = parse_duration_to_seconds(duration)
    target_rps = attempt.target_rps
    points = list(_iter_http_duration_points(raw_path, s3_client=s3_client))

    scopes: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for point in points:
        tags = point["tags"]
        status = str(tags.get("status", "unknown"))
        benchmark_phase = str(tags.get("benchmark_phase", ""))
        request_kind = str(tags.get("request_kind", ""))
        timestamp = point["time"]
        value = point["value"]

        scope_names = ["all_http_requests"]
        if benchmark_phase == "workload" or request_kind == "workload":
            scope_names.append("workload_http_requests")

        for scope in scope_names:
            _record_group(scopes, scope, "status", status, value, timestamp)
            _record_group(scopes, scope, "status_family", _status_family(status), value, timestamp)
            _record_group(scopes, scope, "success_class", _success_class(status), value, timestamp)

    return {
        "schema_version": 1,
        "generated_at_utc": _utc_now(),
        "source_raw_file": PurePosixPath(raw_path).name,
        "configured_duration_seconds": configured_duration_seconds,
        "target_rps": target_rps,
        "notes": [
            "summary.json remains the original k6 aggregate summary.",
            "This derived artifact is computed from raw.json.gz http_req_duration points grouped by response status.",
            "successful_2xx_latency_ms and non_2xx_latency_ms are aggregate latency views across status codes.",
            "workload_http_requests contains only points tagged benchmark_phase=workload or request_kind=workload; it is empty for scenarios that do not use explicit workload tags.",
        ],
        "scopes": {
            scope_name: _finalize_scope(scope_groups, configured_duration_seconds, target_rps)
            for scope_name, scope_groups in sorted(scopes.items())
        },
    }


def _iter_http_duration_points(raw_path: str, *, s3_client: Any | None):
    with _open_gzip_text(raw_path, s3_client=s3_client) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            if payload.get("type") != "Point" or payload.get("metric") != "http_req_duration":
                continue
            data = payload.get("data")
            if not isinstance(data, dict):
                continue
            value = data.get("value")
            if not isinstance(value, (int, float)):
                continue
            tags = data.get("tags")
            if not isinstance(tags, dict):
                tags = {}
            yield {
                "value": float(value),
                "time": data.get("time") if isinstance(data.get("time"), str) else None,
                "tags": tags,
            }


def _open_gzip_text(raw_path: str, *, s3_client: Any | None):
    if raw_path.startswith("s3://"):
        if s3_client is None:
            s3_client = _create_s3_client()
        bucket, key = parse_s3_uri(raw_path)
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
        except (NoCredentialsError, PartialCredentialsError) as exc:
            raise ArtifactDiscoveryError("AWS credentials are missing or expired for raw.json.gz access.") from exc
        except BotoCoreError as exc:
            raise ArtifactDiscoveryError(f"unable to fetch {raw_path}: {exc}") from exc
        body = response["Body"].read()
        gzip_stream = gzip.GzipFile(fileobj=io.BytesIO(body), mode="rb")
        return io.TextIOWrapper(gzip_stream, encoding="utf-8")

    return gzip.open(raw_path, "rt", encoding="utf-8")


def _create_s3_client() -> Any:
    try:
        return boto3.client("s3")
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise ArtifactDiscoveryError("AWS credentials are missing or expired for raw.json.gz access.") from exc
    except BotoCoreError as exc:
        raise ArtifactDiscoveryError(f"unable to create S3 client for raw.json.gz access: {exc}") from exc


def _record_group(
    scopes: dict[str, dict[str, dict[str, Any]]],
    scope: str,
    group_type: str,
    group_key: str,
    value: float,
    timestamp: str | None,
) -> None:
    group_id = f"{group_type}:{group_key}"
    groups = scopes[scope]
    if group_id not in groups:
        groups[group_id] = {
            "group_type": group_type,
            "group_key": group_key,
            "count": 0,
            "sum": 0.0,
            "values": [],
            "first_seen": None,
            "last_seen": None,
        }

    row = groups[group_id]
    row["count"] += 1
    row["sum"] += value
    row["values"].append(value)

    if timestamp:
        first_seen = row["first_seen"]
        last_seen = row["last_seen"]
        if first_seen is None or timestamp < first_seen:
            row["first_seen"] = timestamp
        if last_seen is None or timestamp > last_seen:
            row["last_seen"] = timestamp


def _finalize_scope(
    scope_groups: dict[str, dict[str, Any]],
    configured_duration_seconds: int,
    target_rps: int,
) -> dict[str, Any]:
    status_rows = []
    family_rows = []
    success_rows = []

    for row in scope_groups.values():
        finalized = _finalize_group_row(row)
        match row["group_type"]:
            case "status":
                status_rows.append(finalized)
            case "status_family":
                family_rows.append(finalized)
            case "success_class":
                success_rows.append(finalized)

    total_count = sum(row["count"] for row in status_rows)
    success_2xx_count = next((row["count"] for row in success_rows if row["group_key"] == "successful_2xx"), 0)
    non_2xx_count = next((row["count"] for row in success_rows if row["group_key"] == "non_2xx"), 0)
    success_latency = next((row["latency_ms"] for row in success_rows if row["group_key"] == "successful_2xx"), None)
    non_2xx_latency = next((row["latency_ms"] for row in success_rows if row["group_key"] == "non_2xx"), None)

    return {
        "target_rps": target_rps,
        "total_count": total_count,
        "success_2xx_count": success_2xx_count,
        "non_2xx_count": non_2xx_count,
        "success_2xx_rate": _safe_ratio(success_2xx_count, total_count),
        "non_2xx_rate": _safe_ratio(non_2xx_count, total_count),
        "configured_total_rps": _configured_rps(total_count, configured_duration_seconds),
        "configured_success_2xx_rps": _configured_rps(success_2xx_count, configured_duration_seconds),
        "configured_non_2xx_rps": _configured_rps(non_2xx_count, configured_duration_seconds),
        "total_achievement_rate": _target_ratio(total_count, configured_duration_seconds, target_rps),
        "success_2xx_achievement_rate": _target_ratio(success_2xx_count, configured_duration_seconds, target_rps),
        "successful_2xx_latency_ms": success_latency,
        "non_2xx_latency_ms": non_2xx_latency,
        "status_families": {
            row["group_key"]: {
                "count": row["count"],
                "ratio": _safe_ratio(row["count"], total_count),
                "configured_rps": _configured_rps(row["count"], configured_duration_seconds),
                "target_achievement_rate": _target_ratio(row["count"], configured_duration_seconds, target_rps),
                "latency_ms": row["latency_ms"],
                "time_window_utc": row["time_window_utc"],
            }
            for row in sorted(family_rows, key=lambda item: item["group_key"])
        },
        "statuses": {
            row["group_key"]: {
                "count": row["count"],
                "ratio": _safe_ratio(row["count"], total_count),
                "configured_rps": _configured_rps(row["count"], configured_duration_seconds),
                "target_achievement_rate": _target_ratio(row["count"], configured_duration_seconds, target_rps),
                "is_success_2xx": _is_2xx(row["group_key"]),
                "latency_ms": row["latency_ms"],
                "time_window_utc": row["time_window_utc"],
            }
            for row in sorted(status_rows, key=lambda item: item["group_key"])
        },
    }


def _finalize_group_row(row: dict[str, Any]) -> dict[str, Any]:
    values = sorted(row["values"])
    count = row["count"]

    return {
        "group_type": row["group_type"],
        "group_key": row["group_key"],
        "count": count,
        "latency_ms": {
            "min": values[0],
            "avg": row["sum"] / count,
            "p50": _nearest_rank(values, 50),
            "p90": _nearest_rank(values, 90),
            "p95": _nearest_rank(values, 95),
            "p99": _nearest_rank(values, 99),
            "max": values[-1],
        },
        "time_window_utc": {
            "first_seen": row["first_seen"],
            "last_seen": row["last_seen"],
        },
    }


def _nearest_rank(values: list[float], percentile: int) -> float:
    if not values:
        return 0.0
    index = ((len(values) * percentile) + 99) // 100
    index = max(1, min(index, len(values)))
    return values[index - 1]


def _configured_rps(count: int, configured_duration_seconds: int) -> float | None:
    if configured_duration_seconds == 0:
        return None
    return count / configured_duration_seconds


def _target_ratio(count: int, configured_duration_seconds: int, target_rps: int) -> float | None:
    if configured_duration_seconds == 0 or target_rps == 0:
        return None
    return (count / configured_duration_seconds) / target_rps


def _safe_ratio(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return numerator / denominator


def _status_family(status: str) -> str:
    return f"{status[0]}xx" if len(status) == 3 and status.isdigit() and status[0] in "12345" else "unknown"


def _success_class(status: str) -> str:
    return "successful_2xx" if _is_2xx(status) else "non_2xx"


def _is_2xx(status: str) -> bool:
    return len(status) == 3 and status.isdigit() and status.startswith("2")


def _utc_now() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
