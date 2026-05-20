# RQ1 Performance Analysis

## 1. Purpose

This document defines the conceptual, methodological, and analytical basis for answering Research Question 1 (RQ1) in the thesis benchmark project.

RQ1 focuses on **client-observed application performance** when equivalent external workloads are applied to monolithic and microservices architectures in a cloud-native Kubernetes-based environment.

This document supports:

- Chapter 3 methodology,
- Chapter 4 performance analysis,
- k6 scenario interpretation,
- Datadog trace interpretation as supporting evidence,
- table and graph preparation for thesis reporting.

---

## 2. Research Question

Final RQ1:

```text
How does the performance of monolithic and microservices architectures compare
when handling equivalent workloads in a cloud-native environment based on
Kubernetes orchestration, based on latency, throughput, and error rate?
```

Indonesian thesis version:

```text
Bagaimana perbandingan kinerja arsitektur monolitik dan mikroservis dalam
menangani beban kerja yang setara pada lingkungan cloud-native berbasis
orkestrasi Kubernetes berdasarkan latency, throughput, dan error rate?
```

---

## 3. Position of RQ1 in the Study

RQ1 evaluates the system from the **client perspective**.

It answers:

```text
Which architecture performs better externally under equivalent workload?
```

The main evidence comes from k6 artifacts:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
```

Datadog is used as supporting evidence to explain why the k6 result occurred.

Conceptual relationship:

```text
k6
= client-observed performance

Datadog
= internal system behavior and root-cause explanation

Kubernetes snapshots
= runtime state evidence

S3 artifacts
= reproducibility record
```

Diagram:

```text
+-------------------+
| k6 workload       |
| target RPS        |
+---------+---------+
          |
          v
+-------------------+
| Application       |
| monolith or MSA   |
+---------+---------+
          |
          v
+-------------------+
| k6 result         |
| latency, RPS,     |
| error rate        |
+---------+---------+
          |
          v
+-------------------+
| RQ1 answer        |
| performance       |
| comparison        |
+-------------------+

Datadog supports explanation:
- service latency
- traces
- logs
- resource pressure
- HPA behavior
```

---

## 4. Definition of Application Performance

In this research, application performance is defined as:

```text
The ability of the system to handle an equivalent external workload with low
latency, stable achieved throughput, low error rate, and minimal dropped
iterations.
```

Performance is not determined by one metric only.

Examples:

```text
Low latency + high error rate
= not good performance

Low latency + low achieved RPS
= not valid proof of better performance

High achieved RPS + unstable p95 latency
= needs careful interpretation
```

Therefore, RQ1 must be interpreted using a metric group:

```text
latency
throughput
error rate
dropped iterations
checks rate
```

---

## 5. Main Performance Metrics

### 5.1 Latency

Latency is the time needed for the system to respond to a request.

Primary latency metrics:

```text
p90 latency
p95 latency
```

Supporting metrics:

```text
p50 latency
p99 latency
average latency
maximum latency
```

Interpretation:

```text
p90 and p95 are more useful than average latency because they show the
experience of slower requests and reveal tail latency.
```

### 5.2 Throughput / Achieved RPS

Throughput is the number of requests successfully processed within a time interval.

In k6 arrival-rate scenarios, the intended load is:

```text
TARGET_RPS
```

However, the actual load must be verified through:

```text
achieved RPS
http_reqs
iterations
```

A run is not automatically valid only because `TARGET_RPS` was configured.

### 5.3 Error Rate

Primary metric:

```text
http_req_failed
```

Supporting indicators:

```text
HTTP 4xx/5xx patterns
failed checks
application logs
Datadog error traces
```

### 5.4 Dropped Iterations

Dropped iterations indicate that k6 could not start the expected number of iterations at the configured arrival rate.

Interpretation:

```text
High dropped_iterations means the target arrival rate may not have been achieved.
The run must be reviewed before being included in final analysis.
```

### 5.5 Checks Rate

Checks validate expected API behavior, such as:

```text
status code is 200 or 201
response token exists
response data id exists
```

A high checks rate confirms that requests returned valid expected responses.

---

## 6. Metric Priority for RQ1

Recommended interpretation order:

```text
1. Was the target RPS achieved?
2. Was the error rate low?
3. Were dropped iterations within the accepted threshold?
4. Were checks successful?
5. How did p90/p95 latency compare?
6. Were results stable across attempts?
```

This prevents misleading conclusions.

Example:

```text
Architecture A has lower p95 latency than Architecture B, but Architecture A
also has high dropped iterations and lower achieved RPS. In this condition, the
lower latency cannot be treated as a clean performance advantage.
```

---

## 7. Benchmark Scenarios

RQ1 uses three primary k6 scenarios.

| Scenario | Script | Endpoint | Workload Type |
|---|---|---|---|
| Login | `k6/scripts/login.js` | `POST /api/v1/auth/login` | authentication workload |
| Create Transaction | `k6/scripts/create-transaction.js` | `POST /api/v1/transactions` | write-heavy transaction workload |
| Enriched Transactions | `k6/scripts/enriched-transactions.js` | `GET /api/v1/admin/transactions` | read-heavy aggregation workload |

Validation and optional scenarios:

| Scenario | Script | Role |
|---|---|---|
| Smoke | `k6/scripts/smoke.js` | deployment validation only |
| Sync Items | `k6/scripts/sync-items.js` | optional item synchronization scenario |
| Mixed Workload | `k6/scripts/mixed-workload.js` | optional mixed traffic scenario |

Only the three primary scenarios are required to answer RQ1.

---

## 8. Scenario 1: Login

Endpoint:

```text
POST /api/v1/auth/login
```

Purpose:

```text
Measure authentication path performance.
```

Monolith path:

```text
k6
 |
 v
monolith
 |
 v
mono_db.users
```

Microservices path:

```text
k6
 |
 v
api-gateway
 |
 v
auth-service
 |
 v
auth_db.users
```

Primary metrics:

```text
p90/p95 latency
achieved RPS
error rate
checks rate
```

Interpretation logic:

```text
If monolith has lower latency, this may be caused by a shorter execution path
without an additional API Gateway to Auth Service call.

If MSA remains stable at equivalent RPS with low error rate, the additional
network hop is present but may still be acceptable for the workload.
```

---

## 9. Scenario 2: Create Transaction

Endpoint:

```text
POST /api/v1/transactions
```

Purpose:

```text
Measure write-heavy transaction creation path.
```

Monolith path:

```text
k6
 |
 v
monolith
 |
 +--> validate item
 |
 +--> insert transactions
 |
 +--> insert transaction_items
 |
 v
mono_db
```

Microservices path:

```text
k6
 |
 v
api-gateway
 |
 v
transaction-service
 |
 +--> item-service
 |
 +--> transaction_db
 |
 v
transaction inserted
```

Primary metrics:

```text
p90/p95 latency
achieved RPS
error rate
dropped iterations
```

Important design assumption:

```text
Transactions are created by k6 during the measured workload.
They are not part of the base seed.
```

Interpretation logic:

```text
Monolith may perform better because validation and persistence happen inside
one application boundary.

MSA may show higher latency because the request crosses API Gateway,
Transaction Service, and Item Service.

If MSA performs well, service decomposition and granular scaling may compensate
for the communication overhead.
```

---

## 10. Scenario 3: Enriched Transactions

Endpoint:

```text
GET /api/v1/admin/transactions
```

Purpose:

```text
Measure read-heavy aggregation and response composition performance.
```

Monolith path:

```text
k6
 |
 v
monolith
 |
 v
local SQL query / join
 |
 v
mono_db
```

Microservices path:

```text
k6
 |
 v
api-gateway
 |
 +--> transaction-service
 |
 +--> auth-service
 |
 +--> item-service
 |
 v
in-memory response composition
```

Important lifecycle:

```text
reset
seed base users/items
prepare enrichment transaction dataset
run enriched-transactions benchmark
```

The enrichment preparation step is not measured as part of the k6 benchmark result.

Primary metrics:

```text
p90/p95 latency
achieved RPS
error rate
checks rate
```

Interpretation logic:

```text
Monolith may benefit from local joins and a shorter data access path.

MSA may show higher latency because the API Gateway performs response
composition by calling multiple services.

If MSA remains stable, Datadog traces can help show whether the cost comes from
Gateway processing, Transaction Service, Auth Service, Item Service, or gRPC
fan-out.
```

---

## 11. Workload Equivalence Rules

The comparison is valid only if both architectures are tested under equivalent conditions.

Rules:

```text
same scenario
same target RPS
same duration
same dataset version
same number of attempts
same observability mode
same cloud environment
same Kubernetes cluster class
same resource ceiling policy
same reset/seed lifecycle
same k6 script logic
```

The workload is called **equivalent**, not identical, because the external request pressure is the same, but the internal execution topology is intentionally different.

Correct wording:

```text
equivalent external workload
```

Avoid claiming:

```text
identical internal execution path
```

because monolith and microservices do not have identical internal paths.

---

## 12. k6 Execution Lifecycle

For every measured attempt:

```text
reset data
seed base dataset
optional prepare enrichment data
validate readiness
run k6
collect output
upload result to S3
```

Login:

```text
reset
seed base users/items
run login.js
```

Create transaction:

```text
reset
seed base users/items
run create-transaction.js
```

Enriched transactions:

```text
reset
seed base users/items
prepare enrichment data
run enriched-transactions.js
```

ASCII lifecycle:

```text
+----------------+
| reset database |
+-------+--------+
        |
        v
+----------------+
| seed base data |
| users + items  |
+-------+--------+
        |
        +------------------------------+
        | only for enriched benchmark  |
        v                              |
+----------------------------+         |
| prepare enrichment data    |         |
| transactions + items       |         |
+-------------+--------------+         |
              |                        |
              v                        v
        +-------------------------------+
        | readiness / data validation   |
        +---------------+---------------+
                        |
                        v
                  +-----------+
                  | k6 run    |
                  +-----+-----+
                        |
                        v
                  +-----------+
                  | S3 output |
                  +-----------+
```

---

## 13. Valid Run Criteria

A measured run is considered valid only if:

```text
summary.json exists
raw.json.gz exists
stdout.log exists
metadata.json exists
target RPS and achieved RPS are recorded
checks rate meets the threshold
error rate is below the threshold
dropped iterations are below the threshold
no major pod crash or restart invalidates the run
seed/preparation data is valid
Datadog status is consistent between compared architectures
```

Example threshold policy:

```text
checks rate >= 99%
http_req_failed <= 1%
dropped_iterations <= configured threshold
```

If a run is invalid:

```text
do not overwrite the previous attempt
fix the issue
reset and seed again
run a new attempt with a new attempt ID
```

---

## 14. Relationship with HPA

HPA is not a primary RQ1 metric. It is contextual evidence that may explain performance changes.

Mechanism:

```text
k6 target RPS increases
-> application CPU utilization increases
-> HPA desired replicas increase
-> Kubernetes starts additional pods
-> latency/error may change
```

HPA can explain:

```text
latency spikes before scale-up
latency stabilization after scale-up
error reduction after additional replicas are ready
throughput stabilization after scaling
```

However, RQ1 is still answered primarily using:

```text
latency
achieved RPS
error rate
dropped iterations
```

If HPA is enabled, results must be labeled as:

```text
performance under autoscaling-enabled Kubernetes environment
```

Do not mix fixed-replica results and HPA-enabled results without explicit labeling.

---

## 15. Relationship with Datadog

Datadog explains why k6 results happened.

Examples:

```text
k6 result:
MSA p95 latency is higher.

Datadog explanation:
trace shows latency dominated by api-gateway -> transaction-service -> item-service path.
```

```text
k6 result:
error rate increases during create transaction.

Datadog explanation:
transaction-service logs show timeout or item-service gRPC errors.
```

Datadog supports RQ1 through:

```text
HTTP latency trends
service latency breakdown
distributed traces
error traces
logs
HPA timing
CPU/memory pressure
```

But final RQ1 performance tables should still use k6 as the primary source.

---

## 16. Recommended Tables for Chapter 4

### 16.1 Main Performance Comparison Table

| Scenario | Architecture | Target RPS | Achieved RPS | p90 Latency | p95 Latency | Error Rate | Dropped Iterations | Verdict |
|---|---|---:|---:|---:|---:|---:|---:|---|
| login | monolith | ... | ... | ... | ... | ... | ... | ... |
| login | msa | ... | ... | ... | ... | ... | ... | ... |
| create-transaction | monolith | ... | ... | ... | ... | ... | ... | ... |
| create-transaction | msa | ... | ... | ... | ... | ... | ... | ... |
| enriched-transactions | monolith | ... | ... | ... | ... | ... | ... | ... |
| enriched-transactions | msa | ... | ... | ... | ... | ... | ... | ... |

### 16.2 Attempt-Level Table

| Scenario | Architecture | Attempt | Target RPS | Achieved RPS | p90 | p95 | Error Rate | Dropped Iterations |
|---|---|---|---:|---:|---:|---:|---:|---:|
| login | monolith | attempt-01 | ... | ... | ... | ... | ... | ... |
| login | msa | attempt-01 | ... | ... | ... | ... | ... | ... |

### 16.3 Aggregated Table

| Scenario | Architecture | Mean p95 | Median p95 | Std Dev p95 | Mean Error Rate | Mean Achieved RPS |
|---|---|---:|---:|---:|---:|---:|
| login | monolith | ... | ... | ... | ... | ... |
| login | msa | ... | ... | ... | ... | ... |

Recommended rule:

```text
Report p95 per attempt, then summarize attempt-level p95 values using mean or median.
Do not merge p95 values casually without raw sample aggregation logic.
```

---

## 17. Recommended Graphs for Chapter 4

Primary RQ1 graphs:

```text
p95 latency comparison per scenario
p90 latency comparison per scenario
achieved RPS comparison per scenario
error rate comparison per scenario
dropped iterations comparison per scenario
```

Supporting graphs:

```text
latency over time
request rate over time
error rate over time
trace waterfall examples
```

Example graph structure:

```text
x-axis  = scenario
y-axis  = p95 latency
series  = monolith, msa
```

---

## 18. Example Interpretation Cases

### Case 1: Monolith Has Lower Latency and Same Achieved RPS

```text
Monolith shows better client-observed performance in this scenario because it
achieves the target RPS with lower p95 latency and low error rate. The shorter
execution path and absence of inter-service communication may explain the
latency advantage.
```

### Case 2: MSA Has Higher Latency but Low Error Rate

```text
MSA shows higher latency but remains stable because achieved RPS stays near the
target and error rate remains low. This indicates that inter-service
communication adds overhead, but the architecture still handles the workload
without failure.
```

### Case 3: MSA Has Better Stability at High Load

```text
At high target RPS, MSA maintains achieved RPS and lower error rate compared to
monolith. This may indicate that service decomposition and scaling granularity
help maintain stability under the selected workload.
```

### Case 4: Lower Latency but High Dropped Iterations

```text
The run cannot be interpreted as better performance because k6 did not sustain
the target arrival rate. Lower latency may occur because fewer requests were
actually executed.
```

---

## 19. Chapter 3 Narrative Example

```text
Application performance is evaluated using k6 from the client perspective.
The primary metrics are p90 latency, p95 latency, achieved request rate, error
rate, and dropped iterations. The benchmark uses equivalent external workloads
for monolith and microservices, including the same endpoint scenario, target
RPS, duration, dataset version, and number of attempts. k6 output is treated as
the primary source of performance results, while Datadog is used to explain
internal service behavior, traces, and possible bottlenecks.
```

```text
A run is considered valid only when the configured workload is executed
successfully, the error rate and dropped iterations remain within the accepted
threshold, and all required result artifacts are collected. Invalid runs are not
used for final comparison and must be repeated with a new attempt identifier.
```

---

## 20. Chapter 4 Narrative Example

```text
The login scenario shows that both architectures reached the configured target
RPS with low error rate. However, the monolith produced lower p95 latency than
the microservices architecture. This indicates that, for the authentication
path, the additional API Gateway and service-to-service call in the
microservices architecture introduced measurable latency overhead.
```

```text
In the create-transaction scenario, the microservices architecture showed
higher p95 latency but remained stable in terms of achieved RPS and error rate.
Datadog traces indicate that the request path involved API Gateway,
Transaction Service, and Item Service. Therefore, the observed difference can be
explained by the additional distributed communication path rather than by
request failure.
```

---

## 21. Fairness Rules

Do not compare:

```text
different target RPS
different duration
different dataset version
different environment
Datadog-enabled vs Datadog-disabled without note
fixed-replica vs HPA-enabled without note
Minikube result vs EKS final benchmark result
run with high dropped_iterations vs valid run
```

Compare only when:

```text
scenario is equivalent
target RPS is equivalent
duration is equivalent
dataset version is equivalent
environment is equivalent
observability mode is equivalent
resource policy is documented
```

---

## 22. Final Analytical Model

Input:

```text
scenario
target RPS
duration
dataset version
architecture
```

Runtime:

```text
monolith or MSA in Kubernetes
optional HPA behavior
Datadog observability
```

Output:

```text
k6 summary
k6 raw output
metadata
Datadog time window
Kubernetes snapshots
```

Analysis:

```text
validate run
compare achieved RPS
compare error rate
compare dropped iterations
compare p90/p95 latency
use Datadog to explain internal cause
conclude performance difference
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
| target RPS        |
+---------+---------+
          |
          v
+-------------------+        +----------------------+
| application       +-------> | Datadog              |
| monolith or MSA   |        | trace/log/resource    |
+---------+---------+        +----------+-----------+
          |                             |
          v                             |
+-------------------+                   |
| k6 performance    |                   |
| result            |                   |
+---------+---------+                   |
          |                             |
          +-------------+---------------+
                        |
                        v
              +------------------+
              | RQ1 conclusion   |
              +------------------+
```

---

## 23. Final Summary

RQ1 is answered by comparing external performance between monolith and microservices using equivalent k6 workloads.

Primary evidence:

```text
p90 latency
p95 latency
achieved RPS
error rate
dropped iterations
checks rate
```

Main scenarios:

```text
login
create-transaction
enriched-transactions
```

Datadog supports interpretation, but k6 remains the primary benchmark source.

Final conclusion should answer:

```text
Which architecture delivered more stable and lower-latency performance under
equivalent workload conditions?
```
