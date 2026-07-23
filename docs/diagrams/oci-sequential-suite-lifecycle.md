# OCI Sequential Suite Lifecycles & Diagrams — Complete Reference

This document describes the active OCI sequential benchmark suite lifecycles (`make run-benchmark-suite` and `make run-benchmark-case`). It covers lifecycle steps, Mermaid flowcharts, data setup rules, recovery behaviors, and S3 result status caching.

---

## 1. Dual-Architecture Sequential Suite (`make run-benchmark-suite`)

The dual-architecture sequential suite is the primary entry point for comparing Monolith and Microservices under identical resource ceilings on OCI OKE.

### 1.1 Mermaid Lifecycle Flowchart

```mermaid
flowchart TB
  start(["Operator starts fixed suite<br/>make run-benchmark-suite<br/>SCALING_MODE=fixed K6_PROFILE=steady"])
  dispatch["operator-dispatch.sh<br/>select sequential dual-arch suite runner"]
  matrix["Build benchmark matrix<br/>SCENARIO_RPS_MATRIX or<br/>SCENARIOS + RPS_LEVELS"]
  preflight["Suite preflight<br/>validate env, S3 access,<br/>Kubernetes context, image tag"]
  manifest["Upload suite manifest<br/>s3://bucket/experiments/run_id/_suite/manifest.json"]
  s3Cache["Warm up S3 result-status cache<br/>prime_case_result_status_cache"]

  archLoop{"Next architecture phase<br/>monolith or microservices"}
  pendingArch{"Any pending case<br/>missing result-status.json?"}
  skipArch["Skip architecture deploy<br/>all cases already exist in S3"]
  deployArch["Deploy architecture<br/>relabel app node (monolith/msa)<br/>scale inactive namespace down"]

  scenarioLoop{"Next scenario<br/>(login, create-transaction, enriched-transactions)"}
  setupOnce["Run scenario setup<br/>reset + seed database"]

  rpsLoop{"Next target RPS<br/>(25, 50, 100, 200, 300, 400, 500)"}
  s3Case{"Case result already<br/>exists in S3?"}
  skipCase["Skip measured run<br/>reuse stored result classification"]
  singleCase["Execute k6 benchmark job"]
  upload["Upload attempt artifacts to S3<br/>summary, raw.json.gz, metadata, thresholds"]
  interDelay["Sleep INTER_CASE_DELAY (120s)"]
  switchDelay["Sleep ARCHITECTURE_SWITCH_DELAY (300s)"]
  summary["Upload suite summary to S3"]

  start --> dispatch --> matrix --> preflight --> manifest --> s3Cache --> archLoop
  archLoop -->|monolith phase| pendingArch
  archLoop -->|microservices phase| pendingArch
  pendingArch -->|all cases exist| skipArch --> archLoop
  pendingArch -->|has pending cases| deployArch --> scenarioLoop
  scenarioLoop --> setupOnce --> rpsLoop
  rpsLoop --> s3Case
  s3Case -->|exists| skipCase --> rpsLoop
  s3Case -->|missing| singleCase --> upload --> interDelay --> rpsLoop
  rpsLoop -->|scenario complete| scenarioLoop
  scenarioLoop -->|arch complete| switchDelay --> archLoop
  archLoop -->|suite complete| summary
```

---

## 2. Single-Case Benchmark Execution (`make run-benchmark-case`)

```mermaid
flowchart TB
  startCase(["Operator runs single case<br/>make run-benchmark-case ARCHITECTURE=... SCENARIO=... TARGET_RPS=..."])
  casePreflight["Case preflight<br/>validate env, S3, context"]
  deployTarget["Deploy target architecture<br/>relabel app node (monolith/msa)<br/>scale down inactive namespace"]
  dbSetup["Reset & seed PostgreSQL database"]
  createJob["Create k6 Kubernetes job<br/>namespace benchmark"]
  waitJob["Wait for k6 job completion"]
  uploadS3["Upload attempt artifacts to AWS S3"]
  printStatus["Print RESULT_STATUS_JSON summary"]

  startCase --> casePreflight --> deployTarget --> dbSetup --> createJob --> waitJob --> uploadS3 --> printStatus
```

---

## 3. Recovery & Retry Rules

1. **S3 Result Caching**: If a case's `result-status.json` already exists in S3 under `s3://skripsi-benchmark-results/experiments/{run_id}/{architecture}/{scenario}/{rps}rps/attempt-01/`, the suite runner skips execution to preserve time and compute.
2. **Dynamic Node Relabeling**: Prior to starting workloads for an architecture, nodes labeled `node-group=app` are automatically relabeled with `architecture=monolith` or `architecture=msa` to prevent pod scheduling deadlocks.
3. **Guarded Infrastructure Teardown**: Infrastructure is never destroyed automatically unless `AUTO_DESTROY_CONFIRMED=true` is explicitly provided and all S3 artifacts pass validation checks.
