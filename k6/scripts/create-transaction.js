import { benchmarkOptions, TOKEN_POOL_SIZE, TRANSACTION_AMOUNT } from "./common/config.js";
import { itemIds, users, randomInt } from "./common/data.js";
import {
  loginAndExtractToken,
  createTransactionRequest,
  expectStatus,
  expectJsonValue,
} from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = benchmarkOptions("create_transaction");

export function setup() {
  const seededUsers = users();
  const seededItems = itemIds();

  if (seededUsers.length === 0) {
    throw new Error("No seeded users available for create-transaction scenario.");
  }

  if (seededItems.length === 0) {
    throw new Error("No seeded item IDs available for create-transaction scenario.");
  }

  const tokenPool = [];
  const poolSize = Math.min(TOKEN_POOL_SIZE, seededUsers.length);

  for (let i = 0; i < poolSize; i += 1) {
    const auth = loginAndExtractToken(seededUsers[i].email, seededUsers[i].password, `setup login ${i + 1}`);
    if (auth.token) {
      tokenPool.push(auth.token);
    }
  }

  if (tokenPool.length === 0) {
    throw new Error("No tokens generated for create-transaction scenario.");
  }

  return {
    tokens: tokenPool,
    itemIds: seededItems,
  };
}

export default function (data) {
  const token = data.tokens[randomInt(0, data.tokens.length - 1)];
  const itemId = data.itemIds[randomInt(0, data.itemIds.length - 1)];

  const response = createTransactionRequest(token, itemId, TRANSACTION_AMOUNT);

  expectStatus(response, 201, "create transaction");
  expectJsonValue(response, "data.id", "create transaction");
}
