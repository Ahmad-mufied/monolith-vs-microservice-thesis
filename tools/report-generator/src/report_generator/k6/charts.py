"""Chart generation for report-ready PNG outputs."""
# ruff: noqa: E402

from __future__ import annotations

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
from matplotlib.axes import Axes
import numpy as np
import pandas as pd
from matplotlib.ticker import MaxNLocator
from matplotlib.patches import FancyBboxPatch
from scipy.interpolate import PchipInterpolator

from report_generator.k6.aggregation import aggregate_attempts, rows_to_frame
from report_generator.k6.models import AttemptMode
from report_generator.k6.models import NormalizedRow
from report_generator.styles import smooth_series

ARCHITECTURE_STYLE = {
    "monolith": {
        "label": "Monolith",
        "color": "#3274D9",  # Grafana-style vibrant blue
        "linestyle": "solid",
        "marker": "o",
        "zorder": 3,
    },
    "microservices": {
        "label": "Microservices",
        "color": "#FF780A",  # Grafana-style vibrant orange
        "linestyle": (0, (5, 3)),  # Clean modern dashed line
        "marker": "s",
        "zorder": 4,
    },
}

THEME = {
    "page": "#FFFFFF",
    "card": "#FFFFFF",
    "card_edge": "#E5E7EB",
    "shadow": "#FFFFFF",
    "grid": "#F3F4F6",      # Very light grid lines for Grafana look
    "text": "#111827",
    "muted": "#4B5563",
    "axis": "#E5E7EB",      # Very thin light border color
    "legend_bg": "#FFFFFF",
    "legend_text": "#111827",
}

OUTPUT_DPI = 320
SCENARIO_MARKERS = {
    "login": {"label": "Login", "marker": "o"},
    "create-transaction": {"label": "Create Transaction", "marker": "s"},
    "enriched-transactions": {"label": "Enriched Transactions", "marker": "^"},
    "sync-items": {"label": "Sync Items", "marker": "D"},
}
SCATTER_SCENARIOS = tuple(SCENARIO_MARKERS.keys())


def submit_report_charts(
    executor: ProcessPoolExecutor,
    rows: list[NormalizedRow],
    charts_dir: Path,
    attempt_mode: AttemptMode,
) -> list[Future[Path]]:
    charts_dir.mkdir(parents=True, exist_ok=True)
    raw_frame = rows_to_frame(rows)
    frame = aggregate_attempts(raw_frame, attempt_mode)

    futures: list[Future[Path]] = []

    for (scaling_mode, scenario), group in frame.groupby(["scaling_mode", "scenario"]):
        throughput_path = (
            charts_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput.png"
        )
        successful_throughput_path = (
            charts_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-successful-throughput.png"
        )
        achievement_path = (
            charts_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-throughput-achievement.png"
        )
        latency_path = (
            charts_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-p95-latency.png"
        )
        error_rate_path = (
            charts_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-error-rate.png"
        )
        dropped_path = (
            charts_dir
            / f"{scaling_mode}-{scenario}-{attempt_mode}-dropped-iterations.png"
        )
        achieved_rps_path = (
            charts_dir / f"{scaling_mode}-{scenario}-{attempt_mode}-achieved-rps.png"
        )

        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="actual_throughput",
                y_label="Throughput (req/s)",
                title="Throughput Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=throughput_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="successful_throughput",
                y_label="Successful throughput (req/s)",
                title="Successful Throughput Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=successful_throughput_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="throughput_achievement_pct",
                y_label="Throughput achievement (%)",
                title="Throughput Achievement by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=achievement_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="p95_latency_ms",
                y_label="P95 latency (ms)",
                title="P95 Latency Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=latency_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="error_rate",
                y_label="Error rate",
                title="Error Rate Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=error_rate_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_metric,
                group=group,
                metric_column="dropped_iterations",
                y_label="Dropped iterations",
                title="Dropped Iterations Comparison by Target RPS",
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
                output_path=dropped_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_achieved_vs_target_rps,
                group=group,
                output_path=achieved_rps_path,
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
            )
        )
        futures.append(
            executor.submit(
                _plot_http_status_stacked_bar,
                group=group,
                output_path=(
                    charts_dir
                    / f"{scaling_mode}-{scenario}-{attempt_mode}-http-status-breakdown.png"
                ),
                subtitle=_build_subtitle(scenario, scaling_mode, attempt_mode),
            )
        )

    futures.extend(_submit_scaling_change_scatter_charts(executor, frame, charts_dir, attempt_mode))
    futures.extend(_submit_absolute_scatter_charts(executor, frame, charts_dir, attempt_mode))
    futures.extend(_submit_attempt_comparison_charts(executor, raw_frame, charts_dir))

    return futures


def write_report_charts(
    rows: list[NormalizedRow], charts_dir: Path, attempt_mode: AttemptMode
) -> list[Path]:
    max_workers = min(os.cpu_count() or 1, 8)
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        futures = submit_report_charts(executor, rows, charts_dir, attempt_mode)
        created = [future.result() for future in futures]
    return created


def _plot_metric(
    group: pd.DataFrame,
    metric_column: str,
    y_label: str,
    title: str,
    subtitle: str,
    output_path: Path,
) -> Path:
    fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])

    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)
    x_targets = np.sort(group["target_rps"].dropna().unique().astype(float))

    for architecture, arch_group in sorted(group.groupby("architecture")):
        style = ARCHITECTURE_STYLE.get(
            architecture,
            {"label": architecture.title(), "color": "#6b7280"},
        )
        ordered = arch_group.sort_values("target_rps")
        x_values = ordered["target_rps"].to_numpy(dtype=float)
        y_values = ordered[metric_column].to_numpy(dtype=float)

        smooth_x, smooth_y = smooth_series(x_values, y_values)
        ax.plot(
            smooth_x,
            smooth_y,
            label=style["label"],
            color=style["color"],
            linewidth=2.5,
            linestyle=style.get("linestyle", "solid"),
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=style.get("zorder", 3),
        )
        ax.fill_between(
            smooth_x,
            smooth_y,
            color=style["color"],
            alpha=0.08,
            zorder=1,
        )
        ax.plot(
            x_values,
            y_values,
            linestyle="none",
            color=style["color"],
            marker=style.get("marker", "o"),
            markersize=6.0,
            markeredgewidth=1.5,
            markeredgecolor="#FFFFFF",
            zorder=style.get("zorder", 3) + 0.1,
        )

    fig.text(
        0.22,
        0.89,
        title,
        ha="left",
        va="top",
        fontsize=15,
        fontweight="semibold",
        color=THEME["text"],
    )
    fig.text(
        0.22,
        0.84,
        subtitle,
        ha="left",
        va="top",
        fontsize=9.5,
        color=THEME["muted"],
    )
    ax.set_xlabel("Target RPS", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.set_ylabel(y_label, fontsize=11, color=THEME["muted"], labelpad=10)
    ax.ticklabel_format(style="plain", axis="both")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
    
    # Hide standard spines to draw rounded border patch
    for spine in ax.spines.values():
        spine.set_visible(False)

    # Rounded outer border around the plot axes area
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.02",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)

    _apply_target_rps_axis(ax, x_targets)
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.56, 0.11),
        bbox_transform=fig.transFigure,
        ncol=2,
        frameon=False,
        fontsize=9.5,
        handlelength=1.8,
        columnspacing=1.5,
        handletextpad=0.5,
        labelcolor=THEME["legend_text"],
    )

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path


def _apply_target_rps_axis(ax: Axes, x_targets: np.ndarray) -> None:
    if len(x_targets) == 0:
        return

    min_target = float(x_targets.min())
    max_target = float(x_targets.max())
    if min_target == max_target:
        padding = max(10.0, min_target * 0.1)
    else:
        padding = max(5.0, (max_target - min_target) * 0.04)

    ax.set_xlim(min_target - padding, max_target + padding)
    if len(x_targets) <= 12:
        ax.set_xticks(x_targets)
    else:
        ax.xaxis.set_major_locator(MaxNLocator(nbins=8, integer=True))



def _plot_achieved_vs_target_rps(
    group: pd.DataFrame,
    output_path: Path,
    subtitle: str,
) -> Path:
    fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])

    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)

    x_targets = np.sort(group["target_rps"].dropna().unique().astype(float))

    all_values = np.concatenate([
        x_values
        for _, arch_group in group.groupby("architecture")
        for x_values in [arch_group["target_rps"].to_numpy(dtype=float)]
    ])
    all_achieved = np.concatenate([
        y_values
        for _, arch_group in group.groupby("architecture")
        for y_values in [arch_group["actual_throughput"].to_numpy(dtype=float)]
    ])

    if len(all_values) > 0:
        ref_min = float(min(all_values.min(), all_achieved.min()))
        ref_max = float(max(all_values.max(), all_achieved.max()))
        padding = max(5.0, (ref_max - ref_min) * 0.04)
        ax.plot(
            [ref_min - padding, ref_max + padding],
            [ref_min - padding, ref_max + padding],
            color=THEME["muted"],
            linewidth=1.1,
            linestyle=(0, (6, 4)),
            alpha=0.6,
            zorder=1,
            label="Ideal (achieved = target)",
        )

    for architecture, arch_group in sorted(group.groupby("architecture")):
        style = ARCHITECTURE_STYLE.get(
            architecture,
            {"label": architecture.title(), "color": "#6b7280"},
        )
        ordered = arch_group.sort_values("target_rps")
        x_values = ordered["target_rps"].to_numpy(dtype=float)
        y_values = ordered["actual_throughput"].to_numpy(dtype=float)

        smooth_x, smooth_y = smooth_series(x_values, y_values)
        ax.plot(
            smooth_x,
            smooth_y,
            label=style["label"],
            color=style["color"],
            linewidth=2.5,
            linestyle=style.get("linestyle", "solid"),
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=style.get("zorder", 3),
        )
        ax.fill_between(
            smooth_x,
            smooth_y,
            color=style["color"],
            alpha=0.08,
            zorder=1,
        )
        ax.plot(
            x_values,
            y_values,
            linestyle="none",
            color=style["color"],
            marker=style.get("marker", "o"),
            markersize=6.0,
            markeredgewidth=1.5,
            markeredgecolor="#FFFFFF",
            zorder=style.get("zorder", 3) + 0.1,
        )

    fig.text(
        0.22,
        0.89,
        "Achieved RPS vs Target RPS",
        ha="left",
        va="top",
        fontsize=15,
        fontweight="semibold",
        color=THEME["text"],
    )
    fig.text(
        0.22,
        0.84,
        subtitle,
        ha="left",
        va="top",
        fontsize=9.5,
        color=THEME["muted"],
    )
    ax.set_xlabel("Target RPS", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.set_ylabel("Achieved RPS", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.ticklabel_format(style="plain", axis="both")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
    
    # Hide standard spines to draw rounded border patch
    for spine in ax.spines.values():
        spine.set_visible(False)

    # Rounded outer border around the plot axes area
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.02",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)

    _apply_target_rps_axis(ax, x_targets)
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.56, 0.11),
        bbox_transform=fig.transFigure,
        ncol=3,
        frameon=False,
        fontsize=9.5,
        handlelength=1.8,
        columnspacing=1.5,
        handletextpad=0.5,
        labelcolor=THEME["legend_text"],
    )

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path


def _build_subtitle(scenario: str, scaling_mode: str, attempt_mode: AttemptMode) -> str:
    return f"Scenario: {scenario} | Scaling mode: {scaling_mode} | Attempt mode: {attempt_mode}"


def _submit_scaling_change_scatter_charts(
    executor: ProcessPoolExecutor, frame: pd.DataFrame, charts_dir: Path, attempt_mode: AttemptMode
) -> list[Future[Path]]:
    if frame.empty:
        return []

    if not {"fixed", "hpa"}.issubset(set(frame["scaling_mode"].unique())):
        return []

    filtered = frame[frame["scenario"].isin(SCATTER_SCENARIOS)].copy()
    if filtered.empty:
        return []

    comparison = _build_scaling_change_frame(filtered)
    if comparison.empty:
        return []

    throughput_path = (
        charts_dir / f"fixed-vs-hpa-{attempt_mode}-throughput-change-scatter.png"
    )
    latency_path = (
        charts_dir / f"fixed-vs-hpa-{attempt_mode}-p95-latency-change-scatter.png"
    )

    f1 = executor.submit(
        _plot_multivariable_scatter,
        df=comparison,
        metric_column="throughput_change_pct",
        title="Throughput Change from Fixed to HPA",
        subtitle=f"Attempt mode: {attempt_mode} | Colors show architecture | Markers show scenario",
        y_label="Change in throughput (%)",
        output_path=throughput_path,
        draw_ref_line=True,
    )
    f2 = executor.submit(
        _plot_multivariable_scatter,
        df=comparison,
        metric_column="latency_change_pct",
        title="P95 Latency Change from Fixed to HPA",
        subtitle=f"Attempt mode: {attempt_mode} | Colors show architecture | Markers show scenario",
        y_label="Change in P95 latency (%)",
        output_path=latency_path,
        draw_ref_line=True,
    )

    return [f1, f2]


def _submit_absolute_scatter_charts(
    executor: ProcessPoolExecutor, frame: pd.DataFrame, charts_dir: Path, attempt_mode: AttemptMode
) -> list[Future[Path]]:
    if frame.empty:
        return []

    filtered = frame[frame["scenario"].isin(SCATTER_SCENARIOS)].copy()
    if filtered.empty:
        return []

    present_scenarios = filtered["scenario"].unique()
    if len(present_scenarios) < 2:
        return []

    rps_sets = [
        set(filtered[filtered["scenario"] == s]["target_rps"].unique())
        for s in present_scenarios
    ]
    common_rps = sorted(set.intersection(*rps_sets))
    if not common_rps:
        return []

    filtered = filtered[filtered["target_rps"].isin(common_rps)].copy()

    futures = []
    for scaling_mode, group in filtered.groupby("scaling_mode"):
        throughput_path = (
            charts_dir / f"{scaling_mode}-{attempt_mode}-throughput-absolute-scatter.png"
        )
        latency_path = (
            charts_dir / f"{scaling_mode}-{attempt_mode}-p95-latency-absolute-scatter.png"
        )

        futures.append(
            executor.submit(
                _plot_multivariable_scatter,
                df=group,
                metric_column="actual_throughput",
                title=f"Throughput Absolute Comparison ({scaling_mode.upper()})",
                subtitle=f"Attempt mode: {attempt_mode} | Colors show architecture | Markers show scenario",
                y_label="Throughput (req/s)",
                output_path=throughput_path,
                draw_ref_line=False,
            )
        )

        futures.append(
            executor.submit(
                _plot_multivariable_scatter,
                df=group,
                metric_column="p95_latency_ms",
                title=f"P95 Latency Absolute Comparison ({scaling_mode.upper()})",
                subtitle=f"Attempt mode: {attempt_mode} | Colors show architecture | Markers show scenario",
                y_label="P95 Latency (ms)",
                output_path=latency_path,
                draw_ref_line=False,
            )
        )

        # Dropped iterations: show saturation point where k6 can no longer maintain arrival rate
        futures.append(
            executor.submit(
                _plot_multivariable_scatter,
                df=group,
                metric_column="dropped_iterations",
                title=f"Dropped Iterations Comparison ({scaling_mode.upper()})",
                subtitle=(
                    f"Attempt mode: {attempt_mode} "
                    f"| Colors show architecture | Markers show scenario"
                ),
                y_label="Dropped Iterations",
                output_path=(
                    charts_dir
                    / f"{scaling_mode}-{attempt_mode}-dropped-iterations-absolute-scatter.png"
                ),
                draw_ref_line=False,
            )
        )

    return futures


def _build_scaling_change_frame(frame: pd.DataFrame) -> pd.DataFrame:
    fixed = (
        frame[frame["scaling_mode"] == "fixed"]
        .rename(
            columns={
                "actual_throughput": "fixed_actual_throughput",
                "p95_latency_ms": "fixed_p95_latency_ms",
            }
        )
        .drop(columns=["scaling_mode"])
    )
    hpa = (
        frame[frame["scaling_mode"] == "hpa"]
        .rename(
            columns={
                "actual_throughput": "hpa_actual_throughput",
                "p95_latency_ms": "hpa_p95_latency_ms",
            }
        )
        .drop(columns=["scaling_mode"])
    )

    comparison = fixed.merge(
        hpa,
        on=["scenario", "target_rps", "architecture"],
        how="inner",
        suffixes=("_fixed", "_hpa"),
    )
    if comparison.empty:
        return comparison

    comparison["throughput_change_pct"] = (
        (comparison["hpa_actual_throughput"] - comparison["fixed_actual_throughput"])
        / comparison["fixed_actual_throughput"]
    ).replace([np.inf, -np.inf], np.nan) * 100.0
    comparison["latency_change_pct"] = (
        (comparison["hpa_p95_latency_ms"] - comparison["fixed_p95_latency_ms"])
        / comparison["fixed_p95_latency_ms"]
    ).replace([np.inf, -np.inf], np.nan) * 100.0
    return comparison.sort_values(["target_rps", "scenario", "architecture"]).reset_index(drop=True)


def _plot_multivariable_scatter(
    df: pd.DataFrame,
    metric_column: str,
    title: str,
    subtitle: str,
    y_label: str,
    output_path: Path,
    draw_ref_line: bool = False,
) -> Path:
    from matplotlib.lines import Line2D

    # ── Determine which architectures and scenarios are present ──────────────
    valid_df = df[df[metric_column].notna()]
    present_architectures = [
        k for k in ARCHITECTURE_STYLE if k in set(valid_df["architecture"].unique())
    ]
    present_scenarios = [
        k for k in SCENARIO_MARKERS if k in set(valid_df["scenario"].unique())
    ]

    fig = Figure(figsize=(11, 6.5), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])

    # Margins leaves room for the in-chart legend
    fig.subplots_adjust(left=0.22, right=0.80, bottom=0.20, top=0.76)
    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")

    if draw_ref_line:
        ax.axhline(0, color=THEME["muted"], linewidth=1.1, linestyle=(0, (4, 4)), zorder=1)

    target_levels = sorted(df["target_rps"].dropna().unique().astype(int))
    x_positions = {target_rps: float(index) for index, target_rps in enumerate(target_levels)}
    architecture_offsets = {
        "monolith": -0.12,
        "microservices": 0.12,
    }
    scenario_offsets = {
        "login": -0.06,
        "create-transaction": -0.02,
        "enriched-transactions": 0.02,
        "sync-items": 0.06,
    }

    for _, row in df.iterrows():
        architecture = row["architecture"]
        scenario = row["scenario"]
        if scenario not in SCENARIO_MARKERS:
            continue
        style = ARCHITECTURE_STYLE[architecture]
        marker_style = SCENARIO_MARKERS[scenario]
        base_x = x_positions[int(row["target_rps"])]
        x_value = (
            base_x
            + architecture_offsets.get(architecture, 0.0)
            + scenario_offsets.get(scenario, 0.0)
        )

        ax.scatter(
            [x_value],
            [float(row[metric_column])],
            s=72,
            marker=marker_style["marker"],
            facecolor=style["color"],
            edgecolor="#FFFFFF",
            linewidth=1.5,
            alpha=0.96,
            zorder=3,
        )

    fig.text(
        0.22,
        0.89,
        title,
        ha="left",
        va="top",
        fontsize=15,
        fontweight="semibold",
        color=THEME["text"],
    )
    fig.text(
        0.22,
        0.84,
        subtitle,
        ha="left",
        va="top",
        fontsize=9.5,
        color=THEME["muted"],
    )

    ax.set_xlabel("Target RPS", fontsize=11, color=THEME["muted"], labelpad=8)
    ax.set_ylabel(y_label, fontsize=11, color=THEME["muted"], labelpad=10)
    ax.ticklabel_format(style="plain", axis="y")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
    
    # Hide standard spines to draw rounded border patch
    for spine in ax.spines.values():
        spine.set_visible(False)

    # Rounded outer border around the plot axes area
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.02",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)

    ax.set_xticks([x_positions[level] for level in target_levels])
    ax.set_xticklabels([str(level) for level in target_levels])
    ax.set_xlim(-0.5, len(target_levels) - 0.5)

    # ── IEEE-style in-chart legend (right side, two sections) ────────────────
    legend_handles: list[Line2D] = []

    if present_architectures:
        legend_handles.append(
            Line2D([], [], linestyle="none", marker="none", label="Architecture")
        )
        for arch_key in present_architectures:
            s = ARCHITECTURE_STYLE[arch_key]
            legend_handles.append(
                Line2D(
                    [0], [0],
                    linestyle="none",
                    marker="o",
                    markerfacecolor=s["color"],
                    markeredgewidth=0,
                    markersize=7,
                    label=s["label"],
                )
            )

    if present_scenarios:
        if present_architectures:
            legend_handles.append(
                Line2D([], [], linestyle="none", marker="none", label=" ")
            )
        legend_handles.append(
            Line2D([], [], linestyle="none", marker="none", label="Scenario")
        )
        for scen_key in present_scenarios:
            m = SCENARIO_MARKERS[scen_key]
            legend_handles.append(
                Line2D(
                    [0], [0],
                    linestyle="none",
                    marker=m["marker"],
                    markerfacecolor=THEME["muted"],
                    markeredgewidth=0,
                    markersize=7,
                    label=m["label"],
                )
            )

    if legend_handles:
        leg = ax.legend(
            handles=legend_handles,
            loc="center left",
            bbox_to_anchor=(1.02, 0.5),
            frameon=False,
            fontsize=9.5,
            handletextpad=0.6,
            borderpad=0.7,
            labelspacing=0.5,
            handlelength=0,
        )

        # Style section headers bold, items normal
        section_labels = {"Architecture", "Scenario", " "}
        for text_obj in leg.get_texts():
            label = text_obj.get_text()
            if label in section_labels:
                text_obj.set_fontweight("bold")
                text_obj.set_color(THEME["text"])
            else:
                text_obj.set_color(THEME["legend_text"])

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path


def _submit_attempt_comparison_charts(
    executor: ProcessPoolExecutor, raw_frame: pd.DataFrame, charts_dir: Path
) -> list[Future[Path]]:
    futures = []
    
    # We only generate these charts if there are actually multiple attempts for any configuration
    attempt_counts = raw_frame.groupby(["scaling_mode", "scenario", "target_rps", "architecture"])["attempt"].nunique()
    if not (attempt_counts > 1).any():
        return futures

    # Group by scaling_mode, scenario, target_rps
    for (scaling_mode, scenario, target_rps), group in raw_frame.groupby(["scaling_mode", "scenario", "target_rps"]):
        unique_attempts = sorted(group["attempt"].dropna().unique())
        if len(unique_attempts) <= 1:
            continue
            
        latency_path = charts_dir / f"{scaling_mode}-{scenario}-{int(target_rps)}rps-attempts-latency.png"
        throughput_path = charts_dir / f"{scaling_mode}-{scenario}-{int(target_rps)}rps-attempts-throughput.png"
        
        futures.append(
            executor.submit(
                _plot_attempt_scatter,
                group=group,
                metric_column="p95_latency_ms",
                y_label="P95 latency (ms)",
                title="Latency Comparison by Attempt",
                facet_label=f"{scenario.title()} - {int(target_rps)} RPS ({scaling_mode.upper()})",
                attempts=unique_attempts,
                output_path=latency_path,
            )
        )
        futures.append(
            executor.submit(
                _plot_attempt_scatter,
                group=group,
                metric_column="actual_throughput",
                y_label="Throughput (req/s)",
                title="Throughput Comparison by Attempt",
                facet_label=f"{scenario.title()} - {int(target_rps)} RPS ({scaling_mode.upper()})",
                attempts=unique_attempts,
                output_path=throughput_path,
            )
        )
        
    return futures


def _plot_attempt_scatter(
    group: pd.DataFrame,
    metric_column: str,
    y_label: str,
    title: str,
    facet_label: str,
    attempts: list[str],
    output_path: Path,
) -> Path:
    fig = Figure(figsize=(8, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])

    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.24, top=0.76)

    # Plot points for each architecture
    for architecture, arch_group in sorted(group.groupby("architecture")):
        style = ARCHITECTURE_STYLE.get(
            architecture,
            {"label": architecture.title(), "color": "#6b7280"},
        )
        
        # Sort by attempt to match x-axis ticks
        ordered = arch_group.sort_values("attempt")
        x_values = ordered["attempt"].to_list()
        y_values = ordered[metric_column].to_numpy(dtype=float)
        
        # Map x_values to tick indices
        x_indices = [attempts.index(att) for att in x_values]
        
        ax.scatter(
            x_indices,
            y_values,
            s=120,
            color=style["color"],
            marker="o",
            edgecolor="#FFFFFF",
            linewidth=1.5,
            alpha=0.96,
            zorder=3,
            label=style["label"],
        )

    # Title & Subtitle at the top (with larger padding)
    fig.text(
        0.22,
        0.89,
        title,
        ha="left",
        va="top",
        fontsize=14,
        fontweight="semibold",
        color=THEME["text"],
    )
    
    # Facet strip title block above the plot
    ax.set_title(
        facet_label,
        fontsize=10,
        fontweight="semibold",
        color=THEME["muted"],
        pad=12,
        bbox=dict(
            boxstyle="square,pad=0.3",
            facecolor="#F3F4F6",
            edgecolor=THEME["axis"],
            linewidth=1.0,
        )
    )

    ax.set_xlabel("Attempt", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.set_ylabel(y_label, fontsize=11, color=THEME["muted"], labelpad=10)
    
    ax.set_xticks(range(len(attempts)))
    ax.set_xticklabels(attempts, rotation=15, ha="right")
    ax.set_xlim(-0.5, len(attempts) - 0.5)
    
    ax.ticklabel_format(style="plain", axis="y")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
    
    # Hide standard spines to draw rounded border patch
    for spine in ax.spines.values():
        spine.set_visible(False)

    # Rounded outer border around the plot axes area
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.02",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)
    # Legend at the bottom center
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.56, 0.11),
        bbox_transform=fig.transFigure,
        ncol=2,
        frameon=False,
        fontsize=9.5,
        handlelength=1.2,
        columnspacing=1.5,
        handletextpad=0.5,
        labelcolor=THEME["legend_text"],
    )

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path

def _plot_http_status_stacked_bar(
    group: pd.DataFrame,
    output_path: Path,
    subtitle: str,
) -> Path:
    """Grouped + stacked bar chart showing successful vs error throughput per architecture.

    Each RPS level forms one group of bars (one bar per architecture present in
    *group*). Each bar is split into two stacked segments:

    - Bottom (solid, full opacity): ``successful_throughput`` (req/s)
    - Top (hatched, reduced opacity): error throughput = ``actual_throughput - successful_throughput``

    This chart is particularly informative for the Login scenario where admission
    control returns HTTP 503, making the error segment clearly visible at high RPS
    levels and showing how goodput differs from total request volume.

    Guards:
    - Returns *output_path* unchanged (without writing a file) if *group* is empty
      or if required columns are absent.
    - Handles 1 or 2 architectures gracefully by adjusting bar positions.
    """
    if group.empty:
        return output_path

    required_cols = {"actual_throughput", "successful_throughput", "target_rps"}
    if not required_cols.issubset(group.columns):
        return output_path

    fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])
    ax.grid(True, which="major", axis="y", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)

    # Ordered target_rps levels and architectures (consistent ordering)
    target_levels = sorted(group["target_rps"].dropna().unique().astype(int))
    architectures = [
        a for a in ("monolith", "microservices") if a in group["architecture"].unique()
    ]
    n_levels = len(target_levels)
    n_archs = len(architectures)

    if n_levels == 0 or n_archs == 0:
        return output_path

    # Bar layout: split the 0.7-unit width evenly among architectures
    bar_total_width = 0.7
    bar_width = bar_total_width / n_archs
    x_base = np.arange(n_levels)

    for arch_idx, architecture in enumerate(architectures):
        style = ARCHITECTURE_STYLE.get(
            architecture, {"label": architecture.title(), "color": "#6b7280"}
        )
        arch_group = group[group["architecture"] == architecture]

        # Build per-RPS-level arrays; NaN for any missing level
        success_vals: list[float] = []
        error_vals: list[float] = []
        for level in target_levels:
            row = arch_group[arch_group["target_rps"] == level]
            if row.empty:
                success_vals.append(float("nan"))
                error_vals.append(float("nan"))
            else:
                actual = float(row["actual_throughput"].iloc[0])
                successful = float(row["successful_throughput"].iloc[0])
                success_vals.append(max(0.0, successful))
                error_vals.append(max(0.0, actual - successful))

        success_arr = np.array(success_vals)
        error_arr = np.array(error_vals)

        # X offset centers bars within each group
        offset = (arch_idx - (n_archs - 1) / 2.0) * bar_width
        x_pos = x_base + offset

        # Success segment (bottom, solid)
        ax.bar(
            x_pos,
            success_arr,
            width=bar_width * 0.88,
            color=style["color"],
            alpha=0.88,
            zorder=3,
            label=f"{style['label']} \u2014 Success",
        )
        # Error/rejected segment (top, hatched + reduced alpha)
        ax.bar(
            x_pos,
            error_arr,
            width=bar_width * 0.88,
            bottom=success_arr,
            color=style["color"],
            alpha=0.38,
            hatch="///",
            edgecolor=style["color"],
            linewidth=0.6,
            zorder=3,
            label=f"{style['label']} \u2014 Error/Rejected",
        )

    fig.text(
        0.22, 0.89,
        "Request Outcome Breakdown",
        ha="left", va="top",
        fontsize=15, fontweight="semibold",
        color=THEME["text"],
    )
    fig.text(
        0.22, 0.84,
        subtitle,
        ha="left", va="top",
        fontsize=9.5,
        color=THEME["muted"],
    )

    ax.set_xlabel("Target RPS", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.set_ylabel("Throughput (req/s)", fontsize=11, color=THEME["muted"], labelpad=10)
    ax.set_xticks(x_base)
    ax.set_xticklabels([str(lvl) for lvl in target_levels])
    ax.set_xlim(-0.5, n_levels - 0.5)
    ax.ticklabel_format(style="plain", axis="y")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)

    for spine in ax.spines.values():
        spine.set_visible(False)

    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.02",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)

    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.56, 0.11),
        bbox_transform=fig.transFigure,
        ncol=2,
        frameon=False,
        fontsize=9.5,
        handlelength=1.8,
        columnspacing=1.5,
        handletextpad=0.5,
        labelcolor=THEME["legend_text"],
    )

    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    return output_path
