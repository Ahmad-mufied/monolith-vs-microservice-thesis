"""S3 artifact discovery and loading."""

from __future__ import annotations

import io
import json
from pathlib import PurePosixPath
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, NoCredentialsError, PartialCredentialsError

from report_generator.k6.exceptions import ArtifactDiscoveryError, MissingArtifactError
from report_generator.k6.models import AttemptArtifacts, REQUIRED_FILES, OPTIONAL_JSON_FILES
from report_generator.k6.utils import parse_rps_dir


_S3_AUTH_HINT = (
    "AWS credentials are missing or expired. "
    "Run `aws login` or configure credentials before retrying."
)


def load_s3_attempts(
    bucket: str,
    prefix: str,
    attempt_filter: str | None = None,
) -> tuple[str, list[AttemptArtifacts], str]:
    normalized_prefix = prefix.strip("/")
    if not normalized_prefix:
        raise ArtifactDiscoveryError("S3 prefix must not be empty")

    run_id = PurePosixPath(normalized_prefix).name
    s3 = _create_s3_client(bucket, normalized_prefix)
    paginator = s3.get_paginator("list_objects_v2")

    attempt_files: dict[str, dict[str, str]] = {}
    found_any = False
    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=f"{normalized_prefix}/"):
            for obj in page.get("Contents", []):
                found_any = True
                key = obj["Key"]
                file_name = PurePosixPath(key).name
                if file_name not in REQUIRED_FILES and file_name not in OPTIONAL_JSON_FILES and file_name != "raw.json.gz":
                    continue
                attempt_prefix = str(PurePosixPath(key).parent)
                if attempt_filter:
                    attempt_dir_name = PurePosixPath(attempt_prefix).name
                    if attempt_dir_name != attempt_filter:
                        continue
                attempt_files.setdefault(attempt_prefix, {})[file_name] = key
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except BotoCoreError as exc:
        _raise_s3_error(exc, bucket, normalized_prefix)

    if not found_any:
        raise ArtifactDiscoveryError(f"no objects found under s3://{bucket}/{normalized_prefix}/")
    if not attempt_files:
        raise ArtifactDiscoveryError(
            f"no attempt artifacts found under s3://{bucket}/{normalized_prefix}/"
        )

    from concurrent.futures import ThreadPoolExecutor

    def _load_single_attempt(attempt_prefix: str, files: dict[str, str]) -> AttemptArtifacts | None:
        rel_parts = PurePosixPath(attempt_prefix).relative_to(normalized_prefix).parts
        if len(rel_parts) != 4:
            return None

        architecture, scenario, rps_dir, attempt = rel_parts
        target_rps = parse_rps_dir(rps_dir)

        for required in REQUIRED_FILES:
            if required not in files:
                raise MissingArtifactError(
                    f"missing required file '{required}' in attempt s3://{bucket}/{attempt_prefix}/"
                )

        summary = _load_s3_json(s3, bucket, files["summary.json"])
        metadata = _load_s3_json(s3, bucket, files["metadata.json"])
        thresholds = _load_s3_json(s3, bucket, files["thresholds.json"])
        stdout_text = _load_s3_text(s3, bucket, files["stdout.log"])

        return AttemptArtifacts(
            run_id=run_id,
            architecture=architecture,
            scenario=scenario,
            target_rps=target_rps,
            attempt=attempt,
            source_type="s3",
            source_uri=f"s3://{bucket}/{attempt_prefix}/",
            summary=summary,
            metadata=metadata,
            thresholds=thresholds,
            stdout_text=stdout_text,
            summary_path=f"s3://{bucket}/{files['summary.json']}",
            metadata_path=f"s3://{bucket}/{files['metadata.json']}",
            thresholds_path=f"s3://{bucket}/{files['thresholds.json']}",
            stdout_path=f"s3://{bucket}/{files['stdout.log']}",
            result_status=_optional_json(s3, bucket, files.get("result-status.json")),
            k6_options=_optional_json(s3, bucket, files.get("k6-options.json")),
            datadog_time_window=_optional_json(
                s3, bucket, files.get("datadog-time-window.json")
            ),
            raw_json_gz_path=(
                f"s3://{bucket}/{files['raw.json.gz']}"
                if "raw.json.gz" in files
                else None
            ),
        )

    attempts: list[AttemptArtifacts] = []
    try:
        with ThreadPoolExecutor(max_workers=16) as executor:
            futures = [
                executor.submit(_load_single_attempt, attempt_prefix, files)
                for attempt_prefix, files in sorted(attempt_files.items())
            ]
            for future in futures:
                res = future.result()
                if res is not None:
                    attempts.append(res)
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except BotoCoreError as exc:
        _raise_s3_error(exc, bucket, normalized_prefix)

    if not attempts:
        raise ArtifactDiscoveryError(
            f"no valid attempt folders found under s3://{bucket}/{normalized_prefix}/"
        )

    return run_id, attempts, f"s3://{bucket}/{normalized_prefix}/"


def list_s3_run_ids(
    bucket: str,
    experiments_prefix: str = "experiments",
    limit: int = 20,
) -> list[str]:
    normalized_prefix = experiments_prefix.strip("/")
    if not normalized_prefix:
        raise ArtifactDiscoveryError("S3 experiments prefix must not be empty")

    s3 = _create_s3_client(bucket, normalized_prefix)
    paginator = s3.get_paginator("list_objects_v2")

    run_ids: set[str] = set()
    try:
        for page in paginator.paginate(
            Bucket=bucket,
            Prefix=f"{normalized_prefix}/",
            Delimiter="/",
        ):
            for common_prefix in page.get("CommonPrefixes", []):
                prefix = str(common_prefix.get("Prefix", "")).strip("/")
                if prefix:
                    run_ids.add(PurePosixPath(prefix).name)

            for obj in page.get("Contents", []):
                key = str(obj.get("Key", ""))
                try:
                    rel_parts = PurePosixPath(key).relative_to(normalized_prefix).parts
                except ValueError:
                    continue
                if rel_parts:
                    run_ids.add(rel_parts[0])
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except BotoCoreError as exc:
        _raise_s3_error(exc, bucket, normalized_prefix)

    return sorted(run_ids, reverse=True)[:limit]


def _create_s3_client(bucket: str, prefix: str) -> Any:
    try:
        from botocore.config import Config
        config = Config(
            connect_timeout=30,
            read_timeout=90,
            retries={
                "max_attempts": 5,
                "mode": "standard"
            }
        )
        return boto3.client("s3", config=config)
    except NoCredentialsError as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except PartialCredentialsError as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except BotoCoreError as exc:
        raise ArtifactDiscoveryError(
            f"unable to create S3 client for s3://{bucket}/{prefix}/: {exc}"
        ) from exc


def _raise_s3_error(exc: BotoCoreError, bucket: str, prefix: str) -> None:
    error_name = type(exc).__name__
    message = str(exc)
    if "expired" in message.lower() or "login" in message.lower():
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    raise ArtifactDiscoveryError(
        f"S3 error accessing s3://{bucket}/{prefix}/: {error_name}: {message}"
    ) from exc


def _load_s3_json(s3: Any, bucket: str, key: str) -> dict[str, Any]:
    payload = _load_s3_bytes(s3, bucket, key)
    return json.loads(payload.decode("utf-8"))


def _load_s3_text(s3: Any, bucket: str, key: str) -> str:
    return _load_s3_bytes(s3, bucket, key).decode("utf-8")


def _optional_json(s3: Any, bucket: str, key: str | None) -> dict[str, Any] | None:
    if not key:
        return None
    return _load_s3_json(s3, bucket, key)


def _load_s3_bytes(s3: Any, bucket: str, key: str) -> bytes:
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"]
        data = body.read()
        if isinstance(data, io.BytesIO):
            return data.getvalue()
        return data
    except (NoCredentialsError, PartialCredentialsError) as exc:
        raise ArtifactDiscoveryError(_S3_AUTH_HINT) from exc
    except BotoCoreError as exc:
        _raise_s3_error(exc, bucket, str(PurePosixPath(key).parent))
