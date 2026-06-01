# Hetzner Hybrid Infrastructure Implementation Plan

Date: 2026-06-01 18:13 Asia/Jakarta

## 1. Objective

Add a Hetzner-based benchmark path without breaking the existing EKS workflow.

Provider split:

```text
compute/network/Kubernetes/PostgreSQL : Hetzner Cloud
benchmark artifacts                   : AWS S3
container images for Hetzner           : Docker Hub public
container images for EKS               : Amazon ECR
observability                          : Datadog SaaS
```

The Hetzner baseline is measurement-derived. It is fair between monolith and
microservices because both architectures use the same app-node shape and the
same generated CPU/memory ResourceQuota. It is not claimed to be EKS-equivalent
because its CPU and memory ceilings may differ from the current EKS baseline.

## 2. Final Node Configuration

Sequential bring-up:

```text
cluster: skripsi-hetzner-benchmark

control-plane:
  count : 1
  type  : CCX13
  role  : k3s server/control-plane
  taint : node-role.kubernetes.io/control-plane=:NoSchedule

app-nodes:
  count : 2
  type  : CCX43
  role  : application workloads
  label : node-group=app

testing-node:
  count : 1
  type  : CCX23
  role  : k6 runner
  label : node-group=testing
  taint : workload=benchmark:NoSchedule

postgres-node:
  count : 1
  type  : CCX33
  role  : PostgreSQL 18
  access: private network only
```

Parallel final benchmark:

```text
skripsi-hetzner-monolith:
  control-plane : 1 x CCX13
  app-nodes     : 2 x CCX43
  testing-node  : 1 x CCX23
  postgres-node : 1 x CCX33
  databases     : mono_db

skripsi-hetzner-msa:
  control-plane : 1 x CCX13
  app-nodes     : 2 x CCX43
  testing-node  : 1 x CCX23
  postgres-node : 1 x CCX33
  databases     : auth_db, item_db, transaction_db
```

## 3. Implementation Checklist

- [x] Add Hetzner Terraform stacks separate from AWS state.
- [x] Add k3s cluster module with app/testing labels and control-plane taint.
- [x] Add PostgreSQL 18 VM bootstrap on private network.
- [x] Add Hetzner env/tfvars/Terraform wrapper scripts.
- [x] Add Hetzner kubecontext setup script.
- [x] Add Hetzner sequential secret creation script.
- [x] Add Hetzner parallel secret creation scripts.
- [x] Add Docker Hub public render path.
- [x] Add AWS S3 credentials to k6 runner secret contract.
- [x] Add Hetzner preflight and Docker Hub image checks.
- [x] Add measurement-derived resource baseline script.
- [x] Add Make targets for the Hetzner workflow.
- [x] Add provider-aware deploy and benchmark entrypoints for sequential and
  parallel Hetzner runs.
- [x] Add new Hetzner infrastructure docs.
- [ ] Run Terraform init/validate after provider download is available.
- [ ] Apply Hetzner shared stack.
- [ ] Apply Hetzner sequential stack.
- [ ] Fetch kubeconfig and measure live resource baseline.
- [ ] Run sequential smoke benchmarks.
- [ ] Apply and validate parallel stack.

## 4. Operator Flow

```bash
make env-init-eks
make env-init-hetzner
# edit env/hetzner.env: HCLOUD_TOKEN, DOCKERHUB_NAMESPACE, AWS S3 credentials

make hetzner-render-tfvars
make dockerhub-push-all DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=<tag>

make hetzner-shared-apply
make hetzner-sequential-apply
make hetzner-setup-context-sequential
make hetzner-create-secrets-sequential
make hetzner-measure-resource-baseline

make hetzner-deploy-sequential-architecture ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=<tag>
make run-benchmark-sequential-hetzner ARCHITECTURE=monolith SCENARIO=login TARGET_RPS=100 RUN_ID=hetzner-smoke IMAGE_TAG=<tag>
```

Destroy remains guarded:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-sequential-destroy-confirmed
```

## 5. Validation Evidence

Initial implementation validation:

- Passed: `bash -n` for new Hetzner scripts plus provider-aware sequential scripts.
- Passed: `terraform fmt -check -recursive` for Hetzner module and stacks.
- Passed: `terraform init -backend=false` and `terraform validate` for
  `hetzner-shared`, `hetzner-experiment-sequential`, and `hetzner-experiment`.
- Passed: rendered Hetzner manifest validation with a dummy measured baseline.

Live validation requires:

- Hetzner Cloud token,
- AWS S3 credentials scoped to the benchmark bucket,
- Docker Hub namespace,
- real Hetzner server capacity in Singapore.

## 6. Open Risks

- Hetzner Singapore capacity can reject `CCX43`. The implementation must fail
  instead of silently downgrading.
- PostgreSQL bootstrap depends on the PGDG PostgreSQL 18 package repository.
- k3s bootstrap uses internet package downloads; failed cloud-init must be
  inspected on the server before retrying.
- The Hetzner resource baseline is not known until live allocatable capacity is
  measured.
- Docker Hub public images are acceptable only if `.dockerignore` and image
  checks prevent secret leakage.
