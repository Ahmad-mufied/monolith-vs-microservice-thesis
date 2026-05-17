# AGENTS.md

## Purpose

This file is the single source of repository guidance for Codex.

This repository is a thesis benchmark project comparing monolithic and microservices architectures in a cloud-native environment.

Keep this file focused on rules that must apply across the whole repository. Do not add subdirectory AGENTS.md files unless Codex repeatedly makes mistakes in a specific area.

## Project Context

The thesis compares:

1. Monolithic Architecture
2. Microservices Architecture

The research evaluates:

- application performance,
- latency percentiles,
- throughput/RPS,
- error rate,
- CPU usage,
- memory usage,
- autoscaling behavior with Kubernetes HPA,
- resource efficiency under equivalent resource ceilings.

The benchmark application is a generic transactional API, not a specific e-commerce application.

Use these domain terms:

- user
- item
- amount
- available_amount
- transaction
- transaction_items

External REST API naming follows openapi.yaml. In the current API contract, item availability is exposed as Item.available_amount. The database schema and migration docs also use available_amount for the internal storage column.

Avoid these terms unless explicitly requested:

- product
- cart
- checkout
- payment
- stock
- quantity

## Repository Model

This repository is a monorepo.

Top-level structure:

- docs/
- monolith/
- microservices/
- proto/
- pkg/
- seed/
- deployments/
- infra/
- k6/
- scripts/
- go.work
- AGENTS.md

The monorepo is used for development consistency only.

Runtime architecture must remain different:

- Monolith runs as one deployable application.
- Microservices run as separate deployable services.

## Main Technology Stack

Application:

- Go
- Echo for external REST HTTP API
- gRPC for internal microservices communication
- PostgreSQL 18
- pgx for PostgreSQL access
- Goose for SQL migrations
- Docker
- Kubernetes on Amazon EKS
- Terraform
- k6
- Datadog

External client communication:

- REST HTTP

Internal microservices communication:

- gRPC

## Source of Truth

Before making changes, inspect the relevant source of truth.

For gRPC changes:

- proto/auth/v1/auth.proto
- proto/item/v1/item.proto
- proto/transaction/v1/transaction.proto
- docs/api/grpc-contracts.md

For architecture decisions:

- docs/architecture/overview.md
- docs/architecture/monolith.md
- docs/architecture/microservices.md
- docs/architecture/comparison.md

For database decisions:

- docs/development/database-schema.md
- docs/development/database-migration.md
- docs/infrastructure/rds-postgres.md

For request validation decisions:

- docs/development/validation-strategy.md

For benchmark decisions:

- docs/experiment/research-design.md
- docs/experiment/workload-scenarios.md
- docs/experiment/resource-configuration.md
- docs/experiment/hpa-resourcequota.md
- docs/experiment/data-collection.md
- docs/experiment/test-execution-procedure.md

## Code Architecture

Use Layered Architecture with Clean/Hexagonal-inspired dependency direction.

Recommended layers:

- handler/controller
- usecase/service
- domain/model
- port/interface
- adapter/repository/client

Do not implement full Domain-Driven Design unless explicitly requested.

Dependency rules:

- handler may call usecase or service client.
- usecase may depend on interfaces/ports.
- repository implements database ports.
- gRPC client implements outbound service-client ports.
- gRPC server maps transport request to usecase.
- domain must not import HTTP, Echo, gRPC, PostgreSQL, Datadog, or framework-specific packages.
- business logic must not be placed in handlers.
- SQL queries must not be placed in handlers.
- SQL queries should be placed in repository/adapter layer.

## Command Structure

All deployable Go applications use:

cmd/server/main.go

This applies to:

- monolith
- api-gateway
- auth-service
- item-service
- transaction-service

Do not use mixed command names such as cmd/api for monolith and cmd/server for microservices.

## Monolith Architecture Rules

Path:

monolith/

The monolith contains these modules:

- auth
- item
- transaction

The monolith:

- runs as one process,
- exposes the same REST API as microservices,
- uses one database: mono_db,
- communicates internally using in-process function calls,
- may use foreign keys across users, items, transactions, and transaction_items,
- may use SQL JOIN for enriched transaction response,
- performs create transaction in one database transaction.

Expected monolith flow:

HTTP request
→ handler
→ usecase
→ repository
→ PostgreSQL

Benchmark 1 login flow:

POST /api/v1/auth/login
→ find user by email
→ bcrypt password comparison
→ JWT signing
→ response

Benchmark 2 create transaction flow:

POST /api/v1/transactions
→ begin DB transaction
→ validate item available_amount
→ insert transaction using INSERT ... RETURNING id
→ insert transaction_items
→ commit
→ response

Benchmark 3 enriched transactions flow:

GET /api/v1/admin/transactions
→ single SQL JOIN across users, transactions, transaction_items, and items
→ response

## Microservices Architecture Rules

Path:

microservices/

Services:

- api-gateway
- auth-service
- item-service
- transaction-service

Each service must remain independently deployable.

### API Gateway

Responsibilities:

- external REST HTTP entry point,
- route requests to internal services,
- validate JWT for protected endpoints,
- map HTTP requests to gRPC requests,
- map gRPC responses and errors to HTTP responses,
- start request tracing.

Restrictions:

- must not contain core business logic,
- must not access databases directly,
- must not own migrations,
- must not own persistent data.

### Auth Service

Responsibilities:

- register user,
- login user,
- bcrypt password hashing/comparison,
- JWT issuing,
- GetUserById,
- GetUsersByIds.

Owns:

- auth_db
- users table

### Item Service

Responsibilities:

- create item,
- get item,
- list items,
- update item,
- delete item,
- GetItemSummariesByIds,
- ValidateTransactionItems.

Owns:

- item_db
- items table

### Transaction Service

Responsibilities:

- create transaction,
- get own transactions,
- get transaction by ID,
- get raw transactions for enrichment,
- call Item Service for ValidateTransactionItems.

Owns:

- transaction_db
- transactions table
- transaction_items table

Microservices communication rules:

- external communication uses REST HTTP through API Gateway,
- internal communication uses gRPC only,
- a service must not access another service's database,
- a service must not import another service's internal package,
- transaction-service stores user_id and item_id as UUID references only,
- transaction-service must not create foreign keys to auth_db.users or item_db.items.

Benchmark 1 login flow:

Client/k6
→ API Gateway
→ Auth Service
→ auth_db.users
→ bcrypt compare
→ JWT signing
→ API Gateway
→ response

Benchmark 2 create transaction flow:

Client/k6
→ API Gateway
→ Transaction Service
→ Item Service via gRPC ValidateTransactionItems
→ item_db validates available_amount (validation-only, no deduction)
→ Transaction Service inserts transaction using INSERT ... RETURNING id
→ Transaction Service inserts transaction_items
→ API Gateway
→ response

Benchmark 3 enriched transactions flow:

Client/k6
→ API Gateway
→ Transaction Service
→ transaction_db
→ API Gateway calls Auth Service GetUsersByIds
→ API Gateway calls Item Service GetItemSummariesByIds
→ API Gateway joins/enriches in memory
→ response

Do not add caching, message queues, retries, circuit breakers, asynchronous processing, or saga/compensation mechanisms unless explicitly requested.

This thesis does not focus on distributed transaction consistency, saga pattern, compensation mechanism, or chaos engineering unless explicitly requested.

## API Contract Rules

External REST API source of truth:

openapi.yaml

Do not change these without updating openapi.yaml in the same change:

- endpoint paths,
- request bodies,
- response bodies,
- authentication requirements,
- error response format,
- benchmark endpoint semantics.

All public IDs in OpenAPI must use:

type: string
format: uuid

Examples must use UUID strings, not labels such as USR-001, ITM-001, or TX-001.

Response format:

Success:

{
  "status": "success",
  "data": {}
}

Error:

{
  "status": "error",
  "error": {
    "code": "BAD_REQUEST",
    "message": "Invalid request payload",
    "details": null
  }
}

Main benchmark endpoints:

1. POST /api/v1/auth/login
2. POST /api/v1/transactions
3. GET /api/v1/admin/transactions

## gRPC Contract Rules

Proto files:

- proto/auth/v1/auth.proto
- proto/item/v1/item.proto
- proto/transaction/v1/transaction.proto

UUID values in proto are represented as string fields.

Examples:

string user_id = 1;
string item_id = 2;
string transaction_id = 3;

All UUID strings must be valid UUID format.

After editing proto files:

- regenerate Go gRPC code,
- update affected clients,
- update affected servers,
- update API Gateway mapping if needed,
- update docs/api/grpc-contracts.md if behavior changes.

## Database Rules

Target database:

PostgreSQL 18

All primary keys use PostgreSQL UUID type with database-side UUIDv7 generation:

id UUID PRIMARY KEY DEFAULT uuidv7()

Application code must not generate UUID manually for normal runtime inserts.

All create operations must use:

INSERT ... RETURNING id

All main tables must include:

created_at TIMESTAMPTZ NOT NULL DEFAULT now()
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()

Use TIMESTAMPTZ for timestamp fields.

Use INT for amount and available_amount.

Use checks:

available_amount >= 0
amount > 0

## Database Layout

Use one RDS PostgreSQL 18 instance with separate databases:

- mono_db
- auth_db
- item_db
- transaction_db

Ownership:

- monolith owns mono_db
- auth-service owns auth_db
- item-service owns item_db
- transaction-service owns transaction_db
- api-gateway owns no database

## Monolith Database Rules

Monolith database:

mono_db

Tables:

- users
- items
- transactions
- transaction_items

Monolith may use foreign keys:

- transactions.user_id → users.id
- transaction_items.transaction_id → transactions.id
- transaction_items.item_id → items.id

Monolith may use a single SQL JOIN for enriched transactions.

## Microservices Database Rules

Microservices databases:

- auth_db
- item_db
- transaction_db

auth_db tables:

- users

item_db tables:

- items

transaction_db tables:

- transactions
- transaction_items

transaction_db may use foreign key:

- transaction_items.transaction_id → transactions.id

transaction_db must not use foreign keys to:

- auth_db.users
- item_db.items

transaction_db stores these as UUID references only:

- transactions.user_id
- transaction_items.item_id

## Transaction Tables

transactions table represents transaction header.

transaction_items table represents item details inside a transaction.

Relationship:

one transaction has many transaction_items

Use composite primary key for transaction_items:

PRIMARY KEY (transaction_id, item_id)

Do not add item_name_snapshot or user_name_snapshot unless explicitly requested.

Reason:

Benchmark 3 intentionally evaluates enrichment behavior:
- monolith uses SQL JOIN,
- microservices uses distributed join/fan-out via gRPC.

## Migration Rules

Migration tool:

Goose SQL migration

Migration execution:

Kubernetes Job

Do not use init containers for migration.

Reason:

Migration must run once per deployment/release, not once per pod. Init container migration can be triggered by every new pod during HPA scale-out.

Migration paths:

Monolith:

monolith/migrations/

Microservices:

microservices/auth-service/migrations/
microservices/item-service/migrations/
microservices/transaction-service/migrations/

API Gateway has no migration.

Migration files should contain schema changes only.

Do not put large benchmark seed data into migration files.

## Seed Rules

Seed data is managed centrally under:

seed/

Structure:

seed/
├── datasets/
└── scripts/

Seed is separate from migration.

Migration means:

- create table,
- create index,
- alter schema.

Seed means:

- insert benchmark users,
- insert benchmark items,
- insert benchmark transactions,
- reset benchmark data.

Because IDs are generated by PostgreSQL using uuidv7(), seed scripts must capture generated IDs using:

INSERT ... RETURNING id

Seed scripts must maintain mappings between logical dataset records and generated database IDs.

Examples:

logical_user_key → generated user_id
logical_item_key → generated item_id
logical_transaction_key → generated transaction_id

Seed data for monolith and microservices must be logically equivalent:

- same number of users,
- same number of items,
- same number of transactions,
- same amount distribution,
- same initial available_amount distribution,
- same benchmark workload.

UUID values do not need to be identical between monolith and microservices as long as the dataset is logically equivalent and generated mappings are used correctly.

Before each benchmark scenario that mutates data:

1. reset data,
2. run seed job,
3. validate row counts,
4. run benchmark.

## Kubernetes and Infrastructure Rules

Target infrastructure:

- AWS EKS
- Amazon RDS PostgreSQL 18
- Amazon S3 for benchmark result storage
- Datadog for observability
- Terraform for provisioning

Application node placement:

- application pods run on app-nodes

k6 node placement:

- k6 runner runs on testing-nodes

Datadog:

- runs as DaemonSet on monitored nodes

RDS:

- private subnet only
- public access disabled
- must not allow 0.0.0.0/0 on port 5432

Do not hardcode:

- AWS credentials,
- database passwords,
- JWT secrets,
- Datadog API keys,
- S3 credentials.

Use IAM roles, IRSA, EKS Pod Identity, Kubernetes Secrets, or external secret management as appropriate.

## Resource and HPA Rules

Application CPU ceiling:

- monolith: 4000m
- microservices namespace: 4000m

Application memory ceiling:

- monolith: 4096Mi
- microservices namespace: 4096Mi

Monolith pod:

- CPU: 1000m
- memory: 1024Mi
- minReplicas: 1
- maxReplicas: 4
- HPA target CPU utilization: 70%

Microservices pod per service:

- CPU: 250m
- memory: 256Mi
- minReplicas: 1
- maxReplicas: 16
- HPA target CPU utilization: 70%

Microservices namespace ResourceQuota:

- CPU max: 4000m
- memory max: 4096Mi

Reason for maxReplicas 16:

4000m / 250m = 16 pods

This allows a focused service to scale up under targeted load while ResourceQuota prevents the total microservices resource budget from exceeding the monolith resource budget.

Do not add KEDA, Prometheus Adapter custom metrics, VPA, Cluster Autoscaler, or Karpenter unless explicitly requested.

## k6 Benchmark Rules

k6 scripts are located under:

k6/scripts/

Main scenarios:

- login.js
- create-transaction.js
- enriched-transactions.js
- mixed-workload.js

Use RPS-based testing with constant-arrival-rate.

Default target RPS levels:

- 1000
- 2500
- 5000
- 7500
- 10000

10000 RPS is a stress-level target, not a guaranteed sustainable target.

k6 scripts must read:

- BASE_URL
- TARGET_RPS
- TEST_DURATION when available
- AUTH_TOKEN when required
- ARCHITECTURE when useful
- SCENARIO when useful

Do not hardcode URLs, credentials, tokens, or environment-specific values.

k6 must run on testing-nodes, not app-nodes.

Avoid heavy response parsing or expensive checks that distort load generator overhead.

Monolith and microservices must use symmetrical k6 scenarios.

Do not run monolith and microservices tests simultaneously.

## Benchmark Result Storage

Benchmark results must be uploaded to S3 before infrastructure is destroyed.

S3 prefix format:

s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/

Each k6 execution must upload to a unique attempt folder.

`scenario_name` should normally match the k6 script basename without `.js`.

Examples:

- `k6/scripts/login.js` -> `login`
- `k6/scripts/create-transaction.js` -> `create-transaction`
- `k6/scripts/enriched-transactions.js` -> `enriched-transactions`
- `k6/scripts/mixed-workload.js` -> `mixed-workload`

Required files per attempt:

- summary.json
- raw.json.gz
- stdout.log
- metadata.json
- k6-options.json
- thresholds.json
- pods-state.txt
- top-pods.txt
- top-nodes.txt
- events.txt
- resource-quotas.yaml
- deployments-state.yaml
- services-state.yaml

Required when HPA is enabled:

- hpa-state.yaml
- hpa-describe.txt

Required when Datadog is enabled:

- datadog-time-window.json

Optional files:

- summary.html
- app-manifests.yaml

metadata.json should include:

- run_id
- attempt
- architecture
- scenario_name
- k6_script
- target_rps
- duration
- base_url
- timestamp_utc
- git_commit when available
- image_tag when available
- images when available
- seed_size
- k6 configuration
- infra configuration
- resources configuration
- datadog time window when Datadog is enabled
- app_resource_quota
- hpa_target_cpu
- app_node_pool
- testing_node_pool
- dataset_version

metadata.json is the source of truth for automated analysis and for determining whether the attempt used HPA or fixed replicas.

Do not run terraform destroy before verifying that benchmark data exists in S3.

## Experiment Execution Rules

Preferred sequence:

1. terraform apply
2. run migration jobs
3. run seed job
4. deploy architecture
5. validate application readiness
6. run k6 scenario
7. export Kubernetes snapshots
8. upload results to S3
9. reset and reseed data if the next scenario needs clean state
10. test next scenario
11. verify S3 results
12. terraform destroy
13. check for cost-leak resources

Migration and seed must not run during benchmark execution.

## Observability Rules

Use Datadog for:

- service latency,
- service throughput,
- service error rate,
- CPU usage,
- memory usage,
- pod replica count,
- HPA behavior,
- traces,
- RDS metrics when available.

Expected MSA trace for create transaction:

HTTP request
→ api-gateway
→ transaction-service
→ item-service
→ PostgreSQL

Expected MSA trace for enriched transactions:

HTTP request
→ api-gateway
→ transaction-service
→ transaction_db
→ auth-service
→ auth_db
→ item-service
→ item_db

k6 summary remains the primary source for external client-perceived performance.

Datadog is used to explain internal behavior and root causes.

## Documentation Rules

Root docs/ contains project documentation.

Important documents:

Architecture:

- docs/architecture/overview.md
- docs/architecture/monolith.md
- docs/architecture/microservices.md
- docs/architecture/comparison.md

API:

- docs/api/openapi-notes.md
- docs/api/grpc-contracts.md
- docs/api/error-handling.md

Development:

- docs/development/project-structure.md
- docs/development/coding-guidelines.md
- docs/development/local-development.md
- docs/development/database-schema.md
- docs/development/database-migration.md
- docs/development/validation-strategy.md

Experiment:

- docs/experiment/research-design.md
- docs/experiment/workload-scenarios.md
- docs/experiment/resource-configuration.md
- docs/experiment/hpa-resourcequota.md
- docs/experiment/data-collection.md
- docs/experiment/test-execution-procedure.md
- docs/experiment/result-analysis-template.md

Infrastructure:

- docs/infrastructure/aws-eks.md
- docs/infrastructure/node-pool-design.md
- docs/infrastructure/rds-postgres.md
- docs/infrastructure/s3-result-storage.md
- docs/infrastructure/datadog.md
- docs/infrastructure/terraform.md
- docs/infrastructure/cost-control.md

Thesis:

- docs/thesis/bab-1-notes.md
- docs/thesis/bab-2-literature-review.md
- docs/thesis/bab-3-method.md
- docs/thesis/terminology.md
- docs/thesis/journal-findings.md

When behavior changes, update the relevant docs in the same change.

## Shared Package Rules

Shared technical utilities live under:

pkg/

Allowed in pkg:

- config loader,
- logger,
- observability helper,
- response helper,
- error helper,
- JWT utility,
- PostgreSQL connection helper,
- validator helper.

Not allowed in pkg:

- auth business logic,
- item business logic,
- transaction business logic,
- domain-specific repository,
- usecase logic,
- service-specific policy.

## Development Workflow

Before editing code:

1. inspect relevant docs,
2. inspect proto files for gRPC changes,
3. inspect existing implementation patterns.

After editing Go code:

- run gofmt,
- run go test ./... in the affected module,
- ensure the code compiles.

After editing SQL migrations:

- ensure Goose markers are present,
- verify Up and Down sections,
- ensure schema matches docs/development/database-schema.md.

After editing Terraform:

- run terraform fmt,
- run terraform validate when possible,
- explain cost-impacting resources.

After editing k6:

- ensure BASE_URL and TARGET_RPS are environment-driven,
- ensure scenario symmetry between monolith and microservices,
- ensure output can be uploaded to S3.

## Security Rules

Never commit secrets.

Never hardcode:

- AWS access keys,
- database passwords,
- JWT secrets,
- Datadog API keys,
- S3 credentials,
- private keys.

Do not expose RDS publicly.

Do not weaken authentication rules without explicit request.

Do not print secrets in logs.

## Fairness Rules

Do not optimize only one architecture unless the same optimization is applied to the other architecture or the difference is explicitly documented.

Avoid adding features that alter benchmark semantics, such as:

- caching,
- async queue,
- retries,
- circuit breakers,
- connection pooling changes that only affect one architecture,
- database indexes that only exist in one architecture,
- different endpoint behavior,
- different payloads,
- different auth rules.

Both architectures must remain functionally equivalent from the external API perspective.

## Review Checklist

When reviewing changes, check:

- Do proto files match gRPC clients and servers?
- Are UUID fields handled as valid UUID strings?
- Are IDs generated by PostgreSQL with uuidv7()?
- Do create queries use INSERT ... RETURNING id?
- Are migrations separated from seed data?
- Are monolith and microservices workloads equivalent?
- Are database ownership boundaries preserved?
- Does transaction-service avoid cross-service database access?
- Does API Gateway avoid business logic?
- Are docs updated when behavior changes?

## Done Criteria

A task is done only when:

- code compiles,
- relevant tests pass,
- gofmt has been applied,
- gRPC contracts are updated when needed,
- migrations are updated when schema changes,
- seed scripts are updated when dataset assumptions change,
- docs are updated when behavior changes,
- no secrets are committed,
- benchmark fairness is preserved.

## Local Override Policy

For now, this root AGENTS.md is the single source of repository guidance.

Do not add subdirectory AGENTS.md files unless repeated mistakes happen in a specific area.

If repeated mistakes happen later, consider adding focused subdirectory guidance for:

- k6/
- infra/terraform/
- microservices/
- monolith/

Keep any future subdirectory AGENTS.md short and specific.
