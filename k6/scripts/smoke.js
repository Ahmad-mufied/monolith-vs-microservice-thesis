import { sleep } from "k6";
import { smokeOptions, ENRICHED_TRANSACTION_LIMIT } from "./common/config.js";
import { itemIds, users, randomInt } from "./common/data.js";
import {
  healthRequest,
  loginAndExtractToken,
  listItemsRequest,
  createTransactionRequest,
  ownTransactionsRequest,
  transactionDetailRequest,
  enrichedTransactionsRequest,
  expectStatus,
  expectJsonValue,
  responseDataArrayLength,
  safeJson,
} from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = smokeOptions();

export function setup() {
  const seededUsers = users();
  const seededItems = itemIds();

  if (seededUsers.length === 0) {
    throw new Error("No seeded users available for smoke scenario.");
  }

  if (seededItems.length === 0) {
    throw new Error("No seeded item IDs available for smoke scenario.");
  }

  const auth = loginAndExtractToken(seededUsers[0].email, seededUsers[0].password, "setup smoke login");

  return {
    token: auth.token,
    itemIds: seededItems,
  };
}

export default function (data) {
  const health = healthRequest();
  expectStatus(health, 200, "healthz");

  const items = listItemsRequest(data.token, 10, 0);
  expectStatus(items, 200, "list items");

  const itemId = data.itemIds[randomInt(0, data.itemIds.length - 1)];
  const create = createTransactionRequest(data.token, itemId, 1);
  expectStatus(create, 201, "create transaction");
  expectJsonValue(create, "data.id", "create transaction");

  const transactionId = safeJson(create, "data.id", "");
  const own = ownTransactionsRequest(data.token, 10, 0);
  expectStatus(own, 200, "own transactions");

  if (transactionId) {
    const detail = transactionDetailRequest(data.token, transactionId);
    expectStatus(detail, 200, "transaction detail");
  }

  const enriched = enrichedTransactionsRequest(data.token, ENRICHED_TRANSACTION_LIMIT, 0);
  expectStatus(enriched, 200, "enriched transactions");

  if (responseDataArrayLength(enriched) === 0) {
    // This is allowed for smoke datasets without enrichment preparation.
    // The smoke scenario verifies endpoint availability and response validity.
  }

  sleep(1);
}
