"""Command-line interface and orchestrator for the Datadog reporting tool."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import urlparse
from typing import Any, Dict, List, Tuple

import boto3
from botocore.exceptions import BotoCoreError, NoCredentialsError, PartialCredentialsError

from report_generator.datadog.config import load_config, ReporterConfig
from report_generator.datadog.datadog_client import DatadogClient
from report_generator.datadog.timing import resolve_attempt_timing
from report_generator.datadog.metrics import compute_metrics, AttemptMetrics
from report_generator.datadog.tables import write_tables
from report_generator.datadog.table_images import write_table_images
from report_generator.datadog.charts import plot_architecture_comparison, plot_msa_breakdown


class DiscoveredAttempt:
    """Contains raw parsed JSON contents and metadata of an attempt."""
    architecture: str
    scenario: str
    target_rps: int
    attempt: str
    scaling_mode: str
    metadata: Dict[str, Any]
    summary: Dict[str, Any]
    datadog_time_window: Dict[str, Any] | None


def parse_s3_uri(uri: str) -> Tuple[str, str]:
    """Parse s3://bucket/key URI into (bucket, prefix)."""
    parsed = urlparse(uri)
    if parsed.scheme != "s3":
        raise ValueError(f"Invalid S3 URI scheme: {uri}")
    return parsed.netloc, parsed.path.lstrip("/")


def parse_rps_dir(name: str) -> int:
    """Parse rps directory name like '1000rps' to integer 1000."""
    cleaned = name.lower().strip()
    if cleaned.endswith("rps"):
        cleaned = cleaned[:-3]
    try:
        return int(cleaned)
    except ValueError as exc:
        raise ValueError(f"Invalid RPS directory name format: {name}") from exc


def load_local_suite_summary(run_path: Path) -> Dict[str, Any] | None:
    """Try to load _suite/summary.json or _arch_suite/summary.json locally."""
    for folder in ("_suite", "_arch_suite"):
        path = run_path / folder / "summary.json"
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except Exception as exc:
                print(f"WARNING: Could not parse local suite summary from {folder}: {exc}", file=sys.stderr)
    return None


def load_s3_suite_summary(s3_client: Any, bucket: str, prefix: str) -> Dict[str, Any] | None:
    """Try to load _suite/summary.json or _arch_suite/summary.json from S3."""
    for folder in ("_suite", "_arch_suite"):
        key = f"{prefix.strip('/')}/{folder}/summary.json"
        try:
            response = s3_client.get_object(Bucket=bucket, Key=key)
            return json.loads(response["Body"].read().decode("utf-8"))
        except Exception:
            continue
    return None


def resolve_scaling_mode(metadata: Dict[str, Any]) -> str:
    """Determine scaling mode from metadata with robust defaults."""
    candidates = (
        metadata.get("scaling_mode"),
        metadata.get("autoscaling_mode"),
        (metadata.get("k8s") or {}).get("scaling_mode"),
        (metadata.get("resources") or {}).get("autoscaling_mode"),
        (metadata.get("resources_configuration") or {}).get("autoscaling_mode"),
        metadata.get("k6_profile"),
        (metadata.get("k6_configuration") or {}).get("profile"),
    )
    for c in candidates:
        if isinstance(c, str) and c.strip():
            val = c.strip().lower()
            if "hpa" in val or "ramp-up" in val or "ramp_up" in val:
                return "hpa"
            if "steady" in val or "fixed" in val or "smoke" in val:
                return "fixed"
    return "fixed"


def discover_local_attempts(run_path: Path, attempt_filter: str | None = None) -> List[DiscoveredAttempt]:
    """Find all attempts in a local run directory."""
    if not run_path.exists() or not run_path.is_dir():
        raise FileNotFoundError(f"Local run directory does not exist or is not a directory: {run_path}")

    attempts: List[DiscoveredAttempt] = []
    
    # Scan for summary.json files
    for summary_path in sorted(run_path.rglob("summary.json")):
        attempt_dir = summary_path.parent
        # Avoid suite-level folders
        if attempt_dir.name == "_suite":
            continue
            
        rel_parts = attempt_dir.relative_to(run_path).parts
        if len(rel_parts) != 4:
            continue

        architecture, scenario, rps_dir, attempt_name = rel_parts
        if attempt_filter and attempt_name != attempt_filter:
            continue
        try:
            target_rps = parse_rps_dir(rps_dir)
        except ValueError:
            continue

        # Load files
        metadata_path = attempt_dir / "metadata.json"
        if not metadata_path.exists():
            print(f"WARNING: Missing metadata.json in {attempt_dir}, skipping...", file=sys.stderr)
            continue

        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"WARNING: Error parsing JSON files in {attempt_dir}: {exc}", file=sys.stderr)
            continue

        # Load optional datadog-time-window
        dd_time_path = attempt_dir / "datadog-time-window.json"
        dd_time = None
        if dd_time_path.exists():
            try:
                dd_time = json.loads(dd_time_path.read_text(encoding="utf-8"))
            except Exception:
                pass

        # Determine scaling mode
        scaling_mode = resolve_scaling_mode(metadata)

        da = DiscoveredAttempt()
        da.architecture = architecture
        da.scenario = scenario
        da.target_rps = target_rps
        da.attempt = attempt_name
        da.scaling_mode = scaling_mode
        da.metadata = metadata
        da.summary = summary
        da.datadog_time_window = dd_time
        attempts.append(da)

    return attempts


def discover_s3_attempts(s3_client: Any, bucket: str, prefix: str, attempt_filter: str | None = None) -> List[DiscoveredAttempt]:
    """Find and download all attempts in an S3 run directory prefix."""
    normalized_prefix = prefix.strip("/")
    paginator = s3_client.get_paginator("list_objects_v2")

    # Map attempt paths to their files
    attempt_files: Dict[str, Dict[str, str]] = {}
    
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=f"{normalized_prefix}/"):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                parts = Path(key).name
                if parts in ("summary.json", "metadata.json", "datadog-time-window.json"):
                    parent_prefix = str(Path(key).parent)
                    attempt_files.setdefault(parent_prefix, {})[parts] = key
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise RuntimeError("AWS credentials are missing or expired.") from exc
    except BotoCoreError as exc:
        raise RuntimeError(f"AWS S3 error listing bucket {bucket}: {exc}") from exc

    attempts: List[DiscoveredAttempt] = []

    for attempt_prefix, files in sorted(attempt_files.items()):
        # relative path from the prefix root
        rel_prefix = attempt_prefix
        if rel_prefix.startswith(normalized_prefix):
            rel_prefix = rel_prefix[len(normalized_prefix):].lstrip("/")
        
        rel_parts = Path(rel_prefix).parts
        if len(rel_parts) != 4:
            continue

        architecture, scenario, rps_dir, attempt_name = rel_parts
        if attempt_filter and attempt_name != attempt_filter:
            continue
        try:
            target_rps = parse_rps_dir(rps_dir)
        except ValueError:
            continue

        if "summary.json" not in files or "metadata.json" not in files:
            continue

        # Download json files
        try:
            summary_obj = s3_client.get_object(Bucket=bucket, Key=files["summary.json"])
            summary = json.loads(summary_obj["Body"].read().decode("utf-8"))

            metadata_obj = s3_client.get_object(Bucket=bucket, Key=files["metadata.json"])
            metadata = json.loads(metadata_obj["Body"].read().decode("utf-8"))
        except Exception as exc:
            print(f"WARNING: Error downloading/parsing artifacts from s3://{bucket}/{attempt_prefix}: {exc}", file=sys.stderr)
            continue

        dd_time = None
        if "datadog-time-window.json" in files:
            try:
                dd_time_obj = s3_client.get_object(Bucket=bucket, Key=files["datadog-time-window.json"])
                dd_time = json.loads(dd_time_obj["Body"].read().decode("utf-8"))
            except Exception:
                pass

        # Determine scaling mode
        scaling_mode = resolve_scaling_mode(metadata)

        da = DiscoveredAttempt()
        da.architecture = architecture
        da.scenario = scenario
        da.target_rps = target_rps
        da.attempt = attempt_name
        da.scaling_mode = scaling_mode
        da.metadata = metadata
        da.summary = summary
        da.datadog_time_window = dd_time
        attempts.append(da)

    return attempts


def build_fallback_timing_index(suite_summary: Dict[str, Any] | None) -> Dict[Tuple[str, str, int], Tuple[str, str]]:
    """Build a lookup index from suite-level _suite/summary.json."""
    index = {}
    if not suite_summary or "cases" not in suite_summary:
        return index

    for case in suite_summary["cases"]:
        scenario = case.get("scenario")
        target_rps = case.get("target_rps")
        if not scenario or not target_rps:
            continue

        case_started = case.get("started_at_utc")
        case_finished = case.get("finished_at_utc")

        # Check sub-architectures
        architectures = case.get("architectures", {})
        for arch_name, arch_timing in architectures.items():
            if isinstance(arch_timing, dict):
                start = arch_timing.get("started_at_utc") or case_started
                finish = arch_timing.get("finished_at_utc") or case_finished
                if start and finish:
                    index[(arch_name, scenario, int(target_rps))] = (start, finish)

        # Standalone mappings
        if "monolith" not in architectures and case.get("monolith_s3_uri"):
            if case_started and case_finished:
                index[("monolith", scenario, int(target_rps))] = (case_started, case_finished)
        if "microservices" not in architectures and case.get("microservices_s3_uri"):
            if case_started and case_finished:
                index[("microservices", scenario, int(target_rps))] = (case_started, case_finished)

    return index


def process_attempt(
    da: DiscoveredAttempt,
    client: DatadogClient,
    config: ReporterConfig,
    fallback_timing_index: dict
) -> Tuple[str, Tuple[AttemptMetrics, dict] | None]:
    # Resolve fallback start/end from suite timing index
    fallback_start, fallback_end = None, None
    fallback_tuple = fallback_timing_index.get((da.architecture, da.scenario, da.target_rps))
    if fallback_tuple:
        fallback_start, fallback_end = fallback_tuple

    # Resolve exact timing window
    try:
        timing = resolve_attempt_timing(
            metadata=da.metadata,
            datadog_time_window=da.datadog_time_window,
            fallback_start=fallback_start,
            fallback_end=fallback_end
        )
    except Exception as exc:
        return f"  WARNING: Skipping {da.architecture} | {da.scenario} | {da.target_rps}rps due to timing resolution failure: {exc}", None

    # Parse metrics from k6 summary JSON
    try:
        metrics_section = da.summary.get("metrics", {})
        http_reqs = metrics_section.get("http_reqs", {})
        
        # Duration
        duration_sec = 300.0
        duration_str = da.metadata.get("duration")
        if duration_str:
            duration_str = duration_str.strip().lower()
            if duration_str.endswith("s"):
                duration_sec = float(duration_str[:-1])
            elif duration_str.endswith("m"):
                duration_sec = float(duration_str[:-1]) * 60.0
            elif duration_str.endswith("h"):
                duration_sec = float(duration_str[:-1]) * 3600.0
            else:
                duration_sec = float(duration_str)

        total_rps = http_reqs.get("values", {}).get("rate") or http_reqs.get("rate")
        total_requests = int(
            http_reqs.get("values", {}).get("count") or http_reqs.get("count") or 0
        )
        failed_metric = metrics_section.get("http_req_failed", {})
        error_rate = (
            failed_metric.get("values", {}).get("rate")
            or failed_metric.get("rate")
            or 0.0
        )
        error_rate = min(max(float(error_rate), 0.0), 1.0)

        if total_rps is None:
            total_rps = total_requests / duration_sec
        else:
            total_rps = float(total_rps)

        successful_requests = round(total_requests * (1.0 - error_rate))
        achieved_rps = total_rps * (1.0 - error_rate)

    except Exception as exc:
        return f"  WARNING: Failed to parse k6 metrics from summary.json for {da.architecture} | {da.scenario} | {da.target_rps}rps: {exc}. Skipping...", None

    # Execute Datadog metric queries
    from_epoch = int(timing.start_time.timestamp())
    to_epoch = int(timing.end_time.timestamp())

    try:
        attempt_metrics = compute_metrics(
            client=client,
            config=config,
            architecture=da.architecture,
            scenario=da.scenario,
            target_rps=da.target_rps,
            attempt=da.attempt,
            scaling_mode=da.scaling_mode,
            duration_sec=duration_sec,
            achieved_rps=achieved_rps,
            successful_requests=successful_requests,
            from_time=from_epoch,
            to_time=to_epoch
        )
        msg = (
            f"Processed attempt: {da.architecture} | {da.scenario} | {da.target_rps}rps | attempt {da.attempt}\n"
            f"  Query time range: {timing.start_time.isoformat()} -> {timing.end_time.isoformat()}\n"
            f"  Calculated avg CPU: {attempt_metrics.avg_cpu_cores:.3f} cores, avg Memory: {attempt_metrics.avg_mem_gib:.3f} GiB"
        )
        return msg, (attempt_metrics, {
            "architecture": da.architecture,
            "scenario": da.scenario,
            "target_rps": da.target_rps,
            "scaling_mode": da.scaling_mode,
            "from_time": from_epoch,
            "to_time": to_epoch
        })
    except Exception as exc:
        err_msg = (
            f"  ERROR executing queries or calculating metrics for {da.architecture} | {da.scenario} | {da.target_rps}rps: {exc}\n"
            f"  Skipping this attempt..."
        )
        return err_msg, None


def process_chart_job(
    key: Tuple[str, int, str],
    arch_times: dict,
    client: DatadogClient,
    charts_path: Path,
    output_path: Path
) -> str:
    scenario, target_rps, scaling_mode = key
    mono_t = arch_times.get("monolith")
    msa_t = arch_times.get("microservices")
    
    msgs = []
    
    # Plot CPU & Memory comparisons over time
    try:
        compare_charts = plot_architecture_comparison(
            client=client,
            scenario=scenario,
            target_rps=target_rps,
            scaling_mode=scaling_mode,
            mono_time=mono_t,
            msa_time=msa_t,
            output_dir=charts_path
        )
        for c in compare_charts:
            msgs.append(f"  Created chart: {c.relative_to(output_path.parent.parent) if len(c.parts) > 2 else c}")
    except Exception as exc:
        msgs.append(f"  WARNING: Failed to generate comparison charts for {scenario} {target_rps}rps: {exc}")

    # Plot microservices service breakdown charts
    if msa_t:
        try:
            breakdown_charts = plot_msa_breakdown(
                client=client,
                scenario=scenario,
                target_rps=target_rps,
                scaling_mode=scaling_mode,
                msa_time=msa_t,
                output_dir=charts_path
            )
            for c in breakdown_charts:
                msgs.append(f"  Created chart: {c.relative_to(output_path.parent.parent) if len(c.parts) > 2 else c}")
        except Exception as exc:
            msgs.append(f"  WARNING: Failed to generate breakdown charts for MSA {scenario} {target_rps}rps: {exc}")
            
    return "\n".join(msgs)


def main() -> None:
    parser = argparse.ArgumentParser(description="Datadog Resource Efficiency Reporting Tool (RQ2)")
    parser.add_argument(
        "--run-dir", "-d",
        help="Local directory or s3:// URI containing the benchmark run results."
    )
    parser.add_argument(
        "--run-id",
        help="Run ID under the configured S3 experiments prefix."
    )
    parser.add_argument(
        "--output-dir", "-o",
        default=None,
        help="Path where Markdown/CSV tables and charts will be written."
    )
    parser.add_argument(
        "--config", "-c",
        help="Path to datadog-reporter.toml configuration file."
    )
    parser.add_argument(
        "--attempt-filter",
        default=None,
        help="Filter to only process a single attempt (e.g. attempt-01). Use 'all' or 'none' to disable filtering."
    )
    
    args = parser.parse_args()

    # 1. Load config
    config_path = Path(args.config) if args.config else None
    config = load_config(config_path)

    # 1b. Resolve run_dir
    if args.run_dir:
        resolved_run_dir = args.run_dir
    elif args.run_id:
        if not config.s3_bucket:
            print("ERROR: --run-id requires s3_bucket to be configured in datadog-reporter.toml.", file=sys.stderr)
            sys.exit(1)
        resolved_run_dir = f"s3://{config.s3_bucket.strip('/')}/{config.s3_experiments_prefix.strip('/')}/{args.run_id.strip('/')}"
    else:
        print("ERROR: Either --run-dir (-d) or --run-id must be specified.", file=sys.stderr)
        sys.exit(1)

    # 1c. Resolve output_parent
    if args.output_dir:
        resolved_output_parent = Path(args.output_dir)
    elif config.output_parent:
        resolved_output_parent = Path(config.output_parent)
    else:
        resolved_output_parent = Path("./reports/resources")

    # 1d. Resolve attempt_filter
    toml_attempt_filter = None
    if config_path and config_path.exists():
        try:
            import tomllib
            with open(config_path, "rb") as f:
                raw_toml = tomllib.load(f)
            toml_attempt_filter = raw_toml.get("attempt_filter") or raw_toml.get("defaults", {}).get("attempt_filter")
        except Exception:
            pass
    attempt_filter = args.attempt_filter if args.attempt_filter is not None else toml_attempt_filter
    if attempt_filter is None:
        attempt_filter = "attempt-01"
    if attempt_filter in ("", "all", "none", "None"):
        attempt_filter = None

    if not config.datadog.api_key or not config.datadog.app_key:
        print("ERROR: Datadog API Key or Application Key is missing.", file=sys.stderr)
        print("Please set DATADOG_API_KEY and DATADOG_APP_KEY environment variables or configure them in datadog-reporter.toml.", file=sys.stderr)
        sys.exit(1)
    print("Datadog credentials: present")

    # 2. Instantiate Datadog client
    client = DatadogClient(
        api_key=config.datadog.api_key,
        app_key=config.datadog.app_key,
        site=config.datadog.site
    )

    print(f"Connecting to Datadog site: {config.datadog.site}")

    # 3. Discover attempts (local vs S3)
    is_s3 = resolved_run_dir.startswith("s3://")
    discovered_attempts: List[DiscoveredAttempt] = []
    fallback_timing_index = {}

    if is_s3:
        try:
            bucket, prefix = parse_s3_uri(resolved_run_dir)
            s3_client = boto3.client("s3")
            print(f"Scanning S3 prefix: s3://{bucket}/{prefix}")
            discovered_attempts = discover_s3_attempts(s3_client, bucket, prefix, attempt_filter=attempt_filter)
            
            # Load suite summary fallback
            suite_summary = load_s3_suite_summary(s3_client, bucket, prefix)
            fallback_timing_index = build_fallback_timing_index(suite_summary)
        except Exception as exc:
            print(f"ERROR reading from S3: {exc}", file=sys.stderr)
            sys.exit(1)
    else:
        run_path = Path(resolved_run_dir)
        print(f"Scanning local path: {run_path.resolve()}")
        try:
            discovered_attempts = discover_local_attempts(run_path, attempt_filter=attempt_filter)
            
            # Load suite summary fallback
            suite_summary = load_local_suite_summary(run_path)
            fallback_timing_index = build_fallback_timing_index(suite_summary)
        except Exception as exc:
            print(f"ERROR reading local path: {exc}", file=sys.stderr)
            sys.exit(1)

    if not discovered_attempts:
        print(f"ERROR: No valid attempts discovered under {resolved_run_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Discovered {len(discovered_attempts)} attempts to query and report.")

    # 4. Process each attempt and query Datadog in parallel
    metrics_list: List[AttemptMetrics] = []
    case_timings_for_charts: List[dict] = []
    failed_attempts: List[str] = []

    from concurrent.futures import ThreadPoolExecutor, as_completed

    print("Querying Datadog metrics in parallel using up to 10 workers...")
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = [
            executor.submit(process_attempt, da, client, config, fallback_timing_index)
            for da in discovered_attempts
        ]
        
        for fut in as_completed(futures):
            try:
                msg, result = fut.result()
                if msg:
                    print(msg)
                if result:
                    attempt_metrics, chart_timing = result
                    metrics_list.append(attempt_metrics)
                    case_timings_for_charts.append(chart_timing)
                else:
                    failed_attempts.append(msg or "attempt failed without details")
            except Exception as e:
                failure = f"Unexpected worker error: {e}"
                failed_attempts.append(failure)
                print(failure, file=sys.stderr)

    if not metrics_list:
        print("ERROR: No resource metrics could be calculated.", file=sys.stderr)
        sys.exit(1)
    if failed_attempts:
        print("ERROR: Some discovered attempts could not be processed:", file=sys.stderr)
        for failure in failed_attempts:
            print(failure, file=sys.stderr)
        sys.exit(1)

    # Extract run_id to group output files
    run_id = None
    if discovered_attempts:
        for da in discovered_attempts:
            if da.metadata and "run_id" in da.metadata:
                run_id = da.metadata["run_id"]
                break
    if not run_id:
        if resolved_run_dir.startswith("s3://"):
            try:
                _, prefix = parse_s3_uri(resolved_run_dir)
                run_id = Path(prefix).name
            except Exception:
                run_id = "unknown-run"
        else:
            run_id = Path(resolved_run_dir).name

    # Sanitize run_id to prevent path traversal
    if run_id:
        run_id = run_id.replace("/", "").replace("\\", "").replace("..", "").strip()
        run_id = Path(run_id).name
    if not run_id or run_id in (".", "..", ""):
        run_id = "unknown-run"

    # 5. Write Report Tables (CSV)
    output_path = resolved_output_parent / run_id
    tables_path = output_path / "tables"
    print(f"Writing tables to: {tables_path.resolve()}")
    generated_tables = write_tables(metrics_list, tables_path)
    for p in generated_tables:
        print(f"  Created: {p.relative_to(output_path.parent.parent) if len(p.parts) > 2 else p}")

    table_images_path = output_path / "table-images"
    print(f"Writing table images to: {table_images_path.resolve()}")
    generated_table_images = write_table_images(metrics_list, table_images_path)
    for p in generated_table_images:
        print(f"  Created: {p.relative_to(output_path.parent.parent) if len(p.parts) > 2 else p}")

    # 6. Generate Timeseries Charts
    charts_path = output_path / "charts"
    print(f"Generating charts under: {charts_path.resolve()}")
    
    # We group timings by (scenario, target_rps, scaling_mode) to compare architectures
    grouped_timings = {}
    for ct in case_timings_for_charts:
        key = (ct["scenario"], ct["target_rps"], ct["scaling_mode"])
        grouped_timings.setdefault(key, {})[ct["architecture"]] = (ct["from_time"], ct["to_time"])

    from concurrent.futures import ThreadPoolExecutor, as_completed

    print("Generating timeseries charts in parallel using up to 10 workers...")
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = [
            executor.submit(process_chart_job, key, arch_times, client, charts_path, output_path)
            for key, arch_times in grouped_timings.items()
        ]
        for fut in as_completed(futures):
            try:
                result_msg = fut.result()
                if result_msg:
                    print(result_msg)
            except Exception as e:
                print(f"Unexpected chart generator error: {e}", file=sys.stderr)

    print("Success! Datadog resource reports generated.")


if __name__ == "__main__":
    main()
