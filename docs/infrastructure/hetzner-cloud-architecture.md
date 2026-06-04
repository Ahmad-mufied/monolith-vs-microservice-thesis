# Hetzner Cloud Architecture

## Purpose

This document describes the Hetzner Cloud benchmark path kept as an alternate
or historical benchmark environment. It is not the final thesis benchmark path.

The benchmark semantics remain unchanged:

- same REST and gRPC application behavior,
- same monolith and microservices architecture boundaries,
- same k6 scenarios,
- same AWS S3 artifact layout,
- same Datadog analysis model.

Only the infrastructure substrate changes.

Current final-thesis decision:

- Bab 4 final evidence uses Vultr Kubernetes Engine (VKE).
- Historical EKS and Hetzner preparation or partial runs are not part of the
  final thesis dataset unless explicitly labeled as non-final evidence.
- If Hetzner is used again, fixed and HPA measurements must be rerun fully in
  Hetzner and reported separately from Vultr VKE results.

## Provider Split

```text
Hetzner Cloud:
  - k3s Kubernetes clusters
  - private network
  - app worker nodes
  - k6 testing nodes
  - PostgreSQL 18 VM nodes

AWS:
  - S3 benchmark result bucket

Docker Hub:
  - public container images for Hetzner runs

Datadog:
  - metrics, traces, logs, HPA behavior
```

## Sequential Topology

Sequential mode is the first Hetzner implementation target.

```text
skripsi-hetzner-benchmark
  control-plane : 1 x CCX13
  app-nodes     : 2 x CCX43
  testing-node  : 1 x CCX23
  postgres-node : 1 x CCX33

namespaces:
  mono
  msa
  benchmark
  datadog
```

Only one architecture is active during a measured sequential phase.

## Parallel Topology

Parallel mode restores the current preferred aligned-time-series model.

```text
skripsi-hetzner-monolith
  control-plane : 1 x CCX13
  app-nodes     : 2 x CCX43
  testing-node  : 1 x CCX23
  postgres-node : 1 x CCX33
  database      : mono_db

skripsi-hetzner-msa
  control-plane : 1 x CCX13
  app-nodes     : 2 x CCX43
  testing-node  : 1 x CCX23
  postgres-node : 1 x CCX33
  databases     : auth_db, item_db, transaction_db
```

The monolith and MSA stacks do not share app nodes, Kubernetes contexts, or
PostgreSQL VM capacity.

## Kubernetes Scheduling Contract

The app manifests stay portable by keeping the same labels and taints used by
the EKS manifests.

```text
app nodes:
  label: node-group=app

testing nodes:
  label: node-group=testing
  taint: workload=benchmark:NoSchedule

control plane:
  taint: node-role.kubernetes.io/control-plane=:NoSchedule
```

Application workloads must not run on control-plane or testing nodes. k6 jobs
must run on testing nodes.

## Resource Baseline

Hetzner uses a measurement-derived resource baseline.

After the cluster is created, run:

```bash
make hetzner-measure-resource-baseline
```

The measurement captures app-node allocatable CPU and memory, subtracts safety
margin, and writes:

```text
env/hetzner-resource-baseline.env
env/hetzner-resource-baseline.json
```

Rendered Hetzner manifests use this generated quota. Monolith and MSA must
always receive the same CPU and memory ceiling.

The quota is provider-native. It is not clamped back to the older EKS
`15800m / 27648Mi` ceiling. Fairness is preserved by applying the same
generated ceiling to both architectures within Hetzner.

## Security

PostgreSQL is private-network only. AWS S3 credentials for k6 are stored in
Kubernetes Secrets and must be scoped to the benchmark bucket or prefix. Docker
Hub public images must not include secrets, kubeconfigs, Terraform state, or env
files.
