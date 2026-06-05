# Scaling Mode Strategy

## 1. Purpose

This document explains how fixed mode and HPA mode are used in the benchmark,
and how both modes remain comparable under the active Vultr equal-split
resource methodology.

The benchmark uses two scaling modes:

```text
fixed-replica : static pod count
hpa           : CPU-based horizontal pod autoscaling
```

Both modes must preserve the same total application ceiling per architecture.

For the active Vultr benchmark path, that ceiling is:

```text
CPU    = 7800m
Memory = 15360Mi
```

---

## 2. Fixed Mode

Fixed mode is the static baseline:

- no HPA objects are applied,
- pod count does not change during the run,
- total active limits already represent the final architecture ceiling.

### 2.1 Monolith Fixed

```text
replicas : 1
request  : 3900m CPU / 7680Mi memory
limit    : 7800m CPU / 15360Mi memory
```

### 2.2 Microservices Fixed

The active Vultr methodology uses equal split across the four services:

```text
per-service ceiling = 1950m CPU / 3840Mi memory
```

Fixed per-service values:

| Service | Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|
| `api-gateway` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `auth-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `item-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `transaction-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |

Total active MSA limits:

```text
4 x 1950m   = 7800m CPU
4 x 3840Mi  = 15360Mi memory
```

Interpretation:

- fixed mode compares one monolith pod versus four always-on microservice pods,
- fairness is preserved at the architecture ceiling level,
- fixed mode intentionally includes idle-service overhead in the MSA result.

---

## 3. HPA Mode

HPA mode keeps the same architecture ceiling, but distributes it across
possible replicas.

The key rule is:

```text
fixed mode and hpa mode may differ in pod shape,
but must preserve the same total ceiling
```

### 3.1 Monolith HPA

```text
minReplicas            : 1
maxReplicas            : 4
target CPU utilization : 70%
request / pod          : 970m CPU / 1920Mi memory
limit / pod            : 1950m CPU / 3840Mi memory
```

Maximum monolith ceiling:

```text
4 x 1950m   = 7800m CPU
4 x 3840Mi  = 15360Mi memory
```

### 3.2 Microservices HPA

Each service keeps the same equal-split ceiling:

```text
1950m CPU / 3840Mi memory per service
```

Each service uses:

```text
minReplicas            : 1
maxReplicas            : 2
target CPU utilization : 70%
request / pod          : 500m CPU / 960Mi memory
limit / pod            : 975m CPU / 1920Mi memory
```

Per-service maximum:

```text
2 x 975m   = 1950m CPU
2 x 1920Mi = 3840Mi memory
```

If all four services scale to their maximum:

```text
CPU request total = 4 x 2 x 500m   = 4000m
CPU limit total   = 4 x 2 x 975m   = 7800m
Mem request total = 4 x 2 x 960Mi  = 7680Mi
Mem limit total   = 4 x 2 x 1920Mi = 15360Mi
```

This keeps HPA mathematically aligned with fixed mode.

---

## 4. Why HPA Still Helps Under Equal Split

Equal split does not make HPA pointless.

HPA still provides:

- automatic scale-out when one service experiences higher CPU load,
- lower active footprint when services stay at `minReplicas`,
- scenario-sensitive replica behavior without manual per-scenario redeploy.

The important nuance is:

```text
maxReplicas is not pre-reserved
```

Only running pods contribute active requests and limits.

With all services at `minReplicas = 1`, MSA request usage is:

```text
api-gateway         = 500m
auth-service        = 500m
item-service        = 500m
transaction-service = 500m
Total               = 2000m
```

Remaining request headroom:

```text
7800m - 2000m = 5800m
```

Therefore, if one service is idle, the not-yet-created second pod for that
service does not block another service from scaling.

---

## 5. Why This Study Uses Equal Split Instead of Role-Aware HPA

The active Vultr documentation path intentionally avoids role-aware replica
shapes and role-aware service ceilings.

Reason:

- the study does not include a profiling dataset that justifies asymmetric
  per-service budgets,
- equal split is easier to explain and reproduce,
- equal split reduces the risk that benchmark conclusions are driven by manual
  service favoritism.

This means the study chooses:

```text
allocation neutrality over service-specific tuning
```

That trade-off should be stated explicitly in the thesis.

---

## 6. Inter-Case Delay

Fixed and HPA runs are still executed as independent k6 jobs per scenario and
RPS combination. The inter-case delay remains part of the benchmark method.

Recommended values:

| Scaling mode | Suggested inter-case delay |
|---|---:|
| `fixed` | `60`-`120` seconds |
| `hpa` | `180`-`300` seconds |

Why:

- fixed mode mainly needs recovery time for application state, PostgreSQL
  pressure, and Datadog telemetry,
- HPA mode also needs time for replica changes and scale-down stabilization.

For smoke tests and quick calibration, `INTER_CASE_DELAY=0` remains acceptable.

---

## 7. Practical Summary

Use these rules for the active Vultr benchmark path:

### Fixed

```text
monolith:
  1 pod
  3900m request / 7800m limit
  7680Mi request / 15360Mi limit

microservices:
  1 pod per service
  980m request / 1950m limit
  1920Mi request / 3840Mi limit
```

### HPA

```text
monolith:
  min 1 max 4
  970m request / 1950m limit
  1920Mi request / 3840Mi limit

microservices:
  min 1 max 2 for each service
  500m request / 975m limit
  960Mi request / 1920Mi limit
```

These values are the active equal-split reference for Vultr benchmark runs.
