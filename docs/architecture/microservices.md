# Microservices Architecture

## 1. Purpose

This document describes the microservices runtime variant of the thesis benchmark system.

The microservices implementation is compared against the monolithic implementation using the same external REST API, equivalent logical dataset, equivalent benchmark scenarios, and equivalent total resource ceiling.

The purpose of this document is to define:

- service boundaries,
- runtime topology,
- internal communication flow,
- database ownership,
- benchmark-specific behavior,
- scaling model,
- migration strategy,
- observability expectations,
- fairness constraints.

---

## 2. High-Level Definition

In this project, the microservices architecture decomposes the application into multiple independently deployable services.

The microservices runtime consists of:

- API Gateway,
- Auth Service,
- Item Service,
- Transaction Service.

External communication uses REST HTTP through the API Gateway.

Internal service-to-service communication uses gRPC.

```text
Client / k6
    |
    v
API Gateway
    |
    +-----------------+------------------+
    |                 |                  |
    v                 v                  v
Auth Service     Item Service     Transaction Service
    |                 |                  |
    v                 v                  v
 auth_db          item_db         transaction_db
```

Key characteristics:

- multiple deployable services,
- API Gateway as the external entry point,
- gRPC for internal communication,
- database ownership per business service,
- no direct cross-service database access,
- independent service scaling,
- distributed join/fan-out for enriched transaction responses.

---

## 3. Runtime Topology

The microservices system runs on Kubernetes as multiple Deployments.

```text
+----------------------------------------------------------+
|                       EKS Cluster                         |
|                                                          |
|  +----------------------------------------------------+  |
|  | Namespace: msa                                     |  |
|  |                                                    |  |
|  |  +--------------+                                  |  |
|  |  | API Gateway  |                                  |  |
|  |  +------+-------+                                  |  |
|  |         |                                          |  |
|  |         +----------------+----------------+        |  |
|  |                          |                |        |  |
|  |                          v                v        |  |
|  |                 +--------------+   +--------------+ |
|  |                 | Auth Service |   | Item Service | |
|  |                 +------+-------+   +------+-------+ |
|  |                        |                  |         |  |
|  |                        v                  v         |  |
|  |                     auth_db             item_db      |  |
|  |                                                    |  |
|  |                 +---------------------+             |  |
|  |                 | Transaction Service |             |  |
|  |                 +----------+----------+             |  |
|  |                            |                        |  |
|  |                            v                        |  |
|  |                     transaction_db                  |  |
|  +----------------------------------------------------+  |
+----------------------------------------------------------+
```

External request path:

```text
Client / k6
    |
    v
Ingress / Load Balancer
    |
    v
API Gateway
    |
    v
Internal gRPC services
```

Only the API Gateway is exposed to external clients.

Business services are internal services.

---

## 4. Project Structure

The microservices implementation is located under:

```text
microservices/
```

Final structure:

```text
microservices/
├── api-gateway/
│   ├── README.md
│   ├── Dockerfile
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/
│   │   └── server/
│   │       └── main.go
│   └── internal/
│       ├── handler/
│       ├── client/
│       ├── middleware/
│       ├── dto/
│       ├── router/
│       ├── config/
│       └── bootstrap/
│
├── auth-service/
│   ├── README.md
│   ├── Dockerfile
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/
│   │   └── server/
│   │       └── main.go
│   ├── internal/
│   │   ├── domain/
│   │   ├── usecase/
│   │   ├── port/
│   │   ├── adapter/
│   │   ├── security/
│   │   ├── config/
│   │   └── bootstrap/
│   └── migrations/
│       └── 00001_create_users.sql
│
├── item-service/
│   ├── README.md
│   ├── Dockerfile
│   ├── go.mod
│   ├── go.sum
│   ├── cmd/
│   │   └── server/
│   │       └── main.go
│   ├── internal/
│   │   ├── domain/
│   │   ├── usecase/
│   │   ├── port/
│   │   ├── adapter/
│   │   ├── config/
│   │   └── bootstrap/
│   └── migrations/
│       └── 00001_create_items.sql
│
└── transaction-service/
    ├── README.md
    ├── Dockerfile
    ├── go.mod
    ├── go.sum
    ├── cmd/
    │   └── server/
    │       └── main.go
    ├── internal/
    │   ├── domain/
    │   ├── usecase/
    │   ├── port/
    │   ├── adapter/
    │   ├── config/
    │   └── bootstrap/
    └── migrations/
        ├── 00001_create_transactions.sql
        └── 00002_create_transaction_items.sql
```

All deployable Go applications use:

```text
cmd/server/main.go
```

This convention applies to:

- API Gateway,
- Auth Service,
- Item Service,
- Transaction Service.

---

## 5. Service Boundary Overview

### 5.1 API Gateway

The API Gateway is the external HTTP entry point for the microservices architecture.

Responsibilities:

- receive external REST HTTP requests,
- route requests to internal gRPC services,
- validate JWT for protected endpoints,
- map HTTP request bodies to gRPC request messages,
- map gRPC responses to HTTP responses,
- map gRPC errors to HTTP error responses,
- initialize request tracing.

Restrictions:

- must not contain core business logic,
- must not access any database directly,
- must not own migrations,
- must not own persistent data,
- must not bypass service boundaries.

High-level flow:

```text
Client / k6
    |
    v
API Gateway HTTP Handler
    |
    v
gRPC Client
    |
    v
Internal Service
```

---

### 5.2 Auth Service

The Auth Service owns user and authentication data.

Responsibilities:

- register user,
- login user,
- hash password,
- compare password,
- issue JWT,
- get user by ID,
- get users by IDs for enrichment.

Database ownership:

```text
auth_db.users
```

Main benchmark relevance:

```text
POST /api/v1/auth/login
```

Internal gRPC methods may include:

- Register,
- Login,
- GetUserById,
- GetUsersByIds.

---

### 5.3 Item Service

The Item Service owns item data and active item synchronization behavior.

Responsibilities:

- sync active items,
- get active item by ID,
- list active items,
- get item summaries by IDs for enrichment,
- validate transaction items against active item availability.

Database ownership:

```text
item_db.items
```

Main benchmark relevance:

```text
POST /api/v1/transactions
```

Internal gRPC methods may include:

- SyncItems,
- GetItemById,
- GetItemSummariesByIds,
- ListItems,
- ValidateTransactionItems.

`ValidateTransactionItems` is used by Transaction Service during transaction creation.

---

### 5.4 Transaction Service

The Transaction Service owns transaction data.

Responsibilities:

- create transaction,
- insert transaction_items,
- get own transactions,
- get all enriched transactions,
- call Item Service for transaction item validation,
- call Auth Service for user enrichment,
- call Item Service for item enrichment.

Database ownership:

```text
transaction_db.transactions
transaction_db.transaction_items
```

Main benchmark relevance:

```text
POST /api/v1/transactions
GET /api/v1/admin/transactions
```

Internal gRPC methods may include:

- CreateTransaction,
- GetOwnTransactions,
- GetAllTransactionsEnriched.

---

## 6. Internal Layering Per Service

Each business service follows Layered Architecture with Clean/Hexagonal-inspired dependency direction.

General flow:

```text
gRPC Server / Transport Adapter
        |
        v
Usecase / Application Layer
        |
        v
Port / Interface
        |
        v
Adapter / Repository / Client
        |
        v
Database / External Service
```

Service-level structure:

```text
internal/
├── domain/
├── usecase/
├── port/
├── adapter/
│   ├── postgres/
│   ├── grpcclient/
│   └── grpcserver/
├── config/
└── bootstrap/
```

Rules:

- gRPC server maps transport request to usecase,
- usecase contains business flow,
- repository implements database port,
- gRPC client implements external service port,
- domain must not import gRPC, PostgreSQL, Echo, or framework-specific packages,
- SQL queries must stay in repository adapters,
- business logic must stay in usecases or domain-level functions.

---

## 7. Communication Model

External communication:

```text
Client / k6
    |
    v
REST HTTP
    |
    v
API Gateway
```

Internal communication:

```text
API Gateway
    |
    v
gRPC
    |
    v
Business Services
```

Service-to-service communication:

```text
Transaction Service
    |
    +--> Auth Service via gRPC
    |
    +--> Item Service via gRPC
```

Forbidden communication:

```text
API Gateway -> database
Auth Service -> item_db
Auth Service -> transaction_db
Item Service -> auth_db
Item Service -> transaction_db
Transaction Service -> auth_db directly
Transaction Service -> item_db directly
```

Allowed communication:

```text
Transaction Service -> Auth Service via gRPC
Transaction Service -> Item Service via gRPC
```

---

## 8. Database Ownership

The microservices architecture uses database-per-service ownership.

```text
RDS PostgreSQL 18
    |
    +-- auth_db
    |     |
    |     +-- users
    |
    +-- item_db
    |     |
    |     +-- items
    |
    +-- transaction_db
          |
          +-- transactions
          +-- transaction_items
```

The API Gateway owns no database.

The Transaction Service stores external references as UUID values only:

```text
transactions.user_id
transaction_items.item_id
```

It must not create foreign keys to:

```text
auth_db.users
item_db.items
```

Reason:

Each service owns its data. Direct database coupling across services breaks service autonomy.

---

## 9. ID and Audit Metadata Rules

All services use PostgreSQL 18 UUIDv7 generation.

All primary keys use:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

Application code does not generate UUID manually during normal runtime inserts.

Create operations use:

```sql
INSERT ... RETURNING id
```

All main tables include:

```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
```

This applies to:

- `auth_db.users`,
- `item_db.items`,
- `transaction_db.transactions`,
- `transaction_db.transaction_items`.

---

## 10. Core Databases and Tables

### 10.1 `auth_db.users`

Purpose:

Stores users and authentication information.

Main columns:

```text
id
name
email
password_hash
created_at
updated_at
```

Owned by:

```text
auth-service
```

---

### 10.2 `item_db.items`

Purpose:

Stores generic allocatable items.

Main columns:

```text
id
name
available_amount
created_at
updated_at
```

Owned by:

```text
item-service
```

The `available_amount` value is validated but not modified by Item Service.

---

### 10.3 `transaction_db.transactions`

Purpose:

Stores transaction header data.

Main columns:

```text
id
user_id
status
created_at
updated_at
```

Owned by:

```text
transaction-service
```

`user_id` is a UUID reference to a user owned by Auth Service, but it is not a foreign key.

---

### 10.4 `transaction_db.transaction_items`

Purpose:

Stores item details inside a transaction.

Main columns:

```text
transaction_id
item_id
amount
created_at
updated_at
```

Owned by:

```text
transaction-service
```

Foreign key allowed:

```text
transaction_items.transaction_id -> transactions.id
```

Foreign key not allowed:

```text
transaction_items.item_id -> item_db.items.id
```

`item_id` is a UUID reference to an item owned by Item Service.

Primary key:

```sql
PRIMARY KEY (transaction_id, item_id)
```

---

## 11. External API Exposure

The microservices architecture exposes the same external REST API as the monolith.

External source of truth:

```text
openapi.yaml
```

Only the API Gateway exposes external HTTP endpoints.

Main benchmark endpoints:

```text
POST /api/v1/auth/login
POST /api/v1/transactions
GET /api/v1/admin/transactions
```

All public IDs are represented as UUID strings.

Example:

```json
{
  "id": "0196f5d2-3a6b-7d2a-bc91-8c91e2e8b6a1"
}
```

---

## 12. Benchmark 1: Login Flow

Endpoint:

```text
POST /api/v1/auth/login
```

Workload type:

```text
CPU-bound
```

Purpose:

Evaluate authentication-related CPU work and additional network hop through API Gateway.

Flow:

```text
Client / k6
    |
    v
API Gateway
    |
    v
Auth Service
    |
    +-- Find user by email
    +-- bcrypt password comparison
    +-- JWT signing
    |
    v
auth_db.users
```

ASCII sequence:

```text
Client/k6        API Gateway        Auth Service             auth_db
   |                 |                    |                     |
   | POST /login     |                    |                     |
   |---------------->|                    |                     |
   |                 | Login gRPC         |                     |
   |                 |------------------->|                     |
   |                 |                    | SELECT user by email |
   |                 |                    |-------------------->|
   |                 |                    |<--------------------|
   |                 |                    | bcrypt compare       |
   |                 |                    | JWT signing          |
   |                 |<-------------------|                     |
   |<----------------|                    |                     |
   | 200 + token     |                    |                     |
```

Expected microservices characteristic:

- adds API Gateway to Auth Service gRPC call,
- isolates authentication workload inside Auth Service,
- Auth Service can scale independently under login-heavy workload.

---

## 13. Benchmark 2: Create Transaction Flow

Endpoint:

```text
POST /api/v1/transactions
```

Workload type:

```text
I/O-bound + state mutation + inter-service communication
```

Purpose:

Evaluate write behavior and service-to-service allocation flow.

Flow:

```text
Client / k6
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    +-- Call Item Service ValidateTransactionItems
    |       |
    |       v
    |   item_db.items
    |
    +-- Insert transaction RETURNING id
    |
    +-- Insert transaction_items
    |
    v
transaction_db
```

ASCII sequence:

```text
Client/k6   API Gateway   Transaction Service   Item Service       item_db        transaction_db
   |            |                 |                  |               |                 |
   | POST /tx   |                 |                  |               |                 |
   |----------->|                 |                  |               |                 |
   |            | CreateTx gRPC   |                  |               |                 |
   |            |---------------->|                  |               |                 |
   |            |                 | ValidateTransactionItems |               |                 |
   |            |                 |----------------->|               |                 |
   |            |                 |                  | SELECT active   |                 |
   |            |                 |                  |-------------->|                 |
   |            |                 |                  |<--------------|                 |
   |            |                 |<-----------------|               |                 |
   |            |                 | INSERT tx RETURNING id             |                 |
   |            |                 |---------------------------------------------------->|
   |            |                 | INSERT transaction_items            |                 |
   |            |                 |---------------------------------------------------->|
   |            |<----------------|                  |               |                 |
   |<-----------|                 |                  |               |                 |
   | 201 Created|                 |                  |               |                 |
```

Expected microservices characteristic:

- item validation is handled by Item Service,
- transaction persistence is handled by Transaction Service,
- inter-service communication adds overhead,
- service-level scaling can target hot services independently.

This research does not deeply evaluate distributed transaction consistency, saga, or compensation mechanisms.

---

## 14. Benchmark 3: Enriched Transactions Flow

Endpoint:

```text
GET /api/v1/admin/transactions
```

Workload type:

```text
Aggregation + network-bound
```

Purpose:

Evaluate distributed data enrichment across service boundaries.

Flow:

```text
Client / k6
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    +-- Read transactions from transaction_db
    |
    +-- Collect user_ids
    |
    +-- Collect item_ids
    |
    +-- API Gateway calls Auth Service GetUsersByIds
    |
    +-- API Gateway calls Item Service GetItemSummariesByIds
    |
    +-- API Gateway joins/enriches in memory
    |
    v
Response
```

ASCII sequence:

```text
Client/k6   API Gateway   Transaction Svc    transaction_db    Auth Svc      auth_db     Item Svc      item_db
   |            |                |                  |              |            |           |            |
   | GET admin  |                |                  |              |            |           |            |
   |----------->|                |                  |              |            |           |            |
   |            | GetAll gRPC    |                  |              |            |           |            |
   |            |--------------->|                  |              |            |           |            |
   |            |                | SELECT tx data    |              |            |           |            |
   |            |                |----------------->|              |            |           |            |
   |            |                |<-----------------|              |            |           |            |
   |            | GetUsersByIds                    |              |            |           |            |
   |            |----------------------------------------------->|            |           |            |
   |            |                                                | SELECT     |           |            |
   |            |                                                |----------->|           |            |
   |            |<-----------------------------------------------|            |           |            |
   |            | GetItemSummariesByIds                                     |            |
   |            |---------------------------------------------------------->|            |
   |            |                                                          | SELECT     |
   |            |                                                          |----------->|
   |            |<---------------------------------------------------------|            |
   |            | in-memory enrichment  |                  |              |            |           |            |
   |<-----------|                |                  |              |            |           |            |
   | 200 data   |                |                  |              |            |           |            |
```

Expected microservices characteristic:

- distributed join/fan-out,
- additional gRPC calls,
- higher network overhead,
- clearer service ownership boundaries.

---

## 15. Scaling Model

The microservices architecture scales per service.

Each service has its own HPA.

Services with HPA:

- API Gateway,
- Auth Service,
- Item Service,
- Transaction Service.

Per-service resource configuration:

```text
CPU per pod       : 250m
Memory per pod    : 256Mi
minReplicas       : 1
maxReplicas       : 16
HPA target CPU    : 70%
```

Namespace resource ceiling:

```text
CPU max           : 4000m
Memory max        : 4096Mi
```

Reason for maxReplicas 16:

```text
4000m / 250m = 16 pods
```

This allows one focused service to scale up under targeted load, while the namespace ResourceQuota prevents the total microservices resource usage from exceeding the monolith resource ceiling.

Example login-heavy scaling:

```text
High login traffic
    |
    v
API Gateway CPU increases
Auth Service CPU increases
    |
    v
API Gateway scales out
Auth Service scales out
    |
    v
Item Service and Transaction Service may remain near minReplicas
```

ASCII example:

```text
+-------------------+
| API Gateway x N   |
+-------------------+

+-------------------+
| Auth Service x N  |
+-------------------+

+-------------------+
| Item Service x 1  |
+-------------------+

+------------------------+
| Transaction Service x1 |
+------------------------+
```

This is the expected granular scaling advantage of microservices.

---

## 16. ResourceQuota Behavior

The MSA namespace uses ResourceQuota to keep the total application resource budget comparable to the monolith.

```text
Namespace: msa
CPU max   : 4000m
Memory max: 4096Mi
```

Important consequence:

If multiple services attempt to scale out at the same time, the namespace ResourceQuota may prevent some pods from being scheduled.

This is intentional for the experiment because the total resource budget must remain bounded.

Resource contention under the same CPU ceiling is part of the observed system behavior.

---

## 17. Migration Strategy

Each business service owns its own migrations.

Migration paths:

```text
microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/
```

API Gateway has no migrations.

Migration tool:

```text
Goose SQL migration
```

Migration execution:

```text
Kubernetes Job
```

Migration is not executed through init containers.

Reason:

```text
Migration must run once per deployment or experiment preparation.
It must not run once per pod, especially during HPA scale-out.
```

Migration jobs:

```text
auth-migration-job
item-migration-job
transaction-migration-job
```

Deployment preparation flow:

```text
Run auth migration job
    |
    v
Run item migration job
    |
    v
Run transaction migration job
    |
    v
Run microservices seed job
    |
    v
Deploy microservices
    |
    v
Run benchmark
```

---

## 18. Seed Strategy

Seed data is managed centrally under:

```text
seed/
```

The microservices seed script inserts benchmark data into:

```text
auth_db.users
item_db.items
transaction_db.transactions
transaction_db.transaction_items
```

For benchmark users and items, the seed script uses deterministic UUIDs so k6
and related tooling can rely on stable identities without querying the
databases first.

Normal runtime inserts still use PostgreSQL-generated `uuidv7()` values with
`INSERT ... RETURNING id`.

Seed scripts still capture generated IDs with `INSERT ... RETURNING id` when
the IDs are not predetermined, such as enrichment transaction preparation.

The seed script must maintain mappings such as:

```text
logical_user_key -> seeded auth_db.users.id
logical_item_key -> seeded item_db.items.id
logical_transaction_key -> generated transaction_db.transactions.id
```

These mappings are required because `transaction_db.transactions.user_id` and `transaction_db.transaction_items.item_id` store UUID references to records owned by other services.

The generated UUID values do not need to be identical to the monolith dataset, but the logical dataset must be equivalent.

---

## 19. Observability

Datadog is used for microservices observability.

Important metrics:

- request latency,
- request throughput,
- error rate,
- CPU usage per service,
- memory usage per service,
- replica count per service,
- HPA scaling events,
- gRPC latency,
- gRPC error rate,
- PostgreSQL query duration when available,
- RDS metrics when available.

Expected trace shape for Create Transaction:

```text
HTTP request
    |
    v
api-gateway
    |
    v
transaction-service
    |
    v
item-service
    |
    v
PostgreSQL
```

Expected trace shape for Enriched Transactions:

```text
HTTP request
    |
    v
api-gateway
    |
    v
transaction-service
    |
    +--> transaction_db
    |
    +--> auth-service --> auth_db
    |
    +--> item-service --> item_db
```

Observability goals:

- identify which service becomes the bottleneck,
- observe inter-service latency,
- observe resource usage per service,
- observe scaling behavior per service,
- explain external k6 results using internal telemetry.

---

## 20. Strengths of the Microservices Variant

The microservices architecture is useful because it provides:

- independent service deployment,
- independent service scaling,
- clear service ownership,
- database ownership boundaries,
- modular runtime structure,
- service-level observability,
- potential resource efficiency under targeted load.

For workloads that heavily affect only one service, microservices can scale the affected service without replicating the whole application.

---

## 21. Limitations of the Microservices Variant

The microservices implementation has several limitations relevant to the experiment:

- more network hops,
- gRPC overhead,
- more deployment units,
- more operational complexity,
- distributed tracing requirement,
- harder end-to-end debugging,
- no single database transaction across service-owned data,
- distributed join/fan-out for enriched reads,
- possible ResourceQuota contention when multiple services scale at the same time.

These limitations are part of the architectural trade-off evaluated by the research.

---

## 22. Fairness Rules

To keep the comparison fair, the microservices implementation must follow these rules:

- expose the same external REST API as the monolith,
- use the same programming language,
- use the same database engine,
- use equivalent logical dataset,
- use equivalent business logic,
- use equivalent authentication rules,
- use equivalent response format,
- use equivalent benchmark scenarios,
- use the same k6 scripts,
- stay within the same total application CPU ceiling.

Do not add optimizations only to microservices unless equivalent optimizations are applied to the monolith or explicitly documented.

Examples of unfair differences:

- microservices uses caching while monolith does not,
- microservices uses async queue while monolith is synchronous,
- microservices skips validation done by monolith,
- microservices responds before the actual work is complete,
- microservices uses different payloads,
- microservices uses different authentication behavior,
- microservices has extra database indexes not present in equivalent monolith tables.

---

## 23. Explicitly Excluded Patterns

The microservices implementation does not include these patterns unless explicitly requested later:

- Kafka,
- RabbitMQ,
- event-driven asynchronous transaction flow,
- saga pattern,
- compensation mechanism,
- distributed transaction coordinator,
- circuit breaker,
- retry mechanism,
- service mesh,
- KEDA,
- RPS-based autoscaling,
- latency-based autoscaling.

Reason:

The experiment focuses on a controlled REST + gRPC microservices implementation. Adding these patterns would introduce additional variables and make the architecture comparison harder to isolate.

---

## 24. Why No Event-Driven Transaction Flow

The create transaction benchmark is intentionally synchronous.

The API response should be returned after the main transaction flow is completed.

This avoids comparing different completion semantics.

Unfair pattern:

```text
Microservices:
Client request
    |
    v
Publish event
    |
    v
Return response before allocation is fully completed
```

This would make the microservices response time appear faster because part of the actual work continues after the response.

Chosen pattern:

```text
Client request
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    v
Item Service ValidateTransactionItems
    |
    v
Transaction insert
    |
    v
Return response
```

This keeps the benchmark more comparable to the monolith synchronous transaction flow.

---

## 25. Summary

The microservices implementation is the distributed runtime variant of the benchmark system.

It decomposes the application into independently deployable services with explicit service ownership and gRPC communication.

Key design decisions:

```text
Runtime units          : API Gateway, Auth Service, Item Service, Transaction Service
Database model         : database per business service
External API           : REST HTTP through API Gateway
Internal protocol      : gRPC
ID strategy            : PostgreSQL UUIDv7
Migration              : Goose SQL migration per service
Migration execution    : Kubernetes Job
Scaling unit           : per service
Benchmark role         : distributed architecture for comparison against monolith
```

The microservices variant is expected to have more communication overhead and operational complexity, but it provides more granular scaling and clearer service-level resource isolation than the monolith.
