"""Metric aggregation and calculation of resource efficiency metrics (RQ2)."""

from __future__ import annotations

from typing import List
import pandas as pd
import numpy as np

from pydantic import BaseModel

from report_generator.datadog.config import ReporterConfig
from report_generator.datadog.datadog_client import DatadogClient


class AttemptMetrics(BaseModel):
    """Calculated metrics for a single attempt."""
    architecture: str
    scenario: str
    target_rps: int
    attempt: str
    scaling_mode: str
    duration_sec: float
    achieved_rps: float
    successful_requests: int
    
    # Aggregated metrics (actual)
    avg_cpu_cores: float
    p95_cpu_cores: float
    avg_mem_gib: float
    p95_mem_gib: float
    
    # Limits (ceilings)
    cpu_limit_cores: float
    mem_limit_gib: float
    
    # Utilization percentages
    cpu_utilization_pct: float
    mem_utilization_pct: float
    
    # Derived efficiency ratios
    rps_per_core: float
    core_seconds_per_1000_req: float
    mem_gib_per_1000_rps: float
    
    # Detailed service-level metrics (empty for monolith)
    service_breakdown: List[ServiceMetrics] = []


class ServiceMetrics(BaseModel):
    """Resource metrics for a single service in microservices."""
    service_name: str
    avg_cpu_cores: float
    p95_cpu_cores: float
    avg_mem_gib: float
    p95_mem_gib: float
    
    # Limits
    cpu_limit_cores: float
    mem_limit_gib: float
    
    # Utilization
    cpu_utilization_pct: float
    mem_utilization_pct: float
    
    # Replicas
    avg_replicas: float
    max_replicas: float


def compute_metrics(
    client: DatadogClient,
    config: ReporterConfig,
    architecture: str,
    scenario: str,
    target_rps: int,
    attempt: str,
    scaling_mode: str,
    duration_sec: float,
    achieved_rps: float,
    successful_requests: int,
    from_time: int,
    to_time: int,
) -> AttemptMetrics:
    """Fetch metrics from Datadog for the time window and calculate efficiency metrics."""
    # Determine namespace based on architecture
    # monolith -> mono, microservices -> msa
    namespace = "mono" if architecture == "monolith" else "msa"

    # CPU query
    cpu_query = f"sum:kubernetes.cpu.usage.total{{kube_namespace:{namespace}}} by {{kube_deployment,pod}}"
    # Memory query
    mem_query = f"sum:kubernetes.memory.usage{{kube_namespace:{namespace}}} by {{kube_deployment,pod}}"
    # Replicas/Pods query (to track running count of pods)
    pods_query = f"sum:kubernetes.pods.running{{kube_namespace:{namespace}}} by {{kube_deployment}}"

    # 1. Fetch timeseries data from Datadog (no silent errors, exceptions are raised up)
    cpu_series = client.query_metrics(cpu_query, from_time, to_time)
    mem_series = client.query_metrics(mem_query, from_time, to_time)
    pods_series = client.query_metrics(pods_query, from_time, to_time)

    # 2. Process CPU series into a DataFrame
    # Target structure: Timestamp, Service/Deployment, Pod, CPU_Cores
    cpu_records = []
    for s in cpu_series:
        deployment = s.tags.get("kube_deployment", "monolith" if architecture == "monolith" else "unknown")
        pod = s.tags.get("pod", "unknown")
        for pt in s.points:
            if pt.value is not None:
                # Convert nanocores to CPU cores
                cpu_cores = pt.value / 1e9
                cpu_records.append({
                    "timestamp": pt.timestamp,
                    "service": deployment,
                    "pod": pod,
                    "cpu_cores": cpu_cores
                })

    df_cpu = pd.DataFrame(cpu_records) if cpu_records else pd.DataFrame(columns=["timestamp", "service", "pod", "cpu_cores"])

    # 3. Process Memory series into a DataFrame
    # Target structure: Timestamp, Service/Deployment, Pod, Memory_GiB
    mem_records = []
    for s in mem_series:
        deployment = s.tags.get("kube_deployment", "monolith" if architecture == "monolith" else "unknown")
        pod = s.tags.get("pod", "unknown")
        for pt in s.points:
            if pt.value is not None:
                # Convert bytes to GiB
                mem_gib = pt.value / (1024 ** 3)
                mem_records.append({
                    "timestamp": pt.timestamp,
                    "service": deployment,
                    "pod": pod,
                    "mem_gib": mem_gib
                })

    df_mem = pd.DataFrame(mem_records) if mem_records else pd.DataFrame(columns=["timestamp", "service", "pod", "mem_gib"])

    # 4. Resolve limits config
    mode_limits = config.limits.hpa if scaling_mode.lower() == "hpa" else config.limits.fixed
    
    # Compute totals and breakdowns
    service_metrics_list: List[ServiceMetrics] = []
    
    if architecture == "monolith":
        # Monolith totals
        # Sum CPU and Memory across all monolith pods at each timestamp
        tot_cpu = df_cpu.groupby("timestamp")["cpu_cores"].sum() if not df_cpu.empty else pd.Series([0.0])
        tot_mem = df_mem.groupby("timestamp")["mem_gib"].sum() if not df_mem.empty else pd.Series([0.0])
        
        avg_cpu = tot_cpu.mean()
        p95_cpu = tot_cpu.quantile(0.95)
        avg_mem = tot_mem.mean()
        p95_mem = tot_mem.quantile(0.95)
        
        # Monolith limit limit
        cpu_limit = mode_limits.monolith.cpu_m / 1000.0  # convert m to cores
        mem_limit = mode_limits.monolith.mem_mib / 1024.0  # convert MiB to GiB
        
    else:
        # Microservices totals
        # Get list of expected services
        services = list(mode_limits.microservices.keys())
        
        # We compute architecture-level totals by summing CPU/Memory across all services per timestamp
        tot_cpu = df_cpu.groupby("timestamp")["cpu_cores"].sum() if not df_cpu.empty else pd.Series([0.0])
        tot_mem = df_mem.groupby("timestamp")["mem_gib"].sum() if not df_mem.empty else pd.Series([0.0])
        
        avg_cpu = tot_cpu.mean()
        p95_cpu = tot_cpu.quantile(0.95)
        avg_mem = tot_mem.mean()
        p95_mem = tot_mem.quantile(0.95)
        
        # Use the namespace ResourceQuota as the architecture-level fairness
        # ceiling when configured; fall back to summing service limits.
        msa_ceiling = mode_limits.microservices_ceiling
        if msa_ceiling:
            cpu_limit = msa_ceiling.cpu_m / 1000.0
            mem_limit = msa_ceiling.mem_mib / 1024.0
        else:
            cpu_limit = sum(s.cpu_m for s in mode_limits.microservices.values()) / 1000.0
            mem_limit = sum(s.mem_mib for s in mode_limits.microservices.values()) / 1024.0
        
        # Calculate per-service breakdown
        for svc in services:
            svc_limit = mode_limits.microservices[svc]
            svc_cpu_limit = svc_limit.cpu_m / 1000.0
            svc_mem_limit = svc_limit.mem_mib / 1024.0
            
            # CPU for this service
            svc_df_cpu = df_cpu[df_cpu["service"] == svc]
            svc_tot_cpu = svc_df_cpu.groupby("timestamp")["cpu_cores"].sum() if not svc_df_cpu.empty else pd.Series([0.0])
            svc_avg_cpu = svc_tot_cpu.mean()
            svc_p95_cpu = svc_tot_cpu.quantile(0.95)
            
            # Memory for this service
            svc_df_mem = df_mem[df_mem["service"] == svc]
            svc_tot_mem = svc_df_mem.groupby("timestamp")["mem_gib"].sum() if not svc_df_mem.empty else pd.Series([0.0])
            svc_avg_mem = svc_tot_mem.mean()
            svc_p95_mem = svc_tot_mem.quantile(0.95)
            
            # Replicas from pods_series or pod groupings
            # Try to get it from pods query
            svc_replicas: List[float] = []
            for s in pods_series:
                deployment = s.tags.get("kube_deployment", "")
                if deployment == svc:
                    svc_replicas = [pt.value for pt in s.points if pt.value is not None]
                    break
            
            if not svc_replicas and not svc_df_cpu.empty:
                # Fallback to counting unique pods per timestamp in CPU records
                svc_replicas = svc_df_cpu.groupby("timestamp")["pod"].nunique().tolist()
                
            avg_rep = float(np.mean(svc_replicas)) if svc_replicas else 1.0
            max_rep = float(np.max(svc_replicas)) if svc_replicas else 1.0
            
            # Utilization
            svc_cpu_util = (svc_avg_cpu / svc_cpu_limit) * 100 if svc_cpu_limit > 0 else 0.0
            svc_mem_util = (svc_avg_mem / svc_mem_limit) * 100 if svc_mem_limit > 0 else 0.0
            
            service_metrics_list.append(
                ServiceMetrics(
                    service_name=svc,
                    avg_cpu_cores=float(svc_avg_cpu),
                    p95_cpu_cores=float(svc_p95_cpu),
                    avg_mem_gib=float(svc_avg_mem),
                    p95_mem_gib=float(svc_p95_mem),
                    cpu_limit_cores=svc_cpu_limit,
                    mem_limit_gib=svc_mem_limit,
                    cpu_utilization_pct=svc_cpu_util,
                    mem_utilization_pct=svc_mem_util,
                    avg_replicas=avg_rep,
                    max_replicas=max_rep
                )
            )

    # 5. Architecture-level utilization %
    cpu_utilization = (avg_cpu / cpu_limit) * 100 if cpu_limit > 0 else 0.0
    mem_utilization = (avg_mem / mem_limit) * 100 if mem_limit > 0 else 0.0

    # 6. Derived efficiency metrics
    rps_per_core = achieved_rps / avg_cpu if avg_cpu > 0 else 0.0
    
    # CPU Core-seconds per 1000 Successful Requests
    # Core-seconds = average CPU cores * duration seconds
    if successful_requests > 0:
        core_seconds_per_1000_req = (avg_cpu * duration_sec / successful_requests) * 1000
    else:
        core_seconds_per_1000_req = 0.0
        
    # Memory GiB per 1000 achieved RPS
    # To compare memory footprints under load
    mem_gib_per_1000_rps = (avg_mem / achieved_rps) * 1000 if achieved_rps > 0 else 0.0

    return AttemptMetrics(
        architecture=architecture,
        scenario=scenario,
        target_rps=target_rps,
        attempt=attempt,
        scaling_mode=scaling_mode,
        duration_sec=duration_sec,
        achieved_rps=achieved_rps,
        successful_requests=successful_requests,
        avg_cpu_cores=float(avg_cpu),
        p95_cpu_cores=float(p95_cpu),
        avg_mem_gib=float(avg_mem),
        p95_mem_gib=float(p95_mem),
        cpu_limit_cores=cpu_limit,
        mem_limit_gib=mem_limit,
        cpu_utilization_pct=cpu_utilization,
        mem_utilization_pct=mem_utilization,
        rps_per_core=rps_per_core,
        core_seconds_per_1000_req=core_seconds_per_1000_req,
        mem_gib_per_1000_rps=mem_gib_per_1000_rps,
        service_breakdown=service_metrics_list
    )
