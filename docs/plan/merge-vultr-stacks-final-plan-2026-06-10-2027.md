# Merge Vultr Stacks — Final Implementation Plan

Plan created: `2026-06-10 20:27`
Branch: `refactor/merge-vultr-stacks`
Worktree: `worktrees/refactor__merge-vultr-stacks`

## Context

The Vultr infrastructure currently uses 3 separate Terraform stacks:
- `vultr-shared` (VPC, SSH key, firewall)
- `vultr-sequential` (1 VKE cluster + PostgreSQL VM)
- `vultr-parallel` (2 VKE clusters + PostgreSQL VM)

The sequential/parallel stacks depend on shared via `terraform_remote_state`
with `backend = "local"`. This creates operational fragility (wrong destroy
order, stale state, manual console edits breaking references).

Merging into a single stack eliminates:
- `terraform_remote_state` dependency
- Shared-destroy dependency guard (no longer needed)
- Variable duplication across 3 stacks
- 3 separate tfvars files

## Design

### Merged stack structure

```
infra/terraform/vultr/
├── main.tf              # VPC + SSH + firewall + cluster modules
├── variables.tf         # all variables, deduplicated
├── outputs.tf           # conditional outputs per execution_mode
├── versions.tf
└── terraform.tfvars.example
```

### Core pattern: `for_each` with execution mode toggle

```hcl
variable "execution_mode" {
  type    = string
  default = "sequential"
  validation {
    condition     = contains(["sequential", "parallel"], var.execution_mode)
    error_message = "execution_mode must be sequential or parallel"
  }
}

locals {
  clusters = var.execution_mode == "parallel" ? {
    monolith = { architecture = "monolith" }
    msa      = { architecture = "msa" }
  } : {
    sequential = { architecture = "sequential" }
  }
}

module "cluster" {
  for_each = local.clusters
  source   = "./modules/vultr-vke-benchmark-cluster"

  cluster_name               = "${var.project}-vultr-${each.key}"
  architecture               = each.value.architecture
  region                     = var.region
  vpc_id                     = vultr_vpc.benchmark.id
  vpc_cidr                   = local.vpc_cidr
  ssh_key_ids                = [vultr_ssh_key.operator.id]
  postgres_firewall_group_id = vultr_firewall_group.postgres.id
  ...
}
```

### Outputs design

```hcl
# Sequential outputs (only when execution_mode = "sequential")
output "sequential_cluster_name" {
  value = var.execution_mode == "sequential" ? module.cluster["sequential"].cluster_name : null
}
output "sequential_kube_config" {
  value     = var.execution_mode == "sequential" ? module.cluster["sequential"].kube_config : null
  sensitive = true
}
output "sequential_postgres_private_ip" {
  value = var.execution_mode == "sequential" ? module.cluster["sequential"].postgres_private_ip : null
}

# Parallel outputs (only when execution_mode = "parallel")
output "monolith_cluster_name" {
  value = var.execution_mode == "parallel" ? module.cluster["monolith"].cluster_name : null
}
output "monolith_kube_config" {
  value     = var.execution_mode == "parallel" ? module.cluster["monolith"].kube_config : null
  sensitive = true
}
# ... same for msa_*
```

## Priority Order

```
P0  Core Terraform     →  Phase 1 (merged stack)
P1  Script updates     →  Phase 2 (terraform-vultr.sh, render-vultr-tfvars.sh)
P1  Script updates     →  Phase 3 (operator-dispatch.sh, setup-vultr-contexts.sh, secrets)
P2  Makefile           →  Phase 4
P3  Docs               →  Phase 5
P4  Verification       →  Phase 6
```

---

## Phase 1 — Create merged Vultr Terraform stack [P0]

### Goal

Create `infra/terraform/vultr/` with all shared + cluster resources in one stack,
using `for_each` with `execution_mode` toggle.

### What to create

```
infra/terraform/vultr/main.tf
infra/terraform/vultr/variables.tf
infra/terraform/vultr/outputs.tf
infra/terraform/vultr/versions.tf
infra/terraform/vultr/terraform.tfvars.example
```

### Source files to read

- `infra/terraform/vultr-shared/main.tf` — shared resources to inline
- `infra/terraform/vultr-shared/variables.tf` — shared variables to merge
- `infra/terraform/vultr-shared/outputs.tf` — shared outputs to include
- `infra/terraform/vultr-sequential/main.tf` — module call pattern
- `infra/terraform/vultr-sequential/variables.tf` — experiment variables
- `infra/terraform/vultr-sequential/outputs.tf` — sequential outputs
- `infra/terraform/vultr-parallel/main.tf` — parallel module calls
- `infra/terraform/vultr-parallel/variables.tf` — parallel variables
- `infra/terraform/vultr-parallel/outputs.tf` — parallel outputs
- `infra/terraform/modules/vultr-vke-benchmark-cluster/variables.tf` — module inputs

### Implementation

1. Create `infra/terraform/vultr/` directory
2. Write `versions.tf` — same constraints as current
3. Write `variables.tf` — merge all variables, deduplicate `project`/`region`
4. Write `main.tf` — inline shared resources + `for_each` module block
5. Write `outputs.tf` — conditional outputs for both modes
6. Write `terraform.tfvars.example` — example with `execution_mode = "sequential"`

### Key variable mapping

| Current (shared) | Current (sequential) | Current (parallel) | Merged |
|---|---|---|---|
| `project` | `project` | `project` | `project` |
| `region` | `region` | `region` | `region` |
| — | `sequential_cluster_name` | `monolith_cluster_name` + `msa_cluster_name` | `cluster_names` (map) |
| `vpc_subnet` + `vpc_subnet_mask` | — | — | `vpc_subnet`, `vpc_subnet_mask` |
| `operator_cidrs` | — | — | `operator_cidrs` |
| `operator_ssh_public_key` | — | — | `operator_ssh_public_key` |
| — | `kubernetes_version` | `kubernetes_version` | `kubernetes_version` |
| — | `app_node_plan` | `app_node_plan` | `app_node_plan` |
| — | `app_node_count` | `app_node_count` | `app_node_count` |
| — | `testing_node_plan` | `testing_node_plan` | `testing_node_plan` |
| — | `postgres_plan` | `postgres_plan` | `postgres_plan` |
| — | `postgres_os_id` | `postgres_os_id` | `postgres_os_id` |
| — | `postgres_password` | `postgres_password` | `postgres_password` |
| — | — | — | `execution_mode` (NEW) |

### Test

```bash
terraform -chdir=infra/terraform/vultr validate
terraform -chdir=infra/terraform/vultr fmt -check
```

### Commit suggestion

```
feat(terraform): create merged Vultr stack with execution_mode toggle
```

---

## Phase 2 — Update Terraform wrapper and tfvars scripts [P1]

### Goal

Update `terraform-vultr.sh` and `render-vultr-tfvars.sh` to work with the
merged stack.

### Files to edit

**`scripts/terraform-vultr.sh`:**
- Change `terraform_dir` from `infra/terraform/vultr-${stack}` to `infra/terraform/vultr`
- Remove the `shared`/`sequential`/`parallel` stack routing
- Simplify to single directory
- Keep destroy guards (S3 check + experiment state check can be simplified)
- Remove `POSTGRES_PASSWORD` export for shared (no longer separate)

**`scripts/render-vultr-tfvars.sh`:**
- Generate single `infra/terraform/vultr/terraform.tfvars`
- Add `execution_mode` variable to tfvars
- Merge shared + experiment variables into one file

### Source files to read

- `scripts/terraform-vultr.sh` — full file
- `scripts/render-vultr-tfvars.sh` — full file

### Test

```bash
bash -n scripts/terraform-vultr.sh
bash -n scripts/render-vultr-tfvars.sh
```

### Commit suggestion

```
refactor(scripts): update terraform-vultr.sh and render-vultr-tfvars.sh for merged stack
```

---

## Phase 3 — Update operator scripts [P1]

### Goal

Update scripts that read Terraform outputs or dispatch to Vultr stacks.

### Files to edit

**`scripts/operator-dispatch.sh`:**
- Merge `dispatch_shared_terraform` and `dispatch_experiment_terraform` for Vultr
  into a single `dispatch_vultr_terraform` function
- Update all Vultr dispatch cases

**`scripts/setup-vultr-contexts.sh`:**
- Update output names:
  - `sequential_kube_config` → `sequential_kube_config` (unchanged)
  - `monolith_kube_config` → `monolith_kube_config` (unchanged)
  - `msa_kube_config` → `msa_kube_config` (unchanged)
- Update `terraform -chdir` path from `vultr-sequential`/`vultr-parallel` to `vultr`

**`scripts/create-vultr-secrets-sequential.sh`:**
- Update `terraform -chdir` path from `vultr-sequential` to `vultr`
- Output name `postgres_private_ip` → `sequential_postgres_private_ip`

**`scripts/create-vultr-secrets-monolith.sh` and `scripts/create-vultr-secrets-microservices.sh`:**
- Check if they read from Terraform outputs directly
- Update paths if needed

**`scripts/terraform-vultr.sh`:**
- Remove the shared-destroy dependency guard (no longer needed — single stack)

### Source files to read

- `scripts/operator-dispatch.sh` — full file
- `scripts/setup-vultr-contexts.sh` — full file
- `scripts/create-vultr-secrets-sequential.sh` — full file
- `scripts/create-vultr-secrets-monolith.sh` — full file
- `scripts/create-vultr-secrets-microservices.sh` — full file

### Test

```bash
bash -n scripts/operator-dispatch.sh
bash -n scripts/setup-vultr-contexts.sh
bash -n scripts/create-vultr-secrets-sequential.sh
bash -n scripts/create-vultr-secrets-monolith.sh
bash -n scripts/create-vultr-secrets-microservices.sh
```

### Commit suggestion

```
refactor(scripts): update operator scripts for merged Vultr stack
```

---

## Phase 4 — Update Makefile [P2]

### Goal

Replace `vultr-shared-*`, `vultr-sequential-*`, `vultr-parallel-*` targets
with unified `vultr-plan`, `vultr-apply`, `vultr-destroy-confirmed`.

### What to change

- Remove: `vultr-shared-plan`, `vultr-shared-apply`, `vultr-shared-destroy-confirmed`
- Remove: `vultr-sequential-plan`, `vultr-sequential-apply`, `vultr-sequential-destroy-confirmed`
- Remove: `vultr-parallel-plan`, `vultr-parallel-apply`, `vultr-parallel-destroy-confirmed`
- Add: `vultr-plan`, `vultr-apply`, `vultr-destroy-confirmed` (single stack)
- Update: `terraform-fmt` and `terraform-validate` targets (single directory)
- Keep: `vultr-setup-context-*`, `vultr-create-secrets-*`, `vultr-measure-*`,
  `vultr-preflight-*`, `vultr-render-manifests`, `vultr-deploy-*`

### Source files to read

- `Makefile` — vultr target section

### Test

```bash
make -n help >/dev/null 2>&1
grep -n 'vultr-shared\|vultr-sequential\|vultr-parallel' Makefile
# Expected: no output
```

### Commit suggestion

```
chore(Makefile): unify Vultr Terraform targets for merged stack
```

---

## Phase 5 — Update docs [P3]

### Goal

Update all docs that reference the 3-stack Vultr topology.

### Files to edit

- `docs/infrastructure/vultr-sequential-lifecycle.md` — update Terraform workflow
- `docs/infrastructure/vultr-vke-runbook.md` — update stack references
- `docs/infrastructure/vultr-complete-architecture.md` — update architecture section
- `AGENTS.md` — update cloud providers table and stack references
- `README.md` — update directory structure

### Source files to read

- Each file above

### Test

```bash
grep -rn 'vultr-shared\|vultr-sequential\|vultr-parallel' docs/ AGENTS.md README.md | grep -v 'docs/plan/'
# Expected: no output
```

### Commit suggestion

```
docs: update Vultr docs for merged stack topology
```

---

## Phase 6 — Delete old stacks and final verification [P4]

### Goal

Delete `vultr-shared/`, `vultr-sequential/`, `vultr-parallel/` directories
and run full verification.

### What to delete

```
infra/terraform/vultr-shared/     (entire directory)
infra/terraform/vultr-sequential/ (entire directory)
infra/terraform/vultr-parallel/   (entire directory)
```

### Verification checklist

```bash
# 1. No old stack dirs remain
ls infra/terraform/ | grep -E 'vultr-(shared|sequential|parallel)'
# Expected: no output

# 2. Merged stack validates
terraform -chdir=infra/terraform/vultr validate

# 3. All scripts parse correctly
bash -n scripts/terraform-vultr.sh
bash -n scripts/render-vultr-tfvars.sh
bash -n scripts/operator-dispatch.sh
bash -n scripts/setup-vultr-contexts.sh
bash -n scripts/create-vultr-secrets-sequential.sh

# 4. No stale stack references
grep -rn 'vultr-shared\|vultr-sequential\|vultr-parallel' \
  --include='*.sh' --include='*.tf' --include='Makefile' \
  --include='*.md' --exclude-dir='.git' --exclude-dir='docs/plan' .

# 5. Module still exists
ls infra/terraform/modules/vultr-vke-benchmark-cluster/
```

### Commit suggestion

```
chore: remove old Vultr stack directories after merge
```

---

## Summary

| Phase | Priority | Description | Files Created | Files Edited | Files Deleted |
|---|---|---|---|---|---|
| 1 | P0 | Merged Terraform stack | 5 | 0 | 0 |
| 2 | P1 | Terraform wrapper + tfvars scripts | 0 | 2 | 0 |
| 3 | P1 | Operator scripts | 0 | ~5 | 0 |
| 4 | P2 | Makefile | 0 | 1 | 0 |
| 5 | P3 | Docs | 0 | ~5 | 0 |
| 6 | P4 | Delete old stacks + verification | 0 | 0 | ~15 |
| **Total** | | | **5** | **~13** | **~15** |

## Execution Rules

1. Before each phase: read all related code and docs
2. After each implementation: audit, test, stage
3. After staging: ask for commit with suggested message
4. After commit: proceed to next phase
5. Never skip the test step
6. Never commit without user approval
