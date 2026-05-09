# gRPC Contracts

## 1. Purpose

This document defines the final internal gRPC contract design for the microservices architecture in the thesis benchmark project.

The external API is REST HTTP and is defined in:

```text
openapi.yaml
```

The internal microservices communication uses gRPC.

This document defines:

```text
- service boundaries
- gRPC service methods
- request and response semantics
- UUID and timestamp representation
- REST-to-gRPC mapping
- error mapping
- benchmark-relevant service flows
```

The gRPC contracts must preserve the external behavior defined by the latest OpenAPI specification.

---

## 2. Current REST API Alignment

The latest REST API contract uses these principles:

```text
Success response:
- represented by HTTP status code
- no top-level status: success field

Error response:
- structured error object

Register/Login:
- return user summary
- login also returns token

Create transaction:
- returns message + generated transaction id

Item mutation:
- PUT /api/v1/items performs bulk save
- success response returns message only

Enriched transaction:
- uses UserSummary and ItemSummary
- does not expose Item.available_amount inside enriched transaction items
```

The API Gateway is responsible for wrapping gRPC responses into REST response bodies.

---

## 3. Scope

This document applies only to the microservices architecture.

Microservices using gRPC:

```text
API Gateway
Auth Service
Item Service
Transaction Service
```

Service roles:

```text
API Gateway
→ REST HTTP server for external clients
→ gRPC client to Auth, Item, and Transaction services
→ JWT validation for protected routes
→ REST response mapping
→ enriched transaction aggregation

Auth Service
→ owns users and authentication
→ owns auth_db

Item Service
→ owns item master data
→ owns item_db

Transaction Service
→ owns transactions and transaction_items
→ owns transaction_db
→ calls Item Service only for transaction item validation during transaction creation
```

The monolith does not use internal gRPC.

---

## 4. Proto File Locations

Proto files are stored under:

```text
proto/
```

Final structure:

```text
proto/
├── auth/
│   └── v1/
│       └── auth.proto
├── item/
│   └── v1/
│       └── item.proto
└── transaction/
    └── v1/
        └── transaction.proto
```

Recommended generated Go package structure:

```text
proto/gen/auth/v1
proto/gen/item/v1
proto/gen/transaction/v1
```

Generated code must not be manually edited.

Generated code should not be placed inside a service-specific `internal/` package if it must be imported by the API Gateway or another service.

---

## 5. Communication Overview

External client flow:

```text
Client / k6
    |
    v
REST HTTP
    |
    v
API Gateway
```

Internal service flow:

```text
API Gateway
    |
    +--> Auth Service via gRPC
    |
    +--> Item Service via gRPC
    |
    +--> Transaction Service via gRPC
```

Transaction creation flow:

```text
API Gateway
    |
    v
Transaction Service
    |
    v
Item Service
```

Enriched transaction flow:

```text
API Gateway
    |
    +--> Transaction Service
    |
    +--> Auth Service
    |
    +--> Item Service
    |
    v
API Gateway performs in-memory aggregation
```

Rules:

```text
- API Gateway must not access databases directly.
- Business services must not access another service's database directly.
- Business services communicate through gRPC only.
```

---

## 6. UUID Representation

PostgreSQL stores IDs as native UUID.

In gRPC contracts, UUID values are represented as strings.

Examples:

```proto
string user_id = 1;
string item_id = 2;
string transaction_id = 3;
```

Rules:

```text
- UUID values must use valid UUID string format.
- PostgreSQL generates UUIDv7 for new records.
- Services must validate UUID strings at service boundaries.
- Do not use custom IDs such as USR-001, ITM-001, or TX-001.
```

---

## 7. Timestamp Representation

For this project, timestamps in gRPC responses use RFC3339 strings.

Example:

```proto
string created_at = 10;
string updated_at = 11;
```

Reason:

```text
- simpler mapping to REST date-time strings
- simpler implementation in Go
- sufficient for thesis benchmarking
```

The REST API still returns timestamps as strings with `format: date-time`.

---

## 8. Authentication Context Propagation

External JWT validation is handled by the API Gateway for protected REST routes.

The API Gateway extracts the authenticated user id from the JWT and passes it explicitly to internal gRPC calls.

Recommended approach:

```text
Use explicit user_id fields in gRPC request messages.
```

Example:

```proto
message CreateTransactionRequest {
  string user_id = 1;
  repeated TransactionItemInput items = 2;
}
```

Reason:

```text
- easier to inspect
- easier to test
- easier to document
- clearer for benchmark reproducibility
```

---

# 9. AuthService Contract

Proto file:

```text
proto/auth/v1/auth.proto
```

Recommended proto header:

```proto
syntax = "proto3";

package auth.v1;

option go_package = "github.com/Ahmad-mufied/monolith-vs-microservice-thesis/proto/gen/auth/v1;authv1";
```

Service:

```proto
service AuthService {
  rpc Register(RegisterRequest) returns (RegisterResponse);
  rpc Login(LoginRequest) returns (LoginResponse);
  rpc GetUserById(GetUserByIdRequest) returns (GetUserByIdResponse);
  rpc GetUsersByIds(GetUsersByIdsRequest) returns (GetUsersByIdsResponse);
}
```

## 9.1 Register

Used by:

```text
API Gateway
```

REST endpoint:

```text
POST /api/v1/auth/register
```

Request:

```proto
message RegisterRequest {
  string name = 1;
  string email = 2;
  string password = 3;
}
```

Response:

```proto
message RegisterResponse {
  UserSummary user = 1;
}
```

Behavior:

```text
- validate name
- validate email
- validate password
- hash password
- insert user into auth_db.users
- database generates UUID using uuidv7()
- return user summary without password_hash
```

Expected gRPC errors:

```text
InvalidArgument → invalid request payload
AlreadyExists   → email already exists
Internal        → database or unexpected server error
```

API Gateway maps success to REST:

```json
{
  "message": "User registered successfully",
  "data": {
    "user": {
      "id": "...",
      "name": "...",
      "email": "..."
    }
  }
}
```

## 9.2 Login

Used by:

```text
API Gateway
```

REST endpoint:

```text
POST /api/v1/auth/login
```

Benchmark:

```text
Benchmark 1: CPU-bound authentication workload
```

Request:

```proto
message LoginRequest {
  string email = 1;
  string password = 2;
}
```

Response:

```proto
message LoginResponse {
  string token = 1;
  UserSummary user = 2;
}
```

Behavior:

```text
- validate email and password
- find user by email
- compare password using bcrypt
- generate JWT with authenticated user id in the standard subject claim
- return token and user summary
```

Expected gRPC errors:

```text
InvalidArgument  → invalid request payload
Unauthenticated  → invalid email or password
Internal         → database or unexpected server error
```

For invalid auth input, the service may attach field-level validation detail
using gRPC `BadRequest` field violations, for example invalid `email` format or
password exceeding bcrypt's 72-byte limit.

API Gateway maps success to REST:

```json
{
  "message": "Login successful",
  "data": {
    "token": "...",
    "user": {
      "id": "...",
      "name": "...",
      "email": "..."
    }
  }
}
```

## 9.3 GetUserById

Used by:

```text
API Gateway
```

Purpose:

```text
Return one user summary by id.
```

Request:

```proto
message GetUserByIdRequest {
  string user_id = 1;
}
```

Response:

```proto
message GetUserByIdResponse {
  UserSummary user = 1;
}
```

Expected gRPC errors:

```text
InvalidArgument → invalid UUID
NotFound        → user not found
Internal        → database or unexpected server error
```

## 9.4 GetUsersByIds

Used by:

```text
API Gateway
```

Benchmark relevance:

```text
Benchmark 3: enriched transactions
```

Request:

```proto
message GetUsersByIdsRequest {
  repeated string user_ids = 1;
}
```

Response:

```proto
message GetUsersByIdsResponse {
  repeated UserSummary users = 1;
}
```

Behavior:

```text
- validate UUID values
- query auth_db.users
- return matching user summaries
```

For benchmark consistency, seed data should ensure all referenced users exist.

## 9.5 UserSummary Message

```proto
message UserSummary {
  string id = 1;
  string name = 2;
  string email = 3;
}
```

Do not expose:

```text
password
password_hash
```

---

# 10. ItemService Contract

Proto file:

```text
proto/item/v1/item.proto
```

Recommended proto header:

```proto
syntax = "proto3";

package item.v1;

option go_package = "github.com/mufied/skripsi-benchmark/proto/gen/go/item/v1;itemv1";
```

Service:

```proto
service ItemService {
  rpc BulkSaveItems(BulkSaveItemsRequest) returns (BulkSaveItemsResponse);
  rpc ListItems(ListItemsRequest) returns (ListItemsResponse);
  rpc GetItemById(GetItemByIdRequest) returns (GetItemByIdResponse);
  rpc DeleteItem(DeleteItemRequest) returns (DeleteItemResponse);
  rpc GetItemSummariesByIds(GetItemSummariesByIdsRequest) returns (GetItemSummariesByIdsResponse);
  rpc ValidateTransactionItems(ValidateTransactionItemsRequest) returns (ValidateTransactionItemsResponse);
}
```

## 10.1 BulkSaveItems

Used by:

```text
API Gateway
```

REST endpoint:

```text
PUT /api/v1/items
```

Optional benchmark:

```text
Bulk write workload
```

Request:

```proto
message BulkSaveItemsRequest {
  repeated BulkSaveItemInput items = 1;
}

message BulkSaveItemInput {
  string id = 1;
  string name = 2;
  int64 available_amount = 3;
}
```

Response:

```proto
message BulkSaveItemsResponse {
}
```

Behavior:

```text
- if id is provided and item exists: update item
- if id is provided and item does not exist: insert item using the provided id
- if id is not provided: create new item using database-generated UUIDv7
- if a unique constraint such as item name is violated: return AlreadyExists
- execute the operation atomically in one database transaction
- rollback all changes if one item is invalid
```

REST success response:

```json
{
  "message": "Items saved successfully"
}
```

The gRPC response does not need to return item IDs because the REST API uses `GET /api/v1/items` to retrieve current item state.

## 10.2 ListItems

Used by:

```text
API Gateway
```

REST endpoint:

```text
GET /api/v1/items
```

Request:

```proto
message ListItemsRequest {
  int32 limit = 1;
  int32 offset = 2;
}
```

Response:

```proto
message ListItemsResponse {
  repeated Item items = 1;
  int32 total_returned = 2;
}
```

Default ordering:

```text
created_at DESC, id DESC
```

## 10.3 GetItemById

Used by:

```text
API Gateway
```

REST endpoint:

```text
GET /api/v1/items/{item_id}
```

Request:

```proto
message GetItemByIdRequest {
  string item_id = 1;
}
```

Response:

```proto
message GetItemByIdResponse {
  Item item = 1;
}
```

## 10.4 DeleteItem

Used by:

```text
API Gateway
```

REST endpoint:

```text
DELETE /api/v1/items/{item_id}
```

Request:

```proto
message DeleteItemRequest {
  string item_id = 1;
}
```

Response:

```proto
message DeleteItemResponse {
}
```

REST success response:

```json
{
  "message": "Item deleted successfully"
}
```

## 10.5 GetItemSummariesByIds

Used by:

```text
API Gateway
```

Benchmark relevance:

```text
Benchmark 3: enriched transactions
```

Request:

```proto
message GetItemSummariesByIdsRequest {
  repeated string item_ids = 1;
}
```

Response:

```proto
message GetItemSummariesByIdsResponse {
  repeated ItemSummary items = 1;
}
```

Important:

```text
This method returns ItemSummary, not full Item.
It must not return available_amount for the enriched transaction response.
```

## 10.6 ValidateTransactionItems

Used by:

```text
Transaction Service
```

Benchmark relevance:

```text
Benchmark 2: create transaction
```

Request:

```proto
message ValidateTransactionItemsRequest {
  repeated TransactionItemValidationInput items = 1;
}

message TransactionItemValidationInput {
  string item_id = 1;
  int64 amount = 2;
}
```

Response:

```proto
message ValidateTransactionItemsResponse {
}
```

Behavior:

```text
- validate UUID format
- validate amount > 0
- check that every item exists
- check that amount <= item.available_amount
- return success if all items are valid
- do not deduct available_amount
```

Reason:

```text
The latest REST contract only requires rejecting transactions whose amount exceeds available_amount.
It does not require inventory deduction or allocation semantics.
Keeping validation read-only avoids unnecessary distributed write complexity.
```

Expected gRPC errors:

```text
InvalidArgument     → invalid item id or amount
NotFound            → item not found
FailedPrecondition  → amount exceeds available_amount
Internal            → database or unexpected server error
```

## 10.7 Item Message

Used by item list and detail responses.

```proto
message Item {
  string id = 1;
  string name = 2;
  int64 available_amount = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

Use `available_amount` for item state.

Do not use `amount`, `stock`, or `quantity` for item state.

## 10.8 ItemSummary Message

Used by enriched transaction response.

```proto
message ItemSummary {
  string id = 1;
  string name = 2;
}
```

Do not include:

```text
available_amount
created_at
updated_at
```

Reason:

```text
The enriched transaction response only needs item identity and item name.
The transaction item amount is represented separately by TransactionEnrichedItem.amount.
```

---

# 11. TransactionService Contract

Proto file:

```text
proto/transaction/v1/transaction.proto
```

Recommended proto header:

```proto
syntax = "proto3";

package transaction.v1;

option go_package = "github.com/mufied/skripsi-benchmark/proto/gen/go/transaction/v1;transactionv1";
```

Service:

```proto
service TransactionService {
  rpc CreateTransaction(CreateTransactionRequest) returns (CreateTransactionResponse);
  rpc GetOwnTransactions(GetOwnTransactionsRequest) returns (GetOwnTransactionsResponse);
  rpc GetTransactionById(GetTransactionByIdRequest) returns (GetTransactionByIdResponse);
  rpc GetTransactionsForEnrichment(GetTransactionsForEnrichmentRequest) returns (GetTransactionsForEnrichmentResponse);
}
```

## 11.1 CreateTransaction

Used by:

```text
API Gateway
```

REST endpoint:

```text
POST /api/v1/transactions
```

Benchmark:

```text
Benchmark 2: write-heavy database workload
```

Request:

```proto
message CreateTransactionRequest {
  string user_id = 1;
  repeated TransactionItemInput items = 2;
}

message TransactionItemInput {
  string item_id = 1;
  int64 amount = 2;
}
```

Response:

```proto
message CreateTransactionResponse {
  string transaction_id = 1;
}
```

Behavior:

```text
- validate user_id UUID
- validate item_id UUIDs
- validate amount > 0
- call ItemService.ValidateTransactionItems
- insert transaction into transaction_db.transactions
- database generates transaction ID using uuidv7()
- insert transaction items into transaction_db.transaction_items
- return transaction_id
```

The response must only be returned after validation and transaction persistence are complete.

Do not implement asynchronous write-behind behavior.

REST success response:

```json
{
  "message": "Transaction created successfully",
  "data": {
    "id": "..."
  }
}
```

## 11.2 GetOwnTransactions

Used by:

```text
API Gateway
```

REST endpoint:

```text
GET /api/v1/transactions
```

Request:

```proto
message GetOwnTransactionsRequest {
  string user_id = 1;
  int32 limit = 2;
  int32 offset = 3;
}
```

Response:

```proto
message GetOwnTransactionsResponse {
  repeated Transaction transactions = 1;
  int32 total_returned = 2;
}
```

Default ordering:

```text
created_at DESC, id DESC
```

## 11.3 GetTransactionById

Used by:

```text
API Gateway
```

REST endpoint:

```text
GET /api/v1/transactions/{transaction_id}
```

Request:

```proto
message GetTransactionByIdRequest {
  string transaction_id = 1;
  string user_id = 2;
}
```

Response:

```proto
message GetTransactionByIdResponse {
  Transaction transaction = 1;
}
```

Behavior:

```text
- validate transaction_id
- validate user_id
- return transaction only if it belongs to the authenticated user
```

## 11.4 GetTransactionsForEnrichment

Used by:

```text
API Gateway
```

REST endpoint:

```text
GET /api/v1/admin/transactions
```

Benchmark:

```text
Benchmark 3: read-heavy distributed aggregation workload
```

Request:

```proto
message GetTransactionsForEnrichmentRequest {
  int32 limit = 1;
  int32 offset = 2;
}
```

Response:

```proto
message GetTransactionsForEnrichmentResponse {
  repeated TransactionForEnrichment transactions = 1;
  int32 total_returned = 2;
}
```

Behavior:

```text
- query transactions from transaction_db
- query transaction_items from transaction_db
- return transaction data with user_id and item_ids
- do not call Auth Service
- do not call Item Service
```

The API Gateway performs enrichment by calling:

```text
AuthService.GetUsersByIds
ItemService.GetItemSummariesByIds
```

## 11.5 Transaction Message

Used by regular transaction list and detail responses.

```proto
message Transaction {
  string id = 1;
  string user_id = 2;
  repeated TransactionItem items = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

The current REST schema does not expose transaction status.

## 11.6 TransactionItem Message

```proto
message TransactionItem {
  string item_id = 1;
  int64 amount = 2;
}
```

The current REST TransactionItem response exposes only:

```text
item_id
amount
```

Do not expose `available_amount_after`, `created_at`, or `updated_at` unless the REST contract is updated.

## 11.7 TransactionForEnrichment Message

Used internally by the API Gateway to construct REST `EnrichedTransaction`.

```proto
message TransactionForEnrichment {
  string id = 1;
  string user_id = 2;
  repeated TransactionItem items = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

API Gateway maps this together with `UserSummary` and `ItemSummary` into the REST response.

---

# 12. API Gateway Responsibilities

The API Gateway is responsible for:

```text
- exposing REST HTTP endpoints
- parsing REST requests
- validating JWT for protected routes
- extracting authenticated user_id
- calling internal gRPC services
- mapping gRPC responses to REST responses
- mapping gRPC errors to REST errors
- performing enriched transaction aggregation
```

The API Gateway must not:

```text
- access service databases directly
- bypass gRPC service boundaries
- return raw gRPC errors to external clients
```

---

# 13. REST-to-gRPC Mapping

| REST Endpoint | gRPC Flow |
|---|---|
| `POST /api/v1/auth/register` | `API Gateway -> AuthService.Register` |
| `POST /api/v1/auth/login` | `API Gateway -> AuthService.Login` |
| `PUT /api/v1/items` | `API Gateway -> ItemService.BulkSaveItems` |
| `GET /api/v1/items` | `API Gateway -> ItemService.ListItems` |
| `GET /api/v1/items/{item_id}` | `API Gateway -> ItemService.GetItemById` |
| `DELETE /api/v1/items/{item_id}` | `API Gateway -> ItemService.DeleteItem` |
| `POST /api/v1/transactions` | `API Gateway -> TransactionService.CreateTransaction`, then `TransactionService -> ItemService.ValidateTransactionItems` |
| `GET /api/v1/transactions` | `API Gateway -> TransactionService.GetOwnTransactions` |
| `GET /api/v1/transactions/{transaction_id}` | `API Gateway -> TransactionService.GetTransactionById` |
| `GET /api/v1/admin/transactions` | `API Gateway -> TransactionService.GetTransactionsForEnrichment`, `AuthService.GetUsersByIds`, `ItemService.GetItemSummariesByIds` |

---

# 14. Error Mapping

gRPC errors must be mapped to REST errors by the API Gateway.

| gRPC Code | HTTP Code | Meaning |
|---|---:|---|
| `InvalidArgument` | 400 | Invalid request |
| `Unauthenticated` | 401 | Invalid or missing authentication |
| `PermissionDenied` | 403 | Forbidden |
| `NotFound` | 404 | Resource not found |
| `AlreadyExists` | 409 | Duplicate resource |
| `FailedPrecondition` | 409 | Business rule conflict, such as amount exceeding available_amount |
| `Aborted` | 409 | Transaction or concurrency conflict |
| `Unavailable` | 503 | Upstream service unavailable |
| `DeadlineExceeded` | 504 | Upstream timeout |
| `Internal` | 500 | Internal error |

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

Do not include a top-level `status` field in error responses.

Do not expose raw gRPC error details directly to external clients.

---

# 15. Timeout Rules

Every gRPC call should use a context timeout.

| Call | Suggested Timeout |
|---|---:|
| API Gateway -> AuthService.Register | 2s |
| API Gateway -> AuthService.Login | 2s |
| API Gateway -> ItemService.BulkSaveItems | 3s |
| API Gateway -> ItemService.ListItems | 2s |
| API Gateway -> TransactionService.CreateTransaction | 3s |
| TransactionService -> ItemService.ValidateTransactionItems | 2s |
| API Gateway -> TransactionService.GetTransactionsForEnrichment | 2s |
| API Gateway -> AuthService.GetUsersByIds | 2s |
| API Gateway -> ItemService.GetItemSummariesByIds | 2s |

Do not add retries unless explicitly required and documented.

Reason:

```text
Retries can change benchmark semantics and may hide failure behavior.
```

---

# 16. Benchmark Flow Mapping

## 16.1 Benchmark 1: Login

```text
Client / k6
-> API Gateway
-> AuthService.Login
-> auth_db.users
-> API Gateway
-> Client
```

Measured workload:

```text
- request parsing
- password hash comparison
- JWT generation
- database lookup
```

## 16.2 Benchmark 2: Create Transaction

```text
Client / k6
-> API Gateway
-> TransactionService.CreateTransaction
-> ItemService.ValidateTransactionItems
-> item_db.items
-> transaction_db.transactions
-> transaction_db.transaction_items
-> API Gateway
-> Client
```

Measured workload:

```text
- REST-to-gRPC gateway overhead
- transaction validation
- service-to-service call
- transaction database writes
```

## 16.3 Benchmark 3: Get Enriched Transactions

```text
Client / k6
-> API Gateway
-> TransactionService.GetTransactionsForEnrichment
-> transaction_db
-> API Gateway
-> AuthService.GetUsersByIds
-> auth_db
-> API Gateway
-> ItemService.GetItemSummariesByIds
-> item_db
-> API Gateway in-memory enrichment
-> Client
```

Measured workload:

```text
- distributed read aggregation
- gateway fan-out
- batch gRPC calls
- in-memory joining
- response serialization
```

## 16.4 Optional Benchmark: Bulk Save Items

```text
Client / k6
-> API Gateway
-> ItemService.BulkSaveItems
-> item_db.items
-> API Gateway
-> Client
```

Measured workload:

```text
- bulk JSON parsing
- REST-to-gRPC mapping
- batch validation
- insert/update branching
- database transaction
```

---

# 17. Fairness Rules

The gRPC implementation must preserve external API equivalence with the monolith.

Rules:

```text
- Microservices must not do less work than the monolith before returning a response.
- API Gateway must call the relevant service for each REST endpoint.
- CreateTransaction must complete validation and transaction persistence before returning.
- Enriched transaction must perform distributed aggregation through gRPC calls.
- The API Gateway must not directly query service databases.
```

Do not implement:

```text
publish event -> return response -> process later
```

for any benchmark endpoint.

---

# 18. Code Generation Rules

After editing proto files:

```text
1. regenerate Go code
2. update affected gRPC servers
3. update affected gRPC clients
4. update API Gateway mapping
5. update tests
6. update this document if behavior changes
```

Do not manually edit generated code.

---

# 19. Compatibility Rules

Do not reuse proto field numbers.

If a field is removed:

```proto
reserved 3;
reserved "old_field_name";
```

If a field is no longer used but compatibility matters:

```text
- keep it temporarily
- mark it as deprecated in comments
- do not reuse its field number
```

---

# 20. Out of Scope

The following are out of scope for the initial implementation:

```text
Kafka
RabbitMQ
asynchronous transaction processing
saga pattern
distributed transaction coordinator
service mesh
circuit breaker
automatic retries
KEDA-based autoscaling
RPS-based autoscaling
```

These can be discussed as future work, but they are not part of the main experimental design.

---

# 21. Development Priority

Recommended implementation order:

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

For immediate development, start with:

```text
AuthService.Register
AuthService.Login
AuthService.GetUserById
AuthService.GetUsersByIds
```

---

# 22. Summary

Final contract rules:

```text
External API      : REST HTTP through API Gateway
Internal protocol : gRPC
ID representation : string UUID
Timestamp format  : string RFC3339
Auth ownership    : AuthService
Item ownership    : ItemService
Transaction owner : TransactionService
Gateway role      : REST mapping, JWT validation, distributed enrichment
```

Benchmark mapping:

```text
Benchmark 1:
API Gateway -> AuthService.Login

Benchmark 2:
API Gateway -> TransactionService.CreateTransaction
TransactionService -> ItemService.ValidateTransactionItems

Benchmark 3:
API Gateway -> TransactionService.GetTransactionsForEnrichment
API Gateway -> AuthService.GetUsersByIds
API Gateway -> ItemService.GetItemSummariesByIds

Optional benchmark:
API Gateway -> ItemService.BulkSaveItems
```

The gRPC contracts must preserve service ownership boundaries while keeping the external REST behavior equivalent to the monolith implementation.
