"""Unified CLI entrypoint supporting k6, datadog, and consolidated reporting subcommands."""

from __future__ import annotations

import sys
import hashlib
import argparse
import logging
from pathlib import Path

from report_generator.consolidate import (
    load_runs_config,
    compile_consolidated_dataset,
    generate_consolidated_plots,
)

# Suppress matplotlib font manager warnings about missing semibold fonts
logging.getLogger("matplotlib").setLevel(logging.ERROR)


def k6_main():
    """Legacy entrypoint for k6-report-generator."""
    from report_generator.k6.cli import main as k6_cli_main
    k6_cli_main()


def datadog_main():
    """Legacy entrypoint for datadog-reporter."""
    from report_generator.datadog.cli import main as datadog_cli_main
    datadog_cli_main()


def _runs_content_hash(runs: dict[str, str]) -> str:
    """Compute a short, stable content hash from the sorted run ID values.

    The hash is derived from the *values* of the ``[consolidation.runs]`` mapping,
    sorted deterministically, so that any change to any run ID produces a different
    hash — and the same combination always produces the same hash regardless of key
    ordering in the TOML file.

    Returns the first 8 hexadecimal characters of the SHA-256 digest.
    """
    # Sort by key to ensure determinism regardless of TOML order
    canonical = "\n".join(f"{k}={v}" for k, v in sorted(runs.items()))
    return hashlib.sha256(canonical.encode()).hexdigest()[:8]


def _resolve_consolidated_dir(output_parent: Path, runs: dict[str, str]) -> tuple[Path, bool]:
    """Resolve the output directory for consolidated charts.

    Derives a deterministic directory name of the form
    ``consolidated-{8char_hash}`` based on the content of the run ID mapping.

    Returns:
        A tuple of ``(output_dir, already_exists)`` where *already_exists* is
        ``True`` when the directory already exists and contains at least one file,
        meaning charts were previously generated for this exact combination of run IDs.
    """
    content_hash = _runs_content_hash(runs)
    output_dir = output_parent / f"consolidated-{content_hash}"
    already_exists = output_dir.exists() and any(output_dir.iterdir())
    return output_dir, already_exists


def consolidate_main():
    """Consolidation CLI runner."""
    parser = argparse.ArgumentParser(
        description="Consolidate benchmark results and resource metrics across runs."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("report-generator.toml"),
        help="Path to report-generator.toml config file",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=None,
        help="Local cache directory for datasets",
    )
    parser.add_argument(
        "--s3-bucket",
        type=str,
        default="skripsi-benchmark-results",
        help="AWS S3 bucket name",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory where consolidated charts will be saved. "
            "When omitted, an auto-generated directory "
            "``consolidated-{hash}`` is used under output_parent from config. "
            "If the hash-based directory already exists the run is skipped."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        default=False,
        help="Force regeneration even if the hash-based output directory already exists.",
    )

    args = parser.parse_args()

    if not args.config.exists():
        print(f"Error: Config file not found at {args.config}")
        sys.exit(1)

    try:
        import tomllib
        with open(args.config, "rb") as f:
            config = tomllib.load(f)
        output_parent_str = config.get("output_parent", "reports")
        output_parent = Path(output_parent_str)
    except Exception:
        config = {}
        output_parent = Path("reports")

    cache_dir = args.cache_dir if args.cache_dir else output_parent / "cache"

    try:
        runs = load_runs_config(config or args.config)
    except Exception as exc:
        print(f"Error loading config: {exc}")
        sys.exit(1)

    # Resolve output directory.
    # When --output-dir is explicitly provided, bypass the hash-based logic entirely
    # (preserving the previous behaviour for scripted/CI use-cases).
    if args.output_dir is not None:
        output_dir = args.output_dir
        print(f"Using explicit output directory: {output_dir}")
    else:
        output_dir, already_exists = _resolve_consolidated_dir(output_parent, runs)
        if already_exists and not args.force:
            print(
                f"Consolidated output for this run ID combination already exists:\n"
                f"  {output_dir}\n"
                f"\nThe run ID combination in [consolidation.runs] has not changed —\n"
                f"skipping chart generation to avoid overwriting existing results.\n"
                f"To force regeneration, pass --force."
            )
            sys.exit(0)
        print(f"Consolidated output directory: {output_dir}")

    failed = False

    # 1. Compile k6 results
    print("Compiling k6 consolidated results...")
    try:
        k6_df = compile_consolidated_dataset(
            runs=runs,
            filename="master-results.csv",
            cache_dir=cache_dir,
            s3_bucket=args.s3_bucket,
        )
        if not k6_df.empty:
            print("Generating consolidated k6 charts...")
            generate_consolidated_plots(k6_df, output_dir, metric_type="k6")
        else:
            print("Warning: No k6 results compiled.")
    except Exception as exc:
        print(f"Error compiling or plotting k6 results: {exc}")
        failed = True

    # 2. Compile Datadog resource summary
    print("Compiling Datadog consolidated resource summary...")
    try:
        dd_df = compile_consolidated_dataset(
            runs=runs,
            filename="tables/resource-summary.csv",
            cache_dir=cache_dir,
            s3_bucket=args.s3_bucket,
        )
        if not dd_df.empty:
            print("Generating consolidated Datadog resource charts...")
            generate_consolidated_plots(dd_df, output_dir, metric_type="datadog")
        else:
            print("Warning: No Datadog resource summary compiled.")
    except Exception as exc:
        print(f"Error compiling or plotting Datadog results: {exc}")
        failed = True

    # 3. Create or update symlink 'consolidated' pointing to 'output_dir'
    symlink_path = output_parent / "consolidated"
    try:
        if symlink_path.is_symlink():
            print(f"Removing existing symlink '{symlink_path}'...")
            symlink_path.unlink()
        elif symlink_path.exists():
            if symlink_path.is_dir():
                import time
                backup_path = output_parent / f"consolidated-backup-{int(time.time())}"
                print(f"Moving existing normal directory '{symlink_path}' to '{backup_path}'...")
                symlink_path.rename(backup_path)
            else:
                symlink_path.unlink()

        # Create relative symlink
        try:
            relative_target = output_dir.relative_to(output_parent)
        except ValueError:
            import os
            try:
                relative_target = os.path.relpath(output_dir, output_parent)
            except ValueError:
                relative_target = output_dir.resolve()
        print(f"Creating symlink: {symlink_path} -> {relative_target}")
        symlink_path.symlink_to(relative_target)
    except Exception as exc:
        print(f"Warning: Failed to manage symlink '{symlink_path}': {exc}")

    if failed:
        print("Error: One or more consolidation tasks failed. Exiting with non-zero status.")
        sys.exit(1)

    print(f"Consolidation complete. Output charts are in: {output_dir}")



def main():
    """Unified entrypoint with subcommand dispatching."""
    if len(sys.argv) < 2:
        print("Usage: report-generator {k6|datadog|consolidate} [args]")
        sys.exit(1)

    subcommand = sys.argv[1]
    # Slice off the subcommand so that subcommand CLI parsers receive standard arguments
    sys.argv = [sys.argv[0]] + sys.argv[2:]

    if subcommand == "k6":
        k6_main()
    elif subcommand == "datadog":
        datadog_main()
    elif subcommand == "consolidate":
        consolidate_main()
    else:
        # Restore sys.argv in case someone wants to debug
        sys.argv = [sys.argv[0]] + [subcommand] + sys.argv[1:]
        print(f"Unknown subcommand: {subcommand}")
        print("Usage: report-generator {k6|datadog|consolidate} [args]")
        sys.exit(1)


if __name__ == "__main__":
    main()
