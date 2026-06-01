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
│   ├── helm/
│   │   └── datadog/
│   └── k8s/
│       ├── benchmark/
│       ├── eks/
│       └── local/
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
| `buildspec/` | legacy CodeBuild specifications (not active path) |
| `env/` | environment configuration files |
| `docs/` | project documentation |
| `monolith/` | monolithic implementation |
| `microservices/` | microservices implementation |
| `proto/` | gRPC contracts and generated code |
| `pkg/` | shared technical utilities |
| `seed/` | benchmark seed tool |
| `deployments/` | Docker Compose and Kubernetes manifests |
| `infra/` | Terraform infrastructure |
| `k6/` | benchmark scripts, runner image, and Kubernetes state collection helper |
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
│   ├── k6-workload-scenarios.md
│   ├── validation-strategy.md
│   ├── local-deployment.md
│   ├── run-monolith-local.md
│   └── run-microservices-local.md
│
├── diagrams/
│   ├── README.md
│   ├── cloud-architecture.md
│   ├── sequential-parallel-topology.md
│   ├── architecture-comparison.md
│   ├── benchmark-lifecycle.md
│   ├── login-sequence.md
│   ├── create-transaction-sequence.md
│   └── enriched-transactions-sequence.md
│
├── experiment/
│   ├── application-ceiling-methodology.md
│   ├── resource-configuration.md
│   └── scaling-mode-strategy.md
│
├── infrastructure/
│   ├── cloud-architecture.md
│   ├── eks-cluster-design.md
│   ├── terraform-runbook.md
│   ├── benchmark-execution-lifecycle.md
│   ├── benchmark-runbook-end-to-end.md
│   ├── parallel-benchmark-runbook.md
│   ├── sequential-benchmark-runbook.md
│   ├── rds-postgres.md
│   ├── datadog.md
│   ├── datadog-resource-overhead.md
│   ├── secret-management.md
│   ├── deployment-strategy.md
│   ├── eks-debug-command-reference.md
│   └── aws-budget-shutdown.md
│
├── plan/
│   └── sequential-parallel-benchmark-topology-*.md
│
└── research-questions/
    ├── README.md
    ├── rq1-performance-analysis.md
    └── rq2-resource-efficiency-analysis.md
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
- Transaction Service calls Item Service through gRPC for validation-only item checks,
- API Gateway calls Auth Service and Item Service through gRPC for enrichment,
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
├── errors/
│   ├── errors.go
│   └── errors_test.go
├── jwt/
│   ├── jwt.go
│   └── jwt_test.go
├── numconv/
│   ├── int32.go
│   └── int32_test.go
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
    ├── benchmark/
    │   ├── k6-benchmark-monolith-job.yaml
    │   ├── k6-benchmark-microservices-job.yaml
    │   ├── k6-runner-rbac.yaml
    │   ├── k6-runner-secret.example.yaml
    │   ├── namespace.yaml
    │   ├── monolith/
    │   │   └── db-bootstrap-job.yaml
    │   └── microservices/
    │       └── db-bootstrap-job.yaml
    │
    ├── local/
    │   ├── shared/
    │   │   ├── postgres.yaml
    │   │   └── db-bootstrap-job.yaml
    │   │
    │   ├── monolith/
    │   │   ├── monolith.yaml
    │   │   ├── ingress.yaml
    │   │   ├── migration-job.yaml
    │   │   ├── prepare-monolith-enrichment-benchmark-data-job.yaml
    │   │   ├── prepare-monolith-enrichment-smoke-data-job.yaml
    │   │   ├── resource-management-fixed.yaml
    │   │   ├── resource-management-hpa.yaml
    │   │   ├── reset-monolith-data-job.yaml
    │   │   ├── seed-monolith-benchmark-data-job.yaml
    │   │   └── seed-monolith-smoke-data-job.yaml
    │   │
    │   └── microservices/
    │       ├── api-gateway.yaml
    │       ├── api-gateway-ingress.yaml
    │       ├── auth-service.yaml
    │       ├── auth-migration-job.yaml
    │       ├── item-service.yaml
    │       ├── item-migration-job.yaml
    │       ├── prepare-microservices-enrichment-benchmark-data-job.yaml
    │       ├── prepare-microservices-enrichment-smoke-data-job.yaml
    │       ├── resource-management-fixed.yaml
    │       ├── resource-management-hpa.yaml
    │       ├── reset-microservices-data-job.yaml
    │       ├── seed-microservices-benchmark-data-job.yaml
    │       ├── seed-microservices-smoke-data-job.yaml
    │       ├── transaction-service.yaml
    │       └── transaction-migration-job.yaml
    │
    ├── namespaces/
    │   └── local.yaml
    │
    └── eks/
        ├── monolith/
        │   ├── base/
        │   └── overlays/
        │       ├── fixed/
        │       └── hpa/
        └── microservices/
            ├── base/
            └── overlays/
                ├── fixed/
                └── hpa/
```

Rules:

- `compose/` is used for local development,
- `k8s/local/shared/` contains local-only shared infrastructure manifests,
- `k8s/local/monolith/` contains local Minikube monolith workload manifests,
- `k8s/local/microservices/` contains local Minikube microservices workload manifests,
- `k8s/eks/` remains the EKS-specific source of truth,
- migration runs via Kubernetes Job,
- seed runs via Kubernetes Job,
- migration and seed must not run during benchmark execution,
- API Gateway has no migration job,
- EKS app deployment mode is selected via `deployments/k8s/eks/*/overlays/fixed` and `overlays/hpa`,
- the legacy `resource-management-*.yaml` files remain as generic namespace/HPA references outside the EKS overlay flow.

---

## 11. Infrastructure Structure

Path:

```text
infra/
```

Current structure:

```text
infra/
└── terraform/
    ├── shared/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── experiment/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── experiment-sequential/
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── terraform.tfvars.example
    │
    └── modules/
        ├── aws-budget/
        └── benchmark-cluster/
```

Terraform manages:

- shared VPC, subnets, route tables, NAT, and k6 IAM role in `shared/`,
- two-cluster parallel benchmark topology in `experiment/`,
- one-cluster sequential benchmark topology in `experiment-sequential/`,
- EKS clusters, app node groups, testing node groups, RDS PostgreSQL 18, and
  security groups through `modules/benchmark-cluster`,
- budget guardrail resources through `modules/aws-budget`.

Rules:

- S3 result buckets and ECR repositories are persistent resources created by
  operator commands, not destroyed by experiment Terraform teardown.
- `experiment/` and `experiment-sequential/` both read outputs from
  `shared/terraform.tfstate`.
- Use `scripts/terraform-experiment.sh` for parallel mode and
  `scripts/terraform-sequential.sh` for sequential mode so required variables
  such as `TF_VAR_db_password` are injected consistently.
- Do not keep both experiment stacks active when the AWS account is constrained
  to a 24 vCPU quota.

---

## 12. k6 Structure

Path:

```text
k6/
```

Current structure:

```text
k6/
├── scripts/
│   ├── login.js
│   ├── create-transaction.js
│   ├── enriched-transactions.js
│   └── mixed-workload.js
│
├── runner/
│   ├── Dockerfile
│   └── run-k6.sh
│
└── assets/
```

Rules:

- k6 scripts must be driven by environment variables,
- k6 must use RPS-based scenarios,
- monolith and microservices must use symmetrical scenarios,
- k6 runner jobs must run on `testing-nodes`, not `app-nodes`,
- results must be uploaded to S3 before infrastructure is destroyed.
- `run-k6.sh` writes metadata that identifies `execution_mode`,
  `architecture_order`, `terraform_stack`, and `cluster_name` for parallel and
  sequential analysis.

---

## 13. Scripts Structure

Path:

```text
scripts/
```

Current structure:

```text
scripts/
├── benchmark-preflight-check.sh
├── create-datadog-secret.sh
├── create-eks-secrets-microservices.sh
├── create-eks-secrets-monolith.sh
├── create-eks-secrets-sequential.sh
├── create-local-postgres-secrets.sh
├── create-local-secrets.sh
├── create-local-secrets-microservices.sh
├── deploy-all-eks-clusters.sh
├── deploy-monolith-cluster.sh
├── deploy-msa-cluster.sh
├── deploy-sequential-architecture.sh
├── eks-update-manifests.sh
├── env-init-base.sh
├── env-init-datadog-minikube.sh
├── env-init-eks.sh
├── env-init-monolith.sh
├── env-init-microservices.sh
├── go-mod-tidy-all.sh
├── install-metrics-server.sh
├── prepare-enrichment-benchmark.sh
├── render-eks-manifests.sh
├── render-eks-tfvars.sh
├── run-benchmark-parallel.sh
├── run-benchmark-sequential.sh
├── run-benchmark-suite.sh
├── run-benchmark-suite-sequential.sh
├── setup-eks-contexts.sh
├── setup-eks-contexts-sequential.sh
├── terraform-experiment.sh
├── terraform-recovery-check.sh
├── terraform-recovery-fix-tainted-nodegroups.sh
├── terraform-sequential.sh
├── terraform-sequential-recovery-check.sh
└── validate-eks-assets.sh
```

Rules:

- Scripts should be simple wrappers around documented commands.
- Parallel mode scripts must keep `monolith` and `msa` contexts isolated.
- Sequential mode scripts must use the `benchmark` context and scale the
  inactive architecture to zero before running migration, seed, or k6.
- Benchmark scripts must fail fast on missing AWS, EKS, S3, kubeconfig, or
  required environment state rather than silently continuing.
- Terraform scripts must use explicit stack directories so parallel and
  sequential state do not drift into each other.

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
