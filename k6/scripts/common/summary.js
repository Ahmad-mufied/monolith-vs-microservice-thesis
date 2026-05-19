import {
  RUN_ID,
  ATTEMPT,
  ARCHITECTURE,
  SCENARIO_NAME,
  DATASET,
  DATASET_VERSION,
  BASE_URL,
  K6_PROFILE,
  TARGET_RPS,
  DURATION,
  PRE_ALLOCATED_VUS,
  MAX_VUS,
  IMAGE_TAG,
  GIT_COMMIT,
} from "./config.js";

export function handleSummary(data, options = {}) {
  const summaryPath = __ENV.SUMMARY_PATH || "/results/summary.json";
  const metadataPartialPath = __ENV.METADATA_PARTIAL_PATH || "/results/metadata.partial.json";
  const thresholdsPath = __ENV.THRESHOLDS_PATH || "/results/thresholds.json";
  const optionsPath = __ENV.K6_OPTIONS_PATH || "/results/k6-options.json";
  const metricTags = options.metricTags || null;

  const metadata = {
    run_id: RUN_ID,
    attempt: ATTEMPT,
    architecture: ARCHITECTURE,
    scenario_name: SCENARIO_NAME,
    dataset: DATASET,
    dataset_version: DATASET_VERSION,
    base_url: BASE_URL,
    k6_profile: K6_PROFILE,
    target_rps: TARGET_RPS,
    duration: DURATION,
    pre_allocated_vus: PRE_ALLOCATED_VUS,
    max_vus: MAX_VUS,
    image_tag: IMAGE_TAG,
    git_commit: GIT_COMMIT,
  };

  const k6Options = {
    profile: K6_PROFILE,
    target_rps: TARGET_RPS,
    duration: DURATION,
    pre_allocated_vus: PRE_ALLOCATED_VUS,
    max_vus: MAX_VUS,
  };

  return {
    [summaryPath]: JSON.stringify(data, null, 2),
    [metadataPartialPath]: JSON.stringify(metadata, null, 2),
    [thresholdsPath]: JSON.stringify(thresholdResults(data), null, 2),
    [optionsPath]: JSON.stringify(k6Options, null, 2),
    stdout: summaryLine(data, metricTags),
  };
}

function thresholdResults(data) {
  const results = {};
  const metrics = data && data.metrics ? data.metrics : {};

  for (const [metricName, metric] of Object.entries(metrics)) {
    if (metric && metric.thresholds) {
      results[metricName] = metric.thresholds;
    }
  }

  return results;
}

function parseMetricTags(metricName) {
  const match = metricName.match(/^[^{]+\{(.+)\}$/);

  if (!match) {
    return {};
  }

  return match[1]
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .reduce((tags, entry) => {
      const separatorIndex = entry.indexOf(":");

      if (separatorIndex === -1) {
        return tags;
      }

      const key = entry.slice(0, separatorIndex);
      const value = entry.slice(separatorIndex + 1);
      tags[key] = value;
      return tags;
    }, {});
}

function matchingMetricName(data, metricName, metricTags = null, options = {}) {
  const metrics = data && data.metrics ? data.metrics : {};
  const allowFallback = options.allowFallback !== false;

  if (!metricTags || Object.keys(metricTags).length === 0) {
    return metricName;
  }

  const matches = Object.keys(metrics).filter((candidate) => {
    if (!candidate.startsWith(`${metricName}{`)) {
      return false;
    }

    const candidateTags = parseMetricTags(candidate);

    return Object.entries(metricTags).every(([tagKey, tagValue]) => candidateTags[tagKey] === tagValue);
  });

  if (matches.length > 0) {
    return matches[0];
  }

  return allowFallback ? metricName : null;
}

function metricValue(data, metricName, key, metricTags = null, options = {}) {
  const resolvedMetricName = matchingMetricName(data, metricName, metricTags, options);

  if (!resolvedMetricName) {
    return null;
  }

  try {
    return data.metrics[resolvedMetricName].values[key];
  } catch (_) {
    return null;
  }
}

function summaryLine(data, metricTags = null) {
  const result = {
    http_req_failed_rate: metricValue(data, "http_req_failed", "rate", metricTags),
    http_req_duration_p90: metricValue(data, "http_req_duration", "p(90)", metricTags),
    http_req_duration_p95: metricValue(data, "http_req_duration", "p(95)", metricTags),
    http_reqs_count: metricValue(data, "http_reqs", "count", metricTags, {
      allowFallback: false,
    }),
    iterations_count: metricValue(data, "iterations", "count"),
    checks_rate: metricValue(data, "checks", "rate", metricTags),
    dropped_iterations_count: metricValue(data, "dropped_iterations", "count"),
  };

  return `${JSON.stringify(result, null, 2)}\n`;
}
