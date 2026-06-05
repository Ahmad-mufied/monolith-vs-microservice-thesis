import {
  benchmarkScenarioDefinition,
  thresholdConfig,
  TARGET_RPS,
  TOKEN_POOL_SIZE,
  ENRICHED_TRANSACTION_LIMIT,
  TRANSACTION_AMOUNT,
  envInt,
} from "./common/config.js";
import { itemIds, users, randomInt, randomUser } from "./common/data.js";
import {
  loginRequest,
  loginSetupAndExtractToken,
  createTransactionRequest,
  enrichedTransactionsRequest,
  expectStatus,
  expectJsonValue,
  requireEnrichedTransactionsReady,
} from "./common/requests.js";
import { handleSummary as baseHandleSummary } from "./common/summary.js";

const WORKLOAD_METRIC_TAGS = {
  request_kind: "workload",
  benchmark_phase: "workload",
};

export function handleSummary(data) {
  return baseHandleSummary(data, { metricTags: WORKLOAD_METRIC_TAGS });
}

const LOGIN_WEIGHT = envInt("CONCURRENT_MIX_LOGIN_WEIGHT", 20);
const CREATE_TRANSACTION_WEIGHT = envInt("CONCURRENT_MIX_CREATE_TRANSACTION_WEIGHT", 40);
const ENRICHED_TRANSACTIONS_WEIGHT = envInt("CONCURRENT_MIX_ENRICHED_TRANSACTIONS_WEIGHT", 40);
const TOTAL_WEIGHT = LOGIN_WEIGHT + CREATE_TRANSACTION_WEIGHT + ENRICHED_TRANSACTIONS_WEIGHT;

const ENDPOINT_TAGS = {
  login: {
    request_kind: "workload",
    benchmark_phase: "workload",
    composite_branch: "login",
    name: "concurrent mixed login",
  },
  createTransaction: {
    request_kind: "workload",
    benchmark_phase: "workload",
    composite_branch: "create-transaction",
    name: "concurrent mixed create transaction",
  },
  enrichedTransactions: {
    request_kind: "workload",
    benchmark_phase: "workload",
    composite_branch: "enriched-transactions",
    name: "concurrent mixed enriched transactions",
  },
};

function assertCondition(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function branchRate(branchName, weight) {
  const numerator = TARGET_RPS * weight;
  assertCondition(
    numerator % TOTAL_WEIGHT === 0,
    `TARGET_RPS=${TARGET_RPS} cannot be split exactly for ${branchName} with branch weight ${weight} and weights ${LOGIN_WEIGHT}/${CREATE_TRANSACTION_WEIGHT}/${ENRICHED_TRANSACTIONS_WEIGHT}. The split requires TARGET_RPS * ${weight} to be divisible by ${TOTAL_WEIGHT}; adjust TARGET_RPS or CONCURRENT_MIX_*_WEIGHT.`
  );

  const rate = numerator / TOTAL_WEIGHT;
  assertCondition(rate > 0, `${branchName} rate must be > 0 after split, got ${rate}.`);
  return rate;
}

assertCondition(LOGIN_WEIGHT > 0, "CONCURRENT_MIX_LOGIN_WEIGHT must be > 0.");
assertCondition(CREATE_TRANSACTION_WEIGHT > 0, "CONCURRENT_MIX_CREATE_TRANSACTION_WEIGHT must be > 0.");
assertCondition(ENRICHED_TRANSACTIONS_WEIGHT > 0, "CONCURRENT_MIX_ENRICHED_TRANSACTIONS_WEIGHT must be > 0.");
assertCondition(TOTAL_WEIGHT > 0, "Concurrent mixed workload weights must sum to > 0.");

const LOGIN_RATE = branchRate("login", LOGIN_WEIGHT);
const CREATE_TRANSACTION_RATE = branchRate("create-transaction", CREATE_TRANSACTION_WEIGHT);
const ENRICHED_TRANSACTIONS_RATE = branchRate("enriched-transactions", ENRICHED_TRANSACTIONS_WEIGHT);
assertCondition(
  LOGIN_RATE + CREATE_TRANSACTION_RATE + ENRICHED_TRANSACTIONS_RATE === TARGET_RPS,
  `Concurrent mixed workload split does not match TARGET_RPS: ${LOGIN_RATE} + ${CREATE_TRANSACTION_RATE} + ${ENRICHED_TRANSACTIONS_RATE} != ${TARGET_RPS}.`
);

export const options = {
  scenarios: {
    login: {
      ...benchmarkScenarioDefinition(LOGIN_RATE, { scaleVusByTargetRps: true }),
      exec: "loginScenario",
      tags: ENDPOINT_TAGS.login,
    },
    create_transaction: {
      ...benchmarkScenarioDefinition(CREATE_TRANSACTION_RATE, { scaleVusByTargetRps: true }),
      exec: "createTransactionScenario",
      tags: ENDPOINT_TAGS.createTransaction,
    },
    enriched_transactions: {
      ...benchmarkScenarioDefinition(ENRICHED_TRANSACTIONS_RATE, { scaleVusByTargetRps: true }),
      exec: "enrichedTransactionsScenario",
      tags: ENDPOINT_TAGS.enrichedTransactions,
    },
  },
  thresholds: thresholdConfig(WORKLOAD_METRIC_TAGS),
};

export function setup() {
  const seededUsers = users();
  const seededItems = itemIds();

  if (seededUsers.length === 0) {
    throw new Error("No seeded users available for concurrent-mixed-workload scenario.");
  }

  if (seededItems.length === 0) {
    throw new Error("No seeded item IDs available for concurrent-mixed-workload scenario.");
  }

  const tokenPool = [];
  const poolSize = Math.min(TOKEN_POOL_SIZE, seededUsers.length);

  for (let i = 0; i < poolSize; i += 1) {
    const auth = loginSetupAndExtractToken(seededUsers[i].email, seededUsers[i].password, `setup concurrent mixed login ${i + 1}`);
    if (auth.token) {
      tokenPool.push(auth.token);
    }
  }

  if (tokenPool.length === 0) {
    throw new Error("No tokens generated for concurrent-mixed-workload scenario.");
  }

  requireEnrichedTransactionsReady(tokenPool[0], {
    label: "concurrent-mixed-workload enriched setup probe",
    requireData: true,
  });

  return {
    tokens: tokenPool,
    itemIds: seededItems,
  };
}

export function loginScenario() {
  const user = randomUser();
  const response = loginRequest(user.email, user.password, {
    tags: ENDPOINT_TAGS.login,
  });

  expectStatus(response, 200, "concurrent mixed login", ENDPOINT_TAGS.login);
  expectJsonValue(response, "data.token", "concurrent mixed login", ENDPOINT_TAGS.login);
}

export function createTransactionScenario(data) {
  const token = data.tokens[randomInt(0, data.tokens.length - 1)];
  const itemId = data.itemIds[randomInt(0, data.itemIds.length - 1)];
  const response = createTransactionRequest(token, itemId, TRANSACTION_AMOUNT, {
    tags: ENDPOINT_TAGS.createTransaction,
  });

  expectStatus(response, 201, "concurrent mixed create transaction", ENDPOINT_TAGS.createTransaction);
  expectJsonValue(response, "data.id", "concurrent mixed create transaction", ENDPOINT_TAGS.createTransaction);
}

export function enrichedTransactionsScenario(data) {
  const token = data.tokens[randomInt(0, data.tokens.length - 1)];
  const response = enrichedTransactionsRequest(token, ENRICHED_TRANSACTION_LIMIT, 0, {
    tags: ENDPOINT_TAGS.enrichedTransactions,
  });

  expectStatus(response, 200, "concurrent mixed enriched transactions", ENDPOINT_TAGS.enrichedTransactions);
}
