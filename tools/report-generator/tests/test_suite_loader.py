"""Tests for suite summary loading and timing enrichment."""

from __future__ import annotations

from pathlib import Path

from report_generator.k6.models import NormalizedRow, SuiteSummary
from report_generator.k6.suite_loader import (
    build_timing_index,
    enrich_rows_with_timing,
    load_suite_summary_from_local,
)


def _make_row(
    architecture: str = "monolith",
    scenario: str = "login",
    target_rps: int = 50,
    attempt: str = "attempt-01",
) -> NormalizedRow:
    return NormalizedRow(
        run_id="test-run",
        architecture=architecture,
        scenario=scenario,
        target_rps=target_rps,
        attempt=attempt,
        scaling_mode="fixed",
        duration="5m",
        actual_throughput=50.0,
        p95_latency_ms=100.0,
        error_rate=0.0,
        dropped_iterations=0,
        checks_rate=1.0,
        source_type="local",
        source_uri="test",
        summary_path="summary.json",
        metadata_path="metadata.json",
        thresholds_path="thresholds.json",
    )


def test_load_suite_summary_from_local(fixture_run_dir: Path) -> None:
    suite = load_suite_summary_from_local(fixture_run_dir)

    assert suite is not None
    assert suite.execution_mode == "parallel"
    assert suite.scaling_mode == "fixed"
    assert len(suite.cases) == 2


def test_load_suite_summary_from_local_missing(tmp_path: Path) -> None:
    suite = load_suite_summary_from_local(tmp_path)

    assert suite is None


def test_load_suite_summary_from_local_malformed(tmp_path: Path) -> None:
    suite_dir = tmp_path / "_suite"
    suite_dir.mkdir()
    (suite_dir / "summary.json").write_text("not json", encoding="utf-8")

    suite = load_suite_summary_from_local(tmp_path)

    assert suite is None


def test_build_timing_index_parallel() -> None:
    suite = SuiteSummary(
        execution_mode="parallel",
        cases=[
            {
                "scenario": "login",
                "target_rps": 1000,
                "started_at_utc": "2026-06-03T10:00:00Z",
                "finished_at_utc": "2026-06-03T10:05:00Z",
                "timing_source": "mixed",
                "architectures": {
                    "monolith": {
                        "started_at_utc": "2026-06-03T10:00:03Z",
                        "finished_at_utc": "2026-06-03T10:04:58Z",
                        "timing_source": "attempt_metadata",
                    },
                    "microservices": {
                        "started_at_utc": "2026-06-03T10:00:05Z",
                        "finished_at_utc": "2026-06-03T10:05:00Z",
                        "timing_source": "orchestrator",
                    },
                },
            }
        ],
    )

    index = build_timing_index(suite)

    assert ("monolith", "login", 1000) in index
    assert ("microservices", "login", 1000) in index
    assert index[("monolith", "login", 1000)]["timing_source"] == "attempt_metadata"
    assert index[("microservices", "login", 1000)]["timing_source"] == "orchestrator"


def test_build_timing_index_sequential() -> None:
    suite = SuiteSummary(
        execution_mode="sequential",
        cases=[
            {
                "architecture": "monolith",
                "scenario": "login",
                "target_rps": 1000,
                "started_at_utc": "2026-06-03T10:00:03Z",
                "finished_at_utc": "2026-06-03T10:05:18Z",
                "timing_source": "attempt_metadata",
                "architectures": {
                    "monolith": {
                        "started_at_utc": "2026-06-03T10:00:03Z",
                        "finished_at_utc": "2026-06-03T10:05:18Z",
                        "timing_source": "attempt_metadata",
                    }
                },
            }
        ],
    )

    index = build_timing_index(suite)

    assert ("monolith", "login", 1000) in index
    assert index[("monolith", "login", 1000)]["started_at_utc"] == "2026-06-03T10:00:03Z"


def test_enrich_rows_with_timing(fixture_run_dir: Path) -> None:
    suite = load_suite_summary_from_local(fixture_run_dir)
    rows = [
        _make_row("monolith", "login", 50),
        _make_row("microservices", "login", 50),
        _make_row("monolith", "login", 100),
        _make_row("microservices", "login", 100),
    ]

    enriched = enrich_rows_with_timing(rows, suite)

    assert len(enriched) == 4
    assert enriched[0].case_started_at_utc == "2026-05-27T04:35:03Z"
    assert enriched[0].timing_source == "attempt_metadata"
    assert enriched[1].case_started_at_utc == "2026-05-27T04:35:05Z"
    assert enriched[2].case_started_at_utc == "2026-05-27T04:40:25Z"
    assert enriched[3].case_started_at_utc == "2026-05-27T04:40:27Z"


def test_enrich_rows_with_timing_no_suite() -> None:
    rows = [_make_row()]

    enriched = enrich_rows_with_timing(rows, None)

    assert len(enriched) == 1
    assert enriched[0].case_started_at_utc is None
    assert enriched[0].timing_source is None


def test_enrich_rows_with_timing_no_matching_case() -> None:
    suite = SuiteSummary(
        cases=[
            {
                "scenario": "login",
                "target_rps": 5000,
                "started_at_utc": "2026-06-03T10:00:00Z",
                "finished_at_utc": "2026-06-03T10:05:00Z",
                "timing_source": "orchestrator",
                "architectures": {
                    "monolith": {
                        "started_at_utc": "2026-06-03T10:00:00Z",
                        "finished_at_utc": "2026-06-03T10:05:00Z",
                        "timing_source": "orchestrator",
                    }
                },
            }
        ],
    )
    rows = [_make_row("monolith", "login", 50)]

    enriched = enrich_rows_with_timing(rows, suite)

    assert enriched[0].case_started_at_utc is None


def test_enrich_rows_preserves_existing_fields(fixture_run_dir: Path) -> None:
    suite = load_suite_summary_from_local(fixture_run_dir)
    row = _make_row("monolith", "login", 50)

    enriched = enrich_rows_with_timing([row], suite)

    assert enriched[0].run_id == "test-run"
    assert enriched[0].actual_throughput == 50.0
    assert enriched[0].p95_latency_ms == 100.0
    assert enriched[0].case_started_at_utc == "2026-05-27T04:35:03Z"
