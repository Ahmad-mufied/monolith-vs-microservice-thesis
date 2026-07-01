"""Unit tests for the Datadog Resource Efficiency Reporting Tool."""

from __future__ import annotations

from unittest.mock import MagicMock
import pytest

from report_generator.datadog.config import ReporterConfig, ServiceLimit, ModeLimits, LimitsConfig
from report_generator.datadog.cli import DiscoveredAttempt, process_attempt
from report_generator.datadog.datadog_client import DatadogClient, TimeseriesSeries, TimeseriesPoint
from report_generator.datadog.metrics import compute_metrics, AttemptMetrics
from report_generator.datadog.table_images import write_table_images
from report_generator.datadog.tables import generate_resource_summary_table


@pytest.fixture
def mock_config() -> ReporterConfig:
    """Fixture containing standard limits configuration."""
    return ReporterConfig(
        limits=LimitsConfig(
            fixed=ModeLimits(
                monolith=ServiceLimit(cpu_m=7800, mem_mib=15360),
                microservices_ceiling=ServiceLimit(cpu_m=7800, mem_mib=15360),
                microservices={
                    "api-gateway": ServiceLimit(cpu_m=1950, mem_mib=3840),
                    "auth-service": ServiceLimit(cpu_m=1950, mem_mib=3840),
                    "item-service": ServiceLimit(cpu_m=1950, mem_mib=3840),
                    "transaction-service": ServiceLimit(cpu_m=1950, mem_mib=3840),
                }
            ),
            hpa=ModeLimits(
                monolith=ServiceLimit(cpu_m=7800, mem_mib=15360),
                microservices_ceiling=ServiceLimit(cpu_m=7800, mem_mib=15360),
                microservices={
                    "api-gateway": ServiceLimit(cpu_m=975, mem_mib=1920),
                    "auth-service": ServiceLimit(cpu_m=975, mem_mib=1920),
                    "item-service": ServiceLimit(cpu_m=975, mem_mib=1920),
                    "transaction-service": ServiceLimit(cpu_m=975, mem_mib=1920),
                }
            )
        )
    )


def test_compute_metrics_monolith(mock_config: ReporterConfig):
    """Test metric computation for monolith architecture with mocked Datadog client."""
    client = MagicMock(spec=DatadogClient)

    # 1. Mock CPU metrics response: 2 pods, each reporting CPU nanocores
    # pod 1 at timestamp 1716832500 has 1.0G nanocores (1 core), at 1716832510 has 1.2G nanocores
    # pod 2 at timestamp 1716832500 has 0.8G nanocores, at 1716832510 has 1.0G nanocores
    cpu_series = [
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "monolith", "pod": "monolith-p1"},
            points=[
                TimeseriesPoint(timestamp=1716832500.0, value=1.0e9),
                TimeseriesPoint(timestamp=1716832510.0, value=1.2e9)
            ]
        ),
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "monolith", "pod": "monolith-p2"},
            points=[
                TimeseriesPoint(timestamp=1716832500.0, value=0.8e9),
                TimeseriesPoint(timestamp=1716832510.0, value=1.0e9)
            ]
        )
    ]

    # 2. Mock Memory metrics response: 2 pods, each reporting bytes
    # pod 1 has 4 GiB (4294967296 bytes)
    # pod 2 has 2.5 GiB (2684354560 bytes)
    mem_series = [
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "monolith", "pod": "monolith-p1"},
            points=[
                TimeseriesPoint(timestamp=1716832500.0, value=4.0 * (1024**3)),
                TimeseriesPoint(timestamp=1716832510.0, value=4.0 * (1024**3))
            ]
        ),
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "monolith", "pod": "monolith-p2"},
            points=[
                TimeseriesPoint(timestamp=1716832500.0, value=2.5 * (1024**3)),
                TimeseriesPoint(timestamp=1716832510.0, value=2.5 * (1024**3))
            ]
        )
    ]

    # Mock client.query_metrics
    def mock_query(query: str, from_time: int, to_time: int):
        if "cpu" in query:
            return cpu_series
        if "memory" in query:
            return mem_series
        return []

    client.query_metrics.side_effect = mock_query

    # Run calculation
    metrics = compute_metrics(
        client=client,
        config=mock_config,
        architecture="monolith",
        scenario="login",
        target_rps=1000,
        attempt="attempt-01",
        scaling_mode="fixed",
        duration_sec=300.0,
        achieved_rps=995.0,
        successful_requests=298500,
        from_time=1716832500,
        to_time=1716832510
    )

    # 3. Verify values
    # Total CPU at T1: 1.0 + 0.8 = 1.8 cores
    # Total CPU at T2: 1.2 + 1.0 = 2.2 cores
    # Avg CPU cores = (1.8 + 2.2) / 2 = 2.0 cores
    # P95 CPU cores = 1.8 + 0.95 * (2.2 - 1.8) = 2.18 cores
    assert metrics.avg_cpu_cores == pytest.approx(2.0)
    assert metrics.p95_cpu_cores == pytest.approx(2.18)

    # Total Memory at T1/T2: 4.0 + 2.5 = 6.5 GiB
    # Avg Memory = 6.5 GiB
    # P95 Memory = 6.5 GiB
    assert metrics.avg_mem_gib == pytest.approx(6.5)
    assert metrics.p95_mem_gib == pytest.approx(6.5)

    # Limit ceilings
    # Monolith fixed ceiling follows Bab 3 Vultr VKE: 7800m / 15360Mi.
    assert metrics.cpu_limit_cores == pytest.approx(7.8)
    assert metrics.mem_limit_gib == pytest.approx(15.0)

    # Utilization
    assert metrics.cpu_utilization_pct == pytest.approx((2.0 / 7.8) * 100)
    assert metrics.mem_utilization_pct == pytest.approx((6.5 / 15.0) * 100)

    # Derived
    # RPS/Core: 995.0 / 2.0 = 497.5
    # Core-sec / 1000 Req: (2.0 cores * 300 seconds / 298500 req) * 1000 = 2.01
    assert metrics.rps_per_core == pytest.approx(497.5)
    assert metrics.core_seconds_per_1000_req == pytest.approx(2.01005, rel=1e-3)
    assert metrics.mem_gib_per_1000_rps == pytest.approx(6.53266, rel=1e-3)


def test_compute_metrics_microservices(mock_config: ReporterConfig):
    """Test metric computation for microservices architecture with breakdowns and limits."""
    client = MagicMock(spec=DatadogClient)

    # 1. Mock CPU metrics for MSA services:
    # api-gateway has 1 pod with 0.2 cores (0.2e9 nanocores)
    # auth-service has 1 pod with 0.8 cores (0.8e9 nanocores)
    # item-service has 1 pod with 0.4 cores (0.4e9 nanocores)
    # transaction-service has 1 pod with 0.6 cores (0.6e9 nanocores)
    # Total actual CPU = 0.2 + 0.8 + 0.4 + 0.6 = 2.0 cores
    cpu_series = [
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "api-gateway", "pod": "gateway-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=0.2e9)]
        ),
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "auth-service", "pod": "auth-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=0.8e9)]
        ),
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "item-service", "pod": "item-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=0.4e9)]
        ),
        TimeseriesSeries(
            metric="kubernetes.cpu.usage.total",
            tags={"kube_deployment": "transaction-service", "pod": "tx-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=0.6e9)]
        ),
    ]

    # 2. Mock Memory metrics for MSA services:
    # api-gateway has 0.5 GiB
    # auth-service has 2.0 GiB
    # item-service has 1.0 GiB
    # transaction-service has 1.5 GiB
    # Total actual Memory = 0.5 + 2.0 + 1.0 + 1.5 = 5.0 GiB
    mem_series = [
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "api-gateway", "pod": "gateway-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=0.5 * (1024**3))]
        ),
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "auth-service", "pod": "auth-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=2.0 * (1024**3))]
        ),
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "item-service", "pod": "item-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=1.0 * (1024**3))]
        ),
        TimeseriesSeries(
            metric="kubernetes.memory.usage",
            tags={"kube_deployment": "transaction-service", "pod": "tx-pod"},
            points=[TimeseriesPoint(timestamp=1716832500.0, value=1.5 * (1024**3))]
        ),
    ]

    # Mock client.query_metrics
    def mock_query(query: str, from_time: int, to_time: int):
        if "cpu" in query:
            return cpu_series
        if "memory" in query:
            return mem_series
        return []

    client.query_metrics.side_effect = mock_query

    # Run calculation
    metrics = compute_metrics(
        client=client,
        config=mock_config,
        architecture="microservices",
        scenario="create-transaction",
        target_rps=1000,
        attempt="attempt-01",
        scaling_mode="fixed",
        duration_sec=300.0,
        achieved_rps=980.0,
        successful_requests=294000,
        from_time=1716832500,
        to_time=1716832500
    )

    # 3. Verify total metrics
    assert metrics.avg_cpu_cores == pytest.approx(2.0)
    assert metrics.p95_cpu_cores == pytest.approx(2.0)
    assert metrics.avg_mem_gib == pytest.approx(5.0)
    assert metrics.p95_mem_gib == pytest.approx(5.0)

    # MSA architecture-level ceiling follows namespace ResourceQuota.
    assert metrics.cpu_limit_cores == pytest.approx(7.8)
    assert metrics.mem_limit_gib == pytest.approx(15.0)

    # Derived
    # RPS/Core: 980.0 / 2.0 = 490.0
    # Core-sec / 1000 Req: (2.0 cores * 300 seconds / 294000 req) * 1000 = 2.04
    assert metrics.rps_per_core == pytest.approx(490.0)
    assert metrics.core_seconds_per_1000_req == pytest.approx(2.0408, rel=1e-3)
    assert metrics.mem_gib_per_1000_rps == pytest.approx(5.102, rel=1e-3)

    # 4. Verify breakdown details
    breakdown_dict = {s.service_name: s for s in metrics.service_breakdown}
    assert len(breakdown_dict) == 4
    
    # Check API Gateway
    gw = breakdown_dict["api-gateway"]
    assert gw.avg_cpu_cores == pytest.approx(0.2)
    assert gw.avg_mem_gib == pytest.approx(0.5)
    assert gw.cpu_limit_cores == pytest.approx(1.95)
    assert gw.mem_limit_gib == pytest.approx(3.75)
    assert gw.cpu_utilization_pct == pytest.approx((0.2 / 1.95) * 100)
    assert gw.mem_utilization_pct == pytest.approx((0.5 / 3.75) * 100)
    assert gw.avg_replicas == 1.0

    # Check Transaction Service
    tx = breakdown_dict["transaction-service"]
    assert tx.avg_cpu_cores == pytest.approx(0.6)
    assert tx.avg_mem_gib == pytest.approx(1.5)
    assert tx.cpu_limit_cores == pytest.approx(1.95)
    assert tx.mem_limit_gib == pytest.approx(3.75)
    assert tx.cpu_utilization_pct == pytest.approx((0.6 / 1.95) * 100)
    assert tx.mem_utilization_pct == pytest.approx((1.5 / 3.75) * 100)


def test_process_attempt_uses_successful_request_rate(mock_config: ReporterConfig):
    """Datadog efficiency inputs should discount failed k6 requests."""
    client = MagicMock(spec=DatadogClient)
    client.query_metrics.return_value = []

    da = DiscoveredAttempt()
    da.architecture = "monolith"
    da.scenario = "login"
    da.target_rps = 100
    da.attempt = "attempt-01"
    da.scaling_mode = "fixed"
    da.metadata = {
        "duration": "10s",
        "datadog": {
            "time_window_start": "2026-06-07T01:00:00Z",
            "time_window_end": "2026-06-07T01:00:10Z",
        },
    }
    da.summary = {
        "metrics": {
            "http_reqs": {"values": {"rate": 100.0, "count": 1000}},
            "http_req_failed": {"values": {"rate": 0.1}},
        }
    }
    da.datadog_time_window = None

    _, result = process_attempt(da, client, mock_config, {})

    assert result is not None
    metrics, _ = result
    assert metrics.achieved_rps == pytest.approx(90.0)
    assert metrics.successful_requests == 900


def test_resource_summary_uses_bab3_units_and_sorting(mock_config: ReporterConfig):
    metrics = [
        AttemptMetrics(
            architecture="microservices",
            scenario="login",
            target_rps=200,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration_sec=300,
            achieved_rps=190,
            successful_requests=57000,
            avg_cpu_cores=1.2,
            p95_cpu_cores=1.5,
            avg_mem_gib=2.0,
            p95_mem_gib=2.1,
            cpu_limit_cores=7.8,
            mem_limit_gib=15.0,
            cpu_utilization_pct=15.4,
            mem_utilization_pct=13.3,
            rps_per_core=158.3,
            core_seconds_per_1000_req=6.3,
            mem_gib_per_1000_rps=10.8,
        ),
        AttemptMetrics(
            architecture="monolith",
            scenario="login",
            target_rps=100,
            attempt="attempt-01",
            scaling_mode="fixed",
            duration_sec=300,
            achieved_rps=98,
            successful_requests=29400,
            avg_cpu_cores=0.8,
            p95_cpu_cores=1.0,
            avg_mem_gib=1.5,
            p95_mem_gib=1.6,
            cpu_limit_cores=7.8,
            mem_limit_gib=15.0,
            cpu_utilization_pct=10.3,
            mem_utilization_pct=10.0,
            rps_per_core=122.5,
            core_seconds_per_1000_req=8.2,
            mem_gib_per_1000_rps=15.7,
        ),
    ]

    table = generate_resource_summary_table(metrics)

    assert list(table["Target RPS"]) == [100, 200]
    assert "Avg CPU (m)" in table.columns
    assert "Avg Mem (Mi)" in table.columns
    assert table.loc[0, "Avg CPU (m)"] == 800.0
    assert table.loc[0, "Avg Mem (Mi)"] == 1536.0


def test_table_image_generation_creates_pngs(tmp_path, mock_config: ReporterConfig):
    metric = AttemptMetrics(
        architecture="monolith",
        scenario="login",
        target_rps=100,
        attempt="attempt-01",
        scaling_mode="fixed",
        duration_sec=300,
        achieved_rps=98,
        successful_requests=29400,
        avg_cpu_cores=0.8,
        p95_cpu_cores=1.0,
        avg_mem_gib=1.5,
        p95_mem_gib=1.6,
        cpu_limit_cores=7.8,
        mem_limit_gib=15.0,
        cpu_utilization_pct=10.3,
        mem_utilization_pct=10.0,
        rps_per_core=122.5,
        core_seconds_per_1000_req=8.2,
        mem_gib_per_1000_rps=15.7,
    )

    paths = write_table_images([metric], tmp_path)

    assert paths
    for path in paths:
        assert path.suffix == ".png"
        assert path.exists()
        assert path.stat().st_size > 0


# ---------------------------------------------------------------------------
# Tests for resource-baseline env parsing and limits derivation
# ---------------------------------------------------------------------------

from report_generator.datadog.config import _parse_resource_baseline_env, _build_limits_from_baseline  # noqa: E402


class TestParseResourceBaselineEnv:
    """Tests for _parse_resource_baseline_env."""

    def test_valid_env_file(self, tmp_path: Path) -> None:
        """Parses a well-formed env file and returns (cpu_m, mem_mib)."""
        from pathlib import Path as _Path
        env_file = tmp_path / "vultr-resource-baseline.env"
        env_file.write_text(
            "VULTR_APP_CPU_QUOTA=7800m\n"
            "VULTR_APP_MEMORY_QUOTA=15360Mi\n"
            "VULTR_REGION=mia\n"
        )
        result = _parse_resource_baseline_env(env_file)
        assert result == (7800, 15360)

    def test_missing_file_returns_none(self, tmp_path: Path) -> None:
        """Returns None when the file does not exist."""
        result = _parse_resource_baseline_env(tmp_path / "nonexistent.env")
        assert result is None

    def test_missing_quota_keys_returns_none(self, tmp_path: Path) -> None:
        """Returns None when the required keys are absent."""
        env_file = tmp_path / "incomplete.env"
        env_file.write_text("VULTR_REGION=mia\n")
        result = _parse_resource_baseline_env(env_file)
        assert result is None

    def test_plain_integer_values(self, tmp_path: Path) -> None:
        """Accepts plain integer values without unit suffixes."""
        env_file = tmp_path / "plain.env"
        env_file.write_text(
            "VULTR_APP_CPU_QUOTA=4000\n"
            "VULTR_APP_MEMORY_QUOTA=8192\n"
        )
        result = _parse_resource_baseline_env(env_file)
        assert result == (4000, 8192)

    def test_comments_and_blank_lines_ignored(self, tmp_path: Path) -> None:
        """Correctly skips comments and blank lines."""
        env_file = tmp_path / "commented.env"
        env_file.write_text(
            "# This is a comment\n"
            "\n"
            "VULTR_APP_CPU_QUOTA=7800m\n"
            "# Another comment\n"
            "VULTR_APP_MEMORY_QUOTA=15360Mi\n"
        )
        result = _parse_resource_baseline_env(env_file)
        assert result == (7800, 15360)


class TestBuildLimitsFromBaseline:
    """Tests for _build_limits_from_baseline."""

    def test_vultr_active_ceiling(self) -> None:
        """Produces the correct equal-split values for the active Vultr ceiling."""
        limits = _build_limits_from_baseline(7800, 15360)

        # Fixed: monolith gets full ceiling
        assert limits["fixed"]["monolith"] == {"cpu_m": 7800, "mem_mib": 15360}
        assert limits["fixed"]["microservices_ceiling"] == {"cpu_m": 7800, "mem_mib": 15360}

        # Fixed: each service = ceiling / 4
        for svc in ("api-gateway", "auth-service", "item-service", "transaction-service"):
            assert limits["fixed"]["microservices"][svc] == {"cpu_m": 1950, "mem_mib": 3840}

        # HPA: monolith still gets full ceiling
        assert limits["hpa"]["monolith"] == {"cpu_m": 7800, "mem_mib": 15360}

        # HPA: per-pod = fixed per service / 2
        for svc in ("api-gateway", "auth-service", "item-service", "transaction-service"):
            assert limits["hpa"]["microservices"][svc] == {"cpu_m": 975, "mem_mib": 1920}

    def test_four_services_always_present(self) -> None:
        """All four MSA services are always present in both modes."""
        limits = _build_limits_from_baseline(4000, 8192)
        expected_services = {"api-gateway", "auth-service", "item-service", "transaction-service"}
        assert set(limits["fixed"]["microservices"].keys()) == expected_services
        assert set(limits["hpa"]["microservices"].keys()) == expected_services

    def test_fixed_total_matches_ceiling(self) -> None:
        """Sum of fixed per-service CPU limits equals the total ceiling."""
        cpu_m, mem_mib = 8000, 16384
        limits = _build_limits_from_baseline(cpu_m, mem_mib)
        total_cpu = sum(v["cpu_m"] for v in limits["fixed"]["microservices"].values())
        assert total_cpu == cpu_m

    def test_hpa_per_pod_is_half_fixed_service(self) -> None:
        """HPA per-pod limit is exactly half the fixed per-service limit."""
        limits = _build_limits_from_baseline(7800, 15360)
        fixed_cpu = limits["fixed"]["microservices"]["auth-service"]["cpu_m"]
        hpa_cpu = limits["hpa"]["microservices"]["auth-service"]["cpu_m"]
        assert hpa_cpu == fixed_cpu // 2
