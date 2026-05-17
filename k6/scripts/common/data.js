import {
  DATASET,
  USER_COUNT,
  USER_EMAIL_PREFIX,
  USER_EMAIL_SEPARATOR,
  USER_EMAIL_PADDING,
  USER_EMAIL_DOMAIN,
  USER_PASSWORD,
  USERS_FILE,
  ITEM_COUNT,
  ITEM_IDS_FILE,
  ITEM_ID_NAMESPACE,
  SYNC_ITEM_COUNT,
  SYNC_ITEM_NAME_PREFIX,
  SYNC_ITEM_AVAILABLE_AMOUNT,
  SYNC_ITEM_PADDING,
} from "./config.js";

const smokeUsers = [
  { email: "smoke-user-1@example.com", password: "Password123!" },
  { email: "smoke-user-2@example.com", password: "Password123!" },
];

const smokeItemIDs = [
  "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2001",
  "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2002",
  "018f5f60-7c35-7ccf-9c3c-0a5e6f6f2003",
];

function leftPad(value, width) {
  const raw = String(value);
  if (width <= 0) {
    return raw;
  }
  return raw.padStart(width, "0");
}

export function randomInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function userEmail(index) {
  return `${USER_EMAIL_PREFIX}${USER_EMAIL_SEPARATOR}${leftPad(index, USER_EMAIL_PADDING)}@${USER_EMAIL_DOMAIN}`;
}

const itemIdNamespace = String(ITEM_ID_NAMESPACE).toLowerCase();
if (!/^[0-9a-f]{4}$/.test(itemIdNamespace)) {
  throw new Error(`Invalid ITEM_ID_NAMESPACE '${ITEM_ID_NAMESPACE}'. Expected 4 hex characters.`);
}

export function deterministicItemId(index) {
  return `00000000-0000-7000-${itemIdNamespace}-${leftPad(index, 12)}`;
}

export function deterministicTransactionId(index) {
  return `00000000-0000-7000-a000-${leftPad(index, 12)}`;
}

function safeParseJsonFile(path, fallback) {
  if (!path) {
    return fallback;
  }

  try {
    return JSON.parse(open(path));
  } catch (error) {
    throw new Error(`Failed to load JSON file '${path}': ${error.message}`);
  }
}

function normalizeUsers(raw) {
  if (!raw) {
    return [];
  }

  const rows = Array.isArray(raw) ? raw : raw.users;

  if (!Array.isArray(rows)) {
    return [];
  }

  return rows
    .map((row) => {
      if (typeof row === "string") {
        return { email: row, password: USER_PASSWORD };
      }

      return {
        email: row.email,
        password: row.password || USER_PASSWORD,
      };
    })
    .filter((row) => row.email);
}

function normalizeItemIds(raw) {
  if (!raw) {
    return [];
  }

  if (Array.isArray(raw)) {
    return raw
      .map((row) => (typeof row === "string" ? row : row.id || row.item_id))
      .filter(Boolean);
  }

  if (Array.isArray(raw.item_ids)) {
    return raw.item_ids.filter(Boolean);
  }

  if (Array.isArray(raw.items)) {
    return raw.items.map((item) => item.id || item.item_id).filter(Boolean);
  }

  return [];
}

const loadedUsers = normalizeUsers(safeParseJsonFile(USERS_FILE, null));
const loadedItemIds = normalizeItemIds(safeParseJsonFile(ITEM_IDS_FILE, null));

export function users() {
  if (loadedUsers.length > 0) {
    return loadedUsers;
  }

  if (DATASET === "smoke") {
    return smokeUsers.map((user) => ({
      email: user.email,
      password: user.password || USER_PASSWORD,
    }));
  }

  const rows = [];
  for (let i = 1; i <= USER_COUNT; i += 1) {
    rows.push({
      email: userEmail(i),
      password: USER_PASSWORD,
    });
  }
  return rows;
}

export function itemIds() {
  if (loadedItemIds.length > 0) {
    return loadedItemIds;
  }

  if (DATASET === "smoke") {
    return [...smokeItemIDs];
  }

  const rows = [];
  for (let i = 1; i <= ITEM_COUNT; i += 1) {
    rows.push(deterministicItemId(i));
  }
  return rows;
}

export function randomUser() {
  const rows = users();
  if (rows.length === 0) {
    throw new Error("randomUser: no users available");
  }
  return rows[randomInt(0, rows.length - 1)];
}

export function randomItemId() {
  const rows = itemIds();
  if (rows.length === 0) {
    throw new Error("randomItemId: no item IDs available");
  }
  return rows[randomInt(0, rows.length - 1)];
}

export function buildSyncItems(count = SYNC_ITEM_COUNT) {
  const rows = [];

  for (let i = 1; i <= count; i += 1) {
    rows.push({
      id: deterministicItemId(i),
      name: `${SYNC_ITEM_NAME_PREFIX} ${leftPad(i, SYNC_ITEM_PADDING)}`,
      available_amount: SYNC_ITEM_AVAILABLE_AMOUNT,
    });
  }

  return rows;
}
