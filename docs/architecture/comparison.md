# Architecture Comparison

## 1. Purpose

This document compares the monolithic and microservices architecture variants used in the thesis benchmark project.

The comparison focuses on the architectural characteristics that directly affect:

- performance,
- latency,
- throughput,
- error rate,
- CPU usage,
- memory usage,
- autoscaling behavior,
- resource efficiency,
- operational complexity.

Both architectures implement the same external REST API and equivalent business behavior. The main difference lies in their internal runtime structure, database ownership model, communication pattern, and scaling unit.

The benchmark execution topology is not an application architecture variant.
It only controls how the two existing architectures are scheduled for
measurement:

- parallel mode runs monolith and microservices at the same wall-clock time on
  two isolated EKS clusters (or two VKE clusters on Vultr),
- sequential mode runs one architecture phase at a time on one EKS cluster (or
  one VKE cluster on Vultr) for quota-constrained accounts.

Both modes must preserve the same resource ceilings, workload scripts, seed
data assumptions, and request completion semantics.

---

## 2. Comparison Scope

This comparison covers:

- deployment unit,
- code organization,
- internal communication,
- database ownership,
- transaction handling,
- data enrichment strategy,
- scaling behavior,
- resource allocation,
- migration and seed strategy,
- benchmark workload behavior,
- observability,
- fairness controls.

This comparison does not evaluate:

- maintainability as a primary metric,
- developer productivity,
- team organization,
- long-term cost optimization,
- disaster recovery,
- multi-region deployment,
- full distributed transaction consistency,
- chaos engineering.

---

## 3. High-Level Architecture Difference

## 3.1 Monolith

The monolith runs all modules inside one application process.

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
    +-- Item Module
    +-- Transaction Module
    |
    v
mono_db
```

Main characteristics:

- one deployable application,
- one process,
- one database,
- one scaling unit,
- in-process communication,
- SQL JOIN allowed,
- database transaction across modules allowed.

---

## 3.2 Microservices

The microservices architecture splits the application into several independently deployable services.

```text
Client / k6
    |
    v
Ingress / Load Balancer
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

Main characteristics:

- multiple deployable services,
- API Gateway as external entry point,
- gRPC internal communication,
- database per business service,
- per-service scaling,
- no direct cross-service database access,
- distributed join/fan-out for enriched data.

---

## 4. Summary Comparison Table

| Aspect | Monolith | Microservices |
|---|---|---|
| Deployment unit | One application | Multiple services |
| Runtime process | One process per pod | One process per service pod |
| External API | REST HTTP | REST HTTP via API Gateway |
| Internal communication | In-process calls | gRPC |
| Database model | One shared database | Database per service |
| Database ownership | Owned by monolith | Owned by each service |
| Cross-module FK | Allowed | Not allowed across services |
| Transaction boundary | Single DB transaction | Multi-service flow |
| Data enrichment | SQL JOIN | Distributed join/fan-out |
| Scaling unit | Entire application | Individual service |
| HPA target | Monolith deployment | Each service deployment |
| Resource allocation | Coarse-grained | Fine-grained |
| Network overhead | Lower | Higher |
| Operational complexity | Lower | Higher |
| Observability complexity | Lower | Higher |
| Service autonomy | Lower | Higher |
| Fault isolation | Lower | Higher |
| Benchmark role | Baseline | Distributed comparison target |

---

## 5. Deployment Unit Comparison

## 5.1 Monolith Deployment

The monolith is deployed as one Kubernetes Deployment.

```text
+----------------------+
| Monolith Deployment  |
|                      |
|  Pod 1               |
|  Pod 2               |
|  Pod N               |
+----------------------+
```

Each pod contains all modules:

```text
Monolith Pod
├── Auth Module
├── Item Module
└── Transaction Module
```

When the monolith scales out, all modules are replicated together.

---

## 5.2 Microservices Deployment

Each microservice is deployed independently.

```text
+------------------------+
| API Gateway Deployment |
+------------------------+

+-------------------------+
| Auth Service Deployment |
+-------------------------+

+-------------------------+
| Item Service Deployment |
+-------------------------+

+-------------------------------+
| Transaction Service Deployment |
+-------------------------------+
```

Each service can scale independently.

```text
API Gateway         x N replicas
Auth Service        x N replicas
Item Service        x N replicas
Transaction Service x N replicas
```

---

## 6. Communication Comparison

## 6.1 Monolith Communication

The monolith uses in-process communication between modules.

```text
HTTP Handler
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

Characteristics:

- no network hop between internal modules,
- no serialization between modules,
- lower communication overhead,
- simpler debugging path,
- simpler trace path.

---

## 6.2 Microservices Communication

The microservices architecture uses gRPC for internal service communication.

```text
API Gateway
    |
    v
gRPC
    |
    v
Business Service
```

Service-to-service communication example:

```text
Transaction Service
    |
    +--> Item Service via gRPC
    |
    +--> Auth Service via gRPC
```

Characteristics:

- additional network hop,
- serialization/deserialization overhead,
- possible timeout or connection error,
- distributed tracing required,
- more realistic cloud-native distributed behavior.

---

## 7. Database Ownership Comparison

## 7.1 Monolith Database

The monolith owns one database:

```text
mono_db
├── users
├── items
├── transactions
└── transaction_items
```

Allowed foreign keys:

```text
transactions.user_id -> users.id

transaction_items.transaction_id -> transactions.id

transaction_items.item_id -> items.id
```

The monolith can use SQL JOIN across all tables.

---

## 7.2 Microservices Databases

The microservices architecture uses database ownership per service.

```text
auth-service
    |
    v
auth_db.users

item-service
    |
    v
item_db.items

transaction-service
    |
    v
transaction_db.transactions
transaction_db.transaction_items
```

Allowed foreign key inside transaction database:

```text
transaction_items.transaction_id -> transactions.id
```

Not allowed:

```text
transactions.user_id -> auth_db.users.id

transaction_items.item_id -> item_db.items.id
```

The Transaction Service stores `user_id` and `item_id` as UUID references only.

Reason:

Cross-service foreign keys would couple the Transaction Service to databases owned by other services.

---

## 8. ID Strategy Comparison

Both architectures use the same ID strategy.

Database engine:

```text
PostgreSQL 18
```

Primary key type:

```text
UUID
```

ID generation:

```sql
DEFAULT uuidv7()
```

Runtime insert pattern:

```sql
INSERT ... RETURNING id
```

Application code does not generate UUID manually during normal runtime inserts.

Comparison:

| Aspect | Monolith | Microservices |
|---|---|---|
| ID type | UUID | UUID |
| ID version | UUIDv7 | UUIDv7 |
| ID generator | PostgreSQL | PostgreSQL |
| Runtime insert | `INSERT ... RETURNING id` | `INSERT ... RETURNING id` |
| Public API format | string, format uuid | string, format uuid |

---

## 9. Audit Metadata Comparison

Both architectures use audit metadata in all main tables.

Required fields:

```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
```

Tables:

| Table | Monolith | Microservices |
|---|---|---|
| users | yes | auth_db.users |
| items | yes | item_db.items |
| transactions | yes | transaction_db.transactions |
| transaction_items | yes | transaction_db.transaction_items |

This keeps schema behavior fair across both implementations.

---

## 10. Benchmark 1: Login Comparison

Endpoint:

```text
POST /api/v1/auth/login
```

Workload type:

```text
CPU-bound
```

Main operations:

- find user by email,
- bcrypt password comparison,
- JWT signing.

---

## 10.1 Monolith Login Flow

```text
Client / k6
    |
    v
Monolith
    |
    +-- Auth Module
            |
            +-- SELECT user by email
            +-- bcrypt compare
            +-- JWT signing
            |
            v
         mono_db.users
```

---

## 10.2 Microservices Login Flow

```text
Client / k6
    |
    v
API Gateway
    |
    v
Auth Service
    |
    +-- SELECT user by email
    +-- bcrypt compare
    +-- JWT signing
    |
    v
auth_db.users
```

---

## 10.3 Expected Architectural Difference

| Aspect | Monolith | Microservices |
|---|---|---|
| Network hops | fewer | more |
| Auth logic location | same process | Auth Service |
| Scaling unit | whole app | API Gateway/Auth Service |
| Expected low-load latency | potentially lower | potentially higher |
| Expected targeted scaling | coarse-grained | finer-grained |

The monolith may show lower latency because there is no API Gateway-to-Auth-Service gRPC call.

Microservices may show more targeted scaling because login-heavy load can primarily scale API Gateway and Auth Service.

---

## 11. Benchmark 2: Create Transaction Comparison

Endpoint:

```text
POST /api/v1/transactions
```

Workload type:

```text
I/O-bound + state mutation
```

Main operations:

- validate item availability,
- insert transaction,
- insert transaction_items.

---

## 11.1 Monolith Create Transaction Flow

```text
Client / k6
    |
    v
Monolith
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

The monolith can execute this flow inside one database transaction.

---

## 11.2 Microservices Create Transaction Flow

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

The microservices version splits allocation and transaction persistence across service boundaries.

---

## 11.3 Expected Architectural Difference

| Aspect | Monolith | Microservices |
|---|---|---|
| Transaction boundary | one DB transaction | multi-service synchronous flow |
| Item allocation | local DB operation | Item Service gRPC call |
| Network overhead | lower | higher |
| Data ownership | shared DB | service-owned DBs |
| Consistency model | simpler | more complex |
| Scaling unit | whole app | Transaction/Item services |

The monolith is expected to have simpler transaction handling.

The microservices variant is expected to have additional communication overhead but clearer ownership between transaction and item data.

---

## 12. Benchmark 3: Enriched Transactions Comparison

Endpoint:

```text
GET /api/v1/admin/transactions
```

Workload type:

```text
Aggregation + network-bound
```

Main operation:

Return transaction data enriched with user summary and item summary details.

The enriched transaction response intentionally omits `item.available_amount`.
The benchmark compares aggregation strategy, not current inventory reporting.

---

## 12.1 Monolith Enrichment Flow

```text
Client / k6
    |
    v
Monolith
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
mono_db
```

The monolith can perform enrichment using one SQL query or a small number of local queries.

---

## 12.2 Microservices Enrichment Flow

```text
Client / k6
    |
    v
API Gateway
    |
    v
Transaction Service
    |
    +-- Query transaction_db
    |
    v
raw transactions
    |
    v
API Gateway
    |
    +-- Collect user_ids
    |
    +-- Collect item_ids
    |
    +-- gRPC GetUsersByIds -> Auth Service
    |
    +-- gRPC GetItemSummariesByIds -> Item Service
    |
    +-- In-memory enrichment
    |
    v
Response
```

The microservices version performs distributed join/fan-out.

---

## 12.3 Expected Architectural Difference

| Aspect | Monolith | Microservices |
|---|---|---|
| Enrichment method | SQL JOIN | service fan-out |
| Data access | one database | multiple services |
| Network overhead | lower | higher |
| Query simplicity | simpler | more complex |
| Ownership boundary | weaker | stronger |
| Observability need | lower | higher |

The monolith may show better latency for enriched reads because all data is local to one database.

The microservices version better preserves ownership boundaries but pays communication and aggregation overhead.

---

## 13. Scaling Comparison

## 13.1 Monolith Scaling

Monolith resource configuration:

```text
fixed mode        : 1 pod, 3900m request / 7800m limit and 7680Mi request / 15360Mi limit
hpa mode          : 1 to 4 pods, each 970m request / 1950m limit and 1920Mi request / 3840Mi limit
minReplicas       : 1
maxReplicas       : 4
HPA target CPU    : 70%
Total CPU ceiling : 7800m
Memory ceiling    : 15360Mi
```

Scaling behavior:

```text
Hot module
    |
    v
Scale entire monolith
    |
    v
Auth + Item + Transaction all replicated
```

---

## 13.2 Microservices Scaling

Microservices resource configuration per service:

```text
fixed api-gateway         : request 980m / limit 1950m / 1920Mi / 3840Mi
fixed auth-service        : request 980m / limit 1950m / 1920Mi / 3840Mi
fixed item-service        : request 980m / limit 1950m / 1920Mi / 3840Mi
fixed transaction-service : request 980m / limit 1950m / 1920Mi / 3840Mi

hpa api-gateway           : request 500m / limit 975m / 960Mi / 1920Mi
hpa auth-service          : request 500m / limit 975m / 960Mi / 1920Mi
hpa item-service          : request 500m / limit 975m / 960Mi / 1920Mi
hpa transaction-service   : request 500m / limit 975m / 960Mi / 1920Mi
minReplicas         : 1
HPA target CPU      : 70%
scaleDown window    : 60s
```

Per-service maxReplicas:

```text
api-gateway         : 2
auth-service        : 2
item-service        : 2
transaction-service : 2
```

Namespace ceiling:

```text
CPU max           : 7800m
Memory max        : 15360Mi
```

Scaling behavior:

```text
Hot service
    |
    v
Scale only affected service
    |
    v
Other services may remain at lower replica count
```

---

## 13.3 Scaling Trade-Off

| Aspect | Monolith | Microservices |
|---|---|---|
| Scaling granularity | coarse | fine |
| Simplicity | simpler | more complex |
| Resource isolation | lower | higher |
| HPA target | one deployment | multiple deployments |
| Quota contention | simpler | possible between services |
| Idle module replication | possible | less likely |
| Pod node spreading | not needed (replicas are identical) | pod anti-affinity across app nodes |

Microservices may be more efficient under focused load because only the hot service needs to scale.

However, ResourceQuota may create scheduling contention when several services need to scale at the same time.

---

## 14. Resource Efficiency Comparison

The resource efficiency evaluation focuses on how much CPU and memory each architecture uses to sustain a given workload and target RPS.

Potential indicators:

- average CPU usage,
- peak CPU usage,
- average memory usage,
- peak memory usage,
- achieved RPS per CPU,
- error rate under resource pressure,
- replica count behavior,
- CPU usage distribution across components.

Example comparison idea:

```text
Resource efficiency = achieved throughput / CPU used
```

This project does not reduce the analysis to a single formula only. The final interpretation should consider latency, error rate, and resource usage together.

---

## 15. Observability Comparison

## 15.1 Monolith Observability

Expected trace shape:

```text
HTTP request
    |
    v
monolith handler
    |
    v
usecase
    |
    v
repository
    |
    v
PostgreSQL
```

Monitoring focus:

- total application CPU,
- total application memory,
- endpoint latency,
- database query duration,
- HPA replica count.

---

## 15.2 Microservices Observability

Expected trace shape:

```text
HTTP request
    |
    v
api-gateway
    |
    v
business service
    |
    +-- database
    |
    +-- other service
```

Monitoring focus:

- per-service CPU,
- per-service memory,
- gRPC latency,
- gRPC error rate,
- fan-out path latency,
- service-level bottlenecks,
- HPA behavior per service.

Microservices require deeper tracing because requests cross multiple runtime boundaries.

---

## 16. Migration Strategy Comparison

## 16.1 Monolith Migration

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

Execution:

```text
Goose SQL migration via Kubernetes Job
```

---

## 16.2 Microservices Migration

Migration paths:

```text
microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/
```

Migration jobs:

```text
auth-migration-job
item-migration-job
transaction-migration-job
```

Execution:

```text
Goose SQL migration via Kubernetes Job
```

API Gateway has no migration.

---

## 16.3 Migration Difference

| Aspect | Monolith | Microservices |
|---|---|---|
| Migration ownership | one application | per service |
| Migration location | monolith/migrations | service-level migrations |
| Number of migration jobs | one | multiple |
| Database target | mono_db | auth_db, item_db, transaction_db |
| API Gateway migration | not applicable | none |

---

## 17. Seed Strategy Comparison

Seed data is centralized under:

```text
seed/
├── datasets/
└── scripts/
```

The monolith seed inserts into:

```text
mono_db.users
mono_db.items
mono_db.transactions
mono_db.transaction_items
```

The microservices seed inserts into:

```text
auth_db.users
item_db.items
transaction_db.transactions
transaction_db.transaction_items
```

For benchmark users and items, the seed scripts use deterministic UUIDs so the
same logical dataset can be referenced directly by k6 and related tooling.

Runtime inserts still use PostgreSQL-generated IDs with `INSERT ... RETURNING id`.
Generated IDs must still be captured when the seed path inserts records whose
IDs are not predetermined, such as enrichment transactions.

Logical equivalence matters more than identical UUID values.

Fair seed requirements:

```text
same user count
same item count
same transaction count
same amount distribution
same available_amount distribution
same benchmark access pattern
```

---

## 18. Fairness Controls

The experiment must control non-architectural differences.

Controlled variables:

| Variable | Control Strategy |
|---|---|
| Programming language | Go for both |
| External API | Same OpenAPI contract |
| Database engine | PostgreSQL 18 |
| ID strategy | UUIDv7 generated by DB |
| Load generator | k6 |
| Test scenarios | Same scripts |
| Deployment environment | Same cloud environment (AWS EKS or Vultr VKE) |
| Resource ceiling | Measurement-derived per architecture (Vultr) or 15800m CPU / 27648Mi (AWS) |
| Observability | Datadog |
| Dataset | Logically equivalent seed |
| Authentication behavior | Equivalent JWT rules |
| Response format | Equivalent JSON format |
| Execution mode | Recorded as `parallel` or `sequential`; must not change app semantics |

Execution topology controls how measurements are scheduled, not what is being
measured. Parallel mode gives wall-clock-aligned Datadog series. Sequential
mode gives lower infrastructure footprint and uses `ARCHITECTURE_SWITCH_DELAY`
plus recorded Datadog windows to keep comparison periods clear.

Avoid unfair differences:

- caching in only one architecture,
- async queue in only one architecture,
- different endpoint payloads,
- different indexes without documentation,
- different authentication behavior,
- different data volume,
- different load path,
- different response completion semantics.

---

## 19. Expected Performance Trade-Offs

## 19.1 Monolith Expected Advantages

The monolith may perform better when:

- workload is low to moderate,
- internal communication overhead matters,
- SQL JOIN is efficient,
- single database transaction is beneficial,
- deployment path is simple,
- the system does not need granular scaling.

Expected strengths:

- lower low-load latency,
- simpler transaction handling,
- simpler query model,
- fewer network hops,
- simpler observability path.

---

## 19.2 Microservices Expected Advantages

Microservices may perform better when:

- load is concentrated on specific services,
- service-level scaling is beneficial,
- horizontal scaling can be used effectively,
- service ownership boundaries matter,
- distributed tracing reveals clear bottlenecks,
- the system benefits from independent scaling.

Expected strengths:

- better scaling granularity,
- potentially better resource allocation under focused load,
- independent deployment,
- clearer service ownership,
- better isolation between service responsibilities.

---

## 19.3 Shared Risks

Both architectures may be limited by:

- database bottleneck,
- load generator bottleneck,
- network variability,
- insufficient node resources,
- HPA stabilization delay,
- connection pool saturation,
- PostgreSQL lock contention,
- inefficient queries,
- insufficient warm-up,
- dataset mutation across scenarios.

---

## 20. Completion Semantics

A critical fairness rule is that both architectures must return responses after equivalent work has been completed.

Chosen create transaction semantics:

```text
Request is complete only after:
- item allocation has been validated,
- transaction has been inserted,
- transaction_items have been inserted,
- response is returned.
```

Unfair pattern:

```text
Microservices returns response immediately after publishing an event,
while the actual allocation continues asynchronously.
```

This would compare different things:

```text
Monolith response time:
end-to-end synchronous completion

Microservices response time:
only time until event is accepted
```

Therefore, this project uses a synchronous REST + gRPC flow for create transaction.

---

## 21. Architecture Decision Summary

| Decision | Final Choice |
|---|---|
| External API | Same REST API for both |
| Internal MSA protocol | gRPC |
| Monolith DB | mono_db |
| MSA DB model | database per service |
| ID strategy | PostgreSQL UUIDv7 |
| Migration | Goose SQL |
| Migration execution | Kubernetes Job |
| Seed | central seed scripts |
| Monolith scaling | whole app |
| MSA scaling | per service |
| Autoscaling metric | CPU-based HPA |
| Resource fairness | Measurement-derived ceiling (Vultr) or 15800m CPU / 27648Mi (AWS) |
| Execution topology | parallel or sequential, documented in benchmark metadata |
| Async transaction flow | excluded |
| Caching | excluded unless applied fairly |
| Message queue | excluded |

---

## 22. Final Comparison Diagram

```text
                              +----------------------+
                              |      Client / k6     |
                              +----------+-----------+
                                         |
                 +-----------------------+-----------------------+
                 |                                               |
                 v                                               v
        +------------------+                           +------------------+
        |     Monolith     |                           |   API Gateway    |
        |                  |                           +--------+---------+
        |  Auth Module     |                                    |
        |  Item Module     |                      +-------------+-------------+
        |  Transaction     |                      |             |             |
        |  Module          |                      v             v             v
        +--------+---------+              +------------+ +------------+ +----------------+
                 |                        | Auth Svc   | | Item Svc   | | Transaction Svc|
                 v                        +-----+------+ +-----+------+ +--------+-------+
             +---------+                        |              |                 |
             | mono_db |                        v              v                 v
             +---------+                    auth_db         item_db       transaction_db
```

---

## 23. Conclusion

The monolith and microservices implementations are designed to be functionally equivalent from the external API perspective, but architecturally different internally.

The monolith emphasizes:

- simplicity,
- low internal communication overhead,
- single database transaction,
- direct SQL JOIN,
- coarse-grained scaling.

The microservices architecture emphasizes:

- service autonomy,
- database ownership boundaries,
- gRPC service communication,
- distributed enrichment,
- fine-grained scaling.

The benchmark is designed to measure how these architectural differences affect performance and resource efficiency under controlled cloud-native conditions.
