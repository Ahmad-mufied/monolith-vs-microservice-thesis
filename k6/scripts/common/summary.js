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
  thresholdConfig,
} from "./config.js";

export function handleSummary(data) {
  const summaryPath = __ENV.SUMMARY_PATH || "/results/summary.json";
  const metadataPartialPath = __ENV.METADATA_PARTIAL_PATH || "/results/metadata.partial.json";
  const thresholdsPath = __ENV.THRESHOLDS_PATH || "/results/thresholds.json";
  const optionsPath = __ENV.K6_OPTIONS_PATH || "/results/k6-options.json";

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
    [thresholdsPath]: JSON.stringify(thresholdConfig(), null, 2),
    [optionsPath]: JSON.stringify(k6Options, null, 2),
    stdout: summaryLine(data),
  };
}

function metricValue(data, metricName, key) {
  try {
    return data.metrics[metricName].values[key];
  } catch (_) {
    return null;
  }
}

function summaryLine(data) {
  const result = {
    http_req_failed_rate: metricValue(data, "http_req_failed", "rate"),
    http_req_duration_p90: metricValue(data, "http_req_duration", "p(90)"),
    http_req_duration_p95: metricValue(data, "http_req_duration", "p(95)"),
    http_reqs_count: metricValue(data, "http_reqs", "count"),
    iterations_count: metricValue(data, "iterations", "count"),
    checks_rate: metricValue(data, "checks", "rate"),
    dropped_iterations_count: metricValue(data, "dropped_iterations", "count"),
  };

  return `${JSON.stringify(result, null, 2)}\n`;
}
