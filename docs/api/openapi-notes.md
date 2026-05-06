# OpenAPI Notes

## 1. Purpose

This document describes the REST API contract rules for the thesis benchmark system.

The external API is shared by both architecture variants:

1. Monolith
2. Microservices

The source of truth for the external REST API is:

```text
openapi.yaml
```

Both implementations must expose the same external API behavior. The internal architecture may differ, but the external request and response contract must remain equivalent.

---

## 2. API Design Goal

The API is designed as a generic transactional benchmark API.

It is intentionally not tied to a specific e-commerce domain.

The API uses these generic domain terms:

- user,
- item,
- transaction,
- amount,
- available_amount.

The term `item` represents a generic allocatable entity. It can represent a ticket category, booking unit, quota unit, inventory-like resource, or another resource that can be allocated during a transaction.

The external REST API currently uses `available_amount` for item availability and `amount` for transaction allocation. The database may use internal column names such as `items.available_amount`, and API clients must follow `openapi.yaml`.

Avoid these terms unless explicitly required later:

- product,
- cart,
- checkout,
- payment,
- stock,
- quantity.

Reason:

The research focuses on architecture performance and resource efficiency, not on a specific business domain such as e-commerce.

---

## 3. Source of Truth

The OpenAPI file must define:

- endpoint paths,
- request bodies,
- response bodies,
- security requirements,
- error response format,
- benchmark endpoint descriptions,
- schema definitions,
- ID formats.

Any change to external REST behavior must be reflected in:

```text
openapi.yaml
docs/api/openapi-notes.md
```

If an endpoint behavior affects benchmark semantics, also update:

```text
docs/experiment/workload-scenarios.md
docs/architecture/comparison.md
```

---

## 4. API Versioning

All endpoints use versioned paths:

```text
/api/v1
```

Examples:

```text
POST /api/v1/auth/login
POST /api/v1/transactions
GET  /api/v1/admin/transactions
```

Versioning is kept simple because the thesis benchmark only evaluates one API version.

---

## 5. ID Format

All public IDs must be UUID strings.

OpenAPI schema rule:

```yaml
type: string
format: uuid
```

Example:

```yaml
id:
  type: string
  format: uuid
  example: "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1"
```

This applies to:

- `User.id`,
- `Item.id`,
- `Transaction.id`,
- `item_id`,
- `transaction_id`,
- `user_id` if exposed in a response.

Do not use examples such as:

```text
USR-001
ITM-001
TX-999
```

Reason:

The database uses PostgreSQL UUID with database-side UUIDv7 generation.

---

## 6. Timestamp Format

All timestamp fields exposed in the API use:

```yaml
type: string
format: date-time
```

Expected fields:

- `created_at`,
- `updated_at`.

Example:

```yaml
created_at:
  type: string
  format: date-time
  example: "2026-05-03T10:15:30Z"
```

Database timestamp fields use `TIMESTAMPTZ`.

---

## 7. Response Envelope

All successful responses should follow a consistent envelope:

```json
{
  "status": "success",
  "data": {}
}
```

List responses may include metadata:

```json
{
  "status": "success",
  "data": [],
  "meta": {
    "limit": 50,
    "offset": 0,
    "total_returned": 50
  }
}
```

All error responses should follow:

```json
{
  "status": "error",
  "error": {
    "code": "BAD_REQUEST",
    "message": "Invalid request payload",
    "details": null
  }
}
```

Do not expose raw database errors, stack traces, or internal gRPC errors directly to clients.

---

## 8. Authentication

Protected endpoints use JWT Bearer authentication.

OpenAPI security scheme:

```yaml
bearerAuth:
  type: http
  scheme: bearer
  bearerFormat: JWT
```

Header format:

```text
Authorization: Bearer <token>
```

Authentication behavior must be equivalent between monolith and microservices.

In microservices, the API Gateway is responsible for validating JWT for protected external routes.

The business services may still receive user context through gRPC metadata or request fields, depending on implementation.

---

## 9. Main Benchmark Endpoints

The thesis benchmark focuses on three primary endpoints.

| Benchmark | Endpoint | Workload Type | Purpose |
|---|---|---|---|
| Benchmark 1 | `POST /api/v1/auth/login` | CPU-bound | bcrypt password comparison and JWT signing |
| Benchmark 2 | `POST /api/v1/transactions` | I/O-bound + state mutation | create transaction and allocate item amount |
| Benchmark 3 | `GET /api/v1/admin/transactions` | aggregation + network-bound | return enriched transaction data |

These endpoints are the primary target for k6 scenarios.

---

## 10. Endpoint Group: Auth

## 10.1 Register User

Endpoint:

```text
POST /api/v1/auth/register
```

Purpose:

Create a new user.

Expected request body:

```json
{
  "name": "Ahmad Mufied",
  "email": "mufied@example.com",
  "password": "Password123!"
}
```

Expected response:

```json
{
  "status": "success",
  "data": {
    "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1",
    "name": "Ahmad Mufied",
    "email": "mufied@example.com",
    "created_at": "2026-05-03T10:15:30Z",
    "updated_at": "2026-05-03T10:15:30Z"
  }
}
```

Notes:

- password must not be returned,
- password_hash must not be returned.

---

## 10.2 Login User

Endpoint:

```text
POST /api/v1/auth/login
```

Benchmark:

```text
Benchmark 1
```

Workload type:

```text
CPU-bound
```

Purpose:

Authenticate a user and return JWT.

Expected request body:

```json
{
  "email": "mufied@example.com",
  "password": "Password123!"
}
```

Expected response:

```json
{
  "status": "success",
  "data": {
    "token": "jwt-token",
    "user": {
      "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1",
      "name": "Ahmad Mufied",
      "email": "mufied@example.com"
    }
  }
}
```

Benchmark behavior:

- lookup user by email,
- bcrypt password comparison,
- JWT signing.

Monolith flow:

```text
Client -> Monolith -> mono_db.users
```

Microservices flow:

```text
Client -> API Gateway -> Auth Service -> auth_db.users
```

---

## 11. Endpoint Group: Items

## 11.1 List Items

Endpoint:

```text
GET /api/v1/items
```

Authentication:

```text
Bearer JWT
```

Purpose:

Return available items.

Expected response:

```json
{
  "status": "success",
  "data": [
    {
      "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a2",
      "name": "Item 1",
      "available_amount": 1000000,
      "created_at": "2026-05-03T10:15:30Z",
      "updated_at": "2026-05-03T10:15:30Z"
    }
  ],
  "meta": {
    "limit": 50,
    "offset": 0,
    "total_returned": 1
  }
}
```

---

## 11.2 Create Item

Endpoint:

```text
POST /api/v1/items
```

Authentication:

```text
Bearer JWT
```

Purpose:

Create a new item.

Expected request body:

```json
{
  "name": "Item 1",
  "available_amount": 1000000
}
```

Notes:

- API `available_amount` must be greater than or equal to 0,
- API `available_amount` maps to the internal database column `items.available_amount`,
- the database generates `id` using UUIDv7.

---

## 11.3 Get Item Detail

Endpoint:

```text
GET /api/v1/items/{item_id}
```

Path parameter:

```yaml
item_id:
  type: string
  format: uuid
```

Purpose:

Return one item by ID.

---

## 11.4 Update Item

Endpoint:

```text
PUT /api/v1/items/{item_id}
```

Authentication:

```text
Bearer JWT
```

Purpose:

Update item attributes.

Expected request body:

```json
{
  "name": "Updated Item",
  "available_amount": 500000
}
```

Notes:

- updating API `available_amount` directly is allowed for CRUD/demo purposes,
- API `available_amount` maps to the internal database column `items.available_amount`,
- benchmark transaction allocation must use the transaction flow, not this endpoint.

---

## 11.5 Delete Item

Endpoint:

```text
DELETE /api/v1/items/{item_id}
```

Authentication:

```text
Bearer JWT
```

Purpose:

Delete an item.

For benchmark stability, delete operations should not be part of the main benchmark scenarios unless explicitly designed.

---

## 12. Endpoint Group: Transactions

## 12.1 Create Transaction

Endpoint:

```text
POST /api/v1/transactions
```

Benchmark:

```text
Benchmark 2
```

Authentication:

```text
Bearer JWT
```

Workload type:

```text
I/O-bound + state mutation
```

Purpose:

Create a transaction and allocate item amount.

Final request body:

```json
{
  "items": [
    {
      "item_id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a2",
      "amount": 2
    }
  ]
}
```

Important:

Use `items` with `item_id` and `amount`.

Do not use only:

```json
{
  "item_ids": []
}
```

Reason:

The benchmark needs item allocation behavior. The system must know how much amount is requested for each item.

Expected response:

```json
{
  "status": "success",
  "data": {
    "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a3",
    "user_id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1",
    "items": [
      {
        "item_id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a2",
        "amount": 2
      }
    ],
    "created_at": "2026-05-03T10:15:30Z",
    "updated_at": "2026-05-03T10:15:30Z"
  }
}
```

Completion rule:

The response must be returned only after:

- item availability is validated,
- internal item availability is updated,
- transaction row is inserted,
- transaction_items rows are inserted.

The API must not return before the main work is complete.

Reason:

Returning early after publishing an event would make response time incomparable with the monolith synchronous flow.

---

## 12.2 Get Own Transactions

Endpoint:

```text
GET /api/v1/transactions
```

Authentication:

```text
Bearer JWT
```

Purpose:

Return transactions owned by the authenticated user.

Expected response:

```json
{
  "status": "success",
  "data": [
    {
      "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a3",
      "user_id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1",
      "items": [
        {
          "item_id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a2",
          "amount": 2
        }
      ],
      "created_at": "2026-05-03T10:15:30Z",
      "updated_at": "2026-05-03T10:15:30Z"
    }
  ],
  "meta": {
    "limit": 50,
    "offset": 0,
    "total_returned": 1
  }
}
```

---

## 12.3 Get All Transactions Enriched

Endpoint:

```text
GET /api/v1/admin/transactions
```

Benchmark:

```text
Benchmark 3
```

Authentication:

```text
Bearer JWT
```

Workload type:

```text
aggregation + network-bound
```

Purpose:

Return transaction data enriched with user summary and item summary details.

Query parameters:

```yaml
limit:
  type: integer
  default: 50
  minimum: 1
  maximum: 100
```

Expected response:

```json
{
  "status": "success",
  "data": [
    {
      "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a3",
      "created_at": "2026-05-03T10:15:30Z",
      "updated_at": "2026-05-03T10:15:30Z",
      "user": {
        "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1",
        "name": "Ahmad Mufied",
        "email": "mufied@example.com"
      },
      "items": [
        {
          "item": {
            "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a2",
            "name": "Item 1"
          },
          "amount": 2
        }
      ]
    }
  ],
  "meta": {
    "limit": 50,
    "offset": 0,
    "total_returned": 1
  }
}
```

Monolith implementation:

```text
single SQL JOIN
```

Microservices implementation:

```text
Transaction Service
-> transaction_db
-> Auth Service GetUsersByIds
-> Item Service GetItemsByIds
-> in-memory enrichment
```

Notes:

- This endpoint returns `UserSummary` and `ItemSummary`, not the full `User` and `Item` schemas.
- `available_amount` is intentionally omitted from enriched item payloads because this endpoint represents transaction enrichment, not current inventory state.

---

## 13. Recommended Schema Components

## 13.1 User

```yaml
User:
  type: object
  properties:
    id:
      type: string
      format: uuid
    name:
      type: string
    email:
      type: string
      format: email
    created_at:
      type: string
      format: date-time
    updated_at:
      type: string
      format: date-time
```

Do not expose:

```text
password
password_hash
```

---

## 13.2 Item

```yaml
Item:
  type: object
  properties:
    id:
      type: string
      format: uuid
    name:
      type: string
    available_amount:
      type: integer
      minimum: 0
    created_at:
      type: string
      format: date-time
    updated_at:
      type: string
      format: date-time
```

Use:

```text
available_amount
```

Do not use:

```text
availability
quantity
stock
```

Implementation note:

```text
API Item.available_amount maps to the database column items.available_amount.
```

---

## 13.3 Transaction Item Request

```yaml
TransactionItemRequest:
  type: object
  required:
    - item_id
    - amount
  properties:
    item_id:
      type: string
      format: uuid
    amount:
      type: integer
      minimum: 1
```

---

## 13.4 Transaction Item Response

```yaml
TransactionItemResponse:
  type: object
  properties:
    item_id:
      type: string
      format: uuid
    amount:
      type: integer
```

The REST transaction item response does not expose `available_amount_after` in the current `openapi.yaml`, even though the database stores it for internal persistence and analysis.

---

## 13.5 Transaction Enriched

```yaml
TransactionEnriched:
  type: object
  properties:
    id:
      type: string
      format: uuid
    created_at:
      type: string
      format: date-time
    updated_at:
      type: string
      format: date-time
    user:
      $ref: '#/components/schemas/User'
    items:
      type: array
      items:
        $ref: '#/components/schemas/TransactionEnrichedItem'
```

Current enriched item shape:

```yaml
TransactionEnrichedItem:
  type: object
  properties:
    item:
      $ref: '#/components/schemas/ItemSummary'
    amount:
      type: integer
      minimum: 1
```

---

## 13.6 Error Response

```yaml
ErrorResponse:
  type: object
  properties:
    status:
      type: string
      example: error
    error:
      type: object
      properties:
        code:
          type: string
          example: BAD_REQUEST
        message:
          type: string
          example: Invalid request payload
        details:
          type: object
          additionalProperties: true
          nullable: true
```

---

## 14. Error Handling Summary

Common HTTP status codes:

| HTTP Code | Meaning |
|---:|---|
| 400 | invalid request or validation error |
| 401 | missing or invalid token |
| 403 | forbidden |
| 404 | resource not found |
| 409 | conflict, allocation conflict, or insufficient item amount |
| 500 | internal server error |
| 503 | upstream service unavailable |
| 504 | upstream timeout |

For create transaction:

- insufficient item amount should return `409`,
- invalid UUID should return `400`,
- invalid JWT should return `401`,
- upstream service timeout in microservices should return `504`,
- unexpected internal error should return `500`.

---

## 15. Architecture Mapping

## 15.1 Monolith Mapping

```text
REST endpoint
    |
    v
Monolith handler
    |
    v
Usecase
    |
    v
Repository
    |
    v
mono_db
```

The monolith maps REST handlers directly to internal usecases.

---

## 15.2 Microservices Mapping

```text
REST endpoint
    |
    v
API Gateway handler
    |
    v
gRPC client
    |
    v
Business service gRPC server
    |
    v
Usecase
    |
    v
Repository or another service client
```

The API Gateway maps REST requests to internal gRPC requests.

---

## 16. Fairness Rules

The external API must remain equivalent across monolith and microservices.

Do not allow the following differences:

- different endpoint paths,
- different request fields,
- different response fields,
- different authentication behavior,
- different error format,
- different completion semantics,
- different data volume,
- different benchmark payloads.

Benchmark fairness requires that both architectures complete equivalent work before returning a response.

---

## 17. Current OpenAPI Update Checklist

When updating `openapi.yaml`, ensure:

- all ID fields use `format: uuid`,
- examples use UUID strings,
- `availability`, `quantity`, and `stock` are not used,
- item availability in REST responses uses `Item.available_amount`,
- `item_ids` is replaced by `items: [{ item_id, amount }]`,
- transaction responses include `amount`,
- transaction responses follow the current `Transaction` and `TransactionItem` schemas,
- `created_at` and `updated_at` are included where relevant,
- error response uses `status` plus nested `error`,
- benchmark endpoint descriptions are updated,
- security requirements are consistent.

---

## 18. Summary

The REST API contract is the external interface shared by both architecture variants.

Final API rules:

```text
Source of truth    : openapi.yaml
ID format          : string, format uuid
Domain term        : item
Item field         : available_amount
Allocation field   : amount
Response envelope  : status + data
Error envelope     : status + error
Auth               : Bearer JWT
Benchmark endpoints:
  - POST /api/v1/auth/login
  - POST /api/v1/transactions
  - GET /api/v1/admin/transactions
```

Any architectural difference must remain internal. The external API must stay equivalent.
