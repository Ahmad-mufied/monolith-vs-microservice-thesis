# gRPC Contracts

## 1. Purpose

This document defines the final internal gRPC contract for the microservices architecture. The external API is REST HTTP and is defined in `openapi.yaml`. The internal protocol between API Gateway and business services is gRPC.

## 2. Final Alignment with OpenAPI v1.5.0

Final REST response rules:

```text
Success response: HTTP status code + concise body, without status: success.
Error response: structured error object.
Register/Login: return UserSummary; Login also returns token.
PUT /api/v1/items: full active item synchronization.
Items omitted from the sync payload: soft-deleted.
Create transaction: return transaction id only.
Enriched transaction: use UserSummary and ItemSummary.
```

Soft delete scope:

```text
items        : use soft delete via deleted_at
users        : no soft delete in current scope
transactions : no soft delete in current scope
```

## 3. Proto Locations

```text
proto/
├── auth/v1/auth.proto
├── item/v1/item.proto
└── transaction/v1/transaction.proto
```

Generated Go code should use the paths declared in the proto `go_package` options.

## 4. Service Ownership

```text
AuthService        → auth-service, owns auth_db.users
ItemService        → item-service, owns item_db.items
TransactionService → transaction-service, owns transaction_db.transactions and transaction_items
API Gateway        → exposes REST API, validates JWT, maps REST to gRPC, performs enriched transaction aggregation
```

The API Gateway must not access service databases directly. Business services must not access another service's database directly.

## 4.1 Runtime Service Discovery

Kubernetes deployments should expose internal gRPC backends through a normal
ClusterIP Service and a matching headless Service:

```text
auth-service                    -> compatibility/debug ClusterIP
auth-service-headless           -> gRPC client-side load balancing target
item-service                    -> compatibility/debug ClusterIP
item-service-headless           -> gRPC client-side load balancing target
transaction-service             -> compatibility/debug ClusterIP
transaction-service-headless    -> gRPC client-side load balancing target
```

gRPC clients that talk to scalable Kubernetes services should use the DNS
resolver scheme and the `round_robin` client-side load balancing policy:

```text
dns:///auth-service-headless.msa.svc.cluster.local:50051
dns:///item-service-headless.msa.svc.cluster.local:50052
dns:///transaction-service-headless.msa.svc.cluster.local:50053
```

Reason:

```text
gRPC uses long-lived HTTP/2 connections. When a client targets a normal
ClusterIP Service, many RPCs can stay on one connection selected by kube-proxy.
The headless Service returns pod IPs through DNS, and round_robin distributes
RPCs across the resolved ready endpoints.
```

This does not change the gRPC message contract, REST behavior, database
ownership, benchmark semantics, retry behavior, or consistency model. It only
changes how gRPC clients choose backend pods.

## 5. UUID and Timestamp Rules

UUID values are represented as strings in gRPC messages. PostgreSQL stores UUIDs as native UUID values and generates new IDs using UUIDv7.

Timestamps use RFC3339 strings for simpler REST mapping:

```proto
string created_at = 4;
string updated_at = 5;
```

## 6. AuthService

```proto
service AuthService {
  rpc Register(RegisterRequest) returns (RegisterResponse);
  rpc Login(LoginRequest) returns (LoginResponse);
  rpc GetUserById(GetUserByIdRequest) returns (GetUserByIdResponse);
  rpc GetUsersByIds(GetUsersByIdsRequest) returns (GetUsersByIdsResponse);
}
```

`Register` creates a user and returns `UserSummary`. `Login` validates credentials, generates a JWT, and returns `token + UserSummary`. `GetUsersByIds` is used by API Gateway for enriched transaction responses.

`UserSummary` contains only:

```text
id, name, email
```

It must not expose password, password_hash, created_at, or updated_at.

## 7. ItemService

```proto
service ItemService {
  rpc SyncItems(SyncItemsRequest) returns (SyncItemsResponse);
  rpc ListItems(ListItemsRequest) returns (ListItemsResponse);
  rpc GetItemById(GetItemByIdRequest) returns (GetItemByIdResponse);
  rpc GetItemSummariesByIds(GetItemSummariesByIdsRequest) returns (GetItemSummariesByIdsResponse);
  rpc ValidateTransactionItems(ValidateTransactionItemsRequest) returns (ValidateTransactionItemsResponse);
}
```

`SyncItems` maps to `PUT /api/v1/items`. It receives the full active item snapshot. Active items omitted from the request are soft-deleted by setting `deleted_at`.

`SyncItems` semantics:

```text
id empty                         → create new item with DB-generated UUIDv7
id exists and active             → update item
id exists and soft-deleted       → reactivate item and update fields
id provided and not found        → insert item using provided id
active item omitted from payload → soft delete immediately, no cross-service check
```

Soft delete behavior:

```text
Items omitted from the sync payload are soft-deleted by setting deleted_at.
Item Service does not call Transaction Service to check usage before soft delete.
Items that have been used in transactions remain soft-deletable.
Transaction enrichment (GetItemSummariesByIds) includes soft-deleted items and marks them with deleted=true.
This allows transaction history to remain complete while indicating the item is no longer active.
```

Recommended database shape:

```sql
CREATE TABLE items (
    id UUID PRIMARY KEY DEFAULT uuidv7(),
    name TEXT NOT NULL,
    available_amount INT NOT NULL CHECK (available_amount >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ NULL
);

CREATE UNIQUE INDEX items_name_active_unique
ON items (name)
WHERE deleted_at IS NULL;
```

`ListItems` and `GetItemById` return active items only. `GetItemSummariesByIds` returns `id + name + deleted` for all requested IDs, including soft-deleted items, and is used for transaction enrichment. The `deleted` field allows the caller to mark items that are no longer active in the enriched response. `ValidateTransactionItems` checks active item existence and verifies `amount <= available_amount`; it does not deduct available_amount.

## 8. TransactionService

```proto
service TransactionService {
  rpc CreateTransaction(CreateTransactionRequest) returns (CreateTransactionResponse);
  rpc GetOwnTransactions(GetOwnTransactionsRequest) returns (GetOwnTransactionsResponse);
  rpc GetTransactionById(GetTransactionByIdRequest) returns (GetTransactionByIdResponse);
  rpc GetTransactionsForEnrichment(GetTransactionsForEnrichmentRequest) returns (GetTransactionsForEnrichmentResponse);
}
```

`CreateTransaction` maps to `POST /api/v1/transactions`. It validates item amounts through `ItemService.ValidateTransactionItems`, persists transaction data, and returns `transaction_id`. `ValidateTransactionItems` is validation-only in the current contract, so `CreateTransaction` does not deduct `available_amount` and does not store any `available_amount_after` snapshot.

Transactions are historical records and do not use soft delete in the current scope.

`GetTransactionsForEnrichment` returns raw transaction data only. It does not call AuthService or ItemService. API Gateway performs enrichment by calling:

```text
AuthService.GetUsersByIds
ItemService.GetItemSummariesByIds
```

## 9. REST-to-gRPC Mapping

| REST Endpoint | gRPC Mapping |
|---|---|
| `GET /healthz` | handled by API Gateway |
| `POST /api/v1/auth/register` | `AuthService.Register` |
| `POST /api/v1/auth/login` | `AuthService.Login` |
| `PUT /api/v1/items` | `ItemService.SyncItems` |
| `GET /api/v1/items` | `ItemService.ListItems` |
| `GET /api/v1/items/{item_id}` | `ItemService.GetItemById` |
| `POST /api/v1/transactions` | `TransactionService.CreateTransaction` + `ItemService.ValidateTransactionItems` |
| `GET /api/v1/transactions` | `TransactionService.GetOwnTransactions` |
| `GET /api/v1/transactions/{transaction_id}` | `TransactionService.GetTransactionById` |
| `GET /api/v1/admin/transactions` | `TransactionService.GetTransactionsForEnrichment` + `AuthService.GetUsersByIds` + `ItemService.GetItemSummariesByIds` |

There is no external item delete endpoint in the final contract. Item deletion is handled by item sync omission and implemented as soft delete.

## 10. Error Mapping

| gRPC Code | HTTP Code | Meaning |
|---|---:|---|
| `InvalidArgument` | 400 | Invalid request |
| `Unauthenticated` | 401 | Invalid or missing authentication |
| `PermissionDenied` | 403 | Forbidden |
| `NotFound` | 404 | Resource not found |
| `AlreadyExists` | 409 | Duplicate active resource |
| `FailedPrecondition` | 409 | Business conflict, such as amount exceeding available_amount |
| `Aborted` | 409 | Transaction or concurrency conflict |
| `Unavailable` | 503 | Upstream service unavailable |
| `ResourceExhausted` | 503 | Service accepted no more work, such as login admission overload |
| `Canceled` | 499 | Client canceled request |
| `DeadlineExceeded` | 503 | Upstream timeout surfaced as service unavailable |
| `Internal` | 500 | Internal error |

Timeout behavior notes:

- API Gateway applies `GRPC_CALL_TIMEOUT` to every outbound gRPC call to Auth
  Service, Item Service, and Transaction Service.
- Auth Service, Item Service, and Transaction Service apply
  `GRPC_REQUEST_TIMEOUT` as a server-side unary request deadline.
- Transaction Service applies `ITEM_VALIDATION_TIMEOUT` when it calls Item
  Service for `ValidateTransactionItems`.
- Auth Service returns `ResourceExhausted` when login admission control rejects
  a request because bcrypt capacity is full. API Gateway maps this to HTTP
  `503` with the normal error envelope.
- If the caller disconnects first, the translated REST status remains `499`.
- If the outbound gRPC deadline expires first, the translated REST status is
  `503`.

REST error envelope:

```json
{
  "error": {
    "code": "BAD_REQUEST",
    "message": "Invalid request payload",
    "details": null
  }
}
```

Do not include a top-level `status` field.

## 11. Benchmark Flow Mapping

Benchmark 1, login:

```text
Client/k6 -> API Gateway -> AuthService.Login -> auth_db -> Client
```

Benchmark 2, create transaction:

```text
Client/k6 -> API Gateway -> TransactionService.CreateTransaction -> ItemService.ValidateTransactionItems -> item_db -> transaction_db -> Client
```

Benchmark 3, enriched transactions:

```text
Client/k6 -> API Gateway -> TransactionService.GetTransactionsForEnrichment -> transaction_db
API Gateway -> AuthService.GetUsersByIds -> auth_db
API Gateway -> ItemService.GetItemSummariesByIds -> item_db
API Gateway performs in-memory enrichment -> Client
```

Optional benchmark, sync items:

```text
Client/k6 -> API Gateway -> ItemService.SyncItems -> item_db -> Client
```

## 12. Development Priority

```text
1. Auth Service
2. Item Service
3. Transaction Service
4. API Gateway
5. Dockerfiles for MSA services
6. ECR repositories for MSA services
7. CodeBuild buildspec update for all images
8. k6 smoke test through API Gateway
9. Datadog tracing
10. Kubernetes deployment
```

For parallel item and transaction development:

```text
1. finalize item.proto and transaction.proto
2. generate Go code
3. develop item-service normally
4. develop transaction-service with mock ItemService client
5. replace mock with real gRPC client after item-service is ready
```
