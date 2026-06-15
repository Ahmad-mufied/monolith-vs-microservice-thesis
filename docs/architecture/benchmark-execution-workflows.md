# Benchmark Execution Workflows

## Purpose

This document explains the active benchmark execution workflows after the
dual-architecture suite contract was narrowed to the primary fixed matrix only.

The benchmark now uses three distinct execution paths:

1. a fixed-only dual-architecture suite for the primary comparison,
2. a single-architecture suite for focused fixed or HPA extensions,
3. a single-case runner for smoke tests, reruns, and one-off diagnostics.

This separation keeps the main comparison reproducible and prevents the
monolith fixed baseline from being rerun unnecessarily when the supporting HPA
analysis only targets microservices.

---

## 1. Fixed Suite Workflow

The suite runners are reserved for the primary fixed matrix.

Supported entrypoints:

```text
make run-benchmark-suite
make run-benchmark-suite-sequential
```

Required scaling contract:

```text
SCALING_MODE=fixed
```

If `SCALING_MODE=hpa` is supplied to a dual-architecture suite runner, the
command now fails fast with an explicit operator-facing error and points to the
single-architecture suite or single-case commands.

### 1.1 Why the Suite Is Fixed-Only

The suite is used for the primary Bab 4 matrix, where the goal is a stable,
repeatable architecture comparison under the fixed baseline.

Keeping the suite fixed-only provides these properties:

- command semantics stay simple,
- the sequential suite no longer reruns the monolith fixed baseline during HPA,
- per-suite metadata remains aligned with one primary comparison contract,
- the autoscaling narrative stays clearly separated as supporting evidence.

### 1.2 Fixed Suite Behavior

In both parallel and sequential execution modes, the suite:

- builds the scenario x RPS matrix,
- uploads `_suite/manifest.json`,
- deploys or reuses the fixed baseline,
- runs measured k6 cases,
- uploads per-attempt artifacts,
- uploads `_suite/summary.json`.

Sequential suite specifics:

- the active architecture phase is deployed before its cases run,
- `ARCHITECTURE_SWITCH_DELAY` separates monolith and microservices phases,
- the suite records `architecture_phases` plus per-case timing windows.

### 1.3 Fixed Suite Examples

Parallel fixed suite:

```bash
SCALING_MODE=fixed \
EXPERIMENT_NAME=rq1-fixed-final \
TEST_DURATION=5m \
INTER_CASE_DELAY=120 \
SCENARIO_RPS_MATRIX="concurrent-mixed-workload:100,200,300,400,500;login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500" \
make run-benchmark-suite
```

Sequential fixed suite:

```bash
SCALING_MODE=fixed \
ARCHITECTURE_ORDER="monolith microservices" \
EXPERIMENT_NAME=rq1-fixed-sequential \
TEST_DURATION=5m \
INTER_CASE_DELAY=120 \
ARCHITECTURE_SWITCH_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500;enriched-transactions:100,200,300,400,500" \
make run-benchmark-suite-sequential
```

---

## 2. Single-Architecture Suite Workflow

The architecture suite is used when you want suite behavior for only one
architecture:

- multi-scenario,
- multi-target RPS,
- one deployment state per run,
- one architecture selected explicitly.

Supported entrypoint:

```text
make run-benchmark-arch-suite
```

Required inputs:

```text
ARCHITECTURE=<monolith|microservices>
SCALING_MODE=<fixed|hpa>
```

Default profile behavior:

```text
SCALING_MODE=fixed -> K6_PROFILE defaults to steady
SCALING_MODE=hpa   -> K6_PROFILE defaults to hpa
```

### 2.1 Why the Architecture Suite Exists

The architecture suite fills the gap between the fixed-only dual suite and the
single-case runner. It is useful when:

- the primary fixed suite has already measured the monolith and microservices
  baseline,
- the supporting analysis only needs one architecture,
- a single-case runner would be too tedious for a scenario x RPS batch,
- architecture switching would add no methodological value.

### 2.2 Active Semantics

The architecture suite currently supports:

- `ARCHITECTURE=monolith SCALING_MODE=fixed`
- `ARCHITECTURE=microservices SCALING_MODE=fixed`
- `ARCHITECTURE=microservices SCALING_MODE=hpa`

The active benchmark model rejects:

- `ARCHITECTURE=monolith SCALING_MODE=hpa`

That combination is rejected explicitly because the monolith HPA benchmark path
is not part of the active methodology.

Implementation note:

```text
run-benchmark-arch-suite currently executes on the sequential benchmark cluster,
but it is not called "sequential" because there is no architecture phase switching
inside the run.
```

### 2.3 Architecture Suite Behavior

The architecture suite:

- builds the scenario x RPS matrix,
- uploads `_arch_suite/manifest.json`,
- deploys or reuses the selected architecture once,
- runs each case through the existing sequential single-case runner,
- uploads normal per-attempt artifacts,
- uploads `_arch_suite/summary.json`.

For data handling:

- data-stable scenarios can reuse one setup per scenario,
- mutating scenarios keep conservative per-case reset and seed behavior,
- S3 `result-status.json` is still the resume source of truth per case.

### 2.4 Architecture Suite Examples

Microservices HPA suite:

```bash
ARCHITECTURE=microservices \
SCALING_MODE=hpa \
EXPERIMENT_NAME=rq2-msa-hpa \
TEST_DURATION=5m \
INTER_CASE_DELAY=300 \
SCENARIO_RPS_MATRIX="login:100,250,500;create-transaction:100,250,500;enriched-transactions:100,250,500;concurrent-mixed-workload:100,250,500" \
make run-benchmark-arch-suite
```

Microservices fixed extension suite:

```bash
ARCHITECTURE=microservices \
SCALING_MODE=fixed \
EXPERIMENT_NAME=rq1-msa-fixed-extension \
TEST_DURATION=5m \
INTER_CASE_DELAY=120 \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;create-transaction:100,200,300,400,500" \
make run-benchmark-arch-suite
```

Monolith fixed extension suite:

```bash
ARCHITECTURE=monolith \
SCALING_MODE=fixed \
EXPERIMENT_NAME=rq1-monolith-fixed-extension \
TEST_DURATION=5m \
INTER_CASE_DELAY=120 \
SCENARIO_RPS_MATRIX="login:100,200,300,400,500;enriched-transactions:100,200,300,400,500" \
make run-benchmark-arch-suite
```

### 2.5 HPA Duration Note

When `SCALING_MODE=hpa` is used, the HPA k6 executor controls the actual case
duration. `TEST_DURATION` is recorded in metadata but does not determine the
wall-clock k6 duration for the HPA case.

---

## 3. Single-Case Workflow

The single-case runners remain the right tool for:

- smoke validation,
- rerunning one failed case,
- one-off debugging,
- checking one architecture/scenario/RPS combination before a larger suite run.

Supported entrypoints:

```text
make run-benchmark-case
make run-benchmark-sequential
make run-benchmark-parallel
```

### 3.1 Single-Case Examples

Sequential supplemental HPA single case:

```bash
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=250 \
RUN_ID=rq2-hpa-single-case \
ATTEMPT=attempt-01 \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=5m \
make run-benchmark-case
```

Parallel supplemental HPA single case:

```bash
SCENARIO=concurrent-mixed-workload \
TARGET_RPS=100 \
RUN_ID=rq2-hpa-parallel-single-case \
ATTEMPT=attempt-01 \
SCALING_MODE=hpa \
K6_PROFILE=hpa \
TEST_DURATION=5m \
make run-benchmark-case
```

---

## 4. Operator Decision Guide

Use the following rule:

| Goal | Recommended entrypoint |
|---|---|
| Primary architecture comparison | fixed suite |
| One architecture, many scenarios/RPS levels | architecture suite |
| One isolated fixed smoke or rerun | single-case runner |
| Supplemental autoscaling analysis across many cases | architecture suite |
| One isolated supplemental HPA retry | single-case runner |

If you want one sentence to remember:

```text
suite      = primary fixed matrix
arch-suite = one architecture, many cases
case       = one architecture, one scenario, one RPS
```

---

## 5. Related References

- `docs/experiment/scaling-mode-strategy.md`
- `docs/infrastructure/eks-runbook-end-to-end.md`
- `docs/infrastructure/eks-sequential-runbook.md`
- `docs/diagrams/vultr-sequential-suite-lifecycle.md`
- `docs/diagrams/benchmark-lifecycle.md`
