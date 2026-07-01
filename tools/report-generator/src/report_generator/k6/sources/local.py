"""Local filesystem artifact discovery."""

from __future__ import annotations

import json
from pathlib import Path

from report_generator.k6.exceptions import ArtifactDiscoveryError, InvalidArtifactError, MissingArtifactError
from report_generator.k6.models import AttemptArtifacts, REQUIRED_FILES, OPTIONAL_JSON_FILES
from report_generator.k6.utils import parse_rps_dir

OPTIONAL_PATH_FILES = ("raw.json.gz",)


def _load_json_file(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise InvalidArtifactError(f"malformed JSON in file '{path}': {exc}") from exc


def load_local_attempts(
    run_root: Path,
    attempt_filter: str | None = None,
) -> tuple[str, list[AttemptArtifacts], str]:
    if not run_root.exists():
        raise ArtifactDiscoveryError(f"input path does not exist: {run_root}")
    if not run_root.is_dir():
        raise ArtifactDiscoveryError(f"input path is not a directory: {run_root}")

    run_id = run_root.name
    attempts: list[AttemptArtifacts] = []

    for summary_path in sorted(run_root.rglob("summary.json")):
        attempt_dir = summary_path.parent
        rel_parts = attempt_dir.relative_to(run_root).parts
        if len(rel_parts) != 4:
            continue

        architecture, scenario, rps_dir, attempt = rel_parts
        if attempt_filter and attempt != attempt_filter:
            continue
        target_rps = parse_rps_dir(rps_dir)
        files = {path.name: path for path in attempt_dir.iterdir() if path.is_file()}

        for required in REQUIRED_FILES:
            if required not in files:
                raise MissingArtifactError(
                    f"missing required file '{required}' in attempt {attempt_dir}"
                )

        metadata = _load_json_file(files["metadata.json"])
        summary = _load_json_file(files["summary.json"])
        thresholds = _load_json_file(files["thresholds.json"])
        stdout_text = files["stdout.log"].read_text(encoding="utf-8")

        optional_json = {}
        for file_name in OPTIONAL_JSON_FILES:
            if file_name in files:
                optional_json[file_name] = _load_json_file(files[file_name])

        attempts.append(
            AttemptArtifacts(
                run_id=run_id,
                architecture=architecture,
                scenario=scenario,
                target_rps=target_rps,
                attempt=attempt,
                source_type="local",
                source_uri=str(attempt_dir),
                summary=summary,
                metadata=metadata,
                thresholds=thresholds,
                stdout_text=stdout_text,
                summary_path=str(files["summary.json"]),
                metadata_path=str(files["metadata.json"]),
                thresholds_path=str(files["thresholds.json"]),
                stdout_path=str(files["stdout.log"]),
                result_status=optional_json.get("result-status.json"),
                k6_options=optional_json.get("k6-options.json"),
                datadog_time_window=optional_json.get("datadog-time-window.json"),
                raw_json_gz_path=(
                    str(files["raw.json.gz"]) if "raw.json.gz" in files else None
                ),
            )
        )

    if not attempts:
        raise ArtifactDiscoveryError(
            f"no attempt folders with summary.json found under {run_root}"
        )

    return run_id, attempts, str(run_root)
