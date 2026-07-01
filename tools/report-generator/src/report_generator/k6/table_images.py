"""Render report-ready table PNGs."""
# ruff: noqa: E402

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, Future
import os

import matplotlib

matplotlib.use("Agg")

import warnings
warnings.filterwarnings("ignore", category=UserWarning, module="matplotlib.font_manager")

matplotlib.rcParams['font.family'] = 'sans-serif'
matplotlib.rcParams['font.sans-serif'] = [
    'Inter', 'Roboto', 'Helvetica Neue', 'Arial', 
    'Liberation Sans', 'DejaVu Sans', 'sans-serif'
]

from matplotlib.figure import Figure
from matplotlib.backends.backend_agg import FigureCanvasAgg
import pandas as pd

from report_generator.k6.aggregation import aggregate_attempts, rows_to_frame
from report_generator.k6.models import AttemptMode, NormalizedRow

THEME = {
    "page": "#FFFFFF",
    "card": "#FFFFFF",
    "card_edge": "#E5E7EB",
    "header": "#F3F4F6",
    "header_text": "#111827",
    "row_a": "#FFFFFF",
    "row_b": "#F9FAFB",
    "edge": "#E5E7EB",
    "text": "#111827",
    "muted": "#4B5563",
    "axis": "#E5E7EB",
}

OUTPUT_DPI = 320


def submit_report_table_images(
    executor: ProcessPoolExecutor,
    rows: list[NormalizedRow],
    table_images_dir: Path,
    attempt_mode: AttemptMode,
) -> list[Future[Path]]:
    table_images_dir.mkdir(parents=True, exist_ok=True)
    frame = aggregate_attempts(rows_to_frame(rows), attempt_mode)

    futures = []
    for (scaling_mode, scenario), group in frame.groupby(["scaling_mode", "scenario"]):
        throughput_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput-table.png"
        )
        successful_throughput_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-successful-throughput-table.png"
        )
        achievement_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput-achievement-table.png"
        )
        latency_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-p95-latency-table.png"
        )
        error_rate_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-error-rate-table.png"
        )
        dropped_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-dropped-iterations-table.png"
        )
        achieved_rps_path = (
            table_images_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-achieved-rps-table.png"
        )

        throughput_table = _metric_table(
            group=group,
            metric_column="actual_throughput",
            metric_label_map={
                "monolith": "Monolith\n(req/s)",
                "microservices": "Microservices\n(req/s)",
            },
            formatter=lambda value: f"{value:,.2f}",
        )
        latency_table = _metric_table(
            group=group,
            metric_column="p95_latency_ms",
            metric_label_map={
                "monolith": "Monolith\n(ms)",
                "microservices": "Microservices\n(ms)",
            },
            formatter=lambda value: f"{value:,.2f}",
        )
        successful_throughput_table = _metric_table(
            group=group,
            metric_column="successful_throughput",
            metric_label_map={
                "monolith": "Monolith\n(success req/s)",
                "microservices": "Microservices\n(success req/s)",
            },
            formatter=lambda value: f"{value:,.2f}",
        )
        achievement_table = _metric_table(
            group=group,
            metric_column="throughput_achievement_pct",
            metric_label_map={
                "monolith": "Monolith\n(%)",
                "microservices": "Microservices\n(%)",
            },
            formatter=lambda value: f"{value:,.2f}",
        )
        error_rate_table = _metric_table(
            group=group,
            metric_column="error_rate",
            metric_label_map={
                "monolith": "Monolith\n(%)",
                "microservices": "Microservices\n(%)",
            },
            formatter=lambda value: f"{value:.2%}",
        )
        dropped_table = _metric_table(
            group=group,
            metric_column="dropped_iterations",
            metric_label_map={
                "monolith": "Monolith",
                "microservices": "Microservices",
            },
            formatter=lambda value: f"{value:,.0f}",
        )

        futures.append(
            executor.submit(
                _render_table_png,
                table=throughput_table,
                title="Throughput Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=throughput_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=successful_throughput_table,
                title="Successful Throughput Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=successful_throughput_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=achievement_table,
                title="Throughput Achievement by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=achievement_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=latency_table,
                title="P95 Latency Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=latency_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=error_rate_table,
                title="Error Rate Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=error_rate_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=dropped_table,
                title="Dropped Iterations Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=dropped_path,
            )
        )
        futures.append(
            executor.submit(
                _render_table_png,
                table=successful_throughput_table,
                title="Achieved RPS vs Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=achieved_rps_path,
            )
        )

    return futures


def write_report_table_images(
    rows: list[NormalizedRow], table_images_dir: Path, attempt_mode: AttemptMode
) -> list[Path]:
    max_workers = min(os.cpu_count() or 1, 8)
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = submit_report_table_images(executor, rows, table_images_dir, attempt_mode)
        created = [task.result() for task in futures]
    return created


def _metric_table(
    group: pd.DataFrame,
    metric_column: str,
    metric_label_map: dict[str, str],
    formatter: Callable[[float], str],
) -> pd.DataFrame:
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
        .rename_axis(index="Target\nRPS")
        .reset_index()
    )

    for column in pivot.columns:
        if column != "Target\nRPS":
            pivot[column] = pivot[column].map(formatter)
    return pivot


def _render_table_png(
    table: pd.DataFrame,
    title: str,
    subtitle: str,
    output_path: Path,
) -> Path:
    row_count = max(len(table), 1)
    fig_height = 2.65 + (row_count * 0.46)
    fig_width = max(8.2, 2.7 + (len(table.columns) * 2.05))
    fig = Figure(figsize=(fig_width, fig_height), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.axis("off")
    ax.set_facecolor(THEME["card"])

    # Explicitly set the margins of the axes area
    fig.subplots_adjust(left=0.10, right=0.90, bottom=0.10, top=0.75)

    fig.text(
        0.10,
        0.88,
        title,
        ha="left",
        va="top",
        fontsize=14.5,
        fontweight="semibold",
        color=THEME["text"],
    )
    fig.text(
        0.10,
        0.81,
        subtitle,
        ha="left",
        va="top",
        fontsize=9.2,
        color=THEME["muted"],
    )

    from matplotlib.path import Path as MPath
    from matplotlib.patches import PathPatch

    r = 0.02
    verts = [
        (0, r),
        (0, 1 - r),
        (0, 1), (r, 1),
        (1 - r, 1),
        (1, 1), (1, 1 - r),
        (1, r),
        (1, 0), (1 - r, 0),
        (r, 0),
        (0, 0), (0, r),
        (0, r)
    ]
    codes = [
        MPath.MOVETO,
        MPath.LINETO,
        MPath.CURVE3, MPath.CURVE3,
        MPath.LINETO,
        MPath.CURVE3, MPath.CURVE3,
        MPath.LINETO,
        MPath.CURVE3, MPath.CURVE3,
        MPath.LINETO,
        MPath.CURVE3, MPath.CURVE3,
        MPath.CLOSEPOLY
    ]
    clip_path = MPath(verts, codes)

    mpl_table = ax.table(
        cellText=table.astype(str).values,
        colLabels=list(table.columns),
        cellLoc="center",
        colLoc="center",
        bbox=[0.0, 0.0, 1.0, 1.0],
    )
    mpl_table.auto_set_font_size(False)
    mpl_table.set_fontsize(9.4)
    mpl_table.scale(1, 1.25)

    header_color = THEME["header"]
    header_text_color = THEME["header_text"]
    row_colors = (THEME["row_a"], THEME["row_b"])
    edge_color = THEME["edge"]

    MONOLITH_COLOR = "#3274D9"
    MICROSERVICES_COLOR = "#FF780A"

    for (row_index, col_index), cell in mpl_table.get_celld().items():
        cell.set_edgecolor(edge_color)
        cell.set_linewidth(0.7)
        cell.set_clip_path(clip_path, ax.transAxes)
        cell.set_clip_on(True)

        if row_index == 0:
            cell.set_facecolor(header_color)
            col_name = table.columns[col_index]
            if "monolith" in col_name.lower():
                cell.set_text_props(color=MONOLITH_COLOR, weight="semibold")
            elif "microservices" in col_name.lower():
                cell.set_text_props(color=MICROSERVICES_COLOR, weight="semibold")
            else:
                cell.set_text_props(color=header_text_color, weight="semibold")
            cell.set_height(cell.get_height() * 1.25)
            continue

        cell.set_facecolor(row_colors[(row_index - 1) % 2])
        if col_index == 0:
            cell.set_text_props(color=THEME["text"], weight="semibold")
        else:
            cell.set_text_props(color=THEME["text"])

    rect = PathPatch(
        clip_path,
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
    )
    ax.add_patch(rect)

    fig.savefig(
        output_path,
        format="png",
        facecolor=fig.get_facecolor(),
    )
    return output_path


def _build_subtitle(scenario: str, scaling_mode: str, attempt_mode: AttemptMode) -> str:
    return f"Scenario: {scenario} | Scaling mode: {scaling_mode} | Attempt mode: {attempt_mode}"
