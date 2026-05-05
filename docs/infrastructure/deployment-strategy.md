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
    ├── docker-compose.microservices.yml
    └── docker-compose.full.yml
```

File responsibilities:

| File | Purpose |
|---|---|
| `docker-compose.db.yml` | local PostgreSQL only |
| `docker-compose.monolith.yml` | PostgreSQL + monolith |
| `docker-compose.microservices.yml` | PostgreSQL + microservices |
| `docker-compose.full.yml` | optional all-in-one local stack |

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
make seed-monolith
make run-monolith
```

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
make seed-microservices
```

---

## 8. Minikube Strategy

Minikube is used after Docker Compose works.

Recommended purpose:

```text
Kubernetes validation only
```

Recommended local cluster:

```bash
minikube start --driver=docker --cpus=4 --memory=6144 --disk-size=20g
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
deployments/k8s/local/postgres.yaml
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
docker build -t skripsi/monolith:local ./monolith
minikube image load skripsi/monolith:local
```

For microservices:

```bash
docker build -t skripsi/api-gateway:local ./microservices/api-gateway
docker build -t skripsi/auth-service:local ./microservices/auth-service
docker build -t skripsi/item-service:local ./microservices/item-service
docker build -t skripsi/transaction-service:local ./microservices/transaction-service

minikube image load skripsi/api-gateway:local
minikube image load skripsi/auth-service:local
minikube image load skripsi/item-service:local
minikube image load skripsi/transaction-service:local
```

Set local Kubernetes manifests to:

```yaml
imagePullPolicy: IfNotPresent
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
db-bootstrap-secret
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
seed-monolith-job
```

Microservices:

```text
seed-microservices-job
```

Seed jobs should run after migration jobs and before benchmark execution.

Seed scripts must capture database-generated UUIDs using:

```sql
INSERT ... RETURNING id
```

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
- export Kubernetes snapshots
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
Create namespace mono
    |
    v
Create monolith-secret
    |
    v
Run db-bootstrap-job if not already completed
    |
    v
Run monolith-migration-job
    |
    v
Run seed-monolith-job
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
1. Create namespace mono.
2. Create monolith-secret.
3. Run db-bootstrap-job.
4. Wait until db-bootstrap-job is complete.
5. Run monolith-migration-job.
6. Wait until monolith-migration-job is complete.
7. Run seed-monolith-job.
8. Wait until seed-monolith-job is complete.
9. Deploy monolith application.
10. Apply ResourceQuota and HPA.
11. Validate deployment readiness.
12. Run k6 benchmark Job.
13. Upload benchmark results to S3.
```

---

## 20. Microservices Deployment Flow

```text
Create namespace msa
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
Run seed-microservices-job
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
1. Create namespace msa.
2. Create api-gateway-secret.
3. Create auth-service-secret.
4. Create item-service-secret.
5. Create transaction-service-secret.
6. Run db-bootstrap-job.
7. Wait until db-bootstrap-job is complete.
8. Run auth-migration-job.
9. Run item-migration-job.
10. Run transaction-migration-job.
11. Wait until all migration jobs are complete.
12. Run seed-microservices-job.
13. Wait until seed-microservices-job is complete.
14. Deploy Auth Service.
15. Deploy Item Service.
16. Deploy Transaction Service.
17. Deploy API Gateway.
18. Apply ResourceQuota and HPAs.
19. Validate all service readiness.
20. Run k6 benchmark Job.
21. Upload benchmark results to S3.
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

make seed-monolith
make seed-microservices

make reset-monolith
make reset-microservices

make minikube-start
make minikube-load-images
make minikube-deploy-monolith
make minikube-deploy-microservices

make create-local-secrets
make db-bootstrap
make deploy-monolith
make deploy-microservices
make run-k6-job

make eks-apply
make eks-destroy
```

The Makefile should not hide undocumented experiment behavior.

Critical experiment behavior must be documented.

---

## 23. Kubernetes Job List

Recommended Kubernetes Jobs:

```text
deployments/k8s/jobs/
├── db-bootstrap-job.yaml
├── monolith-migration-job.yaml
├── auth-migration-job.yaml
├── item-migration-job.yaml
├── transaction-migration-job.yaml
├── seed-monolith-job.yaml
├── seed-microservices-job.yaml
└── k6-benchmark-job.yaml
```

Job responsibilities:

| Job | Responsibility |
|---|---|
| `db-bootstrap-job` | create internal PostgreSQL databases |
| `monolith-migration-job` | migrate `mono_db` |
| `auth-migration-job` | migrate `auth_db` |
| `item-migration-job` | migrate `item_db` |
| `transaction-migration-job` | migrate `transaction_db` |
| `seed-monolith-job` | seed monolith benchmark data |
| `seed-microservices-job` | seed microservices benchmark data |
| `k6-benchmark-job` | run benchmark and upload results |

---

## 24. Kubernetes Secret List

Recommended Kubernetes Secrets:

```text
benchmark namespace:
- db-bootstrap-secret
- k6-runner-secret

mono namespace:
- monolith-secret

msa namespace:
- api-gateway-secret
- auth-service-secret
- item-service-secret
- transaction-service-secret
```

Secret purposes:

| Secret | Purpose |
|---|---|
| `db-bootstrap-secret` | contains `BOOTSTRAP_DATABASE_URL` |
| `monolith-secret` | contains monolith app config and `DATABASE_URL` |
| `api-gateway-secret` | contains gateway config and `JWT_SECRET` |
| `auth-service-secret` | contains auth DB URL and `JWT_SECRET` |
| `item-service-secret` | contains item DB URL |
| `transaction-service-secret` | contains transaction DB URL and service addresses |
| `k6-runner-secret` | contains benchmark credentials such as `AUTH_TOKEN` if needed |

Do not store static AWS access keys in any Kubernetes Secret.

---

## 25. What Counts as Final Result

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

## 26. Result Storage

Final benchmark results must be uploaded to S3 before destroying infrastructure.

Recommended S3 prefix:

```text
experiments/{run_id}/{architecture}/{scenario}/{target_rps}rps/
```

Example:

```text
experiments/2026-05-05T120000Z/monolith/login/1000rps/
```

Expected files:

```text
summary.json
raw.json.gz
metadata.json
stdout.log
hpa-state.yaml
pods-state.txt
top-pods.txt
top-nodes.txt
events.txt
```

Do not run `terraform destroy` before verifying result files in S3.

---

## 27. Summary

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
