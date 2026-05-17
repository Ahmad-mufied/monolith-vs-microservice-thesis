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
export const DURATION = envString("TEST_DURATION", envString("DURATION", "1m"));
export const TIME_UNIT = envString("TIME_UNIT", "1s");

export const VUS = envInt("VUS", 1);
export const PRE_ALLOCATED_VUS = envInt("PRE_ALLOCATED_VUS", 20);
export const MAX_VUS = envInt("MAX_VUS", 100);

export const MAX_ERROR_RATE = envFloat("MAX_ERROR_RATE", 0.01);
export const MIN_CHECK_RATE = envFloat("MIN_CHECK_RATE", 0.99);
export const P90_THRESHOLD_MS = envInt("P90_THRESHOLD_MS", 1000);
export const P95_THRESHOLD_MS = envInt("P95_THRESHOLD_MS", 1500);
export const MAX_DROPPED_ITERATIONS = envInt("MAX_DROPPED_ITERATIONS", 1);

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

export function thresholdConfig() {
  const thresholds = {
    http_req_failed: [`rate<${MAX_ERROR_RATE}`],
    checks: [`rate>${MIN_CHECK_RATE}`],
    http_req_duration: [
      `p(90)<${P90_THRESHOLD_MS}`,
      `p(95)<${P95_THRESHOLD_MS}`,
    ],
  };

  if (MAX_DROPPED_ITERATIONS >= 0) {
    thresholds.dropped_iterations = [`count<=${MAX_DROPPED_ITERATIONS}`];
  }

  return thresholds;
}

export function smokeOptions() {
  return {
    vus: VUS,
    duration: DURATION,
    thresholds: thresholdConfig(),
  };
}

export function benchmarkOptions(name) {
  if (K6_PROFILE === "smoke") {
    return smokeOptions();
  }

  if (K6_PROFILE === "ramp" || K6_PROFILE === "hpa") {
    return {
      scenarios: {
        [name]: {
          executor: "ramping-arrival-rate",
          startRate: envInt("START_RPS", Math.max(1, Math.floor(TARGET_RPS / 10))),
          timeUnit: TIME_UNIT,
          preAllocatedVUs: PRE_ALLOCATED_VUS,
          maxVUs: MAX_VUS,
          stages: parseStages(),
        },
      },
      thresholds: thresholdConfig(),
    };
  }

  return {
    scenarios: {
      [name]: {
        executor: "constant-arrival-rate",
        rate: TARGET_RPS,
        timeUnit: TIME_UNIT,
        duration: DURATION,
        preAllocatedVUs: PRE_ALLOCATED_VUS,
        maxVUs: MAX_VUS,
      },
    },
    thresholds: thresholdConfig(),
  };
}

function parseStages() {
  const raw = envString("RAMP_STAGES_JSON", "");
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed.length > 0) {
        return parsed;
      }
    } catch (_) {
      // fall back to generated stages
    }
  }

  if (K6_PROFILE === "hpa") {
    return [
      { target: Math.max(1, Math.floor(TARGET_RPS * 0.25)), duration: envString("HPA_RAMP_UP_1", "2m") },
      { target: Math.max(1, Math.floor(TARGET_RPS * 0.50)), duration: envString("HPA_RAMP_UP_2", "2m") },
      { target: TARGET_RPS, duration: envString("HPA_RAMP_UP_3", "3m") },
      { target: TARGET_RPS, duration: envString("HPA_HOLD", "5m") },
      { target: 0, duration: envString("HPA_RAMP_DOWN", "1m") },
    ];
  }

  return [
    { target: TARGET_RPS, duration: envString("RAMP_UP_DURATION", "1m") },
    { target: TARGET_RPS, duration: DURATION },
    { target: 0, duration: envString("RAMP_DOWN_DURATION", "30s") },
  ];
}
