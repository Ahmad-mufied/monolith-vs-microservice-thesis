# AGENTS.md

## Purpose

This file is the single source of repository guidance for AI agents.

This repository is a thesis benchmark project comparing monolithic and
microservices architectures in a cloud-native environment.

## Project Context

The thesis compares:

1. Monolithic Architecture
2. Microservices Architecture

The research evaluates: performance, latency percentiles, throughput/RPS, error
rate, CPU/memory usage, HPA autoscaling behavior, and resource efficiency under
equivalent resource ceilings.

The benchmark application is a generic transactional API.

Domain terms:

- user, item, amount, available_amount, transaction, transaction_items

Avoid unless explicitly requested: product, cart, checkout, payment, stock,
quantity.

## Repository Model

Monorepo (`go.work`). Top-level: monolith/, microservices/, proto/, pkg/,
seed/, k6/, deployments/, infra/, scripts/, docs/, env/.

Runtime architecture differs:

- Monolith runs as one deployable process.
- Microservices run as four independently deployable services.

## Technology Stack

- Go 1.26.2, Echo (REST), gRPC (internal)
- PostgreSQL 18, pgx, Goose migrations
- Docker, Kubernetes (AWS EKS / Vultr VKE)
- Terraform, k6, Datadog
- AWS ECR (EKS), Docker Hub (Vultr)
- AWS S3 (benchmark results)

## Source of Truth

Before making changes, inspect the relevant source:

| Area | Files |
|---|---|
| Repository rules | `AGENTS.md` |
| External REST API | `openapi.yaml` |
| gRPC contracts | `proto/auth/v1/auth.proto`, `proto/item/v1/item.proto`, `proto/transaction/v1/transaction.proto` |
| Architecture | `docs/architecture/*.md` |
| Database | `docs/development/database-schema.md`, `docs/development/database-migration.md` |
| Validation | `docs/development/validation-strategy.md` |
| Benchmark | `docs/development/k6-workload-scenarios.md`, `docs/experiment/scaling-mode-strategy.md` |
| Infrastructure | `docs/infrastructure/benchmark-runbook-end-to-end.md`, `docs/infrastructure/vultr-vke-runbook.md` |

## Code Architecture

Layered Architecture with Clean/Hexagonal-inspired dependency direction:

- handler/controller -> usecase/service -> domain/model
- port/interface <- adapter/repository/client

Dependency rules:

- handler may call usecase or service client
- usecase may depend on interfaces/ports
- repository implements database ports
- gRPC client implements outbound service-client ports
- domain must not import HTTP, Echo, gRPC, PostgreSQL, Datadog
- business logic must not be in handlers
- SQL queries must not be in handlers; place in repository/adapter layer

## Command Structure

All deployable Go applications use `cmd/server/main.go`:

- monolith, api-gateway, auth-service, item-service, transaction-service

Do not use mixed command names (e.g., `cmd/api` for one and `cmd/server` for
another).

## Monolith Rules

Path: `monolith/`. Modules: auth, item, transaction.

- Runs as one process, exposes REST API, uses `mono_db`
- In-process function calls (no gRPC)
- May use foreign keys and SQL JOIN across all tables
- Create transaction: begin TX -> validate -> INSERT RETURNING id -> commit

## Microservices Rules

Path: `microservices/`. Services: api-gateway, auth-service, item-service,
transaction-service. Each independently deployable.

**API Gateway**: REST entry point, JWT validation, HTTP-to-gRPC mapping. Must not
contain business logic or access databases.

**Auth Service**: register, login, bcrypt, JWT issuing. Owns `auth_db` (users).

**Item Service**: CRUD items, ValidateTransactionItems. Owns `item_db` (items).

**Transaction Service**: create/get transactions. Owns `transaction_db`
(transactions, transaction_items). Calls Item Service via gRPC for validation.

Communication rules:

- External: REST HTTP through API Gateway
- Internal: gRPC only
- A service must not access another service's database
- transaction_db stores user_id and item_id as UUID references only (no FK to
  other databases)

Do not add caching, message queues, retries, circuit breakers, or saga patterns
unless explicitly requested.

## API Contract Rules

Source: `openapi.yaml`. Update it in the same change when API behavior changes.

- Public IDs: `type: string, format: uuid`
- Success responses: HTTP status + body, no `status: success` wrapper
- Error responses: `{ "error": { "code": "...", "message": "...", "details": ... } }`
- Pagination: `limit` (1-100, default 50), `offset` (0, default 0)
- Items use soft delete (`deleted_at`); users and transactions do not

Benchmark endpoints:

1. `POST /api/v1/auth/login` (public)
2. `POST /api/v1/transactions` (auth required)
3. `GET /api/v1/admin/transactions` (auth required)
4. `PUT /api/v1/items` (auth required, optional)

## gRPC Contract Rules

Proto files: `proto/{auth,item,transaction}/v1/*.proto`. UUID as string fields.
After editing: regenerate with `make proto`, update clients/servers, update
`docs/api/grpc-contracts.md`.

## Database Rules

PostgreSQL 18. All primary keys: `id UUID PRIMARY KEY DEFAULT uuidv7()`.

All create operations: `INSERT ... RETURNING id`. Application must not generate
UUIDs manually.

All main tables: `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `updated_at
TIMESTAMPTZ NOT NULL DEFAULT now()`.

Use INT for amount/available_amount. CHECK: `available_amount >= 0`, `amount > 0`.

### Database Layout

One PostgreSQL instance with separate databases: `mono_db`, `auth_db`, `item_db`,
`transaction_db`. API Gateway owns no database.

Monolith may use foreign keys across all tables. Microservices:
transaction_db may use FK within itself but not to auth_db or item_db.

### Transaction Tables

`transactions` (header) -> `transaction_items` (details). Composite PK:
`PRIMARY KEY (transaction_id, item_id)`. No snapshot columns.

## Migration Rules

Tool: Goose SQL migrations. Execution: Kubernetes Job (not init containers).

Migration must run once per deployment, not once per pod. Init container
migration can be triggered by every new pod during HPA scale-out.

Paths:

- `monolith/migrations/`
- `microservices/auth-service/migrations/`
- `microservices/item-service/migrations/`
- `microservices/transaction-service/migrations/`

API Gateway has no migration. Migration files contain schema changes only.
Do not put seed data in migration files.

## Seed Rules

Seed data is managed centrally under `seed/`. The seed runner is a Go CLI
application (`cmd/seed-runner/main.go`) with internal seed logic.

Seed is separate from migration. Migration = schema changes. Seed = data
insertion and reset.

Supported datasets: `smoke` (small), `benchmark` (full).

Seed scripts may use deterministic UUIDs for users and items so k6 can rely
on stable identities. Normal runtime inserts still use `uuidv7()` with
`INSERT ... RETURNING id`.

Monolith and microservices seed data must be logically equivalent (same
user/item/transaction counts, same distributions).

Before each mutating benchmark scenario: reset -> seed -> run benchmark.

## Infrastructure Rules

### Cloud Providers

Three providers are supported. Each has Terraform stacks under
`infra/terraform/`:

| Provider | Stacks | K8s Runtime | Image Registry |
|---|---|---|---|
| AWS EKS | `aws-shared`, `aws-parallel`, `aws-sequential` | EKS | ECR |
| Vultr | `vultr` (single stack with `execution_mode` toggle) | VKE | Docker Hub |

Provider-specific Makefile targets use prefixes: `eks-*`, `vultr-*`.
Generic targets dispatch through `scripts/operator-dispatch.sh`.

### Execution Modes

- **Parallel**: both architectures on separate clusters simultaneously
- **Sequential**: one architecture at a time on a single cluster

### Scaling Modes

- **fixed**: fixed replica count, `K6_PROFILE=steady`
- **hpa**: Horizontal Pod Autoscaler, `K6_PROFILE=hpa`

Switching fixed/HPA is a redeploy action, not a runner-only change.

### Node Placement

- Application pods run on `app-nodes`
- k6 runner runs on `testing-nodes` (tainted `workload=benchmark:NoSchedule`)
- Datadog runs as DaemonSet on monitored nodes

### Database Infrastructure

- AWS: Amazon RDS PostgreSQL 18
- Vultr: Dedicated compute VM with PostgreSQL 18

Database must be private. Do not allow `0.0.0.0/0` on port 5432.

### Resource Ceilings

Resource values are provider-specific. AWS EKS uses a fixed reference ceiling.
Vultr measures live node allocatable capacity and render manifests
dynamically.

See `docs/experiment/scaling-mode-strategy.md` for per-provider details.

Do not add KEDA, VPA, Cluster Autoscaler, or Karpenter unless explicitly
requested.

### Image Tag Management

One `IMAGE_TAG` for all deployables in a benchmark session. Pin with:

```bash
make pin-image-tag IMAGE_TAG=<tag>
make show-image-tag
```

Do not rebuild a different commit into the same tag during a measured run.

### Kubernetes Manifests

Manifests are provider-neutral under `deployments/k8s/cloud/` (Kustomize base
+ fixed/hpa overlays). Provider-specific renderers patch image references,
resource values, and metadata at deploy time.

## k6 Benchmark Rules

Scripts: `k6/scripts/`

Scenarios: `login.js`, `create-transaction.js`, `enriched-transactions.js`,
`concurrent-mixed-workload.js`, `mixed-workload.js`, `smoke.js`, `sync-items.js`.

Use RPS-based testing with constant-arrival-rate.

Default RPS levels: 1000, 2500, 5000, 7500, 10000.

k6 scripts must read environment variables (BASE_URL, TARGET_RPS, etc.) from
`k6/scripts/common/config.js`. Do not hardcode URLs, credentials, or tokens.

k6 must run on testing-nodes, not app-nodes. Monolith and microservices must
use symmetrical k6 scenarios.

## Benchmark Result Storage

Results upload to S3 before infrastructure is destroyed:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario}/{rps}rps/{attempt}/
```

Required files: `summary.json`, `raw.json.gz`, `stdout.log`, `metadata.json`,
`k6-options.json`, `thresholds.json`, `result-status.json`.

`metadata.json` is the source of truth for analysis automation and for
determining whether an attempt used HPA or fixed replicas.

Do not run terraform destroy before verifying benchmark data exists in S3.

## Observability Rules

Datadog for: service latency/throughput/error rate, CPU/memory, pod replicas,
HPA behavior, traces, RDS metrics.

k6 summary remains the primary source for external client-perceived performance.
Datadog is for root-cause analysis.

## Security Rules

Never commit secrets. Never hardcode: AWS keys, DB passwords, JWT secrets,
Datadog API keys, S3 credentials, private keys.

Do not expose databases publicly. Do not print secrets in logs.

## Fairness Rules

Do not optimize only one architecture unless the same optimization is applied
to the other or the difference is explicitly documented.

Avoid: caching, async queues, retries, circuit breakers, architecture-specific
connection pooling, different indexes, different endpoint behavior, different
payloads, different auth rules.

Both architectures must remain functionally equivalent from the external API
perspective.

## Development Workflow

Before editing: inspect relevant docs, proto files, existing patterns.

After editing:

- Go: `make fmt`, `make test`, ensure compilation
- Migrations: verify Goose markers, Up/Down, schema consistency
- Terraform: `terraform fmt`, `terraform validate`
- k6: ensure env-driven config, scenario symmetry, S3 upload capability

## Review Checklist

- Proto files match gRPC clients/servers?
- UUID fields handled as valid UUID strings?
- IDs generated by PostgreSQL with `uuidv7()`?
- Create queries use `INSERT ... RETURNING id`?
- Migrations separated from seed data?
- Monolith and microservices workloads equivalent?
- Database ownership boundaries preserved?
- API Gateway avoids business logic?
- Docs updated when behavior changes?

## Done Criteria

A task is done when: code compiles, tests pass, gofmt applied, gRPC contracts
updated if needed, migrations updated if schema changed, seed scripts updated
if dataset changed, docs updated if behavior changed, no secrets committed,
benchmark fairness preserved.
