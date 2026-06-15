# Architecture Overview

## 1. Purpose

This document describes the high-level architecture of the thesis benchmark system used to compare **Monolithic Architecture** and **Microservices Architecture** in a cloud-native environment.

The project implements the same generic transactional API in two runtime variants:

1. **Monolith**
2. **Microservices**

Both variants expose the same external REST API. The main goal is to keep the external behavior equivalent while allowing the internal architecture, deployment boundary, database ownership, and communication pattern to differ.

This makes the system suitable for a controlled experimental comparison of:

- latency,
- throughput/RPS,
- error rate,
- CPU usage,
- memory usage,
- autoscaling behavior,
- resource efficiency.

The runtime architecture comparison is independent from the benchmark
execution topology. The same monolith and microservices implementations can be
measured in:

- parallel mode, where each architecture runs on its own Kubernetes cluster at
  the same wall-clock time, or
- sequential mode, where one architecture at a time runs on a single reusable
  Kubernetes cluster.

Execution mode must not change the external API, dataset, migration behavior,
resource ceiling, or application request path.

---

## 2. Architectural Goal

The benchmark is designed to answer a central architectural question:

> How do monolithic and microservices architectures differ in performance and resource efficiency when handling equivalent transactional workloads in a cloud-native environment?

The system is intentionally not modeled as a specific e-commerce application. Instead, it uses a **generic transactional workload** with the following domain concepts:

- user,
- item,
- transaction,
- amount,
- available_amount.

The term `item` represents a generic allocatable entity. It can conceptually represent a ticket category, booking slot, quota unit, inventory unit, or another resource-like object.

---

## 3. Runtime Variants

### 3.1 Monolith Runtime

The monolith is implemented as one deployable Go application.

It contains the following internal modules:

- Auth module,
- Item module,
- Transaction module.

All modules run in the same process and use one shared database named `mono_db`.

High-level monolith structure:

```text
Client / k6
    |
    v
Ingress / Load Balancer
    |
    v
Monolith Application
    |
    +-- Auth Module
    |
    +-- Item Module
    |
    +-- Transaction Module
    |
    v
mono_db
```

Key characteristics:

- one deployable unit,
- one process,
- one database,
- in-process internal communication,
- single scaling unit,
- SQL JOIN is allowed across tables,
- database foreign keys are allowed across `users`, `items`, `transactions`, and `transaction_items`.

---

### 3.2 Microservices Runtime

The microservices implementation consists of four deployable services:

- API Gateway,
- Auth Service,
- Item Service,
- Transaction Service.

The API Gateway is the only external REST HTTP entry point. Internal communication between services uses gRPC.

Each business service owns its own database:

- `auth-service` owns `auth_db`,
- `item-service` owns `item_db`,
- `transaction-service` owns `transaction_db`,
- `api-gateway` owns no database.

High-level microservices structure:

```text
Client / k6
    |
    v
Ingress / Load Balancer
    |
    v
API Gateway
    |
    +-------------------+
    |                   |
    v                   v
Auth Service       Transaction Service
    |                   |
    v                   +------------------+
 auth_db                |                  |
                        v                  v
                   Item Service       transaction_db
                        |
                        v
                     item_db
```

Key characteristics:

- multiple deployable services,
- API Gateway as external entry point,
- gRPC for internal communication,
- database per business service,
- independently scalable services,
- no cross-service database access,
- no foreign keys across service-owned databases,
- distributed join/fan-out is used for enriched transaction responses.

---

## 4. Code Architecture Style

All Go applications use **Layered Architecture with Clean/Hexagonal-inspired dependency direction**.

The intended dependency flow is:

```text
Handler / Transport Layer
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

Rules:

- handlers must not contain business logic,
- usecases contain business flow,
- repositories contain SQL/database logic,
- gRPC clients and servers are adapters,
- domain models must not depend on framework-specific packages,
- shared `pkg/` must contain only technical utilities, not business logic.

This project does **not** use full Domain-Driven Design unless explicitly required later.

---

## 5. External API Contract

Both monolith and microservices must expose the same external API.

Main benchmark endpoints:

| Benchmark | Endpoint | Workload Type |
|---|---|---|
| Benchmark 1 | `POST /api/v1/auth/login` | CPU-bound |
| Benchmark 2 | `POST /api/v1/transactions` | I/O-bound + item allocation |
| Benchmark 3 | `GET /api/v1/admin/transactions` | aggregation + network-bound |

All public IDs use UUID strings:

```yaml
type: string
format: uuid
```

---

## 6. Database Strategy

The database engine is:

```text
PostgreSQL 18
```

All primary keys use PostgreSQL native UUID with database-side UUIDv7 generation:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

Application code does not generate UUID manually during normal runtime inserts. Create operations use:

```sql
INSERT ... RETURNING id
```

All main tables include audit metadata:

```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
```

---

## 7. Database Ownership Model

### 7.1 Monolith Database Ownership

The monolith uses one database:

```text
mono_db
```

Tables:

- `users`,
- `items`,
- `transactions`,
- `transaction_items`.

Because all tables are owned by the same application, foreign keys are allowed:

```text
transactions.user_id
    -> users.id

transaction_items.transaction_id
    -> transactions.id

transaction_items.item_id
    -> items.id
```

---

### 7.2 Microservices Database Ownership

The microservices implementation uses database-per-service ownership:

```text
auth-service
    -> auth_db.users

item-service
    -> item_db.items

transaction-service
    -> transaction_db.transactions
    -> transaction_db.transaction_items
```

The Transaction Service stores `user_id` and `item_id` as UUID references only.

It must not create foreign keys to:

- `auth_db.users`,
- `item_db.items`.

This preserves service data ownership and prevents direct database coupling across services.

---

## 8. Benchmark Flow Overview

### 8.1 Benchmark 1: Login

Purpose:

- CPU-bound workload,
- password verification,
- JWT signing.

Monolith flow:

```text
Client / k6
    |
    v
Monolith
    |
    +-- Auth Module
            |
            +-- Find user by email
            +-- bcrypt password comparison
            +-- JWT signing
            |
            v
         mono_db.users
```

Microservices flow:

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

Expected architectural difference:

- monolith avoids network hop between gateway and auth logic,
- microservices adds API Gateway to Auth Service gRPC communication.

---

### 8.2 Benchmark 2: Create Transaction

Purpose:

- I/O-bound workload,
- write operation,
- item allocation,
- transaction persistence.

Monolith flow:

```text
Client / k6
    |
    v
Monolith
    |
    +-- Transaction Usecase
            |
            +-- Begin DB transaction
            +-- Validate item available_amount
            +-- Insert transactions RETURNING id
            +-- Insert transaction_items
            +-- Commit
            |
            v
          mono_db
```

Microservices flow:

```text
Client / k6
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    +-- gRPC ValidateTransactionItems
    |       |
    |       v
    |   Item Service
    |       |
    |       v
    |    item_db
    |
    +-- Insert transactions RETURNING id
    +-- Insert transaction_items
            |
            v
     transaction_db
```

Expected architectural difference:

- monolith uses a single local database transaction,
- microservices uses inter-service communication between Transaction Service and Item Service.

This research does not deeply evaluate distributed transaction patterns, saga, or compensation mechanisms.

---

### 8.3 Benchmark 3: Enriched Transactions

Purpose:

- aggregation workload,
- read-heavy scenario,
- compare SQL JOIN versus distributed join/fan-out.

Monolith flow:

```text
Client / k6
    |
    v
Monolith
    |
    +-- Single SQL JOIN
            |
            +-- users
            +-- transactions
            +-- transaction_items
            +-- items
            |
            v
          mono_db
```

Microservices flow:

```text
Client / k6
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    +-- Read transactions -> transaction_db
    |
    v
raw transactions
    |
    v
API Gateway
    |
    +-- Collect user_ids
    +-- Collect item_ids
    |
    +-- gRPC GetUsersByIds -> Auth Service -> auth_db
    |
    +-- gRPC GetItemSummariesByIds -> Item Service -> item_db
    |
    +-- In-memory enrichment
    |
    v
Response
```

Expected architectural difference:

- monolith uses direct SQL JOIN,
- microservices performs distributed data enrichment through service calls.

---

## 9. Deployment Environment Overview

The target deployment environment is AWS cloud-native infrastructure.

Main components:

- Amazon EKS for Kubernetes,
- Amazon RDS PostgreSQL 18,
- Amazon S3 for benchmark result storage,
- Datadog for observability,
- k6 for load testing,
- Terraform for infrastructure provisioning.

High-level deployment topology in parallel mode:

```text
AWS VPC
├── EKS: skripsi-monolith
│   ├── app-nodes      -> mono namespace
│   ├── testing-nodes  -> benchmark namespace
│   └── RDS            -> mono_db
│
└── EKS: skripsi-msa
    ├── app-nodes      -> msa namespace
    ├── testing-nodes  -> benchmark namespace
    └── RDS            -> auth_db, item_db, transaction_db

S3 stores benchmark artifacts from both clusters.
Datadog receives telemetry with distinct cluster_name tags.
```

High-level deployment topology in sequential mode:

```text
AWS VPC
└── EKS: skripsi-benchmark
    ├── app-nodes      -> one active architecture at a time
    ├── testing-nodes  -> benchmark namespace
    └── RDS            -> mono_db, auth_db, item_db, transaction_db

Sequential phase 1:
  mono namespace active, msa scaled down

Sequential phase 2:
  msa namespace active, mono scaled down

S3 stores the same artifact layout.
Datadog comparison uses recorded time windows instead of wall-clock alignment.
```

Node placement:

- application pods run on `app-nodes`,
- k6 runner runs on `testing-nodes`,
- Datadog Agent runs as DaemonSet on monitored nodes.

### 9.1 Active Implementation: Vultr

The active implementation uses Vultr instead of AWS EKS and Amazon RDS.
The application code, benchmark scripts, and external API contract remain
identical. Only the infrastructure hosting platform differs.

Main components (Vultr):

- Vultr Kubernetes Engine (VKE) for Kubernetes,
- PostgreSQL 18 on Vultr Compute VM (self-managed, cloud-init provisioned),
- Docker Hub for container images,
- AWS S3 for benchmark result storage (unchanged),
- Datadog SaaS for observability (unchanged),
- Terraform with vultr/vultr provider (~> 2.31).

Infrastructure mapping:

| Component | AWS (Original) | Vultr (Active) |
|---|---|---|
| Kubernetes | Amazon EKS | Vultr VKE |
| Database | Amazon RDS PostgreSQL 18 | PostgreSQL 18 on Compute VM |
| Container registry | Amazon ECR | Docker Hub |
| Networking | AWS VPC | Vultr Legacy VPC |
| Provisioning | Terraform AWS provider | Terraform Vultr provider |

High-level Vultr deployment topology in parallel mode:

```text
Vultr Region: sgp (Singapore)

Vultr Legacy VPC (10.20.0.0/16)
├── VKE: skripsi-vultr-monolith
│   ├── app-nodes (1 x voc-c-8c-16gb-150s-amd) -> mono namespace
│   ├── testing-nodes (1 x vc2-2c-4gb)         -> benchmark namespace
│   └── PostgreSQL VM                          -> mono_db
│
└── VKE: skripsi-vultr-msa
    ├── app-nodes (1 x voc-c-8c-16gb-150s-amd) -> msa namespace
    ├── testing-nodes (1 x vc2-2c-4gb)         -> benchmark namespace
    └── PostgreSQL VM                          -> auth_db, item_db, transaction_db

External services:
  Docker Hub: container images
  AWS S3: benchmark artifacts
  Datadog SaaS: metrics, traces, logs
```

High-level Vultr deployment topology in sequential mode:

```text
Vultr Region: sgp (Singapore)

Vultr Legacy VPC (10.20.0.0/16)
└── VKE: skripsi-vultr-benchmark
    ├── app-nodes (1 x voc-c-8c-16gb-150s-amd) -> one active architecture at a time
    ├── testing-nodes (1 x vc2-2c-4gb)         -> benchmark namespace
    └── PostgreSQL VM                          -> mono_db, auth_db, item_db, transaction_db

Sequential phase 1:
  mono namespace active, msa scaled down

Sequential phase 2:
  msa namespace active, mono scaled down
```

For the complete Vultr infrastructure reference, see:
`docs/infrastructure/vultr-complete-architecture.md`.
For the active fixed-suite versus supplemental-HPA benchmark flow, see:
`docs/architecture/benchmark-execution-workflows.md`.

---

## 10. Resource and Autoscaling Overview

The application resource ceiling is designed to keep the comparison fair.

Monolith:

```text
CPU ceiling      : 7800m
Memory ceiling   : 15360Mi
fixed            : 1 pod x (3900m request / 7800m limit, 7680Mi request / 15360Mi limit)
single-architecture HPA suite : use microservices HPA; monolith remains fixed
```

Microservices:

```text
Namespace CPU ceiling    : 7800m
Namespace memory ceiling : 15360Mi
fixed per service        : request 980m / limit 1950m / 1920Mi / 3840Mi
hpa per service          : request 500m / limit 975m / 960Mi / 1920Mi
minReplicas per service  : 1
maxReplicas per service  : 5
shared HPA headroom      : 4 additional pods across the namespace
HPA target CPU           : 50%
```

The active Vultr benchmark path uses an equal per-service split rather than
role-aware service budgets because the study does not have a separate
empirical profiling dataset to justify asymmetric service ceilings.

---

## 11. Migration and Seed Overview

Migration uses:

```text
Goose SQL migration
```

Migration execution uses:

```text
Kubernetes Job
```

Migration is not executed through init containers because migration must run once per deployment or release, not once per pod.

Migration locations:

```text
monolith/migrations/

microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/
```

Seed data is centralized:

```text
seed/
├── README.md
├── Dockerfile
├── cmd/seed-runner/
└── internal/seed/
```

Rules:

- migration is for schema only,
- seed is for benchmark data,
- seed runner behavior is documented in `seed/README.md`,
- seed data must be retry-safe for Kubernetes Job reruns,
- data must be reset and reseeded before benchmark scenarios that mutate data.

---

## 12. Observability Overview

Datadog is used to collect internal system behavior.

Collected metrics include:

- request latency,
- throughput,
- error rate,
- CPU usage,
- memory usage,
- pod replica count,
- HPA events,
- trace spans,
- RDS metrics when available.

k6 is the primary source for external client-perceived metrics.

Datadog is used to explain internal causes behind observed benchmark results.

Expected MSA trace for Create Transaction:

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

Expected MSA trace for Enriched Transactions:

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

---

## 13. Architectural Comparison Summary

| Aspect | Monolith | Microservices |
|---|---|---|
| Deployment unit | One application | Multiple services |
| External API | REST HTTP | REST HTTP via API Gateway |
| Internal communication | In-process calls | gRPC |
| Database ownership | One shared database | Database per service |
| Foreign keys | Allowed across modules | Not allowed across services |
| Transaction boundary | Single DB transaction | Multi-service flow |
| Enrichment strategy | SQL JOIN | Distributed join/fan-out |
| Scaling unit | Entire application | Per service |
| Operational complexity | Lower | Higher |
| Network overhead | Lower | Higher |
| Resource scaling granularity | Coarse-grained | Fine-grained |

---

## 14. Key Architectural Assumptions

The experiment assumes:

- both architectures use the same external API,
- both architectures use the same programming language,
- both architectures use PostgreSQL 18,
- both architectures use equivalent logical datasets,
- both architectures are tested using the same k6 scripts,
- both architectures are deployed with the same AWS/EKS baseline and the same
  per-architecture resource ceiling,
- execution mode is recorded as `parallel` or `sequential` and does not change
  benchmark semantics,
- both architectures are evaluated using the same metric definitions.

The purpose is to isolate the architectural differences as much as possible.

---

## 15. Out of Scope

The following topics are not the main focus of this research:

- full distributed transaction consistency,
- saga pattern,
- compensation mechanism,
- chaos engineering,
- disaster recovery,
- multi-region failover,
- maintainability analysis,
- developer productivity analysis,
- cost optimization as a primary metric,
- KEDA or RPS-based autoscaling,
- message queue architecture.

These may be mentioned as limitations or future work, but they are not part of the main experimental scope.
