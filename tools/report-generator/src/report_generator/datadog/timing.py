"""Timing resolver for benchmark attempts."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from pydantic import BaseModel


class AttemptTiming(BaseModel):
    start_time: datetime
    end_time: datetime
    source: str


def parse_timestamp(ts_str: str | None) -> datetime | None:
    """Parse various ISO-8601 timestamp formats into timezone-aware UTC datetime."""
    if not ts_str:
        return None
    try:
        # Strip trailing Z and replace with UTC offset syntax for older pythons
        cleaned = ts_str.strip()
        if cleaned.endswith("Z"):
            cleaned = cleaned[:-1] + "+00:00"
        return datetime.fromisoformat(cleaned).astimezone(timezone.utc)
    except Exception:
        return None


def resolve_attempt_timing(
    metadata: dict[str, Any] | None,
    datadog_time_window: dict[str, Any] | None,
    fallback_start: str | None = None,
    fallback_end: str | None = None,
) -> AttemptTiming:
    """Resolve start and end datetimes using priority rules similar to the bash script.

    Priority order:
    1. metadata.json -> .datadog.time_window_start & .datadog.time_window_end
    2. datadog-time-window.json -> .time_window_start & .time_window_end
    3. metadata.json -> .timestamp_utc (start) & calculated end based on duration
    4. Fallbacks from suite summary or orchestrator.
    """
    # 1. Check metadata.json datadog window
    if metadata and "datadog" in metadata:
        dd = metadata["datadog"]
        if isinstance(dd, dict):
            start = parse_timestamp(dd.get("time_window_start"))
            end = parse_timestamp(dd.get("time_window_end"))
            if start and end:
                return AttemptTiming(start_time=start, end_time=end, source="attempt_metadata")

    # 2. Check datadog-time-window.json
    if datadog_time_window:
        start = parse_timestamp(datadog_time_window.get("time_window_start"))
        end = parse_timestamp(datadog_time_window.get("time_window_end"))
        if start and end:
            return AttemptTiming(start_time=start, end_time=end, source="datadog_artifact")

    # 3. Check metadata.json timestamp_utc + duration
    if metadata:
        start_str = metadata.get("timestamp_utc") or metadata.get("timestamp")
        start = parse_timestamp(start_str)
        if start:
            # Try to get duration from metadata
            # Default to 300 seconds if not specified (standard k6 run duration)
            duration_sec = 300.0
            if "k6" in metadata and isinstance(metadata["k6"], dict):
                k6_opt = metadata["k6"]
                if "duration" in k6_opt:
                    try:
                        dur_str = str(k6_opt["duration"])
                        if dur_str.endswith("s"):
                            duration_sec = float(dur_str[:-1])
                        else:
                            duration_sec = float(dur_str)
                    except ValueError:
                        pass
            elif "duration" in metadata:
                try:
                    dur_str = str(metadata["duration"]).strip().lower()
                    if dur_str.endswith("s"):
                        duration_sec = float(dur_str[:-1])
                    elif dur_str.endswith("m"):
                        duration_sec = float(dur_str[:-1]) * 60.0
                    elif dur_str.endswith("h"):
                        duration_sec = float(dur_str[:-1]) * 3600.0
                    else:
                        duration_sec = float(dur_str)
                except ValueError:
                    pass

            # End time is start + duration + padding (e.g. 10 seconds cool off)
            end = datetime.fromtimestamp(start.timestamp() + duration_sec + 10, timezone.utc)
            return AttemptTiming(start_time=start, end_time=end, source="attempt_metadata_partial")

    # 4. Use Fallbacks
    start = parse_timestamp(fallback_start)
    end = parse_timestamp(fallback_end)
    if start and end:
        return AttemptTiming(start_time=start, end_time=end, source="suite_summary_fallback")

    raise ValueError("Could not resolve benchmark start and end timings from any source.")
