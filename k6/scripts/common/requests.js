import http from "k6/http";
import { check } from "k6";
import {
  BASE_URL,
  ITEM_LIST_LIMIT,
  TRANSACTION_AMOUNT,
  OWN_TRANSACTION_LIMIT,
  ENRICHED_TRANSACTION_LIMIT,
  REQUEST_TIMEOUT_MS,
} from "./config.js";

export function jsonHeaders(token = "") {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  // timeout is applied to every request so that the application-level deadline
  // (APP_REQUEST_TIMEOUT, default 30s) still fires before k6's default 60s
  // client timeout.
  return { headers, timeout: REQUEST_TIMEOUT_MS };
}

function mergeRequestParams(baseParams, extraParams = {}) {
  const merged = { ...baseParams, ...extraParams };

  if (baseParams.headers || extraParams.headers) {
    merged.headers = {
      ...(baseParams.headers || {}),
      ...(extraParams.headers || {}),
    };
  }

  if (baseParams.tags || extraParams.tags) {
    merged.tags = {
      ...(baseParams.tags || {}),
      ...(extraParams.tags || {}),
    };
  }

  return merged;
}

export function safeJson(response, selector = null, fallback = null) {
  try {
    if (selector) {
      return response.json(selector);
    }
    return response.json();
  } catch (_) {
    return fallback;
  }
}

function normalizeCheckNamePart(value) {
  const normalized = String(value ?? "unknown")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_.]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "");

  return normalized || "unknown";
}

function normalizeSelectorCheckNamePart(selector) {
  return normalizeCheckNamePart(selector).replace(/\./g, "_");
}

function buildCheckName(label, suffix) {
  return `${normalizeCheckNamePart(label)}.${suffix}`;
}

export function expectStatus(response, status, label, tags = undefined) {
  return check(response, {
    [buildCheckName(label, `status_is_${status}`)]: (r) => r.status === status,
  }, tags);
}


export function expectJsonValue(response, selector, label, tags = undefined) {
  const selectorPart = normalizeSelectorCheckNamePart(selector);

  return check(response, {
    [buildCheckName(label, `${selectorPart}_exists`)]: (r) => {
      try {
        const value = r.json(selector);
        return value !== undefined && value !== null;
      } catch (_) {
        return false;
      }
    },
  }, tags);
}

export function healthRequest() {
  return http.get(`${BASE_URL}/healthz`, { timeout: REQUEST_TIMEOUT_MS });
}

export function loginRequest(email, password, extraParams = {}) {
  return http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email, password }),
    mergeRequestParams(jsonHeaders(), extraParams)
  );
}

export function loginSetupRequest(email, password, label = "setup login") {
  return http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email, password }),
    mergeRequestParams(jsonHeaders(), {
      tags: {
        request_kind: "setup_login",
        benchmark_phase: "setup",
        name: label,
      },
    })
  );
}

export function loginAndExtractToken(email, password, label = "login") {
  const response = loginRequest(email, password);

  const statusOk = expectStatus(response, 200, label);
  const tokenOk = expectJsonValue(response, "data.token", label);
  const token = safeJson(response, "data.token", "");

  if (!statusOk || !tokenOk || !token) {
    const body = typeof response.body === "string" ? response.body : "";
    throw new Error(
      `${label}: login failed or token missing (status=${response.status}, body=${body})`
    );
  }

  return {
    response,
    token,
    user: safeJson(response, "data.user", null),
  };
}

export function loginSetupAndExtractToken(email, password, label = "setup login") {
  const response = loginSetupRequest(email, password, label);
  const token = safeJson(response, "data.token", "");

  if (response.status !== 200 || !token) {
    const body = typeof response.body === "string" ? response.body : "";
    throw new Error(
      `${label}: login failed or token missing (status=${response.status}, body=${body})`
    );
  }

  return {
    response,
    token,
    user: safeJson(response, "data.user", null),
  };
}

export function listItemsRequest(token, limit = ITEM_LIST_LIMIT, offset = 0) {
  return http.get(
    `${BASE_URL}/api/v1/items?limit=${limit}&offset=${offset}`,
    jsonHeaders(token)
  );
}

export function syncItemsRequest(token, items) {
  return http.put(
    `${BASE_URL}/api/v1/items`,
    JSON.stringify({ items }),
    jsonHeaders(token)
  );
}

export function createTransactionRequest(token, itemId, amount = TRANSACTION_AMOUNT, extraParams = {}) {
  return http.post(
    `${BASE_URL}/api/v1/transactions`,
    JSON.stringify({
      items: [
        {
          item_id: itemId,
          amount,
        },
      ],
    }),
    mergeRequestParams(jsonHeaders(token), extraParams)
  );
}

export function ownTransactionsRequest(token, limit = OWN_TRANSACTION_LIMIT, offset = 0) {
  return http.get(
    `${BASE_URL}/api/v1/transactions?limit=${limit}&offset=${offset}`,
    jsonHeaders(token)
  );
}

export function transactionDetailRequest(token, transactionId) {
  return http.get(
    `${BASE_URL}/api/v1/transactions/${transactionId}`,
    jsonHeaders(token)
  );
}

export function enrichedTransactionsRequest(token, limit = ENRICHED_TRANSACTION_LIMIT, offset = 0, extraParams = {}) {
  return http.get(
    `${BASE_URL}/api/v1/admin/transactions?limit=${limit}&offset=${offset}`,
    mergeRequestParams(jsonHeaders(token), extraParams)
  );
}

export function enrichedTransactionsWorkloadRequest(token, limit = ENRICHED_TRANSACTION_LIMIT, offset = 0) {
  return http.get(
    `${BASE_URL}/api/v1/admin/transactions?limit=${limit}&offset=${offset}`,
    mergeRequestParams(jsonHeaders(token), {
      tags: {
        request_kind: "workload",
        benchmark_phase: "workload",
        name: "enriched transactions",
      },
    })
  );
}

export function enrichedTransactionsSetupProbeRequest(token, limit = 1, offset = 0) {
  return http.get(
    `${BASE_URL}/api/v1/admin/transactions?limit=${limit}&offset=${offset}`,
    mergeRequestParams(jsonHeaders(token), {
      tags: {
        request_kind: "setup_probe",
        benchmark_phase: "setup",
        name: "setup enriched transactions probe",
      },
    })
  );
}

export function responseDataArrayLength(response) {
  const data = safeJson(response, "data", []);
  return Array.isArray(data) ? data.length : 0;
}

export function requireEnrichedTransactionsReady(token, options = {}) {
  const {
    limit = 1,
    offset = 0,
    label = "enriched-transactions setup probe",
    requireData = true,
  } = options;

  const probe = enrichedTransactionsSetupProbeRequest(token, limit, offset);

  if (probe.status !== 200) {
    const body = typeof probe.body === "string" ? probe.body : "";
    throw new Error(`${label}: status=${probe.status}, body=${body}`);
  }

  if (requireData && responseDataArrayLength(probe) === 0) {
    throw new Error(`${label}: no transaction data found. Run the enrichment preparation job before this benchmark.`);
  }

  return probe;
}
