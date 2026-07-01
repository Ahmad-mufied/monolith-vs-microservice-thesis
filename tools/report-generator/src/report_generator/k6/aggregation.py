"""Helpers for aggregating multiple attempts into report-ready series."""

from __future__ import annotations

import re

import pandas as pd

from report_generator.k6.models import AttemptMode, NormalizedRow

ATTEMPT_NUMBER_RE = re.compile(r"(\d+)$")
NUMERIC_METRICS = (
    "actual_throughput",
    "successful_throughput",
    "throughput_achievement_pct",
    "p95_latency_ms",
    "error_rate",
    "dropped_iterations",
    "checks_rate",
)


def rows_to_frame(rows: list[NormalizedRow]) -> pd.DataFrame:
    return pd.DataFrame([row.model_dump() for row in rows])


def aggregate_attempts(frame: pd.DataFrame, attempt_mode: AttemptMode) -> pd.DataFrame:
    if frame.empty:
        return frame.copy()

    if attempt_mode == "latest":
        return _latest_attempts(frame)

    if attempt_mode in {"mean", "median"}:
        return _aggregate_numeric(frame, attempt_mode)

    raise ValueError(f"unsupported attempt mode: {attempt_mode}")


def _latest_attempts(frame: pd.DataFrame) -> pd.DataFrame:
    latest = frame.copy()
    latest["_attempt_order"] = latest["attempt"].map(_attempt_order)
    latest = latest.sort_values(
        by=[
            "scaling_mode",
            "scenario",
            "target_rps",
            "architecture",
            "_attempt_order",
            "attempt",
        ]
    )
    latest = latest.groupby(
        ["scaling_mode", "scenario", "target_rps", "architecture"],
        as_index=False,
    ).tail(1)
    return latest.drop(columns=["_attempt_order"]).reset_index(drop=True)


def _aggregate_numeric(frame: pd.DataFrame, attempt_mode: AttemptMode) -> pd.DataFrame:
    base = _latest_attempts(frame)

    group_cols = ["scaling_mode", "scenario", "target_rps", "architecture"]
    numeric = frame[group_cols + list(NUMERIC_METRICS)].copy()
    grouped = numeric.groupby(group_cols, as_index=False)

    if attempt_mode == "mean":
        aggregated = grouped.mean(numeric_only=True)
    else:
        aggregated = grouped.median(numeric_only=True)

    merged = base.drop(columns=list(NUMERIC_METRICS)).merge(
        aggregated,
        on=group_cols,
        how="inner",
    )
    return merged.reset_index(drop=True)


def _attempt_order(value: object) -> int:
    if not isinstance(value, str):
        return -1
    match = ATTEMPT_NUMBER_RE.search(value)
    if not match:
        return -1
    return int(match.group(1))
