"""Parsing and normalization logic."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from report_generator.k6.exceptions import InvalidArtifactError
from report_generator.k6.models import AttemptArtifacts, NormalizedRow
from report_generator.k6.utils import (
    metric_float,
    metric_int,
    metric_values,
    parse_duration_to_seconds,
    scaling_mode_from_metadata,
)


def normalize_attempts(attempts: list[AttemptArtifacts]) -> list[NormalizedRow]:
    return [normalize_attempt(attempt) for attempt in attempts]


def _verify_metadata_match(
    actual: Any,
    expected: Any,
    field_name: str,
    source_uri: str,
    cast_fn: Callable[[Any], Any] = lambda x: x,
) -> None:
    if actual is not None and actual != "":
        try:
            casted = cast_fn(actual)
        except (ValueError, TypeError) as exc:
            raise InvalidArtifactError(
                f"invalid {field_name} in metadata for {source_uri}: {actual}"
            ) from exc
        if casted != expected:
            raise InvalidArtifactError(
                f"{field_name} mismatch for {source_uri}: path={expected} metadata={actual}"
            )


def normalize_attempt(attempt: AttemptArtifacts) -> NormalizedRow:
    metadata = attempt.metadata
    summary = attempt.summary

    _verify_metadata_match(metadata.get("target_rps"), attempt.target_rps, "target_rps", attempt.source_uri, int)
    _verify_metadata_match(metadata.get("architecture"), attempt.architecture, "architecture", attempt.source_uri)

    duration = metadata.get("duration")
    if not isinstance(duration, str) or not duration:
        raise InvalidArtifactError(f"missing duration in metadata.json for {attempt.source_uri}")

    scaling_mode = scaling_mode_from_metadata(metadata)

    http_reqs_values = metric_values(summary, "http_reqs")
    http_duration_values = metric_values(summary, "http_req_duration")
    http_failed_values = metric_values(summary, "http_req_failed")
    checks_values = metric_values(summary, "checks")
    dropped_values = metric_values(summary, "dropped_iterations")

    throughput = _actual_throughput(http_reqs_values, duration, attempt.source_uri)
    error_rate = metric_float(
        http_failed_values,
        ("rate",),
        f"{attempt.source_uri} http_req_failed rate",
    )
    successful_throughput = throughput * max(0.0, 1.0 - error_rate)
    throughput_achievement_pct = (
        (successful_throughput / attempt.target_rps) * 100
        if attempt.target_rps > 0
        else 0.0
    )
    p95_latency_ms = metric_float(
        http_duration_values,
        ("p(95)", "p95"),
        f"{attempt.source_uri} http_req_duration p95",
    )
    checks_rate = metric_float(
        checks_values,
        ("rate",),
        f"{attempt.source_uri} checks rate",
    )
    dropped_iterations = metric_int(
        dropped_values,
        ("count",),
        f"{attempt.source_uri} dropped_iterations count",
    )

    return NormalizedRow(
        run_id=attempt.run_id,
        architecture=attempt.architecture,
        scenario=attempt.scenario,
        target_rps=attempt.target_rps,
        attempt=attempt.attempt,
        scaling_mode=scaling_mode,
        duration=duration,
        actual_throughput=throughput,
        successful_throughput=successful_throughput,
        throughput_achievement_pct=throughput_achievement_pct,
        p95_latency_ms=p95_latency_ms,
        error_rate=error_rate,
        dropped_iterations=dropped_iterations,
        checks_rate=checks_rate,
        source_type=attempt.source_type,
        source_uri=attempt.source_uri,
        summary_path=attempt.summary_path,
        metadata_path=attempt.metadata_path,
        thresholds_path=attempt.thresholds_path,
        git_commit=_optional_string(metadata.get("git_commit")),
        image_tag=_optional_string(metadata.get("image_tag")),
        dataset_version=_optional_string(metadata.get("dataset_version")),
        result_status=_extract_result_status(attempt.result_status),
    )


def _actual_throughput(
    http_reqs_values: dict[str, object], duration: str, source_uri: str
) -> float:
    rate = http_reqs_values.get("rate")
    if isinstance(rate, (int, float)):
        return float(rate)

    count = http_reqs_values.get("count")
    if isinstance(count, (int, float)):
        seconds = parse_duration_to_seconds(duration)
        return float(count) / seconds

    raise InvalidArtifactError(f"missing http_reqs rate/count metric for {source_uri}")


def _optional_string(value: object) -> str | None:
    if isinstance(value, str) and value:
        return value
    return None


def _extract_result_status(result_status: dict[str, object] | None) -> str | None:
    if not result_status:
        return None
    for key in ("status", "outcome", "classification_hint"):
        status = result_status.get(key)
        if isinstance(status, str) and status:
            return status
    return None
