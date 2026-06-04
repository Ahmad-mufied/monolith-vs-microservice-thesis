# Cloud Architecture Diagram

This document contains topology diagrams for both the original AWS EKS plan
and the active Vultr implementation.

Both infrastructure paths preserve the same application resource ceiling. The
difference is the hosting platform, not the benchmark API contract or workload
semantics.

---

## AWS EKS — Parallel Mode (Original Plan)

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
        subgraph experimentTf["Parallel stack: infra/terraform/aws-parallel"]
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

## AWS EKS — Sequential Mode (Original Plan)

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
        subgraph sequentialTf["Sequential stack: infra/terraform/aws-sequential"]
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

## AWS Notes

- S3 and ECR are persistent resources and are not destroyed by Terraform.
- VPC and the k6 IAM role come from the shared Terraform stack.
- Parallel mode uses `infra/terraform/aws-parallel`; sequential mode uses
  `infra/terraform/aws-sequential`.
- Application pods run on `app-nodes`; k6 runner jobs run on `testing-nodes`.
- Parallel mode isolates monolith and microservices by cluster and RDS instance.
- Sequential mode isolates benchmark phases by scaling the inactive architecture
  to zero before migration, seed, and k6 execution.
- Do not keep both `aws-parallel` and `aws-sequential` active under a
  constrained vCPU quota; use the switching flow in
  `docs/diagrams/sequential-parallel-topology.md`.

---

## Vultr VKE — Parallel Mode (Active Implementation)

The active implementation uses Vultr VKE instead of Amazon EKS, and
self-managed PostgreSQL on Vultr Compute VM instead of Amazon RDS.

```mermaid
flowchart TB
  operator["Operator laptop<br/>kubectl, terraform, make"]
  dockerhub["Docker Hub<br/>public benchmark images"]
  datadog["Datadog SaaS<br/>metrics, traces, logs"]
  s3["AWS S3<br/>benchmark artifacts"]

  subgraph vultr["Vultr account - sgp (Singapore)"]
    subgraph shared["Shared stack: infra/terraform/vultr-shared"]
      vpc["Legacy VPC Network<br/>10.20.0.0/16"]
      ssh["Operator SSH key"]
      fw["PostgreSQL firewall group"]
    end

    subgraph parallel["Parallel stack: infra/terraform/vultr-parallel"]
      subgraph monoCluster["VKE: skripsi-vultr-monolith"]
        monoAppNodes["app-nodes<br/>2 x voc-c-16c-32gb-300s<br/>node-group=app"]
        monoTesting["testing-nodes<br/>1 x vc2-4c-8gb<br/>node-group=testing<br/>taint workload=benchmark"]
        monoNs["namespace: mono<br/>monolith pod(s)"]
        monoBench["namespace: benchmark<br/>k6 runner job"]
        monoDD["Datadog Agent DaemonSet"]
      end

      monoPg["Vultr Compute VM<br/>PostgreSQL 18<br/>mono_db"]

      subgraph msaCluster["VKE: skripsi-vultr-msa"]
        msaAppNodes["app-nodes<br/>2 x voc-c-16c-32gb-300s<br/>node-group=app"]
        msaTesting["testing-nodes<br/>1 x vc2-4c-8gb<br/>node-group=testing<br/>taint workload=benchmark"]
        msaNs["namespace: msa<br/>api-gateway, auth-service,<br/>item-service, transaction-service"]
        msaBench["namespace: benchmark<br/>k6 runner job"]
        msaDD["Datadog Agent DaemonSet"]
      end

      msaPg["Vultr Compute VM<br/>PostgreSQL 18<br/>auth_db, item_db, transaction_db"]
    end
  end

  operator -->|"terraform apply / destroy"| parallel
  operator -->|"docker push"| dockerhub
  operator -->|"kubectl deploy"| monoCluster
  operator -->|"kubectl deploy"| msaCluster

  dockerhub -->|"pull app images"| monoNs
  dockerhub -->|"pull service images"| msaNs
  dockerhub -->|"pull k6 image"| monoBench
  dockerhub -->|"pull k6 image"| msaBench

  monoNs -->|"pgx via VPC private IP"| monoPg
  msaNs -->|"pgx via VPC private IP"| msaPg

  monoBench -->|"HTTP load"| monoNs
  msaBench -->|"HTTP load"| msaNs

  monoBench -->|"upload results"| s3
  msaBench -->|"upload results"| s3

  monoDD --> datadog
  msaDD --> datadog
  monoNs -->|"APM traces"| monoDD
  msaNs -->|"APM traces"| msaDD
```

## Vultr VKE — Sequential Mode (Active Fallback)

```mermaid
flowchart TB
  operator["Operator laptop"]
  dockerhub["Docker Hub"]
  datadog["Datadog SaaS"]
  s3["AWS S3"]

  subgraph vultr["Vultr account - sgp"]
    subgraph shared["Shared stack"]
      vpc["Legacy VPC Network<br/>10.20.0.0/16"]
      fw["PostgreSQL firewall group"]
    end

    subgraph sequential["Sequential stack: infra/terraform/vultr-sequential"]
      subgraph benchmarkCluster["VKE: skripsi-vultr-benchmark"]
        appPool["app-nodes<br/>2 x voc-c-16c-32gb-300s<br/>node-group=app"]
        testPool["testing-nodes<br/>1 x vc2-4c-8gb<br/>node-group=testing<br/>taint workload=benchmark"]
        monoNs["namespace: mono<br/>active during monolith phase"]
        msaNs["namespace: msa<br/>active during MSA phase"]
        benchNs["namespace: benchmark<br/>k6 + bootstrap jobs"]
        agent["Datadog Agent DaemonSet"]
      end

      pgVm["Vultr Compute VM<br/>PostgreSQL 18<br/>mono_db, auth_db,<br/>item_db, transaction_db"]
    end
  end

  operator -->|"terraform apply"| sequential
  operator -->|"docker push"| dockerhub
  operator -->|"deploy one arch at a time"| benchmarkCluster

  dockerhub -->|"pull images"| benchmarkCluster

  monoNs -->|"pgx via VPC during monolith phase"| pgVm
  msaNs -->|"pgx via VPC during MSA phase"| pgVm

  benchNs -->|"HTTP load: monolith phase"| monoNs
  benchNs -->|"HTTP load: MSA phase"| msaNs
  benchNs -->|"upload results"| s3
  agent --> datadog
```

## Vultr Notes

- Docker Hub replaces Amazon ECR for container images.
- PostgreSQL runs on Vultr Compute VM (self-managed) instead of Amazon RDS.
- Vultr Legacy VPC (not VPC 2.0) is used because VKE requires it.
- PostgreSQL is accessed via VPC private IP only (not publicly exposed).
- AWS S3 and Datadog SaaS remain unchanged.
- For the complete Vultr reference, see `docs/infrastructure/vultr-complete-architecture.md`.
