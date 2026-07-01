# Unified Report and Chart Generator

This directory contains the unified report and chart generator for the Monolith vs Microservices benchmark suite. It consolidates two legacy tools into a single Python package managed by `uv`:
1. **k6 Report Generator**: Processes k6 execution output JSONs to compile throughput, latency, and success rate tables and charts (RQ1).
2. **Datadog Reporter**: Queries the Datadog API for CPU and Memory utilization to generate resource efficiency and allocation plots (RQ2).
3. **Consolidation**: Compiles and plots cross-architecture comparison and ablation charts by mapping dynamic Run IDs.

---

## Installation & Setup

We use `uv` for lightning-fast, isolated Python dependency management.

To install dependencies and prepare the virtual environment, run from the repository root:
```bash
make report-setup
```

Or run directly inside this folder:
```bash
uv sync
```

---

## Configuration & Output Paths (`report-generator.toml`)

All parameters are configured in a single `report-generator.toml` file.

### Dynamic Default Output Paths
Instead of specifying output directories on every command, all subcommands resolve their default target paths dynamically using the `output_parent` value in `report-generator.toml`.

```toml
# In report-generator.toml
output_parent = "/path/to/experimen/hasil/report"
```

*   **k6 Reports (`k6`)**: Outputs compile to `<output_parent>/<RUN_ID>/` by default.
*   **Datadog Reports (`datadog`)**: Outputs compile directly to `<output_parent>/` by default.
*   **Consolidation (`consolidate`)**: Merges are saved to `<output_parent>/consolidated/` and S3 downloads are cached in `<output_parent>/cache/`.

*Note: All defaults can still be overridden using command-line arguments.*

---

## Subcommands & Basic Usage

### 1. k6 Report Generation
```bash
# Via Makefile
make report-k6 ARGS="generate --run-id <run-id>"

# Via uv directly
uv run report-generator k6 generate --run-id <run-id>
```

### 2. Datadog Metrics Fetcher
```bash
# Via Makefile
make report-datadog ARGS="-d <path_to_k6_report_dir> -o <output_dir>"

# Via uv directly
uv run report-generator datadog -d <path_to_k6_report_dir> -o <output_dir>
```

### 3. Consolidated Comparison Charts
```bash
# Via Makefile (idempotent — skips if this combination of run IDs already has output)
make report-consolidate

# Force regeneration even if the output directory already exists
make report-consolidate ARGS=--force

# Via uv directly
uv run report-generator consolidate --config report-generator.toml
```

**How the output directory is determined:**

The consolidation command derives a deterministic **8-character content hash** from the sorted combination of all run IDs defined in `[consolidation.runs]` inside `report-generator.toml`. The output is written to:

```
<output_parent>/consolidated-{8char_hash}/
```

| Scenario | Behaviour |
|---|---|
| First run with a given config | Creates `consolidated-{hash}/` and generates all charts inside |
| Re-run with the **same** config | Detects the directory is non-empty → **skips** (safe idempotency) |
| Config changed (any run ID updated) | Hash changes → creates a **new** `consolidated-{new_hash}/` directory |
| `--force` flag passed | Regenerates into the same `consolidated-{hash}/` directory unconditionally |
| `--output-dir` explicitly provided | Ignores hash logic entirely, writes directly to the given path |


---

## Benchmark Case Scenarios & Workflow

Below are concrete, step-by-step examples of benchmark run scenarios comparing Monolith and Microservices architectures under fixed vs elastic scaling and admission control enable/disable.

### Case 1: Fixed Scaling (Admission Control Enabled)
This represents the primary baseline where both architectures run with a fixed replica count and admission control is enabled.
*   **Composite Run ID Placeholder**: `<vultr-sequential-fixed-enabled-run-id>`

1.  **Generate k6 Report (RQ1)**:
    ```bash
    make report-k6 ARGS="generate --run-id <vultr-sequential-fixed-enabled-run-id>"
    ```
    *Output is created at `<output_parent>/<vultr-sequential-fixed-enabled-run-id>/`.*

2.  **Generate Datadog Report (RQ2)**:
    ```bash
    make report-datadog ARGS="-d /path/to/experimen/hasil/report/<vultr-sequential-fixed-enabled-run-id>"
    ```

---

### Case 2: Elastic HPA Scaling (Admission Control Enabled)
This represents the elastic scaling scenario running Microservices HPA with admission control enabled.
*   **Run ID Placeholder**: `<vultr-sequential-msa-hpa-enabled-run-id>`

1.  **Generate k6 Report (RQ1)**:
    ```bash
    make report-k6 ARGS="generate --run-id <vultr-sequential-msa-hpa-enabled-run-id>"
    ```

2.  **Generate Datadog Report (RQ2)**:
    ```bash
    make report-datadog ARGS="-d /path/to/experimen/hasil/report/<vultr-sequential-msa-hpa-enabled-run-id>"
    ```

---

### Case 3: Fixed Scaling (Admission Control Disabled - Ablation)
This represents the ablation run with fixed replicas where admission control is turned off.
*   **Composite Run ID Placeholder**: `<vultr-sequential-fixed-disabled-run-id>`

1.  **Generate k6 Report (RQ1)**:
    ```bash
    make report-k6 ARGS="generate --run-id <vultr-sequential-fixed-disabled-run-id>"
    ```

2.  **Generate Datadog Report (RQ2)**:
    ```bash
    make report-datadog ARGS="-d /path/to/experimen/hasil/report/<vultr-sequential-fixed-disabled-run-id>"
    ```

---

### Case 4: Elastic HPA Scaling (Admission Control Disabled - Ablation)
This represents the ablation run with HPA elasticity where admission control is turned off.
*   **Run ID Placeholder**: `<vultr-sequential-msa-hpa-disabled-run-id>`

1.  **Generate k6 Report (RQ1)**:
    ```bash
    make report-k6 ARGS="generate --run-id <vultr-sequential-msa-hpa-disabled-run-id>"
    ```

2.  **Generate Datadog Report (RQ2)**:
    ```bash
    make report-datadog ARGS="-d /path/to/experimen/hasil/report/<vultr-sequential-msa-hpa-disabled-run-id>"
    ```

---

### Case 5: Compile Final Consolidated Comparison & Ablation Plots
Once all individual run reports have been compiled, map these Run IDs inside the `[consolidation.runs]` block in `report-generator.toml`:

```toml
[consolidation.runs]
mono_fixed_true = "<vultr-sequential-fixed-enabled-run-id>"
msa_fixed_true = "<vultr-sequential-fixed-enabled-run-id>"
msa_hpa_true = "<vultr-sequential-msa-hpa-enabled-run-id>"
mono_fixed_false = "<vultr-sequential-fixed-disabled-run-id>"
msa_fixed_false = "<vultr-sequential-fixed-disabled-run-id>"
msa_hpa_false = "<vultr-sequential-msa-hpa-disabled-run-id>"
```

Then run the consolidation task:
```bash
make report-consolidate
```

The tool will pull all necessary data (either locally or falling back to S3), filter and isolate the respective architectures at the dataframe level, and produce publication-ready consolidated comparison charts in `<output_parent>/consolidated/`.

For each benchmark scenario (e.g. `login`, `create-transaction`, `enriched-transactions`, `sync-items`), it generates **8 primary consolidated comparison charts** comparing Monolith FIXED, MSA FIXED, and MSA HPA:
- `primary-{scenario}-success-rate.png`
- `primary-{scenario}-p95-latency.png`
- `primary-{scenario}-throughput-achievement.png`
- `primary-{scenario}-throughput-breakdown.png` — RQ1: Request Outcome Breakdown (Success vs. Error/Rejected)
- `primary-{scenario}-cpu-usage.png`
- `primary-{scenario}-memory-usage.png`
- `primary-{scenario}-cpu-efficiency.png` — RQ2: Successful RPS per Core
- `primary-{scenario}-mem-efficiency.png` — RQ2: Memory GiB per 1000 Successful RPS

For the ablation run (comparing Admission Control Enabled vs Disabled), it generates **4 ablation comparison charts** (restricted by design to the `login` scenario):
- `ablation-success-rate.png`
- `ablation-p95-latency.png`
- `ablation-cpu-usage.png`
- `ablation-memory-usage.png`

---

## Testing

To run the unit tests (including TDD validation cases for the consolidation filtering logic), run:
```bash
PYTHONPATH=src uv run pytest
```
All tests should pass successfully.
