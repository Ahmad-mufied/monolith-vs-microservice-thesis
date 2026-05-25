# Cloud Architecture Diagram

This diagram summarizes the final AWS benchmark topology. It focuses on the
resource boundaries that matter for the thesis comparison: isolated runtime
clusters, equivalent app capacity, separate RDS instances, shared persistent
artifacts, and shared observability.

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
        subgraph experimentTf["Experiment stack resources"]
          subgraph monoCluster["EKS cluster: skripsi-monolith"]
            monoAppNodes["app-nodes<br/>2 x c8i.xlarge<br/>node-group=app"]
            monoTesting["testing-nodes<br/>1 x t3.large<br/>node-group=testing<br/>taint workload=benchmark"]
            monoNs["namespace: mono<br/>monolith pod(s)"]
            monoBench["namespace: benchmark<br/>k6 runner job"]
            monoDD["namespace: datadog<br/>Datadog Agent DaemonSet"]
          end

          monoRds["RDS PostgreSQL 18<br/>skripsi-monolith-postgres<br/>mono_db"]

          subgraph msaCluster["EKS cluster: skripsi-msa"]
            msaAppNodes["app-nodes<br/>2 x c8i.xlarge<br/>node-group=app"]
            msaTesting["testing-nodes<br/>1 x t3.large<br/>node-group=testing<br/>taint workload=benchmark"]
            msaNs["namespace: msa<br/>api-gateway, auth, item, transaction"]
            msaBench["namespace: benchmark<br/>k6 runner job"]
            msaDD["namespace: datadog<br/>Datadog Agent DaemonSet"]
          end

          msaRds["RDS PostgreSQL 18<br/>skripsi-msa-postgres<br/>auth_db, item_db, transaction_db"]
        end
      end
    end
  end

  operator -->|"terraform apply / destroy"| terraformManaged
  operator -->|"build and push images"| ecr
  operator -->|"kubectl / helm deploy"| monoCluster
  operator -->|"kubectl / helm deploy"| msaCluster

  ecr -->|"pull images"| monoNs
  ecr -->|"pull images"| msaNs
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

## Notes

- S3 and ECR are persistent resources and are not destroyed by Terraform.
- VPC and the k6 IAM role come from the shared Terraform stack.
- EKS clusters, node groups, and RDS instances come from the experiment
  Terraform stack.
- Application pods run on `app-nodes`; k6 runner jobs run on `testing-nodes`.
- The two clusters are intentionally isolated so monolith and microservices do
  not compete for runtime resources during parallel benchmark runs.
