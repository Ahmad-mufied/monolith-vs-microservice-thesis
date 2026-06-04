# Per-Case Benchmark Timestamps Implementation Plan

## Objective

Add explicit start/end timestamps to suite-level benchmark reports for both
parallel and sequential execution modes so every benchmark case is directly
traceable from `_suite/summary.json` without opening each attempt artifact
manually.

## Scope

In scope:

- add case-level timing fields to `_suite/summary.json`
- add per-architecture timing blocks for each suite case
- add a shared timing helper for suite runners
- ensure fallback behavior is explicit and never silent
- update related benchmark docs so the new output contract is documented

Out of scope:

- changing attempt artifact names
- changing benchmark pass/fail semantics
- adding new persisted timing artifact files
- changing `metadata.json` schema beyond consuming its current fields

## Implementation Phases

### Phase 1 — Shared timing resolution

- create a shared helper under `scripts/lib/`
- resolve timing from:
  - `metadata.json.datadog.time_window_start`
  - `metadata.json.datadog.time_window_end`
  - fallback to `metadata.json.timestamp_utc`
  - fallback to orchestrator case timestamps
- emit compact JSON with:
  - `started_at_utc`
  - `finished_at_utc`
  - `timing_source`
- print stderr warnings when falling back because metadata is missing or invalid

### Phase 2 — Parallel suite runner

- capture orchestrator start/end around every suite case
- resolve timing separately for:
  - monolith attempt
  - microservices attempt
- add to each case:
  - case `started_at_utc`
  - case `finished_at_utc`
  - case `timing_source`
  - `architectures.monolith.*`
  - `architectures.microservices.*`

### Phase 3 — Sequential suite runner

- capture orchestrator start/end around every suite case
- resolve timing for the active architecture attempt
- add to each case:
  - case `started_at_utc`
  - case `finished_at_utc`
  - case `timing_source`
  - `architectures.<active-architecture>.*`
- preserve existing `architecture_phases` structure

### Phase 4 — Documentation

- update suite summary contract references in benchmark docs
- document timing precedence and fallback behavior
- document that case timing is additive and older summaries may not contain it

## JSON Contract Changes

### Parallel `_suite/summary.json` case

Existing fields remain and new fields are added:

```json
{
  "scenario": "login",
  "target_rps": 1000,
  "status": "pass",
  "exit_code": 0,
  "monolith_s3_uri": "s3://...",
  "microservices_s3_uri": "s3://...",
  "started_at_utc": "2026-06-03T11:00:00Z",
  "finished_at_utc": "2026-06-03T11:05:00Z",
  "timing_source": "mixed",
  "architectures": {
    "monolith": {
      "started_at_utc": "2026-06-03T11:00:00Z",
      "finished_at_utc": "2026-06-03T11:05:00Z",
      "timing_source": "attempt_metadata"
    },
    "microservices": {
      "started_at_utc": "2026-06-03T11:00:05Z",
      "finished_at_utc": "2026-06-03T11:04:58Z",
      "timing_source": "orchestrator"
    }
  }
}
```

### Sequential `_suite/summary.json` case

Existing fields remain and new fields are added:

```json
{
  "architecture": "monolith",
  "scenario": "login",
  "target_rps": 1000,
  "status": "pass",
  "exit_code": 0,
  "s3_uri": "s3://...",
  "started_at_utc": "2026-06-03T11:00:00Z",
  "finished_at_utc": "2026-06-03T11:05:00Z",
  "timing_source": "attempt_metadata",
  "architectures": {
    "monolith": {
      "started_at_utc": "2026-06-03T11:00:00Z",
      "finished_at_utc": "2026-06-03T11:05:00Z",
      "timing_source": "attempt_metadata"
    }
  }
}
```

## Timing Rules

- authoritative attempt-local window:
  - `metadata.json.datadog.time_window_start`
  - `metadata.json.datadog.time_window_end`
- partial attempt fallback:
  - `metadata.json.timestamp_utc` as start
  - orchestrator case end as finish
- final fallback:
  - orchestrator case start/end

Timing source labels:

Per-architecture level (under `architectures.<name>`):

- `attempt_metadata` — both timestamps came from metadata (Datadog window)
- `datadog_artifact` — both timestamps came from datadog-time-window.json
- `attempt_metadata_partial` — start from metadata `timestamp_utc`, end from
  orchestrator wall-clock
- `orchestrator` — both timestamps came from orchestrator wall-clock

Case-level aggregated:

- `attempt_metadata` — all architectures used full metadata (attempt_metadata or datadog_artifact)
- `orchestrator` — all architectures used orchestrator-based timing (includes
  `attempt_metadata_partial` which depends on orchestrator for end timestamp)
- `mixed` — at least one architecture used full metadata AND at least one used
  fallback

Per-architecture `attempt_metadata_partial` normalizes to `orchestrator` at case
level because the end timestamp still depends on orchestrator wall-clock.

## Docs To Update

- `docs/infrastructure/benchmark-execution-lifecycle.md`
- `docs/infrastructure/parallel-benchmark-runbook.md`
- `docs/infrastructure/sequential-benchmark-runbook.md`
- `docs/infrastructure/benchmark-runbook-end-to-end.md`
- `docs/diagrams/sequential-parallel-topology.md` if wording becomes stale

## Validation Checklist

- shared timing helper returns valid JSON on all fallback paths
- parallel suite summary includes case timing and both architecture timing blocks
- sequential suite summary includes case timing and active architecture timing
- existing suite fields are unchanged
- timing fallback prints warnings to stderr
- no suite run becomes invalid solely because timing metadata is missing
- docs reflect the final output contract

## Risks

- S3 timing fetch can fail after a case if local auth expires
- older runs will not have the new fields, so docs must note additive rollout
- partial timing sourced from `timestamp_utc` plus orchestrator finish can be
  less precise than full Datadog window

## Progress Log

- [x] phase 1 helper implemented
- [x] phase 2 parallel runner implemented
- [x] phase 3 sequential runner implemented
- [x] docs updated
- [x] validation completed
- [x] fix timing source taxonomy alignment
  - [x] `case_timing_source_from_architecture_sources()` treats
    `attempt_metadata_partial` as orchestrator-category
  - [x] `normalize_case_timing_source()` maps `attempt_metadata_partial` to
    `orchestrator`
  - [x] plan doc timing source labels corrected (per-arch vs case-level split)
  - [x] operational docs updated with `attempt_metadata_partial` documentation
