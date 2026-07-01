from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from report_generator.k6.models import NormalizedRow


@pytest.fixture()
def fixture_run_dir(tmp_path: Path) -> Path:
    source = Path(__file__).parent / "fixtures" / "sample-run"
    destination = tmp_path / "sample-run"
    shutil.copytree(source, destination)
    return destination


@pytest.fixture()
def duplicate_attempt_rows() -> list[NormalizedRow]:
    return [
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=48.0,
            p95_latency_ms=100.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="attempt-01",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-02",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=50.0,
            p95_latency_ms=120.0,
            error_rate=0.0,
            dropped_iterations=1,
            checks_rate=1.0,
            source_type="local",
            source_uri="attempt-02",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="microservices",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=45.0,
            p95_latency_ms=150.0,
            error_rate=0.0,
            dropped_iterations=2,
            checks_rate=1.0,
            source_type="local",
            source_uri="attempt-01",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="microservices",
            scenario="login",
            target_rps=50,
            attempt="attempt-02",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=47.0,
            p95_latency_ms=170.0,
            error_rate=0.0,
            dropped_iterations=4,
            checks_rate=1.0,
            source_type="local",
            source_uri="attempt-02",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
    ]
