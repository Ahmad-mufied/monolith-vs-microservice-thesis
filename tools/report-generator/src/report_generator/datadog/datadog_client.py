"""Datadog API Client for querying time-series metrics."""

from __future__ import annotations

import time
from typing import Dict, List
import requests

from pydantic import BaseModel, Field


class TimeseriesPoint(BaseModel):
    timestamp: float  # epoch seconds
    value: float | None


class TimeseriesSeries(BaseModel):
    metric: str
    tags: Dict[str, str] = Field(default_factory=dict)
    points: List[TimeseriesPoint] = Field(default_factory=list)


ALLOWED_SITES = {
    "datadoghq.com",
    "datadoghq.eu",
    "us3.datadoghq.com",
    "us5.datadoghq.com",
    "ap1.datadoghq.com",
    "ap2.datadoghq.com",
    "ddog-gov.com",
    "us2.ddog-gov.com",
}


class DatadogClient:
    """Simple requests-based Datadog client for metric queries."""

    def __init__(self, api_key: str, app_key: str, site: str = "us5.datadoghq.com"):
        if not api_key:
            raise ValueError("Datadog API Key (DATADOG_API_KEY / DD_API_KEY) is required.")
        if not app_key:
            raise ValueError("Datadog Application Key (DATADOG_APP_KEY / DD_APP_KEY) is required.")
        
        clean_site = site.strip().lower()
        if clean_site not in ALLOWED_SITES:
            raise ValueError(
                f"Invalid Datadog site: {site!r}. Must be one of: {', '.join(sorted(ALLOWED_SITES))}"
            )
        
        self.api_key = api_key
        self.app_key = app_key
        self.site = clean_site
        self.base_url = f"https://api.{self.site}"

    def query_metrics(
        self, query: str, from_time: int, to_time: int
    ) -> List[TimeseriesSeries]:
        """Query Datadog timeseries metrics for a given time window (epoch seconds)."""
        url = f"{self.base_url}/api/v1/query"
        headers = {
            "Content-Type": "application/json",
            "DD-API-KEY": self.api_key,
            "DD-APPLICATION-KEY": self.app_key,
        }
        params = {
            "from": from_time,
            "to": to_time,
            "query": query,
        }

        # Robust API requests with retry and backoff (no silent errors)
        max_retries = 3
        backoff_sec = 2.0
        response = None
        last_exc = None

        for attempt in range(max_retries + 1):
            if attempt > 0:
                time.sleep(backoff_sec)
                backoff_sec *= 2.0

            try:
                response = requests.get(url, headers=headers, params=params, timeout=30)
                if response.status_code in (429, 500, 502, 503, 504):
                    if attempt < max_retries:
                        continue
                break
            except requests.exceptions.RequestException as exc:
                last_exc = exc
                if attempt < max_retries:
                    continue
                raise RuntimeError(f"Datadog API request failed network connection after {max_retries} retries: {exc}") from exc

        if response is None:
            raise RuntimeError(f"Datadog API request failed network connection: {last_exc}")

        if response.status_code != 200:
            err_msg = f"Datadog API returned HTTP {response.status_code}"
            try:
                err_json = response.json()
                if "errors" in err_json:
                    err_msg += f" - Errors: {err_json['errors']}"
            except Exception:
                err_msg += f" - Response: {response.text[:200]}"
            raise RuntimeError(err_msg)

        data = response.json()
        series_list: List[TimeseriesSeries] = []

        raw_series = data.get("series", [])
        for item in raw_series:
            metric_name = item.get("metric", "")
            
            # Parse tag set into a key-value dictionary
            tags: Dict[str, str] = {}
            for tag in item.get("tag_set", []):
                if ":" in tag:
                    k, v = tag.split(":", 1)
                    tags[k] = v
                else:
                    tags[tag] = "true"

            # Parse points: points in API are returned as list of [timestamp_ms, value]
            points: List[TimeseriesPoint] = []
            for pt in item.get("pointlist", []):
                if len(pt) >= 2:
                    ts_ms, val = pt[0], pt[1]
                    # Datadog sometimes returns None for empty buckets
                    points.append(
                        TimeseriesPoint(
                            timestamp=ts_ms / 1000.0,
                            value=float(val) if val is not None else None
                        )
                    )

            series_list.append(
                TimeseriesSeries(metric=metric_name, tags=tags, points=points)
            )

        return series_list
