"""Filesystem output helpers."""

from __future__ import annotations

from pathlib import Path


from report_generator.k6.aggregation import rows_to_frame
from report_generator.k6.models import GeneratedManifest, NormalizedRow


def write_master_results(rows: list[NormalizedRow], output_path: Path) -> Path:
    frame = rows_to_frame(rows).sort_values(
        by=["scenario", "scaling_mode", "target_rps", "architecture", "attempt"]
    )
    frame.to_csv(output_path, index=False)
    return output_path


def write_manifest(manifest: GeneratedManifest, output_path: Path) -> Path:
    output_path.write_text(
        manifest.model_dump_json(indent=2),
        encoding="utf-8",
    )
    return output_path
