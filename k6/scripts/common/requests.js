import http from "k6/http";
import { check } from "k6";
import {
  BASE_URL,
  ITEM_LIST_LIMIT,
  TRANSACTION_AMOUNT,
  OWN_TRANSACTION_LIMIT,
  ENRICHED_TRANSACTION_LIMIT,
} from "./config.js";

export function jsonHeaders(token = "") {
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return { headers };
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

export function expectStatus(response, status, label) {
  return check(response, {
    [`${label}: status is ${status}`]: (r) => r.status === status,
  });
}

export function expectStatusIn(response, statuses, label) {
  return check(response, {
    [`${label}: status is ${statuses.join(" or ")}`]: (r) => statuses.includes(r.status),
  });
}

export function expectJsonValue(response, selector, label) {
  return check(response, {
    [`${label}: ${selector} exists`]: (r) => {
      try {
        const value = r.json(selector);
        return value !== undefined && value !== null;
      } catch (_) {
        return false;
      }
    },
  });
}

export function healthRequest() {
  return http.get(`${BASE_URL}/healthz`);
}

export function loginRequest(email, password) {
  return http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email, password }),
    jsonHeaders()
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

export function createTransactionRequest(token, itemId, amount = TRANSACTION_AMOUNT) {
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
    jsonHeaders(token)
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

export function enrichedTransactionsRequest(token, limit = ENRICHED_TRANSACTION_LIMIT, offset = 0) {
  return http.get(
    `${BASE_URL}/api/v1/admin/transactions?limit=${limit}&offset=${offset}`,
    jsonHeaders(token)
  );
}

export function responseDataArrayLength(response) {
  const data = safeJson(response, "data", []);
  return Array.isArray(data) ? data.length : 0;
}
