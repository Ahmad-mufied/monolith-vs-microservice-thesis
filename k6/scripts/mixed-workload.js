import {
  benchmarkOptions,
  TOKEN_POOL_SIZE,
  ENRICHED_TRANSACTION_LIMIT,
  TRANSACTION_AMOUNT,
  envInt,
} from "./common/config.js";
import { itemIds, users, randomInt, randomUser } from "./common/data.js";
import {
  loginRequest,
  loginAndExtractToken,
  createTransactionRequest,
  ownTransactionsRequest,
  enrichedTransactionsRequest,
  expectStatus,
  expectJsonValue,
} from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = benchmarkOptions("mixed_workload");

const LOGIN_WEIGHT = envInt("MIX_LOGIN_WEIGHT", 10);
const CREATE_TRANSACTION_WEIGHT = envInt("MIX_CREATE_TRANSACTION_WEIGHT", 40);
const OWN_TRANSACTIONS_WEIGHT = envInt("MIX_OWN_TRANSACTIONS_WEIGHT", 20);
const ENRICHED_TRANSACTIONS_WEIGHT = envInt("MIX_ENRICHED_TRANSACTIONS_WEIGHT", 30);

export function setup() {
  const seededUsers = users();
  const seededItems = itemIds();

  if (seededUsers.length === 0) {
    throw new Error("No seeded users available for mixed-workload scenario.");
  }

  if (seededItems.length === 0) {
    throw new Error("No seeded item IDs available for mixed-workload scenario.");
  }

  const tokenPool = [];
  const poolSize = Math.min(TOKEN_POOL_SIZE, seededUsers.length);

  for (let i = 0; i < poolSize; i += 1) {
    const auth = loginAndExtractToken(seededUsers[i].email, seededUsers[i].password, `setup mixed login ${i + 1}`);
    if (auth.token) {
      tokenPool.push(auth.token);
    }
  }

  return {
    tokens: tokenPool,
    itemIds: seededItems,
  };
}

export default function (data) {
  const total = LOGIN_WEIGHT + CREATE_TRANSACTION_WEIGHT + OWN_TRANSACTIONS_WEIGHT + ENRICHED_TRANSACTIONS_WEIGHT;
  const dice = randomInt(1, total);

  if (dice <= LOGIN_WEIGHT) {
    const user = randomUser();
    const response = loginRequest(user.email, user.password);
    expectStatus(response, 200, "mixed login");
    expectJsonValue(response, "data.token", "mixed login");
    return;
  }

  const token = data.tokens[randomInt(0, data.tokens.length - 1)];

  if (dice <= LOGIN_WEIGHT + CREATE_TRANSACTION_WEIGHT) {
    const itemId = data.itemIds[randomInt(0, data.itemIds.length - 1)];
    const response = createTransactionRequest(token, itemId, TRANSACTION_AMOUNT);
    expectStatus(response, 201, "mixed create transaction");
    return;
  }

  if (dice <= LOGIN_WEIGHT + CREATE_TRANSACTION_WEIGHT + OWN_TRANSACTIONS_WEIGHT) {
    const response = ownTransactionsRequest(token, 20, 0);
    expectStatus(response, 200, "mixed own transactions");
    return;
  }

  const response = enrichedTransactionsRequest(token, ENRICHED_TRANSACTION_LIMIT, 0);
  expectStatus(response, 200, "mixed enriched transactions");
}
