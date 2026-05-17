# Seed Runner

## Purpose

The `seed/` module contains the centralized reset, base seed, and enrichment
preparation utility for the benchmark application.

It is intentionally separate from migration:

- migration creates schema objects,
- reset removes benchmark data while keeping schema,
- base seed inserts deterministic users and items,
- enrichment preparation inserts deterministic transaction read fixtures for
  `enriched-transactions`.

The same runner is used by host-side commands and Kubernetes Jobs.

## Commands

The runner exposes six commands:

```bash
seed-runner reset-monolith-data \
  --database-url="$MONO_DATABASE_URL"

seed-runner seed-monolith-data \
  --dataset=smoke \
  --database-url="$MONO_DATABASE_URL"

seed-runner prepare-monolith-enrichment-data \
  --dataset=benchmark \
  --database-url="$MONO_DATABASE_URL"

seed-runner reset-microservices-data \
  --auth-database-url="$AUTH_DATABASE_URL" \
  --item-database-url="$ITEM_DATABASE_URL" \
  --transaction-database-url="$TRANSACTION_DATABASE_URL"

seed-runner seed-microservices-data \
  --dataset=smoke \
  --auth-database-url="$AUTH_DATABASE_URL" \
  --item-database-url="$ITEM_DATABASE_URL" \
  --transaction-database-url="$TRANSACTION_DATABASE_URL"

seed-runner prepare-microservices-enrichment-data \
  --dataset=benchmark \
  --auth-database-url="$AUTH_DATABASE_URL" \
  --item-database-url="$ITEM_DATABASE_URL" \
  --transaction-database-url="$TRANSACTION_DATABASE_URL"
```

Supported dataset values:

- `smoke`
- `benchmark`

No free-form transaction count flag is supported in v1.

## Data Model

Base seed inserts only:

```text
users
items
```

Base seed does not insert:

```text
transactions
transaction_items
```

This keeps the benchmark model clean:

- users and items are workload input,
- transactions are runtime output for `create-transaction`,
- enriched read fixtures are created only by explicit preparation commands.

## Enrichment Preparation

Use enrichment preparation only for the `enriched-transactions` benchmark.

Preparation behavior:

- base users and items must already exist,
- monolith reads from and writes to `mono_db`,
- microservices reads users from `auth_db`, reads items from `item_db`, and
  writes only to `transaction_db`,
- users and items are left untouched,
- preparation inserts only `transactions` and `transaction_items`.

Deterministic v1 rules:

- `smoke` prepares 12 transactions,
- `benchmark` prepares 240 transactions,
- each transaction uses a stable user rotation,
- each transaction has a deterministic 1-3 item pattern,
- item amounts follow a stable bounded pattern,
- timestamps are fixed from dataset-specific UTC anchors so pagination stays
  reproducible.

Preparation is intentionally not designed for dirty-table reruns.

For a clean read dataset, use:

```text
reset -> seed -> prepare
```

Do not treat prepare as idempotent on top of existing transaction rows.

## Makefile Entry Points

Host-side commands:

```bash
make reset-monolith-data
make seed-monolith-data DATASET=smoke
make seed-monolith-data DATASET=benchmark
make prepare-monolith-enrichment-data DATASET=smoke
make prepare-monolith-enrichment-data DATASET=benchmark

make reset-microservices-data
make seed-microservices-data DATASET=smoke
make seed-microservices-data DATASET=benchmark
make prepare-microservices-enrichment-data DATASET=smoke
make prepare-microservices-enrichment-data DATASET=benchmark
```

Minikube data lifecycle:

```bash
make minikube-reset-monolith-data
make minikube-seed-monolith-smoke
make minikube-seed-monolith-benchmark
make minikube-prepare-monolith-enrichment-smoke
make minikube-prepare-monolith-enrichment-benchmark

make minikube-reset-microservices-data
make minikube-seed-microservices-smoke
make minikube-seed-microservices-benchmark
make minikube-prepare-microservices-enrichment-smoke
make minikube-prepare-microservices-enrichment-benchmark
```

Minikube enrichment bootstrap:

```bash
make minikube-bootstrap-monolith-enrichment-smoke
make minikube-bootstrap-monolith-enrichment-benchmark
make minikube-bootstrap-microservices-enrichment-smoke
make minikube-bootstrap-microservices-enrichment-benchmark
```

These enrichment bootstrap targets run:

```text
migration
reset
base seed
enrichment preparation
application deploy
```

Existing bootstrap targets for login and create-transaction flows remain
unchanged.

## Kubernetes Jobs

Local Minikube uses `skripsi/seed-runner:local`.

Monolith jobs:

```text
deployments/k8s/monolith/reset-monolith-data-job.yaml
deployments/k8s/monolith/seed-monolith-smoke-data-job.yaml
deployments/k8s/monolith/seed-monolith-benchmark-data-job.yaml
deployments/k8s/monolith/prepare-monolith-enrichment-smoke-data-job.yaml
deployments/k8s/monolith/prepare-monolith-enrichment-benchmark-data-job.yaml
```

Microservices jobs:

```text
deployments/k8s/microservices/reset-microservices-data-job.yaml
deployments/k8s/microservices/seed-microservices-smoke-data-job.yaml
deployments/k8s/microservices/seed-microservices-benchmark-data-job.yaml
deployments/k8s/microservices/prepare-microservices-enrichment-smoke-data-job.yaml
deployments/k8s/microservices/prepare-microservices-enrichment-benchmark-data-job.yaml
```

No EKS-specific enrichment manifest is added in this branch. EKS should follow
the same command model and lifecycle.

## Retry and Validation Notes

Base seed is retry-safe for Kubernetes Job reruns:

- users upsert by fixed `id`,
- dataset items upsert by fixed `id`.

Enrichment preparation is not retry-safe on dirty transaction tables by design.

Useful checks after reset, seed, or prepare:

```bash
kubectl get jobs -n mono
kubectl logs job/prepare-monolith-enrichment-benchmark-data-job -n mono

kubectl get jobs -n msa
kubectl logs job/prepare-microservices-enrichment-benchmark-data-job -n msa
```

## Benchmark Lifecycle

For `login` and `create-transaction`:

```text
reset
seed
deploy
run measured workload
```

For `enriched-transactions`:

```text
reset
seed
prepare enrichment data
deploy
run measured workload
```

The preparation step is not part of the measured benchmark result.
