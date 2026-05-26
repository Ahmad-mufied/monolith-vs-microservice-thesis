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
  total active MSA limits = architecture ceiling

hpa mode:
  total maximum MSA limits = architecture ceiling
```

This distinction matters.

In fixed mode:

- one pod per service is kept alive,
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
3. estimate the relative importance of each service across the full scenario
   set,
4. assign a larger budget to services with dominant workload roles,
5. keep the same service-level budget logic between fixed mode and HPA mode.

In this repository, the practical interpretation is:

- `api-gateway` needs a meaningful but not dominant budget because it handles
  every external request but does not own database writes,
- `auth-service` needs a relatively high budget because login contains
  CPU-heavy bcrypt work,
- `item-service` needs a moderate budget because it supports validation and
  enrichment but is not the main orchestration point,
- `transaction-service` typically deserves the largest budget because it owns
  the write path and the raw transaction retrieval path.

This yields a role hierarchy like:

```text
transaction-service : highest
auth-service        : high
item-service        : medium
api-gateway         : medium-to-lower
```

The exact numbers may change when the cluster size changes, but the method
stays the same.

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

## 7. Thesis-Friendly Justification

The following wording is suitable for the methodology chapter.

> The monolithic and microservices architectures were constrained by the same
> total application resource ceiling. However, the microservices resource
> budget was not divided equally across services. Instead, it was allocated in
> a role-aware manner based on the participation and expected computational
> weight of each service across the benchmark scenarios. This approach was
> chosen to avoid artificial bottlenecks caused by uniform per-service slicing
> and to ensure that observed bottlenecks reflected the behavior of the
> architecture and request path under study rather than an arbitrary equal
> allocation policy.

For HPA mode, the following wording is also suitable:

> In HPA mode, the same service-level budget logic was preserved, but expressed
> through smaller per-pod limits and service-specific `maxReplicas` values.
> Thus, fixed mode and HPA mode remained comparable at the total resource
> ceiling level while differing in how each service was allowed to consume its
> budget over time.

---

## 8. Worked Example

If the final shared application ceiling follows
[Application Ceiling Methodology](./application-ceiling-methodology.md), the
current recommended total becomes:

```text
CPU    = 15800m
Memory = 27648Mi
```

then a role-aware fixed allocation can be expressed conceptually as:

```text
api-gateway         : smaller share
auth-service        : larger share
item-service        : medium share
transaction-service : largest share
```

One illustrative candidate is:

| Service | Fixed CPU limit | Fixed memory limit |
|---|---:|---:|
| `api-gateway` | `2000m` | `3456Mi` |
| `auth-service` | `4000m` | `6912Mi` |
| `item-service` | `3000m` | `5184Mi` |
| `transaction-service` | `6800m` | `12096Mi` |
| **Total** | **`15800m`** | **`27648Mi`** |

The matching HPA expression of the same service budgets would then be:

| Service | Per-pod CPU limit | Per-pod memory limit | maxReplicas | Service max CPU | Service max memory |
|---|---:|---:|---:|---:|---:|
| `api-gateway` | `500m` | `864Mi` | `4` | `2000m` | `3456Mi` |
| `auth-service` | `1000m` | `1728Mi` | `4` | `4000m` | `6912Mi` |
| `item-service` | `500m` | `864Mi` | `6` | `3000m` | `5184Mi` |
| `transaction-service` | `1700m` | `3024Mi` | `4` | `6800m` | `12096Mi` |
| **Total max** |  |  |  | **`15800m`** | **`27648Mi`** |

This example is a methodology illustration. The live manifests remain the
source of truth for the currently active benchmark configuration.

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
- fixed mode and HPA mode aligned at the service budget level,
- equal split used only as an optional sensitivity study, not as the primary
  baseline.
