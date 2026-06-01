# Sequential and Parallel Benchmark Topology Plan

Date: 2026-06-01 11:17 Asia/Jakarta

## 1. Objective

Add a second EKS execution mode that can run monolith and microservices
benchmarks one after another on a single reusable infrastructure footprint,
without breaking the existing dual-cluster parallel workflow.

The immediate driver is the AWS account quota constraint: the account has only
24 vCPU available, so running both architectures at full app-node size in
parallel can exceed quota. Sequential mode should keep the full per-architecture
resource ceiling intact while ensuring only one architecture is active during a
measured run.

## 2. Current Baseline

The existing parallel mode remains the primary aligned-time-series workflow:

Comprehensive diagram:

```text
docs/diagrams/sequential-parallel-topology.md
```

```text
infra/terraform/shared
  -> VPC, subnets, NAT, k6 IAM role, budget guardrail

infra/terraform/experiment
  -> skripsi-monolith EKS + skripsi-monolith-postgres
  -> skripsi-msa EKS + skripsi-msa-postgres

kubectl contexts:
  monolith
  msa

benchmark runner:
  make run-benchmark-parallel
  make run-benchmark-suite
```

This mode gives the cleanest wall-clock alignment in Datadog because both k6
jobs run at the same time, but it costs roughly two complete benchmark stacks.

## 3. New Sequential Mode

Sequential mode adds one Terraform stack that reuses the same shared VPC and
IAM foundation:

```text
infra/terraform/experiment-sequential
  -> skripsi-benchmark EKS
  -> skripsi-benchmark-postgres

kubectl context:
  benchmark

namespaces:
  mono       -> monolith app, active only during monolith phase
  msa        -> microservices apps, active only during microservices phase
  benchmark  -> db bootstrap, k6 runner, shared benchmark jobs
```

Database names stay unchanged:

```text
mono_db
auth_db
item_db
transaction_db
```

This keeps app and migration behavior consistent with parallel mode while
reducing the active AWS footprint to one EKS cluster and one RDS instance.

## 4. Isolation Contract

Parallel and sequential modes are isolated at the Terraform stack and kubectl
context level.

| Concern | Parallel mode | Sequential mode |
|---|---|---|
| Terraform stack | `infra/terraform/experiment` | `infra/terraform/experiment-sequential` |
| EKS clusters | `skripsi-monolith`, `skripsi-msa` | `skripsi-benchmark` |
| RDS instances | `skripsi-monolith-postgres`, `skripsi-msa-postgres` | `skripsi-benchmark-postgres` |
| Contexts | `monolith`, `msa` | `benchmark` |
| Runner | `run-benchmark-parallel.sh`, `run-benchmark-suite.sh` | `run-benchmark-sequential.sh`, `run-benchmark-suite-sequential.sh` |
| Preflight contexts | `monolith msa` | `benchmark` |
| S3 metadata | `execution_mode=parallel` | `execution_mode=sequential` |

No existing parallel target is renamed or repointed. Sequential mode is additive.

## 5. Terraform Drift Guardrails

Sequential Terraform must not silently recreate resources when an interrupted
apply left live AWS resources outside local state.

Guardrails:

- `scripts/terraform-sequential.sh` injects `TF_VAR_db_password` from
  `env/terraform.experiment.env`, matching the existing experiment wrapper.
- On `plan` and `apply`, the wrapper checks whether `skripsi-benchmark` EKS or
  `skripsi-benchmark-postgres` RDS exists in AWS but is missing from
  `infra/terraform/experiment-sequential/terraform.tfstate`.
- If live resources exist without state tracking, the wrapper refuses to apply.
- `make terraform-sequential-recovery-check` is read-only and exits nonzero
  when it finds blocking drift.
- Sequential destroy requires `S3_BENCHMARK_DATA_VERIFIED=true`, matching the
  existing data-preservation rule.
- `make terraform-validate` includes `shared`, `experiment`, and
  `experiment-sequential`.

## 6. Sequential Lifecycle

```text
make env-init-eks
make eks-render-tfvars
make eks-shared-apply
make eks-sequential-plan
make eks-sequential-apply
make eks-setup-context-sequential
make eks-create-secrets-sequential

ARCHITECTURE=monolith make eks-deploy-sequential-architecture
make run-benchmark-sequential ARCHITECTURE=monolith ...

ARCHITECTURE=microservices make eks-deploy-sequential-architecture
make run-benchmark-sequential ARCHITECTURE=microservices ...

aws s3 ls s3://<bucket>/experiments/<run-id>/ --recursive
S3_BENCHMARK_DATA_VERIFIED=true make eks-sequential-destroy
```

The suite wrapper automates the architecture loop:

```bash
make run-benchmark-suite-sequential \
  SCALING_MODE=fixed \
  ARCHITECTURE_ORDER="monolith microservices" \
  EXPERIMENT_NAME=rq1-fixed-sequential \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  ARCHITECTURE_SWITCH_DELAY=300 \
  SCENARIO_RPS_MATRIX="login:1000,2500,5000;create-transaction:1000,2500,5000;enriched-transactions:1000,2500,5000"
```

`ARCHITECTURE_ORDER` can be reversed for controlled reruns:

```bash
ARCHITECTURE_ORDER="microservices monolith"
```

## 7. Switching Rules

Switching from parallel to sequential:

1. Verify S3 artifacts for the parallel run.
2. Destroy only the parallel experiment stack if quota is needed:
   `make eks-destroy-confirmed`.
3. Keep `infra/terraform/shared` if you still need the VPC/IAM foundation.
4. Apply the sequential stack: `make eks-sequential-apply`.
5. Configure the `benchmark` context and create sequential secrets.
6. Run the sequential suite.

Switching from sequential to parallel:

1. Verify S3 artifacts for the sequential run.
2. Destroy sequential with `make eks-sequential-destroy-confirmed`.
3. Run `make terraform-recovery-check` and `make terraform-sequential-recovery-check`
   before applying another stack.
4. Apply parallel with `make eks-apply`.
5. Configure `monolith` and `msa` contexts, recreate secrets, and deploy both
   clusters.

Do not run both experiment stacks at the same time unless quota and cost have
been explicitly reviewed.

## 8. Benchmark Fairness

Sequential mode preserves benchmark semantics:

- Same EKS manifests are rendered through `scripts/render-eks-manifests.sh`.
- Same fixed/HPA overlays are used.
- Same resource ceilings and ResourceQuota values are applied.
- Same migration, reset, seed, enrichment, and k6 scenario jobs are used.
- Only one architecture is active during each measured run.
- Opposite architecture HPAs are deleted and deployments are scaled to zero.

The tradeoff is analytical, not runtime behavioral: Datadog windows are no
longer wall-clock aligned between architectures. Analysis must compare by
`run_id`, `architecture`, `scenario_name`, `target_rps`, and Datadog time
window metadata rather than assuming simultaneous timestamps.

## 9. Metadata Contract

All k6 attempts now include:

```json
{
  "execution_mode": "parallel|sequential",
  "architecture_order": ["monolith", "microservices"],
  "terraform_stack": "experiment|experiment-sequential",
  "cluster_name": "skripsi-monolith|skripsi-msa|skripsi-benchmark"
}
```

Sequential suites also upload:

```text
s3://<bucket>/experiments/<run_id>/_suite/manifest.json
s3://<bucket>/experiments/<run_id>/_suite/summary.json
```

These files make the architecture order, matrix, and case-level outcome
explicit for downstream report generation.

Sequential suites also record `inter_case_delay_seconds`,
`architecture_switch_delay_seconds`, and `architecture_phases`. The
architecture switch delay is a fixed phase-level gap between monolith and
microservices so Datadog resource windows can be queried and compared without
ambiguous overlap around redeploy time.

## 10. Implemented Files

Terraform:

- `infra/terraform/experiment-sequential/`
- `infra/terraform/modules/benchmark-cluster/variables.tf`
- `infra/terraform/shared/main.tf`

Scripts and Make targets:

- `scripts/terraform-sequential.sh`
- `scripts/terraform-sequential-recovery-check.sh`
- `scripts/setup-eks-contexts-sequential.sh`
- `scripts/create-eks-secrets-sequential.sh`
- `scripts/deploy-sequential-architecture.sh`
- `scripts/run-benchmark-sequential.sh`
- `scripts/run-benchmark-suite-sequential.sh`
- `Makefile`

Metadata and manifests:

- `k6/runner/run-k6.sh`
- `deployments/k8s/benchmark/k6-benchmark-monolith-job.yaml`
- `deployments/k8s/benchmark/k6-benchmark-microservices-job.yaml`
- `deployments/helm/datadog/values-eks-sequential.yaml`

Docs:

- `docs/infrastructure/sequential-benchmark-runbook.md`
- `docs/infrastructure/terraform-runbook.md`
- `docs/infrastructure/benchmark-runbook-end-to-end.md`
- `docs/infrastructure/parallel-benchmark-runbook.md`
- `docs/infrastructure/eks-cluster-design.md`
- `docs/infrastructure/cloud-architecture.md`
- `docs/infrastructure/datadog.md`
- `docs/infrastructure/aws-budget-shutdown.md`
- `docs/diagrams/benchmark-lifecycle.md`
- `README.md`

## 11. Validation Plan

Local validation:

```bash
bash -n scripts/terraform-sequential.sh \
  scripts/terraform-sequential-recovery-check.sh \
  scripts/setup-eks-contexts-sequential.sh \
  scripts/create-eks-secrets-sequential.sh \
  scripts/deploy-sequential-architecture.sh \
  scripts/run-benchmark-sequential.sh \
  scripts/run-benchmark-suite-sequential.sh

terraform fmt -recursive
terraform -chdir=infra/terraform/experiment-sequential init
terraform -chdir=infra/terraform/experiment-sequential validate
```

AWS validation after a fresh login:

```bash
aws login
make terraform-sequential-recovery-check
make eks-sequential-plan
make eks-sequential-apply
make eks-setup-context-sequential
kubectl --context=benchmark get nodes
make eks-create-secrets-sequential
ARCHITECTURE=monolith SCALING_MODE=fixed make eks-deploy-sequential-architecture
ARCHITECTURE=monolith SCENARIO=login TARGET_RPS=100 RUN_ID=smoke-sequential ATTEMPT=attempt-01 make run-benchmark-sequential
```

## 12. Non-Goals

This implementation intentionally does not add:

- Cluster Autoscaler, Karpenter, KEDA, VPA, or Prometheus Adapter.
- Remote Terraform state.
- New benchmark semantics.
- Different app resource profiles for sequential mode.
- Shared active monolith and MSA workloads inside the sequential cluster.

Keeping the mode additive and explicit is the best balance of reliability,
quota efficiency, and low operational surprise.
