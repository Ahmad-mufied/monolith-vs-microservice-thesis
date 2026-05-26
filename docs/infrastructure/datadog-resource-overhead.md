# Datadog Resource Overhead

## Purpose

This document explains how Datadog consumes cluster resources during benchmark
execution and how that overhead should be interpreted in the thesis fairness
methodology.

It answers three separate questions:

1. what Datadog components run on each cluster,
2. what resource configuration those components currently use,
3. how the observed Datadog overhead affects the usable capacity left for the
   benchmark applications.

This document is complementary to [datadog.md](./datadog.md). The main
Datadog document explains the integration and observability workflow. This
document focuses specifically on resource usage and fairness interpretation.

## Scope

The current measurement in this document applies to:

- EKS benchmark clusters:
  - `skripsi-monolith`
  - `skripsi-msa`
- Datadog Helm installation from:
  - `deployments/helm/datadog/values-eks-monolith.yaml`
  - `deployments/helm/datadog/values-eks-msa.yaml`
- Measurement window captured on:
  - `2026-05-23`
  - approximately `06:21Z` to `06:35Z` for monolith
  - approximately `06:23Z` to `06:35Z` for microservices

The measured values below are therefore a documented live snapshot, not a
fixed universal constant. Actual Datadog usage may vary slightly with:

- node count,
- enabled Datadog features,
- container count,
- trace volume,
- log volume,
- benchmark intensity.

Important interpretation note:

- this document captures a measured snapshot taken under the benchmark
  configuration active on `2026-05-23`,
- at that time, the application resource ceiling documented in the benchmark
  manifests was `4000m CPU / 4096Mi memory` per architecture,
- the current repository methodology later moved to a final measured ceiling
  of `15800m CPU / 27648Mi memory` per architecture,
- therefore the Datadog usage measurements in this document remain valid as a
  historical overhead snapshot, while the final fairness baseline is now
  documented in `docs/experiment/application-ceiling-methodology.md`.

## Datadog Components per Cluster

Each benchmark cluster currently runs the same Datadog topology:

- `1` Datadog Cluster Agent Deployment
- `1` Datadog Agent DaemonSet pod per node

Because each EKS cluster currently has `3` nodes, the observed pod layout per
cluster is:

- `1` `datadog-cluster-agent-*` pod
- `3` `datadog-*` agent pods

The agent DaemonSet pod itself contains two containers:

- `agent`
- `trace-agent`

This is why the DaemonSet pods appear as `2/2 Ready`, while the cluster-agent
appears as `1/1 Ready`.

## Current Helm Configuration

The current EKS values files enable:

- logs collection
- APM
- DogStatsD
- process agent
- kube-state-metrics core
- cluster agent
- admission controller

Important current observation:

- the current EKS Datadog values do **not** define explicit
  `resources.requests` or `resources.limits` for either the DaemonSet agent or
  the Cluster Agent

Live inspection also confirmed:

- Datadog pods run with Kubernetes QoS class `BestEffort`

Implication:

- Datadog does **not** reserve a fixed CPU or memory slice through Kubernetes
  scheduling requests,
- but it still consumes real CPU and memory at runtime on the nodes where it
  is running.

This means the overhead is real, but it is currently unreserved and
opportunistic.

## Node Placement

Datadog currently runs on every node in both clusters, including nodes that
schedule application workloads.

Observed live placement:

- on `skripsi-monolith`:
  - `3` DaemonSet agent pods, one per node
  - `1` cluster-agent pod on one of the nodes
- on `skripsi-msa`:
  - `3` DaemonSet agent pods, one per node
  - `1` cluster-agent pod on one of the nodes

Implication:

- Datadog overhead is not isolated away from the application nodes,
- so application workloads share node capacity with observability components.

This is expected in the current benchmark design because application traces,
DogStatsD traffic, and node metrics must be collected from the same nodes that
run the benchmarked application pods.

## Measured Resource Usage Snapshot

### Measurement Source

The following values were obtained from Datadog metrics:

- `kubernetes.cpu.usage.total`
- `kubernetes.memory.usage`

Filtered by:

- `kube_namespace:datadog`
- `cluster_name:skripsi-monolith`
- `cluster_name:skripsi-msa`

The CPU metric values are reported in `nanocores` and converted below into
approximate `millicores`.

The memory metric values are reported in `bytes` and converted below into
approximate `MiB`.

### Monolith Cluster Datadog Usage

Approximate averages over the measured window:

| Pod | CPU | Memory |
| --- | ---: | ---: |
| `datadog-77r7j` | `16.8m` | `66.2 MiB` |
| `datadog-h6prp` | `12.3m` | `54.7 MiB` |
| `datadog-xjtkv` | `15.5m` | `62.4 MiB` |
| `datadog-cluster-agent-*` | `7.4m` | `57.3 MiB` |

Approximate total Datadog overhead on `skripsi-monolith`:

- CPU: `~51.9m`
- Memory: `~240.6 MiB`

### Microservices Cluster Datadog Usage

Approximate averages over the measured window:

| Pod | CPU | Memory |
| --- | ---: | ---: |
| `datadog-4v8gh` | `18.5m` | `65.5 MiB` |
| `datadog-pgjvw` | `12.5m` | `54.2 MiB` |
| `datadog-s7ttg` | `15.5m` | `66.5 MiB` |
| `datadog-cluster-agent-*` | `8.6m` | `58.3 MiB` |

Approximate total Datadog overhead on `skripsi-msa`:

- CPU: `~55.1m`
- Memory: `~244.5 MiB`

## Comparison Between Monolith and Microservices

### Cluster-Level Overhead Comparison

Measured cluster totals:

| Cluster | Total CPU | Total Memory |
| --- | ---: | ---: |
| `skripsi-monolith` | `~51.9m` | `~240.6 MiB` |
| `skripsi-msa` | `~55.1m` | `~244.5 MiB` |

Approximate difference:

- CPU difference: `~3.2m`
- Memory difference: `~3.9 MiB`

Interpretation:

- the Datadog overhead on the two clusters is very close,
- but it is not mathematically identical at every instant,
- because runtime usage depends on real trace volume, pod count, logging
  activity, and the specific node that hosts the cluster-agent pod.

### Per-Node Symmetry

Even though cluster totals are close, per-node overhead is not perfectly flat.

Reason:

- the DaemonSet contributes one agent pod per node,
- but the cluster-agent is a separate Deployment and lands on one node only.

Therefore:

- cluster-level overhead is the correct fairness lens,
- not strict per-node equality.

## Fairness Interpretation

This repository compares applications under equal application ceilings. For the
specific measurement window captured in this document, the active ceiling was
still the older exploratory `4000m CPU / 4096Mi memory` baseline. The current
final methodology now uses:

- monolith application ceiling:
  - `15800m CPU`
  - `27648Mi memory`
- microservices application ceiling:
  - `15800m CPU`
  - `27648Mi memory`

Datadog overhead should be interpreted separately as:

- identical cluster-level observability overhead enabled on both architectures

This means:

- Datadog is **not** treated as an application-only optimization,
- Datadog is **not** counted as evidence that one application was granted a
  special resource boost,
- Datadog is **not** ignored completely either, because it still consumes real
  node capacity.

The correct methodological statement is:

> Benchmark runs were executed on clusters that enabled the same Datadog
> monitoring components on both architectures. The application comparison
> baseline remained the configured application resource ceilings, while
> Datadog usage was treated as identical cluster-level observability overhead.

## What This Means for Available Capacity

### What remains equal

- the configured application quota comparison remains equal,
- the observability stack is enabled symmetrically,
- the measured Datadog overhead is very close between clusters.

### What is not literally equal

- node-level leftover CPU and memory are not guaranteed to match perfectly at
  every second,
- because Datadog usage is dynamic,
- and because cluster-agent placement is not mirrored onto the exact same node
  topology pattern.

### Practical conclusion

For benchmark interpretation, the remaining application capacity after
Datadog overhead is effectively comparable between monolith and microservices
at the cluster level.

The current measured difference is small enough that Datadog should be treated
as symmetric supporting overhead, not as a primary confounder.

## Limitations

This document does not claim:

- that Datadog overhead is always constant,
- that node-level overhead is perfectly identical,
- that future runs will produce the exact same resource numbers.

The following factors can change the measured overhead:

- increasing request volume,
- enabling more Datadog features,
- changing pod counts,
- changing number of nodes,
- changing application trace rate,
- changing logging intensity.

## Recommended Future Guardrails

If stricter observability accounting is needed later, the next reasonable
options are:

1. set explicit `requests` and `limits` for Datadog components so the reserved
   overhead is documented and repeatable,
2. periodically capture Datadog cluster-level CPU and memory totals during
   benchmark windows and archive them with each benchmark report,
3. keep the same Datadog configuration for all benchmark comparison groups and
   document any change as a methodology change.

At the current stage of the thesis workflow, the simplest defensible approach
is to keep Datadog symmetric and document it as shared observability overhead.

## Summary

Current conclusion:

- Datadog consumes real cluster resources on both architectures.
- The current installation does not reserve fixed requests or limits.
- The measured Datadog overhead is very similar between `skripsi-monolith` and
  `skripsi-msa`.
- Application fairness should still be interpreted using the configured
  application resource ceilings.
- Datadog should be documented as identical cluster-level observability
  overhead, not ignored and not treated as an asymmetric optimization.
