# Vultr VKE Topology

These diagrams describe the Vultr Kubernetes Engine infrastructure path for the
thesis benchmark.

## Parallel Benchmark Topology

```mermaid
flowchart TB
  operator[Operator laptop<br/>make, terraform, kubectl, helm]
  dockerhub[(Docker Hub public<br/>benchmark images)]
  s3[(AWS S3<br/>benchmark artifacts)]
  dd[(Datadog SaaS<br/>metrics, traces, logs)]

  subgraph shared[Vultr shared stack]
    vpc[Legacy Vultr VPC<br/>10.20.0.0/16]
    fw[PostgreSQL firewall group]
    ssh[Operator SSH key]
  end

  subgraph mono_cluster[VKE: skripsi-vultr-monolith]
    mono_app_pool[app-nodes<br/>1 x voc-c-8c-16gb-150s-amd]
    mono_test_pool[testing-nodes<br/>1 x vc2-2c-4gb]
    mono_ns[namespace mono<br/>monolith pods]
    mono_bench[namespace benchmark<br/>k6 runner jobs]
    mono_dd[Datadog Agent]
  end

  subgraph msa_cluster[VKE: skripsi-vultr-msa]
    msa_app_pool[app-nodes<br/>1 x voc-c-8c-16gb-150s-amd]
    msa_test_pool[testing-nodes<br/>1 x vc2-2c-4gb]
    msa_ns[namespace msa<br/>api-gateway/auth/item/transaction]
    msa_bench[namespace benchmark<br/>k6 runner jobs]
    msa_dd[Datadog Agent]
  end

  mono_pg[(Vultr Compute PostgreSQL 18<br/>mono_db)]
  msa_pg[(Vultr Compute PostgreSQL 18<br/>auth_db + item_db + transaction_db)]

  operator -->|terraform apply| shared
  operator -->|terraform apply| mono_cluster
  operator -->|terraform apply| msa_cluster
  operator -->|kubectl deploy| mono_ns
  operator -->|kubectl deploy| msa_ns

  dockerhub -->|pull images| mono_ns
  dockerhub -->|pull images| msa_ns
  dockerhub -->|pull k6 image| mono_bench
  dockerhub -->|pull k6 image| msa_bench

  vpc --- mono_cluster
  vpc --- msa_cluster
  fw --- mono_pg
  fw --- msa_pg
  ssh --- mono_pg
  ssh --- msa_pg

  mono_ns -->|private VPC| mono_pg
  msa_ns -->|private VPC| msa_pg
  mono_bench -->|HTTP load| mono_ns
  msa_bench -->|HTTP load| msa_ns
  mono_bench -->|upload results| s3
  msa_bench -->|upload results| s3
  mono_dd --> dd
  msa_dd --> dd
```

## Sequential Fallback Topology

```mermaid
flowchart TB
  operator[Operator laptop]
  dockerhub[(Docker Hub public)]
  s3[(AWS S3)]
  dd[(Datadog SaaS)]

  subgraph shared[Vultr shared stack]
    vpc[Legacy Vultr VPC]
    fw[PostgreSQL firewall group]
  end

  subgraph benchmark_cluster[VKE: skripsi-vultr-benchmark]
    app_pool[app-nodes<br/>1 x voc-c-8c-16gb-150s-amd]
    test_pool[testing-nodes<br/>1 x vc2-2c-4gb]
    mono_phase[namespace mono<br/>active during monolith phase]
    msa_phase[namespace msa<br/>active during MSA phase]
    bench[namespace benchmark<br/>k6 + bootstrap jobs]
    agent[Datadog Agent]
  end

  pg[(Vultr Compute PostgreSQL 18<br/>mono_db + auth_db + item_db + transaction_db)]

  operator -->|terraform apply| shared
  operator -->|terraform apply| benchmark_cluster
  operator -->|deploy one architecture at a time| mono_phase
  operator -->|deploy one architecture at a time| msa_phase
  vpc --- benchmark_cluster
  fw --- pg
  dockerhub --> benchmark_cluster
  mono_phase -->|private VPC| pg
  msa_phase -->|private VPC| pg
  bench -->|HTTP load| mono_phase
  bench -->|HTTP load| msa_phase
  bench -->|upload results| s3
  agent --> dd
```

## End-to-End Execution Flow

```mermaid
sequenceDiagram
  participant Op as Operator
  participant TF as Terraform Vultr stacks
  participant VKE as VKE cluster(s)
  participant PG as PostgreSQL VM
  participant DH as Docker Hub
  participant K6 as k6 Job
  participant S3 as AWS S3
  participant DD as Datadog

  Op->>DH: Build and push public images
  Op->>TF: make vultr-render-tfvars
  Op->>TF: make vultr-apply
  Op->>TF: make vultr-apply (execution_mode selects parallel or sequential)
  TF->>VKE: Create app/testing node pools
  TF->>PG: Create PostgreSQL compute VM on legacy VPC
  Op->>VKE: setup kube contexts
  Op->>VKE: create Kubernetes Secrets
  Op->>VKE: measure app-node allocatable baseline
  Op->>VKE: render and deploy fixed or HPA manifests
  VKE->>DH: Pull app and k6 images
  Op->>VKE: verify live fixed/HPA mode
  Op->>K6: run benchmark case or suite
  K6->>VKE: Send HTTP load to active architecture
  VKE->>PG: Application database traffic over private VPC
  VKE->>DD: Datadog Agent emits telemetry
  K6->>S3: Upload summary, raw data, metadata
  Op->>S3: Verify artifacts
  Op->>TF: guarded destroy after S3 verification
```
