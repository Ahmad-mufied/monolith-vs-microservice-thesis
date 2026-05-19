import {
  benchmarkOptions,
  ADMIN_AUTH_TOKEN,
  ADMIN_USER_EMAIL,
  ADMIN_USER_PASSWORD,
  ENRICHED_TRANSACTION_LIMIT,
} from "./common/config.js";
import { users } from "./common/data.js";
import {
  loginSetupAndExtractToken,
  enrichedTransactionsWorkloadRequest,
  enrichedTransactionsSetupProbeRequest,
  expectStatus,
  responseDataArrayLength,
} from "./common/requests.js";
import { handleSummary as baseHandleSummary } from "./common/summary.js";

const WORKLOAD_METRIC_TAGS = {
  request_kind: "workload",
  benchmark_phase: "workload",
};

export const options = benchmarkOptions("enriched-transactions", WORKLOAD_METRIC_TAGS);

export function handleSummary(data) {
  return baseHandleSummary(data, { metricTags: WORKLOAD_METRIC_TAGS });
}

function resolveToken() {
  if (ADMIN_AUTH_TOKEN) {
    return ADMIN_AUTH_TOKEN;
  }

  if (ADMIN_USER_EMAIL) {
    const auth = loginSetupAndExtractToken(ADMIN_USER_EMAIL, ADMIN_USER_PASSWORD, "setup admin login");
    return auth.token;
  }

  const seededUsers = users();
  if (seededUsers.length === 0) {
    throw new Error("No users available for enriched-transactions scenario.");
  }

  const auth = loginSetupAndExtractToken(seededUsers[0].email, seededUsers[0].password, "setup reader login");
  return auth.token;
}

function validateEnrichmentData(token) {
  const probe = enrichedTransactionsSetupProbeRequest(token, 1, 0);

  if (probe.status !== 200) {
    const body = typeof probe.body === "string" ? probe.body : "";
    throw new Error(
      `enriched-transactions setup probe failed: status=${probe.status}, body=${body}`
    );
  }

  if (responseDataArrayLength(probe) === 0) {
    throw new Error(
      "enriched-transactions setup probe found no transaction data. " +
      "Run the enrichment preparation job before this benchmark."
    );
  }
}

export function setup() {
  const token = resolveToken();
  validateEnrichmentData(token);
  return { token };
}

export default function (data) {
  const response = enrichedTransactionsWorkloadRequest(data.token, ENRICHED_TRANSACTION_LIMIT, 0);
  expectStatus(response, 200, "enriched transactions", WORKLOAD_METRIC_TAGS);
}
