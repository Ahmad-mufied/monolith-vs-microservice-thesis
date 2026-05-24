# Parallel Benchmark Runbook

## 1. Purpose

Step-by-step operational guide for running the benchmark experiment on two
isolated EKS clusters simultaneously.

This runbook covers the full experiment lifecycle from infrastructure
provisioning to result verification and teardown.

---

## 2. Prerequisites

```text
- Both EKS clusters provisioned (see docs/infrastructure/terraform-runbook.md)
- kubectl contexts configured: monolith, msa
- Kubernetes Secrets created in both clusters
- ECR images built and pushed (`make ecr-push-all`)
- Datadog installed on both clusters
- S3 bucket available
```

---

## 3. Experiment Lifecycle Overview

```text
build/push images
    ↓
patch EKS manifests with IMAGE_TAG
    ↓
terraform apply (shared + experiment)
    ↓
configure kubectl contexts
    ↓
create Kubernetes Secrets in both clusters
    ↓
deploy applications
    ↓
install Datadog on both clusters
    ↓
for each scenario:
    reset data
    seed data
    [prepare enrichment data if enriched-transactions]
    run parallel k6 jobs
    verify S3 results
    ↓
aws login
    ↓
make terraform-auth-check
    ↓
make eks-destroy (after all results verified in S3)
```

---

## 4. Scaling Mode Selection

Choose scaling mode before deploying:

| Goal | Scaling mode | K6_PROFILE |
|---|---|---|
| RQ1 clean comparison | `fixed` | `steady` |
| RQ2 + HPA behavior | `hpa` | `hpa` |

Deploy with the selected mode:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)

# Fixed replica (default)
SCALING_MODE=fixed make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
SCALING_MODE=fixed make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG

# HPA mode
# metrics-server is installed automatically by the deploy scripts in HPA mode
# default installer pins a metrics-server release and keeps kubelet TLS verification enabled
SCALING_MODE=hpa make eks-deploy-monolith IMAGE_TAG=$IMAGE_TAG
SCALING_MODE=hpa make eks-deploy-msa IMAGE_TAG=$IMAGE_TAG
```

Important rule:

- changing `SCALING_MODE` in `make run-benchmark-parallel` does **not** switch
  the live application manifests
- every `fixed <-> hpa` transition must be handled as a fresh redeploy event

Verify the live mode after redeploy:

```bash
kubectl --context=monolith get hpa -n mono
kubectl --context=msa get hpa -n msa
kubectl --context=monolith get deploy -n mono
kubectl --context=msa get deploy -n msa
```

Expected checks:

- fixed mode:
  - no HPA objects in `mono` or `msa`
  - monolith deployment at `1`
  - each MSA deployment at `1`
- HPA mode:
  - HPA objects present
  - baseline deployments typically start at `1` and scale during load

---

## 5. Scenario: Login

```bash
# Reset and seed (both clusters)
kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/reset-monolith-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/reset-monolith-data-job -n mono --timeout=120s

kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/reset-microservices-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/reset-microservices-data-job -n msa --timeout=120s

kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f deployments/k8s/eks/monolith/seed-monolith-benchmark-data-job.yaml
kubectl --context=monolith wait --for=condition=complete job/seed-monolith-benchmark-data-job -n mono --timeout=300s

kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f deployments/k8s/eks/microservices/seed-microservices-benchmark-data-job.yaml
kubectl --context=msa wait --for=condition=complete job/seed-microservices-benchmark-data-job -n msa --timeout=300s

# Run parallel benchmark
make run-benchmark-parallel \
  SCENARIO=login \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

Do not start this step immediately after an HPA run unless the stack has been
redeployed back to fixed mode and validated.

---

## 6. Scenario: Create Transaction

Same reset and seed steps as login, then:

```bash
make run-benchmark-parallel \
  SCENARIO=create-transaction \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

---

## 7. Scenario: Enriched Transactions

Requires enrichment data preparation after base seed:

```bash
# After reset and seed (same as above), prepare enrichment data
make eks-prepare-enrichment-benchmark

# Run parallel benchmark
make run-benchmark-parallel \
  SCENARIO=enriched-transactions \
  TARGET_RPS=1000 \
  RUN_ID=eks-run-001 \
  ATTEMPT=attempt-01 \
  S3_BUCKET=<bucket>
```

---

## 8. Multiple RPS Levels

Repeat the run for each target RPS level. Reset and seed before each run
for scenarios that mutate data (create-transaction).

```bash
for rps in 1000 2500 5000; do
  # Reset and seed (for create-transaction)
  # ... (reset/seed commands) ...

  make run-benchmark-parallel \
    SCENARIO=create-transaction \
    TARGET_RPS=$rps \
    RUN_ID=eks-run-001 \
    ATTEMPT=attempt-01 \
    S3_BUCKET=<bucket>
done
```

For login and enriched-transactions, reset and seed only once before the
first RPS level since they do not mutate data.

---

## 9. Verify S3 Results

After each run:

```bash
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive | grep summary.json
```

Expected output:

```text
experiments/eks-run-001/monolith/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/microservices/login/1000rps/attempt-01/summary.json
experiments/eks-run-001/monolith/create-transaction/1000rps/attempt-01/summary.json
experiments/eks-run-001/microservices/create-transaction/1000rps/attempt-01/summary.json
...
```

---

## 10. Datadog Time Window Alignment

After each parallel run, verify that both `datadog-time-window.json` files
have timestamps within 30 seconds of each other:

```bash
aws s3 cp s3://<bucket>/experiments/eks-run-001/monolith/login/1000rps/attempt-01/datadog-time-window.json - | jq .time_window_start
aws s3 cp s3://<bucket>/experiments/eks-run-001/microservices/login/1000rps/attempt-01/datadog-time-window.json - | jq .time_window_start
```

If the gap is > 30 seconds, the Datadog time-series comparison may not be
perfectly aligned. This is acceptable for analysis but should be noted.

---

## 11. Destroy Infrastructure

Only destroy after all planned runs are complete and all S3 results are
verified.

```bash
# Verify all expected files exist
aws s3 ls s3://<bucket>/experiments/eks-run-001/ --recursive | wc -l

# Verify Terraform-compatible AWS auth
make terraform-auth-check

# Destroy clusters and RDS
make eks-destroy

# Destroy shared resources only when fully done with all experiments
# make eks-shared-destroy
```

Do not destroy shared resources if another experiment run is planned soon.
ECR images and S3 results are preserved after cluster destroy.

---

## 12. Metadata Recording

Each run must record the scaling mode in `RESOURCES_CONFIGURATION_JSON`
when calling `run-benchmark-parallel.sh`. The deploy scripts set this
automatically based on `SCALING_MODE`.

Example for fixed mode:

```json
{
  "autoscaling_mode": "fixed",
  "hpa_enabled": false,
  "namespace_resource_quota": { "cpu": "4000m", "memory": "4096Mi" },
  "services": {
    "api-gateway": { "cpu_request": "100m", "cpu_limit": "250m", "replica_count": 1 },
    "auth-service": { "cpu_request": "250m", "cpu_limit": "1000m", "replica_count": 1 },
    "item-service": { "cpu_request": "100m", "cpu_limit": "250m", "replica_count": 1 },
    "transaction-service": { "cpu_request": "150m", "cpu_limit": "500m", "replica_count": 1 }
  }
}
```

Example for HPA mode:

```json
{
  "autoscaling_mode": "hpa",
  "hpa_enabled": true,
  "namespace_resource_quota": { "cpu": "4000m", "memory": "4096Mi" },
  "services": {
    "api-gateway": { "min_replicas": 1, "max_replicas": 9, "target_cpu_utilization": 70 },
    "auth-service": { "min_replicas": 1, "max_replicas": 3, "target_cpu_utilization": 70 },
    "item-service": { "min_replicas": 1, "max_replicas": 9, "target_cpu_utilization": 70 },
    "transaction-service": { "min_replicas": 1, "max_replicas": 5, "target_cpu_utilization": 70 }
  }
}
```

This is written to `metadata.json` and uploaded to S3 with each attempt.

---

## 13. Recovery: HPA to Fixed Transition

If a fixed-mode deploy is attempted while the MSA stack is still expanded by
HPA, migration jobs may be blocked by the namespace `ResourceQuota`.

Observed symptom:

```text
exceeded quota: msa-resource-quota, requested: limits.cpu=100m, used: limits.cpu=4, limited: limits.cpu=4
```

Recovery sequence:

```bash
# stop invalid benchmark jobs
kubectl --context=monolith delete job k6-benchmark-monolith -n benchmark --ignore-not-found
kubectl --context=msa delete job k6-benchmark-microservices -n benchmark --ignore-not-found

# clear stale HPA state on MSA
kubectl --context=msa delete hpa --all -n msa
kubectl --context=msa scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa

# clear stuck migration jobs if they already exist
kubectl --context=msa delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found

# rerun fixed deploy
SCALING_MODE=fixed make eks-deploy-msa
```
