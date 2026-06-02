# Diagrams

This directory contains Mermaid diagrams for the thesis benchmark repository.

The diagrams are source-controlled as Markdown so they can be reviewed in pull
requests, rendered directly by GitHub, and exported later to SVG or PNG for
thesis writing.

## Diagram Index

| Diagram | Purpose |
|---|---|
| [`cloud-architecture.md`](cloud-architecture.md) | Historical AWS-oriented infrastructure topology retained for engineering reference |
| [`sequential-parallel-topology.md`](sequential-parallel-topology.md) | Historical AWS-oriented parallel vs sequential topology retained for engineering reference |
| [`vultr-vke-topology.md`](vultr-vke-topology.md) | Active Vultr VKE parallel, sequential, and end-to-end execution topology |
| [`architecture-comparison.md`](architecture-comparison.md) | Side-by-side monolith and microservices runtime comparison |
| [`benchmark-lifecycle.md`](benchmark-lifecycle.md) | End-to-end benchmark execution lifecycle |
| [`login-sequence.md`](login-sequence.md) | Benchmark 1 login request flow |
| [`create-transaction-sequence.md`](create-transaction-sequence.md) | Benchmark 2 create transaction request flow |
| [`enriched-transactions-sequence.md`](enriched-transactions-sequence.md) | Benchmark 3 enriched transaction read flow |

For Vultr benchmark runs, prefer
[`vultr-vke-topology.md`](vultr-vke-topology.md) together with
`docs/infrastructure/vultr-cloud-architecture.md` and
`docs/infrastructure/vultr-vke-runbook.md`. The AWS-oriented diagrams remain
available as historical engineering references.

## Rendering

GitHub renders Mermaid blocks in Markdown automatically.

For thesis assets, export diagrams from Mermaid-compatible tooling after the
text source is reviewed and stable.
