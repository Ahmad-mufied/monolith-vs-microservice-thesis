"""Table formatter and writer for resource efficiency reports."""

from __future__ import annotations

from pathlib import Path
from typing import List
import pandas as pd

from report_generator.datadog.metrics import AttemptMetrics


def _sort_report_frame(df: pd.DataFrame) -> pd.DataFrame:
    sort_columns = [
        column
        for column in ("Scenario", "Scaling Mode", "Target RPS", "Architecture", "Service")
        if column in df.columns
    ]
    return df.sort_values(by=sort_columns).reset_index(drop=True) if sort_columns else df


def generate_resource_summary_table(metrics_list: List[AttemptMetrics]) -> pd.DataFrame:
    """Generate master resource summary dataframe comparing architectures."""
    rows = []
    for m in metrics_list:
        rows.append({
            "Scenario": m.scenario,
            "Architecture": "Monolith" if m.architecture == "monolith" else "Microservices",
            "Scaling Mode": m.scaling_mode.upper(),
            "Target RPS": m.target_rps,
            "Achieved RPS": round(m.achieved_rps, 1),
            "Avg CPU (m)": round(m.avg_cpu_cores * 1000, 1),
            "P95 CPU (m)": round(m.p95_cpu_cores * 1000, 1),
            "CPU Limit (m)": round(m.cpu_limit_cores * 1000, 1),
            "CPU Util (%)": round(m.cpu_utilization_pct, 1),
            "Avg Mem (Mi)": round(m.avg_mem_gib * 1024, 1),
            "P95 Mem (Mi)": round(m.p95_mem_gib * 1024, 1),
            "Mem Limit (Mi)": round(m.mem_limit_gib * 1024, 1),
            "Mem Util (%)": round(m.mem_utilization_pct, 1)
        })
    df = pd.DataFrame(rows)
    return _sort_report_frame(df)


def generate_efficiency_metrics_table(metrics_list: List[AttemptMetrics]) -> pd.DataFrame:
    """Generate derived efficiency metrics dataframe."""
    rows = []
    for m in metrics_list:
        rows.append({
            "Scenario": m.scenario,
            "Architecture": "Monolith" if m.architecture == "monolith" else "Microservices",
            "Scaling Mode": m.scaling_mode.upper(),
            "Target RPS": m.target_rps,
            "RPS / Core": round(m.rps_per_core, 1),
            "CPU Core-sec / 1000 Req": round(m.core_seconds_per_1000_req, 3),
            "Mem Mi / 1000 RPS": round(m.mem_gib_per_1000_rps * 1024, 1)
        })
    df = pd.DataFrame(rows)
    return _sort_report_frame(df)


def generate_msa_breakdown_table(metrics_list: List[AttemptMetrics]) -> pd.DataFrame:
    """Generate microservices service-level breakdown dataframe."""
    rows = []
    for m in metrics_list:
        if m.architecture != "microservices":
            continue
        for s in m.service_breakdown:
            rows.append({
                "Scenario": m.scenario,
                "Scaling Mode": m.scaling_mode.upper(),
                "Target RPS": m.target_rps,
                "Service": s.service_name,
                "Avg CPU (m)": round(s.avg_cpu_cores * 1000, 1),
                "P95 CPU (m)": round(s.p95_cpu_cores * 1000, 1),
                "CPU Limit (m)": round(s.cpu_limit_cores * 1000, 1),
                "CPU Util (%)": round(s.cpu_utilization_pct, 1),
                "Avg Mem (Mi)": round(s.avg_mem_gib * 1024, 1),
                "P95 Mem (Mi)": round(s.p95_mem_gib * 1024, 1),
                "Mem Limit (Mi)": round(s.mem_limit_gib * 1024, 1),
                "Mem Util (%)": round(s.mem_utilization_pct, 1),
                "Avg Replicas": round(s.avg_replicas, 1),
                "Max Replicas": int(s.max_replicas)
            })
    df = pd.DataFrame(rows)
    return _sort_report_frame(df)


def write_tables(metrics_list: List[AttemptMetrics], output_dir: Path) -> List[Path]:
    """Generate and write tables (CSV) to output directory."""
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_files = []

    # 1. Resource Summary
    df_summary = generate_resource_summary_table(metrics_list)
    if not df_summary.empty:
        csv_path = output_dir / "resource-summary.csv"
        df_summary.to_csv(csv_path, index=False)
        generated_files.append(csv_path)

    # 2. Efficiency Metrics
    df_efficiency = generate_efficiency_metrics_table(metrics_list)
    if not df_efficiency.empty:
        csv_path = output_dir / "efficiency-metrics.csv"
        df_efficiency.to_csv(csv_path, index=False)
        generated_files.append(csv_path)

    # 3. MSA Breakdown
    df_breakdown = generate_msa_breakdown_table(metrics_list)
    if not df_breakdown.empty:
        csv_path = output_dir / "msa-service-breakdown.csv"
        df_breakdown.to_csv(csv_path, index=False)
        generated_files.append(csv_path)

    return generated_files
