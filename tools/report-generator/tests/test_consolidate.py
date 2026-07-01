import os
from pathlib import Path
import pytest
import pandas as pd
from unittest.mock import MagicMock, patch

from report_generator.consolidate import (
    load_runs_config,
    filter_composite_results,
    compile_consolidated_dataset,
    resolve_data_file,
)


def test_load_runs_config(tmp_path):
    # Test valid configuration
    config_content = """
[consolidation.runs]
mono_fixed_true = "run_id_1"
msa_fixed_true = "run_id_1"
msa_hpa_true = "run_id_2"
mono_fixed_false = "run_id_3"
msa_fixed_false = "run_id_3"
msa_hpa_false = "run_id_4"
"""
    config_file = tmp_path / "report-generator.toml"
    config_file.write_text(config_content)

    runs = load_runs_config(config_file)
    assert len(runs) == 6
    assert runs["mono_fixed_true"] == "run_id_1"
    assert runs["msa_hpa_false"] == "run_id_4"


def test_load_runs_config_missing_keys(tmp_path):
    # Test configuration missing required keys
    config_content = """
[consolidation.runs]
mono_fixed_true = "run_id_1"
"""
    config_file = tmp_path / "report-generator.toml"
    config_file.write_text(config_content)

    with pytest.raises(ValueError, match="Missing required consolidation runs"):
        load_runs_config(config_file)


def test_filter_composite_results():
    # Mock dataframe with multiple architectures and scaling modes
    df = pd.DataFrame([
        {"architecture": "monolith", "scaling_mode": "fixed", "target_rps": 100, "value": 10},
        {"architecture": "microservices", "scaling_mode": "fixed", "target_rps": 100, "value": 20},
        {"architecture": "microservices", "scaling_mode": "hpa", "target_rps": 100, "value": 30},
        {"architecture": "monolith", "scaling_mode": "hpa", "target_rps": 100, "value": 40},
    ])

    df_mono_fixed = filter_composite_results(df, "monolith", "fixed")
    assert len(df_mono_fixed) == 1
    assert df_mono_fixed.iloc[0]["value"] == 10

    df_msa_fixed = filter_composite_results(df, "microservices", "fixed")
    assert len(df_msa_fixed) == 1
    assert df_msa_fixed.iloc[0]["value"] == 20

    df_msa_hpa = filter_composite_results(df, "microservices", "hpa")
    assert len(df_msa_hpa) == 1
    assert df_msa_hpa.iloc[0]["value"] == 30


def _make_runs_and_files(tmp_path, include_extra_scenarios=False):
    """Helper: create run directories with CSV files for testing."""
    runs = {
        "mono_fixed_true": "run_1",
        "msa_fixed_true": "run_1",
        "msa_hpa_true": "run_2",
        "mono_fixed_false": "run_3",
        "msa_fixed_false": "run_3",
        "msa_hpa_false": "run_4",
    }

    # run_1 (composite: monolith + msa fixed, admission enabled)
    run_1_dir = tmp_path / "run_1"
    run_1_dir.mkdir()
    rows_run_1 = [
        {"architecture": "monolith", "scaling_mode": "fixed", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 5.0, "actual_throughput": 98.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 98.0},
        {"architecture": "microservices", "scaling_mode": "fixed", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 10.0, "actual_throughput": 95.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 95.0},
    ]
    if include_extra_scenarios:
        rows_run_1 += [
            {"architecture": "monolith", "scaling_mode": "fixed", "scenario": "create-transaction",
             "target_rps": 100, "p95_latency_ms": 3.0, "actual_throughput": 99.0,
             "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 99.0},
            {"architecture": "microservices", "scaling_mode": "fixed", "scenario": "create-transaction",
             "target_rps": 100, "p95_latency_ms": 4.0, "actual_throughput": 97.0,
             "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 97.0},
            {"architecture": "monolith", "scaling_mode": "fixed", "scenario": "enriched-transactions",
             "target_rps": 100, "p95_latency_ms": 8.0, "actual_throughput": 96.0,
             "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 96.0},
            {"architecture": "microservices", "scaling_mode": "fixed", "scenario": "enriched-transactions",
             "target_rps": 100, "p95_latency_ms": 12.0, "actual_throughput": 92.0,
             "checks_rate": 0.9, "error_rate": 0.1, "throughput_achievement_pct": 82.0},
        ]
    pd.DataFrame(rows_run_1).to_csv(run_1_dir / "master-results.csv", index=False)

    # run_2 (msa hpa, admission enabled) — only microservices
    run_2_dir = tmp_path / "run_2"
    run_2_dir.mkdir()
    pd.DataFrame([
        {"architecture": "microservices", "scaling_mode": "hpa", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 8.0, "actual_throughput": 97.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 97.0},
    ]).to_csv(run_2_dir / "master-results.csv", index=False)

    # run_3 (composite: monolith + msa fixed, admission disabled) — login only (mirrors ablation run)
    run_3_dir = tmp_path / "run_3"
    run_3_dir.mkdir()
    pd.DataFrame([
        {"architecture": "monolith", "scaling_mode": "fixed", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 6.0, "actual_throughput": 99.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 99.0},
        {"architecture": "microservices", "scaling_mode": "fixed", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 12.0, "actual_throughput": 94.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 94.0},
    ]).to_csv(run_3_dir / "master-results.csv", index=False)

    # run_4 (msa hpa, admission disabled)
    run_4_dir = tmp_path / "run_4"
    run_4_dir.mkdir()
    pd.DataFrame([
        {"architecture": "microservices", "scaling_mode": "hpa", "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 9.0, "actual_throughput": 96.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 96.0},
    ]).to_csv(run_4_dir / "master-results.csv", index=False)

    return runs


def test_compile_consolidated_dataset(tmp_path):
    """Base case: login-only data — all 6 run_labels produce exactly 1 row each."""
    runs = _make_runs_and_files(tmp_path, include_extra_scenarios=False)

    def mock_resolve(run_id, filename, cache_dir, s3_bucket):
        return tmp_path / run_id / filename

    with patch("report_generator.consolidate.resolve_data_file", side_effect=mock_resolve):
        compiled_df = compile_consolidated_dataset(
            runs=runs,
            filename="master-results.csv",
            cache_dir=tmp_path,
            s3_bucket="mock-bucket",
        )

    # 6 run_labels × 1 row each (login only in mock data)
    assert len(compiled_df) == 6
    assert "run_label" in compiled_df.columns
    assert "admission" in compiled_df.columns

    mono_fixed_true_rows = compiled_df[compiled_df["run_label"] == "mono_fixed_true"]
    assert len(mono_fixed_true_rows) == 1
    assert mono_fixed_true_rows.iloc[0]["architecture"] == "monolith"
    assert bool(mono_fixed_true_rows.iloc[0]["admission"]) is True

    msa_hpa_false_rows = compiled_df[compiled_df["run_label"] == "msa_hpa_false"]
    assert len(msa_hpa_false_rows) == 1
    assert msa_hpa_false_rows.iloc[0]["architecture"] == "microservices"
    assert msa_hpa_false_rows.iloc[0]["scaling_mode"] == "hpa"
    assert bool(msa_hpa_false_rows.iloc[0]["admission"]) is False


def test_compile_consolidated_dataset_preserves_all_scenarios(tmp_path):
    """Non-login scenarios must NOT be filtered out — all scenarios pass through."""
    runs = _make_runs_and_files(tmp_path, include_extra_scenarios=True)

    def mock_resolve(run_id, filename, cache_dir, s3_bucket):
        return tmp_path / run_id / filename

    with patch("report_generator.consolidate.resolve_data_file", side_effect=mock_resolve):
        compiled_df = compile_consolidated_dataset(
            runs=runs,
            filename="master-results.csv",
            cache_dir=tmp_path,
            s3_bucket="mock-bucket",
        )

    # run_1 has 6 rows (2 login + 2 create-transaction + 2 enriched-transactions)
    # run_1 is used by mono_fixed_true AND msa_fixed_true → each filtered to their arch
    # → mono_fixed_true: monolith rows from run_1 = 3 (login + create-tx + enriched-tx)
    # → msa_fixed_true: microservices rows from run_1 = 3
    # → msa_hpa_true: run_2 (only login) = 1
    # → mono_fixed_false: monolith rows from run_3 = 1 (login only)
    # → msa_fixed_false: microservices rows from run_3 = 1 (login only)
    # → msa_hpa_false: run_4 = 1
    # Total = 3 + 3 + 1 + 1 + 1 + 1 = 10
    assert len(compiled_df) == 10

    # All three scenarios must be present
    present_scenarios = set(compiled_df["scenario"].unique())
    assert "login" in present_scenarios
    assert "create-transaction" in present_scenarios
    assert "enriched-transactions" in present_scenarios

    # mono_fixed_true should have 3 rows (one per scenario)
    mono_rows = compiled_df[compiled_df["run_label"] == "mono_fixed_true"]
    assert len(mono_rows) == 3
    assert set(mono_rows["scenario"]) == {"login", "create-transaction", "enriched-transactions"}

    # msa_hpa_true still has 1 row (run_2 only has login)
    hpa_rows = compiled_df[compiled_df["run_label"] == "msa_hpa_true"]
    assert len(hpa_rows) == 1
    assert hpa_rows.iloc[0]["scenario"] == "login"


@patch("boto3.client")
def test_resolve_data_file_s3_fallback(mock_boto_client, tmp_path):
    # Setup mock local path that doesn't exist initially
    cache_dir = tmp_path / "cache"
    run_id = "test-run"
    filename = "master-results.csv"
    local_file_path = cache_dir / run_id / filename

    mock_s3 = MagicMock()
    mock_boto_client.return_value = mock_s3

    # Define side effect to create the file when download_file is called
    def side_effect(bucket, key, filename):
        os.makedirs(os.path.dirname(filename), exist_ok=True)
        with open(filename, "w") as f:
            f.write("architecture,scaling_mode\nmonolith,fixed")

    mock_s3.download_file.side_effect = side_effect

    resolved_path = resolve_data_file(
        run_id=run_id,
        filename=filename,
        cache_dir=cache_dir,
        s3_bucket="mock-bucket",
    )

    assert resolved_path == local_file_path
    assert local_file_path.exists()
    mock_s3.download_file.assert_called_once_with(
        "mock-bucket",
        f"experiments/{run_id}/{filename}",
        str(local_file_path),
    )


def test_generate_consolidated_plots_invalid_metric_type(tmp_path):
    """Invalid metric_type must raise ValueError immediately — not silently no-op."""
    from report_generator.consolidate import generate_consolidated_plots

    df = pd.DataFrame([
        {"run_label": "mono_fixed_true", "admission": True, "scenario": "login",
         "target_rps": 100, "p95_latency_ms": 5.0, "checks_rate": 1.0, "error_rate": 0.0,
         "throughput_achievement_pct": 98.0},
    ])
    with pytest.raises(ValueError, match="metric_type must be"):
        generate_consolidated_plots(df, tmp_path / "out", metric_type="invalid")


@patch("matplotlib.figure.Figure.savefig")
def test_consolidate_plotting_invocation(mock_savefig, tmp_path):
    """Verify generate_consolidated_plots produces one chart per scenario × metric (k6 path)."""
    from report_generator.consolidate import generate_consolidated_plots

    # Two scenarios in primary data
    login_rows = [
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 5.0, "actual_throughput": 98.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 98.0},
        {"run_label": "msa_fixed_true", "architecture": "microservices", "scaling_mode": "fixed",
         "admission": True, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 10.0, "actual_throughput": 95.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 95.0},
        {"run_label": "msa_hpa_true", "architecture": "microservices", "scaling_mode": "hpa",
         "admission": True, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 8.0, "actual_throughput": 97.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 97.0},
        {"run_label": "mono_fixed_false", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": False, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 6.0, "actual_throughput": 99.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 99.0},
        {"run_label": "msa_fixed_false", "architecture": "microservices", "scaling_mode": "fixed",
         "admission": False, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 12.0, "actual_throughput": 94.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 94.0},
        {"run_label": "msa_hpa_false", "architecture": "microservices", "scaling_mode": "hpa",
         "admission": False, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 9.0, "actual_throughput": 96.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 96.0},
    ]
    create_tx_rows = [
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "create-transaction", "target_rps": 100,
         "p95_latency_ms": 3.0, "actual_throughput": 99.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 99.0},
        {"run_label": "msa_fixed_true", "architecture": "microservices", "scaling_mode": "fixed",
         "admission": True, "scenario": "create-transaction", "target_rps": 100,
         "p95_latency_ms": 4.0, "actual_throughput": 97.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 97.0},
        {"run_label": "msa_hpa_true", "architecture": "microservices", "scaling_mode": "hpa",
         "admission": True, "scenario": "create-transaction", "target_rps": 100,
         "p95_latency_ms": 3.5, "actual_throughput": 98.0, "checks_rate": 1.0,
         "error_rate": 0.0, "throughput_achievement_pct": 98.0},
    ]
    df = pd.DataFrame(login_rows + create_tx_rows)

    output_dir = tmp_path / "output_plots"
    generate_consolidated_plots(df, output_dir, metric_type="k6")

    # With 2 scenarios in primary_df × 4 charts per scenario = 8 primary charts
    # + 2 ablation charts (login filtered) = 10 minimum savefig calls
    assert mock_savefig.call_count >= 10


@patch("matplotlib.figure.Figure.savefig")
def test_consolidate_plotting_per_scenario_file_names(mock_savefig, tmp_path):
    """Each scenario must produce its own set of chart files in output_dir."""
    from report_generator.consolidate import generate_consolidated_plots

    df = pd.DataFrame([
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 5.0, "actual_throughput": 98.0, "successful_throughput": 98.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 98.0},
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "create-transaction", "target_rps": 100,
         "p95_latency_ms": 3.0, "actual_throughput": 99.0, "successful_throughput": 99.0,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 99.0},
        # ablation data for login
        {"run_label": "mono_fixed_false", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": False, "scenario": "login", "target_rps": 100,
         "p95_latency_ms": 6.0, "actual_throughput": 99.5, "successful_throughput": 99.5,
         "checks_rate": 1.0, "error_rate": 0.0, "throughput_achievement_pct": 99.5},
    ])

    output_dir = tmp_path / "out"
    generate_consolidated_plots(df, output_dir, metric_type="k6")

    # Collect all file paths that savefig was called with
    saved_paths = {str(call.args[0]) for call in mock_savefig.call_args_list}

    # Per-scenario primary charts must exist for both scenarios
    assert any("primary-login-success-rate" in p for p in saved_paths), \
        f"Expected primary-login-success-rate.png, got: {saved_paths}"
    assert any("primary-create-transaction-success-rate" in p for p in saved_paths), \
        f"Expected primary-create-transaction-success-rate.png, got: {saved_paths}"
    assert any("primary-login-throughput-achievement" in p for p in saved_paths), \
        f"Expected primary-login-throughput-achievement.png, got: {saved_paths}"
    assert any("primary-login-throughput-breakdown" in p for p in saved_paths), \
        f"Expected primary-login-throughput-breakdown.png, got: {saved_paths}"
    assert any("primary-create-transaction-throughput-breakdown" in p for p in saved_paths), \
        f"Expected primary-create-transaction-throughput-breakdown.png, got: {saved_paths}"

    # Ablation charts must still exist
    assert any("ablation-success-rate" in p for p in saved_paths), \
        f"Expected ablation-success-rate.png, got: {saved_paths}"


@patch("matplotlib.figure.Figure.savefig")
def test_consolidate_plotting_datadog(mock_savefig, tmp_path):
    """Verify generate_consolidated_plots generates CPU/Mem usage and efficiency charts."""
    from report_generator.consolidate import generate_consolidated_plots

    df = pd.DataFrame([
        # Scenario: login
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "login", "target_rps": 100, "Achieved RPS": 98.0,
         "Avg CPU (m)": 500.0, "Avg Mem (Mi)": 256.0},
        {"run_label": "msa_fixed_true", "architecture": "microservices", "scaling_mode": "fixed",
         "admission": True, "scenario": "login", "target_rps": 100, "Achieved RPS": 95.0,
         "Avg CPU (m)": 600.0, "Avg Mem (Mi)": 512.0},
        {"run_label": "msa_hpa_true", "architecture": "microservices", "scaling_mode": "hpa",
         "admission": True, "scenario": "login", "target_rps": 100, "Achieved RPS": 97.0,
         "Avg CPU (m)": 550.0, "Avg Mem (Mi)": 400.0},
        # Scenario: create-transaction
        {"run_label": "mono_fixed_true", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": True, "scenario": "create-transaction", "target_rps": 100, "Achieved RPS": 99.0,
         "Avg CPU (m)": 700.0, "Avg Mem (Mi)": 300.0},
        # ablation data for login
        {"run_label": "mono_fixed_false", "architecture": "monolith", "scaling_mode": "fixed",
         "admission": False, "scenario": "login", "target_rps": 100, "Achieved RPS": 99.5,
         "Avg CPU (m)": 800.0, "Avg Mem (Mi)": 350.0},
    ])

    output_dir = tmp_path / "out"
    generate_consolidated_plots(df, output_dir, metric_type="datadog")

    # Collect all file paths that savefig was called with
    saved_paths = {str(call.args[0]) for call in mock_savefig.call_args_list}

    # Verify primary CPU and Memory usage charts
    assert any("primary-login-cpu-usage.png" in p for p in saved_paths), f"Missing login-cpu-usage, got {saved_paths}"
    assert any("primary-login-memory-usage.png" in p for p in saved_paths), f"Missing login-memory-usage, got {saved_paths}"
    assert any("primary-create-transaction-cpu-usage.png" in p for p in saved_paths), f"Missing create-tx-cpu-usage, got {saved_paths}"
    assert any("primary-create-transaction-memory-usage.png" in p for p in saved_paths), f"Missing create-tx-memory-usage, got {saved_paths}"

    # Verify primary resource efficiency charts (newly added)
    assert any("primary-login-cpu-efficiency.png" in p for p in saved_paths), f"Missing login-cpu-efficiency, got {saved_paths}"
    assert any("primary-login-mem-efficiency.png" in p for p in saved_paths), f"Missing login-mem-efficiency, got {saved_paths}"
    assert any("primary-create-transaction-cpu-efficiency.png" in p for p in saved_paths), f"Missing create-tx-cpu-efficiency, got {saved_paths}"
    assert any("primary-create-transaction-mem-efficiency.png" in p for p in saved_paths), f"Missing create-tx-mem-efficiency, got {saved_paths}"

    # Verify ablation CPU and Memory charts
    assert any("ablation-cpu-usage.png" in p for p in saved_paths), f"Missing ablation-cpu-usage, got {saved_paths}"
    assert any("ablation-memory-usage.png" in p for p in saved_paths), f"Missing ablation-memory-usage, got {saved_paths}"

