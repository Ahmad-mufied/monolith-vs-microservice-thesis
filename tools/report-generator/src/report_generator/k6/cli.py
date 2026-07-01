"""Command-line entrypoint for k6-report-generator."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from report_generator.k6.config import ReportConfig, load_report_config
from report_generator.k6.exceptions import ReportGenerationError
from report_generator.k6.models import AttemptMode
from report_generator.k6.pipeline import generate_report
from report_generator.k6.sources.s3 import list_s3_run_ids
from report_generator.k6.utils import parse_s3_uri


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="k6-report-generator",
        description="Generate CSV tables and charts from k6 benchmark artifacts.",
    )

    subparsers = parser.add_subparsers(dest="command")

    generate = subparsers.add_parser(
        "generate",
        help="Generate report outputs from local or S3 artifact sources.",
    )
    generate.add_argument(
        "--source",
        choices=("local", "s3"),
        default=None,
        help="Artifact source type.",
    )
    generate.add_argument(
        "--config",
        help="TOML config file containing default S3 bucket and output parent.",
    )
    generate.add_argument(
        "--run-id",
        help="Run ID under the configured S3 experiments prefix.",
    )
    generate.add_argument(
        "--input",
        help="Local input directory for --source local.",
    )
    generate.add_argument(
        "--bucket",
        help="S3 bucket name for --source s3.",
    )
    generate.add_argument(
        "--s3-uri",
        help="Full S3 URI for --source s3, for example s3://bucket/experiments/run-id.",
    )
    generate.add_argument(
        "--prefix",
        help="S3 prefix for --source s3.",
    )
    generate.add_argument(
        "--experiments-prefix",
        help="S3 parent prefix that contains run IDs. Defaults to config or experiments.",
    )
    generate.add_argument(
        "--output",
        help="Output directory for generated reports.",
    )
    generate.add_argument(
        "--output-parent",
        help="Parent output directory. The selected run_id is appended automatically.",
    )
    generate.add_argument(
        "--attempt-mode",
        choices=("latest", "mean", "median"),
        default=None,
        help="Aggregation mode for report tables and charts. master-results.csv remains per-attempt.",
    )
    generate.add_argument(
        "--attempt-filter",
        default=None,
        help="Filter to only process a single attempt (e.g. attempt-01). Use 'all' or 'none' to disable filtering.",
    )

    list_runs = subparsers.add_parser(
        "list-runs",
        help="List available benchmark run IDs from the configured S3 bucket.",
    )
    list_runs.add_argument(
        "--config",
        help="TOML config file containing default S3 bucket and experiments prefix.",
    )
    list_runs.add_argument("--bucket", help="S3 bucket name.")
    list_runs.add_argument(
        "--experiments-prefix",
        help="S3 parent prefix that contains run IDs. Defaults to config or experiments.",
    )
    list_runs.add_argument(
        "--limit",
        type=int,
        default=20,
        help="Maximum number of run IDs to print.",
    )
    return parser


def _determine_source(args: argparse.Namespace, config: ReportConfig) -> str | None:
    """Determine the source type based on CLI arguments and configuration."""
    if args.source is not None:
        return args.source
    if args.input:
        return "local"
    if args.s3_uri or args.bucket or args.prefix or args.run_id or config.s3_bucket:
        return "s3"
    return None


def _validate_local_source(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    """Validate arguments specific to the local source type."""
    if not args.input:
        parser.error("--input is required when --source=local")


def _validate_s3_source(
    parser: argparse.ArgumentParser,
    args: argparse.Namespace,
    config: ReportConfig,
) -> str | None:
    """Validate S3-specific arguments and return the resolved prefix."""
    bucket = args.bucket or config.s3_bucket
    experiments_prefix = (
        args.experiments_prefix
        or config.normalized_s3_experiments_prefix
        or "experiments"
    )

    prefix = args.prefix
    if args.run_id:
        if args.s3_uri or args.prefix:
            parser.error("--run-id cannot be combined with --s3-uri or --prefix")
        prefix = f"{experiments_prefix.strip('/')}/{args.run_id.strip('/')}"

    has_uri = bool(args.s3_uri)
    has_bucket_prefix = bool(bucket and prefix)

    if not has_uri and not has_bucket_prefix:
        if bucket:
            show_available_runs_hint(bucket, experiments_prefix)
        parser.error(
            "--s3-uri, --run-id, or both --bucket and --prefix are required "
            "when --source=s3"
        )
    return prefix


def validate_generate_args(
    parser: argparse.ArgumentParser,
    args: argparse.Namespace,
    config: ReportConfig,
) -> dict[str, object]:
    source = _determine_source(args, config)

    prefix = None
    if source == "local":
        _validate_local_source(parser, args)
    elif source == "s3":
        prefix = _validate_s3_source(parser, args, config)
    elif source is None:
        parser.error("--source, --input, --s3-uri, or --run-id is required")

    attempt_mode: AttemptMode = args.attempt_mode or config.attempt_mode
    attempt_filter: str | None = args.attempt_filter if args.attempt_filter is not None else config.attempt_filter
    if attempt_filter in ("", "all", "none", "None"):
        attempt_filter = None
    output_path = resolve_output_path(args, config, source, prefix)

    return {
        "source_type": source,
        "input_path": Path(args.input) if args.input else None,
        "s3_uri": args.s3_uri,
        "bucket": args.bucket or config.s3_bucket,
        "prefix": prefix,
        "output_path": output_path,
        "attempt_mode": attempt_mode,
        "attempt_filter": attempt_filter,
    }


def resolve_output_path(
    args: argparse.Namespace,
    config: ReportConfig,
    source: str,
    prefix: str | None,
) -> Path:
    if args.output:
        return Path(args.output)

    output_parent = Path(args.output_parent) if args.output_parent else config.output_parent
    if output_parent is None:
        raise ReportGenerationError(
            "--output is required unless output_parent is configured or passed"
        )

    run_id = infer_run_id(args, source, prefix)
    return output_parent / run_id


def infer_run_id(args: argparse.Namespace, source: str, prefix: str | None) -> str:
    if args.run_id:
        return args.run_id.strip("/")
    if source == "local" and args.input:
        return Path(args.input).name
    if args.s3_uri:
        _bucket, parsed_prefix = parse_s3_uri(args.s3_uri)
        return Path(parsed_prefix).name
    if prefix:
        return Path(prefix.strip("/")).name
    raise ReportGenerationError("unable to infer run_id for output directory")


def show_available_runs_hint(bucket: str, experiments_prefix: str) -> None:
    try:
        run_ids = list_s3_run_ids(bucket, experiments_prefix=experiments_prefix, limit=10)
    except ReportGenerationError:
        return

    if not run_ids:
        return

    print("Available run IDs:", file=sys.stderr)
    for run_id in run_ids:
        print(f"  {run_id}", file=sys.stderr)
    print("Pick one with --run-id <run_id>.", file=sys.stderr)


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return 0

    try:
        config = load_report_config(Path(args.config) if args.config else None)

        if args.command == "list-runs":
            return list_runs_command(args, config)

        if args.command != "generate":
            parser.print_help()
            return 0

        options = validate_generate_args(parser, args, config)
        result = generate_report(**options)
    except ReportGenerationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"ERROR: unexpected error: {exc}", file=sys.stderr)
        return 1

    print_success_summary(result)
    return 0


def list_runs_command(args: argparse.Namespace, config: ReportConfig) -> int:
    bucket = args.bucket or config.s3_bucket
    experiments_prefix = (
        args.experiments_prefix or config.normalized_s3_experiments_prefix
    )
    if not bucket:
        raise ReportGenerationError(
            "S3 bucket is required. Set s3_bucket in config or pass --bucket."
        )

    run_ids = list_s3_run_ids(
        bucket,
        experiments_prefix=experiments_prefix,
        limit=args.limit,
    )
    if not run_ids:
        print(f"No run IDs found under s3://{bucket}/{experiments_prefix}/")
        return 0

    print(f"Run IDs under s3://{bucket}/{experiments_prefix}/:")
    for run_id in run_ids:
        print(f"  {run_id}")
    return 0


def print_success_summary(result: object) -> None:
    from report_generator.k6.models import ReportGenerationResult

    if not isinstance(result, ReportGenerationResult):
        return

    scenario_list = ", ".join(result.scenarios)
    scaling_mode_list = ", ".join(result.scaling_modes)
    architecture_list = ", ".join(result.architectures)

    print("Report generation complete.")
    print(f"  run_id       : {result.run_id}")
    print(f"  source       : {result.source_type} ({result.source_uri})")
    print(f"  attempts     : {result.attempt_count}")
    print(f"  architectures: {architecture_list}")
    print(f"  scenarios    : {scenario_list}")
    print(f"  scaling_modes: {scaling_mode_list}")
    print(f"  output_dir   : {result.output_dir}")
    print(f"  attempt_mode : {result.attempt_mode}")
    print(f"  master_csv   : {result.master_results_path}")
    print(f"  manifest     : {result.manifest_path}")
    print(f"  tables       : {len(result.table_paths)} file(s)")
    print(f"  table_images : {len(result.table_image_paths)} file(s)")
    print(f"  charts       : {len(result.chart_paths)} file(s)")
    if result.timing_count > 0:
        print(f"  timing       : {result.timing_count}/{result.attempt_count} attempts with timing data")


if __name__ == "__main__":
    raise SystemExit(main())
