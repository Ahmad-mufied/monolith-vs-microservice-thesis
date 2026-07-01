"""Configuration loader for the Datadog Resource Efficiency Reporting Tool."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict
import sys

from pydantic import BaseModel, Field

# Support Python < 3.11 with tomli fallback
try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore


class DatadogConfig(BaseModel):
    site: str = "us5.datadoghq.com"
    api_key: str = ""
    app_key: str = ""


class ServiceLimit(BaseModel):
    cpu_m: float  # CPU limit in millicores (e.g. 2500 for 2.5 cores)
    mem_mib: float  # Memory limit in MiB (e.g. 3456)


class ModeLimits(BaseModel):
    monolith: ServiceLimit
    microservices: Dict[str, ServiceLimit]
    microservices_ceiling: ServiceLimit | None = None


class LimitsConfig(BaseModel):
    fixed: ModeLimits
    hpa: ModeLimits


class ReporterConfig(BaseModel):
    datadog: DatadogConfig = Field(default_factory=DatadogConfig)
    limits: LimitsConfig
    s3_bucket: str | None = None
    s3_experiments_prefix: str = "experiments"
    output_parent: Path | None = None


def _load_env_file(path: Path, override: bool = False) -> None:
    """Helper to parse a key-value env file and set in os.environ."""
    if path.exists():
        try:
            with open(path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip("'\"")
                        if k:
                            if override or k not in os.environ or not os.environ[k].strip():
                                os.environ[k] = v
        except Exception as exc:
            print(f"WARNING: Failed to parse env file {path}: {exc}", file=sys.stderr)


def _parse_resource_baseline_env(baseline_path: Path) -> tuple[int, int] | None:
    """Parse VULTR_APP_CPU_QUOTA and VULTR_APP_MEMORY_QUOTA from a resource baseline env file.

    Returns (cpu_m, mem_mib) if both values are found and valid, otherwise None.
    The CPU value is expected in millicores notation (e.g. "7800m") and memory in
    MiB notation (e.g. "15360Mi"). Plain integers are also accepted.
    """
    if not baseline_path.exists():
        return None

    kv: dict[str, str] = {}
    try:
        with open(baseline_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip().strip("'\"")
    except Exception as exc:
        print(
            f"WARNING: Failed to read resource baseline env {baseline_path}: {exc}",
            file=sys.stderr,
        )
        return None

    cpu_raw = kv.get("VULTR_APP_CPU_QUOTA")
    mem_raw = kv.get("VULTR_APP_MEMORY_QUOTA")
    if not cpu_raw or not mem_raw:
        return None

    try:
        # Strip units: "7800m" -> 7800, "15360Mi" -> 15360
        cpu_m = int(cpu_raw.rstrip("m").strip())
        mem_mib = int(mem_raw.rstrip("i").rstrip("M").strip())
        return cpu_m, mem_mib
    except ValueError as exc:
        print(
            f"WARNING: Could not parse CPU/memory quota from {baseline_path}: {exc}",
            file=sys.stderr,
        )
        return None


def _build_limits_from_baseline(cpu_m: int, mem_mib: int) -> dict:
    """Derive the full limits dict from an architecture ceiling using equal-split.

    Fixed mode: each of the 4 MSA services receives ceiling / 4.
    HPA mode: each pod baseline is ceiling / 16 (= ceiling / 4 / 4), matching
    the rule: 4 services x maxReplicas 5 x half-ceiling-per-pod = ceiling.
    Concretely, per-pod HPA limit = ceiling / 4 / 2 = ceiling / 8 (one pod at
    50 % CPU headroom for autoscaling headroom, matching the active Vultr design).
    """
    n_services = 4
    cpu_per_service_fixed = cpu_m // n_services        # 1950 for 7800
    mem_per_service_fixed = mem_mib // n_services      # 3840 for 15360

    # HPA per-pod: half the fixed per-service ceiling (leaves room to scale to 2x)
    cpu_per_pod_hpa = cpu_per_service_fixed // 2       # 975 for 7800
    mem_per_pod_hpa = mem_per_service_fixed // 2       # 1920 for 15360

    return {
        "fixed": {
            "monolith": {"cpu_m": cpu_m, "mem_mib": mem_mib},
            "microservices_ceiling": {"cpu_m": cpu_m, "mem_mib": mem_mib},
            "microservices": {
                "api-gateway":          {"cpu_m": cpu_per_service_fixed, "mem_mib": mem_per_service_fixed},
                "auth-service":         {"cpu_m": cpu_per_service_fixed, "mem_mib": mem_per_service_fixed},
                "item-service":         {"cpu_m": cpu_per_service_fixed, "mem_mib": mem_per_service_fixed},
                "transaction-service":  {"cpu_m": cpu_per_service_fixed, "mem_mib": mem_per_service_fixed},
            },
        },
        "hpa": {
            "monolith": {"cpu_m": cpu_m, "mem_mib": mem_mib},
            "microservices_ceiling": {"cpu_m": cpu_m, "mem_mib": mem_mib},
            "microservices": {
                "api-gateway":          {"cpu_m": cpu_per_pod_hpa, "mem_mib": mem_per_pod_hpa},
                "auth-service":         {"cpu_m": cpu_per_pod_hpa, "mem_mib": mem_per_pod_hpa},
                "item-service":         {"cpu_m": cpu_per_pod_hpa, "mem_mib": mem_per_pod_hpa},
                "transaction-service":  {"cpu_m": cpu_per_pod_hpa, "mem_mib": mem_per_pod_hpa},
            },
        },
    }


def load_config(config_path: Path | None = None) -> ReporterConfig:
    """Load configuration from TOML and environment variables."""
    # Try to load env files to populate os.environ
    package_root = Path(__file__).resolve().parents[3]
    repo_root = Path(__file__).resolve().parents[5]
    _load_env_file(Path.cwd() / ".env", override=True)
    _load_env_file(package_root / ".env", override=True)
    _load_env_file(repo_root / "env" / "datadog.shared.env", override=False)

    # Find default config path
    if config_path is None:
        # Check current working directory, then script directory
        cwd_config = Path.cwd() / "datadog-reporter.toml"
        script_config = Path(__file__).parent.parent.parent / "datadog-reporter.toml"
        if cwd_config.exists():
            config_path = cwd_config
        elif script_config.exists():
            config_path = script_config

    raw_data: dict[str, Any] = {}
    if config_path and config_path.exists():
        try:
            with open(config_path, "rb") as f:
                raw_data = tomllib.load(f)
        except Exception as exc:
            print(f"WARNING: Failed to parse config file {config_path}: {exc}", file=sys.stderr)

    # Apply structure defaults if empty — prefer live measurement from
    # vultr-resource-baseline.env (the same source used by the Kubernetes
    # manifest renderer) so that changing the node spec only requires updating
    # one file instead of two.  Fall back to the hardcoded Vultr VKE ceiling
    # (7800m / 15360Mi) only when the env file cannot be located or parsed.
    if "limits" not in raw_data:
        # Search for vultr-resource-baseline.env relative to repo root.
        # Candidates: current working directory, then up to four parent levels.
        _baseline: tuple[int, int] | None = None
        _baseline_candidates = [
            Path.cwd() / "env" / "vultr-resource-baseline.env",
            Path(__file__).parents[5] / "env" / "vultr-resource-baseline.env",
            Path(__file__).parents[4] / "env" / "vultr-resource-baseline.env",
            Path(__file__).parents[3] / "env" / "vultr-resource-baseline.env",
        ]
        for _candidate in _baseline_candidates:
            _baseline = _parse_resource_baseline_env(_candidate)
            if _baseline is not None:
                break

        if _baseline is not None:
            _cpu_m, _mem_mib = _baseline
            raw_data["limits"] = _build_limits_from_baseline(_cpu_m, _mem_mib)
        else:
            # Hard-coded fallback: Vultr VKE active benchmark ceiling (2026-06-11).
            print(
                "WARNING: vultr-resource-baseline.env not found; "
                "using hardcoded Vultr VKE ceiling (7800m / 15360Mi). "
                "Run `make vultr-measure-resource-baseline` to generate it.",
                file=sys.stderr,
            )
            raw_data["limits"] = _build_limits_from_baseline(7800, 15360)

    # Resolve s3_bucket
    s3_bucket = raw_data.get("s3_bucket")
    if not s3_bucket and "s3" in raw_data and isinstance(raw_data["s3"], dict):
        s3_bucket = raw_data["s3"].get("bucket")
    
    # Resolve s3_experiments_prefix
    s3_experiments_prefix = raw_data.get("s3_experiments_prefix")
    if not s3_experiments_prefix and "s3" in raw_data and isinstance(raw_data["s3"], dict):
        s3_experiments_prefix = raw_data["s3"].get("experiments_prefix")
    if not s3_experiments_prefix:
        s3_experiments_prefix = "experiments"
        
    # Resolve output_parent
    output_parent = raw_data.get("output_parent")
    if not output_parent and "output" in raw_data and isinstance(raw_data["output"], dict):
        output_parent = raw_data["output"].get("parent")

    raw_data["s3_bucket"] = s3_bucket
    raw_data["s3_experiments_prefix"] = s3_experiments_prefix
    if output_parent:
        raw_data["output_parent"] = output_parent

    config = ReporterConfig.model_validate(raw_data)

    # Override Datadog API/APP credentials from environment variables
    # Check both DATADOG_* and DD_* styles
    api_key = (
        os.environ.get("DATADOG_API_KEY")
        or os.environ.get("DD_API_KEY")
        or config.datadog.api_key
    )
    app_key = (
        os.environ.get("DATADOG_APP_KEY")
        or os.environ.get("DD_APP_KEY")
        or config.datadog.app_key
    )
    site = (
        os.environ.get("DATADOG_SITE")
        or os.environ.get("DD_SITE")
        or config.datadog.site
    )

    config.datadog.api_key = api_key
    config.datadog.app_key = app_key
    config.datadog.site = site

    return config
