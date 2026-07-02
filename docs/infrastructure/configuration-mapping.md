# Unified Configuration and Secret Mapping Guide

This document provides a comprehensive, end-to-end explanation of how the benchmark project manages configurations, environment files, and credentials, mapping them to Kubernetes resources. 

---

## 1. The Two Configuration Paradigms

The project separates configuration into two distinct layers based on their lifecycles and scopes:

```text
+-----------------------------------------------------------------------------------+
| 1. INFRASTRUCTURE & RESOURCE CONTROL (.env & .json)                               |
|    - Defines physical cluster topology, region, and Measured Resource baseline.   |
|    - Sourced by rendering scripts to hardcode ResourceQuota limits in manifests.  |
+-----------------------------------------------------------------------------------+
| 2. APPLICATION CONFIGURATION & CREDENTIALS (values.yaml)                           |
|    - Defines database connection parameters, security tokens, timeouts, etc.      |
|    - Sourced at deploy time to dynamically build ConfigMaps & Secrets.            |
+-----------------------------------------------------------------------------------+
```

---

## 2. Infrastructure & Resource Lifecycle (.env)

Infrastructure variables define the physical parameters of the cluster. These files are typically loaded as environment variables in bash during deployment and run steps.

### 2.1 File Inventory
*   **`env/vultr.env`:** Contains static variables for the cloud provider setup (e.g., `VULTR_REGION=mia`, `DOCKERHUB_NAMESPACE`).
*   **`env/vultr-resource-baseline.env` & `env/vultr-resource-baseline.json`:** Dynamically generated files containing measured allocatable resources and rounded safety margins (e.g., `VULTR_APP_CPU_QUOTA=7800m`, `VULTR_APP_MEMORY_QUOTA=15360Mi`).

### 2.2 Execution Flow
```text
[VKE Cluster Up] 
       │
       ▼
[measure-vultr-resource-baseline.sh] ──> Queries K8s Allocatable ──> Writes env/vultr-resource-baseline.env
       │
       ▼
[render-vultr-manifests.sh] ──> Reads VULTR_APP_CPU_QUOTA ──> Overwrites resourcequota.yaml limits
```

---

## 3. Application Configuration Pipeline (values.yaml)

Application settings are managed in a centralized, hierarchical YAML format. This structure provides a clean way to manage settings across different execution profiles (`local`, `compose`, `cluster`, `shared`).

### 3.1 Pipeline Flow Diagram

```text
+-------------------------------------------------------------------------------+
|                       env/values.yaml.template (Git Tracked)                 |
|                       - Blueprint with placeholders (e.g. JWT, DB Passwords)  |
+--------------------------------------┬----------------------------------------+
                                       │
                                       ▼ (env-init-app.sh replaces placeholders)
+--------------------------------------┴----------------------------------------+
|                          env/values.yaml (Git Ignored)                        |
|                       - Actual configs & generated passwords/secrets          |
+--------------------------------------┬----------------------------------------+
                                       │
                                       ▼ (create-vultr-secrets-*.sh uses shared-env.sh)
                    ┌──────────────────┴──────────────────┐
                    │ (is_sensitive_key check)            │
                    ▼ (Non-Sensitive)                     ▼ (Sensitive)
        ┌───────────┴───────────┐             ┌───────────┴───────────┐
        │ Kubernetes ConfigMap  │             │   Kubernetes Secret   │
        │ (e.g. auth-config)    │             │   (e.g. auth-secret)  │
        └───────────┬───────────┘             └───────────┬───────────┘
                    │                                     │
                    └──────────────────┬──────────────────┘
                                       ▼ (envFrom injection)
                        ┌──────────────┴──────────────┐
                        │      Workload Pods          │
                        │   - auth-service, etc.      │
                        └─────────────────────────────┘
```

### 3.2 Step-by-Step Walkthrough

1.  **Template Sourcing:** `env/values.yaml.template` contains the structural skeleton of all configurations, with placeholders like `PLACEHOLDER_JWT_SECRET` and `PLACEHOLDER_POSTGRES_PASSWORD`.
2.  **Secret Initalization:** When running `make env-init`, the script [env-init-app.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/scripts/env-init-app.sh) is triggered. It generates random cryptographic keys and database passwords, replaces the placeholders, and saves the file as `env/values.yaml`.
3.  **Partitioning (Sensivity Split):** When you deploy, the deployment scripts invoke the secret-creation scripts (e.g., `create-vultr-secrets-microservices.sh`). These scripts leverage helper functions in [shared-env.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/scripts/lib/shared-env.sh):
    *   **`is_sensitive_key` predicate:** Uses pattern matching (`*SECRET*`, `*PASSWORD*`, `*DATABASE_URL*`, `*API_KEY*`, `*TOKEN*`) to check if a configuration parameter is sensitive.
    *   **Non-sensitive variables** are written to a temporary config file and created in K8s as a **ConfigMap** (e.g., `auth-service-config`).
    *   **Sensitive variables** are written to a temporary secret file and created in K8s as a **Secret** (e.g., `auth-service-secret`).
4.  **Consuming in Manifests:** Workload manifests (like `auth-service.yaml`) load these ConfigMaps and Secrets collectively via `envFrom`. When a pod launches, Kubernetes injects all keys as active environment variables into the container environment.

---

## 4. Relationship with Secret Management Policy

It is common to confuse this guide with **[secret-management.md](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/docs/infrastructure/secret-management.md)**. The table below clarifies how they relate and work together:

| Aspect | [configuration-mapping.md](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/docs/infrastructure/configuration-mapping.md) (This File) | [secret-management.md](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/docs/infrastructure/secret-management.md) |
| :--- | :--- | :--- |
| **Primary Scope** | **Mechanical Configuration Flow** (The "How"). | **Security Architecture & Rules** (The "Why"). |
| **Focal Point** | Sourcing inputs, script execution orders, rendering pipelines, and file boundaries. | Security compliance rules, encryption policies, credentials checklists, and reasons for avoiding external secret providers. |
| **Key Questions Answered** | * How do I change a variable? <br> * Which script overrides what? <br> * Where do my parameters end up? | * Why do we separate secrets from configs? <br> * What is our password policy? <br> * What checklist must be done before pushing to Git? |

### 4.1 Joint Enforcement: Config Rollout Checksum
Both policies intersect at the rollout stage. To ensure that updating a variable in `values.yaml` (regardless of whether it's stored in a ConfigMap or a Secret) triggers a rollout, the deployment script calculates a SHA256 checksum:
1. It queries the data contents of both the generated ConfigMap and Secret.
2. It concatenates the sorted key-value pairs and generates a SHA256 signature.
3. It annotates the Deployment metadata with this signature: `benchmark.skripsi.dev/config-checksum`.
4. Kubernetes detects the changed annotation and triggers a zero-downtime rolling update.

---

## 5. Code-Level Tracing: Script Execution Alur

To trace this implementation in the codebase, follow this script execution path:

1.  **Orchestrator Start:** Skrip [run-benchmark-suite-sequential.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/scripts/run-benchmark-suite-sequential.sh#L908-L914) calls:
    ```bash
    sync_runtime_secrets() {
      PLATFORM="$PLATFORM" \
      EXECUTION_MODE=sequential \
      SCALING_MODE="$SCALING_MODE" \
      CLOUD_PROVIDER="$CLOUD_PROVIDER" \
      bash scripts/operator-dispatch.sh create-secrets
    }
    ```
2.  **Dispatch:** [operator-dispatch.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/scripts/operator-dispatch.sh) runs:
    *   `create-vultr-secrets-monolith.sh` (for Monolith phase).
    *   `create-vultr-secrets-microservices.sh` (for Microservices phase).
3.  **Parsing & Generation:** The secret scripts source [shared-env.sh](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/scripts/lib/shared-env.sh#L619-L650) to divide `env/values.yaml` profiles into ConfigMaps and Secrets:
    *   Non-sensitive data goes to `auth-service-config` (ConfigMap).
    *   Sensitive data goes to `auth-service-secret` (Secret).
4.  **Deployment Verification:** The deployer applies the rendered manifests, which refer to those ConfigMaps and Secrets by name, injecting the parameters directly into the Go processes.

---

## 6. Manifest Compile Boundaries (Dynamic Overrides vs. Static Assets)

To avoid manual edits being lost during compiler execution, the table below defines which resource settings are dynamically computed/overwritten by skrips, and which settings can be modified directly in the source manifests:

| Configuration Attribute | Controlled / Overwritten By | Direct Source Edit Allowed? | Actionable Guidance / Notes |
| :--- | :--- | :---: | :--- |
| **Container Images & Tags** | `render-vultr-manifests.sh` | **No** | Overwritten using `DOCKERHUB_NAMESPACE` and `IMAGE_TAG`. |
| **Namespace ResourceQuota** | `render-vultr-manifests.sh` | **No** | Injected from `VULTR_APP_CPU_QUOTA` and `VULTR_APP_MEMORY_QUOTA`. |
| **Pod CPU/Memory limits** | `render-vultr-manifests.sh` | **No** | Dynamically computed and patched via `set_container_resources`. |
| **HPA min/max replicas** | `render-vultr-manifests.sh` | **No** | Overwritten to `min: 1` and `max: 5` via `set_hpa_replicas`. |
| **App-level Environment Variables** | `values.yaml` $\rightarrow$ Secret scripts | **No** | Partitioned into ConfigMap/Secret. Edit `env/values.yaml` to modify. |
| **Container Ports & Services** | *None (Static)* | **Yes** | Edit directly under `ports` or `Service` kind in source manifests. |
| **Liveness / Readiness Probes** | *None (Static)* | **Yes** | Edit directly under `livenessProbe` / `readinessProbe` in source manifests. |
| **Security Contexts** | *None (Static)* | **Yes** | Edit directly under `securityContext` in source manifests. |
| **Deployment Rollout Strategy** | *None (Static)* | **Yes** | Edit directly under `spec.strategy` (e.g., Recreate vs. RollingUpdate). |

---

## 7. Concrete Manifest Rendering Case Study

To trace exactly how these modifications occur in YAML files under the hood, here is a comparative example of the `auth-service` workload before and after compilation in Vultr VKE Sequential mode.

### 7.1 Before Rendering (Source Files in `deployments/k8s/cloud/`)

**Base Manifest: `base/auth-service.yaml`**
```yaml
# Note the image placeholder and unpatched datadog tag
spec:
  containers:
    - name: auth-service
      image: REPLACE_WITH_AUTH_SERVICE_ECR_IMAGE
      envFrom:
        - configMapRef:
            name: auth-service-config
        - secretRef:
            name: auth-service-secret
```

**Fixed Overlay Patch: `overlays/fixed/auth-service-patch.yaml`**
```yaml
# Note the static placeholder resources
spec:
  containers:
    - name: auth-service
      resources:
        requests:
          cpu: 980m
          memory: 1920Mi
        limits:
          cpu: 1950m
          memory: 3840Mi
```

---

### 7.2 Compiler Action (Script Interpolation)

When running the compiler, `render-vultr-manifests.sh` executes the following `perl` regex functions on a temporary copy of the manifests (`OUTPUT_DIR`):

1.  **Overwriting Registry Placeholders (`patch_kustomize_image`):**
    The compiler detects the active `CLOUD_PROVIDER` profile to determine the destination registry for the static `REPLACE_WITH_*_ECR_IMAGE` placeholders:
    *   **AWS EKS Profile:** Resolves to **AWS ECR** (e.g., `<aws_account_id>.dkr.ecr.ap-southeast-1.amazonaws.com/skripsi/auth-service:tag`).
    *   **Vultr VKE Profile:** Resolves to **Docker Hub** (e.g., `docker.io/<namespace>/auth-service:tag`).
    For Vultr VKE, the placeholder `REPLACE_WITH_AUTH_SERVICE_ECR_IMAGE` is replaced with the Docker Hub reference: `docker.io/myusername/auth-service:mycommit`.
2.  **Resource Allocation Oversites (`patch_equal_split_resource_profile`):**
    Recalculates the resource bounds on the patch file based on `VULTR_APP_CPU_QUOTA=7800m`:
    *   CPU Limit = $7800\text{m} / 4 = 1950\text{m}$
    *   CPU Request = $1950\text{m} / 2 = 975\text{m}$ (The script overwrites the template's `980m` to maintain exactly 50% symmetry).


---

### 7.3 After Rendering (Final Output Applied to Kubernetes Cluster)

The generated YAML that is actually pushed to VKE contains the fully-resolved, concrete parameters:

```yaml
# Resulting output applied to VKE
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: msa
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: auth-service
        tags.datadoghq.com/version: mycommit
    spec:
      containers:
        - name: auth-service
          image: docker.io/myusername/auth-service:mycommit
          envFrom:
            - configMapRef:
                name: auth-service-config
            - secretRef:
                name: auth-service-secret
          resources:
            requests:
              cpu: 975m
              memory: 1920Mi
            limits:
              cpu: 1950m
              memory: 3840Mi
```

---

## 8. Summary Checklist for Developers

If you want to modify the system configuration:

1.  **To change DB passwords, JWT secret, timeouts, or DB connection pools:**
    *   Edit [env/values.yaml](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/env/values.yaml) directly.
    *   Do **NOT** edit the manifests. Rerun `make vultr-deploy-all` or `make create-secrets` to apply.
2.  **To change Node sizes, CPU quotas, or Memory safety margins:**
    *   Re-measure the baseline, or edit [env/vultr-resource-baseline.env](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/env/vultr-resource-baseline.env).
3.  **To change Application Logic / Ports / Liveness probes:**
    *   Edit the raw manifests in `deployments/k8s/cloud/` directly.
