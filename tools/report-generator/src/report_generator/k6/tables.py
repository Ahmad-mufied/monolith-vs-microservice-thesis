"""Report table generation."""

from __future__ import annotations

from pathlib import Path

import pandas as pd

from report_generator.k6.aggregation import aggregate_attempts, rows_to_frame
from report_generator.k6.models import AttemptMode
from report_generator.k6.models import NormalizedRow


def write_report_tables(
    rows: list[NormalizedRow], tables_dir: Path, attempt_mode: AttemptMode
) -> list[Path]:
    tables_dir.mkdir(parents=True, exist_ok=True)
    created: list[Path] = []
    frame = aggregate_attempts(rows_to_frame(rows), attempt_mode)

    for (scaling_mode, scenario), group in frame.groupby(["scaling_mode", "scenario"]):
        throughput_path = (
            tables_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput.csv"
        )
        successful_throughput_path = (
            tables_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-successful-throughput.csv"
        )
        achievement_path = (
            tables_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput-achievement.csv"
        )
        latency_path = (
            tables_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-p95-latency.csv"
        )
        error_rate_path = (
            tables_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-error-rate.csv"
        )
        dropped_path = (
            tables_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-dropped-iterations.csv"
        )

        _write_metric_table(
            group=group,
            metric_column="actual_throughput",
            metric_label_map={
                "monolith": "Monolith (req/s)",
                "microservices": "Microservices (req/s)",
            },
            output_path=throughput_path,
        )
        _write_metric_table(
            group=group,
            metric_column="successful_throughput",
            metric_label_map={
                "monolith": "Monolith (successful req/s)",
                "microservices": "Microservices (successful req/s)",
            },
            output_path=successful_throughput_path,
        )
        _write_metric_table(
            group=group,
            metric_column="throughput_achievement_pct",
            metric_label_map={
                "monolith": "Monolith (%)",
                "microservices": "Microservices (%)",
            },
            output_path=achievement_path,
        )
        _write_metric_table(
            group=group,
            metric_column="p95_latency_ms",
            metric_label_map={
                "monolith": "Monolith (ms)",
                "microservices": "Microservices (ms)",
            },
            output_path=latency_path,
        )
        _write_metric_table(
            group=group,
            metric_column="error_rate",
            metric_label_map={
                "monolith": "Monolith (%)",
                "microservices": "Microservices (%)",
            },
            output_path=error_rate_path,
            formatter=lambda value: value * 100,
        )
        _write_metric_table(
            group=group,
            metric_column="dropped_iterations",
            metric_label_map={
                "monolith": "Monolith",
                "microservices": "Microservices",
            },
            output_path=dropped_path,
        )
        created.extend(
            [
                throughput_path,
                successful_throughput_path,
                achievement_path,
                latency_path,
                error_rate_path,
                dropped_path,
            ]
        )

    return created


def _write_metric_table(
    group: pd.DataFrame,
    metric_column: str,
    metric_label_map: dict[str, str],
    output_path: Path,
    formatter: object | None = None,
) -> None:
    ordered_architectures = [
        architecture
        for architecture in ("monolith", "microservices")
        if architecture in set(group["architecture"].tolist())
    ]
    pivot = (
        group.pivot_table(
            index="target_rps",
            columns="architecture",
            values=metric_column,
            aggfunc="first",
        )
        .sort_index()
        .reindex(columns=ordered_architectures)
        .rename(columns=metric_label_map)
        .rename_axis(index="Target RPS")
        .reset_index()
    )
    if formatter is not None:
        for column in pivot.columns:
            if column != "Target RPS":
                pivot[column] = pivot[column].map(formatter)
    pivot.to_csv(output_path, index=False)
