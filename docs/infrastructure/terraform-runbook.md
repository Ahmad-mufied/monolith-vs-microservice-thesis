# Terraform Runbook

## 1. Purpose

Step-by-step guide for provisioning and destroying the dual EKS cluster
benchmark infrastructure.

---

## 2. Prerequisites

```text
- AWS CLI configured with admin credentials
- Terraform >= 1.6 installed
- kubectl installed
- helm installed
- AWS region: ap-southeast-1
```

### Terraform-Compatible AWS Profile

This repository assumes interactive sign-in is done with `aws login`, but
Terraform itself must use a companion profile that exposes those short-lived
credentials through `credential_process`.

Recommended local `~/.aws/config` layout:

```ini
[default]
login_session = arn:aws:iam::018982314415:user/muf-admin
region = us-east-1

[profile terraform-process]
credential_process = aws configure export-credentials --profile default --format process
region = ap-southeast-1
```

Operator rules:

- do not commit AWS credentials into the repository
- do not copy access keys, session tokens, or secret keys into `env/` or
  `terraform.tfvars`
- do not let repository scripts mutate `~/.aws/config`
- keep `terraform-process` as the standard local profile name unless you
  intentionally override `TERRAFORM_AWS_PROFILE`

Verify the auth bridge before any Terraform apply or destroy:

```bash
aws login
make terraform-auth-check
```

For interrupted apply or destroy recovery, use:

```bash
make terraform-recovery-check
```

This command is audit-only. It does not mutate Terraform state or AWS
resources. It compares local Terraform state with live AWS state for the
critical benchmark resources:

- shared VPC
- shared IAM role
- EKS clusters
- EKS managed node groups
- EKS pod identity associations
- EKS `eks-pod-identity-agent` add-on
- RDS instances

Expected status classes:

- `OK`
- `STALE_IN_STATE`
- `IN_PROGRESS`
- `REVIEW`
- `BLOCKED`

### Interrupted Terraform Apply or Destroy Recovery

Use this flow when `make eks-apply`, `make eks-destroy`, or a direct Terraform
operation is interrupted by laptop shutdown, sleep, lost network, expired AWS
session, or a closed terminal.

Do not immediately rerun `make eks-apply` and approve a replacement plan. First
reconcile Terraform state with live AWS resources.

1. Restore AWS auth.

```bash
aws login
make terraform-auth-check
```

If this fails with an AWS auth error, fix credentials first. Do not edit
Terraform state while credentials are stale.

2. Run the recovery audit.

```bash
make terraform-recovery-check
```

Interpret the result:

- `OK` means the resource exists in AWS and matches the expected ready state.
- `IN_PROGRESS` means AWS is still creating, updating, or deleting the
  resource. Wait and rerun the recovery check.
- `STALE_IN_STATE` means Terraform state still tracks a resource that AWS no
  longer has. Review the suggested `terraform state rm` command before using
  it.
- `REVIEW` means the script found a case that needs operator judgment before
  another apply.
- `BLOCKED` means a preflight requirement failed, usually AWS auth or missing
  Terraform directories.

3. If a node group is active in AWS but tainted in Terraform state, untaint it.

This happens when Terraform was disconnected during node group creation. AWS
may finish provisioning successfully, but Terraform can still mark the resource
as tainted because it did not observe a clean completion.

The recovery script prints the exact command. Example:

```bash
AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/experiment untaint 'module.msa_cluster.module.eks.module.eks_managed_node_group["app_nodes"].aws_eks_node_group.this[0]'
AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/experiment untaint 'module.msa_cluster.module.eks.module.eks_managed_node_group["testing_nodes"].aws_eks_node_group.this[0]'
```

The repository also includes a focused helper for this specific recovery case.
It is dry-run by default:

```bash
make terraform-recovery-fix-tainted-nodegroups
```

If the dry-run reports that the tainted node group is active and healthy in AWS,
apply the safe untaint operation with:

```bash
make terraform-recovery-fix-tainted-nodegroups-apply
```

Only use `untaint` after confirming the AWS node group is `ACTIVE`. Do not
untaint a node group that is still creating, deleting, degraded, or missing.
The helper enforces this guardrail by only untainting node groups that are
`ACTIVE` and have zero EKS node group health issues.

4. If the recovery script reports `IN_PROGRESS`, wait for AWS to settle.

Useful AWS checks:

```bash
AWS_PROFILE=terraform-process aws eks describe-cluster \
  --region ap-southeast-1 \
  --name skripsi-msa \
  --query 'cluster.status' \
  --output text

AWS_PROFILE=terraform-process aws eks list-nodegroups \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --output text

AWS_PROFILE=terraform-process aws eks describe-nodegroup \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --nodegroup-name <node-group-name> \
  --query '{status:nodegroup.status,health:nodegroup.health,scaling:nodegroup.scalingConfig,resources:nodegroup.resources}' \
  --output json
```

If a node group exists but fails to become active, inspect the backing Auto
Scaling Group activities. This usually exposes quota or capacity errors that
Terraform output hides.

```bash
AWS_PROFILE=terraform-process aws autoscaling describe-scaling-activities \
  --region ap-southeast-1 \
  --auto-scaling-group-name <asg-name> \
  --max-items 10 \
  --output table
```

5. Plan through the repository wrapper.

The experiment stack needs `DB_PASSWORD`, which is injected by
`scripts/terraform-experiment.sh` from `env/terraform.experiment.env`. A direct
`terraform -chdir=infra/terraform/experiment plan` can fail with `No value for
required variable "db_password"`.

Use:

```bash
TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-experiment.sh plan -input=false -lock=false -no-color
```

Expected recovery outcomes:

- `No changes`: state and AWS are synchronized.
- Only missing add-ons or small known resources are planned: review and apply.
- Any `destroy`, `replace`, or unexpected large create action appears: stop and
  inspect before approving.

6. Apply only after reviewing the plan.

If the reviewed plan is small and expected:

```bash
TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-experiment.sh apply
```

For recovery automation where the plan is already reviewed and contains only
expected actions, `-auto-approve` is acceptable, but avoid it while diagnosing
unknown drift.

7. Confirm the final state.

```bash
make terraform-recovery-check
TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-experiment.sh plan -input=false -lock=false -no-color
```

Healthy final result:

- recovery check reports all critical resources as `OK`
- plan reports `No changes`
- no node group is still marked tainted
- no unexpected destroy or replacement remains

Do not run `terraform state rm` or import commands as the first response to an
interruption. Use them only when live AWS and Terraform state clearly disagree:

- use `state rm` when state tracks a resource that AWS no longer has
- use `import` when AWS has a resource that state does not track and you intend
  Terraform to manage it
- use `untaint` when the same resource exists, is healthy in AWS, and Terraform
  only wants to replace it because the state is tainted

### Recovery Case Matrix

Interrupted Terraform does not always fail in the same way. Use this matrix to
classify the recovery path before changing state.

| Case | Common signal | Solve mode | How to solve |
| --- | --- | --- | --- |
| AWS auth expired | `ExpiredTokenException`, `UnrecognizedClientException`, `AccessDenied`, or recovery check `BLOCKED` | Manual | Run `aws login`, then `make terraform-auth-check`, then rerun `make terraform-recovery-check`. Do not edit state while auth is stale. |
| Resource still being created or deleted | recovery check reports `IN_PROGRESS`; EKS/RDS/add-on is not ready yet | Manual wait + inspect | Wait and rerun `make terraform-recovery-check`. If node groups stay stuck, inspect ASG scaling activities with `aws autoscaling describe-scaling-activities`. |
| Node group is tainted but healthy in AWS | recovery check reports `REVIEW` and says the active node group is tainted | Script available | Run `make terraform-recovery-fix-tainted-nodegroups` for dry-run. If it reports the node group is `ACTIVE` with zero health issues, run `make terraform-recovery-fix-tainted-nodegroups-apply`, then run the wrapper plan. |
| Terraform state tracks a resource missing in AWS | recovery check reports `STALE_IN_STATE` | Manual review | Confirm the resource is truly gone in AWS. If Terraform should forget it, run the suggested `terraform state rm` command, then plan through `scripts/terraform-experiment.sh`. |
| AWS has a resource but Terraform state does not track it | AWS CLI shows the resource, but `terraform state list` has no matching address | Manual import | Do not recreate blindly. Import the resource into the correct Terraform address, then plan. Import IDs are resource-specific, so verify the module address and provider import format first. |
| Terraform state lock remains after crash | `Error acquiring the state lock` | Manual review | Confirm no Terraform process is still running. Retry once. If the lock is truly stale, run `terraform force-unlock <LOCK_ID>` for the affected stack. Do not force-unlock while another apply/destroy is running. |
| Plan wants to replace or destroy large resources | plan shows `-/+`, `must be replaced`, or unexpected `destroy` | Manual review | Stop before approving. Check whether the resource is tainted, whether config changed, and whether AWS live state is healthy. Use `untaint` only for healthy tainted resources; otherwise reconcile the real drift. |
| Direct experiment plan asks for `db_password` | `No value for required variable "db_password"` | Use wrapper | Run `TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-experiment.sh plan -input=false -lock=false -no-color`. The wrapper injects `TF_VAR_db_password` from `env/terraform.experiment.env`. |
| Node group fails because of quota or capacity | ASG scaling activity shows `VcpuLimitExceeded`, insufficient capacity, launch failure, or subnet/IP issue | Manual infra fix | Fix the AWS-side blocker first: quota, instance type, subnet capacity, or launch settings. Then rerun recovery check and plan. Do not edit Terraform state to hide a real AWS provisioning failure. |

Current helper coverage:

- `make terraform-recovery-check`: read-only audit for shared VPC, shared IAM
  role, clusters, node groups, Pod Identity associations, EKS add-ons, and RDS.
- `make terraform-recovery-fix-tainted-nodegroups`: dry-run helper for the
  safe tainted-node-group case only.
- `make terraform-recovery-fix-tainted-nodegroups-apply`: runs `untaint` only
  for tainted node groups that are `ACTIVE` in AWS and have zero node group
  health issues.

Cases that intentionally remain manual:

- `terraform state rm`
- `terraform import`
- `terraform force-unlock`
- approving a plan with `destroy` or replacement actions
- quota/capacity remediation

Those actions can remove state, adopt existing AWS resources, or change
cost-heavy infrastructure, so they require operator review and a clean plan
afterward.

Use this after:

- laptop sleep or shutdown during `terraform apply`
- network interruption during apply or destroy
- AWS session expiration during Terraform execution
- manual AWS CLI cleanup that may have drifted local Terraform state

Quick verification checklist for the `shared` stack before applying a new
`experiment` stack:

```bash
aws login
make terraform-auth-check
make terraform-recovery-check
AWS_PROFILE=terraform-process terraform -chdir=infra/terraform/shared plan -input=false -lock=false
```

Healthy expected outcome:

- `make terraform-auth-check` passes
- `make terraform-recovery-check` reports `shared` as `OK`
- `terraform plan` for `infra/terraform/shared` returns `No changes`

If the `shared` plan is not clean, stop before `make eks-apply` and reconcile
the shared stack first.

---

## 3. Step 0 — Create Persistent Resources (Once)

ECR repositories and S3 results bucket are persistent resources. Create them
manually once before the first experiment. They survive `terraform destroy`.

```bash
# S3 results bucket
aws s3api create-bucket \
  --bucket skripsi-benchmark-results \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-public-access-block \
  --bucket skripsi-benchmark-results \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ECR repositories
for repo in monolith api-gateway auth-service item-service transaction-service seed-runner k6-runner; do
  aws ecr create-repository \
    --repository-name "skripsi/$repo" \
    --image-tag-mutability IMMUTABLE \
    --region ap-southeast-1
done
```

These resources are not managed by Terraform.

---

## 4. Step 1 — Build, Push, and Render Images

Build and push images before Terraform apply so the expected deployable tag
already exists in ECR. Manual manifest rendering is optional now because the EKS
deploy scripts rerun it automatically before validation and apply.

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)

make ecr-push-all IMAGE_TAG=$IMAGE_TAG
make eks-render-manifests IMAGE_TAG=$IMAGE_TAG
```

`make eks-render-manifests` is still useful as a manual preflight check, but
`make eks-deploy-monolith` and `make eks-deploy-msa` now rerun the same render
step automatically. The repository manifests remain unchanged; the rendered
manifests are written to a temporary directory for validation or apply. If you
deploy a custom tag, pass the same `IMAGE_TAG` to the deploy command so the
rendered manifests use the intended image tag.

The deploy commands still work without an explicit `IMAGE_TAG` because the
scripts default to `git rev-parse --short HEAD` at execution time. That implicit
mode is acceptable for quick local deploys when `HEAD` will not change during
the session. The runbook uses the explicit pinned `IMAGE_TAG` pattern as the
primary example because it guarantees that build/push and deploy steps use the
same tag even if new commits are created later in the workflow.

---

## 5. Step 2 — Apply Shared Infrastructure

Shared resources (VPC, IAM k6-runner role) are provisioned once and reused
across experiment runs.

Current `shared` stack inventory:

- 1 VPC
- 2 private subnets
- 2 public subnets
- route tables and route table associations for public/private routing
- 1 internet gateway
- 1 NAT gateway
- 1 Elastic IP for the NAT gateway
- default VPC network ACL / route table / security group objects managed by the VPC module
- 1 IAM role for benchmark result upload:
  - `skripsi-k6-runner`
- 1 inline IAM policy attached to that role:
  - `s3-results-access`

Why this is separate from `experiment`:

- `shared` provides the reusable network and IAM foundation
- `experiment` creates the cost-heavy per-session resources on top of it:
  - EKS clusters
  - node groups
  - RDS instances

```bash
cd infra/terraform/shared

# Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set s3_results_bucket to the manually created bucket name

terraform init
terraform plan
terraform apply
```

Optional helper flow:

```bash
make env-init-eks
make eks-render-tfvars
make terraform-auth-check
```

This renders `infra/terraform/shared/terraform.tfvars` from
`env/terraform.shared.env`.

Note the outputs:

```bash
AWS_PROFILE=terraform-process terraform output
# vpc_id, private_subnet_ids, k6_runner_role_arn
```

This workflow assumes a single operator runs Terraform from the same laptop.
The resulting local state file at `infra/terraform/shared/terraform.tfstate`
becomes the source of truth consumed by the `experiment` stack.

---

## 6. Step 3 — Apply Experiment Clusters

```bash
cd infra/terraform/experiment

# Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   cluster_endpoint_public_access_cidrs = ["<operator-public-ip>/32"]

AWS_PROFILE=terraform-process bash ../../../scripts/terraform-experiment.sh init
AWS_PROFILE=terraform-process bash ../../../scripts/terraform-experiment.sh plan
AWS_PROFILE=terraform-process bash ../../../scripts/terraform-experiment.sh apply
```

If you use the helper flow above, `make eks-render-tfvars` also renders
`infra/terraform/experiment/terraform.tfvars` from
`env/terraform.experiment.env`.

`DB_PASSWORD` stays in `env/terraform.experiment.env` and is injected into
Terraform at runtime through `TF_VAR_db_password`. It is no longer rendered
into `infra/terraform/experiment/terraform.tfvars`.

For laptop-driven operation, set the public EKS API endpoint allowlist to the
current operator IP before rendering tfvars:

```bash
make env-init-eks
# Edit env/terraform.experiment.env:
#   CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=manual          # optional for custom/static CIDRs
#   CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS=<operator-public-ip>/32
make eks-render-tfvars
```

The benchmark cluster module keeps the private endpoint enabled and only uses
the public endpoint as a restricted operator entry path. Do not use
`0.0.0.0/0`.

By default, `make env-init-eks` uses `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=auto`
and attempts to detect the current operator public IP automatically. If the
detected IP changes later, re-running `make env-init-eks` refreshes the CIDR
before you render tfvars again. If the autodetect helper receives a malformed
non-IP response, it now fails instead of writing an invalid CIDR value into the
env file.

If the clusters already exist and your operator public IP later changes, update
`CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS`, rerender tfvars, and run
`terraform plan` plus `terraform apply` again for the existing `experiment`
stack. This updates the EKS endpoint access configuration in place; it does not
mean recreating both clusters from scratch.

If you need a custom static CIDR list or multiple operator networks, set
`CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=manual` and maintain the
comma-separated CIDR list yourself.

This provisions two EKS clusters and two RDS instances in parallel.
Expect approximately 15–20 minutes.

Verify outputs:

```bash
AWS_PROFILE=terraform-process terraform output
# monolith_cluster_name, monolith_rds_endpoint
# msa_cluster_name, msa_rds_endpoint
# kubeconfig commands for both clusters
```

`experiment` reads `vpc_id`, `private_subnet_ids`, and `k6_runner_role_arn`
from the local shared state file at `../shared/terraform.tfstate`.
Apply `shared` first, then `experiment`, from the same laptop.

The `terraform-auth-check`, `eks-apply`, and `eks-destroy` Makefile targets now
pass `TERRAFORM_AWS_PROFILE` explicitly into the Terraform wrapper script, so a
non-default profile selection is preserved consistently across those flows.

---

## 7. Step 4 — Configure kubectl Contexts

```bash
make eks-setup-contexts
# or manually:
aws eks update-kubeconfig --name skripsi-monolith --region ap-southeast-1 --alias monolith
aws eks update-kubeconfig --name skripsi-msa      --region ap-southeast-1 --alias msa

# Verify
kubectl --context=monolith get nodes
kubectl --context=msa get nodes
```

---

## 8. Step 5 — Create Secrets and Validate Manifests

Before running deploy scripts, create Kubernetes Secrets in each cluster.
See `docs/infrastructure/secret-management.md` for required secret keys.

Optional helper commands:

```bash
make eks-create-secrets
```

This command creates the benchmark and application secrets for both EKS clusters
from the EKS env helper files under `env/` plus Terraform outputs. It also uses
`TERRAFORM_AWS_PROFILE` internally so their `terraform output` calls follow the
same auth path as `make eks-apply` and `make eks-destroy`.

If you only need to recreate one cluster's secrets, use the granular targets:

```bash
make create-eks-secrets-monolith
make create-eks-secrets-microservices
```

```bash
make eks-validate-manifests
```

This must pass before deploy or benchmark runs. It fails when EKS manifests
still point at local-only images or unresolved ECR placeholders.

---

## 9. Step 6 — Deploy Applications

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)

# Deploy monolith cluster (fixed replica mode by default)
make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG

# Deploy MSA cluster (fixed replica mode by default)
make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together in fixed mode:

```bash
make eks-deploy-all-fixed IMAGE_TAG=$IMAGE_TAG
```

For HPA mode, deploy per cluster:

```bash
SCALING_MODE=hpa make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
SCALING_MODE=hpa make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Alternative when you want both clusters deployed together in HPA mode:

```bash
make eks-deploy-all-hpa IMAGE_TAG=$IMAGE_TAG
```

Quick local alternative for per-cluster deploys:

```bash
SCALING_MODE=fixed make eks-deploy-monolith
SCALING_MODE=fixed make eks-deploy-msa

SCALING_MODE=hpa make eks-deploy-monolith
SCALING_MODE=hpa make eks-deploy-msa
```

Use the shorter implicit form only when you intentionally want the deploy
scripts to derive `IMAGE_TAG` from the current `HEAD` at command execution
time.

---

## 10. Step 7 — Install Datadog

```bash
# Add Datadog Helm repo
make datadog-repo

# Install on monolith cluster
DATADOG_API_KEY=<redacted> make datadog-install-eks-monolith

# Install on MSA cluster
DATADOG_API_KEY=<redacted> make datadog-install-eks-msa
```

Placeholder values such as `replace-me`, `CHANGE_ME`, `your_api_key`, and
`redacted` are rejected by the EKS deploy and Datadog secret helper scripts.

---

## 11. Step 8 — Run Parallel Benchmark

```bash
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket_name>
```

For HPA mode:

```bash
make run-benchmark-parallel \
  SCENARIO=create-transaction \
  TARGET_RPS=2500 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  SCALING_MODE=hpa \
  K6_PROFILE=hpa \
  S3_BUCKET=<bucket_name>
```

---

## 12. Step 9 — Verify S3 Results

```bash
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive
```

Expected files per attempt:

```text
experiments/eks-run-001/monolith/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/monolith/login/1000rps/attempt-01/metadata.json
experiments/eks-run-001/monolith/login/1000rps/attempt-01/raw.json.gz
experiments/eks-run-001/monolith/login/1000rps/attempt-01/datadog-time-window.json
experiments/eks-run-001/microservices/login/1000rps/attempt-01/summary.json
...
```

Do not destroy infrastructure until all expected files are present.

---

## 13. Step 10 — Destroy Infrastructure

```bash
# Destroy clusters and RDS only after verifying benchmark data exists in S3
make eks-destroy-confirmed

# Destroy shared resources (only when experiment is fully complete).
# WARNING: this removes the VPC and IAM roles.
# ECR repositories and the S3 results bucket are manual resources outside Terraform.
# Benchmark results remain safe in S3 after this command.
cd infra/terraform/shared
AWS_PROFILE=terraform-process terraform destroy
```

Important:

- `make eks-destroy` now refuses to forward `terraform destroy` unless you
  explicitly acknowledge that benchmark artifacts have already been verified in
  S3.
- Use `make eks-destroy-confirmed` as the normal operator command after that
  verification step.
- The lower-level form `S3_BENCHMARK_DATA_VERIFIED=true make eks-destroy` still
  works if you need the explicit environment variable for scripting.
- ECR repositories are **not** destroyed by Terraform because they are created manually.
- S3 results bucket is **not** destroyed by Terraform. Benchmark data is safe.
- To manually delete the S3 bucket after confirming all data is backed up:
  ```bash
  aws s3 rm s3://<bucket> --recursive
  aws s3api delete-bucket --bucket <bucket>
  ```

---

## 14. Variable Reference

### shared/terraform.tfvars

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region | `ap-southeast-1` |
| `project` | Resource name prefix | `skripsi` |
| `s3_results_bucket` | S3 bucket for benchmark result artifacts | `skripsi-benchmark-results` |

### experiment/terraform.tfvars

| Variable | Description | Example |
|---|---|---|
| `aws_region` | AWS region | `ap-southeast-1` |
| `db_password` | RDS master password | strong password |

---

## 15. Troubleshooting

For a broader operator command cheat sheet that covers deployment, job,
Datadog, and AWS CLI debugging, see
`docs/infrastructure/eks-debug-command-reference.md`.

**EKS nodes not ready:**
```bash
kubectl --context=monolith describe nodes
kubectl --context=monolith get events -A
```

**RDS not reachable from pods:**
- Verify security group allows port 5432 from EKS node security group
- Verify RDS is in private subnets
- Test from a pod: `kubectl --context=monolith run pg-test --image=postgres:18 --rm -it -- psql "$DATABASE_URL"`

**k6 job fails:**
```bash
kubectl --context=monolith logs job/k6-benchmark-monolith -n benchmark
```

**Terraform state conflict:**
- Ensure only one operator runs `terraform apply` at a time
- If you later move to multi-operator or CI usage, introduce a remote backend then
