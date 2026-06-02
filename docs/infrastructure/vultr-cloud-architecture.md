# Vultr Cloud Architecture

## Purpose

This document describes the Vultr Kubernetes Engine (VKE) architecture used as
an additive benchmark infrastructure path for the thesis experiment. It
explains the mechanism, topology, resource model, network layout, and benchmark
data flow.

The active implementation is in:

```text
infra/terraform/vultr-shared
infra/terraform/vultr-parallel
infra/terraform/vultr-sequential
infra/terraform/modules/vultr-vke-benchmark-cluster
scripts/*vultr*.sh
scripts/lib/cloud-provider.sh
deployments/k8s/eks
```

Vultr official references used by this design:

- Vultr Terraform provider: <https://registry.terraform.io/providers/vultr/vultr/latest/docs>
- Vultr Kubernetes Engine: <https://docs.vultr.com/products/kubernetes>
- Vultr VPC networking: <https://docs.vultr.com/products/network/vpc-networks>

## Design Summary

```text
Provider                : Vultr
Kubernetes              : VKE
Application nodes       : 2 x high-vCPU app nodes per active architecture
Testing nodes           : 1 x dedicated k6 node per active architecture
Database                : PostgreSQL 18 on separate Vultr Compute VM
Container registry      : Docker Hub public
Benchmark result store  : AWS S3
Observability           : Datadog SaaS
Provisioning            : Terraform
Deployment              : kubectl + rendered Kubernetes manifests
```

The Vultr path intentionally does not introduce a managed database, queue,
cache, custom metrics adapter, cluster autoscaler, or VPA. The goal is to keep
the infrastructure simple enough for thesis reproducibility while still giving
the benchmark enough CPU capacity for high-throughput tests.

## Resource Isolation Model

The benchmark compares:

```text
Monolith       : one Go process, one PostgreSQL database
Microservices  : API Gateway + auth-service + item-service + transaction-service
```

Parallel mode preserves the strongest isolation:

```text
Monolith cluster  -> monolith application pods -> monolith PostgreSQL VM
MSA cluster       -> MSA application pods      -> MSA PostgreSQL VM
```

Sequential mode preserves the same per-run resource ceiling, but not the same
wall-clock time window:

```text
One VKE cluster -> monolith phase -> verify results -> MSA phase -> verify results
```

For final thesis comparisons, parallel mode is preferred because Datadog
time-series from monolith and MSA can be compared over the same load window.

## Parallel Topology

```text
Vultr region: sgp

  Shared stack: infra/terraform/vultr-shared
  ------------------------------------------------------------
  Legacy Vultr VPC network: 10.20.0.0/16
  Operator SSH key
  PostgreSQL firewall group

  Experiment stack: infra/terraform/vultr-parallel
  ------------------------------------------------------------

  +-----------------------------------+     +-----------------------------------+
  | VKE: skripsi-vultr-monolith       |     | VKE: skripsi-vultr-msa            |
  | context: monolith                 |     | context: msa                      |
  |                                   |     |                                   |
  | app node pool                     |     | app node pool                     |
  | - 2 x voc-c-16c-32gb-300s         |     | - 2 x voc-c-16c-32gb-300s         |
  | - label role=app                  |     | - label role=app                  |
  | - namespace mono                  |     | - namespace msa                   |
  |                                   |     |                                   |
  | testing node pool                 |     | testing node pool                 |
  | - 1 x vc2-4c-8gb                  |     | - 1 x vc2-4c-8gb                  |
  | - label role=testing              |     | - label role=testing              |
  | - taint dedicated=testing:NoSchedule|   | - taint dedicated=testing:NoSchedule|
  | - namespace benchmark             |     | - namespace benchmark             |
  |                                   |     |                                   |
  | Datadog Agent                     |     | Datadog Agent                     |
  +-----------------+-----------------+     +-----------------+-----------------+
                    |                                     |
                    | legacy VPC private IP               | legacy VPC private IP
                    v                                     v
  +-----------------------------------+     +-----------------------------------+
  | Vultr Compute: monolith Postgres  |     | Vultr Compute: MSA Postgres       |
  | PostgreSQL 18                     |     | PostgreSQL 18                     |
  | database: mono_db                 |     | databases: auth_db, item_db,      |
  |                                   |     | transaction_db                    |
  +-----------------------------------+     +-----------------------------------+

  External services
  ------------------------------------------------------------
  Docker Hub public: images
  AWS S3: benchmark artifacts
  Datadog SaaS: metrics, traces, logs, HPA behavior
```

## Sequential Topology

```text
Vultr region: sgp

  Shared stack: infra/terraform/vultr-shared
  ------------------------------------------------------------
  Legacy Vultr VPC network
  Operator SSH key
  PostgreSQL firewall group

  Sequential stack: infra/terraform/vultr-sequential
  ------------------------------------------------------------

  +-------------------------------------------------------------+
  | VKE: skripsi-vultr-benchmark                                |
  | context: benchmark                                          |
  |                                                             |
  | app node pool                                               |
  | - 2 x voc-c-16c-32gb-300s                                   |
  | - label role=app                                            |
  | - namespace mono active during monolith phase                |
  | - namespace msa active during microservices phase            |
  |                                                             |
  | testing node pool                                           |
  | - 1 x vc2-4c-8gb                                            |
  | - label role=testing                                        |
  | - taint dedicated=testing:NoSchedule                        |
  | - namespace benchmark                                       |
  |                                                             |
  | Datadog Agent                                               |
  +-----------------------------+-------------------------------+
                                |
                                | legacy VPC private IP
                                v
  +-------------------------------------------------------------+
  | Vultr Compute: shared benchmark PostgreSQL                  |
  | PostgreSQL 18                                                |
  | databases: mono_db, auth_db, item_db, transaction_db         |
  +-------------------------------------------------------------+
```

Sequential mode runs one architecture at a time. It must not be interpreted as
a same-wall-clock comparison.

## Network Model

The Vultr implementation uses a legacy Vultr VPC network because VKE support in
this Terraform path expects that model. The shared stack owns the VPC so both
parallel clusters and the sequential fallback can reference the same network
without duplicating CIDR configuration.

Network rules:

- PostgreSQL traffic uses the private VPC IP.
- PostgreSQL is not exposed with public database access.
- SSH to the PostgreSQL VM is restricted to `OPERATOR_CIDRS`.
- k6 uploads artifacts to AWS S3 over public internet using scoped AWS
  credentials in `benchmark/k6-runner-secret`.
- Application ingress uses the Kubernetes service/load balancer behavior
  already defined by the rendered manifests.

## Compute Model

Default app node shape:

```text
VULTR_APP_NODE_PLAN=voc-c-16c-32gb-300s
VULTR_APP_NODE_COUNT=2
```

Default per active architecture:

```text
app capacity nominal   : 32 vCPU, 64 GiB
testing capacity       : 1 x vc2-4c-8gb
PostgreSQL capacity    : 1 x vc2-4c-8gb
```

The Kubernetes allocatable capacity is measured after cluster creation because
nominal plan capacity is not the same as schedulable capacity. The measured
baseline is written to:

```text
env/vultr-resource-baseline.env
env/vultr-resource-baseline.json
```

The manifest renderer then applies the same measured CPU and memory quota to
both monolith and microservices.

## Resource Fairness

The fairness rule is:

```text
monolith application ceiling == microservices namespace ceiling
```

For Vultr, this ceiling is not hardcoded from AWS EKS values. It is derived
from live app-node allocatable capacity minus a safety margin:

```text
VULTR_APP_CPU_QUOTA     = total app-node allocatable CPU - safety CPU
VULTR_APP_MEMORY_QUOTA  = total app-node allocatable memory - safety memory
```

The default safety margins are configured in:

```text
scripts/measure-vultr-resource-baseline.sh
```

This prevents a silent mismatch where the repo assumes a resource ceiling that
VKE cannot actually schedule.

## PostgreSQL Model

PostgreSQL runs on Vultr Compute, not as a managed database. This keeps the
benchmark portable and avoids introducing a managed database feature that is
not equivalent to the self-contained Hetzner path.

Parallel mode creates:

```text
monolith PostgreSQL VM -> mono_db
MSA PostgreSQL VM      -> auth_db, item_db, transaction_db
```

Sequential mode creates:

```text
benchmark PostgreSQL VM -> mono_db, auth_db, item_db, transaction_db
```

Schema creation remains the responsibility of Kubernetes migration jobs. Seed
data remains separate from migrations.

## Image and Artifact Flow

```text
developer laptop
  -> docker build
  -> Docker Hub public images
  -> VKE pulls images
  -> k6 runs benchmark
  -> k6 uploads summary/raw/metadata to AWS S3
  -> Datadog captures runtime telemetry
```

Docker Hub public is acceptable for this project only because images must not
contain secrets, kubeconfigs, Terraform state, env files, or private benchmark
data.

## Failure Boundaries

The integration is designed to fail fast on:

- missing `env/vultr.env`
- placeholder Vultr token or Docker Hub namespace
- missing AWS S3 upload credentials
- missing live resource baseline before manifest rendering
- stale AWS/ECR image references in Vultr-rendered manifests
- wrong fixed/HPA live mode before benchmark execution
- destroy attempts before S3 result verification

These checks are intentionally lightweight and shell-native. They reduce silent
operator error without adding extra infrastructure systems.
