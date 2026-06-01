# Diagrams

This directory contains Mermaid diagrams for the thesis benchmark repository.

The diagrams are source-controlled as Markdown so they can be reviewed in pull
requests, rendered directly by GitHub, and exported later to SVG or PNG for
thesis writing.

## Diagram Index

| Diagram | Purpose |
|---|---|
| [`cloud-architecture.md`](cloud-architecture.md) | Parallel and sequential AWS EKS, RDS, S3, ECR, Datadog, and operator topology |
| [`sequential-parallel-topology.md`](sequential-parallel-topology.md) | Parallel vs sequential EKS benchmark topology, switching, and metadata flow |
| [`architecture-comparison.md`](architecture-comparison.md) | Side-by-side monolith and microservices runtime comparison |
| [`benchmark-lifecycle.md`](benchmark-lifecycle.md) | End-to-end benchmark execution lifecycle |
| [`login-sequence.md`](login-sequence.md) | Benchmark 1 login request flow |
| [`create-transaction-sequence.md`](create-transaction-sequence.md) | Benchmark 2 create transaction request flow |
| [`enriched-transactions-sequence.md`](enriched-transactions-sequence.md) | Benchmark 3 enriched transaction read flow |

## Rendering

GitHub renders Mermaid blocks in Markdown automatically.

For thesis assets, export diagrams from Mermaid-compatible tooling after the
text source is reviewed and stable.
