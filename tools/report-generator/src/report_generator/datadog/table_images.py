"""Render Datadog resource report tables as PNG images."""
# ruff: noqa: E402

from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")

matplotlib.rcParams["font.family"] = "sans-serif"
matplotlib.rcParams["font.sans-serif"] = [
    "Inter",
    "Roboto",
    "Helvetica Neue",
    "Arial",
    "Liberation Sans",
    "DejaVu Sans",
    "sans-serif",
]

from matplotlib.backends.backend_agg import FigureCanvasAgg
from matplotlib.figure import Figure
import pandas as pd

from report_generator.datadog.metrics import AttemptMetrics
from report_generator.datadog.tables import (
    generate_efficiency_metrics_table,
    generate_msa_breakdown_table,
    generate_resource_summary_table,
)

THEME = {
    "page": "#FFFFFF",
    "header": "#F3F4F6",
    "header_text": "#111827",
    "row_a": "#FFFFFF",
    "row_b": "#F9FAFB",
    "edge": "#E5E7EB",
    "text": "#111827",
    "muted": "#4B5563",
}

OUTPUT_DPI = 320


def write_table_images(metrics_list: list[AttemptMetrics], output_dir: Path) -> list[Path]:
    """Generate PNG table images matching the CSV resource tables."""
    output_dir.mkdir(parents=True, exist_ok=True)
    tables = [
        (
            "resource-summary-table.png",
            "Resource Summary",
            generate_resource_summary_table(metrics_list),
        ),
        (
            "efficiency-metrics-table.png",
            "Resource Efficiency Metrics",
            generate_efficiency_metrics_table(metrics_list),
        ),
        (
            "msa-service-breakdown-table.png",
            "Microservices Service Breakdown",
            generate_msa_breakdown_table(metrics_list),
        ),
    ]

    created: list[Path] = []
    for filename, title, table in tables:
        if table.empty:
            continue
        created.append(_render_table_png(table, title, output_dir / filename))
    return created


def _render_table_png(table: pd.DataFrame, title: str, output_path: Path) -> Path:
    display_table = table.copy()
    for column in display_table.columns:
        display_table[column] = display_table[column].map(str)

    row_count = max(len(display_table), 1)
    column_count = max(len(display_table.columns), 1)
    fig_width = max(10.0, 1.35 * column_count)
    fig_height = min(28.0, 2.1 + (0.42 * row_count))

    fig = Figure(figsize=(fig_width, fig_height), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    fig.patch.set_facecolor(THEME["page"])
    ax = fig.add_subplot(111)
    ax.axis("off")

    fig.text(
        0.02,
        0.965,
        title,
        ha="left",
        va="top",
        fontsize=13,
        fontweight="semibold",
        color=THEME["text"],
    )

    table_artist = ax.table(
        cellText=display_table.values,
        colLabels=display_table.columns,
        loc="upper left",
        cellLoc="center",
        bbox=[0.02, 0.02, 0.96, 0.88],
    )
    table_artist.auto_set_font_size(False)
    table_artist.set_fontsize(7.2)

    for (row, _column), cell in table_artist.get_celld().items():
        cell.set_edgecolor(THEME["edge"])
        cell.set_linewidth(0.55)
        if row == 0:
            cell.set_facecolor(THEME["header"])
            cell.set_text_props(color=THEME["header_text"], weight="semibold")
        else:
            cell.set_facecolor(THEME["row_a"] if row % 2 else THEME["row_b"])
            cell.set_text_props(color=THEME["text"])

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path
