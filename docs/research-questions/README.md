# Research Question Analysis Docs

This directory contains the final analysis documents for the thesis research questions.

## Files

```text
docs/research-questions/
├── README.md
├── rq1-performance-analysis.md
└── rq2-resource-efficiency-analysis.md
```

## Purpose

These documents bridge implementation artifacts and thesis writing.

They explain:

```text
how metrics are defined
how k6, Datadog, Kubernetes, and HPA are related
how valid runs are identified
how Chapter 3 methodology can be described
how Chapter 4 results can be interpreted
```

## Scope

RQ1 focuses on external performance:

```text
latency
throughput achievement against target RPS
achieved RPS as supporting calculation input
error rate as validation metric
dropped iterations
```

RQ2 focuses on resource efficiency:

```text
architecture-level CPU usage
architecture-level memory usage
derived efficiency metrics tied to valid k6 results
microservices service breakdown as supporting explanation
HPA behavior as supporting evidence
```

The primary system-level workload is `concurrent-mixed-workload`, which runs
login, create transaction, and enriched transactions concurrently using a
20/40/40 RPS split. The individual `login`, `create-transaction`, and
`enriched-transactions` scenarios remain diagnostic evidence for explaining the
source of latency, throughput, CPU, and memory behavior.

Fixed-replica mode is the primary static-scale comparison mode for both
research questions. HPA mode is reported separately to explain autoscaling
behavior and whether the observed trade-offs change when Kubernetes is allowed
to scale pods.

Final thesis measurements use Vultr Kubernetes Engine (VKE) as the managed
Kubernetes environment. The RQ definitions remain cloud-native and
Kubernetes-based, but final Chapter 4 evidence should come from Vultr VKE runs.

## Source-of-Truth Policy

For external performance:

```text
k6 summary and raw output
```

For internal observability:

```text
Datadog
```

For reproducibility:

```text
S3 result artifacts and metadata.json
```
