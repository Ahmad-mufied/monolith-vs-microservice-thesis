"""Chart generation for report-ready PNG resource plots, matching k6-report-generator style."""

from __future__ import annotations

from pathlib import Path
from typing import List
import matplotlib

matplotlib.use("Agg")
from matplotlib.figure import Figure
from matplotlib.backends.backend_agg import FigureCanvasAgg
from matplotlib.patches import FancyBboxPatch
import numpy as np
import pandas as pd

from report_generator.datadog.datadog_client import DatadogClient

# Setup matplotlib fonts
matplotlib.rcParams['font.family'] = 'sans-serif'
matplotlib.rcParams['font.sans-serif'] = [
    'Inter', 'Roboto', 'Helvetica Neue', 'Arial', 
    'Liberation Sans', 'DejaVu Sans', 'sans-serif'
]

# Grafana/Academic style constants matching k6-report-generator
ARCHITECTURE_STYLE = {
    "monolith": {
        "label": "Monolith",
        "color": "#3274D9",  # Grafana vibrant blue
        "linestyle": "solid",
        "zorder": 3,
    },
    "microservices": {
        "label": "Microservices",
        "color": "#FF780A",  # Grafana vibrant orange
        "linestyle": (0, (5, 3)),  # Clean dashed line
        "zorder": 4,
    },
}

SERVICE_COLORS = {
    "api-gateway": "#5794F2",        # Light blue
    "auth-service": "#73BF69",       # Emerald green
    "item-service": "#FADE2A",       # Golden yellow
    "transaction-service": "#FF780A", # Vibrant orange
    "monolith": "#3274D9"            # Monolith blue
}

THEME = {
    "page": "#FFFFFF",
    "card": "#FFFFFF",
    "card_edge": "#E5E7EB",
    "grid": "#F3F4F6",      # Very light grey grid lines
    "text": "#111827",      # Near black text
    "muted": "#4B5563",
    "axis": "#E5E7EB",      # Thin borders
    "legend_bg": "#FFFFFF",
    "legend_text": "#111827",
}

OUTPUT_DPI = 320


def plot_architecture_comparison(
    client: DatadogClient,
    scenario: str,
    target_rps: int,
    scaling_mode: str,
    mono_time: tuple[int, int] | None,
    msa_time: tuple[int, int] | None,
    output_dir: Path,
) -> List[Path]:
    """Plot cross-architecture CPU and Memory usage comparison over time."""
    output_dir.mkdir(parents=True, exist_ok=True)
    generated = []

    # Datasets for CPU and Memory
    mono_cpu_series = []
    mono_mem_series = []
    msa_cpu_series = []
    msa_mem_series = []

    # 1. Fetch Monolith series
    if mono_time:
        try:
            mono_cpu_series = client.query_metrics(
                "sum:kubernetes.cpu.usage.total{kube_namespace:mono} by {pod}",
                mono_time[0], mono_time[1]
            )
            mono_mem_series = client.query_metrics(
                "sum:kubernetes.memory.usage{kube_namespace:mono} by {pod}",
                mono_time[0], mono_time[1]
            )
        except Exception as exc:
            print(f"WARNING: Failed to fetch monolith series: {exc}")

    # 2. Fetch MSA series
    if msa_time:
        try:
            msa_cpu_series = client.query_metrics(
                "sum:kubernetes.cpu.usage.total{kube_namespace:msa} by {pod}",
                msa_time[0], msa_time[1]
            )
            msa_mem_series = client.query_metrics(
                "sum:kubernetes.memory.usage{kube_namespace:msa} by {pod}",
                msa_time[0], msa_time[1]
            )
        except Exception as exc:
            print(f"WARNING: Failed to fetch msa series: {exc}")

    # Helper function to convert raw datadog query outputs to a total series over relative time (minutes)
    def series_to_relative_totals(series_list: list, conversion_factor: float) -> tuple[np.ndarray, np.ndarray]:
        if not series_list:
            return np.array([]), np.array([])
        
        records = []
        for s in series_list:
            for pt in s.points:
                if pt.value is not None:
                    records.append((pt.timestamp, pt.value * conversion_factor))
        
        if not records:
            return np.array([]), np.array([])

        df = pd.DataFrame(records, columns=["timestamp", "val"])
        df_sum = df.groupby("timestamp")["val"].sum().sort_index()
        
        timestamps = df_sum.index.values
        values = df_sum.values
        
        if len(timestamps) > 0:
            start_t = timestamps[0]
            relative_min = (timestamps - start_t) / 60.0
            return relative_min, values
        return np.array([]), np.array([])

    # Process series
    m_cpu_x, m_cpu_y = series_to_relative_totals(mono_cpu_series, 1e-9) # nanocores -> cores
    m_mem_x, m_mem_y = series_to_relative_totals(mono_mem_series, 1 / (1024**3)) # bytes -> GiB
    
    s_cpu_x, s_cpu_y = series_to_relative_totals(msa_cpu_series, 1e-9)
    s_mem_x, s_mem_y = series_to_relative_totals(msa_mem_series, 1 / (1024**3))

    # --- PLOT CPU COMPARISON ---
    fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor("none")  # Transparent rectangular axes background

    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)

    plotted = False
    if len(m_cpu_x) > 0:
        ax.plot(
            m_cpu_x, m_cpu_y, 
            label=ARCHITECTURE_STYLE["monolith"]["label"],
            color=ARCHITECTURE_STYLE["monolith"]["color"],
            linestyle=ARCHITECTURE_STYLE["monolith"]["linestyle"],
            linewidth=2.5,
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=ARCHITECTURE_STYLE["monolith"]["zorder"]
        )
        ax.fill_between(
            m_cpu_x, m_cpu_y,
            color=ARCHITECTURE_STYLE["monolith"]["color"],
            alpha=0.08,
            zorder=1
        )
        plotted = True

    if len(s_cpu_x) > 0:
        ax.plot(
            s_cpu_x, s_cpu_y, 
            label=ARCHITECTURE_STYLE["microservices"]["label"],
            color=ARCHITECTURE_STYLE["microservices"]["color"],
            linestyle=ARCHITECTURE_STYLE["microservices"]["linestyle"],
            linewidth=2.5,
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=ARCHITECTURE_STYLE["microservices"]["zorder"]
        )
        ax.fill_between(
            s_cpu_x, s_cpu_y,
            color=ARCHITECTURE_STYLE["microservices"]["color"],
            alpha=0.08,
            zorder=1
        )
        plotted = True

    if plotted:
        # Set CPU limits to match duration exactly AFTER plotting to allow proper y-scaling
        all_cpu_x = []
        if len(m_cpu_x) > 0:
            all_cpu_x.append(m_cpu_x.max())
        if len(s_cpu_x) > 0:
            all_cpu_x.append(s_cpu_x.max())
        if all_cpu_x:
            ax.set_xlim(0, max(all_cpu_x))
        ax.set_ylim(bottom=0)

        title = "CPU Usage Comparison"
        subtitle = f"{scenario.replace('-', ' ').title()} at {target_rps} RPS ({scaling_mode.title()} Scaling Mode)"
        fig.text(0.22, 0.89, title, ha="left", va="top", fontsize=15, fontweight="semibold", color=THEME["text"])
        fig.text(0.22, 0.84, subtitle, ha="left", va="top", fontsize=9.5, color=THEME["muted"])

        ax.set_xlabel("Relative Time (Minutes)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.set_ylabel("Total CPU cores used", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
        
        # Hide standard spines to draw rounded border patch
        for spine in ax.spines.values():
            spine.set_visible(False)

        # Draw rounded card background and border
        rect = FancyBboxPatch(
            (0, 0), 1, 1,
            boxstyle="round,pad=0.0,rounding_size=0.02",
            facecolor=THEME["card"],
            edgecolor=THEME["axis"],
            linewidth=1.0,
            transform=ax.transAxes,
            zorder=-10,
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
        
        cpu_path = output_dir / f"{scaling_mode}-{scenario}-{target_rps}rps-cpu-comparison.png"
        fig.savefig(cpu_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
        generated.append(cpu_path)

    # --- PLOT MEMORY COMPARISON ---
    fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
    FigureCanvasAgg(fig)
    ax = fig.add_subplot(111)
    fig.patch.set_facecolor(THEME["page"])
    ax.set_facecolor("none")  # Transparent rectangular axes background

    ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
    fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)

    plotted = False
    if len(m_mem_x) > 0:
        ax.plot(
            m_mem_x, m_mem_y, 
            label=ARCHITECTURE_STYLE["monolith"]["label"],
            color=ARCHITECTURE_STYLE["monolith"]["color"],
            linestyle=ARCHITECTURE_STYLE["monolith"]["linestyle"],
            linewidth=2.5,
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=ARCHITECTURE_STYLE["monolith"]["zorder"]
        )
        ax.fill_between(
            m_mem_x, m_mem_y,
            color=ARCHITECTURE_STYLE["monolith"]["color"],
            alpha=0.08,
            zorder=1
        )
        plotted = True

    if len(s_mem_x) > 0:
        ax.plot(
            s_mem_x, s_mem_y, 
            label=ARCHITECTURE_STYLE["microservices"]["label"],
            color=ARCHITECTURE_STYLE["microservices"]["color"],
            linestyle=ARCHITECTURE_STYLE["microservices"]["linestyle"],
            linewidth=2.5,
            solid_capstyle="round",
            solid_joinstyle="round",
            antialiased=True,
            zorder=ARCHITECTURE_STYLE["microservices"]["zorder"]
        )
        ax.fill_between(
            s_mem_x, s_mem_y,
            color=ARCHITECTURE_STYLE["microservices"]["color"],
            alpha=0.08,
            zorder=1
        )
        plotted = True

    if plotted:
        # Set Memory limits to match duration exactly AFTER plotting to allow proper y-scaling
        all_mem_x = []
        if len(m_mem_x) > 0:
            all_mem_x.append(m_mem_x.max())
        if len(s_mem_x) > 0:
            all_mem_x.append(s_mem_x.max())
        if all_mem_x:
            ax.set_xlim(0, max(all_mem_x))
        ax.set_ylim(bottom=0)

        title = "Memory Usage Comparison"
        subtitle = f"{scenario.replace('-', ' ').title()} at {target_rps} RPS ({scaling_mode.title()} Scaling Mode)"
        fig.text(0.22, 0.89, title, ha="left", va="top", fontsize=15, fontweight="semibold", color=THEME["text"])
        fig.text(0.22, 0.84, subtitle, ha="left", va="top", fontsize=9.5, color=THEME["muted"])

        ax.set_xlabel("Relative Time (Minutes)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.set_ylabel("Total Memory used (GiB)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
        
        # Hide standard spines to draw rounded border patch
        for spine in ax.spines.values():
            spine.set_visible(False)

        # Draw rounded card background and border
        rect = FancyBboxPatch(
            (0, 0), 1, 1,
            boxstyle="round,pad=0.0,rounding_size=0.02",
            facecolor=THEME["card"],
            edgecolor=THEME["axis"],
            linewidth=1.0,
            transform=ax.transAxes,
            zorder=-10,
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
        
        mem_path = output_dir / f"{scaling_mode}-{scenario}-{target_rps}rps-memory-comparison.png"
        fig.savefig(mem_path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
        generated.append(mem_path)

    return generated


def plot_msa_breakdown(
    client: DatadogClient,
    scenario: str,
    target_rps: int,
    scaling_mode: str,
    msa_time: tuple[int, int] | None,
    output_dir: Path,
) -> List[Path]:
    """Plot microservices service-level CPU and Memory usage breakdowns over time."""
    if not msa_time:
        return []
        
    output_dir.mkdir(parents=True, exist_ok=True)
    generated = []

    # Fetch services series
    try:
        cpu_series = client.query_metrics(
            "sum:kubernetes.cpu.usage.total{kube_namespace:msa} by {kube_deployment,pod}",
            msa_time[0], msa_time[1]
        )
        mem_series = client.query_metrics(
            "sum:kubernetes.memory.usage{kube_namespace:msa} by {kube_deployment,pod}",
            msa_time[0], msa_time[1]
        )
    except Exception as exc:
        print(f"WARNING: Failed to fetch msa breakdown series: {exc}")
        return []

    # Parse and structure per service-timestamp
    def process_to_service_dataframe(series_list: list, conversion_factor: float) -> pd.DataFrame:
        records = []
        for s in series_list:
            deployment = s.tags.get("kube_deployment", "unknown")
            for pt in s.points:
                if pt.value is not None:
                    records.append({
                        "timestamp": pt.timestamp,
                        "service": deployment,
                        "val": pt.value * conversion_factor
                    })
        if not records:
            return pd.DataFrame()
        df = pd.DataFrame(records)
        df_sum = df.groupby(["service", "timestamp"])["val"].sum().reset_index()
        return df_sum

    df_cpu = process_to_service_dataframe(cpu_series, 1e-9)
    df_mem = process_to_service_dataframe(mem_series, 1 / (1024**3))

    # Plot service breakdown CPU
    if not df_cpu.empty:
        fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
        FigureCanvasAgg(fig)
        ax = fig.add_subplot(111)
        fig.patch.set_facecolor(THEME["page"])
        ax.set_facecolor("none")  # Transparent rectangular axes background
        
        ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
        fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)
        
        timestamps = sorted(df_cpu["timestamp"].unique())
        start_t = timestamps[0]
        
        for service, group in df_cpu.groupby("service"):
            group = group.sort_values("timestamp")
            rel_min = (group["timestamp"].values - start_t) / 60.0
            color = SERVICE_COLORS.get(service, "#94A3B8")
            
            # Capitalize service label for professional legend look
            display_label = service.replace("-", " ").title()
            if display_label == "Api Gateway":
                display_label = "API Gateway"

            ax.plot(
                rel_min, group["val"].values, 
                label=display_label, 
                color=color, 
                linewidth=2.0,
                solid_capstyle="round",
                solid_joinstyle="round",
                antialiased=True,
                zorder=3
            )

        # Set x and y limits AFTER plotting to allow proper y-scaling
        max_t = (timestamps[-1] - start_t) / 60.0
        ax.set_xlim(0, max_t)
        ax.set_ylim(bottom=0)

        title = "Microservices CPU Usage Breakdown"
        subtitle = f"{scenario.replace('-', ' ').title()} at {target_rps} RPS ({scaling_mode.title()} Scaling Mode)"
        fig.text(0.22, 0.89, title, ha="left", va="top", fontsize=15, fontweight="semibold", color=THEME["text"])
        fig.text(0.22, 0.84, subtitle, ha="left", va="top", fontsize=9.5, color=THEME["muted"])

        ax.set_xlabel("Relative Time (Minutes)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.set_ylabel("CPU cores used", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
        
        for spine in ax.spines.values():
            spine.set_visible(False)

        # Draw rounded card background and border
        rect = FancyBboxPatch(
            (0, 0), 1, 1,
            boxstyle="round,pad=0.0,rounding_size=0.02",
            facecolor=THEME["card"],
            edgecolor=THEME["axis"],
            linewidth=1.0,
            transform=ax.transAxes,
            zorder=-10,
            clip_on=False,
        )
        ax.add_patch(rect)

        ax.legend(
            loc="upper center",
            bbox_to_anchor=(0.56, 0.11),
            bbox_transform=fig.transFigure,
            ncol=4,
            frameon=False,
            fontsize=9.5,
            handlelength=1.8,
            columnspacing=1.5,
            handletextpad=0.5,
            labelcolor=THEME["legend_text"],
        )
        
        path = output_dir / f"{scaling_mode}-{scenario}-{target_rps}rps-msa-cpu-breakdown.png"
        fig.savefig(path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
        generated.append(path)

    # Plot service breakdown Memory
    if not df_mem.empty:
        fig = Figure(figsize=(10, 6.0), dpi=OUTPUT_DPI)
        FigureCanvasAgg(fig)
        ax = fig.add_subplot(111)
        fig.patch.set_facecolor(THEME["page"])
        ax.set_facecolor("none")  # Transparent rectangular axes background
        
        ax.grid(True, which="major", axis="both", color=THEME["grid"], linewidth=1.0, linestyle="-")
        fig.subplots_adjust(left=0.22, right=0.90, bottom=0.22, top=0.76)
        
        timestamps = sorted(df_mem["timestamp"].unique())
        start_t = timestamps[0]
        
        for service, group in df_mem.groupby("service"):
            group = group.sort_values("timestamp")
            rel_min = (group["timestamp"].values - start_t) / 60.0
            color = SERVICE_COLORS.get(service, "#94A3B8")
            
            # Capitalize service label for professional legend look
            display_label = service.replace("-", " ").title()
            if display_label == "Api Gateway":
                display_label = "API Gateway"

            ax.plot(
                rel_min, group["val"].values, 
                label=display_label, 
                color=color, 
                linewidth=2.0,
                solid_capstyle="round",
                solid_joinstyle="round",
                antialiased=True,
                zorder=3
            )

        # Set x and y limits AFTER plotting to allow proper y-scaling
        max_t = (timestamps[-1] - start_t) / 60.0
        ax.set_xlim(0, max_t)
        ax.set_ylim(bottom=0)

        title = "Microservices Memory Usage Breakdown"
        subtitle = f"{scenario.replace('-', ' ').title()} at {target_rps} RPS ({scaling_mode.title()} Scaling Mode)"
        fig.text(0.22, 0.89, title, ha="left", va="top", fontsize=15, fontweight="semibold", color=THEME["text"])
        fig.text(0.22, 0.84, subtitle, ha="left", va="top", fontsize=9.5, color=THEME["muted"])

        ax.set_xlabel("Relative Time (Minutes)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.set_ylabel("Memory used (GiB)", fontsize=11, color=THEME["muted"], labelpad=10)
        ax.tick_params(axis="both", colors=THEME["muted"], labelsize=10, length=4, width=1.0)
        
        for spine in ax.spines.values():
            spine.set_visible(False)

        # Draw rounded card background and border
        rect = FancyBboxPatch(
            (0, 0), 1, 1,
            boxstyle="round,pad=0.0,rounding_size=0.02",
            facecolor=THEME["card"],
            edgecolor=THEME["axis"],
            linewidth=1.0,
            transform=ax.transAxes,
            zorder=-10,
            clip_on=False,
        )
        ax.add_patch(rect)

        ax.legend(
            loc="upper center",
            bbox_to_anchor=(0.56, 0.11),
            bbox_transform=fig.transFigure,
            ncol=4,
            frameon=False,
            fontsize=9.5,
            handlelength=1.8,
            columnspacing=1.5,
            handletextpad=0.5,
            labelcolor=THEME["legend_text"],
        )
        
        path = output_dir / f"{scaling_mode}-{scenario}-{target_rps}rps-msa-memory-breakdown.png"
        fig.savefig(path, format="png", facecolor=fig.get_facecolor(), bbox_inches="tight")
        generated.append(path)

    return generated
