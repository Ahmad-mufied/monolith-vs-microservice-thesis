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

The microservices implementation should be read as the distributed counterpart
to the monolith. The external REST contract stays the same, but the internal
request path is split across the API Gateway and independently deployable
business services. This creates additional network hops and stricter ownership
boundaries, while allowing individual services to scale independently under
different workload shapes.

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

This high-level diagram shows the defining trade-off of the microservices
variant: the public API still looks like one system to the client, but the
runtime is split into separate services with separate databases. That split
creates stronger ownership boundaries and finer-grained scaling, while also
introducing more communication steps on the request path.

Key characteristics:

- multiple deployable services,
- API Gateway as the external entry point,
- gRPC for internal communication,
- database ownership per business service,
- no direct cross-service database access,
- independent service scaling,
- distributed join/fan-out for enriched transaction responses.

In this diagram, each business service owns its own runtime and database. The
API Gateway is not a data owner; it translates external HTTP requests into
internal gRPC calls and assembles responses when a public endpoint needs data
from more than one service.

---

## 3. Runtime Topology

The microservices system runs on Kubernetes as multiple Deployments.

In parallel benchmark mode these Deployments run on the dedicated
`skripsi-msa` EKS cluster (or `skripsi-vultr-msa` VKE cluster on Vultr). In
sequential benchmark mode they run in the `msa` namespace on `skripsi-benchmark`
(or `skripsi-vultr-benchmark` on Vultr) while the monolith namespace is scaled
down. The API Gateway, gRPC call graph, database-per-service model, resource
ceiling, and benchmark semantics remain the same in both modes and on both
infrastructure providers.

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

This topology diagram makes it clear that the API Gateway is the only external
entry point, while Auth, Item, and Transaction remain internal workloads. Each
service scales and deploys independently, and each service talks only to the
database it owns. That separation is central to the benchmark because it lets
us observe whether modular scaling offsets the extra coordination cost.

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

This topology is designed to make distribution costs visible during the
benchmark. Compared with the monolith, a request may pass through more runtime
boundaries, more connection pools, and more tracing spans before it returns to
the client. Those costs are expected and are part of what the thesis measures.

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
- get raw transactions for enrichment,
- call Item Service for ValidateTransactionItems.

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
- GetTransactionById,
- GetTransactionsForEnrichment.

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

This layering diagram explains how each service keeps transport, application
logic, and data access separated even though the overall system is distributed.
It is useful for reading the codebase because every gRPC request should follow
the same conceptual path: transport mapping, usecase orchestration, then
repository or outbound client interaction.

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

This layering keeps each service independently understandable. A gRPC server
handles transport mapping, the usecase coordinates the service-owned business
flow, repository adapters access the service database, and gRPC client adapters
call other services only through declared ports.

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
API Gateway
    |
    +--> Auth Service via gRPC (GetUsersByIds for enrichment)
    |
    +--> Item Service via gRPC (GetItemSummariesByIds for enrichment)

Transaction Service
    |
    +--> Item Service via gRPC (ValidateTransactionItems only)
```

This communication diagram is one of the most important in the document. It
shows that the API Gateway owns external orchestration and enriched-response
assembly, while Transaction Service owns transaction persistence and only calls
Item Service for validation. That distinction prevents the architecture from
quietly drifting into a shared-logic design where multiple services enrich or
mutate the same data path.

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
Transaction Service -> Item Service via gRPC (ValidateTransactionItems only)
API Gateway -> Auth Service via gRPC (GetUsersByIds for enrichment)
API Gateway -> Item Service via gRPC (GetItemSummariesByIds for enrichment)
```

The important distinction is that `Transaction Service` does not enrich
transactions with user or item details. It returns raw transaction data from
`transaction_db`. For enriched responses, the API Gateway performs the fan-out
to Auth and Item services, then joins the data in memory before returning the
REST response.

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

This database ownership diagram should be read together with the communication
diagram above. Each business service owns exactly one database scope and is
responsible for its own schema, migrations, and queries. Cross-service
references are stored as UUID values, but services must not query another
service's database directly just because the identifier is available.

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

Stores generic items with an `available_amount` value used for transaction validation.

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

In the microservices login flow, the API Gateway is only the external entry
point and transport mapper. The Auth Service owns credential lookup, bcrypt
comparison, and JWT signing. This preserves the same external behavior as the
monolith while making the extra HTTP-to-gRPC boundary and Auth Service isolation
visible in traces and latency metrics.

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

This flow shows the extra boundary introduced by the distributed design. The
request first lands at the API Gateway, then the actual authentication work is
performed by Auth Service against `auth_db.users`. The business semantics stay
the same as the monolith, but the runtime path includes an additional gRPC hop
that is visible in latency and traces.

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

Walking through the sequence, the API Gateway behaves as a transport bridge,
not as the owner of authentication logic. It forwards the login request,
waits for the gRPC response, and returns the mapped REST response after Auth
Service completes the same lookup, bcrypt, and JWT steps that the monolith
performs locally.

Expected microservices characteristic:

- adds API Gateway to Auth Service gRPC call,
- isolates authentication workload inside Auth Service,
- Auth Service can scale independently under login-heavy workload.
- login latency includes both authentication CPU work and the API Gateway to Auth Service hop.

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

Evaluate write behavior and service-to-service validation flow.

The create transaction flow demonstrates service ownership during a write. The
Transaction Service owns transaction persistence, but it does not own item data.
It therefore calls Item Service through `ValidateTransactionItems` before
writing to `transaction_db`. Item validation remains validation-only and does
not deduct `available_amount`, keeping the benchmark focused on request path
cost rather than distributed availability consistency.

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

This flow shows the ownership split in the write path. Transaction Service
owns transaction persistence, but it must ask Item Service to validate the
requested items first because item data lives in `item_db`. The write remains
synchronous from the client's perspective, even though the work is distributed
across two services.

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

The sequence shows two distinct responsibilities: Item Service confirms that
the request is valid against current item data, and Transaction Service commits
the transaction records. The API Gateway stays in the middle as the HTTP entry
point, so the end-to-end latency includes transport mapping, at least one
internal RPC, and database writes in the owning service.

Expected microservices characteristic:

- item validation is handled by Item Service,
- transaction persistence is handled by Transaction Service,
- inter-service communication adds overhead,
- service-level scaling can target hot services independently.
- failure handling crosses service boundaries because validation and persistence are owned by different services.

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

The enriched transaction flow is the clearest architectural contrast with the
monolith. Transaction Service returns raw transaction rows and item IDs from
`transaction_db`. The API Gateway then collects the referenced user IDs and
item IDs, calls Auth Service and Item Service in batches, and merges the
returned summaries into the public REST response. This is the distributed
join/fan-out path measured by the benchmark.

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

This flow captures the main distributed-read pattern in the benchmark.
Transaction Service provides the raw transaction rows, but the final enriched
response is assembled by the API Gateway after it gathers user and item
summaries from the owning services. The read is therefore shaped as fan-out and
in-memory merge rather than a single database join.

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
   |            |<---------------|                  |              |            |           |            |
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

The sequence makes the enrichment cost visible: one public request becomes one
raw-transaction fetch plus two batch lookups to other services before the API
Gateway can return a complete payload. This is the clearest place where the
microservices design trades centralized query execution for ownership
boundaries and explicit inter-service coordination.

Expected microservices characteristic:

- distributed join/fan-out,
- additional gRPC calls,
- higher network overhead,
- clearer service ownership boundaries.
- API Gateway owns response assembly for cross-service data, while each service keeps ownership of its own database.

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
fixed mode:
  api-gateway        : request 980m / limit 1950m / 1920Mi / 3840Mi
  auth-service       : request 980m / limit 1950m / 1920Mi / 3840Mi
  item-service       : request 980m / limit 1950m / 1920Mi / 3840Mi
  transaction-service: request 980m / limit 1950m / 1920Mi / 3840Mi

hpa mode:
  api-gateway        : request 500m / limit 975m / 960Mi / 1920Mi
  auth-service       : request 500m / limit 975m / 960Mi / 1920Mi
  item-service       : request 500m / limit 975m / 960Mi / 1920Mi
  transaction-service: request 500m / limit 975m / 960Mi / 1920Mi
minReplicas       : 1
maxReplicas       : 2
HPA target CPU    : 70%
```

Namespace resource ceiling:

```text
CPU max           : 7800m
Memory max        : 15360Mi
```

This allows one focused service to scale up under targeted load while the
namespace ResourceQuota still prevents the total microservices resource usage
from exceeding the monolith resource ceiling.

The methodology for deciding why these per-service budgets use equal split
instead of role-aware allocation is documented in
`docs/experiment/resource-configuration.md`.

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
Item Service and Transaction Service may remain near minReplicas while the
overall namespace ceiling still limits total scale-out
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

This is the expected granular scaling advantage of microservices, even when the
initial service budgets are allocated uniformly.

---

## 16. ResourceQuota Behavior

The MSA namespace uses ResourceQuota to keep the total application resource budget comparable to the monolith.

```text
Namespace: msa
CPU max   : 7800m
Memory max: 15360Mi
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
Return response before validation and persistence are fully completed
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
