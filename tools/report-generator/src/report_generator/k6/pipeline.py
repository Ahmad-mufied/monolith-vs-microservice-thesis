"""End-to-end report generation pipeline."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from report_generator.k6.charts import submit_report_charts
from report_generator.k6.exceptions import ArtifactDiscoveryError
from report_generator.k6.models import AttemptMode, GeneratedManifest, ReportGenerationResult
from report_generator.k6.parser import normalize_attempts
from report_generator.k6.sources.local import load_local_attempts
from report_generator.k6.sources.s3 import load_s3_attempts
from report_generator.k6.status_summary import write_status_summary_artifacts
from report_generator.k6.suite_loader import (
    enrich_rows_with_timing,
    load_suite_summary_from_local,
    load_suite_summary_from_s3,
)
from report_generator.k6.table_images import submit_report_table_images
from report_generator.k6.tables import write_report_tables
from report_generator.k6.utils import parse_s3_uri
from report_generator.k6.writer import write_manifest, write_master_results
from concurrent.futures import ProcessPoolExecutor
import os


def generate_report(
    source_type: str,
    input_path: Path | None,
    s3_uri: str | None,
    bucket: str | None,
    prefix: str | None,
    output_path: Path,
    attempt_mode: AttemptMode,
    attempt_filter: str | None = None,
) -> ReportGenerationResult:
    if source_type == "local":
        if input_path is None:
            raise ArtifactDiscoveryError("local source requires an input path")
        run_id, attempts, source_uri = load_local_attempts(input_path, attempt_filter=attempt_filter)
    elif source_type == "s3":
        if s3_uri:
            try:
                bucket, prefix = parse_s3_uri(s3_uri)
            except Exception as exc:
                raise ArtifactDiscoveryError(str(exc)) from exc
        if not bucket or not prefix:
            raise ArtifactDiscoveryError(
                "s3 source requires either --s3-uri or both --bucket and --prefix"
            )
        run_id, attempts, source_uri = load_s3_attempts(
            bucket=bucket, prefix=prefix, attempt_filter=attempt_filter
        )
    else:
        raise ArtifactDiscoveryError(f"unsupported source type: {source_type}")

    rows = normalize_attempts(attempts)

    suite_summary = None
    if source_type == "s3" and bucket and prefix:
        try:
            import boto3

            s3_client = boto3.client("s3")
            suite_summary = load_suite_summary_from_s3(s3_client, bucket, prefix)
        except Exception:
            pass
    elif source_type == "local" and input_path:
        suite_summary = load_suite_summary_from_local(input_path)

    rows = enrich_rows_with_timing(rows, suite_summary)
    timing_count = sum(1 for row in rows if row.case_started_at_utc is not None)

    output_path.mkdir(parents=True, exist_ok=True)
    tables_dir = output_path / "tables"
    table_images_dir = output_path / "table-images"
    charts_dir = output_path / "charts"
    derived_artifact_paths = write_status_summary_artifacts(attempts, output_path)

    master_results = write_master_results(rows, output_path / "master-results.csv")
    table_paths = write_report_tables(rows, tables_dir, attempt_mode)

    max_workers = min(os.cpu_count() or 1, 8)
    with ProcessPoolExecutor(max_workers=max_workers) as executor:
        table_futures = submit_report_table_images(executor, rows, table_images_dir, attempt_mode)
        chart_futures = submit_report_charts(executor, rows, charts_dir, attempt_mode)

        table_image_paths = [f.result() for f in table_futures]
        chart_paths = [f.result() for f in chart_futures]

    manifest = GeneratedManifest(
        run_id=run_id,
        source_type=source_type,  # type: ignore[arg-type]
        source_uri=source_uri,
        generated_at_utc=datetime.now(timezone.utc),
        attempt_count=len(rows),
        architectures=sorted({row.architecture for row in rows}),
        scenarios=sorted({row.scenario for row in rows}),
        scaling_modes=sorted({row.scaling_mode for row in rows}),
        generated_files=[
            str(master_results.relative_to(output_path)),
            *[str(path.relative_to(output_path)) for path in derived_artifact_paths],
            *[str(path.relative_to(output_path)) for path in table_paths],
            *[str(path.relative_to(output_path)) for path in table_image_paths],
            *[str(path.relative_to(output_path)) for path in chart_paths],
        ],
    )
    manifest_path = write_manifest(manifest, output_path / "manifest.json")

    return ReportGenerationResult(
        run_id=run_id,
        source_type=source_type,  # type: ignore[arg-type]
        source_uri=source_uri,
        output_dir=str(output_path),
        attempt_mode=attempt_mode,
        attempt_count=len(rows),
        architectures=manifest.architectures,
        scenarios=manifest.scenarios,
        scaling_modes=manifest.scaling_modes,
        master_results_path=str(master_results),
        manifest_path=str(manifest_path),
        table_paths=[str(path) for path in table_paths],
        table_image_paths=[str(path) for path in table_image_paths],
        chart_paths=[str(path) for path in chart_paths],
        timing_count=timing_count,
    )
