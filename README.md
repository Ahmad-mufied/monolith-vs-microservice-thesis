# Monolith vs Microservices Thesis Benchmark

This repository contains an undergraduate thesis benchmark project that compares
monolithic and microservices architectures in a cloud-native environment.

The benchmark application is intentionally generic. It models users, items,
amounts, available amounts, transactions, and transaction items without tying
the workload to a specific business domain.

The research evaluates:

- latency percentiles
- throughput / RPS
- error rate
- CPU usage
- memory usage
- Kubernetes HPA behavior
- resource efficiency under equivalent resource ceilings

## Architecture

The repository implements the same external REST API in two runtime
architectures.

```text
Monolith
Client / k6
  -> monolith application
  -> mono_db

Microservices
Client / k6
  -> api-gateway
  -> auth-service / item-service / transaction-service
  -> auth_db / item_db / transaction_db
```

The monolith runs as one deployable Go application with in-process module calls.
The microservices variant runs as four independently deployable Go services.
External communication uses REST HTTP, while internal microservices
communication uses gRPC.

For the final AWS benchmark, both architectures run in parallel on two isolated
EKS clusters:

```text
skripsi-monolith  -> mono namespace, benchmark namespace, RDS mono_db
skripsi-msa       -> msa namespace, benchmark namespace, RDS auth_db/item_db/transaction_db
```

Both clusters use the same measured application resource ceiling:

- CPU: `15800m`
- memory: `27648Mi`

This ceiling is not set equal to raw physical node capacity. It is derived
from allocatable application-node capacity and then rounded down after
considering always-on cluster overhead. See
[`docs/experiment/application-ceiling-methodology.md`](docs/experiment/application-ceiling-methodology.md)
for the full methodology and the final fixed/HPA split.

Application pods run on `app-nodes`; k6 runner jobs run on `testing-nodes`.

Architecture and benchmark diagrams are available in
[`docs/diagrams/`](docs/diagrams/):

- [`cloud-architecture.md`](docs/diagrams/cloud-architecture.md)
- [`architecture-comparison.md`](docs/diagrams/architecture-comparison.md)
- [`benchmark-lifecycle.md`](docs/diagrams/benchmark-lifecycle.md)
- [`login-sequence.md`](docs/diagrams/login-sequence.md)
- [`create-transaction-sequence.md`](docs/diagrams/create-transaction-sequence.md)
- [`enriched-transactions-sequence.md`](docs/diagrams/enriched-transactions-sequence.md)

## Main Stack

- Go `1.26.2`
- Echo for external REST APIs
- gRPC for internal microservices communication
- PostgreSQL 18
- pgx
- Goose SQL migrations
- Docker
- Kubernetes / Amazon EKS
- Terraform
- k6
- Datadog

## Repository Layout

```text
.
├── AGENTS.md                 # repository rules for Codex / agent workflows
├── openapi.yaml              # external REST API source of truth
├── go.work                   # Go workspace
├── buf.yaml                  # protobuf module configuration
├── buf.gen.yaml              # protobuf Go/gRPC generation configuration
├── monolith/                 # monolith application
├── microservices/            # api-gateway, auth, item, transaction services
├── proto/                    # gRPC contracts and generated Go code
├── pkg/                      # shared technical utilities
├── seed/                     # benchmark seed/reset tooling
├── deployments/              # Docker Compose plus local, benchmark, EKS, and Helm manifests
├── infra/terraform/          # AWS shared and experiment Terraform stacks
├── k6/                       # k6 scripts, runner image, benchmark data
├── env/                      # generated local/EKS env files
├── buildspec/                # optional image build/push buildspec
├── scripts/                  # operator and automation scripts
└── docs/                     # architecture, development, infrastructure, experiment docs
```

Kubernetes manifests are separated by environment purpose:

- `deployments/k8s/local/` for Minikube and local Kubernetes workflows
- `deployments/k8s/benchmark/` for benchmark-only jobs and bootstrap assets
- `deployments/k8s/eks/` for EKS deployment source-of-truth manifests

## Source of Truth

This repository has several explicit source-of-truth files:

| Area | Source |
|---|---|
| Repository rules | [`AGENTS.md`](AGENTS.md) |
| External REST API | [`openapi.yaml`](openapi.yaml) |
| gRPC contracts | `proto/auth/v1/auth.proto`, `proto/item/v1/item.proto`, `proto/transaction/v1/transaction.proto` |
| Architecture | `docs/architecture/*.md` |
| Database schema and migration policy | `docs/development/database-schema.md`, `docs/development/database-migration.md` |
| EKS and Terraform operations | `docs/infrastructure/cloud-architecture.md`, `docs/infrastructure/terraform-runbook.md` |
| Benchmark lifecycle | `docs/infrastructure/benchmark-execution-lifecycle.md`, `docs/infrastructure/benchmark-runbook-end-to-end.md` |

When API behavior changes, update `openapi.yaml` in the same change. When gRPC
behavior changes, update proto files, regenerate Go code, and update
[`docs/api/grpc-contracts.md`](docs/api/grpc-contracts.md) when needed.

## API Contract

The external REST API source of truth is [`openapi.yaml`](openapi.yaml).

Main benchmark endpoints:

| Scenario | Endpoint | Purpose |
|---|---|---|
| Login | `POST /api/v1/auth/login` | CPU-bound bcrypt + JWT workload |
| Create transaction | `POST /api/v1/transactions` | write-heavy transaction workload |
| Enriched transactions | `GET /api/v1/admin/transactions` | read-heavy enrichment workload |

Optional benchmark endpoint:

| Scenario | Endpoint | Purpose |
|---|---|---|
| Sync active items | `PUT /api/v1/items` | bulk active item synchronization |

Important API rules:

- Public IDs use `type: string` and `format: uuid`.
- Item availability is exposed as `available_amount`.
- `POST /api/v1/transactions` validates `amount <= available_amount`.
- Creating a transaction does not deduct `available_amount`; it is a benchmark validation boundary.
- Success responses follow the schemas in `openapi.yaml` and do not use a top-level `status: success` wrapper.
- Error responses use a structured `error` object with `code`, `message`, and optional `details`.

## gRPC Contracts

Microservices communicate internally through gRPC. Proto files live under
[`proto/`](proto/), and generated Go files live under `proto/gen/`.

```text
proto/auth/v1/auth.proto
proto/item/v1/item.proto
proto/transaction/v1/transaction.proto
```

Regenerate generated code after editing proto contracts:

```bash
make proto
```

The `go.work` workspace includes `proto/gen` as a separate Go module so service
modules can consume generated contracts consistently.

## Environment Files

Environment files live under [`env/`](env/) and are generated by helper
commands. They are ignored by Git because they may contain local passwords,
tokens, or operator-specific values.

```bash
make env-init-base
make env-init-monolith
make env-init-microservices
make env-init-eks
```

Useful references:

- [`env/README.md`](env/README.md)
- [`docs/infrastructure/secret-management.md`](docs/infrastructure/secret-management.md)

## Local Development

Initialize local environment files:

```bash
make env-init-base
make env-init-monolith
make env-init-microservices
```

Run common checks:

```bash
make fmt
make test
```

Run the monolith locally:

```bash
make run-monolith-local
```

Run microservices locally:

```bash
make run-auth-service-local
make run-item-service-local
make run-transaction-service-local
make run-api-gateway-local
```

For detailed local workflows, see:

- [`docs/development/run-monolith-local.md`](docs/development/run-monolith-local.md)
- [`docs/development/run-microservices-local.md`](docs/development/run-microservices-local.md)
- [`docs/development/local-deployment.md`](docs/development/local-deployment.md)

## Docker Compose Workflow

Docker Compose manifests live under [`deployments/compose/`](deployments/compose/).
They are useful for local database and application wiring before moving to
Kubernetes.

```bash
make compose-db-up
make compose-monolith-up
make compose-microservices-up
make compose-down
```

The compose-specific environment files use service DNS names such as
`postgres`, `auth-service`, `item-service`, and `transaction-service`.

## Minikube Workflow

Minikube is used for local Kubernetes validation before EKS-scale benchmark
runs.

```bash
make minikube-start
make minikube-bootstrap-monolith-smoke
make minikube-deploy-monolith
```

For microservices:

```bash
make minikube-start
make minikube-bootstrap-microservices-smoke
make minikube-deploy-microservices
```

Minikube is suitable for functional validation and smoke testing. High-RPS
benchmark conclusions should come from EKS plus S3 artifacts and Datadog
telemetry.

## AWS EKS Benchmark Workflow

The AWS benchmark uses two resource lifecycle groups:

| Resource group | Managed by | Lifecycle |
|---|---|---|
| S3 result bucket, ECR repositories | AWS CLI / Makefile | persistent |
| VPC, IAM role, EKS clusters, RDS instances | Terraform | experiment session |

High-level flow:

```bash
# one-time persistent resources
make aws-create-s3
make aws-create-ecr

# image build and push
IMAGE_TAG=$(git rev-parse --short HEAD)
make ecr-push-all IMAGE_TAG=$IMAGE_TAG

# optional manifest preflight
make eks-render-manifests IMAGE_TAG=$IMAGE_TAG

# Terraform env and auth
make env-init-eks
make eks-render-tfvars
make terraform-auth-check

# infrastructure
make eks-shared-apply
make eks-apply
make eks-setup-contexts

# secrets and deploy
make create-eks-secrets-monolith
make create-eks-secrets-microservices
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG

# benchmark
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=skripsi-benchmark-results
```

Do not destroy infrastructure until all benchmark artifacts are verified in S3.

```bash
make eks-destroy-confirmed
make eks-shared-destroy
```

Detailed EKS documentation:

- [`docs/infrastructure/cloud-architecture.md`](docs/infrastructure/cloud-architecture.md)
- [`docs/infrastructure/eks-cluster-design.md`](docs/infrastructure/eks-cluster-design.md)
- [`docs/infrastructure/terraform-runbook.md`](docs/infrastructure/terraform-runbook.md)
- [`docs/infrastructure/benchmark-runbook-end-to-end.md`](docs/infrastructure/benchmark-runbook-end-to-end.md)
- [`docs/infrastructure/parallel-benchmark-runbook.md`](docs/infrastructure/parallel-benchmark-runbook.md)

## Images and ECR

The active EKS workflow builds images locally and pushes them to ECR before
Terraform provisioning and Kubernetes deploy.

Images:

- `skripsi/monolith`
- `skripsi/api-gateway`
- `skripsi/auth-service`
- `skripsi/item-service`
- `skripsi/transaction-service`
- `skripsi/seed-runner`
- `skripsi/k6-runner`

Primary command:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
make ecr-push-all IMAGE_TAG=$IMAGE_TAG
```

The image tag is written into rendered EKS manifests and benchmark metadata for
reproducibility. Repository manifests stay unchanged; EKS deploy and benchmark
commands render runtime-specific manifests into temporary directories before
validation and apply. `latest` should not be used for measured runs.

The repository also contains [`buildspec/buildspec.images.yml`](buildspec/buildspec.images.yml)
for image build/push automation experiments. The documented single-operator
benchmark runbook uses `make ecr-push-all` as the primary path.

## Benchmark Scenarios

k6 scripts live under [`k6/scripts/`](k6/scripts/).

Main scenarios:

- `login.js`
- `create-transaction.js`
- `enriched-transactions.js`
- `mixed-workload.js`

Additional validation and optional scripts:

- `smoke.js`
- `sync-items.js`

Default target RPS levels:

- `1000`
- `2500`
- `5000`
- `7500`
- `10000`

`10000` RPS is a stress-level target, not a guaranteed sustainable target.

Each benchmark attempt uploads results to:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Required files include:

- `summary.json`
- `raw.json.gz`
- `stdout.log`
- `metadata.json`
- `result-status.json`
- `k6-options.json`
- `thresholds.json`
- `datadog-time-window.json` when Datadog is enabled

`metadata.json` is the source of truth for analysis automation and for
determining whether an attempt used fixed replicas or HPA.

`thresholds.json` is the primary source for deciding whether a run is `PASS` or
`OVERLOAD`, while `result-status.json` records k6 exit state, S3 upload state,
and artifact-generation status for `INVALID` troubleshooting.

For k6 script behavior and runner details, see [`k6/README.md`](k6/README.md).

## Database and Migrations

PostgreSQL 18 is used for both architectures.

Database ownership:

| Architecture | Database |
|---|---|
| Monolith | `mono_db` |
| Auth Service | `auth_db` |
| Item Service | `item_db` |
| Transaction Service | `transaction_db` |

Migration paths:

```text
monolith/migrations/
microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/
```

Migration rules:

- Use Goose SQL migrations.
- Run migrations via Kubernetes Jobs.
- Do not use init containers for migrations.
- Keep benchmark seed data outside migration files.
- Runtime inserts use PostgreSQL-generated UUIDv7 with `INSERT ... RETURNING id`.

## Seed and Data Lifecycle

Seed/reset logic is centralized in [`seed/`](seed/), separate from schema
migrations.

Supported dataset profiles:

- `smoke`
- `benchmark`

Host-side commands:

```bash
make reset-monolith-data
make seed-monolith-data DATASET=smoke
make seed-monolith-data DATASET=benchmark
make prepare-monolith-enrichment-data DATASET=benchmark

make reset-microservices-data
make seed-microservices-data DATASET=smoke
make seed-microservices-data DATASET=benchmark
make prepare-microservices-enrichment-data DATASET=benchmark
```

Benchmark data lifecycle:

```text
login:
  reset -> seed -> k6

create-transaction:
  reset -> seed -> k6

enriched-transactions:
  reset -> seed -> prepare enrichment data -> k6
```

Base seed inserts users and items. Transaction rows for enriched-read fixtures
are created only by the explicit enrichment preparation step.

For details, see [`seed/README.md`](seed/README.md).

## Observability

Datadog is used to explain internal behavior behind k6 results:

- service latency
- service throughput
- service error rate
- CPU and memory usage
- pod replica count
- HPA behavior
- traces
- RDS metrics when available

k6 summary output remains the primary source for external client-perceived
performance. Datadog is used for root-cause analysis and architecture-level
interpretation.

For Datadog setup and limitations, see:

- [`docs/infrastructure/datadog.md`](docs/infrastructure/datadog.md)
- [`docs/infrastructure/datadog-resource-overhead.md`](docs/infrastructure/datadog-resource-overhead.md)

## Scaling Modes

The benchmark supports two scaling modes:

| Goal | `SCALING_MODE` | `K6_PROFILE` |
|---|---|---|
| Clean comparison | `fixed` | `steady` |
| HPA behavior analysis | `hpa` | `hpa` |

Switching between fixed and HPA is a redeploy action. Changing only
`SCALING_MODE` on the benchmark runner does not change live application
manifests.

See [`docs/experiment/scaling-mode-strategy.md`](docs/experiment/scaling-mode-strategy.md).

## Code Quality

Common development checks:

```bash
make fmt
make test
make lint
make gosec
```

The GitHub Actions workflow in
[`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml) runs Go
fix checks, linting, tests, and gosec on pull requests that change Go files.

## Fairness Rules

This project is a controlled architecture comparison. Avoid introducing changes
that make one architecture unfairly advantaged.

Do not add these patterns unless explicitly required and applied fairly:

- caching
- asynchronous queues
- retries or circuit breakers
- saga / compensation mechanisms
- different database indexes for only one architecture
- different request or response semantics
- different authentication behavior
- different benchmark payloads

Both architectures must remain functionally equivalent from the external API
perspective.

## Documentation Map

Architecture:

- [`docs/architecture/overview.md`](docs/architecture/overview.md)
- [`docs/architecture/monolith.md`](docs/architecture/monolith.md)
- [`docs/architecture/microservices.md`](docs/architecture/microservices.md)
- [`docs/architecture/comparison.md`](docs/architecture/comparison.md)
- [`docs/diagrams/README.md`](docs/diagrams/README.md)

API:

- [`openapi.yaml`](openapi.yaml)
- [`docs/api/openapi-notes.md`](docs/api/openapi-notes.md)
- [`docs/api/grpc-contracts.md`](docs/api/grpc-contracts.md)

Development:

- [`docs/development/project-structure.md`](docs/development/project-structure.md)
- [`docs/development/local-deployment.md`](docs/development/local-deployment.md)
- [`docs/development/run-monolith-local.md`](docs/development/run-monolith-local.md)
- [`docs/development/run-microservices-local.md`](docs/development/run-microservices-local.md)
- [`docs/development/database-schema.md`](docs/development/database-schema.md)
- [`docs/development/database-migration.md`](docs/development/database-migration.md)
- [`docs/development/validation-strategy.md`](docs/development/validation-strategy.md)
- [`docs/development/k6-workload-scenarios.md`](docs/development/k6-workload-scenarios.md)

Deployment:

- [`docs/deployment/codebuild-ecr.md`](docs/deployment/codebuild-ecr.md)

Infrastructure:

- [`docs/infrastructure/cloud-architecture.md`](docs/infrastructure/cloud-architecture.md)
- [`docs/infrastructure/eks-cluster-design.md`](docs/infrastructure/eks-cluster-design.md)
- [`docs/infrastructure/terraform-runbook.md`](docs/infrastructure/terraform-runbook.md)
- [`docs/infrastructure/benchmark-execution-lifecycle.md`](docs/infrastructure/benchmark-execution-lifecycle.md)
- [`docs/infrastructure/parallel-benchmark-runbook.md`](docs/infrastructure/parallel-benchmark-runbook.md)
- [`docs/infrastructure/rds-postgres.md`](docs/infrastructure/rds-postgres.md)
- [`docs/infrastructure/secret-management.md`](docs/infrastructure/secret-management.md)
- [`docs/infrastructure/deployment-strategy.md`](docs/infrastructure/deployment-strategy.md)

Research questions:

- [`docs/research-questions/README.md`](docs/research-questions/README.md)
- [`docs/research-questions/rq1-performance-analysis.md`](docs/research-questions/rq1-performance-analysis.md)
- [`docs/research-questions/rq2-resource-efficiency-analysis.md`](docs/research-questions/rq2-resource-efficiency-analysis.md)

## Safety Notes

- Never commit AWS credentials, database passwords, JWT secrets, Datadog API keys, S3 credentials, or private keys.
- Keep RDS private and non-public.
- Do not allow `0.0.0.0/0` on PostgreSQL port `5432`.
- Verify S3 benchmark artifacts before destroying EKS/RDS.
- Treat local Terraform state and `terraform.tfvars` as operator-local artifacts, not source documentation.
