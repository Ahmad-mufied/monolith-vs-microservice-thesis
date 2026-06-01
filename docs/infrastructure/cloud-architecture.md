# Cloud Architecture

## 1. Purpose

This document describes the cloud architecture of the thesis benchmark
system as deployed on Amazon Web Services. It covers the infrastructure
design, network topology, compute layout, observability paths, and the
end-to-end data flow during a benchmark run.

The intended audience is the thesis researcher, the thesis reviewer, and
anyone reproducing the experiment. The goal is to make every architectural
decision visible, traceable to its source file, and grounded in the
research questions that motivated it.

The benchmark compares two runtime architectures:

```text
Monolith       — one Go application, one database
Microservices  — four Go services, three databases, gRPC between services
```

To keep the comparison fair under cloud-native conditions, the primary
benchmark topology deploys both architectures in **two isolated EKS clusters**
that run in parallel with identical configuration and an identical resource
ceiling.

The repository also supports a quota-constrained sequential topology:
`skripsi-benchmark` runs one architecture at a time on the same resource
ceiling. Use it when account quota cannot support the full parallel topology.
The detailed operator flow is in
`docs/infrastructure/sequential-benchmark-runbook.md`.

---

## 2. Architectural Goal

The cloud architecture is shaped by three principles that come directly
from the research questions in `docs/research-questions/`.

### 2.1 Isolation between architectures

Monolith and microservices must not share runtime resources during a
benchmark. If they shared CPU, memory, or database capacity, results would
reflect contention rather than architectural difference.

### 2.2 Aligned time-series for direct comparison

When both architectures run at the same wall-clock time in parallel mode, Datadog
time-series for CPU, memory, latency, and replica count can be overlaid
directly. This is more robust than running sequentially and stitching time
windows together during analysis.

Sequential mode intentionally gives up this wall-clock alignment to stay within
smaller vCPU quota. Its metadata records `execution_mode=sequential`,
`architecture_order`, `terraform_stack=experiment-sequential`, and the active
cluster name so analysis can compare the explicit time windows instead.

### 2.3 Equivalent resource ceiling

Both architectures are bound to the same maximum CPU and memory budget.
Total compute capacity is identical; only the way that capacity is
distributed across processes differs. This is the foundation of fairness
for RQ2 (resource efficiency).

---

## 3. High-Level Topology

The benchmark runs in one AWS region (`ap-southeast-1`) and uses one shared
VPC. The repository supports two explicit infrastructure modes:

- **Parallel mode** uses `infra/terraform/experiment` and runs two isolated EKS
  clusters plus two isolated RDS instances side by side.
- **Sequential mode** uses `infra/terraform/experiment-sequential` and runs one
  EKS cluster plus one RDS instance, with only one architecture active at a
  time.

The detailed Mermaid version for both modes lives in
`docs/diagrams/cloud-architecture.md`.

### 3.1 Parallel Mode Topology

Parallel mode is the preferred topology when vCPU quota is sufficient. It keeps
monolith and microservices isolated by cluster, database instance, Kubernetes
context, and Datadog cluster name.

```text
AWS account: ap-southeast-1

  Manual persistent resources
  ------------------------------------------------------------
  ECR: skripsi/* images
  S3 : benchmark result bucket

  Terraform shared stack: infra/terraform/shared
  ------------------------------------------------------------
  Shared VPC
  Shared private subnets for EKS nodes and RDS
  Shared public subnets for ELB and NAT
  Shared k6 runner IAM role

  Terraform experiment stack: infra/terraform/experiment
  ------------------------------------------------------------

  +-------------------------------+     +-------------------------------+
  | EKS: skripsi-monolith         |     | EKS: skripsi-msa              |
  |                               |     |                               |
  | app-nodes                     |     | app-nodes                     |
  | - 2 x c8i.2xlarge             |     | - 2 x c8i.2xlarge             |
  | - namespace: mono             |     | - namespace: msa              |
  | - monolith pod(s)             |     | - api-gateway                 |
  |                               |     | - auth-service                |
  | testing-nodes                 |     | - item-service                |
  | - 1 x c8i-flex.large          |     | - transaction-service         |
  | - namespace: benchmark        |     |                               |
  | - k6 runner Job               |     | testing-nodes                 |
  |                               |     | - 1 x c8i-flex.large          |
  | namespace: datadog            |     | - namespace: benchmark        |
  | - Datadog Agent DaemonSet     |     | - k6 runner Job               |
  | - cluster: skripsi-monolith    |     |                               |
  +---------------+---------------+     | namespace: datadog            |
                  |                     | - Datadog Agent DaemonSet     |
                  |                     | - cluster: skripsi-msa         |
                  |                     +---------------+---------------+
                  |                                     |
                  v                                     v
  +-------------------------------+     +-------------------------------+
  | RDS: skripsi-monolith-postgres|     | RDS: skripsi-msa-postgres     |
  | - mono_db                     |     | - auth_db                     |
  +-------------------------------+     | - item_db                     |
                                        | - transaction_db              |
                                        +-------------------------------+

  Operator laptop
  ------------------------------------------------------------
  make, terraform, kubectl, helm

  Datadog SaaS
  ------------------------------------------------------------
  Metrics, traces, logs, HPA behavior, RDS metrics where enabled
```

The parallel architecture deliberately keeps the two clusters as twins:

- same node group sizes,
- same node instance types,
- same ResourceQuota,
- same scaling configuration,
- same Datadog Agent configuration,
- same kubectl deployment flow.

The only differences are the workload they host (monolith vs four MSA
services) and the database scope they serve.

### 3.2 Sequential Mode Topology

Sequential mode is the quota-constrained topology. It keeps the same app-node
and testing-node shape as a single architecture in parallel mode, but it does
not keep both full architecture stacks active at once.

```text
AWS account: ap-southeast-1

  Manual persistent resources
  ------------------------------------------------------------
  ECR: skripsi/* images
  S3 : benchmark result bucket

  Terraform shared stack: infra/terraform/shared
  ------------------------------------------------------------
  Shared VPC
  Shared private subnets for EKS nodes and RDS
  Shared public subnets for ELB and NAT
  Shared k6 runner IAM role

  Terraform sequential stack: infra/terraform/experiment-sequential
  ------------------------------------------------------------

  +-----------------------------------------------------------+
  | EKS: skripsi-benchmark                                   |
  |                                                           |
  | app-nodes                                                 |
  | - 2 x c8i.2xlarge                                         |
  | - namespace: mono                                         |
  | - monolith pod(s), active only during monolith phase       |
  |                                                           |
  | - namespace: msa                                          |
  | - api-gateway, auth-service, item-service, transaction-svc |
  | - active only during microservices phase                   |
  |                                                           |
  | testing-nodes                                             |
  | - 1 x c8i-flex.large                                      |
  | - namespace: benchmark                                    |
  | - db bootstrap, seed, and k6 runner Job                    |
  |                                                           |
  | namespace: datadog                                        |
  | - Datadog Agent DaemonSet                                 |
  | - cluster: skripsi-benchmark                               |
  +----------------------------+------------------------------+
                               |
                               v
  +-----------------------------------------------------------+
  | RDS: skripsi-benchmark-postgres                           |
  | - mono_db                                                  |
  | - auth_db                                                  |
  | - item_db                                                  |
  | - transaction_db                                           |
  +-----------------------------------------------------------+

  Sequential benchmark phase order
  ------------------------------------------------------------
  1. Deploy active architecture
  2. Scale inactive architecture to zero
  3. Run migration job for active architecture
  4. Run seed job for active architecture
  5. Run k6 for active architecture
  6. Upload result artifacts to S3
  7. Wait ARCHITECTURE_SWITCH_DELAY, default 300 seconds
  8. Repeat for the next architecture

  Operator laptop
  ------------------------------------------------------------
  make, terraform, kubectl, helm

  Datadog SaaS
  ------------------------------------------------------------
  Metrics and traces are compared by explicit metadata windows, not by
  overlapping wall-clock execution.
```

The active deploy script scales the inactive architecture to zero before
migration, seed, and benchmark execution. This avoids silent CPU contention and
keeps the active architecture's application ceiling aligned with the parallel
mode ceiling.

---

## 4. Resource Ownership Model

Cloud resources fall into two clearly separated lifecycle groups. This
separation prevents accidental destruction of long-lived bootstrap
resources during normal experiment teardown.

### 4.1 Persistent (manual via AWS CLI)

These resources outlive any single benchmark cycle. They are created once
and reused across every experiment run.

| Resource | Created by | Lives across teardown |
|---|---|---|
| S3 results bucket | `make aws-create-s3` | Yes |
| ECR repositories | `make aws-create-ecr` | Yes |

Rationale: benchmark artifacts in S3 are the primary thesis data and must
never be lost during infrastructure churn. Container images in ECR are
expensive to rebuild and version-tagged, so they are also persistent.

### 4.2 Ephemeral (Terraform-managed)

These resources are tied to one experiment session. They are provisioned
before a benchmark and destroyed afterwards.

| Resource | Created by | Lives across teardown |
|---|---|---|
| VPC, subnets, NAT, route tables | `infra/terraform/shared` | No |
| IAM role for k6 runner S3 access | `infra/terraform/shared` | No |
| EKS cluster — monolith | `infra/terraform/experiment` | No |
| EKS cluster — msa | `infra/terraform/experiment` | No |
| RDS instance — monolith | `infra/terraform/experiment` | No |
| RDS instance — msa | `infra/terraform/experiment` | No |
| EKS cluster — sequential benchmark | `infra/terraform/experiment-sequential` | No |
| RDS instance — sequential benchmark | `infra/terraform/experiment-sequential` | No |

Rationale: clusters and databases are expensive to keep idle. They should
exist only during active benchmark sessions. Terraform handles them as a
disposable unit.

### 4.3 Why Terraform reads shared via local state

```text
infra/terraform/
├── shared/              ← writes terraform.tfstate locally
├── experiment/          ← reads ../shared/terraform.tfstate
└── experiment-sequential/ ← reads ../shared/terraform.tfstate
```

`experiment` consumes `vpc_id`, `private_subnet_ids`, and
`k6_runner_role_arn` from the `shared` stack via
`terraform_remote_state` with the `local` backend. No remote state bucket
is required because the workflow runs from a single operator laptop.

If the project later needs multi-operator workflows or CI automation,
remote state can be introduced without changing the resource model.

---

## 5. Network Architecture

### 5.1 VPC Layout

```text
VPC: 10.0.0.0/16

  Availability Zone A (ap-southeast-1a)
    Public subnet  : 10.0.101.0/24   (NAT gateway, ELB)
    Private subnet : 10.0.1.0/24     (EKS nodes, RDS)

  Availability Zone B (ap-southeast-1b)
    Public subnet  : 10.0.102.0/24   (ELB)
    Private subnet : 10.0.2.0/24     (EKS nodes, RDS)

  NAT gateway: single NAT in one AZ (cost optimization for benchmark)
```

The VPC spans two Availability Zones for EKS subnet requirements. Both
clusters use the same private subnets — they are isolated at the
Kubernetes namespace and cluster level, not at the network level.

A single NAT gateway is used instead of one per AZ. This reduces cost
during benchmark experiments and is acceptable because the workload is
short-lived and the AZ failure mode is not under test.

### 5.2 Public vs Private Placement

```text
Public subnets   : Internet-facing load balancers, NAT gateway
Private subnets  : EKS worker nodes, RDS instances
```

- EKS worker nodes have **no public IPs**. They reach the internet only
  through the NAT gateway (for image pulls from public registries during
  initial bootstrap if needed, and for Datadog SaaS endpoints).
- RDS instances are **never publicly accessible**. The only inbound rule
  on their security group permits port 5432 from the EKS node security
  group of the same cluster.
- The EKS API server endpoint is public-access enabled to allow the
  operator laptop to reach `kubectl` without a bastion. This is acceptable
  for a benchmark experiment but would require restriction in production.

### 5.3 Network Security

```text
Component                        Inbound rule
─────────────────────────────────────────────────────────────────────
EKS API server (managed by AWS)  Allowed from operator IAM identity
EKS node security group          From self (intra-cluster), from ALB
RDS A security group             Port 5432 from monolith node SG only
RDS B security group             Port 5432 from msa node SG only
S3 bucket                        Public access blocked
```

Cross-cluster network access is **not allowed**. The monolith cluster
cannot reach the MSA cluster's RDS, and vice versa. This enforces the
isolation principle even at the network layer.

---

## 6. Compute Layer (EKS)

### 6.1 Node Group Layout

Each cluster has two node groups:

```text
app-nodes            testing-nodes
──────────────       ─────────────
2× c8i.2xlarge      1× c8i-flex.large
8 vCPU each         2 vCPU
16 GiB each         8 GiB
labels:            labels:
  node-group=app     node-group=testing
no taints          taint:
                     workload=benchmark:NoSchedule
```

The taint on `testing-nodes` ensures application pods cannot land there.
The k6 runner Job tolerates this taint, so it runs only on testing-nodes.
This separation prevents the load generator from competing for CPU with
the system under test, which would distort latency measurements.

### 6.2 Namespace Layout per Cluster

Each cluster has three namespaces:

```text
Cluster A: skripsi-monolith        Cluster B: skripsi-msa
─────────────────────────────      ─────────────────────────────
mono              ← workload       msa               ← workload
benchmark         ← k6 runner      benchmark         ← k6 runner
datadog           ← observability  datadog           ← observability
```

The MSA cluster does not have a `mono` namespace, and the monolith
cluster does not have an `msa` namespace. The `local-database` namespace
exists in the namespace YAML for convenience but is not used in EKS
because the database is RDS, not in-cluster.

### 6.3 Workload Placement

```text
                    ┌─────────────────────┐
                    │ Pod scheduling rule │
                    └──────────┬──────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
nodeSelector            no nodeSelector         tolerations
 node-group=app          (rejected from         workload=benchmark
                          tainted node)          (allows testing)
        │                                              │
        ▼                                              ▼
   app-nodes                                    testing-nodes
   (monolith /                                  (k6 runner only)
    MSA services)
```

Application Deployments use:

```yaml
nodeSelector:
  node-group: app
```

The k6 benchmark Job uses both:

```yaml
nodeSelector:
  node-group: testing
tolerations:
  - key: workload
    value: benchmark
    effect: NoSchedule
```

This explicit placement is essential. It guarantees that:

1. application pods never share CPU with the load generator,
2. the load generator never accidentally scales the application,
3. resource measurements per node group are clean and interpretable.

### 6.4 Resource Ceiling and Scaling Modes

Both clusters enforce the same resource ceiling via Kubernetes
`ResourceQuota` at the workload namespace level:

```text
mono namespace                  msa namespace
─────────────                   ─────────────
requests.cpu    : 15800m        requests.cpu    : 15800m
requests.memory : 27648Mi       requests.memory : 27648Mi
limits.cpu      : 15800m        limits.cpu      : 15800m
limits.memory   : 27648Mi       limits.memory   : 27648Mi
```

Two scaling modes are supported. The choice depends on the research
question being answered.

#### Fixed-replica mode

Used for clean RQ1 comparisons. No autoscaling, replicas stay at the
configured count throughout the benchmark.

```text
Monolith: 2 pods with fixed role-neutral budget inside one deployment
MSA:      4 pods with role-aware requests/limits (one pod per service)
```

The MSA fixed-mode baseline uses one replica per service with the same
per-service requests and limits used in HPA mode. The fairness boundary is the
shared namespace ResourceQuota ceiling, not equal per-pod slices.

#### HPA mode

Used for RQ2 with scaling behavior analysis.

```text
Monolith HPA           MSA HPA (one per service)
────────────           ─────────────────────────
minReplicas    : 1     minReplicas    : 1 per service
maxReplicas    : 4     maxReplicas    : role-aware
target CPU     : 70%   target CPU     : 70%
```

In HPA mode, the MSA profile uses role-aware per-service budgets under the same
shared architecture ceiling:

- `api-gateway`: request `250m`, limit `500m`, maxReplicas `4`
- `auth-service`: request `500m`, limit `1000m`, maxReplicas `4`
- `item-service`: request `250m`, limit `500m`, maxReplicas `6`
- `transaction-service`: request `850m`, limit `1700m`, maxReplicas `4`

This keeps fairness at the same `15800m CPU / 27648Mi memory` namespace ceiling
while allowing hotspot services such as `auth-service` and
`transaction-service` to consume more of the
remaining headroom.

All HPA objects set `behavior.scaleDown.stabilizationWindowSeconds: 60` so
post-benchmark scale-in is more responsive than the Kubernetes default
downscale stabilization window.

See `docs/experiment/scaling-mode-strategy.md` for the full scaling
contract and the `K6_PROFILE` ↔ manifest convention.

---

## 7. Database Layer (RDS)

In parallel mode, each cluster has its own RDS instance. They are completely
independent — different VPC security groups, different subnet groups, different
DNS endpoints.

```text
RDS A (monolith)                RDS B (msa)
────────────────────────        ────────────────────────
identifier:                     identifier:
  skripsi-monolith-postgres       skripsi-msa-postgres
engine: PostgreSQL 18           engine: PostgreSQL 18
instance class: db.t3.micro     instance class: db.t3.micro
storage: 20-50 GiB gp3          storage: 20-50 GiB gp3
multi-AZ: false                 multi-AZ: false
public access: false            public access: false
backup retention: 0 days        backup retention: 0 days

databases:                      databases:
  ├─ bootstrap  (idle)            ├─ bootstrap  (idle)
  └─ mono_db                      ├─ auth_db
                                  ├─ item_db
                                  └─ transaction_db
```

In sequential mode, one RDS instance (`skripsi-benchmark-postgres`) hosts the
same logical databases:

```text
bootstrap
mono_db
auth_db
item_db
transaction_db
```

Each RDS instance starts with a `bootstrap` database. The actual
application databases are created later by the `db-bootstrap-job`
Kubernetes Job during deployment. This decouples Terraform (provisions
the engine) from application bootstrap (creates the schemas).

Backup retention is set to 0 because benchmark data is expendable. The
test dataset is regenerated by seed jobs before every benchmark.

---

## 8. Observability Layer (Datadog)

A single Datadog SaaS account observes both clusters. They are separated
by tags rather than by Datadog org.

### 8.1 Datadog Agent Topology

Each cluster runs the Datadog stack via Helm with a different
`clusterName` value:

```text
Cluster A (skripsi-monolith)        Cluster B (skripsi-msa)
─────────────────────────────       ─────────────────────────────
clusterName: skripsi-monolith       clusterName: skripsi-msa
tags:                               tags:
  - env:benchmark                     - env:benchmark
  - architecture:monolith             - architecture:microservices
  - project:skripsi-benchmark         - project:skripsi-benchmark

Datadog Agent (DaemonSet)           Datadog Agent (DaemonSet)
  └─ on every node                    └─ on every node
Datadog Cluster Agent (1 pod)       Datadog Cluster Agent (1 pod)
```

Both Agents send to the same Datadog account. Dashboards filter by
`cluster_name` or `architecture` to separate or compare the two.

### 8.2 Telemetry Channels

```text
Application pod                          Datadog Agent (same node)
─────────────────                        ─────────────────────────
APM trace ──────────────► TCP 8126 ────► dd-trace-agent
                                                │
DD_AGENT_HOST=status.hostIP                     │
DD_TRACE_AGENT_PORT=8126                        ▼
                                          Datadog SaaS
k6 runner pod                            ───────────
─────────────                                   ▲
DogStatsD UDP ────────────► UDP 8125 ───────────┤
                                                │
metrics tagged with:                            │
  run_id, attempt,                              │
  architecture,                                 │
  benchmark_scenario                            │

Datadog Agent itself collects:                  │
  - Kubernetes pod metrics (kube-state-metrics) │
  - process metrics                             │
  - container logs (containerCollectAll)        │
  - HPA replica counts                          │
                                                │
                       all flow ────────────────┘
```

`DD_AGENT_HOST=status.hostIP` is critical. It tells the application to
send traces to the Datadog Agent on the **same node**, not to a Service.
This requires the Agent DaemonSet to be present on every node where
application pods can be scheduled, which is the default for DaemonSets.

### 8.3 Tagging Strategy

Three tag layers correlate the data:

| Tag | Set by | Visible on |
|---|---|---|
| `cluster_name` | Helm values | All Datadog telemetry from that cluster |
| `architecture` | Pod label + DD_TAGS | APM traces, container metrics |
| `env` | Pod label `tags.datadoghq.com/env` | APM traces |
| `service` | Pod label `tags.datadoghq.com/service` | APM traces |
| `version` | Pod label `tags.datadoghq.com/version` | APM traces |
| `run_id`, `attempt`, `benchmark_scenario` | k6 runner CLI tags | DogStatsD metrics |

This makes it possible to ask Datadog questions like:

- "Show CPU usage where `architecture:monolith` and `env:benchmark`."
- "Compare p95 latency for `architecture:monolith` vs
  `architecture:microservices` during `run_id:eks-run-001`."

---

## 9. Data Flow During a Benchmark Run

The diagram below shows what happens end-to-end when the operator runs
`make run-benchmark-parallel`.

```text
┌────────────────────────── Operator laptop ──────────────────────────┐
│                                                                      │
│   make run-benchmark-parallel SCENARIO=login TARGET_RPS=1000 ...    │
│                                                                      │
│              │                              │                        │
│   kubectl --context=monolith    kubectl --context=msa                │
│   apply k6 Job (with sed       apply k6 Job (with sed                │
│   patch for env vars)          patch for env vars)                   │
│                                                                      │
└──────┬───────────────────────────────┬───────────────────────────────┘
       │                               │
       ▼                               ▼
┌──── Cluster A ────┐          ┌──── Cluster B ────┐
│                   │          │                   │
│  k6 Job created   │          │  k6 Job created   │
│  (testing-nodes)  │          │  (testing-nodes)  │
│      │            │          │      │            │
│      │ HTTP       │          │      │ HTTP       │
│      ▼            │          │      ▼            │
│  monolith Service │          │  api-gateway      │
│  (mono ns)        │          │  Service (msa ns) │
│      │            │          │      │            │
│      ▼            │          │      ▼ gRPC       │
│  monolith pod     │          │  ┌─ auth-svc      │
│      │            │          │  ├─ item-svc      │
│      │ pgx        │          │  └─ tx-svc        │
│      ▼            │          │      │            │
│  RDS A (mono_db)  │          │      ▼ pgx        │
│                   │          │  RDS B (3 dbs)    │
│                   │          │                   │
│  Telemetry:       │          │  Telemetry:       │
│   APM → Agent     │          │   APM → Agent     │
│   StatsD → Agent  │          │   StatsD → Agent  │
└────────┬──────────┘          └────────┬──────────┘
         │                              │
         │ Datadog Agent uploads        │
         ▼                              ▼
   ┌──────────────────────────────────────┐
   │        Datadog SaaS                  │
   │  cluster_name=skripsi-monolith       │
   │  cluster_name=skripsi-msa            │
   └──────────────────────────────────────┘

         │                              │
         │ k6 run finishes              │
         │ runner uploads via aws s3 sync (EKS Pod Identity)
         ▼                              ▼
   ┌──────────────────────────────────────┐
   │  S3 (skripsi-benchmark-results)      │
   │   experiments/                       │
   │     <run_id>/                        │
   │       monolith/<scenario>/           │
   │         <rps>rps/<attempt>/          │
   │           summary.json               │
   │           raw.json.gz                │
   │           metadata.json              │
   │           datadog-time-window.json   │
   │       msa/<scenario>/...             │
   └──────────────────────────────────────┘
```

### 9.1 Step-by-step Narrative

1. The operator runs one Make target.
2. The script applies two k6 Jobs in parallel — one to each cluster — via
   `kubectl --context=...`. The Jobs start within seconds of each other,
   producing aligned Datadog time windows.
3. Each k6 Job lands on `testing-nodes` because of its nodeSelector and
   toleration. It immediately starts the `run-k6.sh` orchestrator.
4. `run-k6.sh` records the time window start, builds metadata, and runs
   `k6` against the in-cluster `BASE_URL` for the architecture (monolith
   Service or api-gateway Service).
5. During the run, three telemetry streams flow into Datadog from each
   cluster: APM traces from app pods, real-time k6 metrics via DogStatsD,
   and Kubernetes/host metrics from kube-state-metrics and the process
   agent.
6. When `k6 run` completes, the orchestrator records the time window end
   and writes `datadog-time-window.json`.
7. The runner uses EKS Pod Identity to upload all artifacts to S3 under
   `experiments/<run_id>/<architecture>/<scenario>/<rps>rps/<attempt>/`.
8. The Make target waits for both Jobs to finish via `kubectl wait`.

The only correlation point between k6 client output and Datadog
server-side data is the time window. That window is recorded explicitly
in both `metadata.json` and `datadog-time-window.json`, so analysis can
always recover it.

---

## 10. Identity and Access

### 10.1 IAM model

```text
mufied-admin (IAM user)
   │  Used by operator laptop
   │  Permissions: Admin (manages all AWS resources)
   │
   ▼ Manages
   ├─ ECR repositories (manual via AWS CLI)
   ├─ S3 results bucket (manual via AWS CLI)
   ├─ Terraform state (local on laptop)
   └─ EKS, RDS, VPC (via Terraform)


skripsi-k6-runner (IAM role)
   │  Used by k6 runner pods in both clusters
   │  Permissions: S3 PutObject/GetObject/ListBucket on results bucket
   │
   ▼ Assumed via
EKS Pod Identity association
   │  namespace: benchmark
   │  serviceAccount: k6-runner
   │  cluster: skripsi-monolith AND skripsi-msa
```

EKS Pod Identity replaces the older IRSA (IAM Roles for Service Accounts)
mechanism. It works by attaching the IAM role directly to the
ServiceAccount, with no OIDC trust dance and no annotations.

The k6 runner ServiceAccount itself has no Kubernetes RBAC permissions —
the Kubernetes API is not used during benchmark runs. Only AWS S3 access
is needed, and that comes via the IAM role.

### 10.2 Datadog credentials

The Datadog API key lives in a Kubernetes Secret named `datadog-secret`
in the `datadog` namespace of each cluster. The Secret is created by
`scripts/create-datadog-secret.sh` and consumed by the Datadog Agent
Helm chart via `apiKeyExistingSecret: datadog-secret`.

The script accepts a `KUBE_CONTEXT` environment variable so the secret
is created in the correct cluster — this is critical because the script
is called once per cluster during deploy.

---

## 11. Software Lifecycle and Workflow

The full deployment ordering is mandatory. Steps cannot be reordered.

```text
┌──────────────────────────────────────────────────────────────┐
│  ONE-TIME SETUP (per AWS account)                             │
│                                                                │
│  1. make aws-create-s3       Create results bucket            │
│  2. make aws-create-ecr      Create ECR repositories          │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  PER EXPERIMENT SESSION                                       │
│                                                                │
│  3. make ecr-push-all              Build & push all images    │
│  4. make eks-render-manifests      Optional manifest preflight│
│  5. make terraform-auth-check      Verify TF auth bridge      │
│  6. make eks-shared-apply          Provision VPC + IAM        │
│  7. make eks-apply                 Provision both clusters    │
│  8. make eks-setup-contexts        Configure kubectl aliases  │
│  9. (create K8s Secrets manually)  See benchmark-runbook      │
│ 10. make eks-deploy-monolith       Bootstrap monolith cluster │
│ 11. make eks-deploy-msa            Bootstrap MSA cluster      │
│ 12. make datadog-install-eks-monolith                         │
│ 13. make datadog-install-eks-msa                              │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  PER BENCHMARK SCENARIO                                       │
│                                                                │
│ 14. (reset + seed both clusters)                              │
│ 15. make run-benchmark-parallel    Run k6 on both clusters    │
│ 16. (verify S3 artifacts)                                     │
└──────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│  END OF EXPERIMENT SESSION                                    │
│                                                                │
│ 17. make eks-destroy-confirmed     Destroy clusters + RDS     │
│ 18. make eks-shared-destroy        Destroy VPC + IAM          │
│                                                                │
│  Persistent resources (ECR, S3) are NOT destroyed.            │
└──────────────────────────────────────────────────────────────┘
```

The reason image build/push happens before Terraform apply is to keep
EKS deployment troubleshooting separate from image build issues. By the
time clusters exist, all images are already in ECR, so a deployment
failure is unambiguous: it cannot be an image problem.

The reason image stamping remains tied to the pushed `IMAGE_TAG` is that the
rendered manifests must point to the same tag that was just published to ECR.
The EKS deploy scripts now rerun `eks-render-manifests` automatically before
validation and apply, which removes the operator footgun of forgetting the
manual render step while keeping the rendered manifests aligned with the
intended tag.

The reason `terraform-auth-check` runs before Terraform apply is to verify the
bridge between interactive `aws login` sessions and Terraform-compatible
credentials. The repository standard is a local `terraform-process` AWS
profile backed by `credential_process`, which keeps credentials short-lived and
avoids storing static keys in repository files.

---

## 12. Scaling Mode and Research Question Mapping

The cloud architecture supports two distinct scaling configurations to
serve different parts of the research:

| Goal | `SCALING_MODE` | `K6_PROFILE` | Deployment mode source |
|---|---|---|---|
| RQ1 + RQ2 core (clean) | `fixed` | `steady` | `overlays/fixed` |
| RQ1 + RQ2 with HPA narrative | `hpa` | `hpa` | `overlays/hpa` |

In fixed mode, the cluster runs with one pod per workload unit. CPU and
memory are observable via Datadog and answer RQ2 cleanly. Latency, RPS,
and error rate from k6 answer RQ1 cleanly.

In HPA mode, the cluster autoscales each Deployment based on CPU
utilization. This adds another dimension: RQ2 can include the granular
scaling advantage of microservices (only the hot service scales),
constrained by the namespace ResourceQuota.

See `docs/experiment/scaling-mode-strategy.md` for the full operator
contract.

---

## 13. Cost Profile

Approximate cost planning must be refreshed against the live AWS Pricing
Calculator because the app-node baseline is now `c8i.2xlarge`. The previous
illustrative `t3.xlarge` totals are no longer valid for budgeting.

| Component | Per cluster | Two clusters |
|---|---|---|
| EKS control plane | $0.10 | $0.20 |
| app-nodes (2× c8i.2xlarge) | recalculate live | recalculate live |
| testing-nodes (1× c8i-flex.large) | ~$0.09 | ~$0.18 |
| RDS (db.t3.micro) | recalculate live | recalculate live |
| **Total active** | **recalculate live** | **recalculate live** |

Persistent costs:

```text
S3 results bucket : storage cost only (a few GiB at most)
ECR repositories  : storage cost only (a few GiB per tag)
NAT gateway       : ~$0.045/hour while VPC exists
```

A typical experiment session — provision, run all scenarios at multiple
RPS levels, destroy — still takes 3–4 hours, but the live hourly total must
be recomputed for the new `c8i.2xlarge` baseline before final budgeting.

---

## 14. Reproducibility

The architecture is designed so that another researcher can rebuild the
entire experiment from the repository alone.

The reproducibility chain is:

```text
Git commit
   │ contains application code, manifests, Terraform, scripts, docs
   │
   ▼
make ecr-push-all
   │ builds images tagged with the git short SHA
   │ produces image_tag in metadata.json
   │
   ▼
make eks-apply + deploy
   │ provisions identical infrastructure
   │ image tag flows into deployment manifests
   │
   ▼
make run-benchmark-parallel
   │ k6 record run_id, attempt, image, scenario, rps, time window
   │ writes everything to metadata.json
   │
   ▼
S3 artifact (immutable per attempt)
   │ summary.json, raw.json.gz, metadata.json
   │ datadog-time-window.json
   │
   ▼
Thesis analysis
   │ Python notebooks read S3 artifacts
   │ Datadog dashboards filter by tags from metadata
```

`metadata.json` is the join key. Every other artifact references it.

---

## 15. Limitations and Out of Scope

### 15.1 Single-region

The architecture runs in one AWS region. Multi-region deployment, data
sovereignty, and disaster recovery are out of scope.

### 15.2 Single-AZ NAT

A single NAT gateway is used for cost reasons. AZ failure during a
benchmark run would interrupt the experiment. This is acceptable because
benchmark sessions are short and can be rerun.

### 15.3 No CI/CD

Image build, terraform apply, and benchmark execution are operator-driven
on a single laptop. Automation is intentionally not introduced because it
would add a separate axis of complexity that does not improve thesis
reproducibility.

### 15.4 No Datadog dashboard JSON in repo

Datadog dashboard definitions are not yet exported to JSON. Dashboard
construction is documented in `docs/infrastructure/datadog-dashboard-design.md`
but is created manually in the Datadog UI for now.

### 15.5 No automated pgx tracing

The current `dd-trace-go` integration does not include automatic pgx
query spans. Database operations appear as part of the parent application
span. RDS-side metrics are not yet integrated with Datadog because that
requires additional IAM and Datadog AWS integration setup.

These limitations are documented and do not block the primary RQ1 and
RQ2 analyses.

---

## 16. Source-of-Truth References

| Topic | Authoritative document |
|---|---|
| Detailed cluster design | `docs/infrastructure/eks-cluster-design.md` |
| Terraform runbook | `docs/infrastructure/terraform-runbook.md` |
| End-to-end benchmark runbook | `docs/infrastructure/benchmark-runbook-end-to-end.md` |
| Parallel benchmark execution | `docs/infrastructure/parallel-benchmark-runbook.md` |
| Scaling mode policy | `docs/experiment/scaling-mode-strategy.md` |
| Datadog setup | `docs/infrastructure/datadog.md` |
| Datadog dashboards | `docs/infrastructure/datadog-dashboard-design.md` |
| Database schema | `docs/development/database-schema.md` |
| Image build/push | `docs/deployment/codebuild-ecr.md` |
| Secret management | `docs/infrastructure/secret-management.md` |
| RQ1 methodology | `docs/research-questions/rq1-performance-analysis.md` |
| RQ2 methodology | `docs/research-questions/rq2-resource-efficiency-analysis.md` |
| Budget shutdown | `docs/infrastructure/aws-budget-shutdown.md` |

This document is the architectural overview. For commands, exact YAML,
or step-by-step operator instructions, consult the specific documents
above.

---

## 17. Budget Safety Net

To prevent runaway costs from idle benchmark infrastructure, an automated
budget shutdown system is deployed alongside the shared infrastructure via the
`aws-budget` Terraform module.

```text
AWS Budget monitors monthly cost
    │
    ├── 50%, 80%, 95% → email warnings
    └── 100% → SNS → Lambda → nuclear shutdown
```

When the budget threshold is reached, the Lambda function automatically:

1. deletes both EKS clusters and their node groups,
2. stops both RDS instances,
3. deletes the NAT Gateway and releases associated Elastic IPs.

This reduces monthly idle cost to approximately $3–4 (stopped RDS storage, S3, and ECR).

Configuration is in `infra/terraform/shared/terraform.tfvars`:

```hcl
budget_amount            = 30
budget_threshold_percent = 100
budget_alert_emails      = ["you@email.com"]
```

Budget is deployed automatically with `make eks-shared-apply`. Alternatively,
it can be set up manually via AWS CLI — see
`docs/infrastructure/aws-budget-shutdown.md` for both options.

S3 bucket and ECR repositories are created separately via `make aws-create-s3`
and `make aws-create-ecr`. They are not managed by Terraform, so no conflict
with the shared stack.

Full documentation: `docs/infrastructure/aws-budget-shutdown.md`.
