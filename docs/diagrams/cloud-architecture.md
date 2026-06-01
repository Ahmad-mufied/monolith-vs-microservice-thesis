# Cloud Architecture Diagram

This document keeps the AWS topology diagrams for both supported benchmark
execution modes in one place:

- **Parallel mode** provisions two isolated EKS clusters and two isolated RDS
  instances so monolith and microservices can run at the same wall-clock time.
- **Sequential mode** provisions one EKS cluster and one RDS instance, then runs
  monolith and microservices one after another for quota-constrained accounts.

Both modes preserve the same application resource ceiling. The difference is
the execution topology, not the benchmark API contract or workload semantics.

## Parallel Mode

Use this mode when the AWS account has enough vCPU quota for both architecture
stacks to be active together. It gives the cleanest Datadog time-series overlay
because monolith and microservices run during the same time window.

```mermaid
flowchart TB
  operator["Operator laptop<br/>kubectl, helm, terraform, make"]
  datadog["Datadog SaaS<br/>metrics, traces, logs"]

  subgraph aws["AWS account - ap-southeast-1"]
    subgraph persistent["Persistent resources - manual"]
      ecr["Amazon ECR<br/>skripsi/* images"]
      s3["Amazon S3<br/>benchmark results"]
    end

    subgraph terraformManaged["Terraform-managed resources"]
      k6Role["Shared IAM role<br/>skripsi-k6-runner<br/>EKS Pod Identity"]

      subgraph vpc["Shared VPC<br/>private app/RDS subnets, public ELB/NAT subnets"]
        subgraph experimentTf["Parallel stack: infra/terraform/experiment"]
          subgraph monoCluster["EKS cluster: skripsi-monolith"]
            monoAppNodes["app-nodes<br/>2 x c8i.2xlarge<br/>node-group=app"]
            monoTesting["testing-nodes<br/>1 x c8i-flex.large<br/>node-group=testing<br/>taint workload=benchmark"]
            monoNs["namespace: mono<br/>monolith pod(s)"]
            monoBench["namespace: benchmark<br/>k6 runner job"]
            monoDD["namespace: datadog<br/>Datadog Agent DaemonSet"]
          end

          monoRds["RDS PostgreSQL 18<br/>skripsi-monolith-postgres<br/>mono_db"]

          subgraph msaCluster["EKS cluster: skripsi-msa"]
            msaAppNodes["app-nodes<br/>2 x c8i.2xlarge<br/>node-group=app"]
            msaTesting["testing-nodes<br/>1 x c8i-flex.large<br/>node-group=testing<br/>taint workload=benchmark"]
            msaNs["namespace: msa<br/>api-gateway, auth-service,<br/>item-service, transaction-service"]
            msaBench["namespace: benchmark<br/>k6 runner job"]
            msaDD["namespace: datadog<br/>Datadog Agent DaemonSet"]
          end

          msaRds["RDS PostgreSQL 18<br/>skripsi-msa-postgres<br/>auth_db, item_db, transaction_db"]
        end
      end
    end
  end

  operator -->|"terraform apply / destroy"| experimentTf
  operator -->|"build and push images"| ecr
  operator -->|"kubectl / helm deploy"| monoCluster
  operator -->|"kubectl / helm deploy"| msaCluster

  ecr -->|"pull app image"| monoNs
  ecr -->|"pull service images"| msaNs
  ecr -->|"pull seed and k6 images"| monoBench
  ecr -->|"pull seed and k6 images"| msaBench

  monoNs -->|"pgx"| monoRds
  msaNs -->|"pgx"| msaRds

  monoBench -->|"HTTP load"| monoNs
  msaBench -->|"HTTP load"| msaNs

  monoBench -->|"assume role"| k6Role
  msaBench -->|"assume role"| k6Role
  k6Role -->|"PutObject / GetObject / ListBucket"| s3

  monoNs -->|"APM traces"| monoDD
  msaNs -->|"APM traces"| msaDD
  monoBench -->|"DogStatsD k6 metrics"| monoDD
  msaBench -->|"DogStatsD k6 metrics"| msaDD
  monoDD --> datadog
  msaDD --> datadog
```

## Sequential Mode

Use this mode when the AWS account cannot keep both full architecture stacks
active at once, for example with a 24 vCPU quota. The same cluster hosts both
namespaces, but only one architecture is active during a benchmark phase. The
runner waits `ARCHITECTURE_SWITCH_DELAY` between phases so Datadog windows are
regular and easier to compare.

```mermaid
flowchart TB
  operator["Operator laptop<br/>kubectl, helm, terraform, make"]
  datadog["Datadog SaaS<br/>metrics, traces, logs"]

  subgraph aws["AWS account - ap-southeast-1"]
    subgraph persistent["Persistent resources - manual"]
      ecr["Amazon ECR<br/>skripsi/* images"]
      s3["Amazon S3<br/>benchmark results"]
    end

    subgraph terraformManaged["Terraform-managed resources"]
      k6Role["Shared IAM role<br/>skripsi-k6-runner<br/>EKS Pod Identity"]

      subgraph vpc["Shared VPC<br/>private app/RDS subnets, public ELB/NAT subnets"]
        subgraph sequentialTf["Sequential stack: infra/terraform/experiment-sequential"]
          subgraph benchmarkCluster["EKS cluster: skripsi-benchmark"]
            seqAppNodes["app-nodes<br/>2 x c8i.2xlarge<br/>node-group=app"]
            seqTesting["testing-nodes<br/>1 x c8i-flex.large<br/>node-group=testing<br/>taint workload=benchmark"]
            monoNs["namespace: mono<br/>monolith pod(s)<br/>active only in monolith phase"]
            msaNs["namespace: msa<br/>api-gateway, auth-service,<br/>item-service, transaction-service<br/>active only in microservices phase"]
            benchNs["namespace: benchmark<br/>db bootstrap, seed, k6 runner job"]
            seqDD["namespace: datadog<br/>Datadog Agent DaemonSet"]
          end

          seqRds["RDS PostgreSQL 18<br/>skripsi-benchmark-postgres<br/>mono_db, auth_db, item_db, transaction_db"]
          switchDelay["Architecture switch delay<br/>ARCHITECTURE_SWITCH_DELAY<br/>default 300 seconds"]
        end
      end
    end
  end

  operator -->|"terraform apply / destroy"| sequentialTf
  operator -->|"build and push images"| ecr
  operator -->|"kubectl / helm deploy active architecture"| benchmarkCluster

  ecr -->|"pull app image"| monoNs
  ecr -->|"pull service images"| msaNs
  ecr -->|"pull seed and k6 images"| benchNs

  monoNs -->|"pgx during monolith phase"| seqRds
  msaNs -->|"pgx during microservices phase"| seqRds

  benchNs -->|"HTTP load: monolith phase"| monoNs
  monoNs -->|"scale to zero before switch"| switchDelay
  switchDelay -->|"deploy and seed next phase"| msaNs
  benchNs -->|"HTTP load: microservices phase"| msaNs

  benchNs -->|"assume role"| k6Role
  k6Role -->|"PutObject / GetObject / ListBucket"| s3

  monoNs -->|"APM traces when active"| seqDD
  msaNs -->|"APM traces when active"| seqDD
  benchNs -->|"DogStatsD k6 metrics"| seqDD
  seqDD --> datadog
```

## Notes

- S3 and ECR are persistent resources and are not destroyed by Terraform.
- VPC and the k6 IAM role come from the shared Terraform stack.
- Parallel mode uses `infra/terraform/experiment`; sequential mode uses
  `infra/terraform/experiment-sequential`.
- Application pods run on `app-nodes`; k6 runner jobs run on `testing-nodes`.
- Parallel mode isolates monolith and microservices by cluster and RDS instance.
- Sequential mode isolates benchmark phases by scaling the inactive architecture
  to zero before migration, seed, and k6 execution.
- Do not keep both experiment stacks active under a constrained vCPU quota; use
  the switching flow in `docs/diagrams/sequential-parallel-topology.md`.
