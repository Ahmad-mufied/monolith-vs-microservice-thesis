# Sequential and Parallel Benchmark Topology Diagram

This diagram shows how the two benchmark execution modes relate to the same
application architecture comparison. Parallel and sequential are execution
topologies, not new application variants. Both must preserve the same external
API, seed data assumptions, resource ceiling, scaling mode, and k6 workload
scripts.

```mermaid
flowchart TB
  operator["Operator laptop<br/>make, terraform, kubectl, helm, aws"]
  ecr["Amazon ECR<br/>skripsi/* immutable image tags"]
  s3["Amazon S3 results bucket<br/>experiments/{run_id}/..."]
  datadog["Datadog SaaS<br/>metrics, traces, logs"]

  subgraph shared["Shared Terraform stack: infra/terraform/aws-shared"]
    vpc["Shared VPC<br/>private app/RDS subnets<br/>public ELB/NAT subnets"]
    k6Role["IAM role: skripsi-k6-runner<br/>EKS Pod Identity for S3 upload"]
    budget["Budget shutdown guardrail<br/>parallel + sequential resource names"]
  end

  operator -->|"make env-init PLATFORM=eks EXECUTION_MODE=parallel<br/>or EXECUTION_MODE=sequential<br/>then make eks-render-tfvars"| shared
  operator -->|"make ecr-push-all IMAGE_TAG=..."| ecr

  subgraph modeChoice["Choose exactly one active experiment topology under tight quota"]
    parallelChoice["Parallel mode<br/>best for wall-clock aligned Datadog series"]
    sequentialChoice["Sequential mode<br/>best for 24 vCPU quota / lower footprint"]
  end

  shared --> modeChoice

  subgraph parallel["Parallel experiment stack: infra/terraform/aws-parallel"]
    monoCluster["EKS: skripsi-monolith<br/>kubectl context: monolith"]
    monoApp["namespace: mono<br/>monolith deployment<br/>Resource ceiling: 15800m CPU / 27648Mi"]
    monoBench["namespace: benchmark<br/>k6 job: k6-benchmark-monolith"]
    monoRds["RDS: skripsi-monolith-postgres<br/>mono_db"]
    monoDD["namespace: datadog<br/>cluster_name=skripsi-monolith"]

    msaCluster["EKS: skripsi-msa<br/>kubectl context: msa"]
    msaApp["namespace: msa<br/>api-gateway, auth-service,<br/>item-service, transaction-service<br/>ResourceQuota: 15800m CPU / 27648Mi"]
    msaBench["namespace: benchmark<br/>k6 job: k6-benchmark-microservices"]
    msaRds["RDS: skripsi-msa-postgres<br/>auth_db, item_db, transaction_db"]
    msaDD["namespace: datadog<br/>cluster_name=skripsi-msa"]
  end

  subgraph sequential["Sequential experiment stack: infra/terraform/aws-sequential"]
    seqCluster["EKS: skripsi-benchmark<br/>kubectl context: benchmark"]
    seqMono["namespace: mono<br/>monolith deployment<br/>active only during monolith phase"]
    seqMsa["namespace: msa<br/>api-gateway, auth-service,<br/>item-service, transaction-service<br/>active only during microservices phase"]
    seqBench["namespace: benchmark<br/>db bootstrap + k6 runner"]
    seqRds["RDS: skripsi-benchmark-postgres<br/>mono_db, auth_db, item_db, transaction_db"]
    seqDD["namespace: datadog<br/>cluster_name=skripsi-benchmark"]
  end

  parallelChoice -->|"make eks-apply"| parallel
  sequentialChoice -->|"make eks-sequential-apply"| sequential

  ecr -->|"pull app images"| monoApp
  ecr -->|"pull app images"| msaApp
  ecr -->|"pull app images"| seqMono
  ecr -->|"pull app images"| seqMsa
  ecr -->|"pull seed + k6 images"| monoBench
  ecr -->|"pull seed + k6 images"| msaBench
  ecr -->|"pull seed + k6 images"| seqBench

  monoApp -->|"pgx"| monoRds
  msaApp -->|"pgx"| msaRds
  seqMono -->|"pgx"| seqRds
  seqMsa -->|"pgx"| seqRds

  monoBench -->|"HTTP load same case window"| monoApp
  msaBench -->|"HTTP load same case window"| msaApp

  subgraph sequentialPhases["Sequential suite phases"]
    phaseA["Phase A<br/>deploy selected architecture<br/>reset + seed<br/>run all scenario/RPS cases"]
    phaseGap["ARCHITECTURE_SWITCH_DELAY<br/>default 300s<br/>clean Datadog separation gap"]
    phaseB["Phase B<br/>deploy the other architecture<br/>reset + seed<br/>run all scenario/RPS cases"]
  end

  seqBench --> phaseA
  phaseA -->|"scale inactive namespace to 0"| phaseGap
  phaseGap --> phaseB
  phaseA -->|"HTTP load when monolith active"| seqMono
  phaseB -->|"HTTP load when MSA active"| seqMsa

  monoBench -->|"assume k6 role"| k6Role
  msaBench -->|"assume k6 role"| k6Role
  seqBench -->|"assume k6 role"| k6Role
  k6Role -->|"PutObject summary/raw/metadata"| s3

  monoDD --> datadog
  msaDD --> datadog
  seqDD --> datadog
  monoApp -->|"APM traces"| monoDD
  msaApp -->|"APM traces"| msaDD
  seqMono -->|"APM traces"| seqDD
  seqMsa -->|"APM traces"| seqDD
  monoBench -->|"DogStatsD k6 metrics"| monoDD
  msaBench -->|"DogStatsD k6 metrics"| msaDD
  seqBench -->|"DogStatsD k6 metrics"| seqDD

  subgraph metadata["Required metadata for analysis"]
    executionMode["execution_mode<br/>parallel or sequential"]
    topologyFields["terraform_stack, cluster_name<br/>architecture_order"]
    delayFields["inter_case_delay_seconds<br/>architecture_switch_delay_seconds<br/>architecture_phases"]
    windowFields["datadog-time-window.json<br/>per measured attempt"]
  end

  s3 --> metadata
  datadog -->|"query by run_id, architecture,<br/>scenario, target_rps, time window"| metadata
```

## Operating Rules

- Parallel mode runs one monolith k6 job and one microservices k6 job together
  for each scenario/RPS case.
- Sequential mode runs one architecture phase at a time on the `benchmark`
  context and records `architecture_phases` in the suite summary.
- `INTER_CASE_DELAY` separates cases inside the same architecture phase.
- `ARCHITECTURE_SWITCH_DELAY` separates monolith and microservices phases for
  cleaner Datadog resource windows.
- Do not keep both `aws-parallel` and `aws-sequential` stacks active under
  tight vCPU quota unless quota and cost have been explicitly reviewed.
- Destroy an active Terraform benchmark stack only after expected S3 artifacts
  have been verified.

## Switching Summary

```text
parallel -> sequential:
  verify S3 artifacts
  make eks-destroy-confirmed
  make terraform-sequential-recovery-check
  make eks-sequential-apply
  make eks-setup-context-sequential
  make eks-create-secrets-sequential

sequential -> parallel:
  verify S3 artifacts
  make eks-sequential-destroy-confirmed
  make terraform-recovery-check
  make eks-apply
  make eks-setup-contexts
  make eks-create-secrets
```
