import {
  benchmarkOptions,
  ADMIN_AUTH_TOKEN,
  ADMIN_USER_EMAIL,
  ADMIN_USER_PASSWORD,
  ENRICHED_TRANSACTION_LIMIT,
} from "./common/config.js";
import { users } from "./common/data.js";
import {
  loginAndExtractToken,
  enrichedTransactionsRequest,
  expectStatus,
} from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = benchmarkOptions("enriched_transactions");

export function setup() {
  if (ADMIN_AUTH_TOKEN) {
    return { token: ADMIN_AUTH_TOKEN };
  }

  if (ADMIN_USER_EMAIL) {
    const auth = loginAndExtractToken(ADMIN_USER_EMAIL, ADMIN_USER_PASSWORD, "setup admin login");
    return { token: auth.token };
  }

  const seededUsers = users();
  if (seededUsers.length === 0) {
    throw new Error("No users available for enriched-transactions scenario.");
  }

  const auth = loginAndExtractToken(seededUsers[0].email, seededUsers[0].password, "setup reader login");

  return {
    token: auth.token,
  };
}

export default function (data) {
  const response = enrichedTransactionsRequest(data.token, ENRICHED_TRANSACTION_LIMIT, 0);
  expectStatus(response, 200, "enriched transactions");
}
