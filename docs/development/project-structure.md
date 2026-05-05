# Project Structure

## 1. Purpose

This document describes the final repository structure for the thesis benchmark project.

The repository is designed as a **monorepo** that contains:

- monolith implementation,
- microservices implementation,
- shared API contracts,
- gRPC contracts,
- benchmark scripts,
- infrastructure code,
- Kubernetes manifests,
- seed scripts,
- documentation.

The monorepo is used for development consistency. Runtime deployment must still preserve the architectural difference between monolith and microservices.

---

## 2. Repository Model

Repository model:

```text
Monorepo
```

Main reason:

- easier to keep monolith and microservices aligned,
- easier to maintain the same OpenAPI contract,
- easier to share proto files,
- easier to compare implementation differences,
- easier to run benchmark scripts from one repository,
- easier to guide Codex using one root `AGENTS.md`.

Important rule:

```text
Monorepo does not mean monolithic runtime.
```

Runtime distinction remains:

```text
Monolith:
one deployable application

Microservices:
multiple independently deployable services
```

---

## 3. Final Top-Level Structure

```text
monolith-vs-microservice-thesis/
├── AGENTS.md
├── go.work
├── go.work.sum
├── .gitignore
├── .dockerignore
│
├── docs/
├── monolith/
├── microservices/
├── proto/
├── pkg/
├── seed/
├── deployments/
├── infra/
├── k6/
└── scripts/
```

Top-level folder responsibilities:

| Path | Responsibility |
|---|---|
| `AGENTS.md` | Codex repository guidance |
| `go.work` | Go workspace for monolith and services |
| `go.work.sum` | Go workspace checksums |
| `docs/` | project documentation |
| `monolith/` | monolithic implementation |
| `microservices/` | microservices implementation |
| `proto/` | gRPC contracts |
| `pkg/` | shared technical utilities |
| `seed/` | benchmark dataset and seed scripts |
| `deployments/` | Kubernetes and Helm manifests |
| `infra/` | Terraform infrastructure |
| `k6/` | benchmark scripts and runner |
| `scripts/` | operational automation scripts |

---

## 4. Documentation Structure

Path:

```text
docs/
```

Final structure:

```text
docs/
├── architecture/
│   ├── overview.md
│   ├── monolith.md
│   ├── microservices.md
│   ├── comparison.md
│   └── diagrams/
│
├── api/
│   ├── openapi-notes.md
│   └── grpc-contracts.md
│
├── development/
│   ├── project-structure.md
│   ├── database-schema.md
│   └── database-migration.md
│
└── infrastructure/
    └── rds-postgres.md
```

Rule:

```text
Documentation that applies to both architectures belongs under root docs/.
Service-specific README files are allowed but should not duplicate main design decisions.
```

---

## 5. Monolith Structure

Path:

```text
monolith/
```

Final structure:

```text
monolith/
├── go.mod
├── go.sum
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── auth/
│   ├── item/
│   ├── transaction/
│   └── shared/
│
└── migrations/
    ├── 00001_create_users.sql
    ├── 00002_create_items.sql
    ├── 00003_create_transactions.sql
    └── 00004_create_transaction_items.sql
```

Rules:

- monolith uses one database: `mono_db`,
- monolith migration is stored under `monolith/migrations/`,
- monolith exposes the same REST API as microservices,
- monolith internal modules communicate using in-process calls,
- monolith may use SQL JOIN and foreign keys across all owned tables.

---

## 6. Microservices Structure

Path:

```text
microservices/
```

Final structure:

```text
microservices/
├── api-gateway/
├── auth-service/
├── item-service/
└── transaction-service/
```

---

## 6.1 API Gateway

```text
microservices/api-gateway/
├── go.mod
├── go.sum
│
├── cmd/
│   └── server/
│       └── main.go
│
└── internal/
    ├── handler/
    ├── client/
    ├── middleware/
    ├── dto/
    ├── router/
    ├── config/
    └── bootstrap/
```

Rules:

- API Gateway exposes REST HTTP,
- API Gateway calls internal services using gRPC,
- API Gateway must not contain core business logic,
- API Gateway must not access databases,
- API Gateway has no migrations.

---

## 6.2 Auth Service

```text
microservices/auth-service/
├── go.mod
├── go.sum
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── domain/
│   ├── usecase/
│   ├── port/
│   ├── adapter/
│   │   ├── postgres/
│   │   └── grpcserver/
│   ├── security/
│   ├── config/
│   └── bootstrap/
│
└── migrations/
    └── 00001_create_users.sql
```

Rules:

- Auth Service owns `auth_db`,
- Auth Service owns the `users` table,
- Auth Service handles register, login, and user lookup,
- Auth Service must not access `item_db` or `transaction_db`.

---

## 6.3 Item Service

```text
microservices/item-service/
├── go.mod
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── domain/
│   ├── usecase/
│   ├── port/
│   ├── adapter/
│   │   ├── postgres/
│   │   └── grpcserver/
│   ├── config/
│   └── bootstrap/
│
└── migrations/
    └── 00001_create_items.sql
```

Rules:

- Item Service owns `item_db`,
- Item Service owns the `items` table,
- Item Service handles `available_amount`,
- Item Service handles `ValidateAndAllocate`,
- Item Service must not access `auth_db` or `transaction_db`.

---

## 6.4 Transaction Service

```text
microservices/transaction-service/
├── go.mod
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── domain/
│   ├── usecase/
│   ├── port/
│   ├── adapter/
│   │   ├── postgres/
│   │   ├── grpcclient/
│   │   └── grpcserver/
│   ├── config/
│   └── bootstrap/
│
└── migrations/
    ├── 00001_create_transactions.sql
    └── 00002_create_transaction_items.sql
```

Rules:

- Transaction Service owns `transaction_db`,
- Transaction Service owns `transactions` and `transaction_items`,
- Transaction Service calls Item Service through gRPC for allocation,
- Transaction Service calls Auth Service and Item Service through gRPC for enrichment,
- Transaction Service must not access `auth_db` or `item_db` directly.

---

## 7. Proto Structure

Path:

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

Rules:

- proto files are the source of truth for internal gRPC contracts,
- UUID values are represented as strings in proto,
- do not manually edit generated code,
- regenerate Go code after proto changes.

---

## 8. Shared Package Structure

Path:

```text
pkg/
```

Final structure:

```text
pkg/
├── config/
├── logger/
├── observability/
├── response/
├── errors/
├── jwt/
├── postgres/
└── validator/
```

Allowed in `pkg/`:

- config loader,
- logger helper,
- observability helper,
- response helper,
- error helper,
- JWT utility,
- PostgreSQL connection helper,
- validator helper.

Not allowed in `pkg/`:

- auth business logic,
- item business logic,
- transaction business logic,
- service-specific repository,
- service-specific usecase,
- domain-specific policy.

Rule:

```text
pkg/ is for technical utilities only.
```

---

## 9. Seed Structure

Path:

```text
seed/
```

Final structure:

```text
seed/
├── datasets/
└── scripts/
```

Rules:

- seed data is central,
- seed is separate from migration,
- seed scripts capture generated UUIDs using `INSERT ... RETURNING id`,
- seed scripts maintain logical-to-generated ID mappings,
- seed data must be logically equivalent for monolith and microservices.

---

## 10. Deployment Structure

Path:

```text
deployments/
```

Final structure:

```text
deployments/
├── helm/
│   ├── monolith/
│   ├── api-gateway/
│   ├── auth-service/
│   ├── item-service/
│   ├── transaction-service/
│   └── k6-runner/
│
└── k8s/
    ├── namespaces/
    ├── quotas/
    ├── hpa/
    ├── jobs/
    └── node-placement/
```

Rules:

- migration runs via Kubernetes Job,
- seed runs via Kubernetes Job,
- migration and seed must not run during benchmark execution,
- API Gateway has no migration job.

---

## 11. Infrastructure Structure

Path:

```text
infra/
```

Final structure:

```text
infra/
└── terraform/
    └── experiment/
        └── modules/
            ├── vpc/
            ├── eks/
            ├── node-groups/
            ├── rds/
            ├── s3/
            └── iam/
```

Terraform manages:

- VPC,
- EKS cluster,
- app node group,
- testing node group,
- RDS PostgreSQL 18,
- S3 result bucket,
- IAM roles,
- security groups.

---

## 12. k6 Structure

Path:

```text
k6/
```

Final structure:

```text
k6/
├── scripts/
├── runner/
└── scenarios/
    ├── monolith/
    └── microservices/
```

Rules:

- k6 scripts must be driven by environment variables,
- k6 must use RPS-based scenarios,
- monolith and microservices must use symmetrical scenarios,
- results must be uploaded to S3 before infrastructure is destroyed.

---

## 13. Scripts Structure

Path:

```text
scripts/
```

Final structure:

```text
scripts/
```

Scripts should be simple wrappers around documented commands.

---

## 14. Command Naming Rule

All deployable Go applications use:

```text
cmd/server/main.go
```

Applies to:

- monolith,
- api-gateway,
- auth-service,
- item-service,
- transaction-service.

Do not mix:

```text
cmd/api
cmd/server
cmd/app
```

Reason:

A consistent command layout makes the monorepo easier to navigate and easier for Codex to modify safely.

---

## 15. Migration Location Rule

Migration files are stored near the application or service that owns the database.

Monolith:

```text
monolith/migrations/
```

Microservices:

```text
microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/
```

Not used:

```text
root migrations/
```

Reason:

Migration ownership should follow database ownership.

---

## 16. Documentation Update Rule

When modifying any architectural or implementation decision, update the relevant docs.

Examples:

| Change | Docs to update |
|---|---|
| gRPC contract | `proto/`, `docs/api/grpc-contracts.md` |
| database schema | `docs/development/database-schema.md`, migrations |
| migration strategy | `docs/development/database-migration.md` |
| infrastructure | `docs/infrastructure/` |

---

## 17. Summary

Final repository design:

```text
Monorepo for development.
Separate runtime architectures for experiment.
Root docs for shared decisions.
Migration near database owner.
Seed central for benchmark fairness.
Proto as internal gRPC source of truth.
```

The structure is designed to support clean implementation, reproducible experiments, and clear thesis documentation.
