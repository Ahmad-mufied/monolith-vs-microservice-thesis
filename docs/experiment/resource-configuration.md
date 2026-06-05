# Resource Configuration Methodology

## Purpose

This document explains how application resource ceilings are translated into
per-service resource budgets for the benchmark experiment.

It answers the following methodological questions:

1. why the monolith and microservices architectures use the same total
   resource ceiling,
2. why the microservices services are not assigned identical per-service
   limits,
3. how fixed-replica mode and HPA mode remain comparable,
4. how the benchmark should justify the final resource split in the thesis.

This document focuses on the application layer. Cluster-level overhead such as
Kubernetes system pods and Datadog is documented separately in
`docs/infrastructure/datadog-resource-overhead.md`. The method for converting
live cluster capacity and live overhead into a final shared application
ceiling is documented in
[Application Ceiling Methodology](./application-ceiling-methodology.md).

---

## 1. Core Fairness Rule

The fairness target of this benchmark is:

```text
equal total application ceiling per architecture
```

This means the monolith and the microservices architecture must be compared
under the same total application budget, even though the internal shape of
that budget differs.

The fairness target is **not**:

```text
equal per-component budget inside the microservices architecture
```

That second rule would only be appropriate if every microservice performed the
same type of work, handled the same traffic pattern, and owned the same amount
of business logic and data access. That is not true in this repository.

---

## 2. Why MSA Resource Split Is Not Equal

The microservices architecture in this repository contains four services with
different responsibilities:

- `api-gateway`: external HTTP entry point, JWT validation, HTTP to gRPC
  translation, response mapping
- `auth-service`: login, bcrypt password comparison, JWT issuing, user lookup
- `item-service`: item validation and item summary lookup
- `transaction-service`: transaction creation, transaction query, and
  transaction orchestration

These services participate differently across the benchmark scenarios:

| Scenario | api-gateway | auth-service | item-service | transaction-service |
|---|---|---|---|---|
| `POST /api/v1/auth/login` | yes | dominant | no | no |
| `POST /api/v1/transactions` | yes | no | involved | dominant |
| `GET /api/v1/admin/transactions` | yes | involved | involved | dominant |

As a result, equal service budgets would impose an artificial assumption:

```text
all services deserve the same resource budget regardless of their role
```

That assumption is not architecture-neutral. Instead, it injects a synthetic
constraint that may create bottlenecks unrelated to the actual benchmark
question.

For example:

- if `auth-service` is forced to use the same budget as `api-gateway`, then a
  login-heavy scenario may fail because bcrypt work saturates too early,
  not because the architecture itself is weak,
- if `transaction-service` is forced to use the same budget as
  `item-service`, then write-heavy and enriched-read scenarios may be
  dominated by a budget bottleneck that was created by the experiment design,
  not by the service decomposition itself.

Therefore, the benchmark uses:

```text
equal total architecture budget
+ role-aware per-service budget
```

This keeps the architecture comparison fair while avoiding a resource split
that is unrelated to the actual workload roles.

---

## 3. Theoretical Basis

The resource split is grounded in three methodological ideas.

### 3.1 Workload-Aware Allocation

Resource allocation should reflect the expected work performed by each
component under the defined benchmark scenarios.

In this thesis, the three benchmark scenarios are not symmetric:

- login concentrates CPU-heavy work in `auth-service`,
- create transaction concentrates write-path work in `transaction-service`
  while still involving `item-service`,
- enriched transactions adds a fan-out pattern in which
  `api-gateway`, `transaction-service`, `auth-service`, and `item-service`
  all participate, but not with identical intensity.

Because the workload shape is asymmetric, a role-aware split is more valid
than an equal split.

### 3.2 Bottleneck Validity

End-to-end latency and throughput are strongly shaped by the first component
that saturates.

If the experiment assigns the same budget to all services even though their
expected demand differs, the benchmark may produce a bottleneck caused by the
allocation policy instead of by the architecture.

The benchmark therefore aims to avoid:

```text
artificial bottleneck due to equal per-service slicing
```

and prefers:

```text
role-aware bottleneck that emerges from the actual request path
```

### 3.3 Microservice Heterogeneity

A core property of microservices is that different services may need different
compute budgets because they encapsulate different logic, data access
patterns, and traffic concentration.

Using unequal per-service budgets is therefore not a deviation from the
microservices model. It is one of the natural consequences of decomposing a
system into services with distinct responsibilities.

---

## 4. Fixed Mode vs HPA Mode

The benchmark supports two scaling modes:

- `fixed-replica`
- `hpa`

The comparison rule across these modes is:

```text
fixed mode:
  total active MSA limits = architecture ceiling (strict)

hpa mode:
  CPU total maximum limits = architecture ceiling (strict)
  Memory total maximum limits = elastic oversubscription under ResourceQuota guardrail
```

This distinction matters.

In fixed mode:

- one monolith pod is kept alive for the monolith architecture,
- one pod per service is kept alive for the microservices architecture,
- the service limit itself carries the service budget,
- there is no additional scale-out headroom because the fixed deployment is
  already the final allocation shape.

In HPA mode:

- each service starts with a smaller per-pod budget,
- scale-out is allowed,
- the product of `per-pod limit x maxReplicas` represents the maximum service
  budget,
- the sum of all maximum service budgets must still equal the same total
  architecture ceiling.

This means fixed mode and HPA mode should not be identical at the per-pod
level. They should only be identical at the total architecture ceiling level.

---

## 5. Resource Split Method

The recommended method for deriving the MSA split is:

1. determine the total application ceiling for the architecture,
2. identify which services participate in each benchmark scenario,
3. classify each service by its workload character (CPU-bound vs I/O-bound),
4. assign a larger budget to services with dominant workload roles,
5. in HPA mode, derive per-pod limits from the service budget divided by
   maxReplicas, where maxReplicas is chosen based on workload character.

### 5.1 Workload Character Classification

Each service has a distinct compute character that determines the optimal
replica and resource shape:

- `api-gateway`: **I/O-bound** — goroutines spend most time waiting for
  downstream gRPC responses. CPU actual usage per request is very low.
  Benefits from many small pods to handle high concurrency.
- `auth-service`: **CPU-bound** — bcrypt password comparison consumes one
  full CPU core per request for ~100–300ms. Does not benefit from many small
  pods because each pod is throttled. Benefits from fewer large pods.
- `item-service`: **I/O-bound** — read-only database queries (validation and
  summary lookup). Similar to api-gateway. Benefits from many small pods.
- `transaction-service`: **mixed** — write path requires sequential database
  steps (begin, insert, commit). Database connection pool is a constraint:
  fewer pods means fewer total connections, which is more efficient. Benefits
  from fewer larger pods.

This classification drives the HPA replica shape:

```text
I/O-bound  → many small pods  (api-gateway, item-service)
CPU-bound  → few large pods   (auth-service)
mixed      → few larger pods  (transaction-service)
```

### 5.2 HPA Request-to-Limit Ratio

HPA triggers scale-out when:

```text
actual_usage / request > targetCPUUtilizationPercentage (70%)
```

The request value therefore controls how quickly HPA reacts:

- request too large → HPA triggers late, pod already overloaded
- request too small → HPA triggers too aggressively, wastes replicas

The target ratio for this benchmark is **40–57% of limit**, which provides
burst headroom before HPA triggers without being too conservative.

### 5.3 Scale-In Headroom

When a service is idle (e.g. auth-service during create-transaction scenario),
HPA scales it in to minReplicas = 1. The freed CPU requests become available
for other services to scale out. With all services at minReplicas:

```text
api-gateway:          200m request
auth-service:        2000m request
item-service:         200m request
transaction-service:  800m request
Total at minReplicas: 3200m

Available headroom:  15800m - 3200m = 12600m
```

This 12600m headroom allows the dominant service for any given scenario to
scale out fully without being blocked by idle services holding quota.

### 5.4 Per-Scenario Scale-Out Analysis

The following analysis shows whether each service can reach maxReplicas under
each benchmark scenario, given the 12600m headroom available when all services
start at minReplicas.

**Baseline: all services at minReplicas (1 pod each)**

```text
api-gateway:          200m request × 1 =  200m
auth-service:        2000m request × 1 = 2000m
item-service:         200m request × 1 =  200m
transaction-service:  800m request × 1 =  800m
Total used:                              3200m
Available headroom:  15800m - 3200m   = 12600m
```

---

**Scenario 1 — Login (`POST /api/v1/auth/login`)**

Active services: api-gateway (routing + JWT), auth-service (bcrypt + JWT issue).
item-service and transaction-service are not involved and remain idle at 1 pod.

auth-service is the dominant service. It is CPU-bound and benefits from scaling
out to its maxReplicas of 2 large pods.

```text
Remaining after baseline:          12600m
auth-service pod 2:      +2000m →  10600m remaining
auth-service maxReplicas = 2 → STOP

Total auth-service active limit: 2 × 3500m = 7000m ✅
```

api-gateway handles all inbound HTTP and gRPC translation. It is I/O-bound and
benefits from scaling out to maxReplicas 5.

```text
Remaining after auth-service max:  10600m
api-gateway pods 2–5: 4 × 200m = 800m → 9800m remaining
api-gateway at max (5 pods) ✅
```

Conclusion: both active services reach maxReplicas. item-service and
transaction-service remain idle at 1 pod. Remaining quota: **9800m**.

---

**Scenario 2 — Create Transaction (`POST /api/v1/transactions`)**

Active services: api-gateway (routing), item-service (ValidateTransactionItems
via gRPC), transaction-service (write path: begin TX, insert, commit).
auth-service is not involved in the transaction write path and remains idle at
1 pod, but its 2000m request remains reserved.

transaction-service is the dominant service. It is mixed (write-heavy + DB
connection pool constraint) and benefits from 2 large pods.

```text
Remaining after baseline:                12600m
transaction-service pod 2:  +800m →     11800m remaining
transaction-service maxReplicas = 2 → STOP

Total transaction-service active limit: 2 × 2000m = 4000m ✅
```

item-service handles ValidateTransactionItems — read-only, I/O-bound. Benefits
from scaling out to maxReplicas 5.

```text
Remaining after transaction-service max: 11800m
item-service pods 2–5: 4 × 200m = 800m → 11000m remaining
item-service at max (5 pods) ✅
```

api-gateway handles all inbound requests. I/O-bound, scales to maxReplicas 5.

```text
Remaining after item-service max: 11000m
api-gateway pods 2–5: 4 × 200m = 800m → 10200m remaining
api-gateway at max (5 pods) ✅
```

auth-service is idle at 1 pod. Its 2000m request is reserved but unused. This
is an intentional trade-off: auth-service requires a large pod due to its
CPU-bound nature, and the 2000m reservation does not block any other service
from scaling out.

Conclusion: all active services reach maxReplicas. Remaining quota: **10200m**.

---

**Scenario 3 — Enriched Transactions (`GET /api/v1/admin/transactions`)**

Active services: all four. The enriched transaction flow is a fan-out pattern:

```text
api-gateway
  → transaction-service → transaction_db (raw rows)
  → api-gateway fan-out (parallel):
      → auth-service → auth_db (GetUsersByIds)
      → item-service → item_db (GetItemSummariesByIds)
  → api-gateway in-memory join → response
```

All services participate but with different intensities. transaction-service
and api-gateway carry the heaviest load; auth-service and item-service handle
batch lookup calls.

```text
Remaining after baseline:                12600m
transaction-service pod 2:  +800m →     11800m remaining
transaction-service maxReplicas = 2 → STOP

auth-service pod 2:        +2000m →      9800m remaining
auth-service maxReplicas = 2 → STOP

item-service pods 2–5: 4 × 200m = 800m → 9000m remaining
item-service at max (5 pods) ✅

api-gateway pods 2–5: 4 × 200m = 800m → 8200m remaining
api-gateway at max (5 pods) ✅
```

Conclusion: all four services reach maxReplicas simultaneously. Remaining
quota: **8200m**.

---

**Scenario 4 — Mixed Workload (25% each endpoint)**

All services are active simultaneously with proportional load across all
endpoints. This is the most demanding scenario for the HPA configuration.

Worst case: all services scale out to maxReplicas at the same time.

```text
api-gateway:         5 × 200m  = 1000m
auth-service:        2 × 2000m = 4000m
item-service:        5 × 200m  = 1000m
transaction-service: 2 × 800m  = 1600m
Total requests at max:           7600m

Remaining quota: 15800m - 7600m = 8200m ✅
```

All services can reach maxReplicas simultaneously without exceeding the
namespace quota. The 8200m remaining confirms that the configuration has
sufficient headroom even under the most demanding benchmark condition.

---

**Summary**

| Scenario | api-gateway | auth-service | item-service | transaction-service | Remaining quota |
|---|---|---|---|---|---|
| Login | max (5 pods) ✅ | max (2 pods) ✅ | idle | idle | 9800m |
| Create TX | max (5 pods) ✅ | idle | max (5 pods) ✅ | max (2 pods) ✅ | 10200m |
| Enriched | max (5 pods) ✅ | max (2 pods) ✅ | max (5 pods) ✅ | max (2 pods) ✅ | 8200m |
| Mixed | max (5 pods) ✅ | max (2 pods) ✅ | max (5 pods) ✅ | max (2 pods) ✅ | 8200m |

In every scenario, all relevant services can scale out to their maxReplicas
without being blocked by idle services holding quota. The minimum remaining
quota across all scenarios is **8200m**, confirming that the configuration has
sufficient headroom under all benchmark conditions.

The only intentional inefficiency is auth-service always reserving 2000m
request even when idle (scenarios 2 and 3). This is a deliberate trade-off:
auth-service is CPU-bound and requires a large pod, so its request must be
proportionally large. With 12600m total headroom available, this reservation
does not block any other service from scaling out to its maximum capacity.

---

## 6. Why Not Use an Equal Split as the Main Method

An equal split is easy to explain operationally, but it is weaker
methodologically for this benchmark.

If the MSA ceiling were divided equally across four services, the implicit
claim would be:

```text
equal resource per service is the fairest MSA baseline
```

That claim is difficult to defend here because:

- service responsibilities are not equal,
- scenario participation is not equal,
- CPU intensity is not equal,
- write ownership is not equal,
- fan-out contribution is not equal.

Equal split may still be useful as a **secondary sensitivity analysis**:

```text
How would the MSA behave if all services were forced into identical budgets?
```

But that is a different experimental question. It should not replace the main
role-aware baseline.

---

## 8. Active Configuration

The current benchmark uses the following resource configuration.

### Fixed Mode

| Service | CPU request | CPU limit | Memory request | Memory limit | Replicas |
|---|---:|---:|---:|---:|---:|
| `api-gateway` | `750m` | `2500m` | `864Mi` | `3456Mi` | `1` |
| `auth-service` | `2500m` | `7000m` | `3456Mi` | `10368Mi` | `1` |
| `item-service` | `750m` | `2300m` | `1296Mi` | `3456Mi` | `1` |
| `transaction-service` | `1000m` | `4000m` | `3024Mi` | `10368Mi` | `1` |
| **Total** | **`5000m`** | **`15800m`** | **`8640Mi`** | **`27648Mi`** | **4** |

### HPA Mode

HPA mode uses **quota-guarded elastic oversubscription**. CPU total maximum is
strictly equal to the architecture ceiling. Memory total theoretical maximum
slightly exceeds the ceiling by design, with the namespace ResourceQuota acting
as the hard guardrail.

```text
Fixed mode  = strict active ceiling
HPA mode    = quota-guarded elastic oversubscription
```

| Service | CPU req/pod | CPU limit/pod | Mem req/pod | Mem limit/pod | minReplicas | maxReplicas | Max CPU | Max Mem (theoretical) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `api-gateway` | `200m` | `500m` | `432Mi` | `864Mi` | `1` | `5` | `2500m` | `4320Mi` |
| `auth-service` | `2000m` | `3500m` | `3456Mi` | `5184Mi` | `1` | `2` | `7000m` | `10368Mi` |
| `item-service` | `200m` | `460m` | `432Mi` | `864Mi` | `1` | `5` | `2300m` | `4320Mi` |
| `transaction-service` | `800m` | `2000m` | `3024Mi` | `5184Mi` | `1` | `2` | `4000m` | `10368Mi` |
| **Total max** | | | | | | | **`15800m`** ✅ | **`29376Mi`** ⚠️ |

CPU total maximum = architecture ceiling (strict). Memory theoretical maximum
(29376Mi) exceeds the namespace quota (27648Mi) by ~1728Mi (~6%). This is
intentional: each service is assigned `maxReplicas` based on its workload
character, not based on a precise per-service memory split.

The namespace ResourceQuota (27648Mi) remains the hard ceiling for actual
memory usage. If all services attempt to scale out to maxReplicas
simultaneously and total memory requests approach the quota, new pods will be
held Pending by the Kubernetes scheduler. This is expected behavior and is
recorded as part of HPA behavior observation, not as a configuration failure.

In practice, not all services reach maxReplicas simultaneously because each
benchmark scenario activates only a subset of services. The oversubscription
enables active services to utilize resources freed by idle services.

### HPA Replica Shape Rationale

| Service | Workload character | Replica shape | Reason |
|---|---|---|---|
| `api-gateway` | I/O-bound | many small (max 5) | concurrency bottleneck, not per-request CPU |
| `auth-service` | CPU-bound | few large (max 2) | bcrypt saturates CPU per request; large pod more efficient than many small |
| `item-service` | I/O-bound | many small (max 5) | read-only DB queries, high concurrency benefit |
| `transaction-service` | mixed | few larger (max 2) | DB connection pool efficiency; write path is sequential |

### Mixed-Workload Scenario Weights

The `mixed-workload` scenario uses equal weights across all endpoints:

| Endpoint | Weight |
|---|---:|
| `POST /api/v1/auth/login` | `25%` |
| `POST /api/v1/transactions` | `25%` |
| `GET /api/v1/transactions` (own) | `25%` |
| `GET /api/v1/admin/transactions` | `25%` |

Equal weights were chosen because no empirical traffic data exists to justify
an unequal distribution. This is the most defensible neutral baseline for a
controlled architecture comparison.

---

## 9. Recommended Reporting Rule

When documenting the benchmark, always report resource configuration at two
levels:

1. architecture-level ceiling,
2. per-service allocation logic.

For the microservices architecture, the report should explicitly state whether
the configuration was:

- role-aware,
- equal-split,
- fixed-replica,
- HPA-based.

This avoids ambiguity when interpreting CPU efficiency, memory efficiency, and
autoscaling behavior.

---

## 10. Summary

The main methodological rule is:

```text
same total architecture budget
does not require
same per-service budget
```

For this benchmark, the strongest default choice is:

- equal total ceiling between monolith and microservices,
- role-aware per-service split inside microservices,
- fixed mode uses one pod per service with full service budget as the limit,
- HPA mode uses workload-character-aware replica shape:
  - I/O-bound services get many small pods (high concurrency),
  - CPU-bound and mixed services get few large pods (compute efficiency),
- fixed mode and HPA mode are comparable at the per-service budget level
  (`limit × maxReplicas = fixed limit`),
- equal split used only as an optional sensitivity study, not as the primary
  baseline.
