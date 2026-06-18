# CodeRabbit Review — PR #68 (Centralize Environment Configuration)

PR: `refactor: centralize environment configuration into values.yaml`
Reviewed: `2026-06-18`

## Findings Overview

We have audited and analyzed the CodeRabbit review comments for PR #68. All 8 comments are valid and represent improvements in parsing safety, robust variable falling back, and secret security.

### Priority Mapping

1. **CRITICAL** (Parser Failures / Silent Bugs):
   - Quoting hyphenated YAML path keys in yq expressions to avoid operator parsing issues (Affects 5 scripts).
   - Coercing non-string types (booleans, integers) to strings in `generate_env_from_yaml` (Affects `shared-env.sh`).
2. **MAJOR** (Security & Robustness):
   - Matching `*TOKEN*` patterns as sensitive variables to prevent leakage of credentials like `AUTH_TOKEN` (Affects `shared-env.sh` and docs).
   - Adding a parameter expansion fallback to `auth_login_max_concurrency_hpa` to avoid uninitialized variable bugs (Affects local microservices secret script).

---

## Actionable Findings Detail

### 1. Missing `*TOKEN*` Pattern Matching for Sensitive Keys

- **Severity**: Major (Security)
- **Files**:
  - [shared-env.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/lib/shared-env.sh) (around line 336)
  - [secret-management.md](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/docs/infrastructure/secret-management.md) (around line 138)
- **Status**: Valid — Fix Required
- **Issue**: The current classifier for sensitive variables in `is_sensitive_key` does not check for `*TOKEN*` patterns. This could cause token-based credentials (such as authentication or API tokens) to be categorized as non-sensitive and leak into plain-text ConfigMaps.
- **Fix**: Update the case match pattern in `is_sensitive_key()` to include `*TOKEN*`, and document this update in `secret-management.md`.

### 2. Quoting Hyphenated Keys in `yq` Expressions

- **Severity**: Critical (Parser Failure)
- **Files**:
  - [create-eks-secrets-monolith.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-eks-secrets-monolith.sh)
  - [create-eks-secrets-microservices.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-eks-secrets-microservices.sh)
  - [create-eks-secrets-sequential.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-eks-secrets-sequential.sh)
  - [create-vultr-secrets-monolith.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-vultr-secrets-monolith.sh)
  - [create-vultr-secrets-microservices.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-vultr-secrets-microservices.sh)
  - [create-local-secrets-microservices.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-local-secrets-microservices.sh)
- **Status**: Valid — Fix Required
- **Issue**: Unquoted path segments containing hyphens (e.g., `k6-runner`, `api-gateway`, `auth-service`, `item-service`, `transaction-service`) are interpreted by `yq` as math subtraction operators. This causes values to resolve to null or fail silently.
- **Fix**: Wrap all path segments containing hyphens in double quotes, e.g. `.cluster.microservices."api-gateway".JWT_SECRET` and `.shared."k6-runner".ADMIN_USER_EMAIL`.

### 3. Missing Fallback for `auth_login_max_concurrency_hpa`

- **Severity**: Major (Robustness)
- **File**: [create-local-secrets-microservices.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/create-local-secrets-microservices.sh) (around lines 60-61)
- **Status**: Valid — Fix Required
- **Issue**: Unlike other variables in the script, `auth_login_max_concurrency_hpa` does not have a default fallback assignment. If the YAML path doesn't yield a value and the environment variable is unset, the variable remains blank, which can result in parsing errors in dependent functions.
- **Fix**: Add a bash parameter expansion fallback to define a default value of `1` (symmetrical to the EKS configuration).

### 4. Non-String Concatenation Failure in `generate_env_from_yaml`

- **Severity**: Critical (Parser Failure)
- **File**: [shared-env.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/worktrees/refactor__centralize-environment-configuration-into-values-yaml/scripts/lib/shared-env.sh) (around line 60)
- **Status**: Valid — Fix Required
- **Issue**: The `yq` query `.key + "=" + .value` directly concatenates YAML values. If the value is a boolean or an integer, the query fails with a type error.
- **Fix**: Convert values to string using `.key + "=" + (.value | tostring)` in the `yq` expression.

---

## Resolution Plan & Status

| ID | Finding Summary | Severity | Status | Commit / PR Resolution |
|---|---|---|---|---|
| 1 | Add `*TOKEN*` matching for sensitive keys | Major | DONE | Fixed in `shared-env.sh` & documented in `secret-management.md` |
| 2 | Quote hyphenated keys in EKS/Vultr/Local scripts | Critical | DONE | Fixed in all 6 secret creation scripts |
| 3 | Add fallback for `auth_login_max_concurrency_hpa` | Major | DONE | Added fallback value in `create-local-secrets-microservices.sh` |
| 4 | Coerce YAML values to string in env generator | Critical | DONE | Coerced using `tostring` in `generate_env_from_yaml` |
