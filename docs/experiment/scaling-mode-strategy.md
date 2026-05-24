# Scaling Mode Strategy

## 1. Purpose

This document describes the two scaling modes used in the benchmark experiment
and explains how each mode relates to the research questions.

The benchmark supports two scaling modes:

```text
fixed-replica   : static pod count, no autoscaling
hpa             : CPU-based horizontal pod autoscaling
```

Both modes use the same resource ceiling to preserve fairness between
monolith and microservices.

---

## 2. Scaling Mode Overview

### 2.1 Fixed-Replica Mode

In fixed-replica mode, each deployment runs with exactly one pod throughout
the benchmark. HPA is not applied. The pod count does not change regardless
of CPU utilization.

Manifests:

```text
deployments/k8s/monolith/resource-management-fixed.yaml
deployments/k8s/microservices/resource-management-fixed.yaml
```

These manifests apply only the ResourceQuota. No HPA object is created.

Monolith fixed configuration:

```text
replicas : 1
CPU      : 1000m request = 1000m limit
Memory   : 1024Mi request = 1024Mi limit
```

Microservices fixed configuration (per service):

```text
replicas : 1 per service (api-gateway, auth-service, item-service, transaction-service)
api-gateway         : request 100m / limit 250m / 256Mi / 384Mi
auth-service        : request 250m / limit 1000m / 256Mi / 768Mi
item-service        : request 100m / limit 250m / 256Mi / 384Mi
transaction-service : request 150m / limit 500m / 256Mi / 512Mi
```

Total active resources in fixed mode:

| Architecture | Pods | CPU requests | CPU limits | Memory requests | Memory limits |
|---|---:|---:|---:|---:|---:|
| Monolith | 1 | 1000m | 1000m | 1024Mi | 1024Mi |
| Microservices | 4 (1 per service) | 600m | 2000m | 1024Mi | 2048Mi |

Both architectures remain bounded by the same namespace ResourceQuota ceiling
of `4000m CPU / 4096Mi memory`. The MSA pod-level requests and limits are
role-aware rather than equal `250m` slices.

---

### 2.2 HPA Mode

In HPA mode, each deployment is managed by a HorizontalPodAutoscaler. The
HPA scales the pod count up or down based on average CPU utilization relative
to the configured target.

Manifests:

```text
deployments/k8s/monolith/resource-management-hpa.yaml
deployments/k8s/microservices/resource-management-hpa.yaml
```

These manifests apply the ResourceQuota and all HPA objects.

Monolith HPA configuration:

```text
minReplicas          : 1
maxReplicas          : 4
HPA target CPU       : 70%
CPU per pod          : 1000m
Max total CPU        : 4000m
Scale-down window    : 60s
```

Microservices HPA configuration (per service):

```text
minReplicas          : 1 per service
HPA target CPU       : 70%
Namespace CPU quota  : 4000m
Scale-down window    : 60s
```

Role-aware service configuration:

```text
api-gateway         : request 100m / limit 250m / maxReplicas 9
auth-service        : request 250m / limit 1000m / maxReplicas 3
item-service        : request 100m / limit 250m / maxReplicas 9
transaction-service : request 150m / limit 500m / maxReplicas 5
```

The namespace ResourceQuota caps total MSA CPU at 4000m regardless of how
many services scale out simultaneously. This keeps the total resource ceiling
equivalent to the monolith.

The HPA manifests also set `behavior.scaleDown.stabilizationWindowSeconds: 60`
to make post-benchmark scale-in visibly more responsive than the Kubernetes
default `300s` downscale stabilization window.

---

## 3. Relationship to Research Questions

### 3.1 RQ1 — Performance

RQ1 asks:

```text
How does the performance of monolithic and microservices architectures compare
when handling equivalent workloads in a cloud-native environment based on
Kubernetes orchestration, based on latency, throughput, and error rate?
```

**Recommended mode for RQ1: fixed-replica**

Reason:

Fixed-replica mode eliminates autoscaling as a variable. Both architectures
run with a known, stable pod count throughout the benchmark. This makes the
latency, throughput, and error rate comparison cleaner because the result
reflects the architectural difference, not the scaling behavior.

If HPA mode is used for RQ1, the result must be labeled as:

```text
performance under HPA-enabled Kubernetes environment
```

This is a valid result but requires more careful interpretation because
latency may spike during scale-up events and stabilize after new pods become
ready.

**Primary data source for RQ1:**

```text
k6 summary.json
  → http_req_duration p90, p95
  → http_reqs rate (achieved RPS)
  → http_req_failed rate (error rate)
  → dropped_iterations count
```

Datadog is used as supporting evidence to explain why the k6 result occurred,
not as the primary data source for RQ1 tables.

---

### 3.2 RQ2 — Resource Efficiency

RQ2 asks:

```text
How does CPU and memory resource efficiency compare between monolithic and
microservices architectures when handling equivalent workloads in a
cloud-native environment based on Kubernetes orchestration?
```

**Fixed-replica mode is sufficient for RQ2 core.**

CPU and memory usage is observable from Datadog regardless of whether HPA
is active. In fixed-replica mode, Datadog still captures:

```text
CPU_monolith_total   = CPU usage of the monolith pod
CPU_MSA_total        = CPU(api-gateway) + CPU(auth-service)
                     + CPU(item-service) + CPU(transaction-service)

Memory_monolith_total   = memory usage of the monolith pod
Memory_MSA_total        = Memory(api-gateway) + Memory(auth-service)
                        + Memory(item-service) + Memory(transaction-service)
```

These values are sufficient to calculate the derived efficiency metrics:

```text
RPS per CPU core = achieved RPS / average CPU cores
CPU core-seconds per 1000 requests
Memory MiB per 1000 achieved RPS
```

Fixed-replica mode also reveals the **idle overhead** of the microservices
architecture — all four services run continuously even when only one is
under load, which is part of the operational cost of the distributed design.

**HPA mode adds optional supporting analysis for RQ2:**

If HPA mode is also run, the following additional observations become
available:

- which service scaled under which scenario,
- whether granular scaling reduced total resource usage compared to monolith,
- how quickly scaling stabilized after load increased,
- whether ResourceQuota contention occurred across MSA services.

This is supporting evidence, not the core RQ2 answer. The core answer comes
from CPU and memory comparison under equivalent load, which fixed-replica
mode already provides.

**Recommended approach:**

```text
Minimum: fixed-replica mode
  → answers RQ2 core (CPU/memory efficiency comparison)

Optional: also run HPA mode
  → adds HPA behavior analysis as supporting evidence
  → strengthens Chapter 4 narrative about cloud-native scaling
```

**Primary data source for RQ2:**

```text
Datadog
  → average CPU usage per pod / per service / per architecture
  → p95 CPU usage
  → average memory usage
  → replica count timeline (HPA mode only)
  → HPA desired vs current replicas (HPA mode only)
```

---

## 4. K6_PROFILE and Manifest Convention

`K6_PROFILE` controls the load pattern k6 uses. The Kubernetes manifest
controls whether HPA is active. These are independent settings, but they
must be used together consistently.

### 4.1 Valid Combinations

| `K6_PROFILE` | Required manifest | Valid | Purpose |
|---|---|---|---|
| `steady` | `resource-management-fixed.yaml` | ✅ | RQ1 primary — constant load, fixed replicas, clean comparison |
| `ramp` | `resource-management-fixed.yaml` | ✅ | Fixed replicas under gradually increasing load |
| `smoke` | `resource-management-fixed.yaml` | ✅ | Functional validation before benchmark |
| `hpa` | `resource-management-hpa.yaml` | ✅ | RQ2 primary — ramping load triggers HPA scale-up |
| `hpa` | `resource-management-fixed.yaml` | ❌ | Invalid — ramping load but no HPA to react, produces no autoscaling data |
| `steady` | `resource-management-hpa.yaml` | ⚠️ | Allowed but HPA may not scale before benchmark ends since load is full from the start |

### 4.2 Core Rule

```text
K6_PROFILE=hpa   → must use resource-management-hpa.yaml
All other profiles → must use resource-management-fixed.yaml
```

Additional operational rule:

```text
Changing benchmark SCALING_MODE alone does not switch the live app stack.
```

The live scaling mode changes only after the matching deploy step is rerun:

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa

SCALING_MODE=hpa make eks-deploy-monolith
SCALING_MODE=hpa make eks-deploy-msa
```

Always treat a mode switch as a redeploy event.

### 4.3 K6_PROFILE=hpa Load Pattern

When `K6_PROFILE=hpa` is used, k6 applies a ramping arrival rate designed
to give HPA enough time to observe CPU pressure and scale pods:

```text
Stage 1: ramp to 25% of TARGET_RPS over 2 minutes  (HPA_RAMP_UP_1)
Stage 2: ramp to 50% of TARGET_RPS over 2 minutes  (HPA_RAMP_UP_2)
Stage 3: ramp to 100% of TARGET_RPS over 3 minutes (HPA_RAMP_UP_3)
Stage 4: hold at 100% of TARGET_RPS for 5 minutes  (HPA_HOLD)
Stage 5: ramp down to 0 over 1 minute              (HPA_RAMP_DOWN)
```

All stage durations are configurable via environment variables. The defaults
above are designed to allow HPA to observe sustained CPU pressure at each
level before the next stage begins.

HPA reacts to average CPU utilization over a rolling window (default 15
seconds in Kubernetes). The ramp stages ensure CPU pressure builds gradually
so the HPA controller has time to calculate desired replicas, schedule new
pods, and allow them to become ready before the next load increase.

### 4.4 Why K6_PROFILE=hpa Must Not Be Used with Fixed Manifest

If `resource-management-fixed.yaml` is applied and `K6_PROFILE=hpa` is used:

- Load ramps up gradually as designed
- CPU pressure increases on the fixed pod(s)
- No HPA object exists to trigger scale-out
- Pods may become overloaded or start dropping requests
- The result shows fixed-replica behavior under ramping load, not autoscaling behavior

This combination produces misleading data for RQ2 because the intent of
`K6_PROFILE=hpa` is to observe autoscaling, not to stress fixed replicas.

### 4.5 Why K6_PROFILE=steady Should Not Be Used with HPA Manifest

If `resource-management-hpa.yaml` is applied and `K6_PROFILE=steady` is used:

- Load starts at full TARGET_RPS immediately
- CPU pressure spikes before HPA has time to react
- HPA may scale up, but the initial spike may already cause latency or errors
- The scaling behavior is harder to observe cleanly

This combination is allowed but should be labeled explicitly as
`steady load under HPA-enabled environment` and interpreted with care.

### 4.6 Operator Checklist Before Running k6

Before starting any benchmark run, verify the manifest and profile match:

```text
[ ] Confirm which scaling mode is intended (fixed or hpa)
[ ] Redeploy the app stack with the intended SCALING_MODE
[ ] Verify HPA objects exist (hpa mode) or do not exist (fixed mode):
      kubectl get hpa -n mono
      kubectl get hpa -n msa
[ ] Confirm replica count matches expectation:
      kubectl get deploy -n mono
      kubectl get deploy -n msa
[ ] Set K6_PROFILE in the benchmark Job or env file to match the manifest
[ ] Record autoscaling_mode in RESOURCES_CONFIGURATION_JSON for metadata.json
```

---

## 5. Recommended Experiment Plan

Run both modes to answer both research questions cleanly.

```text
Phase 1 — Fixed-replica benchmark (RQ1 primary data)
  → redeploy app stack with SCALING_MODE=fixed
  → verify HPA objects are absent and replicas=1
  → run login, create-transaction, enriched-transactions scenarios
  → collect k6 summary.json per attempt
  → upload to S3

Phase 2 — HPA benchmark (RQ2 primary data)
  → redeploy app stack with SCALING_MODE=hpa
  → verify HPA objects are present
  → run same scenarios at same target RPS
  → collect k6 summary.json per attempt
  → collect Datadog CPU/memory/replica data via time window
  → upload to S3
```

Do not mix fixed-replica results and HPA results in the same comparison table
without explicit labeling.

---

## 6. How to Switch Between Modes

### 6.1 Switch to Fixed-Replica Mode

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa

# Verify
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

### 6.2 Switch to HPA Mode

```bash
SCALING_MODE=hpa make eks-deploy-monolith
SCALING_MODE=hpa make eks-deploy-msa

# Verify HPA is active
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

### 6.3 Safe Recovery for HPA -> Fixed Transition

If a fixed-mode deploy is started while the live MSA stack is still expanded by
HPA, the migration jobs can be rejected by `msa-resource-quota` before the
deploy script reaches the fixed-mode scaling step.

Observed symptom:

```text
exceeded quota: msa-resource-quota, requested: limits.cpu=100m, used: limits.cpu=4, limited: limits.cpu=4
```

Safe recovery:

```bash
# stop invalid benchmark jobs
kubectl --context=monolith delete job k6-benchmark-monolith -n benchmark --ignore-not-found
kubectl --context=msa delete job k6-benchmark-microservices -n benchmark --ignore-not-found

# release stale MSA HPA state
kubectl --context=msa delete hpa --all -n msa
kubectl --context=msa scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa

# clear stuck migration jobs if they already exist
kubectl --context=msa delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found

# rerun the intended fixed-mode deploy
SCALING_MODE=fixed make eks-deploy-msa
```

---

## 7. Fairness Rules

Both modes preserve the same resource ceiling:

```text
Monolith namespace CPU ceiling  : 4000m
MSA namespace CPU ceiling       : 4000m

Monolith namespace memory ceiling : 4096Mi
MSA namespace memory ceiling      : 4096Mi
```

These ceilings are the application comparison baseline. Datadog remains enabled
on both architectures during measured runs, so monitoring-agent usage is
treated as identical cluster-level observability overhead rather than as part
of an architecture-specific optimization.

In fixed mode, both architectures run one unit of each workload, but the MSA
services use role-aware requests and limits instead of equal `250m` slices.

In HPA mode, both architectures can scale up to 4000m total CPU before the
ResourceQuota blocks further scheduling.

Do not compare:

```text
fixed-replica result vs HPA result without explicit label
different target RPS between architectures
different duration between architectures
Minikube result vs EKS result
```

---

## 8. Metadata Labeling

Each benchmark attempt must record the scaling mode in `metadata.json`:

```json
{
  "resources": {
    "autoscaling_mode": "fixed-replica",
    "hpa_enabled": false,
    "replica_count": 1
  }
}
```

or:

```json
{
  "resources": {
    "autoscaling_mode": "hpa",
    "hpa_enabled": true,
    "min_replicas": 1,
    "max_replicas": 4
  }
}
```

This is already supported by the `RESOURCES_CONFIGURATION_JSON` env var in
`k6/runner/run-k6.sh` and the benchmark Job YAML templates.

---

## 9. HPA Behavior Data

When running in HPA mode, HPA behavior is observed through Datadog:

- replica count over time per deployment,
- HPA desired vs current replicas timeline,
- CPU utilization that triggered scaling events.

If manual HPA snapshots are needed for a specific run, collect them directly:

```bash
kubectl get hpa -n mono -o yaml > hpa-state-mono.yaml
kubectl describe hpa -n mono > hpa-describe-mono.txt

kubectl get hpa -n msa -o yaml > hpa-state-msa.yaml
kubectl describe hpa -n msa > hpa-describe-msa.txt
```

These are optional. Datadog is the primary source for HPA behavior analysis.

---

## 10. Summary

| Aspect | Fixed-Replica | HPA |
|---|---|---|
| Pod count | Static (1 per unit) | Dynamic (1 to max) |
| Scaling variable | Eliminated | Present |
| Primary use | RQ1 + RQ2 core (clean, no scaling variable) | RQ1 under autoscaling + RQ2 with HPA behavior |
| Data source | k6 summary.json | k6 summary.json + Datadog |
| Manifest | `resource-management-fixed.yaml` | `resource-management-hpa.yaml` |
| K6_PROFILE | `steady`, `ramp`, `smoke` | `hpa` |
| Fairness basis | Equal active resources at start | Equal resource ceiling |
| Result label | `autoscaling_mode: fixed-replica` | `autoscaling_mode: hpa` |

HPA mode produces data for both research questions simultaneously:

```text
RQ1 — latency, RPS, error rate under autoscaling-enabled environment
RQ2 — HPA scaling behavior as supporting evidence
```

Fixed-replica mode is sufficient for both RQ1 and RQ2 core analysis:

```text
RQ1 — clean latency, RPS, error rate comparison without scaling variable
RQ2 — CPU and memory efficiency comparison (Datadog, architecture-level)
```

Both modes must be run and labeled separately. Results must not be mixed in
the same comparison table without explicit labeling of the scaling mode.
