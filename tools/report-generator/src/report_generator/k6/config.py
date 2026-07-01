"""Configuration file support for the report generator CLI."""

from __future__ import annotations

from pathlib import Path
import tomllib
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from report_generator.k6.exceptions import ConfigError
from report_generator.k6.models import AttemptMode


class ReportConfig(BaseModel):
    """Defaults shared across report generation commands."""

    model_config = ConfigDict(extra="ignore")

    s3_bucket: str | None = None
    s3_experiments_prefix: str = "experiments"
    output_parent: Path | None = None
    attempt_mode: AttemptMode = "latest"
    attempt_filter: str | None = "attempt-01"

    @property
    def normalized_s3_experiments_prefix(self) -> str:
        return self.s3_experiments_prefix.strip("/")


class RawReportConfig(BaseModel):
    """Top-level config file shape.

    The current config intentionally stays flat for everyday use, while still
    allowing grouped TOML sections if the file grows later.
    """

    model_config = ConfigDict(extra="forbid")


    s3_bucket: str | None = None
    s3_experiments_prefix: str | None = None
    output_parent: Path | None = None
    attempt_mode: AttemptMode | None = None
    attempt_filter: str | None = None
    s3: dict[str, Any] = Field(default_factory=dict)
    output: dict[str, Any] = Field(default_factory=dict)
    defaults: dict[str, Any] = Field(default_factory=dict)
    datadog: dict[str, Any] = Field(default_factory=dict)
    limits: dict[str, Any] = Field(default_factory=dict)
    consolidation: dict[str, Any] = Field(default_factory=dict)


def load_report_config(path: Path | None) -> ReportConfig:
    if path is None:
        return ReportConfig()

    if not path.exists():
        raise ConfigError(f"config file does not exist: {path}")
    if not path.is_file():
        raise ConfigError(f"config path is not a file: {path}")

    try:
        raw_data = tomllib.loads(path.read_text(encoding="utf-8"))
        raw = RawReportConfig.model_validate(raw_data)

        # Resolve values with explicit is None checks to preserve empty strings
        s3_bucket = raw.s3_bucket
        if s3_bucket is None:
            s3_bucket = raw.s3.get("bucket")

        s3_experiments_prefix = raw.s3_experiments_prefix
        if s3_experiments_prefix is None:
            s3_experiments_prefix = raw.s3.get("experiments_prefix")
        if s3_experiments_prefix is None:
            s3_experiments_prefix = "experiments"

        output_parent = raw.output_parent
        if output_parent is None:
            output_parent = raw.output.get("parent")
        if output_parent is not None:
            output_parent = Path(output_parent)

        attempt_mode = raw.attempt_mode
        if attempt_mode is None:
            attempt_mode = raw.defaults.get("attempt_mode")
        if attempt_mode is None:
            attempt_mode = "latest"

        attempt_filter = raw.attempt_filter
        if attempt_filter is None:
            attempt_filter = raw.defaults.get("attempt_filter")
        if attempt_filter is None:
            attempt_filter = "attempt-01"

        return ReportConfig(
            s3_bucket=s3_bucket,
            s3_experiments_prefix=s3_experiments_prefix,
            output_parent=output_parent,
            attempt_mode=attempt_mode,
            attempt_filter=attempt_filter,
        )
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML config {path}: {exc}") from exc
    except ValidationError as exc:
        raise ConfigError(f"invalid report config {path}: {exc}") from exc
