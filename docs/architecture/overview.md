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
            +-- Update items.available_amount
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
    +-- Read transactions
    |       |
    |       v
    |   transaction_db
    |
    +-- Collect user_ids
    +-- Collect item_ids
    |
    +-- gRPC GetUsersByIds
    |       |
    |       v
    |   Auth Service -> auth_db
    |
    +-- gRPC GetItemSummariesByIds
    |       |
    |       v
    |   Item Service -> item_db
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

High-level deployment topology:

```text
                         +----------------------+
                         |        AWS VPC       |
                         |                      |
+-------------+          |  +----------------+  |
|   Client    |          |  |  EKS Cluster   |  |
|    k6       |--------->|  |                |  |
+-------------+          |  |  app-nodes     |  |
                         |  |  testing-nodes |  |
                         |  +----------------+  |
                         |          |           |
                         |          v           |
                         |  +----------------+  |
                         |  | RDS PostgreSQL |  |
                         |  |      18        |  |
                         |  +----------------+  |
                         |          |           |
                         |          v           |
                         |  +----------------+  |
                         |  | S3 Results     |  |
                         |  +----------------+  |
                         +----------------------+
```

Node placement:

- application pods run on `app-nodes`,
- k6 runner runs on `testing-nodes`,
- Datadog Agent runs as DaemonSet on monitored nodes.

---

## 10. Resource and Autoscaling Overview

The application resource ceiling is designed to keep the comparison fair.

Monolith:

```text
CPU ceiling      : 4000m
Memory ceiling   : 4096Mi
CPU per pod      : 1000m
Memory per pod   : 1024Mi
minReplicas      : 1
maxReplicas      : 4
HPA target CPU   : 70%
```

Microservices:

```text
Namespace CPU ceiling    : 4000m
Namespace memory ceiling : 4096Mi
CPU per pod              : 250m
Memory per pod           : 256Mi
minReplicas per service  : 1
maxReplicas per service  : 16
HPA target CPU           : 70%
```

Reason for MSA maxReplicas 16:

```text
4000m total CPU quota / 250m per pod = 16 pods
```

This allows a focused service to scale up under targeted load while the namespace ResourceQuota prevents the total microservices resource budget from exceeding the monolith resource budget.

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
- both architectures are deployed in the same AWS/EKS environment,
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
