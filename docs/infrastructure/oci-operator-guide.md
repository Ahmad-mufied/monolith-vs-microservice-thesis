# Oracle Cloud Infrastructure (OCI / OKE) Operator Guide — Complete Operational Manual

## 1. Overview & Scope

This document is the **complete operational manual** for provisioning, configuring, executing, verifying, and tearing down thesis benchmark experiments on **Oracle Cloud Infrastructure (OCI)** using Oracle Container Engine for Kubernetes (OKE).

OCI is supported as a first-class cloud platform alongside AWS EKS and Vultr VKE. Just like Vultr, OCI uses unified top-level operator commands (`make experiment-bootstrap` and `make run-benchmark-suite`), abstracting provider-specific details behind `scripts/operator-dispatch.sh`.

---

## 2. Prerequisites & Environment Tooling

Before executing benchmark operations on OCI, ensure the following local tools are installed and accessible in `$PATH`:

| Tool | Minimum Version | Required For |
|---|---|---|
| `oci-cli` | `3.30.0` | Managing OCI tenancy & OKE kubeconfig credentials |
| `terraform` | `>= 1.6.0` | Provisioning OCI VCN, OKE cluster, node pools, and PostgreSQL VM |
| `kubectl` | `v1.35.0` | Interacting with Kubernetes clusters and inspecting pod logs |
| `helm` | `v3.12.0` | Deploying Datadog Agent DaemonSet |
| `make` | `4.3` | Dispatching benchmark targets via `Makefile` |
| `git` | `2.40.0` | Pinning `IMAGE_TAG` and tracking codebase revisions |

---

## 3. Environment Profile & Configuration Setup

### Step 1: Initialize Operator Profile

Set the active cloud platform and execution mode to `oci` and `sequential`:

```bash
make env-init PLATFORM=oci EXECUTION_MODE=sequential
```

Verify that the active profile environment matches:

```bash
make profile-show
```

Expected Output:

```text
=== Active Operator Profile ===
  PLATFORM              : oci
  CLOUD_PROVIDER        : oci
  EXECUTION_MODE        : sequential
  SEQUENTIAL_CONTEXT    : monolith
```

> [!WARNING]
> **Security & Credentials Safety Rules**:
> 1. **Never Commit Secret Files**: `env/oci.env`, `infra/terraform/oci/terraform.tfvars`, and `kubeconfig` are ignored by `.gitignore`. Never remove them from `.gitignore` or commit secret files to Git repositories.
> 2. **Runtime Environment Injection**: In automated CI/CD pipelines or secure execution environments, supply sensitive values dynamically via environment variables (e.g., `export TF_VAR_db_password="..."`, `export POSTGRES_PASSWORD="..."`) instead of persisting plaintext credentials to disk.
> 3. **Avoid Shell History Leakage**: When creating Kubernetes secrets via CLI, dereference active environment variables (e.g., `--from-literal=api-key="${DATADOG_API_KEY}"`) or run commands with a leading space to prevent recording passwords in shell history (`.bash_history`).

### Step 2: Configure OCI Environment Variables (`env/oci.env`)

Create or update `env/oci.env` with your AWS S3 writer credentials, Datadog API parameters, and Docker Hub namespace:

```bash
# Cloud Target Settings
CLOUD_PROVIDER="oci"
PLATFORM="oci"
EXECUTION_MODE="sequential"
SEQUENTIAL_CONTEXT="monolith"
OCI_REGION="ap-kulai-2"
OCI_COMPARTMENT_OCID="ocid1.compartment.oc1..your_compartment_ocid"

# Container Registry
DOCKERHUB_NAMESPACE="ahmadmufied"

# PostgreSQL Database Master Password
POSTGRES_PASSWORD="YourSecurePassword123!"

# AWS S3 Result Storage Credentials
AWS_ACCESS_KEY_ID="your_aws_access_key_id"
AWS_SECRET_ACCESS_KEY="your_aws_secret_access_key"
AWS_REGION="ap-southeast-1"
S3_BUCKET="skripsi-benchmark-results"

# Datadog Observability Configuration
DATADOG_ENABLED=true
DATADOG_API_KEY="your_datadog_api_key"
DATADOG_SITE="us5.datadoghq.com"
DATADOG_ENV="benchmark"
```

### Step 3: Configure Terraform Parameters (`infra/terraform/oci/terraform.tfvars`)

Copy `infra/terraform/oci/terraform.tfvars.example` to `infra/terraform/oci/terraform.tfvars` and set target values (or pass `db_password` securely via `export TF_VAR_db_password="${POSTGRES_PASSWORD}"`):

```hcl
region          = "ap-kulai-2"
compartment_id  = "ocid1.compartment.oc1..your_compartment_ocid"
execution_mode  = "sequential"
node_shape      = "VM.Standard.E5.Flex"
app_ocpu_count  = 4
db_ocpu_count   = 2
test_ocpu_count = 1
db_password     = "YourSecurePassword123!"
ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... operator@laptop"
```

---

## 4. Standard Unified Operator Workflow (Recommended)

Just like Vultr, OCI benchmark execution requires **only two primary commands** for full end-to-end operation:

```bash
# Step 1: Single-Command Infrastructure Bootstrap
make experiment-bootstrap

# Step 2: Single-Command Benchmark Suite Execution
make run-benchmark-suite SCALING_MODE=fixed
```

### What `make experiment-bootstrap` Does Automatically:
1. `experiment-plan`: Runs Terraform plan for OCI stack.
2. `experiment-apply`: Applies Terraform to provision VCN, OKE cluster (`skripsi-oci-sequential`), and PostgreSQL VM (`10.0.4.206`).
3. `setup-contexts`: Downloads OKE kubeconfig and maps context `monolith`.
4. `create-secrets`: Generates `mono` and `msa` secrets, configmaps, and gRPC endpoints (`50051-50053`).
5. `measure-resource-baseline`: Measures live allocatable hardware capacity from OKE worker nodes (`7800m` CPU / `15000Mi` RAM).
6. `render-manifests`: Dynamically renders Kubernetes deployment manifests based on live allocatable capacity.

### What `make run-benchmark-suite SCALING_MODE=fixed` Does Automatically:
1. Runs preflight checks (validating S3 auth, K8s context, image tags).
2. Deploys Phase 1 (Monolith): Dynamically relabels app node (`architecture=monolith`), runs DB bootstrap/migrations/seeding, rolls out `monolith` pod, and runs 21 k6 test cases.
3. Deploys Phase 2 (Microservices): Dynamically relabels app node (`architecture=msa`), runs MSA DB migrations/seeding, rolls out `api-gateway`, `auth-service`, `item-service`, `transaction-service` pods, and runs 21 k6 test cases.
4. Emits metrics & traces to Datadog SaaS and uploads complete result bundles (`summary.json`, `raw.json.gz`, `metadata.json`) to AWS S3.

---

## 5. Granular Provider-Specific Commands (Low-Level / Debugging)

If you prefer to run individual steps manually during development or debugging:

### 5.1 Plan & Apply Infrastructure
```bash
make oci-plan
make oci-apply
```

### 5.2 Contexts & Secrets Management
```bash
make oci-setup-context-sequential
make oci-create-secrets
```

### 5.3 Image Tag Pinning
```bash
make show-image-tag
make pin-image-tag IMAGE_TAG=f57e999
```

---

## 6. Datadog Observability Agent Deployment

To collect APM traces, latency metrics, and system metrics during load tests, deploy the Datadog Agent DaemonSet.

### 6.1 Install/Upgrade Datadog Agent via Helm

```bash
# Add Helm repository
helm repo add datadog https://helm.datadoghq.com
helm repo update

# Create namespace and API key secret
kubectl --context=monolith create namespace datadog --dry-run=client -o yaml | kubectl --context=monolith apply -f -
kubectl --context=monolith create secret generic datadog-secret \
  --namespace datadog \
  --from-literal=api-key="${DATADOG_API_KEY}" \
  --dry-run=client -o yaml | kubectl --context=monolith apply -f -

# Deploy Datadog Agent DaemonSet (Chart version 3.134.0)
helm upgrade --install datadog datadog/datadog \
  --version 3.134.0 \
  --namespace datadog \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  --set datadog.site=us5.datadoghq.com \
  --set datadog.apm.portEnabled=true \
  --set datadog.dogstatsd.useHostPort=true \
  --kube-context=monolith
```

### 6.2 Verify Datadog DaemonSet Rollout

```bash
kubectl --context=monolith rollout status daemonset/datadog -n datadog
```

Expected Output:
```text
daemon set "datadog" successfully rolled out
```

---

## 7. Running Preflight Checks & Sanity Smoke Tests

Before starting long-running benchmark suites, execute a 1-minute smoke test for both architectures to verify database migrations, pod readiness, telemetry, and S3 result uploads.

### 7.1 Monolith Architecture Smoke Test

```bash
PATH=$HOME/bin:$PATH \
DATADOG_ENABLED=true \
ARCHITECTURE=monolith \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=oci-smoke-login-dd \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
make run-benchmark-case
```

### 7.2 Microservices Architecture Smoke Test

```bash
PATH=$HOME/bin:$PATH \
DATADOG_ENABLED=true \
ARCHITECTURE=microservices \
SCENARIO=login \
TARGET_RPS=100 \
RUN_ID=oci-smoke-login-msa-dd \
ATTEMPT=attempt-01 \
SCALING_MODE=fixed \
K6_PROFILE=smoke \
TEST_DURATION=1m \
make run-benchmark-case
```

---

## 8. S3 Artifact Verification & Data Validation

Verify uploaded experiment data using AWS CLI:

```bash
aws s3 ls s3://skripsi-benchmark-results/experiments/oci-sequential-fixed-oci-fixed-suite-f57e999/
```

Required files per attempt directory:
- `summary.json`
- `raw.json.gz`
- `metadata.json`
- `thresholds.json`
- `datadog-time-window.json`
- `stdout.log`
- `result-status.json`

---

## 9. Guarded Infrastructure Teardown

To prevent accidental data loss, teardown requires verification that benchmark data exists in S3.

Execute guarded destroy command:

```bash
make experiment-destroy-confirmed
```

---

## 10. Troubleshooting & Diagnostic Reference

### Issue 1: Application Pods Stuck in `Pending`
- **Symptom**: `kubectl get pods -n mono` shows status `Pending`.
- **Cause**: Node selector mismatch (`nodeSelector: architecture: monolith` vs node label `architecture=sequential`).
- **Fix**: Manually apply label to the app worker node or let `make run-benchmark-suite` do it automatically:
  ```bash
  kubectl label nodes -l node-group=app architecture=monolith --overwrite
  ```

### Issue 2: Microservices Crash with `AUTH_SERVICE_ADDR is required`
- **Symptom**: `api-gateway` pod crashes in `CrashLoopBackOff`.
- **Cause**: Legacy secret script populated `AUTH_SERVICE_GRPC_URL` instead of `AUTH_SERVICE_ADDR`.
- **Fix**: Re-run updated secret generator:
  ```bash
  make create-secrets
  ```

### Issue 3: Microservices gRPC Connection Refused (Port Mismatch)
- **Symptom**: `api-gateway` logs indicate connection refused to `auth-service:9081`.
- **Cause**: gRPC ports set to local host ports (`9081`) instead of K8s container ports (`50051`).
- **Fix**: Verify secrets use `50051`, `50052`, `50053`:
  ```bash
  kubectl get secret api-gateway-secret -n msa -o yaml
  ```

### Issue 4: k6 Upload to S3 Fails
- **Symptom**: Log reports `upload failed` or `AWS_ACCESS_KEY_ID not set`.
- **Cause**: Environment variables missing S3 keys.
- **Fix**: Ensure `S3_BUCKET`, `AWS_ACCESS_KEY_ID`, and `AWS_SECRET_ACCESS_KEY` are exported in `env/oci.env`.
