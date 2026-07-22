"""Consolidation module for compiling and plotting combined results across architectures."""

from __future__ import annotations

import logging
import warnings
from pathlib import Path
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.figure import Figure
from matplotlib.backends.backend_agg import FigureCanvasAgg
import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

from report_generator.styles import (
    THEME,
    OUTPUT_DPI,
    smooth_series,
)

logger = logging.getLogger(__name__)

try:
    import tomllib
except ImportError:
    import tomli as tomllib

REQUIRED_RUNS = {
    "mono_fixed_true",
    "msa_fixed_true",
    "msa_hpa_true",
    "mono_fixed_false",
    "msa_fixed_false",
    "msa_hpa_false",
}


def load_runs_config(config_or_path: Path | dict) -> dict[str, str]:
    """Load and validate consolidation runs from TOML config."""
    if isinstance(config_or_path, dict):
        config = config_or_path
    else:
        with open(config_or_path, "rb") as f:
            config = tomllib.load(f)

    consolidation = config.get("consolidation", {})
    runs = consolidation.get("runs", {})

    missing = REQUIRED_RUNS - set(runs.keys())
    if missing:
        raise ValueError(
            f"Missing required consolidation runs in config: {', '.join(sorted(missing))}"
        )

    return runs


def filter_composite_results(df: pd.DataFrame, arch: str, mode: str) -> pd.DataFrame:
    """Filter composite results by architecture and scaling mode columns."""
    arch_col = "architecture"
    if "Architecture" in df.columns:
        arch_col = "Architecture"
    arch_mask = df[arch_col].str.lower() == arch.lower()
    
    # Support both 'scaling_mode' and 'Scaling Mode' column names
    mode_col = "scaling_mode" if "scaling_mode" in df.columns else None
    if not mode_col and "Scaling Mode" in df.columns:
        mode_col = "Scaling Mode"

    if mode_col:
        mode_mask = df[mode_col].str.lower() == mode.lower()
    else:
        # Fallback: column absent — emit a warning so silent data contamination is visible
        warnings.warn(
            f"No scaling_mode column found in DataFrame — mode filter skipped. "
            f"Available columns: {list(df.columns)}",
            stacklevel=3,
        )
        mode_mask = pd.Series(True, index=df.index)

    return df[arch_mask & mode_mask].copy()


def resolve_data_file(run_id: str, filename: str, cache_dir: Path, s3_bucket: str) -> Path:
    """Check if the target file is present locally. If not, download from S3 and cache it."""
    local_file = Path(cache_dir) / run_id / filename
    if local_file.exists():
        return local_file

    # Also check if it's in the sibling report directory (e.g. cache_dir/../run_id/filename)
    sibling_local = Path(cache_dir).parent / run_id / filename
    if sibling_local.exists():
        return sibling_local

    # Ensure parent directory exists
    local_file.parent.mkdir(parents=True, exist_ok=True)

    # Fallback to S3 download
    s3_key = f"experiments/{run_id}/{filename}"
    config = Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 3})
    try:
        s3_client = boto3.client("s3", config=config)
        s3_client.download_file(s3_bucket, s3_key, str(local_file))
    except (BotoCoreError, ClientError) as exc:
        logger.error(f"Failed to download {s3_key} from S3 bucket {s3_bucket}: {exc}")
        if local_file.exists():
            try:
                local_file.unlink()
            except OSError:
                pass
        raise

    return local_file


def compile_consolidated_dataset(
    runs: dict[str, str],
    filename: str,
    cache_dir: Path,
    s3_bucket: str
) -> pd.DataFrame:
    """Load and compile data across multiple Run IDs using dynamic filtering."""
    data_list = []
    errors = []
    
    for run_label, run_id in runs.items():
        # Determine targets from label name
        arch = "monolith" if "mono" in run_label else "microservices"
        mode = "hpa" if "hpa" in run_label else "fixed"
        admission = True if run_label.endswith("_true") else False
        
        try:
            # Load the resolved file
            path = resolve_data_file(run_id, filename, cache_dir, s3_bucket)
            if not path.exists():
                raise FileNotFoundError(f"Data file does not exist locally: {path}")

            df = pd.read_csv(path)

            # Filter matching rows by architecture + scaling mode
            df_filtered = filter_composite_results(df, arch, mode)
            if df_filtered.empty:
                logger.warning(
                    "run_label=%r produced empty DataFrame after arch/mode filter "
                    "(arch=%r, mode=%r, file=%s) — skipping",
                    run_label, arch, mode, path,
                )
                continue

            # Annotate with run identity
            df_filtered = df_filtered.copy()
            df_filtered["run_label"] = run_label
            df_filtered["admission"] = admission

            data_list.append(df_filtered)
        except Exception as exc:
            logger.error(
                "Error processing run_label=%r (run_id=%r, file=%r): %s",
                run_label, run_id, filename, exc,
            )
            errors.append(f"{run_label}: {exc}")
            continue
        
    if not data_list:
        if errors:
            raise RuntimeError(
                "Failed to compile any consolidation runs: " + "; ".join(errors)
            )
        return pd.DataFrame()
        
    return pd.concat(data_list, ignore_index=True)


def _plot_unified_chart(
    df_subset: pd.DataFrame, 
    metric_col: str, 
    styles_dict: dict, 
    title: str, 
    y_label: str, 
    y_limits: tuple | None, 
    output_path: Path,
    ncol_legend: int = 3
):
    fig = Figure(figsize=(8.0, 5.2), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    
    # Theme configuration
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])
    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    
    # Margin adjustments to accommodate bottom legend
    fig.subplots_adjust(left=0.15, right=0.90, bottom=0.25, top=0.85)
    
    # Support both 'target_rps' and 'Target RPS'
    target_col = "target_rps" if "target_rps" in df_subset.columns else "Target RPS"
    x_targets = np.sort(df_subset[target_col].dropna().unique().astype(float))
    
    for key, style in styles_dict.items():
        subset = df_subset[df_subset['run_label'] == key].sort_values(target_col)
        if subset.empty:
            continue
            
        x_values = subset[target_col].to_numpy(dtype=float)
        y_values = subset[metric_col].to_numpy(dtype=float)
        
        # Map x_values to their positions in x_targets to detect missing values in the sequence
        indices = []
        for x in x_values:
            idx_matches = np.where(x_targets == x)[0]
            if len(idx_matches) > 0:
                indices.append(idx_matches[0])
            else:
                indices.append(-1)
                
        # Group indices into contiguous blocks where index differences are exactly 1
        segments = []
        current_segment = []
        for idx, val in enumerate(x_values):
            if not current_segment:
                current_segment.append(idx)
            else:
                prev_target_idx = indices[current_segment[-1]]
                curr_target_idx = indices[idx]
                if curr_target_idx == prev_target_idx + 1:
                    current_segment.append(idx)
                else:
                    segments.append(current_segment)
                    current_segment = [idx]
        if current_segment:
            segments.append(current_segment)
            
        alpha_val = style.get("alpha", 1.0)
        first_segment = True
        for seg in segments:
            seg_x = x_values[seg]
            seg_y = y_values[seg]
            
            # Smooth plotting for this segment
            smooth_x, smooth_y = smooth_series(seg_x, seg_y)
            
            ax.plot(
                smooth_x,
                smooth_y,
                label=style["label"] if first_segment else None,
                color=style["color"],
                linewidth=1.75,
                linestyle=style.get("linestyle", "solid"),
                solid_capstyle="round",
                solid_joinstyle="round",
                antialiased=True,
                alpha=alpha_val,
                zorder=3
            )
            
            # Area fill for this segment
            ax.fill_between(
                smooth_x,
                smooth_y,
                color=style["color"],
                alpha=0.08 * alpha_val,
                zorder=1
            )
            first_segment = False
        
        # Scatter points
        ax.plot(
            x_values,
            y_values,
            linestyle="none",
            color=style["color"],
            marker=style.get("marker", "o"),
            markersize=4.5,
            markeredgewidth=1.0,
            markeredgecolor="#FFFFFF",
            alpha=alpha_val,
            zorder=4
        )

    # Title & Labels
    fig.text(
        0.15,
        0.95,
        title,
        ha="left",
        va="top",
        fontsize=13,
        fontweight="semibold",
        color=THEME["text"],
    )
    
    ax.set_xlabel("Target RPS", fontsize=10.5, color=THEME["muted"], labelpad=8)
    ax.set_ylabel(y_label, fontsize=10.5, color=THEME["muted"], labelpad=8)
    
    # Tick formatting
    ax.set_xticks(x_targets)
    if len(x_targets) > 0:
        ax.set_xlim(x_targets.min() - 10, x_targets.max() + 10)
    if y_limits is not None:
        ax.set_ylim(y_limits)
    ax.ticklabel_format(style="plain", axis="both", useOffset=False)
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=9.5, length=4, width=1.0)
    
    # Spines & Rounded border
    for spine in ax.spines.values():
        spine.set_visible(False)
        
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.015",
        facecolor="none",
        edgecolor=THEME["axis"],
        linewidth=1.0,
        transform=ax.transAxes,
        zorder=5,
        clip_on=False,
    )
    ax.add_patch(rect)
    
    # Consistent bottom legend
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.50, 0.12),
        bbox_transform=fig.transFigure,
        ncol=ncol_legend,
        frameon=False,
        fontsize=9.0,
        handlelength=1.8,
        columnspacing=1.5,
        handletextpad=0.5,
        labelcolor=THEME["text"],
    )
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    plt.close(fig)


def _plot_consolidated_outcome_breakdown(
    df_subset: pd.DataFrame,
    styles_dict: dict,
    title: str,
    output_path: Path,
    ncol_legend: int = 2
):
    fig = Figure(figsize=(8.0, 5.2), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor(THEME["card"])
    ax.grid(True, which="major", axis="y", color=THEME["grid"], linewidth=1.0, linestyle="-")
    
    fig.subplots_adjust(left=0.15, right=0.90, bottom=0.25, top=0.85)
    
    target_col = "target_rps" if "target_rps" in df_subset.columns else "Target RPS"
    target_levels = sorted(df_subset[target_col].dropna().unique().astype(int))
    n_levels = len(target_levels)
    
    run_labels = [k for k in styles_dict.keys() if k in df_subset["run_label"].unique()]
    n_labels = len(run_labels)
    
    if n_levels == 0 or n_labels == 0:
        logger.warning(
            "No levels or run_labels found for consolidated outcome breakdown: %s",
            output_path.name
        )
        return
        
    bar_total_width = 0.7
    bar_width = bar_total_width / n_labels
    x_base = np.arange(n_levels)
    
    for idx, key in enumerate(run_labels):
        style = styles_dict[key]
        subset = df_subset[df_subset["run_label"] == key]
        
        success_vals = []
        error_vals = []
        for level in target_levels:
            row = subset[subset[target_col] == level]
            if row.empty:
                success_vals.append(np.nan)
                error_vals.append(np.nan)
            else:
                actual = float(row["actual_throughput"].iloc[0])
                if "successful_throughput" in row.columns:
                    successful = float(row["successful_throughput"].iloc[0])
                elif "error_rate" in row.columns:
                    error_rate = float(row["error_rate"].iloc[0])
                    successful = actual * (1.0 - error_rate)
                else:
                    successful = actual
                success_vals.append(max(0.0, successful))
                error_vals.append(max(0.0, actual - successful))
                
        success_arr = np.array(success_vals)
        error_arr = np.array(error_vals)
        
        offset = (idx - (n_labels - 1) / 2.0) * bar_width
        x_pos = x_base + offset
        
        alpha_val = style.get("alpha", 1.0)
        
        # Success segment (bottom, solid)
        ax.bar(
            x_pos,
            success_arr,
            width=bar_width * 0.88,
            color=style["color"],
            alpha=0.85 * alpha_val,
            zorder=3,
            label=f"{style['label']} — Success",
        )
        # Error/rejected segment (top, hatched)
        ax.bar(
            x_pos,
            error_arr,
            width=bar_width * 0.88,
            bottom=np.nan_to_num(success_arr),
            color=style["color"],
            alpha=0.35 * alpha_val,
            hatch="///",
            edgecolor=style["color"],
            linewidth=0.6,
            zorder=3,
            label=f"{style['label']} — Error/Rejected",
        )
        
    fig.text(
        0.15,
        0.95,
        title,
        ha="left",
        va="top",
        fontsize=13,
        fontweight="semibold",
        color=THEME["text"],
    )
    
    ax.set_xlabel("Target RPS", fontsize=10.5, color=THEME["muted"], labelpad=8)
    ax.set_ylabel("Throughput (req/s)", fontsize=10.5, color=THEME["muted"], labelpad=8)
    
    ax.set_xticks(x_base)
    ax.set_xticklabels([str(lvl) for lvl in target_levels])
    ax.set_xlim(-0.5, n_levels - 0.5)
    ax.ticklabel_format(style="plain", axis="y")
    ax.tick_params(axis="both", colors=THEME["muted"], labelsize=9.5, length=4, width=1.0)
    
    for spine in ax.spines.values():
        spine.set_visible(False)
        
    rect = FancyBboxPatch(
        (0, 0), 1, 1,
        boxstyle="round,pad=0.0,rounding_size=0.015",
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
        bbox_to_anchor=(0.50, 0.12),
        bbox_transform=fig.transFigure,
        ncol=ncol_legend,
        frameon=False,
        fontsize=8.0,
        handlelength=1.6,
        columnspacing=1.2,
        handletextpad=0.4,
        labelcolor=THEME["text"],
    )
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
    plt.close(fig)


def _get_scenario_col(df: pd.DataFrame) -> str | None:
    """Return the name of the scenario column, supporting both snake_case and Title Case variants."""
    if "scenario" in df.columns:
        return "scenario"
    if "Scenario" in df.columns:
        return "Scenario"
    return None


def _get_target_col(df: pd.DataFrame) -> str:
    """Return the name of the target RPS column."""
    return "target_rps" if "target_rps" in df.columns else "Target RPS"


def generate_consolidated_plots(df: pd.DataFrame, output_dir: Path, metric_type: str) -> None:
    """Generate all consolidated comparison charts for either k6 or datadog metrics.

    For primary charts, one set of files is generated per scenario found in the data,
    named ``primary-{scenario-slug}-{metric}.png``.  Ablation charts are always
    restricted to the ``login`` scenario because the ablation run (admission-control
    disabled) only contains that endpoint.

    Args:
        df: Compiled DataFrame from :func:`compile_consolidated_dataset`.
        output_dir: Directory where PNG files are written.
        metric_type: Either ``"k6"`` (throughput/latency metrics) or
            ``"datadog"`` (CPU/memory metrics).

    Raises:
        ValueError: If *metric_type* is not ``"k6"`` or ``"datadog"``.
    """
    if metric_type not in {"k6", "datadog"}:
        raise ValueError(
            f"metric_type must be 'k6' or 'datadog', got: {metric_type!r}"
        )

    output_dir.mkdir(parents=True, exist_ok=True)

    primary_styles = {
        "mono_fixed_true": {
            "label": "Monolith (FIXED)",
            "color": "#3274D9",
            "marker": "o",
            "linestyle": "solid",
        },
        "msa_fixed_true": {
            "label": "Microservices (FIXED)",
            "color": "#FF780A",
            "marker": "s",
            "linestyle": "solid",
        },
        "msa_hpa_true": {
            "label": "Microservices (HPA)",
            "color": "#10B981",
            "marker": "^",
            "linestyle": "solid",
        },
    }

    # Ablation: compare admission-control enabled vs disabled for fixed scaling only.
    # HPA ablation run keys (msa_hpa_true/false) are intentionally excluded here
    # because the ablation run only covers the login scenario under fixed replicas.
    ablation_styles = {
        "mono_fixed_true": {
            "label": "Monolith (Enabled)",
            "color": "#3274D9",
            "marker": "o",
            "linestyle": "solid",
        },
        "msa_fixed_true": {
            "label": "Microservices FIXED (Enabled)",
            "color": "#FF780A",
            "marker": "s",
            "linestyle": "solid",
        },
        "mono_fixed_false": {
            "label": "Monolith (Disabled)",
            "color": "#3274D9",
            "marker": "o",
            "linestyle": (0, (5, 3)),
            "alpha": 0.6,
        },
        "msa_fixed_false": {
            "label": "Microservices FIXED (Disabled)",
            "color": "#FF780A",
            "marker": "s",
            "linestyle": (0, (5, 3)),
            "alpha": 0.6,
        },
    }

    if metric_type == "k6":
        df = df.copy()

        # Derive success_rate_pct — prefer checks_rate, fall back to error_rate
        if "checks_rate" in df.columns:
            df["success_rate_pct"] = (
                df["checks_rate"].fillna(1.0 - df.get("error_rate", 0.0)) * 100.0
            )
        elif "error_rate" in df.columns:
            df["success_rate_pct"] = (1.0 - df["error_rate"]) * 100.0
        else:
            df["success_rate_pct"] = 100.0

        df["p95_latency_s"] = df["p95_latency_ms"] / 1000.0

        primary_df = df[df["admission"]].copy()
        scenario_col = _get_scenario_col(primary_df)

        if scenario_col is None:
            logger.warning("No scenario column found in k6 primary_df — skipping per-scenario primary charts")
        else:
            scenarios = sorted(primary_df[scenario_col].dropna().unique())
            if not scenarios:
                logger.warning("No scenarios found in k6 primary_df — skipping per-scenario primary charts")

            for scenario in scenarios:
                scenario_df = primary_df[primary_df[scenario_col] == scenario].copy()
                if scenario_df.empty:
                    continue

                # Derive a filesystem-safe slug and a human-readable title fragment
                scenario_slug = scenario.lower().replace(" ", "-")
                scenario_title = scenario.replace("-", " ").title()

                _plot_unified_chart(
                    df_subset=scenario_df,
                    metric_col="success_rate_pct",
                    styles_dict=primary_styles,
                    title=f"Success Rate vs Target RPS — {scenario_title}",
                    y_label="Success Rate (%)",
                    y_limits=(-5, 105),
                    output_path=output_dir / f"primary-{scenario_slug}-success-rate.png",
                    ncol_legend=3,
                )
                _plot_unified_chart(
                    df_subset=scenario_df,
                    metric_col="p95_latency_s",
                    styles_dict=primary_styles,
                    title=f"p95 Latency vs Target RPS — {scenario_title}",
                    y_label="p95 Latency (seconds)",
                    y_limits=None,   # auto-scale: each scenario has a different latency range
                    output_path=output_dir / f"primary-{scenario_slug}-p95-latency.png",
                    ncol_legend=3,
                )
                _plot_unified_chart(
                    df_subset=scenario_df,
                    metric_col="throughput_achievement_pct",
                    styles_dict=primary_styles,
                    title=f"Throughput Achievement vs Target RPS — {scenario_title}",
                    y_label="Achievement (%)",
                    y_limits=(-5, 105),
                    output_path=output_dir / f"primary-{scenario_slug}-throughput-achievement.png",
                    ncol_legend=3,
                )
                _plot_consolidated_outcome_breakdown(
                    df_subset=scenario_df,
                    styles_dict=primary_styles,
                    title=f"Request Outcome Breakdown — {scenario_title}",
                    output_path=output_dir / f"primary-{scenario_slug}-throughput-breakdown.png",
                    ncol_legend=3,
                )
                if "dropped_iterations" in scenario_df.columns:
                    _plot_unified_chart(
                        df_subset=scenario_df,
                        metric_col="dropped_iterations",
                        styles_dict=primary_styles,
                        title=f"Dropped Iterations vs Target RPS — {scenario_title}",
                        y_label="Dropped Iterations",
                        y_limits=None,
                        output_path=output_dir / f"primary-{scenario_slug}-dropped-iterations.png",
                        ncol_legend=3,
                    )



        # Ablation charts — always restricted to login scenario.
        # The ablation run (admission-control disabled) only executed the login
        # endpoint, so filtering here is intentional and documented.
        ablation_scenario_col = _get_scenario_col(df)
        if ablation_scenario_col is not None:
            ablation_df = df[df[ablation_scenario_col].str.lower() == "login"].copy()
        else:
            ablation_df = df.copy()

        _plot_unified_chart(
            df_subset=ablation_df,
            metric_col="success_rate_pct",
            styles_dict=ablation_styles,
            title="Success Rate vs Target RPS (Admission Control — Login)",
            y_label="Success Rate (%)",
            y_limits=(-5, 105),
            output_path=output_dir / "ablation-success-rate.png",
            ncol_legend=2,
        )
        _plot_unified_chart(
            df_subset=ablation_df,
            metric_col="p95_latency_s",
            styles_dict=ablation_styles,
            title="p95 Latency vs Target RPS (Admission Control — Login)",
            y_label="p95 Latency (seconds)",
            y_limits=(-2, 42),
            output_path=output_dir / "ablation-p95-latency.png",
            ncol_legend=2,
        )

    elif metric_type == "datadog":
        df = df.copy()

        # CPU from millicores (m) to cores
        cpu_col = None
        for col in ["Avg CPU (m)", "cpu_cores"]:
            if col in df.columns:
                cpu_col = col
                break
        if cpu_col == "Avg CPU (m)":
            df["cpu_cores"] = df["Avg CPU (m)"] / 1000.0
        elif cpu_col is None:
            logger.warning("No CPU column found in datadog DataFrame — cpu charts will be skipped")

        # Memory from mebibytes (Mi) to GiB
        mem_col = None
        for col in ["Avg Mem (Mi)", "mem_gib"]:
            if col in df.columns:
                mem_col = col
                break
        if mem_col == "Avg Mem (Mi)":
            df["mem_gib"] = df["Avg Mem (Mi)"] / 1024.0
        elif mem_col is None:
            logger.warning("No memory column found in datadog DataFrame — memory charts will be skipped")

        # Derive resource efficiency metrics:
        # 1. Successful RPS per Core
        # 2. Memory GiB per 1000 Successful RPS
        achieved_col = "achieved_rps" if "achieved_rps" in df.columns else None
        if not achieved_col and "Achieved RPS" in df.columns:
            achieved_col = "Achieved RPS"

        if achieved_col and "cpu_cores" in df.columns:
            df["rps_per_core"] = np.where(
                df["cpu_cores"] > 0,
                df[achieved_col] / df["cpu_cores"],
                0.0
            )

        if achieved_col and "mem_gib" in df.columns:
            df["mem_gib_per_1000_rps"] = np.where(
                df[achieved_col] > 0,
                (df["mem_gib"] / df[achieved_col]) * 1000.0,
                0.0
            )

        primary_df = df[df["admission"]].copy()
        scenario_col = _get_scenario_col(primary_df)

        if scenario_col is None:
            logger.warning("No scenario column found in datadog primary_df — skipping per-scenario primary charts")
        else:
            scenarios = sorted(primary_df[scenario_col].dropna().unique())
            if not scenarios:
                logger.warning("No scenarios found in datadog primary_df — skipping per-scenario primary charts")

            for scenario in scenarios:
                scenario_df = primary_df[primary_df[scenario_col] == scenario].copy()
                if scenario_df.empty:
                    continue

                scenario_slug = scenario.lower().replace(" ", "-")
                scenario_title = scenario.replace("-", " ").title()

                if cpu_col is not None:
                    _plot_unified_chart(
                        df_subset=scenario_df,
                        metric_col="cpu_cores",
                        styles_dict=primary_styles,
                        title=f"Average CPU Usage vs Target RPS — {scenario_title}",
                        y_label="CPU Usage (cores)",
                        y_limits=None,   # auto-scale per scenario
                        output_path=output_dir / f"primary-{scenario_slug}-cpu-usage.png",
                        ncol_legend=3,
                    )
                if mem_col is not None:
                    _plot_unified_chart(
                        df_subset=scenario_df,
                        metric_col="mem_gib",
                        styles_dict=primary_styles,
                        title=f"Average Memory Usage vs Target RPS — {scenario_title}",
                        y_label="Memory Usage (GiB)",
                        y_limits=None,   # auto-scale per scenario
                        output_path=output_dir / f"primary-{scenario_slug}-memory-usage.png",
                        ncol_legend=3,
                    )
                if "rps_per_core" in df.columns:
                    _plot_unified_chart(
                        df_subset=scenario_df,
                        metric_col="rps_per_core",
                        styles_dict=primary_styles,
                        title=f"CPU Efficiency vs Target RPS — {scenario_title}",
                        y_label="Successful RPS per Core",
                        y_limits=None,
                        output_path=output_dir / f"primary-{scenario_slug}-cpu-efficiency.png",
                        ncol_legend=3,
                    )
                if "mem_gib_per_1000_rps" in df.columns:
                    _plot_unified_chart(
                        df_subset=scenario_df,
                        metric_col="mem_gib_per_1000_rps",
                        styles_dict=primary_styles,
                        title=f"Memory Efficiency vs Target RPS — {scenario_title}",
                        y_label="Memory GiB per 1000 Successful RPS",
                        y_limits=None,
                        output_path=output_dir / f"primary-{scenario_slug}-mem-efficiency.png",
                        ncol_legend=3,
                    )

        # Ablation charts — login only (same rationale as k6 path)
        ablation_scenario_col = _get_scenario_col(df)
        if ablation_scenario_col is not None:
            ablation_df = df[df[ablation_scenario_col].str.lower() == "login"].copy()
        else:
            ablation_df = df.copy()

        if cpu_col is not None:
            _plot_unified_chart(
                df_subset=ablation_df,
                metric_col="cpu_cores",
                styles_dict=ablation_styles,
                title="Average CPU Usage vs Target RPS (Admission Control — Login)",
                y_label="CPU Usage (cores)",
                y_limits=(-0.5, 11.5),
                output_path=output_dir / "ablation-cpu-usage.png",
                ncol_legend=2,
            )
        if mem_col is not None:
            _plot_unified_chart(
                df_subset=ablation_df,
                metric_col="mem_gib",
                styles_dict=ablation_styles,
                title="Average Memory Usage vs Target RPS (Admission Control — Login)",
                y_label="Memory Usage (GiB)",
                y_limits=(-0.02, 0.45),
                output_path=output_dir / "ablation-memory-usage.png",
                ncol_legend=2,
            )
