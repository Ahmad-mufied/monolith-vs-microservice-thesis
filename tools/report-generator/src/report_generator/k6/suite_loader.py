"""Suite summary loading and timing enrichment."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from report_generator.k6.models import NormalizedRow, SuiteSummary


def load_suite_summary_from_s3(
    s3_client: Any, bucket: str, prefix: str
) -> SuiteSummary | None:
    """Load _suite/summary.json or _arch_suite/summary.json from S3. Returns None if not found or malformed."""
    for folder in ("_suite", "_arch_suite"):
        key = f"{prefix.strip('/')}/{folder}/summary.json"
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
            data = json.loads(response["Body"].read().decode("utf-8"))
            return SuiteSummary.model_validate(data)
        except s3_client.exceptions.NoSuchKey:
            continue
        except Exception as exc:
            print(
                f"WARNING: could not load suite summary from s3://{bucket}/{key}: {exc}",
                file=sys.stderr,
            )
    return None


def load_suite_summary_from_local(run_root: Path) -> SuiteSummary | None:
    """Load _suite/summary.json or _arch_suite/summary.json from local filesystem. Returns None if not found or malformed."""
    for folder in ("_suite", "_arch_suite"):
        summary_path = run_root / folder / "summary.json"
        if not summary_path.exists():
            continue
        try:
            data = json.loads(summary_path.read_text(encoding="utf-8"))
            return SuiteSummary.model_validate(data)
        except Exception as exc:
            print(
                f"WARNING: could not parse {summary_path}: {exc}",
                file=sys.stderr,
            )
    return None


def build_timing_index(
    suite: SuiteSummary,
) -> dict[tuple[str, str, int], dict[str, str | None]]:
    """Build lookup: (architecture, scenario, target_rps) -> timing fields."""
    index: dict[tuple[str, str, int], dict[str, str | None]] = {}

    for case in suite.cases:
        scenario = case.get("scenario")
        target_rps = case.get("target_rps")
        if not scenario or not target_rps:
            continue

        case_started = case.get("started_at_utc")
        case_finished = case.get("finished_at_utc")
        case_timing_source = case.get("timing_source")

        architectures = case.get("architectures", {})
        for arch_name, arch_timing in architectures.items():
            if not isinstance(arch_timing, dict):
                continue
            index[(arch_name, scenario, int(target_rps))] = {
                "started_at_utc": arch_timing.get("started_at_utc", case_started),
                "finished_at_utc": arch_timing.get("finished_at_utc", case_finished),
                "timing_source": arch_timing.get("timing_source", case_timing_source),
            }

        if "monolith" not in architectures and case.get("monolith_s3_uri"):
            index[("monolith", scenario, int(target_rps))] = {
                "started_at_utc": case_started,
                "finished_at_utc": case_finished,
                "timing_source": case_timing_source,
            }
        if "microservices" not in architectures and case.get("microservices_s3_uri"):
            index[("microservices", scenario, int(target_rps))] = {
                "started_at_utc": case_started,
                "finished_at_utc": case_finished,
                "timing_source": case_timing_source,
            }

    return index


def enrich_rows_with_timing(
    rows: list[NormalizedRow],
    suite: SuiteSummary | None,
) -> list[NormalizedRow]:
    """Enrich normalized rows with timing from suite summary.

    Returns rows unchanged if suite summary is None or has no usable timing.
    """
    if suite is None:
        return rows

    timing_index = build_timing_index(suite)
    if not timing_index:
        return rows

    enriched: list[NormalizedRow] = []
    for row in rows:
        key = (row.architecture, row.scenario, row.target_rps)
        timing = timing_index.get(key)
        if timing:
            row = row.model_copy(
                update={
                    "case_started_at_utc": timing.get("started_at_utc"),
                    "case_finished_at_utc": timing.get("finished_at_utc"),
                    "timing_source": timing.get("timing_source"),
                }
            )
        enriched.append(row)

    return enriched
