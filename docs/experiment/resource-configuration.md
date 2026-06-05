# Resource Configuration Methodology

## Purpose

This document defines how the benchmark translates the final application
ceiling into concrete pod-level resource settings for the active Vultr VKE
benchmark path.

It answers four methodological questions:

1. what fairness means for monolith versus microservices,
2. why the microservices resource budget is divided equally across services,
3. how fixed mode and HPA mode remain comparable,
4. how the chosen split should be justified in the thesis.

The total application ceiling itself is defined in
[Application Ceiling Methodology](./application-ceiling-methodology.md).
This document explains how that ceiling is divided inside each architecture.

---

## 1. Core Fairness Rule

The primary fairness rule is:

```text
equal total application ceiling per architecture
```

This means:

- monolith receives one architecture-level CPU and memory budget,
- microservices receive the same architecture-level CPU and memory budget,
- any internal split inside microservices must not increase the total budget.

For the active Vultr path, the measured benchmark ceiling is:

```text
CPU    = 7800m
Memory = 15360Mi
```

These values come from the live benchmark app-node measurement recorded in
`env/vultr-resource-baseline.env` and `env/vultr-resource-baseline.json`.

---

## 2. Why This Study Uses Equal Split

The microservices architecture contains four independently deployable services:

- `api-gateway`
- `auth-service`
- `item-service`
- `transaction-service`

In principle, the resource budget could be divided using a role-aware split.
However, this study does **not** use role-aware allocation as the final Vultr
benchmark method.

The reason is methodological, not technical:

- the study does not include a separate empirical profiling phase that
  quantifies per-service resource demand,
- no production traffic distribution is available to justify asymmetric
  per-service budgets,
- choosing larger or smaller budgets for specific services would introduce a
  researcher-selected assumption that is difficult to defend quantitatively.

Therefore, the final Vultr benchmark uses:

```text
equal total architecture budget
+ equal per-service split inside microservices
```

This keeps the internal MSA allocation:

- simple,
- transparent,
- easy to reproduce,
- less dependent on subjective tuning decisions.

This design does **not** claim that all services perform identical work.
Instead, it claims that equal split is the most defensible baseline when no
empirical service-level profiling dataset is available.

---

## 3. Equal-Split Formula

The active Vultr microservices architecture has four services.

The equal-split formula is therefore:

```text
per-service CPU ceiling    = total CPU ceiling / 4
per-service memory ceiling = total memory ceiling / 4
```

Using the active Vultr ceiling:

```text
CPU per service    = 7800m / 4    = 1950m
Memory per service = 15360Mi / 4  = 3840Mi
```

This produces the final microservices service-level ceiling:

```text
api-gateway         = 1950m CPU / 3840Mi memory
auth-service        = 1950m CPU / 3840Mi memory
item-service        = 1950m CPU / 3840Mi memory
transaction-service = 1950m CPU / 3840Mi memory
```

Total:

```text
4 x 1950m   = 7800m
4 x 3840Mi  = 15360Mi
```

---

## 4. Fixed Mode

In fixed mode:

- monolith runs as one deployment,
- microservices run as one pod per service,
- pod count is static,
- HPA is disabled.

### 4.1 Monolith Fixed Configuration

The monolith keeps the full architecture ceiling in one running pod:

```text
replicas : 1
request  : 3900m CPU / 7680Mi memory
limit    : 7800m CPU / 15360Mi memory
```

### 4.2 Microservices Fixed Configuration

Each service receives one quarter of the architecture ceiling:

| Service | Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---:|---:|---:|---:|---:|
| `api-gateway` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `auth-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `item-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| `transaction-service` | `1` | `980m` | `1950m` | `1920Mi` | `3840Mi` |
| **Total** | **4** | **3920m** | **7800m** | **7680Mi** | **15360Mi** |

Interpretation:

- total CPU limit equals the architecture ceiling,
- total memory limit equals the architecture ceiling,
- total requests remain below the ceiling to avoid request-only saturation.

---

## 5. HPA Mode

In HPA mode:

- monolith uses CPU-based HPA,
- each microservice also uses CPU-based HPA,
- fixed and HPA must preserve the same total service-level ceiling.

The comparison rule is:

```text
fixed mode:
  total service ceiling is active immediately

hpa mode:
  total service ceiling is identical
  but distributed across multiple possible replicas
```

### 5.1 Monolith HPA Configuration

```text
minReplicas            : 1
maxReplicas            : 4
target CPU utilization : 70%
request / pod          : 970m CPU / 1920Mi memory
limit / pod            : 1950m CPU / 3840Mi memory
```

This preserves:

```text
4 x 1950m   = 7800m CPU max
4 x 3840Mi  = 15360Mi memory max
```

### 5.2 Microservices HPA Configuration

The equal-split service ceiling remains:

```text
1950m CPU / 3840Mi memory per service
```

To preserve that ceiling while enabling scale-out, each service uses:

```text
minReplicas            : 1
maxReplicas            : 2
target CPU utilization : 70%
```

Per-pod resources:

| Service | Min | Max | CPU Request / Pod | CPU Limit / Pod | Memory Request / Pod | Memory Limit / Pod |
|---|---:|---:|---:|---:|---:|---:|
| `api-gateway` | `1` | `2` | `500m` | `975m` | `960Mi` | `1920Mi` |
| `auth-service` | `1` | `2` | `500m` | `975m` | `960Mi` | `1920Mi` |
| `item-service` | `1` | `2` | `500m` | `975m` | `960Mi` | `1920Mi` |
| `transaction-service` | `1` | `2` | `500m` | `975m` | `960Mi` | `1920Mi` |

If a service scales to `maxReplicas = 2`, its total service ceiling becomes:

```text
2 x 975m   = 1950m CPU
2 x 1920Mi = 3840Mi memory
```

Therefore, if all services reach max replicas simultaneously:

```text
CPU request total = 4 services x 2 pods x 500m   = 4000m
CPU limit total   = 4 services x 2 pods x 975m   = 7800m
Memory request    = 4 services x 2 pods x 960Mi  = 7680Mi
Memory limit      = 4 services x 2 pods x 1920Mi = 15360Mi
```

This keeps HPA mode mathematically aligned with fixed mode.

---

## 6. Idle Service Headroom

HPA does not reserve `maxReplicas` in advance.

Only running pods contribute active requests and limits.

For the equal-split HPA configuration, all services at `minReplicas = 1`
consume:

```text
api-gateway         = 500m request
auth-service        = 500m request
item-service        = 500m request
transaction-service = 500m request
Total               = 2000m request
```

Remaining request headroom:

```text
7800m - 2000m = 5800m
```

This means:

- if one service is idle, its not-yet-created second pod does not reserve
  request or limit,
- another service with higher load can use the remaining namespace headroom to
  scale,
- the active guardrails remain the namespace ResourceQuota and node-level
  schedulability.

This is one reason why the equal-split HPA design remains operationally useful
even though it does not tune each service differently.

---

## 7. Why Equal Split Is Defensible for the Thesis

The equal-split design is justified by the following argument:

1. the total benchmark ceiling is derived empirically from live Vultr
   measurement,
2. the internal microservices split is not supported by an independent
   per-service profiling dataset,
3. therefore, the least assumption-heavy internal split is equal division
   across the four services,
4. fixed mode and HPA preserve the same total service-level ceiling, so the
   comparison focuses on scaling behavior rather than manual service tuning.

Suggested thesis wording:

```text
This study uses uniform per-service resource allocation for the microservices
architecture. The choice was made because the benchmark includes a shared
architecture-level resource ceiling derived from live infrastructure
measurement, but does not include a separate empirical profiling phase to
justify asymmetric service budgets. Equal division across the four services was
therefore selected as the most transparent and reproducible baseline.
```

---

## 8. What This Method Does Not Claim

This method does not claim that:

- all microservices consume identical CPU in reality,
- all microservices consume identical memory in reality,
- equal split is the globally optimal deployment strategy.

Instead, it claims only that:

```text
equal split is the most defensible neutral baseline
when service-specific tuning evidence is unavailable
```

That is a narrower and more defensible methodological claim.

---

## 9. Practical Summary

For the active Vultr benchmark path, use the following rules:

1. final architecture ceiling:
   `7800m CPU / 15360Mi memory`
2. monolith fixed:
   `1 pod`, `3900m/7800m`, `7680Mi/15360Mi`
3. microservices fixed:
   `4 services`, each `980m/1950m`, `1920Mi/3840Mi`
4. monolith HPA:
   `min 1 max 4`, `970m/1950m`, `1920Mi/3840Mi`
5. microservices HPA:
   `min 1 max 2` for each service,
   `500m/975m`, `960Mi/1920Mi` per pod

These values are the source of truth for the final equal-split Vultr
documentation path.
