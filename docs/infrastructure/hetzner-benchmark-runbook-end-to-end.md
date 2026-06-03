# Hetzner Benchmark Runbook — End to End

## Purpose

This runbook covers the full Hetzner benchmark path from a fresh local setup
to completed benchmark artifacts in S3 and safe teardown.

It is written for:

- the thesis author running the final experiment,
- an operator reproducing the Hetzner environment,
- a reviewer who needs to understand the exact execution flow.

This document is the detailed Hetzner counterpart to the shorter
[`hetzner-benchmark-runbook.md`](./hetzner-benchmark-runbook.md).

Final-thesis scope:

- Hetzner Cloud is the final benchmark environment,
- Docker Hub public images are used for Hetzner runs,
- AWS S3 is used only for benchmark artifact storage,
- monolith and microservices must both be rerun fully in Hetzner,
- `fixed` and `hpa` are treated as separate deployment states.

What this runbook explicitly covers:

- first-time local preparation,
- Terraform provisioning order,
- environment file expectations,
- Kubernetes context creation,
- secrets and S3 credential flow,
- resource-baseline measurement,
- deploy, smoke, measured run, and suite patterns,
- verification checkpoints after each phase,
- safe destroy and rerun rules,
- troubleshooting for the most common operator failures.

---

## 1. Topology Choice

Choose the benchmark topology before provisioning.

| Topology | Use when | Terraform stack | Kubernetes contexts |
|---|---|---|---|
| Sequential | one architecture active at a time, simpler final-thesis execution, lower concurrent cost | `infra/terraform/hetzner-sequential` | `benchmark` |
| Parallel | monolith and microservices active at the same time, aligned Datadog time-series | `infra/terraform/hetzner-parallel` | `monolith`, `msa` |

Shared infrastructure is common to both:

```text
infra/terraform/hetzner-shared
```

Recommended final-thesis default:

- use **sequential** unless you explicitly need parallel time-series alignment,
- keep **parallel** as an optional advanced mode.

---

## 2. Prerequisites

Install or prepare these locally:

```text
- Terraform >= 1.6
- kubectl
- helm
- Docker
- jq
- openssl
- gh (optional, for GitHub work)
- AWS CLI v2
```

Optional but helpful:

```text
- hcloud CLI (extra Hetzner connectivity check during preflight)
```

You also need:

- a Hetzner Cloud project and API token,
- a Docker Hub namespace with permission to push public images,
- an AWS S3 bucket for benchmark artifacts,
- Datadog credentials if observability is enabled.

Quick local sanity check:

```bash
terraform version
kubectl version --client
helm version
docker --version
jq --version
aws --version
```

If you plan to rely on Terraform-managed AWS S3 writer credentials, also make
sure the AWS side is ready:

```bash
aws sts get-caller-identity
make terraform-auth-check
```

Required repository-side env/bootstrap files:

```bash
make env-init-app
make env-init-hetzner
```

Why both?

- `env-init-app` prepares the shared app/benchmark env files reused by the
  Hetzner scripts,
- `env-init-hetzner` prepares the Hetzner-specific infrastructure env file.

Expected generated files after initialization:

```text
env/hetzner.env
env/monolith.app.env
env/api-gateway.app.env
env/auth-service.app.env
env/item-service.app.env
env/transaction-service.app.env
env/k6-runner.app.env
```

---

## 3. Required Environment Files

### 3.1 Hetzner Environment

Edit `env/hetzner.env` and fill the real values:

```text
HCLOUD_TOKEN
DOCKERHUB_NAMESPACE
S3_BUCKET
AWS_REGION
POSTGRES_PASSWORD
```

Commonly relevant optional values:

```text
HETZNER_NETWORK_CIDR
HETZNER_OPERATOR_CIDRS
HETZNER_CONTROL_PLANE_SERVER_TYPE
HETZNER_APP_SERVER_TYPE
HETZNER_TESTING_SERVER_TYPE
HETZNER_POSTGRES_SERVER_TYPE
SEQUENTIAL_CLUSTER_NAME
MONOLITH_CLUSTER_NAME
MSA_CLUSTER_NAME
```

Important default server-type assumptions:

```text
control-plane : ccx13
app-nodes     : ccx43
testing-node  : ccx23
postgres-node : ccx33
```

Adjust them only if you intentionally want a different thesis baseline.

### 3.2 AWS S3 Credentials for Hetzner

The preferred flow is:

- create the S3 bucket if it does not exist yet,
- create or reuse the AWS S3 writer credentials from
  `infra/terraform/aws-s3-writer`,
- let the Hetzner secret scripts read those credentials from Terraform outputs,
- avoid manually copying secrets unless you intentionally want to override them.

If the S3 bucket does not exist yet:

```bash
make aws-create-s3
```

If you want Terraform to create the Hetzner S3 writer credentials for you:

```bash
make aws-s3-writer-apply
```

This means the normal flow is:

```text
AWS S3 writer terraform apply
-> outputs contain hetzner_k6_s3_access_key_id / hetzner_k6_s3_secret_access_key
-> create-hetzner-secrets*.sh reads them automatically
```

If you do not use the Terraform-managed AWS credential path, you must set these
manually in `env/hetzner.env` before secret creation:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

### 3.3 Optional Datadog

If you want Datadog during deployment and benchmark runs, make sure these are
available through the existing env files:

```text
DATADOG_API_KEY
DATADOG_SITE
DATADOG_ENV
```

If Datadog API key is still a placeholder, the deploy script skips the install.

---

## 4. One-Time Image Publishing

> [!TIP]
> **Automated CI/CD Build and Push Alternative**
> Instead of building and pushing images locally, you can use the configured GitHub Actions workflow. Every merge or push to `main` will automatically build and push all 7 images to Docker Hub using the Git short commit SHA as the tag.
> Refer to [github-actions-dockerhub.md](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/docs/deployment/github-actions-dockerhub.md) for setup and credentials configuration.

Hetzner runs use Docker Hub public images.

Choose a stable image tag first:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
echo "$IMAGE_TAG"
```

Push all required images:

```bash
make dockerhub-push-all \
  DOCKERHUB_NAMESPACE=<namespace> \
  IMAGE_TAG=$IMAGE_TAG
```

What this covers:

- `monolith`
- `api-gateway`
- `auth-service`
- `item-service`
- `transaction-service`
- `seed-runner`
- `k6-runner`

The repository validates that the expected public tags exist before deployment.

Example:

```bash
IMAGE_TAG=thesis-final-20260601
make dockerhub-push-all \
  DOCKERHUB_NAMESPACE=ahmadmufied \
  IMAGE_TAG=$IMAGE_TAG
```

Operator checkpoint after push:

```bash
docker manifest inspect docker.io/<namespace>/monolith:$IMAGE_TAG >/dev/null
docker manifest inspect docker.io/<namespace>/k6-runner:$IMAGE_TAG >/dev/null
```

---

## 5. Render Terraform Variables

Render the Hetzner tfvars from `env/hetzner.env`:

```bash
make hetzner-render-tfvars
```

This writes:

```text
infra/terraform/hetzner-shared/terraform.tfvars
infra/terraform/hetzner-sequential/terraform.tfvars
infra/terraform/hetzner-parallel/terraform.tfvars
```

Fail-fast behavior already included:

- placeholder `HCLOUD_TOKEN=replace-me` is rejected,
- `OPERATOR_CIDRS` entries are validated one by one,
- world-open CIDRs and placeholders are rejected.

Good operator habit:

```bash
git diff -- infra/terraform/hetzner-*/terraform.tfvars
```

Expected high-signal values to confirm in the rendered tfvars:

- cluster names,
- Hetzner location,
- `app_server_type`,
- `postgres_server_type`,
- operator CIDRs,
- SSH public key,
- project name.

---

## 6. Provision Infrastructure with Terraform

### 6.1 Shared Infrastructure

Apply the shared Hetzner network and shared objects first:

```bash
make hetzner-shared-apply
```

Dry-run first if desired:

```bash
make hetzner-shared-plan
```

Expected shared outputs after apply:

```bash
terraform -chdir=infra/terraform/hetzner-shared output
```

Operator check:

- network exists,
- firewall resources exist,
- SSH key resource exists,
- no Terraform errors remain.

### 6.2 Sequential Infrastructure

For the recommended sequential topology:

```bash
make hetzner-sequential-apply
```

Dry-run:

```bash
make hetzner-sequential-plan
```

Expected sequential outputs after apply:

```bash
terraform -chdir=infra/terraform/hetzner-sequential output
```

Key outputs to note:

- `control_plane_public_ip`
- `postgres_private_ip`

### 6.3 Parallel Infrastructure

If you intentionally want monolith and MSA active in parallel:

```bash
make hetzner-parallel-apply
```

Dry-run:

```bash
make hetzner-parallel-plan
```

Expected parallel outputs after apply:

```bash
terraform -chdir=infra/terraform/hetzner-parallel output
```

Key outputs to note:

- `monolith_control_plane_public_ip`
- `msa_control_plane_public_ip`

### 6.4 Manual Terraform Access

The wrapper script is the safest normal path:

```bash
bash scripts/terraform-hetzner.sh shared init
bash scripts/terraform-hetzner.sh sequential plan -out=tfplan
bash scripts/terraform-hetzner.sh parallel apply
```

Use this only when you need lower-level control than the Makefile targets.

Important destroy guard:

- `sequential` and `parallel` destroy require `S3_BENCHMARK_DATA_VERIFIED=true`,
- `shared` destroy should be done only after you intentionally decide no more
  Hetzner runs are needed.

---

## 7. Configure kubectl Contexts

### 7.1 Sequential

```bash
make hetzner-setup-context-sequential
kubectl --context=benchmark get nodes
```

Expected:

- control-plane node present,
- app nodes labeled `node-group=app`,
- testing node labeled `node-group=testing`.

Recommended verification:

```bash
kubectl --context=benchmark get nodes -o wide
kubectl --context=benchmark get nodes -l node-group=app
kubectl --context=benchmark get nodes -l node-group=testing
kubectl --context=benchmark describe nodes -l node-group=testing | rg 'workload=benchmark:NoSchedule'
```

### 7.2 Parallel

```bash
make hetzner-setup-contexts-parallel
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

The setup script fetches kubeconfig over SSH from the control plane and writes
local kubeconfig entries with hardened SSH options.

Expected local files:

```text
env/kubeconfig/benchmark.yaml
env/kubeconfig/monolith.yaml
env/kubeconfig/msa.yaml
~/.kube/config
```

---

## 8. Create Kubernetes Secrets

### 8.1 Sequential

```bash
make hetzner-create-secrets-sequential
```

### 8.2 Parallel

```bash
make hetzner-create-secrets
```

What gets created:

- benchmark secrets,
- bootstrap DB env,
- monolith app secrets,
- microservices app secrets,
- k6 runner secret for S3 upload.

Sequential secret map:

| Namespace | Secret | Main purpose |
|---|---|---|
| `benchmark` | `db-bootstrap-env` | bootstrap DB logical databases |
| `benchmark` | `k6-runner-secret` | k6 admin credentials + S3 upload credentials |
| `mono` | `monolith-env` | monolith app config |
| `msa` | `api-gateway-secret` | gateway config |
| `msa` | `auth-service-secret` | auth DB and JWT config |
| `msa` | `item-service-secret` | item DB config |
| `msa` | `transaction-service-secret` | transaction DB and downstream address config |

If `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are absent in
`env/hetzner.env`, the scripts try the Terraform `aws-s3-writer` outputs
automatically.

Quick verification:

```bash
kubectl --context=benchmark get secrets -n benchmark
kubectl --context=benchmark get secrets -n mono
kubectl --context=benchmark get secrets -n msa
```

Parallel verification:

```bash
kubectl --context=monolith get secrets -n benchmark
kubectl --context=msa get secrets -n benchmark
```

If secret creation fails, check these first:

- `env/hetzner.env` exists,
- the `.app.env` app files exist,
- the sequential or parallel Terraform stack has already been applied,
- AWS S3 credentials are either present in env or available from
  `infra/terraform/aws-s3-writer` outputs.

---

## 9. Measure Hetzner Resource Baseline

This step is mandatory for real benchmark runs.

```bash
make hetzner-measure-resource-baseline
```

This generates:

```text
env/hetzner-resource-baseline.env
env/hetzner-resource-baseline.json
```

What it does:

1. reads allocatable CPU and memory from app nodes,
2. subtracts the configured safety margin,
3. rounds the result to practical quota values,
4. stores the final application ceiling for manifest rendering.

Why this matters:

- the final thesis baseline is provider-native,
- monolith and MSA must receive the same Hetzner-derived ceiling,
- manifests should not use raw physical capacity directly.

Inspect the result:

```bash
cat env/hetzner-resource-baseline.env
```

Typical output shape:

```text
HETZNER_APP_CPU_QUOTA=...
HETZNER_APP_MEMORY_QUOTA=...
HETZNER_APP_NODE_COUNT=2
HETZNER_APP_ALLOCATABLE_CPU=...
HETZNER_APP_ALLOCATABLE_MEMORY=...
```

Recommended operator checkpoint:

```bash
cat env/hetzner-resource-baseline.env
jq . env/hetzner-resource-baseline.json | sed -n '1,80p'
```

For debugging manifests only, you can bypass this with:

```bash
SKIP_HETZNER_RESOURCE_BASELINE=true make hetzner-render-manifests ...
```

Do not use that bypass for measured benchmark runs.

---

## 10. Validate Rendered Hetzner Manifests

Before deployment, validate that the rendered Kubernetes assets are consistent:

```bash
make hetzner-render-manifests \
  DOCKERHUB_NAMESPACE=<namespace> \
  IMAGE_TAG=$IMAGE_TAG
```

This:

- renders EKS-base manifests into a temporary Hetzner-adjusted output,
- swaps image references to Docker Hub,
- applies the measured Hetzner resource baseline,
- validates the rendered assets,
- fails if AWS/ECR placeholders remain.

Use this as a safe preflight before the first deployment of a new tag.

What this step catches early:

- missing baseline file,
- Docker Hub placeholder leakage,
- stale AWS/ECR references,
- invalid generated manifests.

---

## 11. Run Hetzner Preflight

Before measured benchmark runs:

```bash
make hetzner-preflight-check
```

This verifies:

- Hetzner token presence,
- cluster context availability,
- app/testing node labels,
- testing node taint,
- Docker Hub image visibility,
- AWS S3 access for artifact storage.

Recommended timing:

- after infrastructure is up,
- after secrets are created,
- after images are pushed,
- before long benchmark suites.

Recommended success criteria:

- `Hetzner preflight passed`
- no missing app/testing nodes,
- S3 bucket head check succeeds,
- required Docker Hub tags are visible.

---

## 12. Deploy Applications

### 12.1 Sequential Deploy

Deploy exactly one architecture on the sequential cluster:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=monolith \
  SCALING_MODE=fixed \
  IMAGE_TAG=$IMAGE_TAG
```

or:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=microservices \
  SCALING_MODE=hpa \
  IMAGE_TAG=$IMAGE_TAG
```

What the deploy script does:

1. renders Hetzner manifests,
2. validates them,
3. applies namespaces and benchmark RBAC,
4. runs DB bootstrap job,
5. runs migration job(s),
6. runs reset job,
7. runs seed job,
8. applies the selected `fixed` or `hpa` overlay,
9. installs metrics-server automatically when `SCALING_MODE=hpa`,
10. optionally installs Datadog if configured.

Expected operator checkpoint after sequential deploy:

Monolith fixed:

```bash
kubectl --context=benchmark get pods -n mono
kubectl --context=benchmark get jobs -n benchmark
kubectl --context=benchmark get jobs -n mono
```

Microservices fixed:

```bash
kubectl --context=benchmark get pods -n msa
kubectl --context=benchmark get jobs -n benchmark
kubectl --context=benchmark get jobs -n msa
```

For HPA mode also verify:

```bash
kubectl --context=benchmark get hpa -n mono
kubectl --context=benchmark get hpa -n msa
```

### 12.2 Parallel Deploy

Deploy both clusters in the selected scaling mode:

```bash
make hetzner-deploy-all \
  DOCKERHUB_NAMESPACE=<namespace> \
  IMAGE_TAG=$IMAGE_TAG \
  SCALING_MODE=fixed
```

or:

```bash
make hetzner-deploy-all \
  DOCKERHUB_NAMESPACE=<namespace> \
  IMAGE_TAG=$IMAGE_TAG \
  SCALING_MODE=hpa
```

This uses the parallel contexts `monolith` and `msa`.

Expected operator checkpoint after parallel deploy:

```bash
kubectl --context=monolith get pods -n mono
kubectl --context=msa get pods -n msa
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
```

---

## 13. Smoke-Test Cases

Run these first before any long final suite.

### 13.1 Sequential Fixed Smoke

Monolith:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=monolith \
  SCALING_MODE=fixed \
  IMAGE_TAG=$IMAGE_TAG

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=monolith \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-smoke-fixed \
  ATTEMPT=attempt-01 \
  SCALING_MODE=fixed \
  TEST_DURATION=1m
```

Microservices:

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=microservices \
  SCALING_MODE=fixed \
  IMAGE_TAG=$IMAGE_TAG

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=microservices \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-smoke-fixed \
  ATTEMPT=attempt-01 \
  SCALING_MODE=fixed \
  TEST_DURATION=1m
```

### 13.2 Sequential HPA Smoke

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=monolith \
  SCALING_MODE=hpa \
  IMAGE_TAG=$IMAGE_TAG

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=monolith \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-smoke-hpa \
  ATTEMPT=attempt-01 \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  TEST_DURATION=3m
```

Repeat for microservices.

What a good smoke run should confirm:

- benchmark Job reaches `Complete`,
- S3 attempt folder is created,
- `metadata.json` exists,
- threshold failures, if any, are understandable and not caused by infra misconfiguration.

### 13.3 Parallel Smoke

```bash
make hetzner-deploy-all \
  DOCKERHUB_NAMESPACE=<namespace> \
  IMAGE_TAG=$IMAGE_TAG \
  SCALING_MODE=fixed

make run-benchmark-parallel-hetzner \
  SCENARIO=login \
  TARGET_RPS=100 \
  RUN_ID=hetzner-parallel-smoke \
  ATTEMPT=attempt-01 \
  SCALING_MODE=fixed \
  TEST_DURATION=1m
```

---

## 14. Measured Single-Case Runs

Use these when you want one deliberate case at a time.

Recommended use cases:

- calibrating RPS before a full suite,
- confirming one architecture after changing `IMAGE_TAG`,
- rerunning one failed attempt with a new `ATTEMPT`.

### 14.1 Sequential Fixed Case

```bash
make run-benchmark-sequential-hetzner \
  ARCHITECTURE=monolith \
  SCENARIO=create-transaction \
  TARGET_RPS=300 \
  RUN_ID=hetzner-rq1-fixed \
  ATTEMPT=attempt-01 \
  SCALING_MODE=fixed \
  TEST_DURATION=5m
```

### 14.2 Sequential HPA Case

```bash
make run-benchmark-sequential-hetzner \
  ARCHITECTURE=microservices \
  SCENARIO=enriched-transactions \
  TARGET_RPS=300 \
  RUN_ID=hetzner-rq2-hpa \
  ATTEMPT=attempt-01 \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  TEST_DURATION=13m
```

### 14.3 Parallel Case

```bash
make run-benchmark-parallel-hetzner \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=hetzner-parallel-login \
  ATTEMPT=attempt-01 \
  SCALING_MODE=fixed \
  TEST_DURATION=5m
```

---

## 15. Full Suite Examples

### 15.1 Sequential Fixed Suite

Use the generic sequential suite runner with `CLOUD_PROVIDER=hetzner`:

```bash
CLOUD_PROVIDER=hetzner make run-benchmark-suite-sequential \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=hetzner-rq1-fixed \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  ARCHITECTURE_SWITCH_DELAY=300 \
  ARCHITECTURE_ORDER="monolith microservices" \
  SCENARIO_RPS_MATRIX="login:100,120,140;create-transaction:100,150,200;enriched-transactions:100,150,200"
```

Use this when:

- you want one architecture active at a time,
- you want a complete final-thesis fixed dataset,
- you want consistent inter-case stabilization.

### 15.2 Sequential HPA Suite

```bash
CLOUD_PROVIDER=hetzner make run-benchmark-suite-sequential \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  EXPERIMENT_NAME=hetzner-rq2-hpa \
  TEST_DURATION=13m \
  INTER_CASE_DELAY=300 \
  ARCHITECTURE_SWITCH_DELAY=300 \
  ARCHITECTURE_ORDER="monolith microservices" \
  SCENARIO_RPS_MATRIX="login:100,120;create-transaction:100,150;enriched-transactions:100,150"
```

### 15.3 Parallel Fixed Suite

```bash
CLOUD_PROVIDER=hetzner make run-benchmark-suite \
  SCALING_MODE=fixed \
  EXPERIMENT_NAME=hetzner-parallel-fixed \
  TEST_DURATION=5m \
  INTER_CASE_DELAY=120 \
  SCENARIO_RPS_MATRIX="login:1000,2500;create-transaction:1000,1500;enriched-transactions:1000,1500"
```

### 15.4 Parallel HPA Suite

```bash
CLOUD_PROVIDER=hetzner make run-benchmark-suite \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  EXPERIMENT_NAME=hetzner-parallel-hpa \
  TEST_DURATION=13m \
  INTER_CASE_DELAY=300 \
  SCENARIO_RPS_MATRIX="login:1000,1500;create-transaction:1000,1500"
```

Note:

- `run-benchmark-suite` and `run-benchmark-suite-sequential` are generic
  wrappers,
- for Hetzner, set `CLOUD_PROVIDER=hetzner`,
- for HPA, keep `K6_PROFILE=hpa`,
- `SCALING_MODE=hpa` without `K6_PROFILE=hpa` is rejected by the scripts.

Additional suite guidance:

- use `INTER_CASE_DELAY=120` as a practical fixed baseline unless you have a
  reason to shorten it,
- use `INTER_CASE_DELAY=300` as a practical HPA baseline so scale-down and
  Datadog windows can settle,
- keep `ARCHITECTURE_SWITCH_DELAY=300` in sequential mode unless you have
  measurement evidence that a shorter gap is safe.

---

## 16. Common Execution Patterns

### Case A — Fresh Sequential Thesis Run from Zero

```bash
make env-init-app
make env-init-hetzner
make dockerhub-push-all DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=$IMAGE_TAG
make hetzner-render-tfvars
make hetzner-shared-apply
make hetzner-sequential-apply
make hetzner-setup-context-sequential
make hetzner-create-secrets-sequential
make hetzner-measure-resource-baseline
make hetzner-preflight-check
make hetzner-deploy-sequential-architecture ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=$IMAGE_TAG
CLOUD_PROVIDER=hetzner make run-benchmark-suite-sequential ...
```

Use when:

- starting the real final benchmark from scratch.

### Case B — Rerun One Failed Sequential Attempt Without Destroy

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=microservices \
  SCALING_MODE=fixed \
  IMAGE_TAG=$IMAGE_TAG

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=microservices \
  SCENARIO=create-transaction \
  TARGET_RPS=200 \
  RUN_ID=hetzner-rq1-fixed \
  ATTEMPT=attempt-02 \
  SCALING_MODE=fixed \
  TEST_DURATION=5m
```

Use when:

- only one benchmark case failed,
- infrastructure is still healthy,
- you want a new attempt folder in S3.

### Case C — Switch Fixed to HPA on Sequential Cluster

```bash
make hetzner-deploy-sequential-architecture \
  ARCHITECTURE=monolith \
  SCALING_MODE=hpa \
  IMAGE_TAG=$IMAGE_TAG

make run-benchmark-sequential-hetzner \
  ARCHITECTURE=monolith \
  SCENARIO=login \
  TARGET_RPS=120 \
  RUN_ID=hetzner-rq2-hpa \
  ATTEMPT=attempt-01 \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  TEST_DURATION=13m
```

Use when:

- you intentionally move to the HPA phase,
- you understand fixed and HPA are different deployment states.

### Case D — Parallel One-Off Comparison

```bash
make hetzner-parallel-apply
make hetzner-setup-contexts-parallel
make hetzner-create-secrets
make hetzner-measure-resource-baseline
make hetzner-deploy-all DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=$IMAGE_TAG SCALING_MODE=fixed
make run-benchmark-parallel-hetzner SCENARIO=login TARGET_RPS=1000 RUN_ID=hetzner-parallel ATTEMPT=attempt-01 SCALING_MODE=fixed TEST_DURATION=5m
```

Use when:

- you need both architectures active at once.

---

## 17. Result Verification

Never destroy before checking that the benchmark artifacts actually exist.

Check a whole run:

```bash
aws s3 ls s3://<bucket>/experiments/<run-id>/ --recursive
```

Check one attempt:

```bash
aws s3 ls s3://<bucket>/experiments/<run-id>/monolith/login/100rps/attempt-01/
```

Expected core files:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
```

When Datadog is enabled, also expect:

```text
datadog-time-window.json
```

Good operator habit:

- inspect `metadata.json`,
- verify `provider` is `hetzner`,
- verify `resources` reflect the intended scaling mode and quota,
- verify `run_id`, `attempt`, `architecture`, `scenario_name`, and `target_rps`.

Suggested quick content check:

```bash
aws s3 cp s3://<bucket>/experiments/<run-id>/monolith/login/100rps/attempt-01/metadata.json -
```

---

## 18. Safe Teardown

### 18.1 Sequential Destroy

```bash
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-sequential-destroy-confirmed
```

### 18.2 Parallel Destroy

```bash
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-parallel-destroy-confirmed
```

### 18.3 Shared Stack

There is no dedicated Makefile destroy target for the Hetzner shared stack.
If you intentionally want to destroy it too, use the lower-level wrapper:

```bash
S3_BENCHMARK_DATA_VERIFIED=true bash scripts/terraform-hetzner.sh shared destroy
```

Normal recommendation:

- keep the shared stack if another Hetzner run is planned soon,
- destroy the shared stack only when you intentionally want full cleanup.

---

## 19. Rerun Rules

Use these rules to avoid data contamination:

- do not rerun a mutating scenario directly against old mutated data,
- keep `ATTEMPT` unique for repeated executions,
- treat `fixed` and `hpa` as separate deployment states,
- redeploy before switching scaling mode,
- verify S3 artifacts after each measured run or case batch,
- do not destroy infra just to retry a single case unless the environment is unhealthy.

Reset/seed behavior:

- handled by the deploy and suite scripts,
- still interpret mutating scenarios carefully when doing manual reruns.

Practical rerun matrix:

| Situation | Recommended action |
|---|---|
| one benchmark Job failed, infra healthy | rerun same case with new `ATTEMPT` |
| want to switch `fixed` to `hpa` | redeploy selected architecture with new `SCALING_MODE` |
| want to change image tag | repush image if needed, rerender manifests implicitly via deploy/run scripts, rerun smoke first |
| baseline file missing after cluster recreation | rerun `make hetzner-measure-resource-baseline` before deploy |
| secrets changed | rerun the relevant `hetzner-create-secrets*` target |

---

## 20. Troubleshooting Shortlist

### `missing env/hetzner.env`

Run:

```bash
make env-init-hetzner
```

### `HCLOUD_TOKEN must be set`

Edit `env/hetzner.env` and replace the placeholder with the real token.

### `DOCKERHUB_NAMESPACE is required for CLOUD_PROVIDER=hetzner`

Set it in `env/hetzner.env` or pass it explicitly.

### `missing env/hetzner-resource-baseline.env`

Run:

```bash
make hetzner-measure-resource-baseline
```

### `S3_BENCHMARK_DATA_VERIFIED must be true`

This is the destroy guardrail. Verify the S3 artifacts first, then rerun the
destroy command with the variable set exactly to `true`.

### `AWS_ACCESS_KEY_ID must be set` during preflight or secret creation

Resolve with one of these:

1. apply the AWS S3 writer stack so Terraform outputs the Hetzner S3 writer
   credentials:

```bash
make aws-s3-writer-apply
```

2. or set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` manually in
   `env/hetzner.env`.

### `missing control-plane public IP output`

The target Terraform stack is either not applied yet or the wrong stack/mode
was selected. Re-check:

```bash
terraform -chdir=infra/terraform/hetzner-sequential output
terraform -chdir=infra/terraform/hetzner-parallel output
```

### `OPERATOR_CIDRS` rejected during tfvars render

Use explicit CIDRs only, for example:

```text
203.0.113.10/32
```

Do not use placeholders, `0.0.0.0/0`, or `::/0`.

### Secret creation fails because `postgres_private_ip` is missing

The sequential Terraform stack has not been applied yet, or you are attempting
to use the sequential secret helper before infrastructure exists.

Run:

```bash
make hetzner-sequential-apply
```

then retry:

```bash
make hetzner-create-secrets-sequential
```

### Benchmark job completes but expected artifacts are missing in S3

Check:

- the benchmark Job logs,
- `k6-runner-secret`,
- S3 bucket name in `env/hetzner.env`,
- AWS credential validity,
- `result-status.json` in the same attempt folder.

### `DOCKERHUB_NAMESPACE` or image tag looks correct but preflight says image missing

Verify the exact repository path and tag:

```bash
docker manifest inspect docker.io/<namespace>/monolith:<tag>
docker manifest inspect docker.io/<namespace>/k6-runner:<tag>
```

### HPA run rejected because `K6_PROFILE` is wrong

Use:

```bash
SCALING_MODE=hpa K6_PROFILE=hpa ...
```

Do not use `K6_PROFILE=steady` for the standard HPA experiment.

### First SSH context setup hangs or fails on a fresh host

Re-run the context setup target after the control plane is fully reachable:

```bash
make hetzner-setup-context-sequential
```

The repository already uses hardened SSH options with connect timeout and
non-interactive host-key acceptance.

---

## 21. Failure Recovery by Phase

This section explains what to do when a failure happens at a specific phase of
the Hetzner benchmark flow.

Core recovery rule:

- do not blindly restart from the very beginning,
- identify the last healthy checkpoint,
- retry only the phase that failed when the previous phases are still valid,
- rerun baseline measurement after any cluster recreation,
- never destroy infrastructure before confirming whether useful artifacts
  already reached S3.

### 21.1 Failure During Environment Initialization

Symptoms:

- `make env-init-hetzner` stops,
- generated env files are incomplete,
- placeholders remain where real values are expected.

Safe recovery:

1. rerun:

```bash
make env-init-app
make env-init-hetzner
```

2. recheck:
   - `env/hetzner.env`
   - app `.app.env` files
   - `POSTGRES_PASSWORD`
   - `OPERATOR_CIDRS`
   - `OPERATOR_SSH_PUBLIC_KEY`

Do not continue to tfvars rendering until those files exist and the critical
placeholders have been replaced.

### 21.2 Failure During Docker Hub Publish

Symptoms:

- `make dockerhub-push-all` fails,
- preflight later says image missing,
- only some image repositories contain the target tag.

Safe recovery:

1. rerun the image push with the exact same `IMAGE_TAG`.
2. verify the missing images explicitly:

```bash
docker manifest inspect docker.io/<namespace>/monolith:<tag>
docker manifest inspect docker.io/<namespace>/k6-runner:<tag>
```

3. only continue when all required tags are visible.

Do not switch to a new tag mid-session unless you intentionally want a new
experiment image version. If you change the tag, rerun smoke validation first.

### 21.3 Failure During tfvars Rendering

Symptoms:

- `make hetzner-render-tfvars` fails,
- placeholder token or CIDR validation error,
- SSH key rejected.

Safe recovery:

1. edit `env/hetzner.env`.
2. fix the specific invalid values.
3. rerun:

```bash
make hetzner-render-tfvars
```

This phase is stateless. It is safe to rerun as many times as needed.

### 21.4 Failure During Terraform Apply

Symptoms:

- `make hetzner-shared-apply` fails,
- `make hetzner-sequential-apply` fails,
- `make hetzner-parallel-apply` fails,
- Terraform exits after partial creation.

Safe recovery:

1. do not immediately destroy unless you are sure the stack is unusable.
2. inspect current outputs:

```bash
terraform -chdir=infra/terraform/hetzner-shared output
terraform -chdir=infra/terraform/hetzner-sequential output
terraform -chdir=infra/terraform/hetzner-parallel output
```

3. rerun the same apply target:

```bash
make hetzner-shared-apply
make hetzner-sequential-apply
make hetzner-parallel-apply
```

4. only continue when the required outputs exist and are non-empty.

When to stop and inspect manually:

- Terraform repeatedly fails on the same resource,
- control-plane or PostgreSQL IP outputs are still missing,
- provider quota or location capacity looks exhausted,
- the apply error indicates a real invalid configuration instead of a transient
  connection interruption.

Important consequence:

- if Terraform recreate or cluster recreation happens later, you must rerun
  context setup, secrets if needed, and baseline measurement.

### 21.5 Failure During kubectl Context Setup

Symptoms:

- `make hetzner-setup-context-sequential` fails,
- SSH cannot reach control plane,
- kubeconfig exists but `kubectl get nodes` fails.

Safe recovery:

1. confirm Terraform outputs exist.
2. rerun the same setup target:

```bash
make hetzner-setup-context-sequential
```

or:

```bash
make hetzner-setup-contexts-parallel
```

3. verify nodes immediately after:

```bash
kubectl --context=benchmark get nodes
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

When to stop:

- control-plane public IP is empty,
- SSH times out repeatedly,
- kubeconfig merges but points to an unreachable API endpoint.

### 21.6 Failure During Secret Creation

Symptoms:

- `make hetzner-create-secrets-sequential` fails,
- missing `postgres_private_ip`,
- missing AWS S3 credentials,
- missing `.app.env` files.

Safe recovery:

1. confirm the required env files exist.
2. confirm the relevant Terraform stack has already been applied.
3. if using Terraform-managed AWS credentials, ensure the AWS S3 writer stack is
   applied:

```bash
make aws-s3-writer-apply
```

4. rerun the secret target:

```bash
make hetzner-create-secrets-sequential
```

or:

```bash
make hetzner-create-secrets
```

5. verify secrets exist before moving on.

This phase is safe to rerun. The scripts use `kubectl apply` semantics for the
secret manifests.

### 21.7 Failure During Baseline Measurement

Symptoms:

- `make hetzner-measure-resource-baseline` fails,
- no app nodes found,
- invalid derived quota,
- baseline files missing or empty.

Safe recovery:

1. verify the context first:

```bash
kubectl --context=benchmark get nodes -l node-group=app
```

2. rerun:

```bash
make hetzner-measure-resource-baseline
```

3. confirm:
   - `env/hetzner-resource-baseline.env` exists,
   - quota values are non-empty,
   - node count matches the intended topology.

Important rule:

- rerun this phase after any cluster recreation,
- rerun this phase after any app-node shape change,
- do not reuse an old baseline file after reprovisioning.

### 21.8 Failure During Manifest Rendering or Hetzner Preflight

Symptoms:

- `make hetzner-render-manifests` fails,
- `make hetzner-preflight-check` fails,
- missing baseline,
- missing Docker Hub tags,
- bad S3 access.

Safe recovery:

1. fix the reported dependency:
   - baseline file,
   - image tag visibility,
   - context availability,
   - S3 credentials,
   - Hetzner token.
2. rerun:

```bash
make hetzner-render-manifests DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=<tag>
make hetzner-preflight-check
```

Do not proceed to deployment while preflight is red. This is the cheapest phase
to fail and recover from.

### 21.9 Failure During Application Deployment

Symptoms:

- migration job fails,
- reset or seed job fails,
- pods do not become Ready,
- HPA objects missing in HPA mode,
- metrics-server missing for HPA mode.

Safe recovery:

1. inspect the relevant namespace:

```bash
kubectl --context=benchmark get pods -n mono
kubectl --context=benchmark get pods -n msa
kubectl --context=benchmark get jobs -n benchmark
kubectl --context=benchmark get jobs -n mono
kubectl --context=benchmark get jobs -n msa
```

2. inspect failing Job or pod logs.
3. rerun the deploy target for the same architecture and scaling mode:

```bash
make hetzner-deploy-sequential-architecture ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=<tag>
```

or the corresponding microservices/HPA command.

This phase is usually safe to rerun because the deploy script recreates the
relevant jobs and reapplies the manifests.

When to stop:

- database bootstrap keeps failing,
- migrations fail on a real schema issue,
- app secrets are wrong,
- pods remain CrashLoopBackOff after configuration is corrected once.

### 21.10 Failure During Smoke Run

Symptoms:

- benchmark Job fails quickly,
- no S3 attempt folder appears,
- threshold result is clearly invalid because deployment was unhealthy.

Safe recovery:

1. do not start the full suite yet.
2. inspect:
   - benchmark Job status,
   - benchmark Job logs,
   - `result-status.json` if present,
   - application pod health.
3. if the failure is infra/config-related, fix it and rerun the same smoke
   command with the same `RUN_ID` but a new `ATTEMPT`.

Only move to measured runs when:

- the smoke run reaches a sensible end state,
- S3 artifacts exist,
- metadata is correct,
- failures, if any, are attributable to load rather than misconfiguration.

### 21.11 Failure During Measured Single-Case Run

Symptoms:

- benchmark Job ends in `FAILED`,
- runtime error in k6,
- `result-status.json` shows S3 upload failure,
- thresholds are unreadable.

Safe recovery:

1. fetch or inspect:
   - Job logs,
   - `thresholds.json`,
   - `result-status.json`,
   - `metadata.json`.
2. classify the result:
   - runtime/config error,
   - overload with valid artifacts,
   - upload failure after valid execution.
3. rerun only the failed case with a new `ATTEMPT`.

Do not delete the previous attempt folder unless you are certain it is
completely invalid and you have already recorded why.

### 21.12 Failure During Full Suite Run

Symptoms:

- suite stops mid-matrix,
- one case fails while earlier cases succeeded,
- architecture switch fails in sequential mode,
- later cases inherit unstable deployment state.

Safe recovery:

1. identify the last successful case from S3 and local output.
2. preserve all successful attempt folders.
3. fix the root cause.
4. resume by rerunning only the missing or invalid cases, using new `ATTEMPT`
   or a new `RUN_ID` depending on how you want to organize the dataset.

Recommended rule:

- use the same `RUN_ID` when the suite is still conceptually one experiment
  session and only a subset of cases must be retried,
- use a new `RUN_ID` when the environment or image tag changed significantly.

### 21.13 Failure During Result Verification

Symptoms:

- some expected files are missing in S3,
- `metadata.json` exists but `raw.json.gz` or `summary.json` does not,
- `result-status.json` indicates upload failure.

Safe recovery:

1. do not destroy infra yet.
2. inspect:
   - benchmark Job logs,
   - `result-status.json`,
   - AWS credential validity,
   - S3 bucket name and prefix.
3. decide whether the attempt is still analytically usable.

Usable attempt examples:

- thresholds and metadata exist, and you intentionally classify it as
  overload.

Not yet usable examples:

- runtime failed before benchmark meaningfully started,
- S3 upload failed and core artifacts are missing,
- metadata is inconsistent with the actual scaling mode or architecture.

### 21.14 Failure During Destroy

Symptoms:

- destroy guard blocks because `S3_BENCHMARK_DATA_VERIFIED` is missing,
- destroy starts but some resources remain,
- shared stack is accidentally targeted too early.

Safe recovery:

1. verify S3 results first.
2. rerun the same destroy target:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-sequential-destroy-confirmed
```

or:

```bash
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-parallel-destroy-confirmed
```

3. destroy the shared stack only after confirming no more Hetzner runs are
   needed.

If destroy partially succeeds:

- rerun the same destroy target,
- then inspect Terraform outputs again,
- only consider lower-level manual cleanup after repeated wrapper retries fail.

---

## 22. Recommended Final-Thesis Flow

If your goal is the final Bab 4 dataset, the most defensible default is:

1. sequential topology,
2. smoke-test fixed mode,
3. complete fixed suite for monolith and microservices,
4. redeploy HPA mode,
5. smoke-test HPA mode,
6. complete HPA suite for monolith and microservices,
7. verify every run in S3,
8. destroy the experiment stack only after results are safe.

Recommended explicit checkpoints:

1. after Terraform apply:
   - contexts reachable
   - app/testing nodes present
2. after secret creation:
   - required secrets exist in `benchmark`, `mono`, and `msa`
3. after baseline measurement:
   - `env/hetzner-resource-baseline.env` exists
4. after each smoke run:
   - one valid attempt folder appears in S3
5. before fixed suite:
   - deployment confirmed in fixed mode
6. before HPA suite:
   - redeploy completed in HPA mode and HPA objects exist
7. before destroy:
   - all expected `run_id` prefixes verified in S3

Minimal command outline:

```bash
make env-init-app
make env-init-hetzner
make dockerhub-push-all DOCKERHUB_NAMESPACE=<namespace> IMAGE_TAG=$IMAGE_TAG
make hetzner-render-tfvars
make hetzner-shared-apply
make hetzner-sequential-apply
make hetzner-setup-context-sequential
make hetzner-create-secrets-sequential
make hetzner-measure-resource-baseline
make hetzner-preflight-check

# fixed
make hetzner-deploy-sequential-architecture ARCHITECTURE=monolith SCALING_MODE=fixed IMAGE_TAG=$IMAGE_TAG
CLOUD_PROVIDER=hetzner make run-benchmark-suite-sequential ...

# hpa
make hetzner-deploy-sequential-architecture ARCHITECTURE=monolith SCALING_MODE=hpa IMAGE_TAG=$IMAGE_TAG
CLOUD_PROVIDER=hetzner make run-benchmark-suite-sequential ...

# verify
aws s3 ls s3://<bucket>/experiments/<run-id>/ --recursive

# teardown
S3_BENCHMARK_DATA_VERIFIED=true make hetzner-sequential-destroy-confirmed
```

This keeps the final dataset:

- Hetzner-only,
- complete for `fixed` and `hpa`,
- internally fair between monolith and microservices,
- reproducible from Terraform apply to S3 artifact verification.
