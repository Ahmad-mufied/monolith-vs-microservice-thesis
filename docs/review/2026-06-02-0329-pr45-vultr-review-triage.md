# PR #45 Vultr Review Triage

Date: 2026-06-02 03:29 Asia/Jakarta

PR: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45

Branch: `feature/add-vultr-infra`

## Purpose

Track and prioritize PR review feedback for the Vultr VKE infrastructure
integration. This document separates valid actionable findings from lower-risk
nitpicks and records the implementation plan before fixes are applied.

## Current PR State

- PR state: `OPEN`
- Draft: `false`
- Mergeable: `MERGEABLE`
- Review decision: empty at the time of triage
- Status checks observed:
  - `CodeRabbit`: success
  - `Graphite / AI Reviews`: success
- Review threads fetched via `gh api graphql`.
- Unresolved review threads: `8`
- Outdated review threads: `0`

## Implementation Results

| Priority | Review IDs | Status | Commit |
|---|---|---|---|
| P0 | R1 | Done | `aa964de` |
| P1 | R2, R3, R4, R5 | Done | `45498d9` |
| P2 | R6, R7, R8, R11 | Done | `4b46a7f` |
| P3 | R9, R10 | Done | `9b220e7` |

Final decision for R10: do not add conditional modules to the parallel stack.
The parallel stack intentionally creates both architecture clusters for
same-window benchmark comparison. Sequential mode remains the supported
lower-cost/quota fallback.

## Priority Summary

| Priority | Count | Meaning |
|---|---:|---|
| P0 | 1 | Security/injection risk that can compromise VM bootstrap or secret handling. |
| P1 | 4 | Fail-fast correctness issues that can silently create broken runtime config. |
| P2 | 3 | Hardening issues that reduce portability or close security/race gaps. |
| P3 | 2 | Cost/documentation guardrails and optional design clarifications. |

Recommended execution order:

1. P0 first, because it is a real shell/cloud-init injection risk.
2. P1 next, because malformed PostgreSQL IPs can silently create bad secrets.
3. P2 next, because the fixes are small and reduce operational footguns.
4. P3 last, because cost guardrails need careful alignment with the thesis
   parallel benchmark design.

## P0 - Critical

### R1 - Cloud-init SQL command interpolates password into shell command

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854787
- File: `infra/terraform/modules/vultr-vke-benchmark-cluster/main.tf`
- Related file: `infra/terraform/modules/vultr-vke-benchmark-cluster/templates/postgres-cloud-init.yaml.tftpl`
- Status: `done`
- Validity: valid and high priority.
- Reviewer concern: `postgres_password_sql_literal` is placed inside a
  double-quoted shell command in cloud-init `runcmd`. A password containing
  shell-sensitive characters can break the command or be interpreted by shell.

Current implementation:

```text
sudo -u postgres psql ... -c "CREATE ROLE ... PASSWORD '${postgres_password_sql_literal}';"
sudo -u postgres psql ... -c "ALTER USER postgres PASSWORD '${postgres_password_sql_literal}';"
```

Risk:

- SQL single-quote escaping is not enough because the value is still embedded
  inside a shell command.
- A generated password is normally hex-like today, but the module variable
  accepts arbitrary input. Future/manual passwords could trigger this issue.

Plan:

- Move SQL into a cloud-init `write_files` entry, for example
  `/root/init-postgres.sql`.
- Keep SQL-level single quote escaping.
- Run `sudo -u postgres psql -v ON_ERROR_STOP=1 -f /root/init-postgres.sql`.
- Remove the SQL file after execution.
- Keep the Terraform input sensitive and avoid logging the password.

Implementation:

- Moved SQL bootstrap into cloud-init `write_files` at
  `/root/init-postgres.sql`.
- Executes SQL through `psql -f` and removes the bootstrap SQL file afterward.
- Commit: `aa964de`

Validation:

- `terraform fmt -check -recursive infra/terraform/modules/vultr-vke-benchmark-cluster`
- `terraform -chdir=infra/terraform/vultr-experiment validate`
- `terraform -chdir=infra/terraform/vultr-experiment-sequential validate`

Draft quote reply:

```text
> The cloud-init template currently interpolates postgres_password_sql_literal into a double-quoted shell command...

Addressed by moving the PostgreSQL bootstrap SQL into a cloud-init-written SQL file and executing it with `psql -f`, so the password is no longer interpolated through a shell command.
```

## P1 - Major Correctness / Fail-Fast

### R2 - `postgres_password` placeholder is committed in tfvars example

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854797
- File: `infra/terraform/vultr-experiment-sequential/terraform.tfvars.example`
- Status: `done`
- Validity: valid, but fix should be applied to both Vultr tfvars examples.
- Reviewer concern: example tfvars includes
  `postgres_password = "replace-with-generated-password"`.

Risk:

- Operators can copy the placeholder into `terraform.tfvars`.
- It normalizes putting DB password values into tfvars, even though wrapper
  scripts already support passing `TF_VAR_postgres_password` from `env/vultr.env`.

Plan:

- Remove `postgres_password` from both:
  - `infra/terraform/vultr-experiment/terraform.tfvars.example`
  - `infra/terraform/vultr-experiment-sequential/terraform.tfvars.example`
- Add comments explaining that `POSTGRES_PASSWORD` belongs in `env/vultr.env`
  and is exported as `TF_VAR_postgres_password` by `scripts/terraform-vultr.sh`.
- Confirm `scripts/render-vultr-tfvars.sh` still does not write
  `postgres_password` into generated tfvars.

Implementation:

- Removed password placeholder from both Vultr tfvars examples.
- Removed `postgres_password` from `scripts/render-vultr-tfvars.sh` output.
- Kept runtime password injection through `scripts/terraform-vultr.sh` and
  `TF_VAR_postgres_password`.
- Commit: `45498d9`

Validation:

- `terraform fmt -check -recursive infra/terraform/vultr-experiment infra/terraform/vultr-experiment-sequential`
- `bash -n scripts/terraform-vultr.sh scripts/render-vultr-tfvars.sh`

Draft quote reply:

```text
> The example tfvars file contains a literal placeholder for postgres_password...

Addressed by removing the password placeholder from the Vultr tfvars examples and documenting that the password is supplied via `env/vultr.env` / `TF_VAR_postgres_password` through the Terraform wrapper.
```

### R3 - MSA secret creation can silently use empty PostgreSQL IP

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854801
- File: `scripts/create-vultr-secrets-microservices.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: `postgres_ip="$(terraform ...)"` can fail or return empty
  and the script may continue into malformed DB URLs.

Plan:

- Add a small helper that captures Terraform stderr and validates non-empty
  output.
- Preserve sequential override behavior through `VULTR_SEQUENTIAL_POSTGRES_IP`.
- Fail with a clear message when the output command fails or returns empty.

Implementation:

- Added validated Terraform output helper with captured stderr.
- Preserved `VULTR_SEQUENTIAL_POSTGRES_IP` override.
- Commit: `45498d9`

Validation:

- `bash -n scripts/create-vultr-secrets-microservices.sh`
- Negative smoke by temporarily pointing at missing state should fail before
  `kubectl create secret`.

Draft quote reply:

```text
> The assignment to postgres_ip using terraform output can produce an empty string on failure...

Addressed by validating the Terraform output before constructing Kubernetes Secrets and failing fast with a clear error when the MSA PostgreSQL private IP is unavailable.
```

### R4 - Monolith secret creation can silently use empty PostgreSQL IP

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854821
- File: `scripts/create-vultr-secrets-monolith.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: same failure mode as R3 for
  `monolith_postgres_private_ip`.

Plan:

- Apply the same validated Terraform output helper as R3.
- Keep `VULTR_SEQUENTIAL_POSTGRES_IP` override supported.

Implementation:

- Added validated Terraform output helper with captured stderr.
- Preserved `VULTR_SEQUENTIAL_POSTGRES_IP` override.
- Commit: `45498d9`

Validation:

- `bash -n scripts/create-vultr-secrets-monolith.sh`

Draft quote reply:

```text
> The terraform command substitution assigned to postgres_ip can silently fail and produce an empty string...

Addressed by validating the monolith PostgreSQL private IP before creating secrets, so malformed DB URLs are not generated when Terraform output is missing or empty.
```

### R5 - Sequential secret creation can export empty PostgreSQL IP

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854834
- File: `scripts/create-vultr-secrets-sequential.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: sequential script exports `VULTR_SEQUENTIAL_POSTGRES_IP`
  without checking Terraform output failure or empty value.

Plan:

- Validate `terraform -chdir=infra/terraform/vultr-experiment-sequential output -raw postgres_private_ip`.
- Capture Terraform stderr and print it on failure.
- Export only after successful non-empty output.

Implementation:

- Captures Terraform stderr and exits before exporting
  `VULTR_SEQUENTIAL_POSTGRES_IP` if the output fails or is empty.
- Commit: `45498d9`

Validation:

- `bash -n scripts/create-vultr-secrets-sequential.sh`

Draft quote reply:

```text
> The terraform output call that sets postgres_ip can fail and produce an empty value...

Addressed by validating the sequential PostgreSQL private IP before exporting it to the monolith/MSA secret creation scripts.
```

## P2 - Hardening / Reliability

### R6 - `printf` uses env values as format strings

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854845
- File: `scripts/lib/cloud-provider.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: environment-derived cluster names are passed directly to
  `printf`, so `%` can be interpreted as a format specifier.

Plan:

- Change env-value `printf "$value"` calls to `printf '%s' "$value"`.
- Keep literal hardcoded values as-is or normalize them too for consistency.

Implementation:

- Environment-derived cluster names now use `printf '%s'`.
- Commit: `4b46a7f`

Validation:

- `bash -n scripts/lib/cloud-provider.sh`
- Quick shell smoke:
  `CLOUD_PROVIDER=vultr VULTR_MONOLITH_CLUSTER_NAME='x%s' bash -c 'source scripts/lib/cloud-provider.sh; provider_default_cluster_name monolith'`

Draft quote reply:

```text
> In provider_default_cluster_name(), avoid using variable contents as printf format strings...

Addressed by printing environment-derived cluster names with `printf '%s'`, so `%` characters are treated as data.
```

### R7 - Resource baseline JSON output directory is not created

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854865
- File: `scripts/measure-vultr-resource-baseline.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: script creates only the env output directory, not the JSON
  output directory.

Plan:

- Add `mkdir -p "$(dirname "$output_json")"` near startup.

Implementation:

- Creates both env and JSON output directories before writing baseline files.
- Commit: `4b46a7f`

Validation:

- `bash -n scripts/measure-vultr-resource-baseline.sh`

Draft quote reply:

```text
> The script only ensures the env output directory exists...

Addressed by creating the JSON output directory before writing `VULTR_RESOURCE_BASELINE_JSON`.
```

### R8 - Kubeconfig write has a brief permissive-umask window

- Thread: https://github.com/Ahmad-mufied/monolith-vs-microservice-thesis/pull/45#discussion_r3336854878
- File: `scripts/setup-vultr-contexts.sh`
- Status: `done`
- Validity: valid.
- Reviewer concern: kubeconfig is written first and chmodded afterward, leaving
  a small exposure window if the process runs under a permissive umask.

Plan:

- Capture current umask.
- Set `umask 077` before writing kubeconfig.
- Restore old umask after write.
- Keep final `chmod 600`.
- Consider the same umask handling for merged `$HOME/.kube/config` write if
  touched in the same function.

Implementation:

- Writes both generated kubeconfig and merged kubeconfig under `umask 077`.
- Commit: `4b46a7f`

Validation:

- `bash -n scripts/setup-vultr-contexts.sh`

Draft quote reply:

```text
> The kubeconfig write uses a plain redirect then chmod 600...

Addressed by writing kubeconfig files under a restrictive `umask 077` before chmod, closing the world-readable race window.
```

## P3 - Cost / UX / Design Guardrails

### R9 - Sequential tfvars example needs explicit cost guardrails

- Source: CodeRabbit nitpick in review summary.
- File: `infra/terraform/vultr-experiment-sequential/terraform.tfvars.example`
- Status: `done`
- Validity: valid as documentation/UX.

Plan:

- Add comments near `app_node_plan`, `testing_node_plan`, and `postgres_plan`
  explaining that these are cost-impacting SKUs.
- Prefer not to remove defaults completely because the runbook and rendered env
  flow rely on a known thesis baseline. Instead, make the cost warning explicit
  and keep `make vultr-preflight-check` / docs as the operator confirmation path.
- Mirror warning in `docs/infrastructure/vultr-configuration-reference.md` if
  not already explicit enough.

Implementation:

- Added cost-impacting SKU comments to both Vultr tfvars examples.
- Added runbook/configuration reference cost guardrails.
- Commit: `9b220e7`

Validation:

- `terraform fmt -check -recursive infra/terraform/vultr-experiment-sequential`

Draft quote reply:

```text
> Add explicit cost guardrails for default instance plans.

Addressed by documenting the cost-impacting Vultr plan variables in the tfvars example and configuration reference while preserving the thesis baseline defaults.
```

### R10 - Parallel stack should maybe make both clusters conditional

- Source: CodeRabbit nitpick in review summary.
- File: `infra/terraform/vultr-experiment/main.tf`
- Status: `done`
- Validity: partially valid, but the suggested implementation may be harmful
  for this thesis workflow.

Analysis:

- The cost warning is valid: the parallel stack intentionally provisions two
  high-vCPU VKE clusters at the same time.
- The suggestion to make `monolith_cluster` and `msa_cluster` conditional is
  not ideal as a default fix because the parallel stack's purpose is same
  wall-clock execution for aligned Datadog windows.
- Adding optional `count` to modules would complicate outputs and downstream
  scripts (`vultr-setup-contexts-parallel`, secret creation, benchmark suite)
  and could introduce silent single-cluster partial state unless every caller is
  hardened too.

Recommended resolution:

- Do not add conditional modules by default.
- Add explicit cost-warning documentation to:
  - `docs/infrastructure/vultr-vke-runbook.md`
  - `docs/infrastructure/vultr-configuration-reference.md`
  - maybe `infra/terraform/vultr-experiment/terraform.tfvars.example`
- Keep sequential stack as the supported one-cluster fallback.

Implementation:

- Documented the decision not to make parallel modules conditional.
- Clarified that sequential stack is the supported lower-cost/quota fallback.
- Commit: `9b220e7`

Validation:

- Docs only unless we decide to add a hard confirmation variable later.

Draft quote reply:

```text
> Cost note: this stack stands up two heavy clusters simultaneously.

Acknowledged. The parallel Vultr stack intentionally creates both architecture clusters for same-window benchmark comparison, while the sequential stack is the supported lower-cost fallback. I added explicit cost guardrail documentation rather than making the parallel modules conditional, because conditional modules would complicate outputs and risk accidental partial benchmark topology.
```

### R11 - `env-init-vultr` uses `bash -lc`

- Source: CodeRabbit nitpick in review summary.
- File: `scripts/env-init-vultr.sh`
- Status: `done`
- Validity: valid and trivial.
- Reviewer concern: `bash -lc` sources login shell files and can introduce
  operator-specific side effects.

Plan:

- Change `bash -lc` to `bash -c` in `read_env_value`.

Implementation:

- Replaced login shell invocation with non-login `bash -c`.
- Commit: `4b46a7f`

Validation:

- `bash -n scripts/env-init-vultr.sh`
- Smoke: rerun `make env-init-vultr` only if safe, or inspect function behavior
  with a temp env file.

Draft quote reply:

```text
> Remove the `-l` login shell flag from the bash invocation.

Addressed by switching `read_env_value` from `bash -lc` to `bash -c`, avoiding login-shell profile side effects.
```

## Validation Plan After Fixes

Minimum validation after all accepted review fixes:

```bash
bash -n \
  scripts/env-init-vultr.sh \
  scripts/create-vultr-secrets-monolith.sh \
  scripts/create-vultr-secrets-microservices.sh \
  scripts/create-vultr-secrets-sequential.sh \
  scripts/lib/cloud-provider.sh \
  scripts/measure-vultr-resource-baseline.sh \
  scripts/setup-vultr-contexts.sh \
  scripts/terraform-vultr.sh \
  scripts/render-vultr-tfvars.sh

terraform fmt -check -recursive \
  infra/terraform/vultr-shared \
  infra/terraform/vultr-experiment \
  infra/terraform/vultr-experiment-sequential \
  infra/terraform/modules/vultr-vke-benchmark-cluster

terraform -chdir=infra/terraform/vultr-shared validate
terraform -chdir=infra/terraform/vultr-experiment validate
terraform -chdir=infra/terraform/vultr-experiment-sequential validate

git diff --check
```

Executed validation:

```bash
bash -n scripts/create-vultr-secrets-monolith.sh scripts/create-vultr-secrets-microservices.sh scripts/create-vultr-secrets-sequential.sh scripts/render-vultr-tfvars.sh scripts/terraform-vultr.sh
bash -n scripts/lib/cloud-provider.sh scripts/measure-vultr-resource-baseline.sh scripts/setup-vultr-contexts.sh scripts/env-init-vultr.sh
terraform fmt -check -recursive infra/terraform/modules/vultr-vke-benchmark-cluster
terraform fmt -check -recursive infra/terraform/vultr-experiment infra/terraform/vultr-experiment-sequential
terraform -chdir=infra/terraform/vultr-experiment validate
terraform -chdir=infra/terraform/vultr-experiment-sequential validate
TF_VAR_postgres_password=0123456789abcdef terraform -chdir=infra/terraform/vultr-experiment validate
TF_VAR_postgres_password=0123456789abcdef terraform -chdir=infra/terraform/vultr-experiment-sequential validate
git diff --check
```

Optional smoke validations:

```bash
CLOUD_PROVIDER=vultr VULTR_MONOLITH_CLUSTER_NAME='cluster-%s' \
  bash -c 'source scripts/lib/cloud-provider.sh; provider_default_cluster_name monolith'

tmp_env="$(mktemp -d)/baseline.env"
tmp_json="$(mktemp -d)/nested/baseline.json"
VULTR_RESOURCE_BASELINE_ENV="$tmp_env" VULTR_RESOURCE_BASELINE_JSON="$tmp_json" \
  bash -n scripts/measure-vultr-resource-baseline.sh
```

## Working Notes

- Keep review fixes traceable. Prefer one commit for P0/P1 security/fail-fast
  fixes and one commit for P2/P3 hardening/docs if batching is acceptable.
- Do not reply to review threads until fixes are pushed and the user asks for
  quote replies.
- Do not resolve threads unless explicitly requested.
