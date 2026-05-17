import { benchmarkOptions } from "./common/config.js";
import { users, buildSyncItems } from "./common/data.js";
import {
  loginAndExtractToken,
  syncItemsRequest,
  expectStatus,
} from "./common/requests.js";
export { handleSummary } from "./common/summary.js";

export const options = benchmarkOptions("sync_items");

export function setup() {
  const seededUsers = users();

  if (seededUsers.length === 0) {
    throw new Error("No seeded users available for sync-items scenario.");
  }

  const auth = loginAndExtractToken(seededUsers[0].email, seededUsers[0].password, "setup sync login");

  return {
    token: auth.token,
    items: buildSyncItems(),
  };
}

export default function (data) {
  const response = syncItemsRequest(data.token, data.items);
  expectStatus(response, 200, "sync items");
}
