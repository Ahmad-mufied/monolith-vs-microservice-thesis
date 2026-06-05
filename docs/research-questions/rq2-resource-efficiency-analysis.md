# RQ2 Resource Efficiency Analysis

## 1. Purpose

This document defines the conceptual, methodological, and analytical basis for answering Research Question 2 (RQ2) in the thesis benchmark project.

RQ2 focuses on **resource efficiency**, especially CPU and memory usage, when monolithic and microservices architectures handle equivalent workloads in a cloud-native Kubernetes-based environment.

This document supports:

- Chapter 3 methodology,
- Chapter 4 resource analysis,
- Datadog dashboard interpretation,
- Kubernetes HPA interpretation,
- CPU/memory aggregation rules,
- fairness rules for architecture-level comparison.

---

## 2. Research Question

Final RQ2:

```text
How does CPU and memory resource efficiency compare between monolithic and
microservices architectures?
```

Indonesian thesis version:

```text
Bagaimana perbandingan efisiensi penggunaan sumber daya CPU dan memori antara
arsitektur monolitik dan mikroservis?
```

---

## 3. Position of RQ2 in the Study

RQ2 evaluates the system from the **resource usage perspective**.

It answers:

```text
Which architecture uses CPU and memory more efficiently to handle equivalent workload?
```

RQ2 must be interpreted together with RQ1.

Reason:

```text
Low CPU usage is not automatically efficient if the system fails to reach target
RPS, produces high errors, or drops many iterations.
```

Relationship:

```text
RQ1 = client-observed performance
RQ2 = resource cost needed to produce that performance
```

Final thesis evidence should come from the Vultr Kubernetes Engine (VKE)
benchmark environment. CPU and memory comparisons from local, EKS, or other
provider runs must not be mixed with final Vultr VKE evidence unless explicitly
labeled as non-final or historical.

Diagram:

```text
+-------------------+
| RQ1               |
| latency, target   |
| RPS achievement   |
+---------+---------+
          |
          v
+-------------------+
| performance valid?|
+---------+---------+
          |
          v
+-------------------+
| RQ2               |
| CPU, memory,      |
| efficiency ratio  |
+-------------------+
```

---

## 4. Definition of Resource Efficiency

In this research, resource efficiency is defined as:

```text
The ability of an architecture to serve an equivalent workload with lower CPU
and memory usage while maintaining valid and stable performance.
```

Stable performance means:

```text
throughput achievement is close to target RPS
p90/p95 latency is stable
error rate is low as validation evidence
dropped iterations are low
checks pass
```

Resource efficiency must not be interpreted using CPU or memory alone.

Example:

```text
Architecture A uses lower CPU but has high error rate.
Architecture A is not considered more efficient.

Architecture B uses more CPU but achieves much lower latency and stable RPS.
Architecture B may show a performance-resource trade-off.
```

---

## 5. Main Resource Metrics

Primary RQ2 metrics:

```text
average CPU usage per architecture
p95 CPU usage per architecture
average memory usage per architecture
p95 memory usage per architecture
```

Derived metrics:

```text
RPS per CPU core
CPU core-seconds per 1000 successful requests
Memory MiB per 1000 achieved RPS
throughput achievement per resource ceiling
```

Supporting metrics:

```text
service-level CPU/memory breakdown for MSA
current replicas
desired replicas
HPA target CPU
pod count
pod restart count
Datadog trace latency per service
```

Error rate, checks rate, and dropped iterations remain validation inputs from
RQ1. They are not primary RQ2 metrics, but they prevent false efficiency claims
when an architecture used fewer resources because it did not process the target
workload correctly.

---

## 6. Architecture-Level Resource Comparison

RQ2 is answered at the **architecture level**.

For monolith:

```text
CPU_monolith_total = CPU_monolith
Memory_monolith_total = Memory_monolith
```

For MSA:

```text
CPU_MSA_total =
  CPU_api_gateway
+ CPU_auth_service
+ CPU_item_service
+ CPU_transaction_service
```

```text
Memory_MSA_total =
  Memory_api_gateway
+ Memory_auth_service
+ Memory_item_service
+ Memory_transaction_service
```

Diagram:

```text
Monolith
========

+------------------+
| monolith pod(s)  |
+---------+--------+
          |
          v
CPU_total_monolith
Memory_total_monolith


Microservices
=============

+-------------+     +--------------+     +--------------+     +---------------------+
| api-gateway |     | auth-service |     | item-service |     | transaction-service |
+------+------+     +------+-------+     +------+-------+     +----------+----------+
       |                   |                    |                         |
       +-------------------+--------------------+-------------------------+
                                           |
                                           v
                                  CPU_total_MSA
                                Memory_total_MSA
```

Service-level MSA data is still collected, but it is used for explanation, not as the primary comparison unit.

---

## 7. Resource Budget Fairness

Correct fairness principle:

```text
The total maximum resource ceiling per architecture must be equivalent.
```

Important scope note:

```text
The concrete numerical examples in this section must always be interpreted
relative to the active benchmark configuration. For the active Vultr path, the
shared architecture ceiling is 7800m CPU / 15360Mi memory per architecture.
```

Incorrect design:

```text
monolith = 16000m CPU

api-gateway = 16000m CPU
auth-service = 16000m CPU
item-service = 16000m CPU
transaction-service = 16000m CPU

total MSA = 64000m CPU
```

Correct design:

```text
monolith total ceiling = 7800m CPU / 15360Mi memory

api-gateway + auth-service + item-service + transaction-service
  = total MSA ceiling 7800m CPU / 15360Mi memory
```

Example table:

| Architecture | Component | Replica | CPU Limit per Pod | Memory Limit per Pod | Total CPU | Total Memory |
|---|---:|---:|---:|---:|---:|---:|
| Monolith | monolith | 1 | 7800m | 15360Mi | 7800m | 15360Mi |
| MSA | api-gateway | 1 | 1950m | 3840Mi | 1950m | 3840Mi |
| MSA | auth-service | 1 | 1950m | 3840Mi | 1950m | 3840Mi |
| MSA | item-service | 1 | 1950m | 3840Mi | 1950m | 3840Mi |
| MSA | transaction-service | 1 | 1950m | 3840Mi | 1950m | 3840Mi |
| **MSA Total** | - | - | - | - | **7800m** | **15360Mi** |

Recommended Chapter 3 explanation:

```text
Both architectures are given an equivalent total resource ceiling. In the
microservices architecture, the resource budget is distributed across multiple
deployment units. In the monolithic architecture, the resource budget is assigned
to a single deployment unit. Resource efficiency is compared at the architecture
level using aggregate CPU and memory usage.
```

---

## 8. Idle Service Overhead in MSA

All active MSA services should be included in total MSA resource usage, even if a service is not heavily used by a specific scenario.

Example login path:

```text
k6 -> api-gateway -> auth-service
```

Even though login does not use:

```text
item-service
transaction-service
```

those pods still run and consume baseline CPU/memory.

Interpretation:

```text
Idle service overhead is part of the operational cost of microservices. It must
be included when resource efficiency is evaluated at the architecture level.
```

This is especially important for memory usage, because each service has its own:

```text
runtime process
container memory overhead
connection pool
logger/tracer overhead
Kubernetes pod overhead
```

---

## 9. Relationship with k6

k6 provides controlled external workload.

RQ2 depends on k6 because resource usage only makes sense when tied to a specific load condition.

For each resource analysis, record:

```text
scenario
target RPS
achieved RPS
duration
attempt
dataset version
architecture
```

Mechanism:

```text
k6 scenario
-> request pressure
-> application processing
-> CPU/memory usage
-> Datadog/Kubernetes metrics
-> RQ2 resource efficiency analysis
```

Diagram:

```text
+----------------------+
| k6 scenario          |
| target RPS, duration |
+----------+-----------+
           |
           v
+----------------------+
| Application          |
| monolith or MSA      |
+----------+-----------+
           |
           v
+----------------------+
| CPU/memory behavior  |
+----------+-----------+
           |
           v
+----------------------+
| Datadog/K8s metrics  |
+----------+-----------+
           |
           v
+----------------------+
| RQ2 analysis         |
+----------------------+
```

---

## 10. Relationship with HPA

HPA is not the primary RQ2 metric. It is a mechanism for explaining resource
usage and scaling behavior under autoscaling-enabled execution.

Fixed-replica mode is the primary static-scale RQ2 comparison mode because it
isolates CPU and memory usage under a static deployment configuration.
HPA-enabled mode is reported separately to explain whether autoscaling changes
the performance-resource trade-off.

Mechanism:

```text
k6 target RPS increases
-> CPU utilization increases
-> metrics-server reports CPU metrics
-> HPA calculates desired replicas
-> Kubernetes creates more pods
-> Datadog records CPU, memory, replicas, latency, and errors
```

Diagram:

```text
+----------------------+
| k6 target RPS        |
+----------+-----------+
           |
           v
+----------------------+
| pod CPU utilization  |
+----------+-----------+
           |
           v
+----------------------+
| metrics-server       |
+----------+-----------+
           |
           v
+----------------------+
| HPA controller       |
| desired replicas     |
+----------+-----------+
           |
           v
+----------------------+
| Kubernetes replicas  |
| current replicas     |
+----------------------+
```

HPA helps explain:

```text
whether scaling happened
which deployment scaled
when scaling happened
whether latency stabilized after scaling
whether resource usage increased due to extra replicas
```

But HPA does not replace CPU/memory analysis.

---

## 11. Fixed Replica vs HPA-Enabled Mode

The experiment must clearly label whether it uses fixed replicas or HPA.

For the final thesis analysis:

```text
fixed-replica mode = primary RQ1/RQ2 comparison
HPA-enabled mode   = separately labeled autoscaling analysis
```

### 11.1 Fixed Replica Mode

Characteristics:

```text
replica count is fixed
HPA is disabled
resource budget is static
```

Strengths:

```text
simpler interpretation
fewer confounding variables
easier architecture comparison
```

Suitable for:

```text
primary resource efficiency comparison under fixed resource allocation
```

### 11.2 HPA-Enabled Mode

Characteristics:

```text
HPA is enabled
replica count may change
maximum ceiling is controlled through max replicas and resource limits
```

Strengths:

```text
more cloud-native
shows Kubernetes autoscaling behavior
shows MSA granular scaling
```

Suitable for:

```text
supporting analysis of autoscaling behavior and trade-off changes
```

Risks:

```text
more complex interpretation
scale-up delay may affect latency
results cannot be mixed with fixed-replica results without explicit labeling
```

Rule:

```text
Do not mix fixed-replica and HPA-enabled results in the same primary comparison.
Use HPA results as a separately labeled supporting analysis.
```

If HPA is enabled, it must be applied consistently for both architectures.

---

## 12. Maximum Resource Ceiling vs Actual Resource Usage

When HPA is enabled, two resource concepts must be separated.

### 12.1 Maximum Resource Ceiling

Used for fairness.

Formula:

```text
Monolith maximum CPU ceiling = max_replicas x CPU limit per pod
MSA HPA maximum CPU ceiling  = namespace CPU limit quota
```

Example monolith:

```text
4 replicas x 1950m CPU = 7800m CPU
```

Example MSA:

```text
minimum MSA state     = 4 x 975m = 3900m
shared burst budget   = 4 x 975m = 3900m
namespace CPU ceiling = 7800m
```

### 12.2 Actual Resource Usage

Used for efficiency analysis.

Formula:

```text
Actual CPU MSA = sum observed CPU usage from all MSA service pods
Actual Memory MSA = sum observed memory usage from all MSA service pods
```

HPA explains changes in actual usage over time.

---

## 13. Datadog Role in RQ2

Datadog is the main observability source for RQ2.

It provides:

```text
CPU usage
memory usage
replica count
service-level latency
distributed traces
pod health
logs
HPA-related behavior
```

Datadog should be used to generate:

```text
architecture-level CPU comparison
architecture-level memory comparison
service-level MSA breakdown
HPA current vs desired replica timeline
trace examples for bottleneck explanation
```

Datadog does not replace k6 for external performance numbers.

Correct separation:

```text
k6 explains what the client observed.
Datadog explains why the system behaved that way.
```

---

## 14. Derived Efficiency Metrics

### 14.1 RPS per CPU Core

Formula:

```text
RPS per CPU core = achieved RPS / average CPU cores
```

Interpretation:

```text
Higher is better.
It means more requests are served per CPU core.
```

### 14.2 CPU Core-Seconds per 1000 Successful Requests

Formula:

```text
CPU core-seconds per 1000 successful requests =
(average CPU cores x duration seconds / successful requests) x 1000
```

Interpretation:

```text
Lower is better.
It means less CPU time is spent per 1000 successful requests.
```

### 14.3 Memory MiB per 1000 Achieved RPS

Formula:

```text
Memory MiB per 1000 achieved RPS =
(average memory MiB / achieved RPS) x 1000
```

Interpretation:

```text
Lower is better.
It means lower memory footprint for a given throughput level.
```

---

## 15. Example Calculation

Assume the create-transaction scenario runs for 300 seconds.

| Architecture | Target RPS | Achieved RPS | Successful Requests | Avg CPU | Avg Memory | p95 Latency | Error Rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| Monolith | 1000 | 995 | 298500 | 2.2 cores | 1600Mi | 180ms | 0.2% |
| MSA | 1000 | 990 | 297000 | 2.8 cores | 2500Mi | 240ms | 0.3% |

### 15.1 RPS per CPU Core

Monolith:

```text
995 / 2.2 = 452 RPS/core
```

MSA:

```text
990 / 2.8 = 354 RPS/core
```

Interpretation:

```text
Monolith is more CPU-efficient in this scenario because it serves more requests
per CPU core.
```

### 15.2 CPU Core-Seconds per 1000 Requests

Monolith:

```text
(2.2 x 300 / 298500) x 1000 = 2.21 core-sec / 1000 requests
```

MSA:

```text
(2.8 x 300 / 297000) x 1000 = 2.83 core-sec / 1000 requests
```

Interpretation:

```text
MSA requires more CPU time to process 1000 successful requests in this scenario.
```

### 15.3 Memory Footprint per 1000 RPS

Monolith:

```text
1600 / 995 x 1000 = 1608 MiB / 1000 RPS
```

MSA:

```text
2500 / 990 x 1000 = 2525 MiB / 1000 RPS
```

Interpretation:

```text
MSA has a higher memory footprint because it runs multiple processes and pods.
```

---

## 16. Example Interpretation Cases

### Case 1: Low CPU but High Error Rate

```text
The architecture is not more efficient. Low CPU can occur because the system
failed to process the workload or because k6 could not sustain the intended
arrival rate.
```

### Case 2: Higher CPU but Lower Latency

```text
MSA shows a performance-resource trade-off. It uses more CPU but provides better
latency. It may not be more resource-efficient, but it may provide a performance
advantage under the tested workload.
```

### Case 3: HPA Scales but Latency Remains High

```text
The bottleneck may not be CPU. It may come from database latency, gRPC fan-out,
API Gateway overhead, connection pool limits, or lock contention. Datadog traces
should be used for root-cause explanation.
```

### Case 4: MSA Memory is Higher in All Scenarios

```text
MSA has higher baseline memory overhead because it runs multiple services,
containers, and runtime processes. This overhead is part of the architecture
cost and must be included in RQ2.
```

### Case 5: HPA Stabilizes Latency After Scale-Up

```text
HPA helps stabilize performance after scale-up, but there is transient latency
during the scaling process. This should be explained as autoscaling behavior.
```

---

## 17. Recommended Chapter 4 Tables

### 17.1 Resource Summary Table

| Scenario | Architecture | Target RPS | Achieved RPS | Achievement % | p95 Latency | Validation Status | Avg CPU | P95 CPU | Avg Memory | P95 Memory |
|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|
| login | monolith | ... | ... | ... | ... | ... | ... | ... | ... | ... |
| login | microservices | ... | ... | ... | ... | ... | ... | ... | ... | ... |
| create-transaction | monolith | ... | ... | ... | ... | ... | ... | ... | ... | ... |
| create-transaction | microservices | ... | ... | ... | ... | ... | ... | ... | ... | ... |

### 17.2 Efficiency Metrics Table

| Scenario | Architecture | RPS/Core | CPU Core-sec / 1000 Req | Memory MiB / 1000 RPS | Interpretation |
|---|---|---:|---:|---:|---|
| login | monolith | ... | ... | ... | ... |
| login | microservices | ... | ... | ... | ... |
| create-transaction | monolith | ... | ... | ... | ... |
| create-transaction | microservices | ... | ... | ... | ... |

### 17.3 Microservices Service-Level Breakdown

| Scenario | Service | Avg CPU | P95 CPU | Avg Memory | P95 Memory | Avg Replicas | Max Replicas |
|---|---|---:|---:|---:|---:|---:|---:|
| create-transaction | api-gateway | ... | ... | ... | ... | ... | ... |
| create-transaction | transaction-service | ... | ... | ... | ... | ... | ... |
| create-transaction | item-service | ... | ... | ... | ... | ... | ... |
| create-transaction | auth-service | ... | ... | ... | ... | ... | ... |

### 17.4 HPA Behavior Table

| Scenario | Architecture | Component | HPA Target CPU | Min Replicas | Max Replicas | Max Observed Replicas | Notes |
|---|---|---|---:|---:|---:|---:|---|
| create-transaction | monolith | monolith | 70% | ... | ... | ... | ... |
| create-transaction | microservices | api-gateway | 70% | ... | ... | ... | ... |
| create-transaction | microservices | transaction-service | 70% | ... | ... | ... | ... |

---

## 18. Recommended Datadog Graphs

### 18.1 Cross-Architecture Comparison

```text
CPU total: monolith vs microservices
memory total: monolith vs microservices
p95 latency: monolith vs microservices
throughput achievement: monolith vs microservices
error rate as validation evidence
pod count: monolith vs microservices
```

### 18.2 Monolith Detail

```text
monolith CPU
monolith memory
monolith p95 latency
monolith error rate as validation evidence
monolith current vs desired replicas
slow traces
```

### 18.3 Microservices Detail

```text
api-gateway CPU/memory/latency
auth-service CPU/memory/latency
item-service CPU/memory/latency
transaction-service CPU/memory/latency
gRPC trace waterfall
current vs desired replicas per service
namespace CPU/memory total
```

### 18.4 HPA Timeline

```text
target RPS
achieved RPS
p95 latency
error rate as validation evidence
CPU utilization
HPA desired replicas
HPA current replicas
pod count
```

Purpose:

```text
show whether scaling behavior explains performance and resource changes
```

---

## 19. Required Files and Metadata

Required k6 files:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
result-status.json
k6-options.json
thresholds.json
```

Required when Datadog is enabled:

```text
datadog-time-window.json
```

HPA behavior is analyzed from Datadog telemetry plus benchmark metadata. Do not
assume separate Kubernetes snapshot files are present unless a run explicitly
collects them.

Interpretation note:

- `thresholds.json` distinguishes valid `PASS` vs `OVERLOAD` outcomes
- `result-status.json` helps identify `INVALID` runs caused by runtime or
  artifact-delivery failures

Important metadata fields:

```json
{
  "run_id": "20260512-103000",
  "attempt": "attempt-01",
  "architecture": "microservices",
  "scenario_name": "create-transaction",
  "target_rps": 1000,
  "duration": "5m",
  "dataset_version": "v1",
  "resource_ceiling": "7800m CPU / 15360Mi memory",
  "hpa_enabled": true,
  "hpa_target_cpu": "70%",
  "datadog": {
    "enabled": true,
    "time_window_start": "...",
    "time_window_end": "..."
  }
}
```

---

## 20. S3 Layout

Recommended prefix:

```text
s3://{bucket}/experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Example:

```text
s3://skripsi-benchmark-results/experiments/20260512-103000/microservices/create-transaction/1000rps/attempt-01/
```

Raw output should remain immutable.

Aggregated analysis can be stored separately:

```text
s3://{bucket}/experiments/{run_id}/analysis/
```

Example analysis files:

```text
performance-summary.csv
resource-efficiency-summary.csv
hpa-behavior-summary.csv
microservices-service-breakdown.csv
```

---

## 21. Chapter 3 Narrative Example

```text
Resource efficiency is evaluated at the architecture level. For the monolithic
architecture, CPU and memory usage are obtained from the monolith deployment.
For the microservices architecture, CPU and memory usage are aggregated from all
service deployments that form the application, including API Gateway, Auth
Service, Item Service, and Transaction Service. This approach is used because
the microservices architecture consists of multiple deployment units that
collectively provide one application behavior.
```

```text
CPU and memory usage are interpreted together with achieved RPS, latency
percentiles, error rate, checks rate, and dropped iterations. Therefore, an
architecture is not considered more efficient only because it uses lower
resources if it fails to sustain the target workload or produces invalid
responses.
```

```text
When HPA is enabled, current replicas, desired replicas, and scale events are
recorded as autoscaling metrics. These metrics explain how Kubernetes adjusts
application capacity under increasing load. HPA results are reported separately
from fixed-replica results and interpreted as autoscaling-enabled resource
efficiency, not merged into the static-scale comparison table.
```

---

## 22. Chapter 4 Narrative Examples

### Monolith More Efficient

```text
In the create-transaction scenario, the monolith reached the configured target
RPS with low error rate and lower p95 latency than the microservices
architecture. It also consumed lower aggregate CPU and memory. Based on RPS per
CPU core and CPU core-seconds per 1000 successful requests, the monolith showed
better resource efficiency in this scenario. This result is likely related to
the shorter execution path and the absence of inter-service communication.
```

### MSA Shows Scaling Benefit

```text
In the enriched-transactions scenario, the microservices architecture showed
stable latency after HPA increased the relevant service replicas. Although its
baseline memory usage was higher, the service-level breakdown shows that the
main resource pressure was concentrated in specific services. This indicates
that microservices can benefit from granular scaling, but the total resource
cost must still be compared against the monolithic architecture.
```

### Trade-Off

```text
The microservices architecture consumed higher aggregate memory and showed
higher p95 latency. However, the service-level breakdown revealed that the
resource usage was concentrated in Transaction Service and Item Service. This
indicates distributed communication overhead, while also showing where granular
scaling can be applied.
```

---

## 23. Fairness Rules

Do not compare:

```text
different target RPS
different duration
different dataset version
different environment
fixed-replica vs HPA-enabled without note
Datadog-enabled vs Datadog-disabled without note
Minikube result vs Vultr VKE final result
different resource ceiling
invalid k6 run vs valid k6 run
```

Compare only when:

```text
scenario is equivalent
target RPS is equivalent
duration is equivalent
dataset version is equivalent
resource ceiling is documented
observability mode is equivalent
scaling mode is clear
attempt lifecycle is equivalent
```

---

## 24. Checklist Before Answering RQ2

```text
[ ] k6 summary.json exists
[ ] raw.json.gz exists
[ ] metadata.json exists
[ ] thresholds.json exists for PASS vs OVERLOAD interpretation
[ ] result-status.json exists for INVALID/runtime/artifact diagnostics
[ ] achieved RPS is recorded
[ ] error rate is valid
[ ] dropped iterations are acceptable
[ ] Datadog CPU/memory data exists
[ ] MSA service-level breakdown exists
[ ] HPA files exist when HPA is enabled
[ ] Datadog time window exists when Datadog is enabled
[ ] resource ceiling is documented
[ ] every attempt starts from reset + seed
```

---

## 25. Final Analytical Model

Input:

```text
k6 scenario
target RPS
duration
dataset version
resource ceiling
scaling mode
```

Runtime:

```text
monolith or MSA on Kubernetes
fixed replicas or HPA
Datadog observability
```

Output:

```text
k6 summary
Datadog CPU/memory
metadata
```

Analysis:

```text
validate performance
calculate aggregate CPU/memory
calculate RPS per CPU core
calculate CPU core-seconds per 1000 requests
calculate memory per 1000 RPS
explain MSA service-level breakdown
explain HPA behavior separately when enabled
conclude resource efficiency
```

Diagram:

```text
+-------------------+
| reset + seed      |
+---------+---------+
          |
          v
+-------------------+
| k6 scenario       |
+---------+---------+
          |
          v
+-------------------+       +----------------------+
| architecture      +------> | Datadog/K8s          |
| monolith or MSA   |       | CPU, memory, HPA,    |
+---------+---------+       | traces, logs         |
          |                 +----------+-----------+
          v                            |
+-------------------+                  |
| k6 performance    |                  |
| result            |                  |
+---------+---------+                  |
          |                            |
          +-------------+--------------+
                        |
                        v
              +------------------+
              | RQ2 conclusion   |
              +------------------+
```

---

## 26. Final Summary

RQ2 is answered by comparing architecture-level CPU and memory efficiency.

Monolith:

```text
CPU and memory from monolith pods
```

MSA:

```text
CPU and memory aggregated from:
api-gateway
auth-service
item-service
transaction-service
```

Efficiency is evaluated using:

```text
aggregate CPU
aggregate memory
throughput achievement against target RPS
achieved RPS
latency percentiles
error rate as validation
dropped iterations as validation
RPS per CPU core
CPU core-seconds per 1000 requests
memory MiB per 1000 RPS
HPA behavior as supporting evidence when enabled
```

Final RQ2 conclusion should answer:

```text
Which architecture uses CPU and memory more efficiently to serve equivalent
workloads while maintaining valid and stable performance?
```
