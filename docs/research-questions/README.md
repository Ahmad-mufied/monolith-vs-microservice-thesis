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
achieved RPS
error rate
dropped iterations
```

RQ2 focuses on resource efficiency:

```text
CPU usage
memory usage
derived efficiency metrics
HPA behavior as supporting evidence
```

## Source-of-Truth Policy

For external performance:

```text
k6 summary and raw output
```

For internal observability:

```text
Datadog and Kubernetes snapshots
```

For reproducibility:

```text
S3 result artifacts and metadata.json
```
