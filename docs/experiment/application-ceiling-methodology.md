# Application Ceiling Methodology

## Purpose

This document explains how the benchmark derives a defensible application
resource ceiling from live Kubernetes cluster measurements.

It is intended to serve two audiences at once:

- repository readers who want to understand why the manifests are not set to
  raw physical node capacity,
- thesis readers who need a traceable methodology for converting cluster
  capacity into an application ceiling that remains fair across the monolith
  and microservices architectures.

This document answers the following questions:

1. why physical node capacity should not be used directly as the benchmark
   application ceiling,
2. why allocatable capacity is a stronger baseline than raw physical capacity,
3. how Kubernetes system overhead and Datadog overhead are measured,
4. how the final ceiling is rounded into practical manifest values,
5. how the final ceiling should influence fixed and HPA resource manifests.

This document complements:

- [Resource Configuration Methodology](./resource-configuration.md)
- [Scaling Mode Strategy](./scaling-mode-strategy.md)
- [Datadog Resource Overhead](../infrastructure/datadog-resource-overhead.md)

The final thesis benchmark path follows the same measurement-first rule, but it
does not reuse the historical EKS `15800m CPU / 27648Mi memory` ceiling.
Hetzner app-node capacity is measured live after provisioning, then the
generated CPU and memory quota is applied equally to monolith and
microservices. See `docs/infrastructure/hetzner-cloud-architecture.md`.

The resource-configuration document explains **how** the application budget is
split between services and scaling modes. This document explains **how the
total budget itself is derived**.

---

## 1. Core Principle

The benchmark should not set the application ceiling directly equal to:

```text
raw physical node capacity
```

Instead, the ceiling should be derived from:

```text
allocatable application capacity
- always-on cluster pod overhead
= usable application ceiling
```

This matters because Kubernetes does not expose all physical node resources to
workload pods. Some resources are retained implicitly by the operating system,
the kubelet, the container runtime, and cluster services.

Therefore, a benchmark configuration that simply sets:

```text
application ceiling = physical capacity
```

can overstate the capacity that is truly available for the benchmarked
applications.

---

## 2. Why Physical Capacity Is Not Enough

In Kubernetes, each node exposes at least two relevant resource views:

- `capacity`
- `allocatable`

`capacity` is the node's total visible hardware budget inside Kubernetes.
`allocatable` is the portion that Kubernetes makes available for workload
pods after reserving part of the node for system operation.

For benchmark fairness, the ceiling should be tied to `allocatable`, not
`capacity`, because `allocatable` better represents the maximum resource pool
that application pods can realistically compete for.

If `capacity` is used directly, the benchmark may silently assume that:

- the kubelet itself consumes nothing,
- the container runtime consumes nothing,
- Kubernetes system pods consume nothing,
- Datadog consumes nothing,
- there is no safety margin between scheduling and runtime.

Those assumptions are not valid in this repository.

---

## 3. Measurement Model

The methodology uses a three-layer model:

```text
Layer 1: physical capacity visible to Kubernetes
Layer 2: allocatable capacity available to workload scheduling
Layer 3: always-on pod overhead on app nodes
```

The final application ceiling is derived after subtracting Layer 3 from
Layer 2.

### 3.1 Included Overhead

The measured always-on pod overhead includes:

- `kube-system` pods on app nodes,
- `datadog` namespace pods on app nodes.

Examples:

- CNI / overlay agents
- `kube-proxy` or equivalent networking helpers
- `coredns`
- `datadog` DaemonSet pods
- `datadog-cluster-agent`

### 3.2 Excluded Overhead

The measured pod overhead does not directly include:

- Linux kernel memory,
- kubelet process memory,
- container runtime process memory,
- other host-level overhead outside pods.

Those costs are already reflected indirectly in the difference between:

```text
capacity - allocatable
```

This is why the methodology subtracts both:

1. `capacity -> allocatable` reduction,
2. measured always-on pod overhead.

### 3.3 Why Testing Nodes Are Excluded

The benchmark architecture isolates the k6 runner on `testing-nodes`.

Therefore:

- testing node overhead must not be deducted from application ceiling,
- only app-node capacity and app-node overhead should be used to define the
  application ceiling.

This keeps the application ceiling specific to the resource pool that hosts:

- monolith pods,
- microservice pods,
- cluster services that share those same nodes.

---

## 4. Live Measurement Basis

This section has two roles:

- explain the general method that applies to the final Hetzner benchmark path,
- preserve the historical EKS example that originally motivated the quota
  derivation.

For the final thesis dataset, use the live Hetzner measurement outputs under
`env/hetzner-resource-baseline.env` and `env/hetzner-resource-baseline.json`
instead of the historical EKS sample values below.

Historical EKS sample environment:

- `2` app nodes of type `c8i.2xlarge`
- `1` testing node of type `c8i-flex.large`

The ceiling calculation below intentionally uses only the `2` app nodes.

### 4.1 Per-App-Node Capacity

Observed from live Kubernetes node data:

```text
capacity.cpu    = 8
capacity.memory = 16085172Ki

allocatable.cpu    = 7910m
allocatable.memory = 14392500Ki
```

### 4.2 Total App-Node Pool Per Architecture

Because each architecture has `2` app nodes:

```text
physical CPU    = 16000m
physical memory = 32170344Ki  = 31416.35Mi

allocatable CPU    = 15820m
allocatable memory = 28785000Ki = 28110.35Mi
```

### 4.3 Capacity-to-Allocatable Reduction

The live reduction from physical to allocatable is:

```text
CPU    = 16000m - 15820m    = 180m
Memory = 31416.35Mi - 28110.35Mi = 3306.00Mi
```

This reduction already represents node-level system reservation and is one of
the most important observations in the whole methodology:

```text
the largest reduction happens before application pods are even considered
```

In other words, the main reason not to use physical capacity directly is not
Datadog alone. The bigger reason is that allocatable memory is substantially
smaller than raw physical memory.

---

## 5. Measured Pod-Level Overhead on App Nodes

The following values were derived from live Datadog metrics on app nodes only:

- `kubernetes.cpu.usage.total`
- `kubernetes.memory.working_set`

Measurement scope:

- last 15 minutes,
- namespace `kube-system`,
- namespace `datadog`,
- grouped by app node.

CPU values are expressed below in approximate millicores.
Memory values are expressed below in approximate mebibytes.

### 5.1 Monolith Cluster App-Node Overhead

Observed app-node totals:

| App Node | kube-system CPU | kube-system Memory | Datadog CPU | Datadog Memory | Total CPU | Total Memory |
|---|---:|---:|---:|---:|---:|---:|
| `ip-10-0-1-179` | `0.60m` | `19.40Mi` | `7.08m` | `70.25Mi` | `7.68m` | `89.64Mi` |
| `ip-10-0-2-123` | `0.68m` | `20.87Mi` | `7.86m` | `72.00Mi` | `8.54m` | `92.87Mi` |
| **Total** |  |  |  |  | **`16.22m`** | **`182.52Mi`** |

### 5.2 Microservices Cluster App-Node Overhead

Observed app-node totals:

| App Node | kube-system CPU | kube-system Memory | Datadog CPU | Datadog Memory | Total CPU | Total Memory |
|---|---:|---:|---:|---:|---:|---:|
| `ip-10-0-1-151` | `0.62m` | `20.32Mi` | `7.25m` | `69.00Mi` | `7.87m` | `89.32Mi` |
| `ip-10-0-2-42` | `0.77m` | `20.30Mi` | `10.31m` | `69.47Mi` | `11.08m` | `89.77Mi` |
| **Total** |  |  |  |  | **`18.95m`** | **`179.09Mi`** |

### 5.3 Interpretation

The cluster-level app-node pod overhead is very similar across architectures:

- monolith app-node overhead: `16.22m / 182.52Mi`
- microservices app-node overhead: `18.95m / 179.09Mi`

This supports two methodological conclusions:

1. Datadog and Kubernetes system pods do consume real resources on app nodes,
   so they should not be ignored.
2. Their contribution is relatively small compared with the allocatable pool,
   so an extremely conservative application ceiling is unnecessary.

---

## 6. Derived Clean Ceiling

The clean application ceiling is computed as:

```text
clean ceiling
= allocatable app-node pool
- app-node pod overhead
```

### 6.1 Monolith Cluster Clean Ceiling

```text
CPU    = 15820m - 16.22m  = 15803.78m
Memory = 28110.35Mi - 182.52Mi = 27927.83Mi
```

### 6.2 Microservices Cluster Clean Ceiling

```text
CPU    = 15820m - 18.95m  = 15801.05m
Memory = 28110.35Mi - 179.09Mi = 27931.26Mi
```

### 6.3 Fair Shared Ceiling

Because the benchmark requires the same architecture-level ceiling for both
architectures, the shared ceiling should be derived from the smaller of the
two clean ceilings.

Therefore, the raw shared ceiling is approximately:

```text
CPU    = 15800m
Memory = 27900Mi
```

---

## 7. Rounded Thesis Ceiling

For manifests and thesis reporting, it is often useful to round the clean
ceiling into a practical configuration that:

- remains below measured usable capacity,
- is easy to explain,
- produces readable pod-level allocations.

Two reasonable representations are:

### 7.1 Scientific Raw Ceiling

```text
CPU    = 15800m
Memory = 27900Mi
```

This is the closest rounded representation of the measured clean ceiling.

### 7.2 Rounded Thesis Ceiling

```text
CPU    = 15800m
Memory = 27648Mi
```

`27648Mi` is exactly `27Gi`, which makes it:

- easier to explain,
- easier to split into per-pod budgets,
- still safely below the measured clean ceiling.

For final benchmark manifests and thesis reporting, this document recommends:

```text
final shared ceiling = 15800m CPU / 27648Mi memory
```

---

## 8. Why the Current Exploratory Manifests May Differ

During exploratory or debugging phases, it can still be useful to keep a more
aggressive temporary manifest configuration, for example:

```text
16000m / 32768Mi
```

because that helps:

- validate deploy scripts,
- validate HPA behavior,
- validate benchmark orchestration,
- observe rough bottlenecks quickly.

However, such a configuration should be treated as:

```text
exploratory configuration
```

not automatically as the final thesis benchmark configuration.

The final thesis configuration should instead follow the measured ceiling
method in this document.

---

## 9. Implication for Manifest Design

Once the benchmark pipeline is stable and the final thesis configuration is
ready to be frozen, the following resources should be aligned to the measured
ceiling:

- EKS monolith fixed overlay
- EKS monolith HPA overlay
- EKS microservices fixed overlay
- EKS microservices HPA overlay
- namespace `ResourceQuota`
- benchmark metadata that reports the resource configuration

The implication is important:

```text
changing the final ceiling is not only a ResourceQuota change
```

It also changes:

- per-pod limits,
- per-pod requests,
- HPA service budgets,
- benchmark metadata integrity.

Therefore, ceiling adjustment should be performed as one coordinated batch.

---

## 10. Relationship to MSA Resource Split

This document defines the total application ceiling.

The next methodological question is how that ceiling should be distributed
inside the microservices architecture.

That topic is covered in
[Resource Configuration Methodology](./resource-configuration.md), whose main
rules are:

- monolith and microservices use the same total architecture ceiling,
- microservices do not need identical per-service budgets,
- a role-aware split is preferred over equal per-service slicing,
- fixed mode and HPA mode should remain comparable at the total ceiling level.

In other words:

```text
this document explains how big the budget is
resource-configuration.md explains how the budget is split
```

---

## 11. Practical Summary

If you only need the practical rule, use this:

1. do not assume raw physical node memory is fully usable by the benchmark
   application,
2. start from app-node `allocatable`,
3. subtract `kube-system` and `datadog` overhead on app nodes,
4. round the result into a manifest-friendly ceiling,
5. keep that same total ceiling across monolith and microservices.

For the current measured environment, the practical recommendation is:

```text
final shared ceiling = 15800m CPU / 27648Mi memory
```

This value is the most appropriate basis for final benchmark manifests once
the benchmark execution layer and deployment workflow are ready to be frozen.
