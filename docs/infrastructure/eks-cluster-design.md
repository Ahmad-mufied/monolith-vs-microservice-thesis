# EKS Cluster Design — Parallel and Sequential Topologies

## 1. Purpose

This document describes the EKS cluster designs used for the thesis benchmark
experiment.

Two separate EKS clusters run in parallel to eliminate resource contention
between the monolith and microservices architectures and to produce aligned
Datadog time-series for direct comparison.

A quota-constrained sequential topology is also available. It uses one EKS
cluster and one RDS instance, then runs monolith and microservices phases one
after another. See `docs/infrastructure/sequential-benchmark-runbook.md`.

---

## 2. Topology

```text
AWS ap-southeast-1
│
├── Shared VPC (10.0.0.0/16)
│   ├── Private subnets: 10.0.1.0/24, 10.0.2.0/24
│   └── Public subnets:  10.0.101.0/24, 10.0.102.0/24
│
├── Cluster A: skripsi-monolith
│   ├── app-nodes      (2× c8i.2xlarge)  → mono namespace
│   ├── testing-nodes  (1× c8i-flex.large)   → benchmark namespace
│   └── RDS A: skripsi-monolith-postgres
│       └── mono_db
│
├── Cluster B: skripsi-msa
│   ├── app-nodes      (2× c8i.2xlarge)  → msa namespace
│   ├── testing-nodes  (1× c8i-flex.large)   → benchmark namespace
│   └── RDS B: skripsi-msa-postgres
│       ├── auth_db
│       ├── item_db
│       └── transaction_db
│
├── Shared ECR (skripsi/*)
├── Shared S3  (skripsi-benchmark-results-*)
└── Shared Datadog account (two cluster_name tags)
```

Sequential topology:

```text
AWS ap-southeast-1
│
├── Shared VPC (10.0.0.0/16)
│
├── Cluster: skripsi-benchmark
│   ├── app-nodes      (2× c8i.2xlarge)     → mono or msa active workload
│   ├── testing-nodes  (1× c8i-flex.large)  → benchmark namespace
│   └── RDS: skripsi-benchmark-postgres
│       ├── mono_db
│       ├── auth_db
│       ├── item_db
│       └── transaction_db
│
├── Shared ECR
├── Shared S3
└── Shared Datadog account (cluster_name=skripsi-benchmark)
```

---

## 3. Why Two Clusters

Running both architectures in one cluster introduces shared resource
contention:

- CPU and memory on `app-nodes` are shared between monolith and MSA pods
- RDS receives load from both architectures simultaneously
- Node pressure from one architecture can affect the other

Two isolated clusters eliminate these variables. Each architecture gets
dedicated compute, dedicated database, and dedicated network paths.

Additional benefit: both k6 jobs start at the same time, so Datadog
time-series for CPU, memory, latency, and replica count are aligned and
can be overlaid directly in dashboards.

Sequential mode intentionally trades that wall-clock alignment for lower
footprint. It is valid only because the deploy workflow keeps one architecture
active at a time and stores `execution_mode=sequential` plus the Datadog time
window in benchmark metadata.

---

## 4. Node Groups

Each cluster has two node groups:

### app-nodes

```text
instance type : c8i.2xlarge (8 vCPU, 16 GiB)
count         : 2
label         : node-group=app
taint         : none
purpose       : application pods (monolith or MSA services) on the stronger
                x86 benchmark baseline
```

### testing-nodes

```text
instance type : c8i-flex.large (2 vCPU, 4 GiB)
count         : 1
label         : node-group=testing
taint         : workload=benchmark:NoSchedule
purpose       : k6 runner Job
```

The taint on testing-nodes prevents application pods from being scheduled
there. k6 Job manifests include the matching toleration.

For the microservices architecture, pod anti-affinity is used to spread service
pods across the 2 app nodes. Each MSA service deployment includes a soft
preference to avoid co-location with other MSA services on the same node. This
prevents CPU-heavy services (e.g. `auth-service`) from monopolizing a single
node. See `docs/infrastructure/deployment-strategy.md` section 12a for details.

---

## 5. RDS Split

Each cluster has its own RDS instance.

| Cluster | RDS identifier | Databases |
|---|---|---|
| skripsi-monolith | skripsi-monolith-postgres | `mono_db` |
| skripsi-msa | skripsi-msa-postgres | `auth_db`, `item_db`, `transaction_db` |
| skripsi-benchmark | skripsi-benchmark-postgres | `mono_db`, `auth_db`, `item_db`, `transaction_db` |

RDS configuration:

```text
engine         : PostgreSQL 18
instance class : db.t3.micro by default
storage        : 20 GiB gp3 (max 50 GiB)
multi-AZ       : disabled
public access  : disabled
deletion protection : disabled
final snapshot : skipped
```

The monolith cluster RDS only needs `mono_db`. The MSA cluster RDS only
needs the three MSA databases. This keeps each RDS focused on its
architecture's workload.

---

## 6. Shared Resources

The following resources are shared between both clusters:

| Resource | Name | How created | Purpose |
|---|---|---|---|
| VPC | skripsi-vpc | Terraform (shared) | Network for both clusters |
| IAM role | skripsi-k6-runner | Terraform (shared) | S3 access for k6 via EKS Pod Identity |
| ECR | skripsi/* | Manual (persistent) | Container image registry |
| S3 | skripsi-benchmark-results | Manual (persistent) | Benchmark result storage |
| Datadog account | — | Manual | Observability for both clusters |

ECR and S3 are created manually because they are persistent resources that
must survive `terraform destroy`. They are created once and reused across
all experiment runs.

---

## 7. Datadog Multi-Cluster

Both clusters send telemetry to the same Datadog account. They are
distinguished by the `cluster_name` tag set in the Helm values:

| Cluster | `cluster_name` | `architecture` tag |
|---|---|---|
| skripsi-monolith | `skripsi-monolith` | `architecture:monolith` |
| skripsi-msa | `skripsi-msa` | `architecture:microservices` |
| skripsi-benchmark | `skripsi-benchmark` | active app pods keep their architecture tag |

Application pods also carry `env:benchmark` via Unified Service Tagging,
which aligns with the k6 runner `DATADOG_ENV=benchmark`.

This allows Datadog dashboards to filter by `cluster_name`, `architecture`,
`service`, `env`, and `run_id` independently.

---

## 8. kubectl Context Management

After `terraform apply`, configure kubectl contexts:

```bash
make eks-setup-contexts
```

This runs:

```bash
aws eks update-kubeconfig --name skripsi-monolith --region ap-southeast-1 --alias monolith
aws eks update-kubeconfig --name skripsi-msa      --region ap-southeast-1 --alias msa
```

All subsequent kubectl commands use `--context=monolith` or `--context=msa`
to target the correct cluster.

Sequential mode uses:

```bash
make eks-setup-context-sequential
```

This creates the `benchmark` context for `skripsi-benchmark`.

---

## 9. Cost Estimate

Cost must be recalculated against the live AWS Pricing Calculator before each
measured run because the app-node baseline is now `c8i.2xlarge` instead of the
older `t3.xlarge`.

| Component | Per cluster | Two clusters |
|---|---|---|
| EKS control plane | $0.10 | $0.20 |
| app-nodes (2× c8i.2xlarge) | recalculate live | recalculate live |
| testing-nodes (1× c8i-flex.large) | $0.09 | $0.18 |
| RDS db.t3.micro | recalculate live | recalculate live |
| **Total** | **recalculate live** | **recalculate live** |

A typical benchmark session (provision + deploy + 3 scenarios × 2 RPS
levels + destroy) still takes approximately 3–4 hours, but the cost budget
must be recomputed for the new `c8i.2xlarge` baseline before running the
final measured series.

---

## 10. Terraform Structure

```text
infra/terraform/
├── shared/                    ← VPC, IAM (apply once, local state)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── modules/
│   └── benchmark-cluster/     ← reusable EKS + RDS module
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── experiment/                ← instantiates two clusters (local state)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
└── experiment-sequential/     ← instantiates one cluster (local state)
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

ECR repositories and S3 results bucket are **not** managed by Terraform.
They are created once via `make aws-create-ecr` and `make aws-create-s3`.

Apply order:

```bash
# 1. Shared resources (once per AWS account)
make eks-shared-apply

# 2. Both clusters
make eks-apply

# Alternative: one sequential cluster
make eks-sequential-apply
```

Both stacks use local Terraform state. The `experiment` stack reads shared
outputs from `infra/terraform/shared/terraform.tfstate` via
`terraform_remote_state` with the `local` backend. Both stacks must be
applied from the same laptop.

---

## 11. Deployment Manifests

EKS-specific manifests are in `deployments/k8s/eks/` and differ from
Minikube manifests in three ways:

| Difference | Minikube | EKS |
|---|---|---|
| `DD_ENV` | `minikube` | `benchmark` |
| `imagePullPolicy` | `Never` | `Always` |
| `nodeSelector` | none | `node-group: app` |

All other configuration (resources, probes, secrets) is identical.
