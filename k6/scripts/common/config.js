export function envString(name, fallback = "") {
  const value = __ENV[name];
  if (value === undefined || value === null || value === "") {
    return fallback;
  }
  return String(value);
}

export function envInt(name, fallback) {
  const raw = envString(name, String(fallback));
  const parsed = parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function envFloat(name, fallback) {
  const raw = envString(name, String(fallback));
  const parsed = parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function envBool(name, fallback = false) {
  const raw = envString(name, fallback ? "true" : "false").toLowerCase();
  return raw === "true" || raw === "1" || raw === "yes";
}

export function trimTrailingSlash(value) {
  return String(value || "").replace(/\/+$/, "");
}

export const BASE_URL = trimTrailingSlash(envString("BASE_URL", "http://localhost:8080"));

export const K6_PROFILE = envString("K6_PROFILE", "steady");
export const TARGET_RPS = envInt("TARGET_RPS", 1000);
export const TEST_DURATION = envString("TEST_DURATION", "1m");
export const TIME_UNIT = envString("TIME_UNIT", "1s");

export const VUS = envInt("VUS", 1);
export const PRE_ALLOCATED_VUS = envInt("PRE_ALLOCATED_VUS", 20);
export const MAX_VUS = envInt("MAX_VUS", 100);

export const MAX_ERROR_RATE = envFloat("MAX_ERROR_RATE", 0.01);
export const MIN_CHECK_RATE = envFloat("MIN_CHECK_RATE", 0.99);
export const P90_THRESHOLD_MS = envInt("P90_THRESHOLD_MS", 1000);
export const P95_THRESHOLD_MS = envInt("P95_THRESHOLD_MS", 1500);
export const MAX_DROPPED_ITERATIONS = envInt("MAX_DROPPED_ITERATIONS", 1);

// REQUEST_TIMEOUT_MS is the per-request HTTP timeout applied to all k6 http
// calls. It must remain greater than the application-level request deadline
// (APP_REQUEST_TIMEOUT, default 30s) so that the application always times out
// first and the benchmark observes the app's 503 behavior rather than a k6
// client cancellation.
//
// Default k6 behavior is effectively 60s. We keep that as the default here so
// the application remains the first timeout authority, while still allowing a
// tighter override via K6_REQUEST_TIMEOUT_MS when an experiment explicitly
// needs it.
//
// GRACEFUL_STOP is the time k6 waits for in-flight iterations to finish
// after the scenario duration ends. It must be greater than REQUEST_TIMEOUT_MS
// so that HTTP client timeouts always fire before k6 forcefully cancels
// iterations — ensuring the server (not k6) is always the timeout authority.
//
// Timeout precedence with the current defaults:
// GRPC_CALL_TIMEOUT (32s) < APP_REQUEST_TIMEOUT (35s) < REQUEST_TIMEOUT_MS (60s) < GRACEFUL_STOP (65s)
export const GRACEFUL_STOP = envString("K6_GRACEFUL_STOP", "65s");
export const REQUEST_TIMEOUT_MS = envInt("K6_REQUEST_TIMEOUT_MS", 60000);


export const USER_COUNT = envInt("USER_COUNT", 100);
export const USER_EMAIL_PREFIX = envString("USER_EMAIL_PREFIX", "benchmark-user");
export const USER_EMAIL_SEPARATOR = envString("USER_EMAIL_SEPARATOR", "-");
export const USER_EMAIL_PADDING = envInt("USER_EMAIL_PADDING", 3);
export const USER_EMAIL_DOMAIN = envString("USER_EMAIL_DOMAIN", "example.com");
export const USER_PASSWORD = envString("USER_PASSWORD", "Password123!");
export const USERS_FILE = envString("USERS_FILE", "");

export const TOKEN_POOL_SIZE = envInt("TOKEN_POOL_SIZE", 20);
export const ITEM_COUNT = envInt("ITEM_COUNT", 100);
export const ITEM_IDS_FILE = envString("ITEM_IDS_FILE", "");
export const ITEM_ID_NAMESPACE = envString("ITEM_ID_NAMESPACE", "8000");
export const ITEM_LIST_LIMIT = envInt("ITEM_LIST_LIMIT", 100);

export const TRANSACTION_AMOUNT = envInt("TRANSACTION_AMOUNT", 1);
export const OWN_TRANSACTION_LIMIT = envInt("OWN_TRANSACTION_LIMIT", 50);
export const ENRICHED_TRANSACTION_LIMIT = envInt("ENRICHED_TRANSACTION_LIMIT", 50);

export const SYNC_ITEM_COUNT = envInt("SYNC_ITEM_COUNT", 100);
export const SYNC_ITEM_NAME_PREFIX = envString("SYNC_ITEM_NAME_PREFIX", "Benchmark Item");
export const SYNC_ITEM_AVAILABLE_AMOUNT = envInt("SYNC_ITEM_AVAILABLE_AMOUNT", 1000000);
export const SYNC_ITEM_PADDING = envInt("SYNC_ITEM_PADDING", 6);

export const ADMIN_AUTH_TOKEN = envString("ADMIN_AUTH_TOKEN", "");
export const ADMIN_USER_EMAIL = envString("ADMIN_USER_EMAIL", "");
export const ADMIN_USER_PASSWORD = envString("ADMIN_USER_PASSWORD", USER_PASSWORD);

export const RUN_ID = envString("RUN_ID", "local-run");
export const ATTEMPT = envString("ATTEMPT", "attempt-01");
export const ARCHITECTURE = envString("ARCHITECTURE", "unknown");
export const SCENARIO_NAME = envString("SCENARIO_NAME", "unknown");
export const DATASET = envString("DATASET", "benchmark");
export const DATASET_VERSION = envString("DATASET_VERSION", "v1");
export const IMAGE_TAG = envString("IMAGE_TAG", "");
export const GIT_COMMIT = envString("GIT_COMMIT", "");

const SUPPORTED_K6_PROFILES = new Set(["smoke", "steady", "ramp", "ramping-arrival-rate"]);

function assertCondition(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function metricTagFilter(metricTags) {
  if (!metricTags || Object.keys(metricTags).length === 0) {
    return "";
  }

  const parts = Object.entries(metricTags)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}:${value}`);

  return `{${parts.join(",")}}`;
}

export function thresholdConfig(metricTags = null) {
  const tagFilter = metricTagFilter(metricTags);
  const thresholds = {
    [`http_req_failed${tagFilter}`]: [`rate<${MAX_ERROR_RATE}`],
    [`checks${tagFilter}`]: [`rate>${MIN_CHECK_RATE}`],
    [`http_req_duration${tagFilter}`]: [
      `p(90)<${P90_THRESHOLD_MS}`,
      `p(95)<${P95_THRESHOLD_MS}`,
    ],
  };

  if (MAX_DROPPED_ITERATIONS >= 0) {
    thresholds.dropped_iterations = [`count<=${MAX_DROPPED_ITERATIONS}`];
  }

  return thresholds;
}

export function smokeOptions(metricTags = null) {
  return {
    vus: VUS,
    duration: TEST_DURATION,
    thresholds: thresholdConfig(metricTags),
  };
}

export function benchmarkOptions(name, metricTags = null) {
  if (K6_PROFILE === "smoke") {
    return smokeOptions(metricTags);
  }

  if (K6_PROFILE === "ramp" || K6_PROFILE === "ramping-arrival-rate") {
    return {
      scenarios: {
        [name]: {
          executor: "ramping-arrival-rate",
          startRate: envInt("START_RPS", 0),
          timeUnit: TIME_UNIT,
          preAllocatedVUs: PRE_ALLOCATED_VUS,
          maxVUs: MAX_VUS,
          stages: parseStages(),
          gracefulStop: GRACEFUL_STOP,
        },
      },
      thresholds: thresholdConfig(metricTags),
    };
  }

  return {
    scenarios: {
      [name]: {
        executor: "constant-arrival-rate",
        rate: TARGET_RPS,
        timeUnit: TIME_UNIT,
        duration: TEST_DURATION,
        preAllocatedVUs: PRE_ALLOCATED_VUS,
        maxVUs: MAX_VUS,
        gracefulStop: GRACEFUL_STOP,
      },
    },
    thresholds: thresholdConfig(metricTags),
  };
}

export function benchmarkScenarioDefinition(rate, options = {}) {
  assertCondition(Number.isInteger(rate) && rate > 0, `scenario rate must be a positive integer, got ${rate}.`);
  const preAllocatedVUs = options.scaleVusByTargetRps ? scaleCapacity(PRE_ALLOCATED_VUS, rate) : PRE_ALLOCATED_VUS;
  const maxVUs = Math.max(
    preAllocatedVUs,
    options.scaleVusByTargetRps ? scaleCapacity(MAX_VUS, rate) : MAX_VUS
  );

  if (K6_PROFILE === "ramp" || K6_PROFILE === "ramping-arrival-rate") {
    return {
      executor: "ramping-arrival-rate",
      startRate: envInt("START_RPS", 0),
      timeUnit: TIME_UNIT,
      preAllocatedVUs,
      maxVUs,
      stages: parseStagesForTarget(rate),
      gracefulStop: GRACEFUL_STOP,
    };
  }

  return {
    executor: "constant-arrival-rate",
    rate,
    timeUnit: TIME_UNIT,
    duration: TEST_DURATION,
    preAllocatedVUs,
    maxVUs,
    gracefulStop: GRACEFUL_STOP,
  };
}

function scaleCapacity(totalCapacity, targetRps) {
  return Math.max(1, Math.ceil((totalCapacity * targetRps) / TARGET_RPS));
}

function parseStages() {
  return parseStagesForTarget(TARGET_RPS);
}

function parseStagesForTarget(targetRps) {
  const raw = envString("RAMP_STAGES_JSON", "");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed) || parsed.length === 0) {
        throw new Error("RAMP_STAGES_JSON must be a non-empty JSON array.");
      }

      parsed.forEach((stage, index) => validateStage(stage, index, "RAMP_STAGES_JSON"));
      return scaleCustomStages(parsed, targetRps);
    } catch (error) {
      throw new Error(`Invalid RAMP_STAGES_JSON: ${error.message}`);
    }
  }

  const level1 = envInt("RAMP_RPS_LEVEL_1", Math.max(1, Math.floor(targetRps * 0.10)));
  const level2 = envInt("RAMP_RPS_LEVEL_2", Math.max(1, Math.floor(targetRps * 0.50)));
  const level3 = targetRps;

  return [
    // --- LEVEL 1: Baseline (100 RPS) ---
    { target: level1, duration: envString("RAMP_STAGE_1", "2m") },
    { target: level1, duration: envString("HOLD_STAGE_1", "2m") },

    // --- LEVEL 2: Moderate Load (500 RPS) ---
    { target: level2, duration: envString("RAMP_STAGE_2", "2m") },
    { target: level2, duration: envString("HOLD_STAGE_2", "2m") },

    // --- LEVEL 3: Peak / Saturation Point (1.000 RPS) ---
    { target: level3, duration: envString("RAMP_STAGE_3", "2m") },
    { target: level3, duration: envString("HOLD_STAGE_3", "2m") },

    // --- COOLDOWN ---
    { target: 0,      duration: envString("RAMP_DOWN", "1m") },
  ];
}

function validateStage(stage, index, sourceName) {
  assertCondition(stage && typeof stage === "object" && !Array.isArray(stage), `${sourceName}[${index}] must be an object.`);
  assertCondition(Number.isInteger(stage.target) && stage.target >= 0, `${sourceName}[${index}].target must be a non-negative integer.`);
  assertCondition(typeof stage.duration === "string" && stage.duration.trim() !== "", `${sourceName}[${index}].duration must be a non-empty duration string.`);
}

function scaleCustomStages(stages, targetRps) {
  if (targetRps === TARGET_RPS) {
    return stages;
  }

  return stages.map((stage, index) => {
    const numerator = stage.target * targetRps;
    assertCondition(
      numerator % TARGET_RPS === 0,
      `RAMP_STAGES_JSON[${index}].target=${stage.target} cannot be split exactly from TARGET_RPS=${TARGET_RPS} to branch rate=${targetRps}. Use stage targets divisible by the composite split, or omit RAMP_STAGES_JSON for generated stages.`
    );

    return {
      ...stage,
      target: numerator / TARGET_RPS,
    };
  });
}

function validateConfig() {
  assertCondition(SUPPORTED_K6_PROFILES.has(K6_PROFILE), `Unsupported K6_PROFILE '${K6_PROFILE}'. Expected one of: smoke, steady, ramp, ramp-up.`);
  assertCondition(TARGET_RPS > 0, `TARGET_RPS must be > 0, got ${TARGET_RPS}.`);
  assertCondition(PRE_ALLOCATED_VUS > 0, `PRE_ALLOCATED_VUS must be > 0, got ${PRE_ALLOCATED_VUS}.`);
  assertCondition(MAX_VUS >= PRE_ALLOCATED_VUS, `MAX_VUS must be >= PRE_ALLOCATED_VUS (got MAX_VUS=${MAX_VUS}, PRE_ALLOCATED_VUS=${PRE_ALLOCATED_VUS}).`);
  assertCondition(TOKEN_POOL_SIZE > 0, `TOKEN_POOL_SIZE must be > 0, got ${TOKEN_POOL_SIZE}.`);
  assertCondition(USER_COUNT > 0, `USER_COUNT must be > 0, got ${USER_COUNT}.`);
  assertCondition(ITEM_COUNT > 0, `ITEM_COUNT must be > 0, got ${ITEM_COUNT}.`);
  assertCondition(TRANSACTION_AMOUNT > 0, `TRANSACTION_AMOUNT must be > 0, got ${TRANSACTION_AMOUNT}.`);
  assertCondition(ITEM_LIST_LIMIT > 0, `ITEM_LIST_LIMIT must be > 0, got ${ITEM_LIST_LIMIT}.`);
  assertCondition(OWN_TRANSACTION_LIMIT > 0, `OWN_TRANSACTION_LIMIT must be > 0, got ${OWN_TRANSACTION_LIMIT}.`);
  assertCondition(ENRICHED_TRANSACTION_LIMIT > 0, `ENRICHED_TRANSACTION_LIMIT must be > 0, got ${ENRICHED_TRANSACTION_LIMIT}.`);
  assertCondition(MAX_ERROR_RATE >= 0 && MAX_ERROR_RATE <= 1, `MAX_ERROR_RATE must be between 0 and 1, got ${MAX_ERROR_RATE}.`);
  assertCondition(MIN_CHECK_RATE >= 0 && MIN_CHECK_RATE <= 1, `MIN_CHECK_RATE must be between 0 and 1, got ${MIN_CHECK_RATE}.`);
  assertCondition(P90_THRESHOLD_MS > 0, `P90_THRESHOLD_MS must be > 0, got ${P90_THRESHOLD_MS}.`);
  assertCondition(P95_THRESHOLD_MS > 0, `P95_THRESHOLD_MS must be > 0, got ${P95_THRESHOLD_MS}.`);
  assertCondition(REQUEST_TIMEOUT_MS > 0, `K6_REQUEST_TIMEOUT_MS must be > 0, got ${REQUEST_TIMEOUT_MS}.`);
  assertCondition(typeof GRACEFUL_STOP === "string" && GRACEFUL_STOP.trim() !== "", "K6_GRACEFUL_STOP must be a non-empty string.");

  if (K6_PROFILE === "ramp" || K6_PROFILE === "ramp-up" || K6_PROFILE === "hpa") {
    parseStages().forEach((stage, index) => validateStage(stage, index, "generated stages"));
  }
}

validateConfig();
