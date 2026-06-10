# Monolith vs Microservices Thesis Benchmark

Undergraduate thesis benchmark comparing monolithic and microservices
architectures in a cloud-native Kubernetes environment. The benchmark
application is a generic transactional API (users, items, transactions) — not
tied to a specific business domain.

The thesis evaluates two research questions:

- **RQ1 — Performance**: latency, throughput achievement against target RPS,
  error rate between architectures under equivalent workloads.
- **RQ2 — Resource Efficiency**: CPU and memory usage comparison, HPA
  autoscaling behavior.

Primary workload: `concurrent-mixed-workload` (20% login, 40%
create-transaction, 40% enriched-transactions running concurrently).

Details: [`docs/research-questions/`](docs/research-questions/)

## Architecture

Both architectures expose the same external REST API and run on Kubernetes.
The difference is internal: monolith uses in-process function calls, while
microservices use gRPC across independently deployable services.

### Monolith

Single Go process. Three internal modules share one database via in-process
calls and SQL JOINs.

```text
  Kubernetes Cluster
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  ┌──────────────┐       REST HTTP :8080                  │
  │  │   k6 Job     │─ ─ ─ ─ ─ ─ ─ ─ ┐                      │
  │  │ (testing-    │                  │                      │
  │  │   nodes)     │                  ▼                      │
  │  └──────────────┘    ┌────────────────────────────┐      │
  │                      │      Monolith Pod          │      │
  │                      │      (app-nodes)           │      │
  │                      │                            │      │
  │                      │  ┌──────────────────────┐  │      │
  │                      │  │   Echo HTTP :8080    │  │      │
  │                      │  └──────────┬───────────┘  │      │
  │                      │             │ handler      │      │
  │                      │             ▼              │      │
  │                      │  ┌──────────────────────┐  │      │
  │                      │  │    Auth Module       │  │      │
  │                      │  │    Item Module       │  │      │
  │                      │  │    Tx Module         │  │      │
  │                      │  └──────────┬───────────┘  │      │
  │                      │             │ pgx          │      │
  │                      └─────────────┼──────────────┘      │
  │                                    │                     │
  │                                    ▼                     │
  │                      ┌────────────────────────────┐      │
  │                      │         mono_db            │      │
  │                      │      (PostgreSQL 18)       │      │
  │                      │                            │      │
  │                      │  users                     │      │
  │                      │  items                     │      │
  │                      │  transactions              │      │
  │                      │  transaction_items         │      │
  │                      │                            │      │
  │                      │  FK: all tables            │      │
  │                      │  JOIN: allowed             │      │
  │                      └────────────────────────────┘      │
  └──────────────────────────────────────────────────────────┘
```

### Microservices

Four independently deployable Go services. API Gateway handles REST, routes
requests to backend services via gRPC. Each service owns its own database.

```text
  Kubernetes Cluster
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │  ┌──────────────┐            REST HTTP :8080                            │
  │  │   k6 Job     │─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐                                │
  │  │ (testing-    │                      │                                │
  │  │   nodes)     │                      ▼                                │
  │  └──────────────┘         ┌─────────────────────────┐                   │
  │                           │     API Gateway Pod     │                   │
  │                           │     (app-nodes)         │                   │
  │                           │                         │                   │
  │                           │  ┌───────────────────┐  │                   │
  │                           │  │  Echo HTTP :8080  │  │                   │
  │                           │  │  JWT validation   │  │                   │
  │                           │  │  HTTP -> gRPC     │  │                   │
  │                           │  └────────┬──────────┘  │                   │
  │                           └───────────┼─────────────┘                   │
  │                                       │ gRPC                            │
  │                ┌──────────────────────┼──────────────────────┐          │
  │                │                      │                      │          │
  │                ▼                      ▼                      ▼          │
  │  ┌──────────────────────┐┌──────────────────────┐┌──────────────────────┐
  │  │    auth-service Pod  ││    item-service Pod  ││  transaction-svc Pod │
  │  │    (app-nodes)       ││    (app-nodes)       ││  (app-nodes)         │
  │  │                      ││                      ││                      │
  │  │  gRPC :50051         ││  gRPC :50052         ││  gRPC :50053         │
  │  │  - Register          ││  - CRUD Items        ││  - CreateTx          │
  │  │  - Login             ││  - ValidateTxItems   ││  - GetOwnTxs         │
  │  │  - GetUserById       ││  - SyncItems         ││  - GetTxById         │
  │  │  - GetUsersByIds     ││  - ListItems         ││  - EnrichTxs         │
  │  └──────────┬───────────┘└──────────┬───────────┘└──────────┬───────────┘
  │             │ pgx                   │ pgx                   │ pgx        │
  │             ▼                       ▼                       ▼            │
  │  ┌────────────────────┐┌────────────────────┐┌────────────────────────┐  │
  │  │      auth_db       ││      item_db       ││    transaction_db      │  │
  │  │                    ││                    ││                        │  │
  │  │  users             ││  items             ││  transactions          │  │
  │  │                    ││  (soft delete)     ││  transaction_items     │  │
  │  │  NO FK to          ││  NO FK to          ││  FK: tx_items ->       │  │
  │  │  other DBs         ││  other DBs         ││      transactions      │  │
  │  └────────────────────┘└────────────────────┘│  NO FK to other DBs    │  │
  │                                              └────────────────────────┘  │
  └──────────────────────────────────────────────────────────────────────────┘
```

### Key Differences

```text
  Aspect              Monolith                Microservices
  ─────────────────   ─────────────────────   ─────────────────────────
  Process             1 Go process            4 Go processes
  Internal calls      in-process function     gRPC (HTTP/2)
  Database            1 (mono_db)             3 (auth_db, item_db, tx_db)
  Cross-table FK      allowed                 not allowed across DBs
  SQL JOIN            allowed (enrichment)    not possible across DBs
  Deployment          1 Deployment            4 Deployments
  Scaling             scale whole app         scale per service
```

### Benchmark Scenarios

```text
  Scenario                  HTTP Method + Path                    Focus
  ────────────────────────  ──────────────────────────────────    ──────────────
  login                     POST /api/v1/auth/login               CPU (bcrypt)
  create-transaction        POST /api/v1/transactions             DB write
  enriched-transactions     GET /api/v1/admin/transactions        Read + JOIN
  concurrent-mixed-workload all 3 above with 20/40/40 split       System-level
  sync-items                PUT /api/v1/items                     Bulk sync
```

### Execution Modes

```text
  PARALLEL (2 clusters)                        SEQUENTIAL (1 cluster)

  ┌──────────────────┐ ┌──────────────────┐   ┌────────────────────────────┐
  │   Cluster A      │ │   Cluster B      │   │     Single Cluster         │
  │   (monolith)     │ │   (microservices)│   │                            │
  │                  │ │                  │   │  Phase 1: Monolith         │
  │   mono pods      │ │   msa pods       │   │  ┌──────────────────────┐ │
  │   mono_db (RDS)  │ │   3x DB (RDS)    │   │  │ mono pods + mono_db  │ │
  │   k6 jobs        │ │   k6 jobs        │   │  │ k6 run all cases     │ │
  │                  │ │                  │   │  └──────────────────────┘ │
  │   both run       │ │   both run       │   │         │ 300s delay      │
  │   simultaneously │ │   simultaneously │   │         ▼                  │
  │                  │ │                  │   │  Phase 2: Microservices   │
  │                  │ │                  │   │  ┌──────────────────────┐ │
  │                  │ │                  │   │  │ msa pods + 3 DBs     │ │
  │                  │ │                  │   │  │ k6 run all cases     │ │
  └──────────────────┘ └──────────────────┘   │  └──────────────────────┘ │
                                              └────────────────────────────┘
```

### Scaling Modes

- **fixed** — fixed replica count (clean architecture comparison, `K6_PROFILE=steady`)
- **hpa** — Horizontal Pod Autoscaler (autoscaling behavior analysis, `K6_PROFILE=hpa`)

Application pods run on `app-nodes`; k6 runner jobs run on `testing-nodes`.

## Tech Stack

| Layer | Technology |
|---|---|
| Application | Go 1.26.2, Echo (REST), gRPC (internal) |
| Database | PostgreSQL 18, pgx, Goose migrations |
| Container | Docker |
| Kubernetes | AWS EKS, Vultr VKE |
| Infrastructure | Terraform |
| Benchmarking | k6 |
| Observability | Datadog |
| Image Registry | AWS ECR (EKS), Docker Hub (Vultr) |
| Result Storage | AWS S3 |

## Project Structure

```text
.
├── monolith/                 # monolithic Go application
├── microservices/            # api-gateway, auth-service, item-service, transaction-service
├── proto/                    # gRPC protobuf definitions + generated code
├── pkg/                      # shared utilities (config, jwt, postgres, validator, etc.)
├── seed/                     # benchmark seed/reset tool (Go CLI + Dockerfile)
├── k6/                       # load test scripts + runner image
├── deployments/
│   ├── k8s/cloud/            # generic cloud manifests (Kustomize base + fixed/hpa overlays)
│   ├── k8s/benchmark/        # k6 runner jobs, RBAC, DB bootstrap
│   ├── k8s/local/            # Minikube manifests
│   ├── compose/              # Docker Compose for local dev
│   └── helm/datadog/         # Datadog Helm values per environment
├── infra/terraform/          # Terraform stacks for AWS, Vultr
├── scripts/                  # operator and automation scripts
├── env/                      # generated environment files (gitignored)
├── docs/                     # project documentation
├── openapi.yaml              # external REST API source of truth
├── go.work                   # Go workspace
├── Makefile                  # operational command center
└── AGENTS.md                 # repository rules for AI agents
```

## Quick Start

```bash
# 1. Initialize operator environment
make env-init PLATFORM=vultr EXECUTION_MODE=sequential
# or: make env-init PLATFORM=eks EXECUTION_MODE=parallel

# 2. Build and push images
export IMAGE_TAG=$(git rev-parse --short HEAD)
make docker-build-all IMAGE_TAG=$IMAGE_TAG
make dockerhub-push-all IMAGE_TAG=$IMAGE_TAG   # Vultr
# or: make ecr-push-all IMAGE_TAG=$IMAGE_TAG   # AWS EKS

# 3. Provision infrastructure
make render-tfvars
make shared-apply
make experiment-apply
make setup-contexts
make create-secrets

# 4. Deploy and benchmark
make deploy-workloads
make run-benchmark-suite SCALING_MODE=fixed IMAGE_TAG=$IMAGE_TAG

# 5. Verify results in S3, then destroy
make experiment-destroy-confirmed
make shared-destroy-confirmed
```

Run `make help` for the full command reference.

## Cloud Providers

| Provider | Terraform Stacks | K8s Runtime | Image Registry |
|---|---|---|---|
| AWS EKS | `aws-shared`, `aws-parallel`, `aws-sequential` | EKS | ECR |
| Vultr | `vultr-shared`, `vultr-parallel`, `vultr-sequential` | VKE | Docker Hub |

Provider-specific Makefile targets use prefixes: `eks-*`, `vultr-*`.
Generic targets (`shared-apply`, `experiment-apply`, `deploy-workloads`,
`run-benchmark-suite`) dispatch through `scripts/operator-dispatch.sh` based on
`env/operator-profile.env`.

For detailed provider runbooks:

- AWS: [`docs/infrastructure/benchmark-runbook-end-to-end.md`](docs/infrastructure/benchmark-runbook-end-to-end.md)
- Vultr: [`docs/infrastructure/vultr-vke-runbook.md`](docs/infrastructure/vultr-vke-runbook.md)

## API Contract

Source of truth: [`openapi.yaml`](openapi.yaml)

| Endpoint | Purpose |
|---|---|
| `POST /api/v1/auth/login` | CPU-bound bcrypt + JWT (Benchmark 1) |
| `POST /api/v1/transactions` | write-heavy DB transaction (Benchmark 2) |
| `GET /api/v1/admin/transactions` | read-heavy enrichment/JOIN (Benchmark 3) |
| `PUT /api/v1/items` | bulk item sync (optional) |

gRPC contracts: `proto/auth/v1/auth.proto`, `proto/item/v1/item.proto`,
`proto/transaction/v1/transaction.proto`. Regenerate with `make proto`.

## Benchmark Scenarios

k6 scripts: [`k6/scripts/`](k6/scripts/)

| Script | Scenario |
|---|---|
| `login.js` | Benchmark 1 — bcrypt + JWT |
| `create-transaction.js` | Benchmark 2 — DB write transaction |
| `enriched-transactions.js` | Benchmark 3 — read + fan-out/JOIN |
| `concurrent-mixed-workload.js` | composite concurrent workload |
| `mixed-workload.js` | legacy random-branch mixed traffic |
| `smoke.js` | quick validation |
| `sync-items.js` | PUT /api/v1/items |

Default RPS levels: `1000, 2500, 5000, 7500, 10000`.

Results upload to: `s3://{bucket}/experiments/{run_id}/{architecture}/{scenario}/{rps}rps/{attempt}/`

## Local Development

```bash
make env-init-base                    # generate postgres.env
make env-init-monolith                # generate monolith.env
make env-init-microservices           # generate service env files
make fmt && make test                 # format and test
make run-monolith-local               # run monolith locally
make compose-up                       # Docker Compose (all services)
make minikube-bootstrap-monolith-smoke  # Minikube full bootstrap
```

Docs: [`docs/development/`](docs/development/)

## Documentation

| Area | Key Documents |
|---|---|
| Architecture | [`docs/architecture/`](docs/architecture/) — overview, monolith, microservices, comparison |
| API | [`openapi.yaml`](openapi.yaml), [`docs/api/`](docs/api/) |
| Development | [`docs/development/`](docs/development/) — database, migrations, validation, project structure |
| Infrastructure | [`docs/infrastructure/`](docs/infrastructure/) — cloud architecture, Terraform, benchmark runbooks |
| Experiment | [`docs/experiment/`](docs/experiment/) — scaling mode, resource configuration, ceiling methodology |
| Diagrams | [`docs/diagrams/`](docs/diagrams/) — architecture, topology, benchmark lifecycle, sequence diagrams |
| Research | [`docs/research-questions/`](docs/research-questions/) — RQ1 performance, RQ2 resource efficiency |

## Fairness Rules

Both architectures must remain functionally equivalent from the external API
perspective. Do not add caching, retries, circuit breakers, async queues, or
architecture-specific optimizations unless applied equally to both.

## Safety

- Never commit secrets, credentials, or keys.
- Keep databases in private subnets; do not expose publicly.
- Verify S3 benchmark artifacts before destroying infrastructure.
- Treat `env/*.env` and `terraform.tfvars` as operator-local artifacts.
