# Scaling Mode Strategy

## 1. Purpose

This document explains how fixed mode and the supplemental microservices-only
HPA mode are used in the benchmark, and how both remain comparable under the
active Vultr equal-split resource methodology.

The benchmark uses two scaling modes:

```text
fixed-replica : static pod count
hpa           : CPU-based horizontal pod autoscaling
```

All benchmark variants must preserve the same total application ceiling per
architecture.

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

## 3. Supplemental HPA Mode

The primary benchmark comparison remains fixed mode for both architectures.
The autoscaling extension keeps the monolith on its fixed baseline and enables
HPA only for the microservices deployment. This isolates the architectural
benefit of service-specific elasticity without forcing the monolith into a
smaller per-pod shape that would no longer represent its fixed baseline.

The key rule is:

```text
fixed mode remains the primary architecture baseline
and supplemental HPA must preserve the same total architecture ceiling
```

### 3.1 Monolith During Supplemental HPA Runs

During supplemental HPA benchmark runs, the monolith remains on the fixed
single-pod baseline:

```text
replicas : 1
request  : 3900m CPU / 7680Mi memory
limit    : 7800m CPU / 15360Mi memory
```

This keeps the monolith pod shape identical to the primary benchmark baseline.

### 3.2 Microservices HPA

Each service uses:

```text
minReplicas            : 1
maxReplicas            : 5
target CPU utilization : 50%
request / pod          : 500m CPU / 960Mi memory
limit / pod            : 975m CPU / 1920Mi memory
```

If all services stay at `minReplicas = 1`, the namespace starts with:

```text
4 x 975m   = 3900m CPU limit
4 x 1920Mi = 7680Mi memory limit
```

Remaining shared burst headroom:

```text
7800m - 3900m   = 3900m CPU
15360Mi - 7680Mi = 7680Mi memory
```

That headroom is exactly equal to four more pods of the same HPA size:

```text
4 x 975m   = 3900m CPU
4 x 1920Mi = 7680Mi memory
```

Therefore, the active Vultr supplemental HPA model should be read as:

- 4 baseline pods, one for each service,
- plus up to 4 extra pods shared across the namespace,
- with ResourceQuota and node schedulability acting as the final limiters.

### 3.3 gRPC Load Balancing and Connection Pinning under HPA

During HPA scale-out, HTTP/2 multiplexing in gRPC can cause a "connection pinning" issue where clients continue sending requests to pre-existing pods instead of distributing them to newly scaled pods.

To mitigate this, a dynamic **Server-Side Max Connection Age** policy is implemented:
- **HPA Mode (`SCALING_MODE=hpa`)**: Server connection age is limited to `30s` (via `GRPC_MAX_CONNECTION_AGE_HPA` from [values.yaml](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/env/values.yaml)), forcing clients to re-resolve DNS and load balance round-robin.
- **Fixed Mode (`SCALING_MODE=fixed`)**: Unset (infinite connection age) to preserve baseline performance.

For a detailed technical explanation of the pinning mechanism and implementation details, see [docs/api/grpc-contracts.md#4.2 Connection Pinning and MaxConnectionAge](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/docs/api/grpc-contracts.md#42-connection-pinning-and-maxconnectionage).

---

## 4. Why HPA Still Helps Under Equal Split

Equal split does not make HPA pointless.

Microservices HPA still provides:

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

Remaining limit headroom:

```text
7800m - 3900m = 3900m
```

Therefore, if one service is idle, its not-yet-created extra pods do not block
another service from scaling.

The request headroom is larger than the limit headroom, but the real burst
shape is still capped by namespace limit quota and node schedulability. With
the active HPA pod size, that practical burst ceiling is four additional pods.

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

## 6. Running Fixed and Supplemental HPA Benchmarks

The benchmark workflow now distinguishes clearly between:

- fixed-mode suite runs for the primary architecture matrix, and
- supplemental HPA runs executed through the non-suite benchmark runners.

Use the suite runners only for the fixed matrix:

```bash
make run-benchmark-suite SCALING_MODE=fixed ...
make run-benchmark-suite-sequential SCALING_MODE=fixed ...
```

Use the single-architecture suite or single-case runners for supplemental HPA measurements:

```bash
make run-benchmark-arch-suite ARCHITECTURE=microservices SCALING_MODE=hpa K6_PROFILE=ramp-up ...
make run-benchmark-case SCALING_MODE=hpa K6_PROFILE=ramp-up ...
make run-benchmark-sequential SCALING_MODE=hpa K6_PROFILE=ramp-up ...
make run-benchmark-parallel SCALING_MODE=hpa K6_PROFILE=ramp-up ...
```

This keeps the primary fixed comparison separate from the supporting autoscaling
analysis and avoids rerunning the monolith fixed baseline inside the
single-architecture HPA extension.

## 7. Inter-Case Delay

Fixed and HPA runs are still executed as independent k6 jobs per scenario and
RPS combination. The inter-case delay remains part of the benchmark method.

For `K6_PROFILE=ramp-up`, `TEST_DURATION` should not be read as the total case
duration. The HPA k6 profile uses ramping arrival-rate stages so each HPA case
is approximately 13 minutes before orchestration overhead and inter-case delay.
Use `TEST_DURATION` as the fixed/steady case duration control, not as the HPA
suite duration control.

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

## 8. Practical Summary

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

### Supplemental HPA

```text
monolith:
  remains fixed at the primary baseline
  1 pod
  3900m request / 7800m limit
  7680Mi request / 15360Mi limit

microservices:
  each service starts at 1 pod
  500m request / 975m limit
  960Mi request / 1920Mi limit per pod
  up to 4 replicas per service, bounded by shared namespace headroom
```

These values are the active equal-split reference for Vultr benchmark runs.

> **Note:** Monolith HPA mode is not part of the active benchmark design.
> The monolith remains on its fixed single-pod baseline for all runs including
> single-architecture HPA extension runs. See Section 3.1 for rationale.
