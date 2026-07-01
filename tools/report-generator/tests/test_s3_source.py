from __future__ import annotations

import io
import json
from pathlib import Path

import boto3
from botocore.response import StreamingBody
from botocore.stub import Stubber
import pytest

from report_generator.k6.exceptions import InvalidArtifactError
from report_generator.k6.sources.s3 import list_s3_run_ids, load_s3_attempts
from report_generator.k6.parser import normalize_attempts
from report_generator.k6.utils import parse_s3_uri


def test_s3_source_success(monkeypatch) -> None:
    bucket = "benchmark-results"
    prefix = "experiments/2026-05-27-fixed"
    client = boto3.client(
        "s3",
        region_name="ap-southeast-1",
        aws_access_key_id="testing",
        aws_secret_access_key="testing",
    )
    stubber = Stubber(client)

    object_keys = [
        f"{prefix}/monolith/login/50rps/attempt-01/summary.json",
        f"{prefix}/monolith/login/50rps/attempt-01/metadata.json",
        f"{prefix}/monolith/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/monolith/login/50rps/attempt-01/stdout.log",
        f"{prefix}/microservices/login/50rps/attempt-01/summary.json",
        f"{prefix}/microservices/login/50rps/attempt-01/metadata.json",
        f"{prefix}/microservices/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/microservices/login/50rps/attempt-01/stdout.log",
    ]

    stubber.add_response(
        "list_objects_v2",
        {"Contents": [{"Key": key} for key in object_keys]},
        {"Bucket": bucket, "Prefix": f"{prefix}/"},
    )

    expected_get_order = [
        f"{prefix}/microservices/login/50rps/attempt-01/summary.json",
        f"{prefix}/microservices/login/50rps/attempt-01/metadata.json",
        f"{prefix}/microservices/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/microservices/login/50rps/attempt-01/stdout.log",
        f"{prefix}/monolith/login/50rps/attempt-01/summary.json",
        f"{prefix}/monolith/login/50rps/attempt-01/metadata.json",
        f"{prefix}/monolith/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/monolith/login/50rps/attempt-01/stdout.log",
    ]

    for key in expected_get_order:
        payload = _payload_for_key(key)
        stubber.add_response(
            "get_object",
            {"Body": StreamingBody(io.BytesIO(payload), len(payload))},
            {"Bucket": bucket, "Key": key},
        )

    stubber.activate()
    monkeypatch.setattr("report_generator.k6.sources.s3.boto3.client", lambda *_args, **_kwargs: client)

    run_id, attempts, source_uri = load_s3_attempts(bucket=bucket, prefix=prefix)
    rows = normalize_attempts(attempts)

    assert run_id == "2026-05-27-fixed"
    assert source_uri == f"s3://{bucket}/{prefix}/"
    assert len(rows) == 2
    assert {row.architecture for row in rows} == {"monolith", "microservices"}

    stubber.deactivate()


def test_s3_source_filter(monkeypatch) -> None:
    bucket = "benchmark-results"
    prefix = "experiments/2026-05-27-fixed"
    client = boto3.client(
        "s3",
        region_name="ap-southeast-1",
        aws_access_key_id="testing",
        aws_secret_access_key="testing",
    )
    stubber = Stubber(client)

    object_keys = [
        f"{prefix}/monolith/login/50rps/attempt-01/summary.json",
        f"{prefix}/monolith/login/50rps/attempt-01/metadata.json",
        f"{prefix}/monolith/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/monolith/login/50rps/attempt-01/stdout.log",
        f"{prefix}/monolith/login/50rps/attempt-02/summary.json",
        f"{prefix}/monolith/login/50rps/attempt-02/metadata.json",
        f"{prefix}/monolith/login/50rps/attempt-02/thresholds.json",
        f"{prefix}/monolith/login/50rps/attempt-02/stdout.log",
    ]

    stubber.add_response(
        "list_objects_v2",
        {"Contents": [{"Key": key} for key in object_keys]},
        {"Bucket": bucket, "Prefix": f"{prefix}/"},
    )

    expected_get_order = [
        f"{prefix}/monolith/login/50rps/attempt-01/summary.json",
        f"{prefix}/monolith/login/50rps/attempt-01/metadata.json",
        f"{prefix}/monolith/login/50rps/attempt-01/thresholds.json",
        f"{prefix}/monolith/login/50rps/attempt-01/stdout.log",
    ]

    for key in expected_get_order:
        payload = _payload_for_key(key)
        stubber.add_response(
            "get_object",
            {"Body": StreamingBody(io.BytesIO(payload), len(payload))},
            {"Bucket": bucket, "Key": key},
        )

    stubber.activate()
    monkeypatch.setattr("report_generator.k6.sources.s3.boto3.client", lambda *_args, **_kwargs: client)

    run_id, attempts, source_uri = load_s3_attempts(
        bucket=bucket, prefix=prefix, attempt_filter="attempt-01"
    )
    rows = normalize_attempts(attempts)

    assert run_id == "2026-05-27-fixed"
    assert len(rows) == 1
    assert rows[0].attempt == "attempt-01"

    stubber.deactivate()


def test_parse_s3_uri_success() -> None:
    bucket, prefix = parse_s3_uri("s3://benchmark-results/experiments/2026-05-27-fixed/")

    assert bucket == "benchmark-results"
    assert prefix == "experiments/2026-05-27-fixed"


def test_parse_s3_uri_rejects_empty_prefix() -> None:
    with pytest.raises(InvalidArtifactError):
        parse_s3_uri("s3://benchmark-results")


def test_list_s3_run_ids(monkeypatch) -> None:
    bucket = "benchmark-results"
    client = boto3.client(
        "s3",
        region_name="ap-southeast-1",
        aws_access_key_id="testing",
        aws_secret_access_key="testing",
    )
    stubber = Stubber(client)
    stubber.add_response(
        "list_objects_v2",
        {
            "CommonPrefixes": [
                {"Prefix": "experiments/eks-suite-fixed-002/"},
                {"Prefix": "experiments/eks-suite-fixed-001/"},
            ]
        },
        {"Bucket": bucket, "Prefix": "experiments/", "Delimiter": "/"},
    )
    stubber.activate()
    monkeypatch.setattr("report_generator.k6.sources.s3.boto3.client", lambda *_args, **_kwargs: client)

    run_ids = list_s3_run_ids(bucket, experiments_prefix="experiments", limit=10)

    assert run_ids == ["eks-suite-fixed-002", "eks-suite-fixed-001"]
    stubber.deactivate()


def _payload_for_key(key: str) -> bytes:
    file_name = Path(key).name
    architecture = "microservices" if "/microservices/" in key else "monolith"

    if file_name == "summary.json":
        return json.dumps(
            {
                "metrics": {
                    "http_reqs": {"values": {"count": 15000, "rate": 50.0}},
                    "http_req_duration": {"values": {"p(95)": 180.0}},
                    "http_req_failed": {"values": {"rate": 0.0}},
                    "checks": {"values": {"rate": 1.0}},
                    "dropped_iterations": {"values": {"count": 0}},
                }
            }
        ).encode("utf-8")
    if file_name == "metadata.json":
        return json.dumps(
            {
                "run_id": "2026-05-27-fixed",
                "attempt": "attempt-01",
                "architecture": architecture,
                "scenario_name": "login",
                "target_rps": 50,
                "duration": "5m",
                "dataset_version": "v1",
                "resources": {"autoscaling_mode": "fixed"},
            }
        ).encode("utf-8")
    if file_name == "thresholds.json":
        return json.dumps(
            {
                "thresholds": {
                    "http_req_duration": [{"threshold": "p(95)<1500", "ok": True}]
                }
            }
        ).encode("utf-8")
    return b"k6 run output\n"
