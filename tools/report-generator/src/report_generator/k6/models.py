"""Typed models for benchmark artifacts and generated reports."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

AttemptMode = Literal["latest", "mean", "median"]

REQUIRED_FILES = ("summary.json", "metadata.json", "thresholds.json", "stdout.log")
OPTIONAL_JSON_FILES = ("result-status.json", "k6-options.json", "datadog-time-window.json")



class AttemptArtifacts(BaseModel):
    """All files associated with a single benchmark attempt."""

    run_id: str
    architecture: str
    scenario: str
    target_rps: int
    attempt: str
    source_type: Literal["local", "s3"]
    source_uri: str
    summary: dict[str, Any]
    metadata: dict[str, Any]
    thresholds: dict[str, Any]
    stdout_text: str
    summary_path: str
    metadata_path: str
    thresholds_path: str
    stdout_path: str
    result_status: dict[str, Any] | None = None
    k6_options: dict[str, Any] | None = None
    datadog_time_window: dict[str, Any] | None = None
    raw_json_gz_path: str | None = None


class NormalizedRow(BaseModel):
    """One reportable row per benchmark attempt."""

    run_id: str
    architecture: str
    scenario: str
    target_rps: int
    attempt: str
    scaling_mode: str
    duration: str
    actual_throughput: float
    successful_throughput: float = 0.0
    throughput_achievement_pct: float = 0.0
    p95_latency_ms: float
    error_rate: float
    dropped_iterations: int
    checks_rate: float
    source_type: Literal["local", "s3"]
    source_uri: str
    summary_path: str
    metadata_path: str
    thresholds_path: str
    git_commit: str | None = None
    image_tag: str | None = None
    dataset_version: str | None = None
    result_status: str | None = None
    case_started_at_utc: str | None = None
    case_finished_at_utc: str | None = None
    timing_source: str | None = None


class SuiteSummary(BaseModel):
    """Parsed _suite/summary.json structure."""

    model_config = ConfigDict(extra="ignore")

    execution_mode: str | None = None
    scaling_mode: str | None = None
    suite_status: str | None = None
    started_at_utc: str | None = None
    finished_at_utc: str | None = None
    cases: list[dict[str, Any]] = Field(default_factory=list)


class GeneratedManifest(BaseModel):
    """Description of generated outputs for one run."""

    run_id: str
    source_type: Literal["local", "s3"]
    source_uri: str
    generated_at_utc: datetime
    attempt_count: int
    architectures: list[str]
    scenarios: list[str]
    scaling_modes: list[str]
    generated_files: list[str] = Field(default_factory=list)


class ReportGenerationResult(BaseModel):
    """High-signal summary returned after a successful generation run."""

    run_id: str
    source_type: Literal["local", "s3"]
    source_uri: str
    output_dir: str
    attempt_mode: AttemptMode
    attempt_count: int
    architectures: list[str]
    scenarios: list[str]
    scaling_modes: list[str]
    master_results_path: str
    manifest_path: str
    table_paths: list[str]
    table_image_paths: list[str]
    chart_paths: list[str]
    timing_count: int = 0
