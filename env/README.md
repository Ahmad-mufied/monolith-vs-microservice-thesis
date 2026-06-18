# Local Environment Files

This directory stores environment configuration templates and generated environment files. 

Under the centralized configuration model, **`env/values.yaml`** (copied from `env/values.yaml.template` during initialization) serves as the **single source of truth** for all environment configuration parameters across all deployable workloads (monolith, api-gateway, auth-service, item-service, transaction-service) and all execution runtimes (local host `go run`, Docker Compose, and Kubernetes EKS/Vultr clusters).

## Centralized Configuration (values.yaml)

To customize configurations, you edit `env/values.yaml` instead of editing individual flat `.env` files. The repository initialization scripts parse the values from `env/values.yaml` using `yq` and dynamically generate the required flat `.env` files for tool and runtime compatibility.

> [!WARNING]
> Do not modify the generated flat `*.env` files directly! Any manual changes will be overwritten on the next execution of `make env-init` or any profile-specific `make env-init-*` target. Always update `env/values.yaml` instead.

### Initialization Workflow

1. **Initialize Base Local DB Environment:**
   ```bash
   make env-init-base
   ```
   Generates `postgres.env` to configure the shared local PostgreSQL database.

2. **Initialize App Environment (YAML to Flat Envs):**
   ```bash
   make env-init-app
   ```
   Parses `env/values.yaml` and generates the provider-neutral app env files:
   - `datadog.shared.env` (from `.shared.datadog`)
   - `k6-runner.app.env` (from `.shared.k6-runner`)
   - `monolith.app.env` (from `.cluster.monolith`)
   - `api-gateway.app.env`, `auth-service.app.env`, `item-service.app.env`, `transaction-service.app.env` (from `.cluster.microservices.*`)

3. **Initialize Local Monolith Environment:**
   ```bash
   make env-init-monolith
   ```
   Generates local monolith environment files (`monolith.env` from `.local.monolith`) and bootstrap configs (`db-bootstrap.env`).

4. **Initialize Local Microservices Environment:**
   ```bash
   make env-init-microservices
   ```
   Generates local host `go run` environment files (`api-gateway.env`, etc. from `.local.microservices.*`) and Docker Compose environment files (`api-gateway.compose.env`, etc. from `.compose.microservices.*`).

5. **Initialize Cloud Provider Benchmark Environments:**
   - **AWS EKS:** Run `make env-init-eks` to create AWS-specific benchmark helpers (`aws-benchmark.env`, `terraform.shared.env`, `terraform.experiment.env`).
   - **Vultr:** Run `make env-init-vultr` to create Vultr operator configurations.

6. **Unified Profile Configuration (All-in-One):**
   ```bash
   make env-init PLATFORM=<eks|vultr> EXECUTION_MODE=<parallel|sequential>
   ```
   Coordinatively runs base, app, and cloud-provider initializations, then writes the `env/operator-profile.env` profile.

### Generated files (Ignored by Git):
The following files contain local settings, passwords, or secrets and are excluded from Git:
- `postgres.env`
- `datadog.minikube.env`
- `aws-benchmark.env`
- `terraform.shared.env`
- `terraform.experiment.env`
- `datadog.shared.env`
- `monolith.app.env`
- `api-gateway.app.env`
- `auth-service.app.env`
- `item-service.app.env`
- `transaction-service.app.env`
- `k6-runner.app.env`
- `api-gateway.env`, `auth-service.env`, `item-service.env`, `transaction-service.env`
- `api-gateway.compose.env`, `auth-service.compose.env`, `item-service.compose.env`, `transaction-service.compose.env`

---

## Key Configurations in values.yaml

### 1. Application Debugging
- `DIAGNOSTIC_LOGGING_ENABLED` (boolean): When set to `true` under the respective YAML profile block, deployable applications emit structured, failure-only debug events that correlate with Datadog traces.

### 2. Login Admission Control
- `LOGIN_ADMISSION_ENABLED` (boolean): Controls whether the login concurrency limiter is active.
- `LOGIN_MAX_CONCURRENCY` (integer): Maximum login slots for monolith or microservices under fixed scaling.
- `LOGIN_MAX_CONCURRENCY_HPA` (integer): Concurrency limit override when deploying under Horizontal Pod Autoscaling (HPA) mode.

`make env-init-eks` creates AWS benchmark helper env files:

- `aws-benchmark.env`
- `terraform.shared.env`
- `terraform.experiment.env`

`aws-benchmark.env` stores shared benchmark and AWS helper values such as
`AWS_REGION`, `S3_BUCKET`, and `ECR_NAMESPACE`.

`datadog.shared.env` stores shared Datadog values, including:

- `DATADOG_API_KEY`
- `DATADOG_SITE`

Optional file:

- `image-tag.env`

When present, `image-tag.env` pins the default deployment `IMAGE_TAG` for Make
targets and deploy scripts. This is useful when you want to keep deploying an
existing image tag across unrelated local commits.

`k6-runner.app.env` stores the benchmark admin credentials used by the k6
runner secret during benchmark setup.

- `ADMIN_USER_EMAIL` defaults to `benchmark-user-001@example.com`
- `ADMIN_USER_PASSWORD` is generated automatically as a strong random hex value
- if an existing legacy `k6-runner.eks.env` still contains the old weak value
  `Password123!`, `make env-init-app` migrates it into the neutral file and
  preserves the benchmark default password expected by the current repo flow

`terraform.experiment.env` also stores the EKS version policy and the operator
CIDR allowlist used to restrict the public EKS Kubernetes API endpoint.

- `CLUSTER_VERSION` defaults to `1.34`; re-check the live AWS EKS version
  lifecycle table before final measured runs and update this value when the
  default is no longer in Standard Support
- `CLUSTER_SUPPORT_TYPE` defaults to `STANDARD` so new benchmark clusters do
  not silently stay in paid EKS Extended Support
- `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE` defaults to `auto` for the
  generated helper flow
- when the source is `auto`, `make env-init-eks` attempts to detect the current
  public operator IP and writes it as
  `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS=<detected-ip>/32`
- this should be the public egress IP range that AWS sees for your laptop or
  network; for a single operator laptop this is usually a `/32`
- if the autodetect helper receives a malformed non-IP response, it now fails
  without writing a CIDR value so you can retry or set the value manually
- if your public IP changes later and the source remains `auto`,
  `make env-init-eks` refreshes the CIDR automatically
- you may provide multiple CIDRs as a comma-separated list if more than one
  operator/network must reach the public EKS API endpoint
- if you want to keep a custom static or multi-CIDR value, set
  `CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS_SOURCE=manual`; `make env-init-eks`
  will then preserve your configured CIDR list
- `make eks-render-tfvars` rejects placeholders and world-open values such as
  `0.0.0.0/0`

These files are intended to make EKS setup repeatable:

- `make eks-render-tfvars` renders Terraform `terraform.tfvars` from the
  `env/terraform.*.env` files without writing `DB_PASSWORD` into
  `infra/terraform/aws-parallel/terraform.tfvars`
- rendered experiment tfvars include `cluster_version` and
  `cluster_support_type` for both parallel and sequential stacks
- `bash scripts/terraform-aws-parallel.sh ...` and the Makefile Terraform targets
  source `env/terraform.experiment.env` and inject `TF_VAR_db_password` at
  runtime for the experiment stack
- `make create-eks-secrets-monolith` creates monolith cluster secrets from the
  neutral app env files plus EKS Terraform env files
- `make create-eks-secrets-microservices` creates microservices cluster
  secrets from the neutral app env files plus EKS Terraform env files

Legacy compatibility:

- the repo still accepts legacy files such as `monolith.eks.env`,
  `datadog.eks.env`, and `image-tag.eks.env` as fallback input
- when a neutral file such as `monolith.app.env` already exists, it becomes
  the source of truth
- the legacy file names are deprecated and should only remain as temporary
  compatibility helpers during migration

The non-compose microservices env files use `localhost` and are intended for
`go run` from the host.

The `*.compose.env` files use Docker Compose service names such as `postgres`,
`auth-service`, `item-service`, and `transaction-service`.
