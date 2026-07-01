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

    model_config = ConfigDict(extra="ignore")


    s3_bucket: str | None = None
    s3_experiments_prefix: str | None = None
    output_parent: Path | None = None
    attempt_mode: AttemptMode | None = None
    attempt_filter: str | None = None
    s3: dict[str, Any] = Field(default_factory=dict)
    output: dict[str, Any] = Field(default_factory=dict)
    defaults: dict[str, Any] = Field(default_factory=dict)


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
        return ReportConfig(
            s3_bucket=raw.s3_bucket or raw.s3.get("bucket"),
            s3_experiments_prefix=(
                raw.s3_experiments_prefix
                or raw.s3.get("experiments_prefix")
                or "experiments"
            ),
            output_parent=raw.output_parent or raw.output.get("parent"),
            attempt_mode=raw.attempt_mode or raw.defaults.get("attempt_mode") or "latest",
            attempt_filter=raw.attempt_filter or raw.defaults.get("attempt_filter") or "attempt-01",
        )
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML config {path}: {exc}") from exc
    except ValidationError as exc:
        raise ConfigError(f"invalid report config {path}: {exc}") from exc
