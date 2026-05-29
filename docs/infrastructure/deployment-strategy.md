# Deployment Strategy

## 1. Purpose

This document describes the deployment strategy for the thesis benchmark project.

The project compares:

1. Monolithic Architecture
2. Microservices Architecture

The deployment strategy is split into three levels:

```text
Level 1: Docker Compose
Level 2: Minikube
Level 3: AWS EKS
```

Each level has a different purpose.

Docker Compose is used for local development and functional validation.

Minikube is used for local Kubernetes dry-run.

AWS EKS is used for the final benchmark environment.

---

## 2. Final Deployment Decision

Final decision:

```text
Local development       : Docker Compose
Local Kubernetes dry-run: Minikube
Final benchmark         : AWS EKS
Database final          : Amazon RDS PostgreSQL 18
Result storage final    : Amazon S3
Observability final     : Datadog
```

Final execution model:

```text
DB bootstrap  : Kubernetes Job
Migration     : Kubernetes Job
Seed          : Kubernetes Job
Application   : Kubernetes Deployment
k6 benchmark  : Kubernetes Job
Result upload : Amazon S3
```

Important rule:

```text
Only AWS EKS benchmark results are used as final thesis experiment results.
```

Docker Compose and Minikube are used to reduce implementation risk before the final AWS experiment.

---

## 3. Deployment Levels

### 3.1 Level 1: Docker Compose

Purpose:

- run services locally,
- test REST API behavior,
- test gRPC communication,
- test PostgreSQL connection,
- test Goose migration locally,
- test seed scripts locally,
- run small k6 smoke tests.

Docker Compose is the fastest local validation layer.

Use it before Minikube or EKS.

Suitable for:

```text
- development
- debugging
- functional testing
- service integration testing
- local database validation
```

Not suitable for:

```text
- final benchmark result
- HPA testing
- Kubernetes ResourceQuota testing
- EKS topology validation
```

---

### 3.2 Level 2: Minikube

Purpose:

- validate Kubernetes manifests,
- validate Helm charts if used,
- validate Kubernetes Secret injection,
- validate DB Bootstrap Job,
- validate migration Jobs,
- validate seed Jobs,
- validate Service discovery,
- validate Ingress behavior,
- validate basic HPA behavior,
- run small k6 smoke tests inside or outside the cluster.

Minikube is a Kubernetes dry-run environment.

Suitable for:

```text
- Kubernetes manifest testing
- local cluster deployment validation
- Secret/ConfigMap validation
- DB Bootstrap Job validation
- migration Job validation
- seed Job validation
- Service/Ingress validation
- small k6 smoke Job validation
```

Not suitable for:

```text
- final benchmark result
- final RPS comparison
- final resource efficiency conclusion
```

Reason:

Minikube does not represent the final AWS EKS environment. It usually runs locally and shares resources with the developer machine.

---

### 3.3 Level 3: AWS EKS

Purpose:

- run final thesis benchmark,
- collect final performance data,
- collect final resource usage data,
- observe HPA behavior,
- collect Datadog telemetry,
- store benchmark results in S3.

AWS EKS is the final experiment environment.

Suitable for:

```text
- final benchmark
- thesis Chapter 4 data
- Datadog monitoring
- RDS PostgreSQL 18 integration
- S3 result upload
- ResourceQuota validation
- HPA behavior observation
- app node group and testing node group validation
```

---

## 4. Recommended Development Flow

Use the following sequence:

```text
1. Implement service locally
2. Run with GoLand or Makefile
3. Validate with Docker Compose
4. Validate Kubernetes manifests with Minikube
5. Deploy to AWS EKS for final benchmark
```

Detailed flow:

```text
Code implementation
    |
    v
Local go test
    |
    v
Docker Compose functional test
    |
    v
Minikube Kubernetes dry-run
    |
    v
AWS EKS final benchmark
```

---

## 5. Docker Compose Strategy

Docker Compose files should be stored under:

```text
deployments/compose/
```

Recommended structure:

```text
deployments/
└── compose/
    ├── docker-compose.db.yml
    ├── docker-compose.monolith.yml
    └── initdb/
```

File responsibilities:

| File | Purpose |
|---|---|
| `docker-compose.db.yml` | local PostgreSQL only |
| `docker-compose.monolith.yml` | monolith app container only (connects to `skripsi-local` network) |
| `initdb/*.sql` | initial database bootstrap SQL for local PostgreSQL container |

---

## 6. Docker Compose: Monolith Flow

Expected local flow:

```text
PostgreSQL
    |
    v
Create local databases if needed
    |
    v
Run monolith migration
    |
    v
Run monolith seed
    |
    v
Optional: run monolith enrichment preparation for enriched-transactions
    |
    v
Run monolith app
    |
    v
Test REST API
```

Example commands:

```bash
docker compose -f deployments/compose/docker-compose.monolith.yml up --build
```

Or using Makefile:

```bash
make compose-monolith-up
make migrate-monolith
make seed-monolith-data DATASET=benchmark
make prepare-monolith-enrichment-data DATASET=benchmark
make run-monolith
```

For `login` and `create-transaction`, stop after the base seed step. Run the
prepare command only when you are validating `GET /api/v1/admin/transactions`.

Notes:

```text
Docker Compose may use PostgreSQL init SQL or a local script to create databases.
The db-bootstrap-job is mainly required for Kubernetes environments.
```

---

## 7. Docker Compose: Microservices Flow

Expected local flow:

```text
PostgreSQL
    |
    v
Create local databases if needed
    |
    v
Run service migrations
    |
    v
Run microservices seed
    |
    v
Optional: run microservices enrichment preparation for enriched-transactions
    |
    v
Run Auth Service
    |
    v
Run Item Service
    |
    v
Run Transaction Service
    |
    v
Run API Gateway
    |
    v
Test REST API through API Gateway
```

Example commands:

```bash
docker compose -f deployments/compose/docker-compose.microservices.yml up --build
```

Or using Makefile:

```bash
make compose-microservices-up
make migrate-microservices
make seed-microservices-data DATASET=benchmark
make prepare-microservices-enrichment-data DATASET=benchmark
```

For `login` and `create-transaction`, stop after the base seed step. Run the
prepare command only when you are validating `GET /api/v1/admin/transactions`.

---

## 8. Minikube Strategy

Minikube is used after Docker Compose works.

Recommended purpose:

```text
Kubernetes validation only
```

Recommended local cluster:

```bash
minikube start --driver=docker --cpus=2 --memory=3072 --disk-size=20g
```

For heavier validation:

```bash
minikube start --driver=docker --cpus=6 --memory=8192 --disk-size=30g
```

Enable useful addons:

```bash
minikube addons enable ingress
minikube addons enable metrics-server
```

Use Minikube to validate:

```text
- Namespace
- ConfigMap
- Secret
- Deployment
- Service
- Ingress
- DB Bootstrap Job
- Migration Job
- Seed Job
- k6 smoke Job
- HPA basic behavior
```

---

## 9. Minikube Database Strategy

For Minikube, use PostgreSQL inside the cluster for Kubernetes validation.

Reason:

```text
It makes DB Bootstrap Job, migration Job, and seed Job behavior easier to validate.
```

Example local-only database manifest:

```text
deployments/k8s/local/shared/postgres.yaml
```

Do not treat Minikube PostgreSQL as equivalent to Amazon RDS.

Final benchmark still uses:

```text
Amazon RDS PostgreSQL 18
```

Minikube database preparation flow:

```text
PostgreSQL local cluster
    |
    v
db-bootstrap-job
    |
    v
migration jobs
    |
    v
seed job
    |
    v
application deployment
```

---

## 10. Minikube Image Strategy

Recommended approach:

```text
Build local Docker images and load them into Minikube.
```

Example:

```bash
eval $(minikube docker-env)
docker build -t skripsi/monolith:local -f monolith/Dockerfile .
```

After the monolith deployment is ready, use a foreground port-forward session
for direct access from the host:

```bash
make minikube-port-forward-monolith
```

If local port `8080` is already occupied:

```bash
make minikube-port-forward-monolith MONOLITH_PORT=18080
```

For microservices:

```bash
eval $(minikube docker-env)
docker build -t skripsi/api-gateway:local ./microservices/api-gateway
docker build -t skripsi/auth-service:local ./microservices/auth-service
docker build -t skripsi/item-service:local ./microservices/item-service
docker build -t skripsi/transaction-service:local ./microservices/transaction-service
```

Set local Kubernetes manifests to:

```yaml
imagePullPolicy: Never
```

---

## 11. Minikube Node Placement

The final EKS environment uses separate node groups:

```text
app-nodes
testing-nodes
```

Minikube usually runs as a single-node cluster.

Therefore, do not force final nodeSelector behavior in Minikube.

Recommended strategy:

```text
Use separate values or overlay for Minikube.
```

For Minikube:

```yaml
nodeSelector: {}
```

For EKS application pods:

```yaml
nodeSelector:
  node-group: app
```

For k6 in EKS:

```yaml
nodeSelector:
  node-group: testing
```

If the testing node group uses taint, the k6 Job must also use matching toleration.

Example:

```yaml
tolerations:
  - key: workload
    operator: Equal
    value: benchmark
    effect: NoSchedule
```

---

## 12. AWS EKS Final Strategy

AWS EKS is the final benchmark environment.

EKS components:

```text
- EKS cluster
- app node group
- testing node group
- application namespaces
- HPA
- ResourceQuota
- RDS PostgreSQL 18
- S3 result bucket
- ECR repositories
- IAM role for k6 runner
- EKS Pod Identity or IRSA
- Datadog
```

Expected namespaces:

```text
mono
msa
benchmark
```

Application placement:

```text
application pods -> app-nodes
k6 runner        -> testing-nodes
```

Recommended node labels:

```text
node-group=app
node-group=testing
```

---

## 12a. Microservices Pod Anti-Affinity

The microservices architecture uses pod anti-affinity to spread service pods
across available app nodes. This prevents CPU-heavy services (especially
`auth-service`) from being co-located with other services on the same node,
which would create an unbalanced resource distribution.

### Problem

Without anti-affinity, the Kubernetes scheduler may place all four MSA service
pods on the same app node:

```text
App Node 1 (88% CPU):  auth-service (6989m) + api-gateway (25m)
App Node 2 (0.8% CPU): item-service (1m) + transaction-service (1m)
```

This creates an artificial bottleneck on one node while the other node is
underutilized.

### Solution

Each MSA base deployment includes a `preferredDuringSchedulingIgnoredDuringExecution`
anti-affinity rule that prefers scheduling pods on nodes that do not already
have pods with the `benchmark.skripsi.dev/architecture: microservices` label.

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: benchmark.skripsi.dev/architecture
                operator: In
                values:
                  - microservices
          topologyKey: kubernetes.io/hostname
```

### Expected Result

With 2 app nodes and 4 services (fixed mode, 1 replica each), the scheduler
will spread 2 services per node:

```text
App Node 1: auth-service + transaction-service
App Node 2: api-gateway + item-service
```

Or any other 2-service combination, depending on scheduling order and resource
availability.

### Properties

- `preferred` (not `required`): scheduler will still place pods if anti-affinity
  cannot be satisfied. This avoids scheduling failures when only one node is
  available.
- `weight: 100`: highest soft preference, strongly encourages spreading.
- `topologyKey: kubernetes.io/hostname`: spread across distinct nodes.
- Uses existing label `benchmark.skripsi.dev/architecture: microservices` that
  is already present on all MSA service pods.
- Applies to both `fixed` and `HPA` overlays because the rule is in the base
  manifest.

### Fairness Impact

Anti-affinity is applied symmetrically to all microservices services. It does
not give any service a special advantage. It simply distributes services across
available nodes, which is a standard Kubernetes scheduling practice.

The monolith architecture does not need anti-affinity because it runs as a
single deployment with replicas that are identical and interchangeable.

### Files Modified

```text
deployments/k8s/eks/microservices/base/api-gateway.yaml
deployments/k8s/eks/microservices/base/auth-service.yaml
deployments/k8s/eks/microservices/base/item-service.yaml
deployments/k8s/eks/microservices/base/transaction-service.yaml
```

---

## 13. Database Job Model

Database preparation is separated from application runtime.

Final model:

```text
DB bootstrap  -> Kubernetes Job
Migration     -> Kubernetes Job
Seed          -> Kubernetes Job
Application   -> Kubernetes Deployment
k6 benchmark  -> Kubernetes Job
```

Reason:

```text
Database bootstrap, migration, and seed are one-shot tasks.
They must not run every time an application pod starts or scales out.
```

Do not use application init containers for database bootstrap or migration.

---

## 14. DB Bootstrap Job

The DB Bootstrap Job creates internal PostgreSQL databases after RDS is ready.

Job name:

```text
db-bootstrap-job
```

Recommended namespace:

```text
benchmark
```

Databases created:

```text
mono_db
auth_db
item_db
transaction_db
```

Target connection:

```text
RDS initial database, for example bootstrap
```

Example bootstrap SQL:

```sql
CREATE DATABASE mono_db;
CREATE DATABASE auth_db;
CREATE DATABASE item_db;
CREATE DATABASE transaction_db;
```

The Job should be executed once before all migration jobs.

Secret used:

```text
db-bootstrap-env
```

Expected secret key:

```text
BOOTSTRAP_DATABASE_URL
```

---

## 15. Migration Jobs

Migration Jobs create schema objects using Goose SQL migrations.

Monolith:

```text
monolith-migration-job -> mono_db
```

Microservices:

```text
auth-migration-job        -> auth_db
item-migration-job        -> item_db
transaction-migration-job -> transaction_db
```

API Gateway has no migration job.

Migration command pattern:

```bash
goose -dir /app/migrations postgres "$DATABASE_URL" up
```

Important rule:

```text
Migration must run before seed and before application benchmark execution.
Migration must not run during benchmark execution.
```

---

## 16. Seed Jobs

Seed Jobs insert benchmark datasets.

Monolith:

```text
seed-monolith-benchmark-data-job
```

Microservices:

```text
seed-microservices-benchmark-data-job
```

Seed jobs should run after migration jobs and before benchmark execution.

Seed runner behavior, datasets, reset semantics, and retry behavior are
documented in `seed/README.md`.

For mutation-heavy scenarios, reset and seed may be rerun before each scenario to restore a clean dataset.

---

## 17. k6 Benchmark Job

The final benchmark should run as a Kubernetes Job.

Recommended namespace:

```text
benchmark
```

Recommended service account:

```text
k6-runner
```

The k6 Job should:

```text
- read scenario configuration
- run the selected k6 script
- export summary.json
- export metadata.json
- export stdout.log
- upload results to S3
```

The k6 Job should run on:

```text
node-group=testing
```

The k6 runner should use IAM role-based access through EKS Pod Identity or IRSA to upload results to S3.

Do not store static AWS access keys in Kubernetes Secrets.

---

## 18. Final EKS Deployment Flow

Final experiment flow:

```text
terraform apply
    |
    v
configure kubectl
    |
    v
create Kubernetes namespaces
    |
    v
create/update Kubernetes Secrets
    |
    v
run db-bootstrap-job
    |
    v
run migration Jobs
    |
    v
run seed Job
    |
    v
deploy application architecture
    |
    v
validate readiness
    |
    v
run k6 benchmark Job
    |
    v
export cluster snapshots
    |
    v
upload results to S3
    |
    v
verify S3 results
    |
    v
terraform destroy
```

Important:

```text
DB bootstrap, migration, and seed must not run during benchmark execution.
Application pods should not run schema migration automatically.
```

---

## 19. Monolith Deployment Flow

```text
Apply local Kubernetes namespaces
    |
    v
Create monolith-env
    |
    v
Run db-bootstrap-job if not already completed
    |
    v
Run monolith-migration-job
    |
    v
Run seed-monolith-benchmark-data-job
    |
    v
Deploy monolith
    |
    v
Apply ResourceQuota
    |
    v
Apply monolith HPA
    |
    v
Validate readiness
    |
    v
Run k6 benchmark Job
    |
    v
Upload results to S3
```

Expanded sequence:

```text
1. Apply the local Kubernetes namespace manifest.
2. Create monolith-env.
3. Run db-bootstrap-job.
4. Wait until db-bootstrap-job is complete.
5. Run monolith-migration-job.
6. Wait until monolith-migration-job is complete.
7. Run seed-monolith-benchmark-data-job.
8. Wait until seed-monolith-benchmark-data-job is complete.
9. Deploy monolith application.
10. Apply ResourceQuota and HPA.
11. Validate deployment readiness.
12. Run k6 benchmark Job.
13. Upload benchmark results to S3.
```

---

## 20. Microservices Deployment Flow

```text
Apply local Kubernetes namespaces
    |
    v
Create service secrets
    |
    v
Run db-bootstrap-job if not already completed
    |
    v
Run auth-migration-job
    |
    v
Run item-migration-job
    |
    v
Run transaction-migration-job
    |
    v
Run seed-microservices-benchmark-data-job
    |
    v
Deploy Auth Service
    |
    v
Deploy Item Service
    |
    v
Deploy Transaction Service
    |
    v
Deploy API Gateway
    |
    v
Apply ResourceQuota
    |
    v
Apply service HPAs
    |
    v
Validate readiness
    |
    v
Run k6 benchmark Job
    |
    v
Upload results to S3
```

Expanded sequence:

```text
1. Create local PostgreSQL and db-bootstrap secrets.
2. Apply the local Kubernetes namespace manifest.
3. Create api-gateway-secret.
4. Create auth-service-secret.
5. Create item-service-secret.
6. Create transaction-service-secret.
7. Run db-bootstrap-job.
8. Wait until db-bootstrap-job is complete.
9. Run auth-migration-job.
10. Run item-migration-job.
11. Run transaction-migration-job.
12. Wait until all migration jobs are complete.
13. Run reset-microservices-data-job.
14. Run either seed-microservices-smoke-data-job or seed-microservices-benchmark-data-job.
15. Wait until the selected seed job is complete.
16. Deploy Auth Service.
17. Deploy Item Service.
18. Deploy Transaction Service.
19. Deploy API Gateway.
20. Apply ResourceQuota and HPAs.
21. Validate all service readiness.
22. Run k6 benchmark Job.
23. Upload benchmark results to S3.
```

---

## 21. Deployment Tools

Recommended tool usage:

| Tool | Purpose |
|---|---|
| Docker Compose | local functional validation |
| Minikube | local Kubernetes dry-run |
| Terraform | provision AWS infrastructure |
| kubectl | apply Kubernetes objects and inspect cluster |
| Helm | optional chart-based deployment |
| Makefile | repeatable local commands |
| shell scripts | experiment orchestration |
| k6 | benchmark execution |
| Datadog | observability |
| S3 | benchmark result storage |
| ECR | application image registry |
| EKS Pod Identity / IRSA | AWS access for k6 runner |

---

## 22. Makefile Role

The Makefile should act as a command center.

Recommended targets:

For day-to-day local Kubernetes usage, prefer these entry points first:

- monolith smoke: `make minikube-bootstrap-monolith-smoke`
- monolith benchmark prep: `make minikube-bootstrap-monolith-benchmark`
- monolith enriched read prep: `make minikube-bootstrap-monolith-enrichment-benchmark`
- microservices smoke: `make minikube-bootstrap-microservices-smoke`
- microservices benchmark prep: `make minikube-bootstrap-microservices-benchmark`
- microservices enriched read prep: `make minikube-bootstrap-microservices-enrichment-benchmark`

Treat the longer list below as a reference inventory.

```text
make run-monolith
make run-auth-service
make run-item-service
make run-transaction-service
make run-api-gateway

make compose-monolith-up
make compose-microservices-up
make compose-down

make migrate-monolith
make migrate-microservices

make seed-monolith-data DATASET=smoke
make seed-monolith-data DATASET=benchmark
make prepare-monolith-enrichment-data DATASET=smoke
make prepare-monolith-enrichment-data DATASET=benchmark
make seed-microservices-data DATASET=smoke
make seed-microservices-data DATASET=benchmark
make prepare-microservices-enrichment-data DATASET=smoke
make prepare-microservices-enrichment-data DATASET=benchmark

make reset-monolith-data
make reset-microservices-data

make minikube-start
make minikube-load-images
make minikube-reset-monolith-data
make minikube-seed-monolith-smoke
make minikube-seed-monolith-benchmark
make minikube-prepare-monolith-enrichment-smoke
make minikube-prepare-monolith-enrichment-benchmark
make minikube-load-microservices
make minikube-bootstrap-monolith-smoke
make minikube-bootstrap-monolith-benchmark
make minikube-bootstrap-monolith-enrichment-smoke
make minikube-bootstrap-monolith-enrichment-benchmark
make minikube-deploy-monolith
make minikube-migrate-microservices
make minikube-reset-microservices-data
make minikube-seed-microservices-smoke
make minikube-seed-microservices-benchmark
make minikube-prepare-microservices-enrichment-smoke
make minikube-prepare-microservices-enrichment-benchmark
make minikube-bootstrap-microservices-smoke
make minikube-bootstrap-microservices-benchmark
make minikube-bootstrap-microservices-enrichment-smoke
make minikube-bootstrap-microservices-enrichment-benchmark
make minikube-deploy-microservices

make create-local-postgres-secrets
make create-local-secrets
make create-local-secrets-microservices
make db-bootstrap
make deploy-monolith
make deploy-microservices
make run-k6-job

make eks-apply
make eks-destroy-confirmed
```

The Makefile should not hide undocumented experiment behavior.

Critical experiment behavior must be documented.

---

## 23. Local Kubernetes Command Reference

Use this section as the low-level operational reference for the local Minikube
flow implemented in this repository.

The `make` targets remain the primary entry points. The commands below are the
manual equivalents you can use for inspection, debugging, or step-by-step
reruns.

### 23.1 Cluster lifecycle

Start the local cluster:

```bash
minikube start --driver=docker --cpus=2 --memory=3072 --disk-size=20g
minikube addons enable ingress
minikube addons enable metrics-server
```

Command notes:

- `minikube start ...`: starts the local Kubernetes cluster with the expected CPU, memory, and disk size.
- `minikube addons enable ingress`: enables the local ingress controller for hostname-based access.
- `minikube addons enable metrics-server`: enables metrics collection so HPA can evaluate CPU usage.

Check status:

```bash
minikube status
kubectl get nodes
kubectl get ns
```

Command notes:

- `minikube status`: shows whether the Minikube host, kubelet, and apiserver are healthy.
- `kubectl get nodes`: shows node readiness from the Kubernetes control plane.
- `kubectl get ns`: lists namespaces currently available in the cluster.

Stop or reset:

```bash
minikube stop
minikube delete
```

Command notes:

- `minikube stop`: stops the cluster runtime while usually keeping cluster state and PVC-backed data.
- `minikube delete`: removes the whole local cluster and should be treated as a full reset.

### 23.2 Image build and load

Build the local images with host Docker:

```bash
docker build -t skripsi/monolith:local -f monolith/Dockerfile .
docker build -t skripsi/api-gateway:local -f microservices/api-gateway/Dockerfile .
docker build -t skripsi/auth-service:local -f microservices/auth-service/Dockerfile .
docker build -t skripsi/item-service:local -f microservices/item-service/Dockerfile .
docker build -t skripsi/transaction-service:local -f microservices/transaction-service/Dockerfile .
docker build -t skripsi/seed-runner:local -f seed/Dockerfile .
```

Command notes:

- each `docker build -t ...`: builds one local application or utility image from the current repository source.

Load the images into the Minikube node runtime:

```bash
docker save skripsi/monolith:local | docker exec -i minikube docker load
docker save skripsi/api-gateway:local | docker exec -i minikube docker load
docker save skripsi/auth-service:local | docker exec -i minikube docker load
docker save skripsi/item-service:local | docker exec -i minikube docker load
docker save skripsi/transaction-service:local | docker exec -i minikube docker load
docker save skripsi/seed-runner:local | docker exec -i minikube docker load
```

Command notes:

- each `docker save ... | docker exec -i minikube docker load`: transfers a host-built image into the Docker runtime used by the Minikube node.

### 23.3 Shared PostgreSQL preparation

Create namespaces and PostgreSQL secrets:

```bash
kubectl apply -f deployments/k8s/namespaces/local.yaml

bash scripts/create-local-postgres-secrets.sh
```

Command notes:

- `kubectl apply -f deployments/k8s/namespaces/local.yaml`: creates or updates the local Kubernetes namespaces used by the Minikube flow.
- `bash scripts/create-local-postgres-secrets.sh`: generates the local PostgreSQL and DB bootstrap Kubernetes secrets from env files.

Deploy PostgreSQL and wait until Ready:

```bash
kubectl apply -f deployments/k8s/local/shared/postgres.yaml
kubectl wait --for=condition=ready pod/postgres-0 -n local-database --timeout=180s
```

Command notes:

- `kubectl apply -f deployments/k8s/local/shared/postgres.yaml`: deploys the local PostgreSQL Service and StatefulSet.
- `kubectl wait --for=condition=ready ...`: blocks until the PostgreSQL pod is ready to accept connections.

Synchronize the in-cluster `postgres` password:

```bash
kubectl exec -n local-database postgres-0 -- /bin/sh -ec \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "ALTER USER \"$POSTGRES_USER\" WITH PASSWORD '\''$POSTGRES_PASSWORD'\'';"'
```

Command notes:

- `kubectl exec ... ALTER USER ...`: aligns the in-cluster `postgres` password with the latest generated local secret values.

Run DB bootstrap:

```bash
kubectl delete job db-bootstrap-job -n local-database --ignore-not-found
kubectl apply -f deployments/k8s/local/shared/db-bootstrap-job.yaml
kubectl wait --for=condition=complete job/db-bootstrap-job -n local-database --timeout=180s
kubectl logs job/db-bootstrap-job -n local-database
```

Command notes:

- `kubectl delete job db-bootstrap-job ...`: removes any old bootstrap job object before rerunning it.
- `kubectl apply -f deployments/k8s/local/shared/db-bootstrap-job.yaml`: starts the job that creates the internal application databases.
- `kubectl wait --for=condition=complete ...`: waits until the bootstrap job finishes successfully.
- `kubectl logs job/db-bootstrap-job ...`: prints bootstrap logs for verification or debugging.

### 23.4 Monolith manual flow

Create the monolith secret:

```bash
bash scripts/create-local-secrets.sh
```

Command notes:

- `bash scripts/create-local-secrets.sh`: creates the monolith Kubernetes secret and rewrites local DB host values for in-cluster DNS.

Run migration, reset, and seed jobs:

```bash
kubectl delete job monolith-migration-job -n mono --ignore-not-found
kubectl apply -f deployments/k8s/local/monolith/migration-job.yaml
kubectl wait --for=condition=complete job/monolith-migration-job -n mono --timeout=180s

kubectl delete job reset-monolith-data-job -n mono --ignore-not-found
kubectl apply -f deployments/k8s/local/monolith/reset-monolith-data-job.yaml
kubectl wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=180s

kubectl delete job seed-monolith-smoke-data-job -n mono --ignore-not-found
kubectl apply -f deployments/k8s/local/monolith/seed-monolith-smoke-data-job.yaml
kubectl wait --for=condition=complete job/seed-monolith-smoke-data-job -n mono --timeout=180s
```

Command notes:

- `kubectl delete job monolith-migration-job ...`: removes the old migration job object so it can be rerun cleanly.
- `kubectl apply -f deployments/k8s/local/monolith/migration-job.yaml`: starts the monolith schema migration job.
- `kubectl wait --for=condition=complete job/monolith-migration-job ...`: waits until schema migration completes.
- `kubectl delete/apply/wait reset-monolith-data-job ...`: reruns the monolith data reset job.
- `kubectl delete/apply/wait seed-monolith-smoke-data-job ...`: reruns the monolith smoke dataset seed job.

Swap the last two commands to `seed-monolith-benchmark-data-job.yaml` when you
need the benchmark dataset instead of the smoke dataset.

Deploy and inspect monolith:

```bash
kubectl apply -f deployments/k8s/local/monolith/monolith.yaml
kubectl apply -f deployments/k8s/local/monolith/resource-management-fixed.yaml
kubectl apply -f deployments/k8s/local/monolith/ingress.yaml
kubectl rollout status deployment/monolith -n mono --timeout=180s

kubectl get pods,svc,hpa,resourcequota -n mono
kubectl logs job/monolith-migration-job -n mono
```

Command notes:

- `kubectl apply -f deployments/k8s/local/monolith/monolith.yaml`: deploys the monolith application and Service.
- `kubectl apply -f deployments/k8s/local/monolith/resource-management-fixed.yaml`: applies the monolith fixed-replica ResourceQuota configuration.
- `kubectl apply -f deployments/k8s/local/monolith/ingress.yaml`: applies the monolith ingress resource.
- `kubectl rollout status deployment/monolith ...`: waits until the monolith Deployment finishes rolling out.
- `kubectl get pods,svc,hpa,resourcequota -n mono`: gives a quick summary of monolith runtime state.
- `kubectl logs job/monolith-migration-job -n mono`: shows migration logs if schema setup needs inspection.

For HPA mode, swap the resource-management manifest:

```bash
kubectl apply -f deployments/k8s/local/monolith/resource-management-hpa.yaml
```

This HPA manifest uses a `60s` scale-down stabilization window so replica
counts fall back to baseline faster after benchmark traffic stops.

Access monolith:

```bash
kubectl port-forward svc/monolith -n mono 8080:8080
curl -i http://localhost:8080/healthz
```

Command notes:

- `kubectl port-forward svc/monolith ...`: exposes the monolith Service on the local machine.
- `curl -i http://localhost:8080/healthz`: verifies that the monolith HTTP endpoint is responding.

### 23.5 Microservices manual flow

Create the microservices secrets:

```bash
bash scripts/create-local-secrets-microservices.sh
```

Command notes:

- `bash scripts/create-local-secrets-microservices.sh`: creates the gateway and service secrets and rewrites local values for in-cluster DNS and service addresses.

Run migration, reset, and seed jobs:

```bash
kubectl delete job auth-migration-job -n msa --ignore-not-found
kubectl apply -f deployments/k8s/local/microservices/auth-migration-job.yaml
kubectl wait --for=condition=complete job/auth-migration-job -n msa --timeout=180s

kubectl delete job item-migration-job -n msa --ignore-not-found
kubectl apply -f deployments/k8s/local/microservices/item-migration-job.yaml
kubectl wait --for=condition=complete job/item-migration-job -n msa --timeout=180s

kubectl delete job transaction-migration-job -n msa --ignore-not-found
kubectl apply -f deployments/k8s/local/microservices/transaction-migration-job.yaml
kubectl wait --for=condition=complete job/transaction-migration-job -n msa --timeout=180s

kubectl delete job reset-microservices-data-job -n msa --ignore-not-found
kubectl apply -f deployments/k8s/local/microservices/reset-microservices-data-job.yaml
kubectl wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=180s

kubectl delete job seed-microservices-smoke-data-job -n msa --ignore-not-found
kubectl apply -f deployments/k8s/local/microservices/seed-microservices-smoke-data-job.yaml
kubectl wait --for=condition=complete job/seed-microservices-smoke-data-job -n msa --timeout=180s
```

Command notes:

- `kubectl delete/apply/wait auth-migration-job ...`: reruns the `auth_db` schema migration.
- `kubectl delete/apply/wait item-migration-job ...`: reruns the `item_db` schema migration.
- `kubectl delete/apply/wait transaction-migration-job ...`: reruns the `transaction_db` schema migration.
- `kubectl delete/apply/wait reset-microservices-data-job ...`: clears mutable microservices benchmark data.
- `kubectl delete/apply/wait seed-microservices-smoke-data-job ...`: reruns the microservices smoke dataset seed job.

Swap the last two commands to `seed-microservices-benchmark-data-job.yaml` when
you need the benchmark dataset instead of the smoke dataset.

Deploy and inspect microservices:

```bash
kubectl apply -f deployments/k8s/local/microservices/auth-service.yaml
kubectl apply -f deployments/k8s/local/microservices/item-service.yaml
kubectl apply -f deployments/k8s/local/microservices/transaction-service.yaml
kubectl apply -f deployments/k8s/local/microservices/api-gateway.yaml
kubectl apply -f deployments/k8s/local/microservices/resource-management-fixed.yaml
kubectl apply -f deployments/k8s/local/microservices/api-gateway-ingress.yaml

kubectl rollout status deployment/auth-service -n msa --timeout=180s
kubectl rollout status deployment/item-service -n msa --timeout=180s
kubectl rollout status deployment/transaction-service -n msa --timeout=180s
kubectl rollout status deployment/api-gateway -n msa --timeout=180s

kubectl get pods,svc,hpa,resourcequota -n msa
kubectl logs job/auth-migration-job -n msa
kubectl logs job/item-migration-job -n msa
kubectl logs job/transaction-migration-job -n msa
```

Command notes:

- `kubectl apply -f deployments/k8s/local/microservices/auth-service.yaml`: deploys the Auth Service and its Service resource.
- `kubectl apply -f deployments/k8s/local/microservices/item-service.yaml`: deploys the Item Service and its Service resource.
- `kubectl apply -f deployments/k8s/local/microservices/transaction-service.yaml`: deploys the Transaction Service and its Service resource.
- `kubectl apply -f deployments/k8s/local/microservices/api-gateway.yaml`: deploys the API Gateway and its Service resource.
- `kubectl apply -f deployments/k8s/local/microservices/resource-management-fixed.yaml`: applies the fixed-replica microservices ResourceQuota and HPA-disabled resource configuration.
- `kubectl apply -f deployments/k8s/local/microservices/api-gateway-ingress.yaml`: applies ingress for the API Gateway.
- `kubectl rollout status deployment/...`: waits until each microservice Deployment is available.
- `kubectl get pods,svc,hpa,resourcequota -n msa`: gives a quick summary of microservices runtime state.
- `kubectl logs job/... -n msa`: shows migration logs for troubleshooting.

For HPA mode, swap the resource-management manifest:

```bash
kubectl apply -f deployments/k8s/local/microservices/resource-management-hpa.yaml
```

This HPA manifest uses a `60s` scale-down stabilization window so replica
counts fall back to baseline faster after benchmark traffic stops.

Access API Gateway:

```bash
kubectl port-forward svc/api-gateway -n msa 8080:8080
curl -i http://localhost:8080/healthz
```

Command notes:

- `kubectl port-forward svc/api-gateway ...`: exposes the API Gateway Service on the local machine.
- `curl -i http://localhost:8080/healthz`: verifies that the gateway HTTP endpoint is responding.

### 23.6 Ingress access

Start the tunnel:

```bash
minikube tunnel
```

Command notes:

- `minikube tunnel`: enables local access to Kubernetes LoadBalancer and ingress routes.

Add these local hosts:

```text
127.0.0.1 monolith.skripsi.local
127.0.0.1 api.skripsi.local
```

Then access:

```bash
curl -i http://monolith.skripsi.local/healthz
curl -i http://api.skripsi.local/healthz
```

Command notes:

- each `curl -i .../healthz`: verifies ingress-based access for the monolith or API Gateway.

---

## 24. Kubernetes Job List

Recommended Kubernetes Jobs:

```text
deployments/k8s/
├── local/
│   └── shared/
│       └── db-bootstrap-job.yaml
├── benchmark/
│   ├── namespace.yaml
│   ├── k6-runner-rbac.yaml
│   ├── k6-benchmark-monolith-job.yaml
│   ├── k6-benchmark-microservices-job.yaml
│   └── k6-runner-secret.example.yaml
│   ├── monolith/
│   │   └── db-bootstrap-job.yaml
│   └── microservices/
│       └── db-bootstrap-job.yaml
├── eks/
│   ├── monolith/
│   │   ├── migration-job.yaml
│   │   ├── reset-monolith-data-job.yaml
│   │   ├── seed-monolith-smoke-data-job.yaml
│   │   ├── seed-monolith-benchmark-data-job.yaml
│   │   ├── prepare-monolith-enrichment-smoke-data-job.yaml
│   │   └── prepare-monolith-enrichment-benchmark-data-job.yaml
│   └── microservices/
│       ├── auth-migration-job.yaml
│       ├── item-migration-job.yaml
│       ├── transaction-migration-job.yaml
│       ├── reset-microservices-data-job.yaml
│       ├── seed-microservices-smoke-data-job.yaml
│       ├── seed-microservices-benchmark-data-job.yaml
│       ├── prepare-microservices-enrichment-smoke-data-job.yaml
│       └── prepare-microservices-enrichment-benchmark-data-job.yaml
├── monolith/
│   ├── migration-job.yaml
│   ├── prepare-monolith-enrichment-smoke-data-job.yaml
│   ├── prepare-monolith-enrichment-benchmark-data-job.yaml
│   ├── reset-monolith-data-job.yaml
│   ├── seed-monolith-smoke-data-job.yaml
│   └── seed-monolith-benchmark-data-job.yaml
└── microservices/
    ├── auth-migration-job.yaml
    ├── item-migration-job.yaml
    ├── prepare-microservices-enrichment-smoke-data-job.yaml
    ├── prepare-microservices-enrichment-benchmark-data-job.yaml
    ├── transaction-migration-job.yaml
    ├── reset-microservices-data-job.yaml
    ├── seed-microservices-smoke-data-job.yaml
    └── seed-microservices-benchmark-data-job.yaml
```

Job responsibilities:

| Job | Responsibility |
|---|---|
| `db-bootstrap-job` | create internal PostgreSQL databases |
| `monolith-migration-job` | migrate `mono_db` |
| `auth-migration-job` | migrate `auth_db` |
| `item-migration-job` | migrate `item_db` |
| `transaction-migration-job` | migrate `transaction_db` |
| `reset-monolith-data-job` | clear mutable monolith benchmark data |
| `seed-monolith-smoke-data-job` | seed small deterministic monolith smoke data |
| `seed-monolith-benchmark-data-job` | seed deterministic monolith benchmark data |
| `prepare-monolith-enrichment-smoke-data-job` | prepare monolith smoke enriched-read fixtures |
| `prepare-monolith-enrichment-benchmark-data-job` | prepare monolith benchmark enriched-read fixtures |
| `reset-microservices-data-job` | clear mutable microservices benchmark data |
| `seed-microservices-smoke-data-job` | seed small deterministic microservices smoke data |
| `seed-microservices-benchmark-data-job` | seed deterministic microservices benchmark data |
| `prepare-microservices-enrichment-smoke-data-job` | prepare microservices smoke enriched-read fixtures |
| `prepare-microservices-enrichment-benchmark-data-job` | prepare microservices benchmark enriched-read fixtures |
| `k6-benchmark-monolith-job` | run monolith benchmark and upload results |
| `k6-benchmark-microservices-job` | run microservices benchmark and upload results |

---

## 25. Kubernetes Secret List

Recommended Kubernetes Secrets:

```text
local-database namespace:
- db-bootstrap-env

mono namespace:
- monolith-env

msa namespace:
- api-gateway-secret
- auth-service-secret
- item-service-secret
- transaction-service-secret

benchmark namespace:
- k6-runner-secret
```

Secret purposes:

| Secret | Purpose |
|---|---|
| `db-bootstrap-env` | contains `BOOTSTRAP_DATABASE_URL` |
| `monolith-env` | contains monolith app config and `DATABASE_URL` |
| `api-gateway-secret` | contains gateway config and `JWT_SECRET` |
| `auth-service-secret` | contains auth DB URL and `JWT_SECRET` |
| `item-service-secret` | contains item DB URL |
| `transaction-service-secret` | contains transaction DB URL and service addresses |
| `k6-runner-secret` | contains optional benchmark admin credentials for enriched reads |

Do not store static AWS access keys in any Kubernetes Secret.

---

## 26. Local Persistence And Cleanup Rules

For local validation, stopping compute is not always the same as deleting data.

Quick rule:

```text
Stop:
usually keep data

Delete / down -v / delete PVC:
remove data
```

Important local behaviors:

- `minikube stop` stops the local cluster runtime but usually keeps PVC-backed
  PostgreSQL data.
- `minikube delete` should be treated as a full local cluster reset.
- deleting a completed Kubernetes Job removes only the Job object, not the
  database, schema, or CRUD data it already created.
- deleting the monolith `Deployment` removes app pods only; PostgreSQL data
  remains if the PostgreSQL PVC is still present.
- `docker compose ... down` stops containers and keeps Compose volumes unless
  `-v` is added.
- `docker compose ... down -v` removes the Compose PostgreSQL volume and deletes
  local Compose data.
- the current `make compose-down` target is destructive for local Compose data
  because it uses `down -v`.

Operational detail:

```text
The local operational guide for step verification, stop options,
and cleanup commands is docs/development/run-monolith-local.md.
```

---

## 27. What Counts as Final Result

Final result source:

```text
AWS EKS benchmark runs only
```

Not final result:

```text
Docker Compose result
Minikube result
local Go run result
```

Docker Compose and Minikube results may be used only for:

```text
- debugging
- validation
- dry-run evidence
- implementation confidence
```

---

## 28. Result Storage

Final benchmark results must be uploaded to S3 before destroying infrastructure.

Recommended S3 prefix:

```text
experiments/{run_id}/{architecture}/{scenario_name}/{target_rps}rps/{attempt}/
```

Example:

```text
experiments/20260512-103000/monolith/login/1000rps/attempt-01/
experiments/20260512-103000/monolith/login/1000rps/attempt-02/
experiments/20260512-103000/microservices/create-transaction/2500rps/attempt-01/
```

`scenario_name` should use the k6 script basename without `.js`, for example:

```text
k6/scripts/login.js -> login
k6/scripts/create-transaction.js -> create-transaction
```

Each k6 execution must upload to a unique attempt folder. Raw attempt output
must stay separated during collection; aggregation should happen later during
analysis.

Expected files:

```text
summary.json
raw.json.gz
metadata.json
stdout.log
result-status.json
k6-options.json
thresholds.json
```

When Datadog is enabled, also collect:

```text
datadog-time-window.json
```

Do not run `terraform destroy` before verifying result files in S3.

Detailed benchmark lifecycle and S3 naming policy:

```text
docs/infrastructure/benchmark-execution-lifecycle.md
```

---

## 29. Summary

Final deployment strategy:

```text
Docker Compose:
local development and functional validation

Minikube:
local Kubernetes dry-run

AWS EKS:
final benchmark environment
```

Final execution strategy:

```text
Terraform provisions AWS infrastructure.
Kubernetes Secret injects sensitive configuration.
DB Bootstrap Job creates internal PostgreSQL databases.
Migration Jobs create schemas using Goose.
Seed Jobs insert benchmark datasets.
Application runs as Deployment.
k6 runs as benchmark Job.
Results are uploaded to S3.
Only EKS results are used as final thesis data.
```

This layered strategy keeps development simple while preserving a reliable final experimental environment.
