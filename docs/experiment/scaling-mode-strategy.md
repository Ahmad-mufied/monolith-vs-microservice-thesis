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

In fixed-replica mode, each deployment runs with a static replica count
throughout the benchmark. HPA is not applied. The pod count does not change
regardless of CPU utilization.

Manifests:

```text
deployments/k8s/eks/monolith/overlays/fixed
deployments/k8s/eks/microservices/overlays/fixed
```

These Kustomize overlays render the fixed-replica Deployment resources plus
the namespace ResourceQuota. No HPA object is created.

Monolith fixed configuration:

```text
replicas : 2
CPU      : 3950m request / 7900m limit per pod
Memory   : 6912Mi request / 13824Mi limit per pod
```

Microservices fixed configuration (per service):

```text
replicas : 1 per service (api-gateway, auth-service, item-service, transaction-service)
api-gateway         : request 500m / limit 2000m / 864Mi / 3456Mi
auth-service        : request 1500m / limit 4000m / 2592Mi / 6912Mi
item-service        : request 1000m / limit 3000m / 1728Mi / 5184Mi
transaction-service : request 2000m / limit 6800m / 3456Mi / 12096Mi
```

Total active resources in fixed mode:

| Architecture | Pods | CPU requests | CPU limits | Memory requests | Memory limits |
|---|---:|---:|---:|---:|---:|
| Monolith | 2 | 7900m | 15800m | 13824Mi | 27648Mi |
| Microservices | 4 (1 per service) | 5000m | 15800m | 8640Mi | 27648Mi |

Both architectures remain bounded by the same namespace ResourceQuota ceiling
of `15800m CPU / 27648Mi memory`. The MSA pod-level requests and limits are
role-aware rather than equal `250m` slices.

The broader methodology for why the MSA split is role-aware instead of equal
per-service slicing is documented in
`docs/experiment/resource-configuration.md`.

---

### 2.2 HPA Mode

In HPA mode, each deployment is managed by a HorizontalPodAutoscaler. The
HPA scales the pod count up or down based on average CPU utilization relative
to the configured target.

Manifests:

```text
deployments/k8s/eks/monolith/overlays/hpa
deployments/k8s/eks/microservices/overlays/hpa
```

These Kustomize overlays render the HPA-mode Deployment resources, the
namespace ResourceQuota, and all HPA objects.

Monolith HPA configuration:

```text
minReplicas            : 2
maxReplicas            : 4
HPA target CPU         : 70%
CPU request / limit    : 1975m / 3950m per pod
Memory request / limit : 3456Mi / 6912Mi per pod
Max total CPU          : 15800m
Max total memory       : 27648Mi
Scale-down window      : 60s
```

Microservices HPA configuration (per service):

```text
minReplicas          : 1 per service
HPA target CPU       : 70%
Namespace CPU quota  : 15800m
Namespace memory quota: 27648Mi
Scale-down window    : 60s
```

Role-aware service configuration:

```text
api-gateway         : request 250m / limit 500m / 432Mi / 864Mi / maxReplicas 4
auth-service        : request 500m / limit 1000m / 864Mi / 1728Mi / maxReplicas 4
item-service        : request 250m / limit 500m / 432Mi / 864Mi / maxReplicas 6
transaction-service : request 850m / limit 1700m / 1512Mi / 3024Mi / maxReplicas 4
```

The namespace ResourceQuota caps total MSA CPU at 15800m and memory at
27648Mi regardless of how many services scale out simultaneously. This keeps the total resource ceiling
equivalent to the monolith.

The HPA manifests also set `behavior.scaleDown.stabilizationWindowSeconds: 60`
to make post-benchmark scale-in visibly more responsive than the Kubernetes
default `300s` downscale stabilization window.

---

## 2.3 Benchmark Suite Inter-Case Delay

Fixed and HPA modes are evaluated through independent k6 jobs for each
scenario/RPS combination. The numeric RPS level is therefore a discrete
experiment point, not a continuous ramp. The suite runner may insert an
inter-case delay between cases through `INTER_CASE_DELAY`.

Recommended final-run values:

| Scaling mode | Suggested inter-case delay | Purpose |
|---|---:|---|
| fixed | `60`-`120` seconds | Let application pods, PostgreSQL pressure, and Datadog metrics settle before the next independent RPS point. |
| hpa | `180`-`300` seconds | Let HPA CPU metrics, replica changes, scale-down behavior, and Datadog telemetry settle before the next independent RPS point. |

The inter-case delay is part of the experiment methodology, not part of the k6
load model. The runner accepts a non-negative integer value in seconds and
rejects values above `86400` seconds to avoid accidental multi-day pauses.
Duration suffixes such as `5m` are not supported; use `300` for five minutes.
If a suite contains only one case, the inter-case delay is skipped. k6
`gracefulStop` only controls how in-flight iterations finish inside one run. It
does not provide a recovery gap between separate runs.

For smoke tests and quick calibration, use `INTER_CASE_DELAY=0`. For measured
Bab 4 runs, record the chosen inter-case delay in the suite manifest and keep it
consistent across monolith and microservices comparisons.

---

## 3. Understanding CPU and Memory Units

The benchmark uses Amazon EC2 instance types for worker nodes, but Kubernetes
manifests express application resources using Kubernetes resource units. The
same physical capacity is therefore described with different notation at
different layers.

```text
EC2 node layer          : vCPU and GB
Kubernetes resource    : CPU / millicpu and Mi / Gi
Pod configuration      : requests and limits
Namespace guardrail    : ResourceQuota
```

### 3.1 CPU: vCPU, CPU, and millicpu

In Kubernetes, CPU can be written as a whole CPU value or as millicpu:

```text
1000m = 1 CPU
500m  = 0.5 CPU
250m  = 0.25 CPU
100m  = 0.1 CPU
4000m = 4 CPU
```

The `m` suffix means millicpu. It is useful because Kubernetes often needs to
schedule pods that consume fractions of a CPU core.

For this benchmark, app nodes use `c8i.2xlarge`. Each `c8i.2xlarge` provides:

```text
8 vCPU
16 GiB-class memory
```

For practical benchmark reasoning:

```text
8 vCPU ~= 8 Kubernetes CPU ~= 8000m
```

This means a pod with `cpu: 1000m` uses a request or limit equivalent to one
CPU. A pod with `cpu: 250m` uses one quarter of a CPU.

### 3.2 Memory: GB, Gi, and Mi

Kubernetes usually expresses memory in binary units:

```text
1024Mi = 1Gi
2048Mi = 2Gi
4096Mi = 4Gi
8192Mi = 8Gi
```

`Mi` means mebibyte and `Gi` means gibibyte. These are close to MB and GB in
everyday language, but they are based on 1024 rather than 1000.

For practical benchmark reasoning:

```text
8Gi ~= 8192Mi
4Gi ~= 4096Mi
1Gi ~= 1024Mi
```

So a pod with `memory: 1024Mi` requests or limits roughly one GiB of memory.
Likewise, a namespace quota of `27648Mi` corresponds to exactly `27Gi` of
application budget.

### 3.3 Mapping Repository Values to c8i.2xlarge Capacity

The following table maps common repository resource values to the approximate
capacity of one `c8i.2xlarge` app node.

| Repo value | Kubernetes meaning | Approximate share of one `c8i.2xlarge` |
|---|---|---:|
| `100m` CPU | 0.1 CPU | 1.25% of 8 vCPU |
| `150m` CPU | 0.15 CPU | 1.875% of 8 vCPU |
| `250m` CPU | 0.25 CPU | 3.125% of 8 vCPU |
| `500m` CPU | 0.5 CPU | 6.25% of 8 vCPU |
| `1000m` CPU | 1 CPU | 12.5% of 8 vCPU |
| `4000m` CPU | 4 CPU | 50% of 8 vCPU |
| `8000m` CPU | 8 CPU | 100% of 8 vCPU |
| `256Mi` memory | 0.25Gi | about 1.6% of 16Gi |
| `384Mi` memory | 0.375Gi | about 2.3% of 16Gi |
| `512Mi` memory | 0.5Gi | about 3.1% of 16Gi |
| `768Mi` memory | 0.75Gi | about 4.7% of 16Gi |
| `1024Mi` memory | 1Gi | 6.25% of 16Gi |
| `4096Mi` memory | 4Gi | 25% of 16Gi |
| `8192Mi` memory | 8Gi | 50% of 16Gi |
| `16384Mi` memory | 16Gi | 100% of 16Gi |

The percentages above are a mental model, not a guarantee that every byte or
millicpu is available to application pods. Kubernetes system components,
DaemonSets, kubelet reservations, and monitoring agents also consume node
resources.

### 3.4 Node Capacity vs Application ResourceQuota

The app node has physical capacity, but the benchmark intentionally limits the
application namespace with `ResourceQuota`.

```text
Two c8i.2xlarge app nodes
  physical visible capacity : about 16000m CPU / 31416Mi memory
  allocatable pool          : about 15820m CPU / 28110Mi memory

Benchmark application namespace quota
  CPU    : 15800m
  Memory : 27648Mi
```

In the current configuration, the namespace quota is intentionally placed below
the measured allocatable pool and below the clean ceiling derived after
subtracting always-on `kube-system` and `datadog` pod overhead on app nodes.

The EKS cluster uses two app nodes per architecture cluster. The namespace quota
caps the application workload at `15800m CPU / 27648Mi memory`, so the
benchmark comparison remains controlled at architecture level while still
respecting measured cluster overhead.

### 3.5 Request, Limit, and ResourceQuota

Kubernetes uses three related concepts:

```text
request       : resource reserved for scheduling
limit         : maximum resource the container may use
ResourceQuota : maximum total resource allowed in a namespace
```

For example:

```yaml
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

This means the scheduler reserves `250m CPU / 256Mi memory` for the pod, while
the container may use up to `500m CPU / 512Mi memory`.

At namespace level, ResourceQuota acts as the total budget guardrail:

```text
mono namespace quota : max 15800m CPU / 27648Mi memory
msa namespace quota  : max 15800m CPU / 27648Mi memory
```

The quota is what keeps the benchmark fair at architecture level.

### 3.6 Mental Diagram

The relationship from EC2 node to pod can be read as:

```text
EKS cluster for one architecture
  |
  +-- app-nodes
  |     |
  |     +-- 2 x c8i.2xlarge
  |           |
  |           +-- each node is roughly 8000m CPU / 16384Mi memory
  |
  +-- application namespace
        |
        +-- ResourceQuota: 15800m CPU / 27648Mi memory
              |
              +-- fixed mode
              |     |
              |     +-- monolith: 1 pod x 1000m / 1024Mi
              |     +-- MSA: 1 pod per service with role-aware requests/limits
              |
              +-- hpa mode
                    |
                    +-- monolith: 1 to 4 pods, 1000m each
                    +-- MSA: each service scales independently
                    +-- total still constrained by namespace ResourceQuota
```

The key idea is that node capacity is the physical pool, ResourceQuota is the
experiment budget, and pod requests/limits are how the budget is assigned to
workloads.

### 3.7 Kubernetes, DaemonSet, and Observability Overhead

The `15800m CPU / 27648Mi memory` ResourceQuota is the application comparison
budget. It is not the same thing as the total physical capacity of the EKS
worker nodes.

Several non-application components also consume node resources:

```text
kube-system components
metrics-server
AWS VPC CNI / EKS node components
kubelet and container runtime overhead
Datadog Agent DaemonSet
Datadog Cluster Agent
other DaemonSets or system pods
```

These components run outside the `mono` or `msa` application namespaces, so
they are not counted inside the `mono` or `msa` ResourceQuota. They still use
real CPU and memory on the same worker nodes.

The benchmark separates the concepts like this:

```text
Node physical capacity
  = total CPU and memory available on the EC2 worker nodes

Application ResourceQuota
  = maximum CPU and memory the benchmark application namespace may consume

Cluster overhead
  = Kubernetes system pods, DaemonSets, observability agents, kubelet,
    container runtime, and other node-level or cluster-level components
```

For example, two `c8i.2xlarge` app nodes are roughly:

```text
16000m CPU / 31416Mi visible memory
```

But the application namespace is capped at:

```text
15800m CPU / 27648Mi memory
```

This means the final application ceiling sits below both the app-node
allocatable pool and the measured clean ceiling after subtracting always-on
cluster overhead. In practice, Kubernetes overhead and observability overhead
still share those nodes, so the ceiling should be interpreted as a defensible
application budget, not as raw hardware capacity.

CPU is slightly different from memory in practice because Kubernetes CPU is
compressible. If system components are busy, application pods may experience
less effective CPU time even though the namespace quota still says `15800m`.

Datadog is the most visible DaemonSet overhead in this benchmark. The current
EKS Datadog installation:

```text
1 Datadog Agent DaemonSet pod per node
1 Datadog Cluster Agent Deployment per cluster
```

Because each benchmark cluster currently has three nodes, this normally means:

```text
3 Datadog Agent pods
1 Datadog Cluster Agent pod
```

The `datadog-*` Agent pods are created by a DaemonSet, so they follow the node
count. The `datadog-cluster-agent-*` pod is a Deployment, so it runs once per
cluster. Each Agent pod contains multiple containers, commonly appearing as
`2/2 Ready` because it includes the main agent and trace agent containers.

The current Datadog values do not set explicit resource requests or limits, so
Datadog pods run opportunistically and consume real node resources without
reserving a fixed slice through Kubernetes scheduling. This is documented in
`docs/infrastructure/datadog-resource-overhead.md`.

Methodologically, this overhead is handled as shared cluster-level overhead:

```text
monolith cluster      : Datadog enabled
microservices cluster : Datadog enabled
```

Because both clusters use the same Datadog configuration, the application
comparison still uses the equal application ResourceQuota as the fairness
boundary. Datadog overhead is not ignored, but it is interpreted separately as
symmetrical observability overhead rather than as part of one architecture's
application budget.

If stricter accounting is needed later, the next step is to set explicit
requests and limits for Datadog components and archive observed Datadog CPU and
memory usage with each benchmark run.

---

## 4. Why Fixed and HPA Are Divided This Way

The benchmark does not split resources by making every pod identical. It splits
resources according to the role of each architecture while keeping the total
architecture-level ceiling equal.

### 4.1 Why Fixed Mode Uses One Pod per Workload Unit

Fixed mode removes autoscaling from the experiment. This makes the comparison
cleaner because pod count stays stable from the beginning to the end of the
benchmark.

In fixed mode:

```text
Monolith      : 1 application pod
Microservices : 1 pod per service, 4 pods total
```

This is intentional. A microservices architecture naturally has multiple
deployable units, and the overhead of running those units at the same time is
part of what the benchmark should observe.

The fixed-mode comparison is therefore not:

```text
1 monolith pod vs 1 microservice pod
```

It is:

```text
one monolith deployable application
vs
one complete microservices system
```

Both systems expose the same REST API and run under the same namespace
ResourceQuota ceiling.

### 4.2 Why Microservices Are Role-Aware Instead of Equal Slices

The MSA services do not have identical responsibilities:

```text
api-gateway         : HTTP entry point, JWT validation, REST to gRPC mapping
auth-service        : login, bcrypt comparison, JWT issuing, user lookup
item-service        : item reads, item sync, transaction item validation
transaction-service : transaction writes, transaction reads, raw transaction data
```

Because the responsibilities differ, the resource profiles differ too. The
current configuration uses role-aware requests, limits, and HPA maxima:

| Service | Fixed request / limit | HPA maxReplicas | Reasoning |
|---|---:|---:|---|
| `api-gateway` | `250m / 500m` | 4 | lightweight entry point, but still needs moderate headroom for HTTP translation and JWT middleware |
| `auth-service` | `500m / 1000m` | 4 | bcrypt/JWT work is CPU-heavy, so each pod gets a larger CPU limit |
| `item-service` | `250m / 500m` | 6 | validation/read path scales horizontally with smaller pods |
| `transaction-service` | `850m / 1700m` | 4 | write path and transaction retrieval are the heaviest service responsibilities, so each pod gets the largest per-pod budget |

This avoids pretending every service has the same cost. It also keeps the total
MSA architecture constrained by the same `15800m CPU / 27648Mi memory` quota.

The thesis-oriented justification for this choice, including the theoretical
basis and fixed-vs-HPA budget relationship, is documented in
`docs/experiment/resource-configuration.md`.

### 4.3 Why HPA Mode Uses Different maxReplicas

In HPA mode, the goal is to observe autoscaling behavior, not to force every
service to scale the same way.

The monolith scales as one unit:

```text
monolith: 1 to 4 pods
3950m CPU limit per pod
maximum scheduled CPU = 4 x 3950m = 15800m
```

The MSA scales per service:

```text
api-gateway         : up to 9 small pods
auth-service        : up to 3 larger CPU pods
item-service        : up to 9 small pods
transaction-service : up to 5 medium pods
```

The sum of theoretical maxima can exceed the namespace quota if all services
try to scale at the same time. That is acceptable and intentional because the
namespace ResourceQuota is the final fairness guardrail. It prevents the MSA
architecture from consuming more than the allowed total budget.

This lets the experiment observe two real MSA behaviors:

- a targeted service can scale out under the scenario that stresses it,
- multiple hot services may contend for the same namespace quota.

### 4.4 How to Interpret the Result

Use fixed mode for the clean architecture comparison:

```text
What happens when both architectures run with stable pod counts?
```

Use HPA mode for autoscaling analysis:

```text
What happens when both architectures are allowed to react to CPU pressure,
while still capped by the same total resource ceiling?
```

Do not mix fixed and HPA numbers in the same table unless the table explicitly
labels the scaling mode. A fixed result and an HPA result answer different
questions.

---

## 5. Relationship to Research Questions

### 5.1 RQ1 — Performance

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

### 5.2 RQ2 — Resource Efficiency

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

## 6. K6_PROFILE and Manifest Convention

`K6_PROFILE` controls the load pattern k6 uses. The Kubernetes manifest
controls whether HPA is active. These are independent settings, but they
must be used together consistently.

### 6.1 Valid Combinations

| `K6_PROFILE` | Required manifest | Valid | Purpose |
|---|---|---|---|
| `steady` | `overlays/fixed` | ✅ | RQ1 primary — constant load, fixed replicas, clean comparison |
| `ramp` | `overlays/fixed` | ✅ | Fixed replicas under gradually increasing load |
| `smoke` | `overlays/fixed` | ✅ | Functional validation before benchmark |
| `hpa` | `overlays/hpa` | ✅ | RQ2 primary — ramping load triggers HPA scale-up |
| `hpa` | `overlays/fixed` | ❌ | Invalid — ramping load but no HPA to react, produces no autoscaling data |
| `steady` | `overlays/hpa` | ⚠️ | Allowed but HPA may not scale before benchmark ends since load is full from the start |

### 6.2 Core Rule

```text
K6_PROFILE=hpa   → must use overlays/hpa
All other profiles → must use overlays/fixed
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

### 6.3 K6_PROFILE=hpa Load Pattern

When `K6_PROFILE=hpa` is used, k6 applies a ramping arrival rate designed
to give HPA enough time to observe CPU pressure and scale pods:

```text
Stage 1: ramp to 25% of TARGET_RPS over 2 minutes  (HPA_RAMP_UP_1)
Stage 2: ramp to 50% of TARGET_RPS over 2 minutes  (HPA_RAMP_UP_2)
Stage 3: ramp to 100% of TARGET_RPS over 3 minutes (HPA_RAMP_UP_3)
Stage 4: hold at 100% of TARGET_RPS for 5 minutes  (HPA_HOLD)
Stage 5: ramp down to 0 over 1 minute              (HPA_RAMP_DOWN)
                                                   ───────────────
                                                   Total: 13 minutes
```

All stage durations are configurable via environment variables. The defaults
above are designed to allow HPA to observe sustained CPU pressure at each
level before the next stage begins.

HPA reacts to average CPU utilization over a rolling window (default 15
seconds in Kubernetes). The ramp stages ensure CPU pressure builds gradually
so the HPA controller has time to calculate desired replicas, schedule new
pods, and allow them to become ready before the next load increase.

**Important: `TEST_DURATION` is not used by `K6_PROFILE=hpa`.** The actual
run duration is determined entirely by the HPA stage environment variables
(`HPA_RAMP_UP_1/2/3` + `HPA_HOLD` + `HPA_RAMP_DOWN`). `TEST_DURATION` is
still recorded in `metadata.json` for reference, but the k6 executor
ignores it. This is a common source of confusion — setting
`TEST_DURATION=5m` with `K6_PROFILE=hpa` does **not** produce a 5-minute
run; the run will be 13 minutes (default) regardless.

### 6.3.1 Duration Behavior Per Profile

Each `K6_PROFILE` determines the actual k6 run duration differently:

| Profile | k6 Executor | Duration controlled by | `TEST_DURATION` used? |
|---|---|---|---|
| `smoke` | per-vu-iterations | `TEST_DURATION` | Yes |
| `steady` | constant-arrival-rate | `TEST_DURATION` | Yes |
| `ramp` | ramping-arrival-rate | `RAMP_UP_DURATION` + `TEST_DURATION` + `RAMP_DOWN_DURATION` | Yes (hold stage only) |
| `hpa` | ramping-arrival-rate | `HPA_RAMP_UP_1/2/3` + `HPA_HOLD` + `HPA_RAMP_DOWN` | **No** |

Visual comparison:

```text
steady (TEST_DURATION=5m):
RPS │ ████████████████████████
    └──────────────────────── time
        5 minutes constant

hpa (default, TEST_DURATION ignored):
RPS │          ██████████████
    │        ██              ██
    │      ██                  ██
    │    ██                      ██
    │  ██                          ██
    └──────────────────────────────── time
      2m  2m  2m    5m hold    1m      = 13 minutes
```

To shorten the HPA run for faster iteration:

```bash
HPA_RAMP_UP_1=1m HPA_RAMP_UP_2=1m HPA_RAMP_UP_3=2m HPA_HOLD=3m HPA_RAMP_DOWN=30s \
  make run-benchmark-suite SCALING_MODE=hpa ...
# Total: 1+1+2+3+0.5 = 7.5 minutes per case
```

To override all stages with a custom JSON array:

```bash
RAMP_STAGES_JSON='[{"target":1250,"duration":"1m"},{"target":5000,"duration":"3m"},{"target":5000,"duration":"5m"},{"target":0,"duration":"30s"}]'
```

### 6.3.2 HPA Stage Environment Variables

| Variable | Default | Description |
|---|---|---|
| `HPA_RAMP_UP_1` | `2m` | Duration to ramp to 25% of TARGET_RPS |
| `HPA_RAMP_UP_2` | `2m` | Duration to ramp to 50% of TARGET_RPS |
| `HPA_RAMP_UP_3` | `3m` | Duration to ramp to 100% of TARGET_RPS |
| `HPA_HOLD` | `5m` | Duration to hold at 100% of TARGET_RPS |
| `HPA_RAMP_DOWN` | `1m` | Duration to ramp down to 0 |

### 6.3.3 Ramp Stage Environment Variables (K6_PROFILE=ramp)

| Variable | Default | Description |
|---|---|---|
| `RAMP_UP_DURATION` | `1m` | Duration to ramp from 0 to TARGET_RPS |
| `RAMP_DOWN_DURATION` | `30s` | Duration to ramp from TARGET_RPS to 0 |

### 6.4 Why K6_PROFILE=hpa Must Not Be Used with Fixed Overlay

If the fixed overlay is applied and `K6_PROFILE=hpa` is used:

- Load ramps up gradually as designed
- CPU pressure increases on the fixed pod(s)
- No HPA object exists to trigger scale-out
- Pods may become overloaded or start dropping requests
- The result shows fixed-replica behavior under ramping load, not autoscaling behavior

This combination produces misleading data for RQ2 because the intent of
`K6_PROFILE=hpa` is to observe autoscaling, not to stress fixed replicas.

### 6.5 Why K6_PROFILE=steady Should Not Be Used with HPA Overlay

If the HPA overlay is applied and `K6_PROFILE=steady` is used:

- Load starts at full TARGET_RPS immediately
- CPU pressure spikes before HPA has time to react
- HPA may scale up, but the initial spike may already cause latency or errors
- The scaling behavior is harder to observe cleanly

This combination is allowed but should be labeled explicitly as
`steady load under HPA-enabled environment` and interpreted with care.

### 6.6 Operator Checklist Before Running k6

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

## 7. Recommended Experiment Plan

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

## 8. How to Switch Between Modes

### 8.1 Switch to Fixed-Replica Mode

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa

# Verify
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

### 8.2 Switch to HPA Mode

```bash
SCALING_MODE=hpa make eks-deploy-monolith
SCALING_MODE=hpa make eks-deploy-msa

# Verify HPA is active
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

### 8.3 Safe Recovery for HPA -> Fixed Transition

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

## 9. Fairness Rules

Both modes preserve the same resource ceiling:

```text
Monolith namespace CPU ceiling  : 15800m
MSA namespace CPU ceiling       : 15800m

Monolith namespace memory ceiling : 27648Mi
MSA namespace memory ceiling      : 27648Mi
```

These ceilings are the application comparison baseline. Datadog remains enabled
on both architectures during measured runs, so monitoring-agent usage is
treated as identical cluster-level observability overhead rather than as part
of an architecture-specific optimization.

In fixed mode, both architectures run one unit of each workload, but the MSA
services use role-aware requests and limits instead of equal `250m` slices.

In HPA mode, both architectures can scale up to 15800m total CPU before the
ResourceQuota blocks further scheduling.

For the service-budget interpretation behind this fixed-vs-HPA relationship,
see `docs/experiment/resource-configuration.md`.

Do not compare:

```text
fixed-replica result vs HPA result without explicit label
different target RPS between architectures
different duration between architectures
Minikube result vs EKS result
```

---

## 10. Metadata Labeling

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

## 11. HPA Behavior Data

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

## 12. Summary

| Aspect | Fixed-Replica | HPA |
|---|---|---|
| Pod count | Static (1 per unit) | Dynamic (1 to max) |
| Scaling variable | Eliminated | Present |
| Primary use | RQ1 + RQ2 core (clean, no scaling variable) | RQ1 under autoscaling + RQ2 with HPA behavior |
| Data source | k6 summary.json | k6 summary.json + Datadog |
| Deployment mode source | `overlays/fixed` | `overlays/hpa` |
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
