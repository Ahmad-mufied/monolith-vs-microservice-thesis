# Monolith Architecture

## 1. Purpose

This document describes the monolithic runtime variant of the thesis benchmark system.

The monolith is one of two architectural implementations used in this research:

1. Monolithic Architecture
2. Microservices Architecture

The purpose of the monolith implementation is to provide a baseline architecture where all application modules run inside one deployable application and communicate through in-process function calls.

This implementation is compared against the microservices implementation using the same external REST API, equivalent logical dataset, equivalent benchmark scenarios, and equivalent resource ceiling.

The monolith should be read as the baseline for centralized execution. It keeps
authentication, item validation, transaction persistence, and enriched
transaction reads inside one runtime boundary. This makes the request path
shorter and gives the database permission to enforce relationships across all
main tables, but it also means scaling happens at the whole-application level
rather than at a specific module level.

---

## 2. High-Level Definition

In this project, the monolith is a single Go application that contains all business modules in one deployable unit.

The monolith includes:

- Auth module,
- Item module,
- Transaction module.

All modules run in the same process and share the same database.

```text
+--------------------------------------------------+
|              Monolith Application                |
|                                                  |
|  +-------------+  +-----------+  +-------------+ |
|  | Auth Module |  |   Item    |  | Transaction | |
|  |             |  |  Module   |  |   Module    | |
|  +-------------+  +-----------+  +-------------+ |
|                                                  |
+-------------------------+------------------------+
                          |
                          v
                    +-----------+
                    |  mono_db  |
                    +-----------+
```

This diagram shows the core monolith idea in the most compact form: all three
business modules live inside one deployable application and persist to one
shared database. The boundaries between Auth, Item, and Transaction are
organizational code boundaries, not runtime boundaries. Because of that, the
monolith can orchestrate cross-module behavior with direct function calls and
can rely on one database to enforce relational integrity across the full
transaction lifecycle.

Key characteristics:

- one codebase section for the monolith,
- one running process,
- one deployable artifact,
- one Kubernetes Deployment,
- one database,
- one scaling unit,
- in-process module communication,
- SQL JOIN is allowed,
- foreign keys across tables are allowed.

In the diagrams below, the boxes inside the monolith are logical modules, not
separate deployables. Calls between modules are ordinary function calls inside
the same Go process. The only network boundary on the hot request path is
between the application pod and PostgreSQL.

---

## 3. Runtime Topology

The monolith is exposed through the same external HTTP API used by the microservices variant.

Runtime topology:

```text
Client / k6
    |
    v
Ingress / Load Balancer
    |
    v
Monolith Pod(s)
    |
    v
Amazon RDS PostgreSQL 18
    |
    v
mono_db
```

In parallel benchmark mode this topology runs on the dedicated
`skripsi-monolith` EKS cluster (or `skripsi-vultr-monolith` VKE cluster on
Vultr). In sequential benchmark mode it runs in the `mono` namespace on
`skripsi-benchmark` (or `skripsi-vultr-benchmark` on Vultr) while the
microservices namespace is scaled down. The monolith request path, database
name, resource ceiling, and benchmark semantics remain the same in both modes
and on both infrastructure providers.

This request path is intentionally linear. A client request reaches the
monolith over HTTP, the monolith executes all relevant application logic
locally, and PostgreSQL is the only external dependency on the hot path. That
shape matters for the benchmark because any added latency mostly comes from
application code and database work, not from service-to-service network hops.

In Kubernetes, the monolith is deployed as one Deployment object.

```text
+-----------------------------+
|          EKS Cluster         |
|                             |
|  +-----------------------+  |
|  | Namespace: mono       |  |
|  |                       |  |
|  |  +-----------------+  |  |
|  |  | Monolith Pod 1  |  |  |
|  |  +-----------------+  |  |
|  |  | Monolith Pod 2  |  |  |
|  |  +-----------------+  |  |
|  |  | Monolith Pod N  |  |  |
|  |  +-----------------+  |  |
|  |                       |  |
|  +-----------+-----------+  |
|              |              |
+--------------|--------------+
               |
               v
        +-------------+
        |   mono_db   |
        +-------------+
```

This Kubernetes view makes the scaling model explicit. When HPA increases the
replica count, it replicates the entire application pod, not just one module.
As a result, high load on login, item reads, or transaction writes all consume
capacity from the same monolith replica pool.

When the monolith scales out, the whole application is replicated.

This means the Auth, Item, and Transaction modules are scaled together even if only one module receives most of the load.

This topology is intentionally simple for the benchmark. A request enters one
HTTP server, executes business logic in-process, and reaches one database. The
trade-off is that the benchmark cannot observe service-level isolation inside
the monolith; CPU, memory, latency, and HPA behavior are measured for the whole
application pod.

---

## 4. Project Structure

The monolith implementation is located under:

```text
monolith/
```

Final structure:

```text
monolith/
├── README.md
├── Dockerfile
├── go.mod
├── go.sum
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── auth/
│   │   ├── handler.go
│   │   ├── service.go
│   │   ├── repository.go
│   │   ├── model.go
│   │   └── dto.go
│   │
│   ├── item/
│   │   ├── handler.go
│   │   ├── service.go
│   │   ├── repository.go
│   │   ├── model.go
│   │   └── dto.go
│   │
│   ├── transaction/
│   │   ├── handler.go
│   │   ├── service.go
│   │   ├── repository.go
│   │   ├── model.go
│   │   └── dto.go
│   │
│   └── shared/
│       ├── db/
│       │   └── postgres.go
│       ├── config/
│       │   └── config.go
│       ├── jwtutil/
│       │   └── jwt.go
│       ├── httputil/
│       │   └── response.go
│       ├── observability/
│       │   └── observability.go
│       └── apperror/
│           └── error.go
│
└── migrations/
    ├── 00001_create_users.sql
    ├── 00002_create_items.sql
    ├── 00003_create_transactions.sql
    └── 00004_create_transaction_items.sql
```

---

## 5. Command Entry Point

All deployable Go applications in this repository use the same command convention:

```text
cmd/server/main.go
```

For the monolith:

```text
monolith/cmd/server/main.go
```

The monolith command starts the external HTTP REST server.

It is responsible for:

- loading configuration,
- initializing logger,
- initializing PostgreSQL connection pool,
- initializing repositories,
- initializing service implementations for the usecase layer,
- initializing HTTP handlers,
- registering routes,
- starting the HTTP server,
- starting observability instrumentation if enabled.

---

## 6. Internal Layering

The monolith uses Layered Architecture with Clean/Hexagonal-inspired dependency direction.

General flow:

```text
HTTP Handler
    |
    v
Usecase (implemented in service.go)
    |
    v
Repository
    |
    v
PostgreSQL
```

This layering diagram shows how a request is intended to move through the
monolith. The handler owns HTTP concerns, the usecase layer coordinates the
business flow, and the repository owns SQL access. The separation helps the
benchmark remain readable and auditable, because we can discuss runtime costs
without mixing transport code and database code together.

Detailed layer responsibilities:

| Layer | Responsibility |
|---|---|
| Handler | Parse request, call usecase, map response/error |
| Usecase | Business flow and orchestration, implemented by `service.go` files |
| Repository | SQL queries and database transaction handling |
| Model | Domain/data model |
| DTO | Request/response transport objects |
| Shared | Technical utilities only |

Rules:

- handlers must not contain business logic,
- usecases must not contain raw SQL,
- repositories must not contain HTTP-specific logic,
- shared packages must not contain domain-specific business logic,
- modules may call each other through usecase-level or repository-level composition if needed, but the flow must remain clear.

For benchmark interpretation, this layering matters because it keeps HTTP
concerns, business orchestration, and SQL access separated while still running
inside one deployable. A latency increase in the monolith therefore represents
the combined cost of the handler, service logic, repository work, and database
interaction in a single process.

---

## 7. Module Responsibilities

## 7.1 Auth Module

Path:

```text
monolith/internal/auth/
```

Responsibilities:

- register user,
- login user,
- find user by email,
- bcrypt password hashing,
- bcrypt password comparison,
- JWT signing,
- extract authenticated user context when needed.

Main benchmark relevance:

```text
POST /api/v1/auth/login
```

This endpoint represents the CPU-bound workload because it performs password verification and token generation.

---

## 7.2 Item Module

Path:

```text
monolith/internal/item/
```

Responsibilities:

- create item,
- get item by ID,
- list items,
- update item,
- delete item,
- validate `available_amount`,
- validate `available_amount` during transaction creation.

Main benchmark relevance:

```text
POST /api/v1/transactions
```

The Item module participates in the create transaction flow because the
transaction must validate requested item amounts against `available_amount`.
The current benchmark contract is validation-only: the create transaction flow
does not deduct or mutate `available_amount`.

---

## 7.3 Transaction Module

Path:

```text
monolith/internal/transaction/
```

Responsibilities:

- create transaction,
- create transaction items,
- get own transactions,
- get all enriched transactions,
- coordinate item validation and transaction persistence inside one database transaction.

Main benchmark endpoints:

```text
POST /api/v1/transactions
GET /api/v1/admin/transactions
```

The transaction module is the primary module for I/O-bound and aggregation workloads.

---

## 8. Database Ownership

The monolith owns one database:

```text
mono_db
```

Tables:

- `users`,
- `items`,
- `transactions`,
- `transaction_items`.

Because all tables are owned by one application, the monolith may use database-level foreign keys across tables.

Logical database model:

```text
users
  |
  | 1:N
  v
transactions
  |
  | 1:N
  v
transaction_items
  ^
  | N:1
  |
items
```

This model explains why the monolith can serve enriched transaction responses
with a single SQL join. All entities that participate in the benchmark live in
the same database, and the relationships between them can be expressed and
validated directly at the database level.

Foreign key relationships:

```text
transactions.user_id
    -> users.id

transaction_items.transaction_id
    -> transactions.id

transaction_items.item_id
    -> items.id
```

---

## 9. ID and Audit Metadata Rules

The monolith uses PostgreSQL 18 UUIDv7 generation.

All primary keys use:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

The application does not generate UUID manually during normal runtime inserts.

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

- `users`,
- `items`,
- `transactions`,
- `transaction_items`.

---

## 10. Core Tables

## 10.1 `users`

Purpose:

Stores registered users and authentication information.

Main columns:

```text
id
name
email
password_hash
created_at
updated_at
```

Used by:

- Auth module,
- login benchmark,
- enriched transactions query.

---

## 10.2 `items`

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

Used by:

- Item module,
- create transaction benchmark,
- enriched transactions query.

`available_amount` is validated during transaction creation, but the current
benchmark contract does not deduct or mutate it.

---

## 10.3 `transactions`

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

`transactions` represents the parent or header of a transaction.

---

## 10.4 `transaction_items`

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

`transaction_items` represents the detail lines of a transaction.

Relationship:

```text
one transaction -> many transaction_items
```

Primary key:

```sql
PRIMARY KEY (transaction_id, item_id)
```

This means the same item should appear only once in the same transaction.

---

## 11. External API Exposure

The monolith exposes the same REST API defined in:

```text
openapi.yaml
```

The monolith must remain externally compatible with the microservices implementation.

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

Evaluate authentication-related CPU work such as password comparison and JWT signing.

In the monolith, the login request does not cross a service boundary after it
enters the HTTP server. The handler calls the auth service directly, the auth
repository reads from `mono_db.users`, and the same process performs bcrypt
comparison and JWT signing. This makes the flow useful as a baseline for the
microservices login path, where the same work requires an additional API
Gateway to Auth Service gRPC hop.

Flow:

```text
Client / k6
    |
    v
HTTP Handler
    |
    v
Auth Usecase
    |
    +-- Find user by email
    |
    +-- bcrypt password comparison
    |
    +-- JWT signing
    |
    v
Response
```

This flow emphasizes that the login benchmark is dominated by local
application work after the request enters the monolith. The expensive part is
not network fan-out, but credential lookup followed by bcrypt verification and
JWT creation in the same process.

Database interaction:

```text
Auth Repository
    |
    v
mono_db.users
```

ASCII sequence:

```text
Client/k6          Monolith                  mono_db
   |                  |                         |
   | POST /login      |                         |
   |----------------->|                         |
   |                  | SELECT user by email    |
   |                  |------------------------>|
   |                  |<------------------------|
   |                  | bcrypt compare          |
   |                  | JWT signing             |
   |<-----------------|                         |
   | 200 + token      |                         |
```

Reading the sequence step by step, there is only one database lookup and no
intermediate service hop. The request enters the monolith, the monolith reads
the user row, performs the CPU-heavy security checks, signs the token, and
returns the response directly.

Expected monolith characteristic:

- no network hop between API layer and auth logic,
- all authentication logic runs in the same process.
- database access is limited to a single `users` lookup before CPU-heavy bcrypt work.

---

## 13. Benchmark 2: Create Transaction Flow

Endpoint:

```text
POST /api/v1/transactions
```

Workload type:

```text
I/O-bound + state mutation
```

Purpose:

Evaluate database write behavior and item validation in a transactional flow.

The monolith can execute item validation and transaction persistence under one
database transaction because all required tables live in `mono_db`. The flow
checks requested item amounts, inserts the transaction header with
`INSERT ... RETURNING id`, inserts the transaction item rows, and commits the
transaction. No service-to-service hop is needed to validate item data.

Flow:

```text
Client / k6
    |
    v
Transaction Handler
    |
    v
Transaction Usecase
    |
    +-- Begin DB transaction
    |
    +-- Validate item available_amount
    |
    +-- Insert transaction RETURNING id
    |
    +-- Insert transaction_items
    |
    +-- Commit
    |
    v
Response
```

This flow shows why the monolith is the simplest write-path baseline. The same
application layer can validate requested item amounts, open a database
transaction, create the transaction header, create the detail rows, and commit
the work without handing control to another service.

ASCII sequence:

```text
Client/k6          Monolith                         mono_db
   |                  |                                |
   | POST /transactions                                |
   |----------------->|                                |
   |                  | BEGIN                          |
   |                  |------------------------------->|
   |                  | SELECT available_amount         |
   |                  |------------------------------->|
   |                  | INSERT transactions RETURNING id|
   |                  |------------------------------->|
   |                  | INSERT transaction_items        |
   |                  |------------------------------->|
   |                  | COMMIT                         |
   |                  |------------------------------->|
   |<-----------------|                                |
   | 201 Created      |                                |
```

The sequence highlights that all write coordination stays inside one runtime
and one database transaction. If validation or insert work fails, the
application can roll back locally without crossing a service boundary or
coordinating a second database owner.

Expected monolith characteristic:

- transaction and item validation can be handled inside one database transaction,
- no inter-service communication is required.
- rollback behavior is local to one database transaction if validation or insert work fails.

---

## 14. Benchmark 3: Enriched Transactions Flow

Endpoint:

```text
GET /api/v1/admin/transactions
```

Workload type:

```text
Aggregation workload
```

Purpose:

Evaluate read aggregation performance using a single database.

The monolith enriched read is intentionally database-centric. Because `users`,
`items`, `transactions`, and `transaction_items` are all owned by the same
application and database, the response can be assembled with one SQL query that
joins the required tables. This provides the centralized-read baseline for the
microservices version, where the same response shape is produced through raw
transaction reads plus API Gateway fan-out to Auth and Item services.

Flow:

```text
Client / k6
    |
    v
Transaction Handler
    |
    v
Transaction Usecase
    |
    v
Transaction Repository
    |
    v
Single SQL JOIN
    |
    +-- users
    +-- transactions
    +-- transaction_items
    +-- items
    |
    v
Response
```

This flow captures the monolith's main read-side advantage in this benchmark:
the enriched transaction response can be assembled where the data already lives.
The application does not need to call another runtime to fetch user or item
details because the database already contains the full relational picture.

ASCII sequence:

```text
Client/k6          Monolith                            mono_db
   |                  |                                   |
   | GET /admin/transactions                             |
   |----------------->|                                   |
   |                  | SQL JOIN users + transactions     |
   |                  | + transaction_items + items       |
   |                  |---------------------------------->|
   |                  |<----------------------------------|
   |<-----------------|                                   |
   | 200 enriched data|                                   |
```

The sequence is short because the heavy lifting happens inside one SQL query.
The application issues a join, receives the aggregated rows, maps them into
the REST response shape, and returns the result without additional RPC hops.

Expected monolith characteristic:

- enrichment can be done using SQL JOIN,
- no distributed join or service fan-out is required.
- the database query carries most of the enrichment cost, while application code mainly maps rows to the REST response.

---

## 15. Scaling Model

The monolith scales as a whole application.

Resource configuration:

```text
fixed mode        : 2 pods, each 3950m request / 7900m limit and 6912Mi request / 13824Mi limit
hpa mode          : 2 to 4 pods, each 1975m request / 3950m limit and 3456Mi request / 6912Mi limit
minReplicas       : 2
maxReplicas       : 4
HPA target CPU    : 70%
Total CPU ceiling : 15800m
Memory ceiling    : 27648Mi
```

Scaling behavior:

```text
If one module becomes hot,
the entire monolith is replicated.
```

Example:

```text
High login traffic
    |
    v
HPA scales monolith pods
    |
    v
Auth + Item + Transaction modules are all replicated
```

This is a key architectural trade-off.

```text
+-------------------+
| Monolith Pod 1    |
| Auth              |
| Item              |
| Transaction       |
+-------------------+

+-------------------+
| Monolith Pod 2    |
| Auth              |
| Item              |
| Transaction       |
+-------------------+

+-------------------+
| Monolith Pod 3    |
| Auth              |
| Item              |
| Transaction       |
+-------------------+
```

Advantages:

- simple scaling model,
- fewer moving parts,
- easier to reason about.

Limitations:

- coarse-grained scaling,
- potentially inefficient when only one module is under load,
- all modules consume resources in every replica.

---

## 16. Migration Strategy

The monolith uses Goose SQL migration.

Migration path:

```text
monolith/migrations/
```

Migration files:

```text
00001_create_users.sql
00002_create_items.sql
00003_create_transactions.sql
00004_create_transaction_items.sql
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

Example deployment preparation flow:

```text
Run monolith migration job
    |
    v
Run monolith seed job
    |
    v
Deploy monolith
    |
    v
Run benchmark
```

---

## 17. Seed Strategy

Seed data is managed centrally under:

```text
seed/
```

The monolith seed script inserts benchmark data into:

```text
mono_db.users
mono_db.items
mono_db.transactions
mono_db.transaction_items
```

For benchmark users and items, the seed script uses deterministic UUIDs so k6
and related tooling can rely on stable identities without querying the
database first.

Normal runtime inserts still use PostgreSQL-generated `uuidv7()` values with
`INSERT ... RETURNING id`.

Seed scripts still capture generated IDs with `INSERT ... RETURNING id` when
the IDs are not predetermined, such as enrichment transaction preparation.

The seed script must maintain mappings such as:

```text
logical_user_key -> seeded user_id
logical_item_key -> seeded item_id
logical_transaction_key -> generated transaction_id
```

The monolith and microservices datasets do not need identical UUID values, but they must be logically equivalent.

---

## 18. Observability

Datadog is used for monolith observability.

Important metrics:

- request latency,
- request throughput,
- error rate,
- CPU usage,
- memory usage,
- replica count,
- HPA scaling events,
- PostgreSQL query duration when available,
- RDS metrics when available.

Expected monolith trace shape:

```text
HTTP request
    |
    v
monolith handler
    |
    v
monolith usecase
    |
    v
repository
    |
    v
PostgreSQL
```

Example create transaction trace:

```text
POST /api/v1/transactions
    |
    v
transaction.handler
    |
    v
transaction.usecase
    |
    +-- item validation
    +-- transaction insert
    +-- transaction_items insert
    |
    v
postgresql
```

---

## 19. Strengths of the Monolith Baseline

The monolith baseline is useful because it provides:

- simpler runtime architecture,
- lower communication overhead,
- simpler database transaction model,
- direct SQL JOIN capability,
- fewer network boundaries,
- easier local debugging,
- easier deployment pipeline.

For low to moderate workloads, these characteristics may produce lower latency.

---

## 20. Limitations of the Monolith Baseline

The monolith has several limitations relevant to the experiment:

- all modules scale together,
- one hot module causes full application replication,
- resource usage can be less granular,
- deployment is coupled,
- failure or resource pressure inside one module may affect the entire application process,
- codebase complexity can grow as modules increase.

These limitations are part of the architectural trade-off evaluated by the research.

---

## 21. Fairness Rules

To keep the comparison fair, the monolith must follow these rules:

- expose the same external REST API as microservices,
- use the same programming language,
- use the same database engine,
- use the same logical dataset,
- use equivalent business logic,
- use equivalent authentication rules,
- use equivalent response format,
- use equivalent benchmark scenarios,
- use the same k6 scripts,
- use the same resource ceiling.

Do not add optimizations only to the monolith unless equivalent optimizations are applied to microservices or explicitly documented.

Examples of unfair differences:

- monolith has extra indexes but microservices do not,
- monolith skips authentication but microservices validate JWT,
- monolith uses cache while microservices do not,
- monolith uses different request payloads,
- monolith uses different response format.

---

## 22. Out of Scope for the Monolith Variant

The monolith implementation does not focus on:

- modular monolith governance,
- plugin architecture,
- event-driven internal modules,
- message queues,
- distributed transaction patterns,
- saga or compensation mechanisms,
- advanced domain-driven design,
- maintainability metrics.

These topics may be discussed as limitations or future work, but they are not part of the main benchmark design.

---

## 23. Summary

The monolith is the baseline implementation of the benchmark system.

It represents a single deployable application where all modules run in one process and share one PostgreSQL database.

Key design decisions:

```text
Runtime unit          : one application
Database              : mono_db
Communication         : in-process calls
External API          : REST HTTP
ID strategy           : PostgreSQL UUIDv7
Migration             : Goose SQL migration
Migration execution   : Kubernetes Job
Scaling unit          : whole application
Benchmark role        : baseline for performance and resource efficiency comparison
```

The monolith is expected to have lower communication overhead, simpler transaction handling, and simpler data aggregation, but less granular scaling compared with microservices.
