"""Shared helper functions."""

from __future__ import annotations

from pathlib import Path
import re
from typing import Any

from report_generator.k6.exceptions import InvalidArtifactError

RPS_DIR_RE = re.compile(r"^(?P<rps>\d+)rps$")
S3_URI_RE = re.compile(r"^s3://(?P<bucket>[^/]+)/?(?P<prefix>.*)$")


def parse_rps_dir(name: str) -> int:
    match = RPS_DIR_RE.match(name)
    if not match:
        raise InvalidArtifactError(f"invalid RPS directory name: {name}")
    return int(match.group("rps"))


def parse_duration_to_seconds(duration: str) -> int:
    match = re.fullmatch(r"(?P<value>\d+)(?P<unit>[smh])", duration.strip())
    if not match:
        raise InvalidArtifactError(f"unsupported duration format: {duration}")

    multipliers = {"s": 1, "m": 60, "h": 3600}
    value = int(match.group("value"))
    unit = match.group("unit")
    return value * multipliers[unit]


def require_dict(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InvalidArtifactError(f"{context} must be a JSON object")
    return value


def metric_values(summary: dict[str, Any], metric_name: str) -> dict[str, Any]:
    metrics = require_dict(summary.get("metrics"), "summary.metrics")
    metric = require_dict(metrics.get(metric_name), f"summary.metrics.{metric_name}")
    values = metric.get("values")
    if isinstance(values, dict):
        return values
    return metric


def metric_float(values: dict[str, Any], keys: tuple[str, ...], context: str) -> float:
    for key in keys:
        value = values.get(key)
        if isinstance(value, (int, float)):
            return float(value)
    raise InvalidArtifactError(f"missing numeric metric for {context}")


def metric_int(values: dict[str, Any], keys: tuple[str, ...], context: str) -> int:
    return int(metric_float(values, keys, context))


def scaling_mode_from_metadata(metadata: dict[str, Any]) -> str:
    candidates = (
        metadata.get("scaling_mode"),
        metadata.get("autoscaling_mode"),
        (metadata.get("resources") or {}).get("autoscaling_mode"),
        (metadata.get("resources_configuration") or {}).get("autoscaling_mode"),
        metadata.get("k6_profile"),
        (metadata.get("k6_configuration") or {}).get("profile"),
    )
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            val = candidate.strip().lower()
            if "hpa" in val:
                return "hpa"
            if val in ("steady", "fixed", "smoke", "steady-state"):
                return "fixed"
            return val
    return "fixed"


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def parse_s3_uri(uri: str) -> tuple[str, str]:
    match = S3_URI_RE.fullmatch(uri.strip())
    if not match:
        raise InvalidArtifactError(
            f"invalid S3 URI: {uri}. Expected format: s3://bucket/prefix"
        )

    bucket = match.group("bucket").strip()
    prefix = match.group("prefix").strip().strip("/")
    if not bucket:
        raise InvalidArtifactError("S3 URI is missing a bucket name")
    if not prefix:
        raise InvalidArtifactError("S3 URI must include a non-empty prefix")
    return bucket, prefix
