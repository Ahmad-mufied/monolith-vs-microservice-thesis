"""Domain-specific exceptions for report generation."""

from __future__ import annotations


class ReportGenerationError(Exception):
    """Base exception for predictable report generation failures."""


class ConfigError(ReportGenerationError):
    """Raised when a report generator config file is invalid."""


class ArtifactDiscoveryError(ReportGenerationError):
    """Raised when artifact folders or object prefixes are invalid."""


class MissingArtifactError(ReportGenerationError):
    """Raised when a required artifact file is missing."""


class InvalidArtifactError(ReportGenerationError):
    """Raised when a discovered artifact cannot be parsed or validated."""
