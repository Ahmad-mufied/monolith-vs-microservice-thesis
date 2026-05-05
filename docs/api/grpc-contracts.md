# gRPC Contracts

## 1. Purpose

This document describes the internal gRPC contract design for the microservices architecture.

The external API is REST HTTP and is defined in:

```text
openapi.yaml
```

The internal microservices communication uses gRPC.

The purpose of this document is to define:

- service-to-service contracts,
- method responsibilities,
- request and response semantics,
- UUID representation,
- error mapping expectations,
- benchmark-related gRPC flows.

---

## 2. Scope

This document applies only to the microservices architecture.

Microservices that use gRPC:

- API Gateway as gRPC client,
- Auth Service as gRPC server,
- Item Service as gRPC server,
- Transaction Service as gRPC server,
- Transaction Service as gRPC client to Auth Service and Item Service.

The monolith does not use gRPC internally.

---

## 3. Proto File Locations

Proto files are stored under:

```text
proto/
```

Final proto structure:

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

Generated Go code should be placed in a predictable generated package path, depending on the chosen code generation strategy.

The exact output path can be finalized during implementation, but it must be consistent across services.

---

## 4. Communication Overview

External client communication:

```text
Client / k6
    |
    v
REST HTTP
    |
    v
API Gateway
```

Internal microservices communication:

```text
API Gateway
    |
    v
gRPC
    |
    v
Auth Service / Item Service / Transaction Service
```

Service-to-service communication:

```text
Transaction Service
    |
    +--> Auth Service via gRPC
    |
    +--> Item Service via gRPC
```

The API Gateway must not access databases directly.

Business services must not access another service's database directly.

---

## 5. UUID Representation

PostgreSQL stores IDs as native UUID.

In gRPC contracts, UUID values are represented as strings.

Example:

```proto
string user_id = 1;
string item_id = 2;
string transaction_id = 3;
```

All UUID string fields must contain valid UUID values.

The application code must validate UUID format at the appropriate boundary.

Do not use custom string labels such as:

```text
USR-001
ITM-001
TX-999
```

---

## 6. Timestamp Representation

For simplicity, timestamps in gRPC responses may use string values in RFC3339 format.

Example:

```proto
string created_at = 10;
string updated_at = 11;
```

Alternative option:

```proto
google.protobuf.Timestamp created_at = 10;
google.protobuf.Timestamp updated_at = 11;
```

Recommended for this project:

```text
Use google.protobuf.Timestamp if implementation complexity is acceptable.
Use string RFC3339 timestamps if simpler implementation is preferred.
```

The REST API must still return timestamps as `string` with `format: date-time`.

---

## 7. Service List

The microservices architecture defines these gRPC services:

```text
AuthService
ItemService
TransactionService
```

Service ownership:

| Service | Owner | Database |
|---|---|---|
| AuthService | auth-service | auth_db |
| ItemService | item-service | item_db |
| TransactionService | transaction-service | transaction_db |

API Gateway consumes all three services.

Transaction Service consumes AuthService and ItemService for enrichment and allocation flows.

---

## 8. AuthService Contract

Proto file:

```text
proto/auth/v1/auth.proto
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

---

## 8.1 Register

Used by:

```text
API Gateway
```

Purpose:

Create a new user.

Request concept:

```proto
message RegisterRequest {
  string name = 1;
  string email = 2;
  string password = 3;
}
```

Response concept:

```proto
message RegisterResponse {
  User user = 1;
}
```

Behavior:

- validate name, email, and password,
- hash password,
- insert user into `auth_db.users`,
- database generates UUID using `uuidv7()`,
- return created user without password_hash.

---

## 8.2 Login

Used by:

```text
API Gateway
```

Benchmark:

```text
Benchmark 1
```

Purpose:

Authenticate user and return JWT.

Request concept:

```proto
message LoginRequest {
  string email = 1;
  string password = 2;
}
```

Response concept:

```proto
message LoginResponse {
  string token = 1;
  User user = 2;
}
```

Behavior:

- find user by email,
- compare password using bcrypt,
- generate JWT,
- return token and user data.

Expected error cases:

- user not found,
- invalid password,
- invalid request,
- internal error.

---

## 8.3 GetUserById

Used by:

```text
Transaction Service
```

Purpose:

Return one user by ID.

Request concept:

```proto
message GetUserByIdRequest {
  string user_id = 1;
}
```

Response concept:

```proto
message GetUserByIdResponse {
  User user = 1;
}
```

---

## 8.4 GetUsersByIds

Used by:

```text
Transaction Service
```

Benchmark relevance:

```text
Benchmark 3: enriched transactions
```

Purpose:

Batch fetch users for transaction enrichment.

Request concept:

```proto
message GetUsersByIdsRequest {
  repeated string user_ids = 1;
}
```

Response concept:

```proto
message GetUsersByIdsResponse {
  repeated User users = 1;
}
```

Behavior:

- validate UUIDs,
- query `auth_db.users`,
- return matching users.

Important:

The response may return fewer users than requested if some IDs are missing. The Transaction Service must decide how to handle missing references.

For benchmark consistency, seed data should ensure all referenced users exist.

---

## 8.5 User Message

Concept:

```proto
message User {
  string id = 1;
  string name = 2;
  string email = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

Do not expose:

```text
password
password_hash
```

---

## 9. ItemService Contract

Proto file:

```text
proto/item/v1/item.proto
```

Service:

```proto
service ItemService {
  rpc CreateItem(CreateItemRequest) returns (CreateItemResponse);
  rpc GetItemById(GetItemByIdRequest) returns (GetItemByIdResponse);
  rpc GetItemsByIds(GetItemsByIdsRequest) returns (GetItemsByIdsResponse);
  rpc ListItems(ListItemsRequest) returns (ListItemsResponse);
  rpc UpdateItem(UpdateItemRequest) returns (UpdateItemResponse);
  rpc DeleteItem(DeleteItemRequest) returns (DeleteItemResponse);
  rpc ValidateAndAllocate(ValidateAndAllocateRequest) returns (ValidateAndAllocateResponse);
}
```

---

## 9.1 CreateItem

Used by:

```text
API Gateway
```

Purpose:

Create a new item.

Request concept:

```proto
message CreateItemRequest {
  string name = 1;
  int64 available_amount = 2;
}
```

Response concept:

```proto
message CreateItemResponse {
  Item item = 1;
}
```

Behavior:

- validate name,
- validate `available_amount >= 0`,
- insert item into `item_db.items`,
- database generates UUID using `uuidv7()`,
- return created item.

---

## 9.2 GetItemById

Used by:

```text
API Gateway
```

Purpose:

Return one item by ID.

Request concept:

```proto
message GetItemByIdRequest {
  string item_id = 1;
}
```

Response concept:

```proto
message GetItemByIdResponse {
  Item item = 1;
}
```

---

## 9.3 GetItemsByIds

Used by:

```text
Transaction Service
```

Benchmark relevance:

```text
Benchmark 3: enriched transactions
```

Purpose:

Batch fetch items for transaction enrichment.

Request concept:

```proto
message GetItemsByIdsRequest {
  repeated string item_ids = 1;
}
```

Response concept:

```proto
message GetItemsByIdsResponse {
  repeated Item items = 1;
}
```

For benchmark consistency, seed data should ensure all referenced items exist.

---

## 9.4 ListItems

Used by:

```text
API Gateway
```

Purpose:

Return item list.

Request concept:

```proto
message ListItemsRequest {
  int32 limit = 1;
  int32 offset = 2;
}
```

Response concept:

```proto
message ListItemsResponse {
  repeated Item items = 1;
  int32 total_returned = 2;
}
```

---

## 9.5 UpdateItem

Used by:

```text
API Gateway
```

Purpose:

Update item attributes.

Request concept:

```proto
message UpdateItemRequest {
  string item_id = 1;
  string name = 2;
  int64 available_amount = 3;
}
```

Response concept:

```proto
message UpdateItemResponse {
  Item item = 1;
}
```

Notes:

- this endpoint is for CRUD/demo behavior,
- benchmark transaction allocation should use `ValidateAndAllocate`, not direct item update.

---

## 9.6 DeleteItem

Used by:

```text
API Gateway
```

Purpose:

Delete item.

Request concept:

```proto
message DeleteItemRequest {
  string item_id = 1;
}
```

Response concept:

```proto
message DeleteItemResponse {
  bool success = 1;
}
```

Delete should not be part of primary benchmark scenarios unless explicitly designed.

---

## 9.7 ValidateAndAllocate

Used by:

```text
Transaction Service
```

Benchmark:

```text
Benchmark 2
```

Purpose:

Validate item availability and deduct requested amount atomically.

Request concept:

```proto
message ValidateAndAllocateRequest {
  repeated AllocationRequest items = 1;
}

message AllocationRequest {
  string item_id = 1;
  int64 amount = 2;
}
```

Response concept:

```proto
message ValidateAndAllocateResponse {
  repeated AllocationResult items = 1;
}

message AllocationResult {
  string item_id = 1;
  int64 amount = 2;
  int64 available_amount_after = 3;
}
```

Behavior:

- validate UUID format,
- validate `amount > 0`,
- lock or update item rows safely,
- ensure `available_amount >= amount`,
- deduct requested amount,
- return `available_amount_after`.

Expected error cases:

- invalid item ID,
- item not found,
- invalid amount,
- insufficient available_amount,
- database error.

Atomicity requirement:

For a multi-item transaction, allocation should be handled consistently. If one item allocation fails, the allocation operation should not partially allocate other items.

Implementation option:

Use a database transaction inside Item Service.

---

## 9.8 Item Message

Concept:

```proto
message Item {
  string id = 1;
  string name = 2;
  int64 available_amount = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

Use:

```text
available_amount
```

Do not use:

```text
availability
stock
quantity
```

---

## 10. TransactionService Contract

Proto file:

```text
proto/transaction/v1/transaction.proto
```

Service:

```proto
service TransactionService {
  rpc CreateTransaction(CreateTransactionRequest) returns (CreateTransactionResponse);
  rpc GetOwnTransactions(GetOwnTransactionsRequest) returns (GetOwnTransactionsResponse);
  rpc GetAllTransactionsEnriched(GetAllTransactionsEnrichedRequest) returns (GetAllTransactionsEnrichedResponse);
}
```

---

## 10.1 CreateTransaction

Used by:

```text
API Gateway
```

Benchmark:

```text
Benchmark 2
```

Purpose:

Create transaction and coordinate item allocation.

Request concept:

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

Response concept:

```proto
message CreateTransactionResponse {
  Transaction transaction = 1;
}
```

Behavior:

- validate user_id UUID,
- validate item_id UUIDs,
- validate `amount > 0`,
- call Item Service `ValidateAndAllocate`,
- insert transaction into `transaction_db.transactions`,
- database generates transaction ID using `uuidv7()`,
- insert transaction_items into `transaction_db.transaction_items`,
- return transaction response.

Completion rule:

The response must be returned only after item allocation and transaction persistence are completed.

Do not return immediately after publishing an event or scheduling asynchronous work.

---

## 10.2 GetOwnTransactions

Used by:

```text
API Gateway
```

Purpose:

Return transactions for authenticated user.

Request concept:

```proto
message GetOwnTransactionsRequest {
  string user_id = 1;
  int32 limit = 2;
  int32 offset = 3;
}
```

Response concept:

```proto
message GetOwnTransactionsResponse {
  repeated Transaction transactions = 1;
  int32 total_returned = 2;
}
```

Behavior:

- validate user_id,
- query `transaction_db.transactions`,
- query `transaction_db.transaction_items`,
- return user's transaction history.

This endpoint does not need full enrichment unless explicitly required by the REST contract.

---

## 10.3 GetAllTransactionsEnriched

Used by:

```text
API Gateway
```

Benchmark:

```text
Benchmark 3
```

Purpose:

Return transactions enriched with user and item details.

Request concept:

```proto
message GetAllTransactionsEnrichedRequest {
  int32 limit = 1;
  int32 offset = 2;
}
```

Response concept:

```proto
message GetAllTransactionsEnrichedResponse {
  repeated TransactionEnriched transactions = 1;
  int32 total_returned = 2;
}
```

Behavior:

1. query transactions from `transaction_db`,
2. query transaction_items from `transaction_db`,
3. collect unique user_ids,
4. collect unique item_ids,
5. call Auth Service `GetUsersByIds`,
6. call Item Service `GetItemsByIds`,
7. join/enrich data in memory,
8. return enriched transactions.

This is the distributed join/fan-out benchmark flow.

---

## 10.4 Transaction Message

Concept:

```proto
message Transaction {
  string id = 1;
  string user_id = 2;
  string status = 3;
  repeated TransactionItem items = 4;
  string created_at = 5;
  string updated_at = 6;
}
```

---

## 10.5 TransactionItem Message

Concept:

```proto
message TransactionItem {
  string item_id = 1;
  int64 amount = 2;
  int64 available_amount_after = 3;
  string created_at = 4;
  string updated_at = 5;
}
```

---

## 10.6 TransactionEnriched Message

Concept:

```proto
message TransactionEnriched {
  string id = 1;
  string status = 2;
  UserSnapshot user = 3;
  repeated TransactionEnrichedItem items = 4;
  string created_at = 5;
  string updated_at = 6;
}
```

The enriched response may define local view messages instead of importing full Auth and Item message types directly.

Example:

```proto
message UserSnapshot {
  string id = 1;
  string name = 2;
  string email = 3;
}

message TransactionEnrichedItem {
  string id = 1;
  string name = 2;
  int64 amount = 3;
  int64 available_amount_after = 4;
}
```

Reason:

The Transaction Service response should expose the data shape needed by the API Gateway, without leaking unnecessary internal fields.

---

## 11. Error Mapping

gRPC errors should be mapped to HTTP errors by the API Gateway.

| gRPC Code | HTTP Code | Meaning |
|---|---:|---|
| `InvalidArgument` | 400 | invalid request |
| `Unauthenticated` | 401 | invalid or missing token |
| `PermissionDenied` | 403 | forbidden |
| `NotFound` | 404 | resource not found |
| `AlreadyExists` | 409 | duplicate resource |
| `FailedPrecondition` | 409 | insufficient available_amount |
| `Aborted` | 409 | allocation conflict |
| `Unavailable` | 503 | upstream service unavailable |
| `DeadlineExceeded` | 504 | upstream timeout |
| `Internal` | 500 | internal error |

API Gateway must convert internal errors into the standard REST error envelope:

```json
{
  "status": "error",
  "message": "error message"
}
```

Do not expose raw gRPC error details directly to external clients.

---

## 12. Timeout Rules

Each gRPC call should use context with timeout.

Recommended starting values:

| Call | Suggested Timeout |
|---|---:|
| API Gateway -> AuthService.Login | 2s |
| API Gateway -> TransactionService.CreateTransaction | 3s |
| TransactionService -> ItemService.ValidateAndAllocate | 2s |
| TransactionService -> AuthService.GetUsersByIds | 2s |
| TransactionService -> ItemService.GetItemsByIds | 2s |

Timeout values can be adjusted during implementation, but they must be consistent across benchmark runs.

Do not add retries unless explicitly required and documented, because retries can change benchmark semantics.

---

## 13. Authentication Context Propagation

External JWT validation happens at the API Gateway for protected routes.

The API Gateway should pass authenticated user identity to internal services.

Possible mechanisms:

1. include `user_id` in gRPC request fields,
2. include user context in gRPC metadata.

Recommended for this project:

```text
Use explicit user_id fields in gRPC request messages for benchmark clarity.
```

Example:

```proto
message CreateTransactionRequest {
  string user_id = 1;
  repeated TransactionItemInput items = 2;
}
```

Reason:

Explicit fields are easier to inspect, test, and document.

---

## 14. Benchmark Flow Mapping

## 14.1 Login

REST endpoint:

```text
POST /api/v1/auth/login
```

gRPC call:

```text
API Gateway -> AuthService.Login
```

Flow:

```text
Client
-> API Gateway
-> AuthService.Login
-> auth_db.users
-> API Gateway
-> Client
```

---

## 14.2 Create Transaction

REST endpoint:

```text
POST /api/v1/transactions
```

gRPC calls:

```text
API Gateway -> TransactionService.CreateTransaction
TransactionService -> ItemService.ValidateAndAllocate
```

Flow:

```text
Client
-> API Gateway
-> TransactionService.CreateTransaction
-> ItemService.ValidateAndAllocate
-> item_db.items
-> transaction_db.transactions
-> transaction_db.transaction_items
-> API Gateway
-> Client
```

---

## 14.3 Enriched Transactions

REST endpoint:

```text
GET /api/v1/admin/transactions
```

gRPC calls:

```text
API Gateway -> TransactionService.GetAllTransactionsEnriched
TransactionService -> AuthService.GetUsersByIds
TransactionService -> ItemService.GetItemsByIds
```

Flow:

```text
Client
-> API Gateway
-> TransactionService.GetAllTransactionsEnriched
-> transaction_db
-> AuthService.GetUsersByIds
-> auth_db
-> ItemService.GetItemsByIds
-> item_db
-> TransactionService in-memory enrichment
-> API Gateway
-> Client
```

---

## 15. Code Generation Rules

After editing proto files:

1. regenerate Go code,
2. update affected gRPC servers,
3. update affected gRPC clients,
4. update API Gateway mapping,
5. update unit/integration tests,
6. update this document if behavior changes.

Do not manually edit generated code.

Generated code should not be placed inside service-specific `internal/` folders if it needs to be imported by multiple services.

---

## 16. Contract Compatibility Rules

Do not break existing fields casually.

If a field is no longer used:

- keep it temporarily if compatibility is needed,
- mark as deprecated in proto comments,
- avoid reusing field numbers.

Proto field number rule:

```text
Never reuse deleted field numbers.
```

For this thesis project, compatibility history may be simple, but using safe proto practices prevents accidental contract breakage.

---

## 17. Fairness Rules

The gRPC implementation must preserve external API equivalence.

Do not allow microservices to do less work than the monolith before returning a response.

Specifically, for `CreateTransaction`:

The response must only return after:

- item availability validation,
- item allocation,
- transaction insert,
- transaction_items insert.

Do not implement:

```text
publish event -> return response -> process allocation later
```

Reason:

That would make microservices response time not comparable to the monolith synchronous response time.

---

## 18. Out of Scope

The following are not part of the initial gRPC contract design:

- Kafka,
- RabbitMQ,
- asynchronous event-driven transaction flow,
- saga pattern,
- compensation mechanism,
- distributed transaction coordinator,
- service mesh,
- circuit breaker,
- retries,
- KEDA-based autoscaling,
- RPS-based autoscaling.

These can be discussed as future work, but they are not part of the main experimental design.

---

## 19. Summary

The internal microservices contract uses gRPC.

Final contract rules:

```text
External API       : REST HTTP through API Gateway
Internal protocol  : gRPC
ID representation  : string UUID
Auth ownership     : AuthService
Item ownership     : ItemService
Transaction owner  : TransactionService
Benchmark 1        : AuthService.Login
Benchmark 2        : TransactionService.CreateTransaction + ItemService.ValidateAndAllocate
Benchmark 3        : TransactionService.GetAllTransactionsEnriched + batch calls to Auth and Item services
```

The gRPC contracts must preserve service ownership boundaries while keeping external behavior equivalent to the monolith.
