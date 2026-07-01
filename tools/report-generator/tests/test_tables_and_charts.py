from __future__ import annotations

from pathlib import Path

import pandas as pd

from report_generator.k6.models import NormalizedRow
from report_generator.k6.parser import normalize_attempts
from report_generator.k6.sources.local import load_local_attempts
from report_generator.k6.table_images import write_report_table_images
from report_generator.k6.tables import write_report_tables
from report_generator.k6.charts import write_report_charts


def test_table_generation_orders_target_rps(fixture_run_dir: Path, tmp_path: Path) -> None:
    _, attempts, _ = load_local_attempts(fixture_run_dir)
    rows = normalize_attempts(attempts)

    tables = write_report_tables(rows, tmp_path / "tables", "latest")
    throughput_table = next(
        path for path in tables if path.name == "fixed-login-latest-throughput.csv"
    )
    frame = pd.read_csv(throughput_table)

    assert frame["Target RPS"].tolist() == [50, 100]
    assert list(frame.columns) == [
        "Target RPS",
        "Monolith (req/s)",
        "Microservices (req/s)",
    ]


def test_normalized_rows_include_successful_throughput_metrics(
    fixture_run_dir: Path,
) -> None:
    _, attempts, _ = load_local_attempts(fixture_run_dir)
    rows = normalize_attempts(attempts)

    row = next(
        row
        for row in rows
        if row.architecture == "monolith" and row.target_rps == 50
    )

    assert row.successful_throughput == row.actual_throughput
    assert row.throughput_achievement_pct == 100.0


def test_chart_generation_creates_non_empty_pngs(fixture_run_dir: Path, tmp_path: Path) -> None:
    _, attempts, _ = load_local_attempts(fixture_run_dir)
    rows = normalize_attempts(attempts)

    chart_paths = write_report_charts(rows, tmp_path / "charts", "latest")

    assert chart_paths
    for chart_path in chart_paths:
        assert chart_path.suffix == ".png"
        assert chart_path.exists()
        assert chart_path.stat().st_size > 0


def test_chart_generation_includes_rq1_priority_charts(
    fixture_run_dir: Path, tmp_path: Path
) -> None:
    _, attempts, _ = load_local_attempts(fixture_run_dir)
    rows = normalize_attempts(attempts)

    chart_paths = write_report_charts(rows, tmp_path / "charts", "latest")
    chart_names = {path.name for path in chart_paths}

    assert "fixed-login-latest-error-rate.png" in chart_names
    assert "fixed-login-latest-dropped-iterations.png" in chart_names
    assert "fixed-login-latest-achieved-rps.png" in chart_names
    assert "fixed-login-latest-throughput-achievement.png" in chart_names


def test_chart_generation_adds_scaling_change_scatter_when_fixed_and_hpa_exist(
    tmp_path: Path,
) -> None:
    rows = [
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=50.0,
            p95_latency_ms=100.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="fixed-login",
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
            p95_latency_ms=140.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="fixed-login-msa",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="hpa",
            duration="5m",
            actual_throughput=60.0,
            p95_latency_ms=90.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="hpa-login",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="microservices",
            scenario="sync-items",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=40.0,
            p95_latency_ms=160.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="fixed-sync",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="microservices",
            scenario="sync-items",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="hpa",
            duration="5m",
            actual_throughput=48.0,
            p95_latency_ms=150.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="hpa-sync",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="mixed-workload",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=55.0,
            p95_latency_ms=120.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="fixed-mixed",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="mixed-workload",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="hpa",
            duration="5m",
            actual_throughput=58.0,
            p95_latency_ms=118.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="hpa-mixed",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
    ]

    chart_paths = write_report_charts(rows, tmp_path / "charts", "latest")
    chart_names = {path.name for path in chart_paths}

    assert "fixed-vs-hpa-latest-throughput-change-scatter.png" in chart_names
    assert "fixed-vs-hpa-latest-p95-latency-change-scatter.png" in chart_names


def test_table_image_generation_creates_non_empty_pngs(
    fixture_run_dir: Path, tmp_path: Path
) -> None:
    _, attempts, _ = load_local_attempts(fixture_run_dir)
    rows = normalize_attempts(attempts)

    table_image_paths = write_report_table_images(
        rows, tmp_path / "table-images", "latest"
    )

    assert len(table_image_paths) == 7
    for table_image_path in table_image_paths:
        assert table_image_path.suffix == ".png"
        assert table_image_path.exists()
        assert table_image_path.stat().st_size > 0

    image_names = {path.name for path in table_image_paths}
    assert "fixed-login-latest-throughput-table.png" in image_names
    assert "fixed-login-latest-p95-latency-table.png" in image_names
    assert "fixed-login-latest-error-rate-table.png" in image_names
    assert "fixed-login-latest-dropped-iterations-table.png" in image_names
    assert "fixed-login-latest-achieved-rps-table.png" in image_names


def test_table_generation_uses_latest_attempt_mode(
    duplicate_attempt_rows, tmp_path: Path
) -> None:
    tables = write_report_tables(duplicate_attempt_rows, tmp_path / "tables", "latest")
    throughput_table = next(
        path for path in tables if path.name == "fixed-login-latest-throughput.csv"
    )
    frame = pd.read_csv(throughput_table)

    assert frame.loc[0, "Monolith (req/s)"] == 50.0
    assert frame.loc[0, "Microservices (req/s)"] == 47.0


def test_table_generation_uses_mean_attempt_mode(
    duplicate_attempt_rows, tmp_path: Path
) -> None:
    tables = write_report_tables(duplicate_attempt_rows, tmp_path / "tables", "mean")
    throughput_table = next(
        path for path in tables if path.name == "fixed-login-mean-throughput.csv"
    )
    frame = pd.read_csv(throughput_table)

    assert frame.loc[0, "Monolith (req/s)"] == 49.0
    assert frame.loc[0, "Microservices (req/s)"] == 46.0


def test_table_generation_uses_median_attempt_mode(
    duplicate_attempt_rows, tmp_path: Path
) -> None:
    tables = write_report_tables(duplicate_attempt_rows, tmp_path / "tables", "median")
    latency_table = next(
        path for path in tables if path.name == "fixed-login-median-p95-latency.csv"
    )
    frame = pd.read_csv(latency_table)

    assert frame.loc[0, "Monolith (ms)"] == 110.0
    assert frame.loc[0, "Microservices (ms)"] == 160.0


def test_chart_generation_includes_absolute_scatter_charts(
    tmp_path: Path,
) -> None:
    rows = [
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=50.0,
            p95_latency_ms=100.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="login-50",
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
            actual_throughput=48.0,
            p95_latency_ms=120.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="login-50-msa",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="create-transaction",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=49.0,
            p95_latency_ms=150.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="create-50",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="microservices",
            scenario="create-transaction",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=45.0,
            p95_latency_ms=180.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="create-50-msa",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
    ]

    chart_paths = write_report_charts(rows, tmp_path / "charts", "latest")
    chart_names = {path.name for path in chart_paths}

    assert "fixed-latest-throughput-absolute-scatter.png" in chart_names
    assert "fixed-latest-p95-latency-absolute-scatter.png" in chart_names


def test_absolute_scatter_chart_filters_to_common_rps_levels(tmp_path: Path) -> None:
    rows = [
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=50,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=50.0,
            p95_latency_ms=100.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="login-50",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=100,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=98.0,
            p95_latency_ms=120.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="login-100",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="login",
            target_rps=200,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=195.0,
            p95_latency_ms=150.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="login-200",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="create-transaction",
            target_rps=100,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=95.0,
            p95_latency_ms=200.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="create-100",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
        NormalizedRow(
            run_id="sample-run",
            architecture="monolith",
            scenario="create-transaction",
            target_rps=500,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration="5m",
            actual_throughput=480.0,
            p95_latency_ms=300.0,
            error_rate=0.0,
            dropped_iterations=0,
            checks_rate=1.0,
            source_type="local",
            source_uri="create-500",
            summary_path="summary.json",
            metadata_path="metadata.json",
            thresholds_path="thresholds.json",
        ),
    ]

    chart_paths = write_report_charts(rows, tmp_path / "charts", "latest")
    chart_names = {path.name for path in chart_paths}

    assert "fixed-latest-throughput-absolute-scatter.png" in chart_names
