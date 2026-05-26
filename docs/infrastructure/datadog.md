# Datadog Observability

## 1. Purpose

This document describes the Datadog observability setup for the thesis benchmark
project.

Datadog is used to explain internal system behavior during benchmark execution.
It is not the primary source of external client-perceived performance numbers.

Primary benchmark result source:

```text
k6 summary and raw output
```

Datadog result role:

```text
internal observability and root-cause explanation
```

Datadog collects and correlates:

- Kubernetes node metrics,
- Kubernetes pod metrics,
- container logs,
- application traces,
- HTTP request traces,
- gRPC request traces,
- service latency,
- service throughput,
- service error rate,
- CPU usage,
- memory usage,
- replica count,
- HPA behavior,
- Datadog Agent health,
- real-time k6 metrics through DogStatsD.

The observability goal is to support the architecture comparison defined in:

```text
docs/architecture/overview.md
docs/architecture/monolith.md
docs/architecture/microservices.md
docs/architecture/comparison.md
```

Datadog should help answer questions such as:

- Which service is the bottleneck under a given workload?
- Does microservices latency come from gRPC hops, database work, or API Gateway work?
- Does HPA scale the expected Deployment?
- Did error rate increase because of application errors, resource pressure, or load generator limits?
- How do CPU and memory usage differ between monolith and microservices under equivalent ceilings?

Important benchmark interpretation rule:

```text
Monolith and microservices benchmark runs remain sequential, but Datadog may
still present both architectures together in a combined comparison dashboard
after those separate runs are completed.
```

## 2. Architecture Decision

Datadog Agent is installed with Helm.

The Helm chart deploys the Datadog Agent as a Kubernetes DaemonSet. This keeps
the runtime model aligned with the repository architecture guidance:

```text
Datadog runs as DaemonSet on monitored nodes.
```

Helm is preferred over hand-written DaemonSet manifests because:

- it follows Datadog's recommended Kubernetes installation path,
- it reduces manual YAML drift,
- it keeps Minikube and EKS installation similar,
- it allows environment-specific values files,
- it is easier to upgrade later.

Current values files:

| Environment | Values file |
|---|---|
| Minikube | `deployments/helm/datadog/values-minikube.yaml` |
| AWS EKS — monolith cluster | `deployments/helm/datadog/values-eks-monolith.yaml` |
| AWS EKS — MSA cluster | `deployments/helm/datadog/values-eks-msa.yaml` |

Current Makefile targets:

| Target | Purpose |
|---|---|
| `make datadog-secret` | Create the Kubernetes Secret used by the Datadog Helm chart |
| `make datadog-install-minikube` | Install or upgrade Datadog on Minikube |
| `make datadog-install-eks-monolith` | Install or upgrade Datadog on the monolith EKS cluster |
| `make datadog-install-eks-msa` | Install or upgrade Datadog on the MSA EKS cluster |
| `make datadog-status` | Inspect Datadog pods, services, DaemonSet, and Deployment |
| `make datadog-uninstall` | Remove the Datadog Helm release |

## 3. Repository Files

Datadog-related files:

```text
deployments/helm/datadog/values-minikube.yaml
deployments/helm/datadog/values-eks-monolith.yaml
deployments/helm/datadog/values-eks-msa.yaml
scripts/create-datadog-secret.sh
docs/infrastructure/datadog.md
docs/infrastructure/datadog-resource-overhead.md
```

Application manifests with Datadog tagging and runtime env:

```text
deployments/k8s/local/monolith/monolith.yaml
deployments/k8s/local/microservices/api-gateway.yaml
deployments/k8s/local/microservices/auth-service.yaml
deployments/k8s/local/microservices/item-service.yaml
deployments/k8s/local/microservices/transaction-service.yaml
```

This repository uses purpose-based Datadog environment naming:

- `development` for local and Minikube validation flows
- `benchmark` for measured EKS benchmark runs

Platform identity such as Minikube or EKS should be expressed through cluster
name, Kubernetes context, run metadata, and architecture tags, not by changing
the Datadog `env` meaning. EKS deployments must still override local image and
version defaults, but the Datadog environment purpose should remain
`development` locally and `benchmark` on EKS.

Important integration note for the separate EKS deployment path:

```text
These tracked Kubernetes manifests represent local/Minikube defaults.
When the EKS deployment path is integrated, deployment-specific overrides must
replace local-only image settings and Datadog runtime identity values,
especially:

- tags.datadoghq.com/env: development -> benchmark
- tags.datadoghq.com/version: local -> deployed image tag
- image: local repository tag -> ECR image
- imagePullPolicy: Never -> EKS-compatible pull policy
```

Application tracing code:

```text
monolith/internal/shared/observability/
pkg/observability/
monolith/cmd/server/main.go
microservices/api-gateway/internal/bootstrap/bootstrap.go
microservices/api-gateway/internal/router/router.go
microservices/auth-service/internal/bootstrap/bootstrap.go
microservices/item-service/internal/bootstrap/bootstrap.go
microservices/transaction-service/internal/bootstrap/bootstrap.go
```

k6 Datadog integration:

```text
k6/runner/Dockerfile
k6/runner/run-k6.sh
k6/runner/env.example
```

Related docs:

```text
docs/infrastructure/benchmark-execution-lifecycle.md
docs/infrastructure/secret-management.md
docs/infrastructure/deployment-strategy.md
docs/development/k6-workload-scenarios.md
```

## 4. Runtime Topology

### 4.1 Monolith

Expected monolith observability path:

```text
k6
  |
  v
Monolith HTTP endpoint
  |
  v
Echo tracing middleware
  |
  v
monolith service/usecase/repository
  |
  v
PostgreSQL

Monolith pod
  |
  v
Datadog Agent on same node
  |
  v
Datadog backend
```

Expected trace shape:

```text
HTTP request
-> monolith
```

The monolith has one application process and one scaling unit. Datadog should
show service-level latency, throughput, error rate, CPU, memory, logs, and HPA
behavior for the `monolith` service.

### 4.2 Microservices

Expected microservices observability path:

```text
k6
  |
  v
API Gateway HTTP endpoint
  |
  v
Echo tracing middleware
  |
  v
API Gateway gRPC client tracing
  |
  v
Business service gRPC server tracing
  |
  v
service usecase/repository/client
  |
  v
PostgreSQL or another gRPC service
```

Expected Create Transaction trace shape:

```text
HTTP request
-> api-gateway
-> transaction-service
-> item-service
```

Expected Enriched Transactions trace shape:

```text
HTTP request
-> api-gateway
-> transaction-service
-> api-gateway (fan-out, parallel)
-> auth-service
-> item-service
```

Microservices require deeper tracing because requests cross multiple runtime
boundaries. Datadog should make those boundaries visible without changing
business behavior.

For this benchmark, `transaction-service` is responsible only for returning raw
transaction data from `transaction_db`. The enriched response is assembled by
`api-gateway`, which batches the referenced IDs, calls `auth-service` and
`item-service`, and merges the returned summaries in memory. In trace review,
the important point is not just that `auth-service` and `item-service` appear,
but that they appear as downstream fan-out work initiated by `api-gateway`
after the raw transaction read completes.

## 5. Helm Configuration

Both Minikube and EKS values enable:

- Datadog Agent,
- Datadog Cluster Agent,
- container logs,
- APM TCP port `8126`,
- DogStatsD UDP port `8125`,
- Kubernetes metadata collection,
- process collection,
- kube-state-metrics core.

Important Helm values:

| Setting | Meaning |
|---|---|
| `datadog.apiKeyExistingSecret` | Uses an existing Kubernetes Secret instead of storing API key in values |
| `datadog.logs.enabled` | Enables log collection |
| `datadog.logs.containerCollectAll` | Collects logs from all containers |
| `datadog.apm.portEnabled` | Opens APM trace intake over TCP `8126` |
| `datadog.dogstatsd.port` | Sets DogStatsD port to `8125` |
| `datadog.dogstatsd.useHostPort` | Exposes DogStatsD through host port |
| `datadog.dogstatsd.nonLocalTraffic` | Allows DogStatsD traffic from non-local clients |
| `clusterAgent.enabled` | Enables Datadog Cluster Agent |
| `clusterAgent.admissionController.enabled` | Enables Datadog admission controller |
| `clusterAgent.admissionController.mutateUnlabelled` | Kept `false` to avoid mutating all pods unexpectedly |

The current setup does not rely on Datadog mutating every pod. Application
manifests explicitly define required tags and `DD_*` environment variables.
This keeps the benchmark configuration visible and auditable.

## 6. Secret Management

The Datadog API key is sensitive and must never be committed.

Sensitive value:

```text
DATADOG_API_KEY
```

Optional sensitive value:

```text
DATADOG_APP_KEY
```

Kubernetes Secret:

```text
namespace: datadog
name: datadog-secret
key: api-key
```

Create secret:

```bash
make env-init-datadog-minikube
set -a
source env/datadog.minikube.env
set +a
make datadog-secret
```

The generated `env/datadog.minikube.env` file is a local helper template. Edit
the placeholder values before running `make datadog-secret`.

Important distinction:

```text
env/datadog.minikube.env
!=
datadog-secret
```

They serve different roles:

- `env/datadog.minikube.env` is a local helper file on the developer machine,
- `datadog-secret` is the Kubernetes Secret created inside the cluster,
- the Datadog Helm chart reads `datadog-secret`, not the local file directly.

The Minikube flow is:

```text
edit env/datadog.minikube.env
-> load it into the shell environment
-> run make datadog-secret
-> create/update Kubernetes Secret datadog-secret
-> run make datadog-install-minikube
-> Helm reads the existing Kubernetes Secret
```

This is why `make env-init-datadog-minikube` and `make datadog-secret` are not
the same step:

- `make env-init-datadog-minikube` creates the local helper file template,
- `make datadog-secret` converts the loaded values into the cluster Secret used
  by Helm.

Optional site override:

```bash
DATADOG_SITE=datadoghq.com \
DATADOG_API_KEY=<redacted> \
make datadog-secret
```

Optional app key:

```bash
DATADOG_APP_KEY=<redacted> \
DATADOG_API_KEY=<redacted> \
make datadog-secret
```

The current Helm values in this repository require only the Datadog API key.
The app key is supported by the helper script so the same secret can be reused
later if a Datadog feature requires `app-key`.

Rules:

- do not commit the API key,
- do not commit the app key,
- do not store the API key in Helm values,
- do not store the app key in Helm values,
- do not store the API key in application env files,
- do not print the API key in logs,
- do not include the API key in benchmark metadata.

## 7. Application Tagging

Application pods use Datadog Unified Service Tagging.

Required pod labels:

```text
tags.datadoghq.com/env
tags.datadoghq.com/service
tags.datadoghq.com/version
```

Additional benchmark architecture label:

```text
benchmark.skripsi.dev/architecture
```

Current service names:

| Workload | `DD_SERVICE` |
|---|---|
| Monolith | `monolith` |
| API Gateway | `api-gateway` |
| Auth Service | `auth-service` |
| Item Service | `item-service` |
| Transaction Service | `transaction-service` |

Current local development defaults:

```text
DD_ENV=development
DD_VERSION=local
```

Application containers receive these manifest-provided values:

```text
DD_ENV=<from pod label>
DD_SERVICE=<from pod label>
DD_VERSION=<from pod label>
DD_AGENT_HOST=<status.hostIP>
DD_TRACE_AGENT_PORT=8126
```

Datadog runtime toggles such as `DATADOG_ENABLED` and `DD_TRACE_ENABLED` are
provided through local env files, Kubernetes Secrets, or deployment-specific
runtime configuration. They are intentionally opt-in, so the manifests do not
force tracing on for every environment.

`DD_AGENT_HOST=status.hostIP` means each application pod sends traces to the
Datadog Agent running on the same Kubernetes node.

The application manifests also set:

```text
DD_TAGS=architecture:monolith
DD_TAGS=architecture:microservices
```

This makes cross-architecture filtering cleaner in Datadog APM and dashboard
queries.

Important requirement:

```text
Datadog Agent must run on every node that can schedule application pods.
```

If the Agent is not running on the same node as the application pod, APM trace
delivery can fail even if the application starts successfully.

## 8. Application Instrumentation

### 8.1 Shared Observability Helper

MSA services use:

```text
pkg/observability
```

The monolith uses:

```text
monolith/internal/shared/observability
```

The monolith has its own helper because its Go module path is separate from the
MSA/shared package module path.

The helper:

- checks `DATADOG_ENABLED` and `DD_TRACE_ENABLED`,
- starts the Datadog tracer,
- uses `DD_SERVICE` when present,
- optionally starts Datadog profiler when enabled,
- returns a cleanup function for graceful shutdown.

Profiler toggles:

```text
DATADOG_PROFILING_ENABLED=true
DD_PROFILING_ENABLED=true
```

Profiling is optional. It should be enabled only when profiling overhead is
acceptable for the experiment being run.

### 8.2 HTTP Tracing

HTTP tracing uses Datadog Echo middleware.

Instrumented HTTP applications:

- monolith,
- api-gateway.

Expected HTTP span service names:

```text
monolith
api-gateway
```

### 8.3 gRPC Tracing

gRPC tracing uses Datadog gRPC client and server interceptors.

Instrumented gRPC clients:

- API Gateway -> Auth Service,
- API Gateway -> Item Service,
- API Gateway -> Transaction Service,
- Transaction Service -> Item Service.

Instrumented gRPC servers:

- Auth Service,
- Item Service,
- Transaction Service.

This enables distributed trace propagation across the MSA request path.

### 8.4 PostgreSQL Query Visibility

The current implementation does not add automatic pgx query spans.

Reason:

```text
The latest Datadog dd-trace-go/v2 module pulled by Go did not expose the
expected contrib/jackc/pgx.v5 package path during implementation.
```

Current coverage still includes:

- HTTP spans,
- gRPC client spans,
- gRPC server spans,
- pod CPU and memory metrics,
- logs,
- process metrics,
- RDS metrics when enabled in infrastructure.

If query-level spans become required later, add them only after verifying the
exact Datadog pgx integration package and version. Do not replace the database
driver or change repository behavior only for observability.

## 9. k6 and Datadog

### 9.1 Responsibility Split

k6 remains the benchmark source of truth for:

- external latency percentiles,
- achieved request rate,
- failed request rate,
- dropped iterations,
- checks,
- raw request output.

Datadog is used to correlate those results with:

- application service latency,
- internal gRPC latency,
- CPU saturation,
- memory usage,
- HPA scaling,
- pod count,
- logs and errors,
- service-level bottlenecks.

### 9.2 Real-Time k6 Metrics

k6 sends real-time metrics to Datadog through DogStatsD.

DogStatsD path:

```text
k6 runner
-> UDP 8125
-> Datadog Agent
-> Datadog backend
```

The k6 runner image is built with:

```text
xk6-output-statsd
```

This is required because the built-in k6 StatsD output is deprecated/removed in
newer k6 versions.

### 9.3 k6 Runner Environment

Relevant environment variables:

```text
DATADOG_ENABLED=false
DATADOG_ENV=development
K6_STATSD_ADDR=127.0.0.1:8125
K6_STATSD_NAMESPACE=k6
K6_STATSD_ENABLE_TAGS=true
```

When `DATADOG_ENABLED=true`, `k6/runner/run-k6.sh`:

- adds the StatsD output,
- adds test-wide k6 tags for `run_id`, `attempt`, `architecture`, and `benchmark_scenario`,
- exports `K6_STATSD_ADDR`,
- exports `K6_STATSD_NAMESPACE`,
- exports `K6_STATSD_ENABLE_TAGS`,
- writes `datadog-time-window.json`,
- writes Datadog metadata into `metadata.json`.

### 9.4 Running k6 with Datadog

Example local host-run command:

```bash
DATADOG_ENABLED=true \
DATADOG_ENV=development \
K6_STATSD_ADDR=127.0.0.1:8125 \
k6/runner/run-k6.sh
```

Recommended operating modes:

- `Minikube validation mode`
  Use the same runner script with lightweight settings. Keep `S3_URI` empty.
- `EKS benchmark mode`
  Run the same runner script inside the benchmark Job with `DATADOG_ENABLED=true`
  and a non-empty `S3_URI`.

For in-cluster k6 jobs, prefer a DogStatsD endpoint reachable from the k6 pod.

Possible patterns:

```text
node-local Agent endpoint
Datadog Agent Service endpoint
hostPort exposed Agent endpoint
```

Current EKS job templates use:

```text
datadog-agent.datadog.svc.cluster.local:8125
```

The selected pattern must be documented in `metadata.json` through:

```text
datadog.k6_statsd_addr
datadog.k6_statsd_namespace
```

## 10. Metadata and Result Files

When Datadog is enabled, every measured attempt must include:

```text
datadog-time-window.json
```

The runner also writes a Datadog block into:

```text
metadata.json
```

Example:

```json
{
  "datadog": {
    "enabled": true,
    "env": "development",
    "time_window_start": "2026-05-17T10:00:00Z",
    "time_window_end": "2026-05-17T10:05:00Z",
    "k6_statsd_addr": "127.0.0.1:8125",
    "k6_statsd_namespace": "k6",
    "k6_statsd_enable_tags": true
  }
}
```

The time window is important because Datadog is queried by time range during
analysis. Without this file, it is harder to correlate a k6 attempt with its
Datadog traces and metrics.

Required result files when Datadog is enabled:

```text
summary.json
raw.json.gz
stdout.log
metadata.json
k6-options.json
thresholds.json
datadog-time-window.json
```

## 11. Minikube Runbook

### 11.1 Start Minikube

Datadog Agent, app pods, PostgreSQL, and k6 smoke workloads need more local
resources than the minimal Minikube default.

Recommended:

```bash
make minikube-start MINIKUBE_CPUS=4 MINIKUBE_MEMORY=6144
```

If the local machine has enough resources, higher memory is safer:

```bash
make minikube-start MINIKUBE_CPUS=6 MINIKUBE_MEMORY=8192
```

### 11.2 Install Datadog

```bash
DATADOG_API_KEY=<redacted> make datadog-install-minikube
```

Optional Datadog site:

```bash
DATADOG_SITE=datadoghq.com \
DATADOG_API_KEY=<redacted> \
make datadog-install-minikube
```

### 11.3 Verify Datadog

```bash
make datadog-status
```

Expected:

```text
datadog Agent DaemonSet exists
Datadog Agent pod is Running
Datadog Cluster Agent Deployment exists
Datadog Cluster Agent pod is Running
```

Useful direct checks:

```bash
kubectl get pods -n datadog
kubectl get daemonset -n datadog
kubectl logs -n datadog -l app=datadog --tail=100
```

### 11.4 Deploy Monolith

Smoke flow:

```bash
make minikube-bootstrap-monolith-smoke
```

Benchmark-size dataset flow:

```bash
make minikube-bootstrap-monolith-benchmark
```

Verify:

```bash
kubectl get pods -n mono
kubectl describe pod -n mono -l app=monolith
```

Confirm local development labels:

```text
tags.datadoghq.com/env=development
tags.datadoghq.com/service=monolith
tags.datadoghq.com/version=local
```

### 11.5 Deploy Microservices

Smoke flow:

```bash
make minikube-bootstrap-microservices-smoke
```

Benchmark-size dataset flow:

```bash
make minikube-bootstrap-microservices-benchmark
```

Verify:

```bash
kubectl get pods -n msa
kubectl describe pod -n msa -l app=api-gateway
kubectl describe pod -n msa -l app=transaction-service
```

Expected service labels:

```text
api-gateway
auth-service
item-service
transaction-service
```

### 11.6 Verify APM Trace Flow

Generate traffic:

```bash
make minikube-port-forward-monolith
```

or:

```bash
make minikube-port-forward-api-gateway
```

Then run a small k6 smoke test or curl requests.

Expected Datadog services:

```text
monolith
api-gateway
auth-service
item-service
transaction-service
```

Expected MSA create transaction trace:

```text
api-gateway
-> transaction-service
-> item-service
```

## 12. AWS EKS Runbook

EKS is the final benchmark target. The dual cluster design uses two separate
EKS clusters — one for monolith and one for MSA — each with its own Datadog
Helm values file and `cluster_name` tag.

Install Datadog on monolith cluster:

```bash
DATADOG_API_KEY=<redacted> make datadog-install-eks-monolith
```

Install Datadog on MSA cluster:

```bash
DATADOG_API_KEY=<redacted> make datadog-install-eks-msa
```

The two EKS values files differ only in `clusterName` and `tags`:

| Setting | Monolith cluster | MSA cluster |
|---|---|---|
| `clusterName` | `skripsi-monolith` | `skripsi-msa` |
| `architecture` tag | `architecture:monolith` | `architecture:microservices` |

Both clusters use `env:benchmark` as the Datadog Agent environment tag.
Application pods on EKS must also expose `DD_ENV=benchmark` semantics through
their pod labels or deployment-specific overrides. The tracked application
manifests in this branch now default to `tags.datadoghq.com/env=development`
for the local Minikube flow, while k6 benchmark jobs should use
`DATADOG_ENV=benchmark`.

Use the repository's active EKS provisioning and deployment runbook for the
cluster lifecycle, then apply the Datadog install commands above on each
cluster after the workloads and secrets are ready.

Important EKS rule:

```text
Do not install Datadog only on system nodes if app pods run on app nodes and
DD_AGENT_HOST uses status.hostIP.
```

The Agent must run on app nodes so application traces can reach the local Agent.

## 13. Benchmark Fairness Rules

Datadog adds observability overhead.

Therefore:

- do not compare Datadog-enabled attempts with Datadog-disabled attempts unless the difference is explicitly documented,
- keep Datadog enabled consistently across monolith and microservices for a comparison group,
- state explicitly in the methodology that every measured attempt runs on clusters
  with the same Datadog monitoring components enabled on both architectures,
- keep the same k6 Datadog output settings for both architectures,
- record Datadog status in metadata,
- record the Datadog time window for every measured attempt,
- do not change application resource ceilings only for Datadog unless that change is documented outside the app quota comparison,
- do not add caching, retries, queues, circuit breakers, or async behavior as part of observability.

Interpretation rule:

- the application resource ceilings remain the comparison baseline,
- while Datadog overhead is treated as identical cluster-level observability
  overhead present on both architectures, not as an asymmetric application
  optimization.

Datadog must not change benchmark semantics.

Forbidden as part of Datadog integration:

- changing REST API behavior,
- changing gRPC contract behavior,
- changing transaction validation behavior,
- changing seed dataset shape,
- changing reset semantics,
- changing application database ownership,
- adding distributed transaction mechanisms,
- adding service-specific optimizations that are not symmetric.

## 14. Verification Checklist

Before running a measured benchmark:

- Datadog Agent is installed.
- Datadog Agent pods are Running.
- Datadog Cluster Agent is Running.
- Application pods have Datadog tags.
- Application pods have `DD_AGENT_HOST`.
- Monolith emits APM traces.
- API Gateway emits HTTP traces.
- MSA services emit gRPC traces.
- k6 can still produce `summary.json`.
- k6 can still produce `raw.json.gz`.
- `metadata.json` includes Datadog status.
- `datadog-time-window.json` exists when Datadog is enabled.
- Results are uploaded to S3 before infrastructure destroy.

## 15. Troubleshooting

### 15.1 Datadog Agent Pod Not Running

Check:

```bash
kubectl get pods -n datadog
kubectl describe pod -n datadog <pod-name>
kubectl logs -n datadog <pod-name> --tail=100
```

Common causes:

- invalid API key,
- insufficient Minikube resources,
- image pull failure,
- Helm values error,
- node pressure.

### 15.2 No APM Traces

Check app env:

```bash
kubectl describe pod -n mono -l app=monolith
kubectl describe pod -n msa -l app=api-gateway
```

Required env for a traced run:

```text
DATADOG_ENABLED=true
DD_TRACE_ENABLED=true
DD_AGENT_HOST=<node ip>
DD_TRACE_AGENT_PORT=8126
```

Check Agent is on the same node:

```bash
kubectl get pods -A -o wide
```

If the application pod runs on a node without a Datadog Agent pod, APM delivery
can fail.

### 15.3 No k6 Metrics in Datadog

Check:

```bash
DATADOG_ENABLED=true
K6_STATSD_ADDR=<agent-host>:8125
```

Common causes:

- k6 binary does not include `xk6-output-statsd`,
- DogStatsD port `8125` is not reachable,
- `K6_STATSD_ADDR` points to the wrong host,
- UDP traffic is blocked,
- Datadog Agent DogStatsD is not enabled.

### 15.4 Missing `datadog-time-window.json`

This file is written only when:

```text
DATADOG_ENABLED=true
```

If the file is missing, the attempt should be treated as Datadog-disabled or
rerun with Datadog enabled.

### 15.5 High Resource Usage in Minikube

Datadog can be heavy for small local clusters.

Use:

```bash
make minikube-start MINIKUBE_CPUS=4 MINIKUBE_MEMORY=6144
```

or:

```bash
make minikube-start MINIKUBE_CPUS=6 MINIKUBE_MEMORY=8192
```

If pods remain Pending, inspect:

```bash
kubectl describe pod -n datadog <pod-name>
kubectl top nodes
kubectl top pods -A
```

## 16. Known Limitations

Current limitations:

- automatic pgx query tracing is not enabled,
- EKS Terraform integration is not implemented yet,
- Datadog RDS integration is not yet configured in infrastructure code,
- final Datadog dashboard definitions are not yet committed.

These limitations do not block Minikube validation of:

- Agent installation,
- logs,
- HTTP traces,
- gRPC traces,
- service tagging,
- k6 metadata,
- k6 DogStatsD output path.

## 17. References

Official references:

- Datadog Kubernetes Agent DaemonSet and installation guidance:
  `https://docs.datadoghq.com/containers/guide/kubernetes_daemonset/?tab=tcp`
- Datadog Go tracer configuration:
  `https://docs.datadoghq.com/tracing/trace_collection/library_config/go/`
- Grafana k6 Datadog real-time output:
  `https://grafana.com/docs/k6/latest/results-output/real-time/datadog/`
- Datadog k6 integration:
  `https://docs.datadoghq.com/integrations/k6/`
