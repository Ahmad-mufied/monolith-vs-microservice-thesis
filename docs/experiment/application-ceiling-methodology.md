# Application Ceiling Methodology

## Purpose

This document explains how the benchmark derives the final application ceiling
from live Vultr VKE measurement.

It answers five questions:

1. why raw node capacity is not used directly,
2. why allocatable capacity matters,
3. why app-node overhead must be considered,
4. how the final Vultr ceiling is rounded,
5. how that ceiling becomes the shared budget for monolith and microservices.

This document defines the size of the total budget.
[Resource Configuration Methodology](./resource-configuration.md) defines how
that total budget is divided inside each architecture.

---

## 1. Core Principle

The benchmark must not treat raw node capacity as fully available to the
application.

Instead, the benchmark uses:

```text
allocatable app-node capacity
- measured safety margin
= final shared application ceiling
```

This avoids overstating the resource budget available to the benchmarked
application pods.

---

## 2. Why Allocatable Is the Starting Point

In Kubernetes, node capacity and node allocatable are not identical.

- `capacity` represents visible hardware capacity,
- `allocatable` represents the portion available for workload scheduling after
  node-level reservation.

The benchmark therefore anchors the resource ceiling to `allocatable`, not to
nominal instance marketing values such as "8 vCPU / 16 GB".

---

## 3. Active Vultr Measurement

For the active Vultr benchmark path, the measurement source of truth is:

- `env/vultr-resource-baseline.env`
- `env/vultr-resource-baseline.json`

Observed benchmark app-node values:

```text
app_node_count        = 1
app_allocatable_cpu   = 7800m
app_allocatable_memory= 15786Mi
safety_cpu            = 0m
safety_memory         = 110Mi
```

Therefore:

```text
CPU ceiling    = 7800m
Memory ceiling = 15786Mi - 110Mi = 15360Mi
```

The final shared application ceiling is:

```text
7800m CPU / 15360Mi memory
```

`15360Mi` is exactly `15Gi`, which is easier to explain and split than the raw
unrounded allocatable memory value.

### 3.1 Mathematical Formulation of Baseline Derivation

To ensure reproducibility and academic rigor in the thesis, the resource quota ceilings are derived using the following mathematical rounding operations:

Let \(C_{\text{allocatable}}\) and \(M_{\text{allocatable}}\) be the total allocatable CPU (in millicores) and Memory (in MiB) aggregated across all active application nodes, and let \(S_{\text{cpu}}\) and \(S_{\text{memory}}\) be the respective safety margins. The final CPU ceiling (\(C_{\text{ceiling}}\)) and Memory ceiling (\(M_{\text{ceiling}}\)) are calculated as:

\[C_{\text{ceiling}} = \left\lfloor \frac{C_{\text{allocatable}} - S_{\text{cpu}}}{100} \right\rfloor \times 100 \text{ m}\]

\[M_{\text{ceiling}} = \left\lfloor \frac{M_{\text{allocatable}} - S_{\text{memory}}}{1024} \right\rfloor \times 1024 \text{ MiB}\]

Where:
- \(C_{\text{allocatable}}\) and \(M_{\text{allocatable}}\) represent the aggregated allocatable resources of all nodes with the label `node-group=app`.
- \(S_{\text{cpu}}\) and \(S_{\text{memory}}\) represent safety margin buffers to protect node stability (by default, \(S_{\text{cpu}} = 0\text{ m}\) and \(S_{\text{memory}} = 110\text{ MiB}\)).
- \(\lfloor \dots \rfloor\) represents the **floor function** (rounding down to the nearest integer).
- The CPU ceiling is rounded down to the nearest \(100\text{ m}\) (millicores) to keep limits clean.
- The Memory ceiling is rounded down to the nearest \(1024\text{ MiB}\) (equivalent to \(1\text{ GiB}\)) to facilitate clean, symmetric division among microservices.

#### Concrete Walkthrough Example (Vultr VKE App Node)

To illustrate the mathematical steps using the live Vultr environment measurements:

1. **CPU Ceiling Calculation**:
   - Total App Node Allocatable (\(C_{\text{allocatable}}\)) = \(7800\text{ m}\)
   - CPU Safety Margin (\(S_{\text{cpu}}\)) = \(0\text{ m}\)
   - Applying the formula:
     \[C_{\text{ceiling}} = \left\lfloor \frac{7800 - 0}{100} \right\rfloor \times 100 = \lfloor 78 \rfloor \times 100 = 7800\text{ m}\]
   - Result: **\(7800\text{ m}\)** (already a multiple of 100m).

2. **Memory Ceiling Calculation**:
   - Total App Node Allocatable (\(M_{\text{allocatable}}\)) = \(15786\text{ MiB}\)
   - Memory Safety Margin (\(S_{\text{memory}}\)) = \(110\text{ MiB}\)
   - Applying the formula:
     \[M_{\text{ceiling}} = \left\lfloor \frac{15786 - 110}{1024} \right\rfloor \times 1024 = \left\lfloor \frac{15676}{1024} \right\rfloor \times 1024 = \lfloor 15.308 \rfloor \times 1024 = 15 \times 1024 = 15360\text{ MiB}\]
   - Result: **\(15360\text{ MiB}\)** (exactly \(15\text{ GiB}\)). This allows a clean division by 4 for the microservices architecture (\(15360 / 4 = 3840\text{ MiB}\) per service).

### 3.2 Auditability and Provenance Data

The generated `env/vultr-resource-baseline.json` file is a machine-readable JSON structure that captures not only the calculated quotas, but also:
1. The exact timestamp of measurement (`measured_at_utc`),
2. The specific Vultr compute plans (`app_node_plan`),
3. The raw `kubectl get nodes` JSON output (`raw_nodes`).

This design guarantees **data provenance** and **auditability** for the thesis. An external evaluator can inspect the JSON file to verify that the experimental resource limits were indeed bound to the physical constraints of the specific hardware used at the time of the experiment, rather than chosen arbitrarily.

---

## 4. Why the Same Ceiling Must Be Used for Both Architectures

The benchmark compares:

- monolith architecture,
- microservices architecture.

To preserve fairness:

```text
monolith ceiling = microservices ceiling
```

For the active Vultr path, both architectures therefore use:

```text
7800m CPU / 15360Mi memory
```

This shared ceiling is then applied through namespace ResourceQuota and
architecture-specific pod settings.

---

## 5. Relation to Fixed and HPA Modes

The final ceiling is shared across both scaling modes:

```text
fixed:
  total active pod limits must equal the architecture ceiling

hpa:
  total maximum pod limits must equal the same architecture ceiling
```

This means the ceiling is not just a ResourceQuota value.
It also constrains:

- monolith fixed pod limits,
- microservices fixed per-service limits,
- microservices HPA per-service total ceilings,
- the fixed monolith baseline that remains active during supplemental HPA runs,
- benchmark metadata that records resource settings.

---

## 6. What This Document Does Not Use

The final Vultr methodology does **not** reuse the historical AWS EKS ceiling
as the final experimental ceiling.

The repository still contains historical AWS-oriented examples in some places,
but those are implementation history, not the active Vultr benchmark baseline.

For the final Vultr path, the source of truth is the live Vultr measurement.

---

## 7. Practical Summary

Use this rule:

1. measure live app-node allocatable capacity on Vultr,
2. subtract the defined safety margin,
3. round memory down to a manifest-friendly value that does not exceed the
   measured usable capacity,
4. apply the same final ceiling to both monolith and microservices.

For the active environment, the final ceiling is:

```text
7800m CPU / 15360Mi memory
```

That is the resource budget that all other benchmark resource documents should
reference.
