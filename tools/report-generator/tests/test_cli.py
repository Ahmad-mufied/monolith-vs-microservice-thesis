from __future__ import annotations

from pathlib import Path

import pytest

from report_generator.k6.cli import main
from report_generator.k6.models import ReportGenerationResult


def test_local_generate_success(fixture_run_dir: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    output_dir = tmp_path / "report"
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "local",
            "--input",
            str(fixture_run_dir),
            "--output",
            str(output_dir),
        ],
    )

    exit_code = main()

    assert exit_code == 0
    assert (output_dir / "master-results.csv").exists()
    assert (output_dir / "manifest.json").exists()
    assert (output_dir / "tables" / "fixed-login-latest-throughput.csv").exists()
    assert (
        output_dir / "tables" / "fixed-login-latest-successful-throughput.csv"
    ).exists()
    assert (
        output_dir / "tables" / "fixed-login-latest-throughput-achievement.csv"
    ).exists()
    assert (output_dir / "tables" / "fixed-login-latest-p95-latency.csv").exists()
    assert (output_dir / "tables" / "fixed-login-latest-error-rate.csv").exists()
    assert (
        output_dir / "tables" / "fixed-login-latest-dropped-iterations.csv"
    ).exists()
    assert (
        output_dir / "table-images" / "fixed-login-latest-throughput-table.png"
    ).exists()
    assert (
        output_dir
        / "table-images"
        / "fixed-login-latest-throughput-achievement-table.png"
    ).exists()
    assert (
        output_dir / "table-images" / "fixed-login-latest-p95-latency-table.png"
    ).exists()
    assert (output_dir / "charts" / "fixed-login-latest-throughput.png").exists()
    assert (
        output_dir / "charts" / "fixed-login-latest-throughput-achievement.png"
    ).exists()
    assert (output_dir / "charts" / "fixed-login-latest-p95-latency.png").exists()
    assert (output_dir / "charts" / "fixed-login-latest-error-rate.png").exists()
    assert (output_dir / "charts" / "fixed-login-latest-dropped-iterations.png").exists()
    assert (output_dir / "charts" / "fixed-login-latest-achieved-rps.png").exists()


def test_local_generate_success_prints_summary(
    fixture_run_dir: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    output_dir = tmp_path / "report"
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "local",
            "--input",
            str(fixture_run_dir),
            "--output",
            str(output_dir),
        ],
    )

    exit_code = main()

    assert exit_code == 0
    stdout = capsys.readouterr().out
    assert "Report generation complete." in stdout
    assert "run_id       : sample-run" in stdout
    assert "attempts     : 4" in stdout
    assert "attempt_mode : latest" in stdout
    assert "tables       : 6 file(s)" in stdout
    assert "table_images : 7 file(s)" in stdout
    assert "charts       : 8 file(s)" in stdout
    assert "timing       : 4/4 attempts with timing data" in stdout


def test_local_generate_missing_required_file(
    fixture_run_dir: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    missing_file = (
        fixture_run_dir
        / "monolith"
        / "login"
        / "50rps"
        / "attempt-01"
        / "thresholds.json"
    )
    missing_file.unlink()
    output_dir = tmp_path / "report"

    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "local",
            "--input",
            str(fixture_run_dir),
            "--output",
            str(output_dir),
        ],
    )

    exit_code = main()

    assert exit_code == 1
    assert "missing required file 'thresholds.json'" in capsys.readouterr().err


def test_local_generate_invalid_summary_metric(
    fixture_run_dir: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    summary_path = (
        fixture_run_dir
        / "microservices"
        / "login"
        / "100rps"
        / "attempt-01"
        / "summary.json"
    )
    summary_path.write_text(
        '{"metrics":{"http_reqs":{"values":{"count":30000,"rate":100}},'
        '"http_req_duration":{"values":{"avg":100}},'
        '"http_req_failed":{"values":{"rate":0}},'
        '"checks":{"values":{"rate":1}},'
        '"dropped_iterations":{"values":{"count":0}}}}',
        encoding="utf-8",
    )
    output_dir = tmp_path / "report"

    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "local",
            "--input",
            str(fixture_run_dir),
            "--output",
            str(output_dir),
        ],
    )

    exit_code = main()

    assert exit_code == 1
    assert "missing numeric metric" in capsys.readouterr().err


def test_cli_argument_validation_requires_local_input(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "local",
            "--output",
            "out",
        ],
    )
    with pytest.raises(SystemExit):
        main()


def test_cli_argument_validation_requires_s3_args(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "s3",
            "--output",
            "out",
        ],
    )
    with pytest.raises(SystemExit):
        main()


def test_cli_accepts_s3_uri(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    output_dir = tmp_path / "report"
    captured: dict[str, object] = {}

    def fake_generate_report(**kwargs: object) -> ReportGenerationResult:
        captured.update(kwargs)
        return ReportGenerationResult(
            run_id="sample-run",
            source_type="s3",
            source_uri="s3://benchmark-results/experiments/sample-run/",
            output_dir=str(output_dir),
            attempt_mode="latest",
            attempt_count=2,
            architectures=["microservices", "monolith"],
            scenarios=["login"],
            scaling_modes=["fixed"],
            master_results_path=str(output_dir / "master-results.csv"),
            manifest_path=str(output_dir / "manifest.json"),
            table_paths=[],
            table_image_paths=[],
            chart_paths=[],
        )

    monkeypatch.setattr("report_generator.k6.cli.generate_report", fake_generate_report)
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--source",
            "s3",
            "--s3-uri",
            "s3://benchmark-results/experiments/sample-run",
            "--output",
            str(output_dir),
        ],
    )

    exit_code = main()

    assert exit_code == 0
    assert captured["source_type"] == "s3"
    assert captured["s3_uri"] == "s3://benchmark-results/experiments/sample-run"
    assert captured["bucket"] is None
    assert captured["prefix"] is None


def test_generate_uses_configured_bucket_run_id_and_output_parent(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "k6-report-generator.toml"
    output_parent = tmp_path / "reports"
    config_path.write_text(
        "\n".join(
            [
                's3_bucket = "benchmark-results"',
                's3_experiments_prefix = "experiments"',
                f'output_parent = "{output_parent}"',
                'attempt_mode = "median"',
            ]
        ),
        encoding="utf-8",
    )
    captured: dict[str, object] = {}

    def fake_generate_report(**kwargs: object) -> ReportGenerationResult:
        captured.update(kwargs)
        output_dir = output_parent / "sample-run"
        return ReportGenerationResult(
            run_id="sample-run",
            source_type="s3",
            source_uri="s3://benchmark-results/experiments/sample-run/",
            output_dir=str(output_dir),
            attempt_mode="median",
            attempt_count=2,
            architectures=["microservices", "monolith"],
            scenarios=["login"],
            scaling_modes=["fixed"],
            master_results_path=str(output_dir / "master-results.csv"),
            manifest_path=str(output_dir / "manifest.json"),
            table_paths=[],
            table_image_paths=[],
            chart_paths=[],
        )

    monkeypatch.setattr("report_generator.k6.cli.generate_report", fake_generate_report)
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--config",
            str(config_path),
            "--run-id",
            "sample-run",
        ],
    )

    exit_code = main()

    assert exit_code == 0
    assert captured["source_type"] == "s3"
    assert captured["bucket"] == "benchmark-results"
    assert captured["prefix"] == "experiments/sample-run"
    assert captured["output_path"] == output_parent / "sample-run"
    assert captured["attempt_mode"] == "median"


def test_generate_cli_overrides_config_defaults(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    config_path = tmp_path / "k6-report-generator.toml"
    output_parent = tmp_path / "reports"
    explicit_output = tmp_path / "explicit-report"
    config_path.write_text(
        "\n".join(
            [
                's3_bucket = "benchmark-results"',
                's3_experiments_prefix = "experiments"',
                f'output_parent = "{output_parent}"',
                'attempt_mode = "latest"',
            ]
        ),
        encoding="utf-8",
    )
    captured: dict[str, object] = {}

    def fake_generate_report(**kwargs: object) -> ReportGenerationResult:
        captured.update(kwargs)
        return ReportGenerationResult(
            run_id="sample-run",
            source_type="s3",
            source_uri="s3://other-bucket/custom/sample-run/",
            output_dir=str(explicit_output),
            attempt_mode="mean",
            attempt_count=2,
            architectures=["microservices", "monolith"],
            scenarios=["login"],
            scaling_modes=["fixed"],
            master_results_path=str(explicit_output / "master-results.csv"),
            manifest_path=str(explicit_output / "manifest.json"),
            table_paths=[],
            table_image_paths=[],
            chart_paths=[],
        )

    monkeypatch.setattr("report_generator.k6.cli.generate_report", fake_generate_report)
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "generate",
            "--config",
            str(config_path),
            "--run-id",
            "sample-run",
            "--bucket",
            "other-bucket",
            "--experiments-prefix",
            "custom",
            "--output",
            str(explicit_output),
            "--attempt-mode",
            "mean",
        ],
    )

    exit_code = main()

    assert exit_code == 0
    assert captured["bucket"] == "other-bucket"
    assert captured["prefix"] == "custom/sample-run"
    assert captured["output_path"] == explicit_output
    assert captured["attempt_mode"] == "mean"


def test_list_runs_uses_configured_bucket(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    config_path = tmp_path / "k6-report-generator.toml"
    config_path.write_text(
        "\n".join(
            [
                's3_bucket = "benchmark-results"',
                's3_experiments_prefix = "experiments"',
            ]
        ),
        encoding="utf-8",
    )
    captured: dict[str, object] = {}

    def fake_list_s3_run_ids(
        bucket: str,
        experiments_prefix: str = "experiments",
        limit: int = 20,
    ) -> list[str]:
        captured["bucket"] = bucket
        captured["experiments_prefix"] = experiments_prefix
        captured["limit"] = limit
        return ["eks-suite-fixed-001", "eks-suite-hpa-001"]

    monkeypatch.setattr("report_generator.k6.cli.list_s3_run_ids", fake_list_s3_run_ids)
    monkeypatch.setattr(
        "sys.argv",
        [
            "k6-report-generator",
            "list-runs",
            "--config",
            str(config_path),
            "--limit",
            "5",
        ],
    )

    exit_code = main()

    assert exit_code == 0
    assert captured == {
        "bucket": "benchmark-results",
        "experiments_prefix": "experiments",
        "limit": 5,
    }
    stdout = capsys.readouterr().out
    assert "eks-suite-fixed-001" in stdout
    assert "eks-suite-hpa-001" in stdout
