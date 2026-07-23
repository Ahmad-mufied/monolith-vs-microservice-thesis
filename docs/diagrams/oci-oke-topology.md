# Oracle Cloud Infrastructure (OCI / OKE) Topology Diagrams

This document contains the complete infrastructure topology diagrams for Oracle Cloud Infrastructure (OCI) using Oracle Container Engine for Kubernetes (OKE).

---

## 1. Sequential Benchmark Topology (Active Implementation)

```mermaid
flowchart TB
  operator[Operator laptop<br/>make, terraform, kubectl, helm]
  dockerhub[(Docker Hub public<br/>docker.io/ahmadmufied/*)]
  s3[(AWS S3<br/>s3://skripsi-benchmark-results)]
  dd[(Datadog SaaS<br/>us5.datadoghq.com)]

  subgraph vcn[OCI Virtual Cloud Network: 10.0.0.0/16]
    api_subnet[K8s API Subnet<br/>10.0.0.0/28]
    worker_subnet[Worker Subnet<br/>10.0.10.0/24]
    db_subnet[Private DB Subnet<br/>10.0.4.0/24]
    sec_list[Security Lists & Route Tables]
  end

  subgraph benchmark_cluster[OKE Cluster: skripsi-oci-sequential]
    app_pool[app-nodes<br/>1 x VM.Standard.E5.Flex<br/>4 OCPUs / 8 vCPUs / 16 GB RAM]
    test_pool[testing-nodes<br/>1 x VM.Standard.E5.Flex<br/>1 OCPU / 2 vCPUs / 4 GB RAM]
    mono_phase[namespace mono<br/>active during monolith phase]
    msa_phase[namespace msa<br/>active during MSA phase]
    bench[namespace benchmark<br/>k6 + bootstrap jobs]
    agent[Datadog Agent DaemonSet<br/>namespace datadog]
  end

  pg[(OCI Compute VM: 10.0.4.206<br/>PostgreSQL 18<br/>mono_db + auth_db + item_db + transaction_db)]

  operator -->|terraform apply| vcn
  operator -->|terraform apply| benchmark_cluster
  operator -->|deploy monolith phase| mono_phase
  operator -->|deploy MSA phase| msa_phase
  
  worker_subnet --- benchmark_cluster
  db_subnet --- pg
  sec_list --- pg
  dockerhub -->|pull images| benchmark_cluster
  
  mono_phase -->|private VCN 10.0.4.206| pg
  msa_phase -->|private VCN 10.0.4.206| pg
  bench -->|HTTP load| mono_phase
  bench -->|HTTP load| msa_phase
  bench -->|upload results| s3
  agent --> dd
```

---

## 2. Component Network Mapping Table

| Component Name | Subnet / Network | Internal IP Range | Security Rules |
|---|---|---|---|
| OKE K8s Control Plane | `k8s-api-subnet` | `10.0.0.0/28` | HTTPS (6443) for kubectl control |
| OKE Worker Nodes (`app-nodes`, `testing-nodes`) | `worker-subnet` | `10.0.10.0/24` | Internal pod overlay traffic & NAT egress |
| Dedicated PostgreSQL VM | `db-subnet` | `10.0.4.206` | Port 5432 ingress from `10.0.10.0/24`, Port 22 SSH |
| Docker Hub Registry | External Public | `docker.io` | Egress HTTPS via NAT Gateway |
| AWS S3 Result Bucket | External Public | `s3.ap-southeast-1.amazonaws.com` | Egress HTTPS via NAT Gateway |
| Datadog Observability SaaS | External Public | `us5.datadoghq.com` | Egress HTTPS via NAT Gateway |

---

## 3. End-to-End Execution Flow Sequence Diagram

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator
  participant TF as Terraform OCI Stack
  participant OKE as OKE Cluster (10.0.10.0/24)
  participant PG as PostgreSQL VM (10.0.4.206)
  participant DH as Docker Hub
  participant K6 as k6 Job
  participant S3 as AWS S3
  participant DD as Datadog SaaS

  Op->>DH: Push images (ahmadmufied/*)
  Op->>TF: make env-init PLATFORM=oci EXECUTION_MODE=sequential
  Op->>TF: make oci-apply
  TF->>OKE: Create OKE Cluster & Node Pools (app 4 OCPU, testing 1 OCPU)
  TF->>PG: Provision PostgreSQL VM (2 OCPU, 8 GB RAM)
  Op->>OKE: make oci-create-secrets (inject 10.0.4.206, gRPC ports)
  Op->>OKE: helm upgrade --install datadog
  Op->>K6: make run-benchmark-suite SCALING_MODE=fixed
  
  Note over OKE,PG: Phase 1: Monolith Benchmark Phase
  K6->>OKE: Scale down MSA, relabel node (architecture=monolith)
  K6->>PG: Reset & Seed mono_db
  K6->>OKE: Rollout monolith pod
  K6->>OKE: Execute k6 HTTP load
  OKE->>PG: SQL traffic over 10.0.4.206
  OKE->>DD: Telemetry & APM Traces
  K6->>S3: Upload monolith result artifacts

  Note over OKE,PG: Phase 2: Microservices Benchmark Phase
  K6->>OKE: Scale down monolith, relabel node (architecture=msa)
  K6->>PG: Reset & Seed auth_db, item_db, transaction_db
  K6->>OKE: Rollout api-gateway, auth, item, transaction pods
  K6->>OKE: Execute k6 HTTP load
  OKE->>PG: SQL traffic over 10.0.4.206
  OKE->>DD: Telemetry & APM Traces
  K6->>S3: Upload MSA result artifacts
```
