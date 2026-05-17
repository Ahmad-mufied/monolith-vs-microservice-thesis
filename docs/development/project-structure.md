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
├── .env
├── .golangci.yml
├── Makefile
├── openapi.yaml
├── buf.yaml
├── buf.gen.yaml
│
├── .github/
├── buildspec/
├── env/
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
| `.gitignore` | Git ignore rules |
| `.dockerignore` | Docker ignore rules |
| `.env` | environment variables (not committed) |
| `.golangci.yml` | golangci-lint configuration |
| `Makefile` | build and task automation |
| `openapi.yaml` | external REST API contract (source of truth) |
| `buf.yaml` | buf module configuration for proto |
| `buf.gen.yaml` | buf code generation configuration |
| `.github/` | GitHub Actions CI workflows |
| `buildspec/` | AWS CodeBuild specifications |
| `env/` | environment configuration files |
| `docs/` | project documentation |
| `monolith/` | monolithic implementation |
| `microservices/` | microservices implementation |
| `proto/` | gRPC contracts and generated code |
| `pkg/` | shared technical utilities |
| `seed/` | benchmark seed tool |
| `deployments/` | Docker Compose and Kubernetes manifests |
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
│   └── comparison.md
│
├── api/
│   ├── openapi-notes.md
│   └── grpc-contracts.md
│
├── deployment/
│   └── codebuild-ecr.md
│
├── development/
│   ├── project-structure.md
│   ├── database-schema.md
│   ├── database-migration.md
│   ├── validation-strategy.md
│   ├── local-deployment.md
│   ├── run-monolith-local.md
│   └── run-microservices-local.md
│
└── infrastructure/
    ├── rds-postgres.md
    ├── deployment-strategy.md
    └── secret-management.md
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
├── Dockerfile
│
├── cmd/
│   └── server/
│       └── main.go
│
├── internal/
│   ├── auth/
│   │   ├── dto.go
│   │   ├── handler.go
│   │   ├── handler_test.go
│   │   ├── model.go
│   │   ├── password.go
│   │   ├── repository.go
│   │   ├── service.go
│   │   └── service_test.go
│   │
│   ├── health/
│   │   ├── handler.go
│   │   └── handler_test.go
│   │
│   ├── item/
│   │   ├── dto.go
│   │   ├── handler.go
│   │   ├── handler_test.go
│   │   ├── model.go
│   │   ├── repository.go
│   │   ├── service.go
│   │   └── service_test.go
│   │
│   ├── transaction/
│   │   ├── dto.go
│   │   ├── handler.go
│   │   ├── handler_test.go
│   │   ├── model.go
│   │   ├── repository.go
│   │   ├── service.go
│   │   └── service_test.go
│   │
│   └── shared/
│       ├── apperror/
│       ├── config/
│       ├── db/
│       ├── httputil/
│       ├── jwtutil/
│       ├── middleware/
│       ├── pagination/
│       └── validation/
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
├── Dockerfile
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
    ├── httputil/
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
├── Dockerfile
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
├── go.sum
├── Dockerfile
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
├── go.sum
├── Dockerfile
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
├── transaction/
│   └── v1/
│       └── transaction.proto
│
└── gen/
    ├── go.mod
    ├── go.sum
    ├── auth/v1/
    │   ├── auth.pb.go
    │   └── auth_grpc.pb.go
    ├── item/v1/
    │   ├── item.pb.go
    │   └── item_grpc.pb.go
    └── transaction/v1/
        ├── transaction.pb.go
        └── transaction_grpc.pb.go
```

Rules:

- proto files are the source of truth for internal gRPC contracts,
- UUID values are represented as strings in proto,
- do not manually edit generated code,
- `gen/` contains generated Go gRPC code from `buf generate`,
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
├── go.mod
├── go.sum
├── config/
│   └── config.go
├── logger/
│   └── logger.go
├── observability/          # not yet implemented
├── response/               # not yet implemented
├── errors/
│   ├── errors.go
│   └── errors_test.go
├── jwt/
│   ├── jwt.go
│   └── jwt_test.go
├── postgres/
│   └── postgres.go
└── validator/
    └── validator.go
```

Allowed in `pkg/`:

- config loader,
- logger helper,
- observability helper (Datadog integration),
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
├── README.md
├── go.mod
├── go.sum
├── Dockerfile
│
├── cmd/
│   └── seed-runner/
│       └── main.go
│
└── internal/
    └── seed/
        ├── monolith.go
        └── microservices.go
```

Rules:

- seed is implemented as a Go application,
- seed is separate from migration,
- seed runs as a Kubernetes Job via Docker container,
- seed runner details are documented in `seed/README.md`,
- seed data must be retry-safe for Kubernetes Job reruns,
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
├── compose/
│   ├── docker-compose.db.yml
│   ├── docker-compose.monolith.yml
│   ├── docker-compose.microservices.yml
│   └── initdb/
│       └── 001-create-databases.sql
│
└── k8s/
    ├── local/
    │   ├── postgres.yaml
    │   └── db-bootstrap-job.yaml
    │
    ├── namespaces/
    │   └── local.yaml
    │
    ├── monolith/
    │   ├── monolith.yaml
    │   ├── ingress.yaml
    │   ├── migration-job.yaml
    │   ├── prepare-monolith-enrichment-benchmark-data-job.yaml
    │   ├── prepare-monolith-enrichment-smoke-data-job.yaml
    │   ├── resource-management.yaml
    │   ├── reset-monolith-data-job.yaml
    │   ├── seed-monolith-benchmark-data-job.yaml
    │   └── seed-monolith-smoke-data-job.yaml
    │
    └── microservices/
        ├── api-gateway.yaml
        ├── api-gateway-ingress.yaml
        ├── auth-service.yaml
        ├── auth-migration-job.yaml
        ├── item-service.yaml
        ├── item-migration-job.yaml
        ├── prepare-microservices-enrichment-benchmark-data-job.yaml
        ├── prepare-microservices-enrichment-smoke-data-job.yaml
        ├── transaction-service.yaml
        ├── transaction-migration-job.yaml
        ├── resource-management.yaml
        ├── reset-microservices-data-job.yaml
        ├── seed-microservices-benchmark-data-job.yaml
        └── seed-microservices-smoke-data-job.yaml
```

Rules:

- `compose/` is used for local development,
- `k8s/local/` is used for local Kubernetes development,
- migration runs via Kubernetes Job,
- seed runs via Kubernetes Job,
- migration and seed must not run during benchmark execution,
- API Gateway has no migration job,
- resource management includes ResourceQuota and HPA definitions.

---

## 11. Infrastructure Structure

Path:

```text
infra/
```

Status: **Not yet implemented.**

Planned structure:

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

Terraform will manage:

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

Status: **Not yet implemented.**

Planned structure:

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

Current structure:

```text
scripts/
├── create-local-postgres-secrets.sh
├── create-local-secrets.sh
├── create-local-secrets-microservices.sh
├── env-init-base.sh
├── env-init-monolith.sh
├── env-init-microservices.sh
└── go-mod-tidy-all.sh
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
