# EKS Debug Command Reference

## Purpose

Operator-focused reference for the AWS CLI and `kubectl` commands that are
most useful while deploying, monitoring, debugging, and recovering the EKS
benchmark environment.

Use this document when:

- deployments are not becoming ready,
- migration, reset, seed, preparation, or k6 jobs are failing,
- pods are CrashLooping or Pending,
- HPA behavior looks wrong,
- Terraform or `kubectl` symptoms need a live AWS cross-check.

This is a command cheat sheet, not the primary lifecycle runbook. For the full
experiment sequence, use:

- `docs/infrastructure/terraform-runbook.md`
- `docs/infrastructure/benchmark-runbook-end-to-end.md`
- `docs/infrastructure/parallel-benchmark-runbook.md`

---

## Safety Notes

Most commands below are read-only. The commands that change cluster state are
called out explicitly and should be used deliberately:

- `kubectl delete job ...`
- `kubectl apply -f ...`
- `kubectl rollout restart ...`
- `kubectl scale deployment ...`

Prefer this order during incidents:

1. inspect,
2. confirm the failing resource,
3. read logs and events,
4. only then rerun or restart.

---

## Contexts, Namespaces, and Main Resource Names

Kubernetes contexts:

- `monolith`
- `msa`

Namespaces:

- `mono` for monolith application resources
- `msa` for microservices application resources
- `benchmark` for k6 runner and DB bootstrap jobs
- `datadog` for Datadog Agent and Cluster Agent

Main deployments:

- monolith: `deployment/monolith`
- microservices:
  - `deployment/api-gateway`
  - `deployment/auth-service`
  - `deployment/item-service`
  - `deployment/transaction-service`

Main EKS jobs used in this repository:

- monolith:
  - `job/monolith-migration-job`
  - `job/reset-monolith-data-job`
  - `job/seed-monolith-benchmark-data-job`
  - `job/prepare-monolith-enrichment-benchmark-data-job`
- microservices:
  - `job/auth-migration-job`
  - `job/item-migration-job`
  - `job/transaction-migration-job`
  - `job/reset-microservices-data-job`
  - `job/seed-microservices-benchmark-data-job`
  - `job/prepare-microservices-enrichment-benchmark-data-job`
- benchmark:
  - `job/k6-benchmark-monolith`
  - `job/k6-benchmark-microservices`

---

## Fast Cluster Checks

Check that both clusters and the important namespaces are reachable:

```bash
kubectl --context=monolith get nodes
kubectl --context=msa get nodes

kubectl --context=monolith get ns
kubectl --context=msa get ns
```

Get a quick runtime summary:

```bash
kubectl --context=monolith get pods,svc,hpa,resourcequota -n mono
kubectl --context=monolith get jobs -n mono
kubectl --context=monolith get jobs -n benchmark

kubectl --context=msa get pods,svc,hpa,resourcequota -n msa
kubectl --context=msa get jobs -n msa
kubectl --context=msa get jobs -n benchmark
```

Get the newest events first:

```bash
kubectl --context=monolith get events -A --sort-by=.metadata.creationTimestamp
kubectl --context=msa get events -A --sort-by=.metadata.creationTimestamp
```

Check resource consumption if Metrics Server is installed:

```bash
kubectl --context=monolith top nodes
kubectl --context=monolith top pods -A

kubectl --context=msa top nodes
kubectl --context=msa top pods -A
```

---

## Deployment Troubleshooting

### Monolith

Check rollout and pod placement:

```bash
kubectl --context=monolith rollout status deployment/monolith -n mono --timeout=300s
kubectl --context=monolith get deployment monolith -n mono
kubectl --context=monolith get pods -n mono -o wide
kubectl --context=monolith describe deployment monolith -n mono
kubectl --context=monolith describe pod -n mono -l app=monolith
```

Read application logs:

```bash
kubectl --context=monolith logs deploy/monolith -n mono --tail=100
kubectl --context=monolith logs deploy/monolith -n mono --previous --tail=100
```

Safe operator actions when the deployment object exists but the pods need a new
start:

```bash
kubectl --context=monolith rollout restart deployment/monolith -n mono
kubectl --context=monolith rollout status deployment/monolith -n mono --timeout=300s
```

### Microservices

Check all service rollouts:

```bash
kubectl --context=msa rollout status deployment/api-gateway -n msa --timeout=300s
kubectl --context=msa rollout status deployment/auth-service -n msa --timeout=300s
kubectl --context=msa rollout status deployment/item-service -n msa --timeout=300s
kubectl --context=msa rollout status deployment/transaction-service -n msa --timeout=300s
```

Get a compact deployment and pod summary:

```bash
kubectl --context=msa get deployment -n msa
kubectl --context=msa get pods -n msa -o wide
kubectl --context=msa describe deployment api-gateway -n msa
kubectl --context=msa describe deployment auth-service -n msa
kubectl --context=msa describe deployment item-service -n msa
kubectl --context=msa describe deployment transaction-service -n msa
```

Read service logs:

```bash
kubectl --context=msa logs deploy/api-gateway -n msa --tail=100
kubectl --context=msa logs deploy/auth-service -n msa --tail=100
kubectl --context=msa logs deploy/item-service -n msa --tail=100
kubectl --context=msa logs deploy/transaction-service -n msa --tail=100
```

Read previous container logs after a crash:

```bash
kubectl --context=msa logs deploy/api-gateway -n msa --previous --tail=100
kubectl --context=msa logs deploy/transaction-service -n msa --previous --tail=100
```

Restart one or all services:

```bash
kubectl --context=msa rollout restart deployment/api-gateway -n msa
kubectl --context=msa rollout restart deployment/auth-service -n msa
kubectl --context=msa rollout restart deployment/item-service -n msa
kubectl --context=msa rollout restart deployment/transaction-service -n msa
```

### Common deployment failure checks

Pending or unschedulable pods:

```bash
kubectl --context=monolith describe pod -n mono -l app=monolith
kubectl --context=msa describe pod -n msa -l app=api-gateway
kubectl --context=msa describe pod -n msa -l app=transaction-service
```

Missing secrets or config:

```bash
kubectl --context=monolith get secrets -n mono
kubectl --context=msa get secrets -n msa
kubectl --context=monolith get secret monolith-env -n mono -o yaml
kubectl --context=msa get secret api-gateway-secret -n msa -o yaml
```

Image or pull-policy issues:

```bash
kubectl --context=monolith get pod -n mono -o jsonpath='{range .items[*]}{.metadata.name}{"  ->  "}{.spec.containers[*].image}{"\n"}{end}'
kubectl --context=msa get pod -n msa -o jsonpath='{range .items[*]}{.metadata.name}{"  ->  "}{.spec.containers[*].image}{"\n"}{end}'
```

ResourceQuota and HPA pressure:

```bash
kubectl --context=monolith get resourcequota -n mono
kubectl --context=monolith get hpa -n mono

kubectl --context=msa get resourcequota -n msa
kubectl --context=msa get hpa -n msa
kubectl --context=msa describe hpa api-gateway -n msa
kubectl --context=msa describe hpa transaction-service -n msa
```

---

## Job Troubleshooting

### Inspect job status and logs

Get job summaries:

```bash
kubectl --context=monolith get jobs -n mono
kubectl --context=monolith get jobs -n benchmark

kubectl --context=msa get jobs -n msa
kubectl --context=msa get jobs -n benchmark
```

Inspect a specific job:

```bash
kubectl --context=monolith describe job monolith-migration-job -n mono
kubectl --context=msa describe job transaction-migration-job -n msa
kubectl --context=monolith get pods -n mono -l job-name=monolith-migration-job
kubectl --context=msa get pods -n msa -l job-name=transaction-migration-job
```

Read job logs:

```bash
kubectl --context=monolith logs job/monolith-migration-job -n mono
kubectl --context=monolith logs job/reset-monolith-data-job -n mono
kubectl --context=monolith logs job/seed-monolith-benchmark-data-job -n mono
kubectl --context=monolith logs job/prepare-monolith-enrichment-benchmark-data-job -n mono
kubectl --context=monolith logs job/k6-benchmark-monolith -n benchmark

kubectl --context=msa logs job/auth-migration-job -n msa
kubectl --context=msa logs job/item-migration-job -n msa
kubectl --context=msa logs job/transaction-migration-job -n msa
kubectl --context=msa logs job/reset-microservices-data-job -n msa
kubectl --context=msa logs job/seed-microservices-benchmark-data-job -n msa
kubectl --context=msa logs job/prepare-microservices-enrichment-benchmark-data-job -n msa
kubectl --context=msa logs job/k6-benchmark-microservices -n benchmark
```

Wait for completion:

```bash
kubectl --context=monolith wait --for=condition=complete job/monolith-migration-job -n mono --timeout=300s
kubectl --context=msa wait --for=condition=complete job/auth-migration-job -n msa --timeout=300s
kubectl --context=msa wait --for=condition=complete job/item-migration-job -n msa --timeout=300s
kubectl --context=msa wait --for=condition=complete job/transaction-migration-job -n msa --timeout=300s
```

### Rerun a job cleanly

For EKS job manifests, render the manifests first so image placeholders and
benchmark metadata are resolved correctly:

```bash
IMAGE_TAG=$(git rev-parse --short HEAD)
RENDER_ROOT="$(IMAGE_TAG="$IMAGE_TAG" AWS_REGION=ap-southeast-1 ECR_NAMESPACE=skripsi bash scripts/render-eks-manifests.sh)"

RENDERED_EKS_MONOLITH_DIR="$RENDER_ROOT/deployments/k8s/eks/monolith"
RENDERED_EKS_MICROSERVICES_DIR="$RENDER_ROOT/deployments/k8s/eks/microservices"
RENDERED_BENCHMARK_DIR="$RENDER_ROOT/deployments/k8s/benchmark"
```

If you already know the exact `IMAGE_TAG` used in the current deployment, use
that same tag here rather than a newer Git `HEAD`.

Monolith migration, reset, seed, and enrichment preparation:

```bash
kubectl --context=monolith delete job monolith-migration-job -n mono --ignore-not-found
kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/migration-job.yaml"

kubectl --context=monolith delete job reset-monolith-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/reset-monolith-data-job.yaml"

kubectl --context=monolith delete job seed-monolith-benchmark-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/seed-monolith-benchmark-data-job.yaml"

kubectl --context=monolith delete job prepare-monolith-enrichment-benchmark-data-job -n mono --ignore-not-found
kubectl --context=monolith apply -f "$RENDERED_EKS_MONOLITH_DIR/prepare-monolith-enrichment-benchmark-data-job.yaml"
```

Microservices migration, reset, seed, and enrichment preparation:

```bash
kubectl --context=msa delete job auth-migration-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/auth-migration-job.yaml"

kubectl --context=msa delete job item-migration-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/item-migration-job.yaml"

kubectl --context=msa delete job transaction-migration-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/transaction-migration-job.yaml"

kubectl --context=msa delete job reset-microservices-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/reset-microservices-data-job.yaml"

kubectl --context=msa delete job seed-microservices-benchmark-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/seed-microservices-benchmark-data-job.yaml"

kubectl --context=msa delete job prepare-microservices-enrichment-benchmark-data-job -n msa --ignore-not-found
kubectl --context=msa apply -f "$RENDERED_EKS_MICROSERVICES_DIR/prepare-microservices-enrichment-benchmark-data-job.yaml"
```

Benchmark jobs:

```bash
kubectl --context=monolith delete job k6-benchmark-monolith -n benchmark --ignore-not-found
kubectl --context=msa delete job k6-benchmark-microservices -n benchmark --ignore-not-found
```

For k6 benchmark job creation, prefer the repository runner instead of applying
benchmark manifests by hand, because the runner injects the rendered image URI,
scenario metadata, S3 target prefix, and timing parameters:

```bash
make run-benchmark-parallel SCENARIO=login TARGET_RPS=1000 RUN_ID=<run-id> S3_BUCKET=<bucket>
```

### Common job failure checks

Jobs rejected by ResourceQuota during HPA mode:

```bash
kubectl --context=msa get hpa -n msa
kubectl --context=msa get resourcequota -n msa
kubectl --context=msa describe resourcequota msa-resource-quota -n msa
```

If you intentionally need to clear HPA pressure before rerunning migration
jobs:

```bash
kubectl --context=msa delete hpa --all -n msa
kubectl --context=msa scale deployment api-gateway auth-service item-service transaction-service --replicas=1 -n msa
kubectl --context=msa delete job auth-migration-job item-migration-job transaction-migration-job -n msa --ignore-not-found
```

Inspect the pod created by a failing job:

```bash
kubectl --context=monolith get pods -n mono -l job-name=monolith-migration-job -o wide
kubectl --context=msa get pods -n msa -l job-name=transaction-migration-job -o wide
kubectl --context=monolith describe pod -n mono -l job-name=monolith-migration-job
kubectl --context=msa describe pod -n msa -l job-name=transaction-migration-job
```

---

## Datadog and Benchmark Support Checks

Datadog Agent health:

```bash
kubectl --context=monolith get pods -n datadog
kubectl --context=monolith get daemonset -n datadog
kubectl --context=monolith rollout status daemonset/datadog -n datadog --timeout=300s
kubectl --context=monolith logs -n datadog -l app=datadog --tail=100

kubectl --context=msa get pods -n datadog
kubectl --context=msa get daemonset -n datadog
kubectl --context=msa rollout status daemonset/datadog -n datadog --timeout=300s
kubectl --context=msa logs -n datadog -l app=datadog --tail=100
```

Benchmark job pod inspection:

```bash
kubectl --context=monolith get pods -n benchmark -l job-name=k6-benchmark-monolith -o wide
kubectl --context=msa get pods -n benchmark -l job-name=k6-benchmark-microservices -o wide
kubectl --context=monolith describe job k6-benchmark-monolith -n benchmark
kubectl --context=msa describe job k6-benchmark-microservices -n benchmark
```

---

## AWS CLI Cross-Checks

### EKS control plane and node groups

```bash
AWS_PROFILE=terraform-process aws eks describe-cluster \
  --region ap-southeast-1 \
  --name skripsi-monolith \
  --query 'cluster.{status:status,version:version,endpoint:endpoint}' \
  --output table

AWS_PROFILE=terraform-process aws eks describe-cluster \
  --region ap-southeast-1 \
  --name skripsi-msa \
  --query 'cluster.{status:status,version:version,endpoint:endpoint}' \
  --output table

AWS_PROFILE=terraform-process aws eks list-nodegroups \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --output text

AWS_PROFILE=terraform-process aws eks describe-nodegroup \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --nodegroup-name <node-group-name> \
  --query '{status:nodegroup.status,health:nodegroup.health,scaling:nodegroup.scalingConfig,resources:nodegroup.resources}' \
  --output json
```

Check add-ons:

```bash
AWS_PROFILE=terraform-process aws eks list-addons \
  --region ap-southeast-1 \
  --cluster-name skripsi-monolith

AWS_PROFILE=terraform-process aws eks describe-addon \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --addon-name eks-pod-identity-agent \
  --query 'addon.{status:status,version:addonVersion,health:health}' \
  --output json
```

### Auto Scaling Groups behind EKS node groups

Useful when nodes are not joining, node group creation is stuck, or Terraform
shows `IN_PROGRESS` for too long.

```bash
AWS_PROFILE=terraform-process aws autoscaling describe-auto-scaling-groups \
  --region ap-southeast-1 \
  --auto-scaling-group-names <asg-name> \
  --query 'AutoScalingGroups[].{name:AutoScalingGroupName,desired:DesiredCapacity,inservice:Instances[?LifecycleState==`InService`]|length(@)}' \
  --output table

AWS_PROFILE=terraform-process aws autoscaling describe-scaling-activities \
  --region ap-southeast-1 \
  --auto-scaling-group-name <asg-name> \
  --max-items 20 \
  --output table
```

### EC2 instance and security group checks

```bash
AWS_PROFILE=terraform-process aws ec2 describe-instances \
  --region ap-southeast-1 \
  --filters 'Name=tag:eks:cluster-name,Values=skripsi-msa' 'Name=instance-state-name,Values=running,pending,stopping,stopped' \
  --query 'Reservations[].Instances[].{id:InstanceId,type:InstanceType,state:State.Name,private_ip:PrivateIpAddress}' \
  --output table

AWS_PROFILE=terraform-process aws ec2 describe-security-groups \
  --region ap-southeast-1 \
  --group-ids <security-group-id> \
  --output json
```

### RDS checks

```bash
AWS_PROFILE=terraform-process aws rds describe-db-instances \
  --region ap-southeast-1 \
  --db-instance-identifier skripsi-monolith-postgres \
  --query 'DBInstances[0].{status:DBInstanceStatus,engine:Engine,endpoint:Endpoint.Address,public:PubliclyAccessible}' \
  --output table

AWS_PROFILE=terraform-process aws rds describe-db-instances \
  --region ap-southeast-1 \
  --db-instance-identifier skripsi-msa-postgres \
  --query 'DBInstances[0].{status:DBInstanceStatus,engine:Engine,endpoint:Endpoint.Address,public:PubliclyAccessible}' \
  --output table
```

### IAM and Pod Identity checks

```bash
AWS_PROFILE=terraform-process aws iam get-role \
  --role-name skripsi-k6-runner \
  --query 'Role.{name:RoleName,arn:Arn}' \
  --output table

AWS_PROFILE=terraform-process aws eks list-pod-identity-associations \
  --region ap-southeast-1 \
  --cluster-name skripsi-msa \
  --output table
```

### CloudWatch log group checks

Use this when the control plane exists but Terraform or `kubectl` output does
not explain the problem clearly.

```bash
AWS_PROFILE=terraform-process aws logs describe-log-groups \
  --region ap-southeast-1 \
  --log-group-name-prefix /aws/eks/skripsi-monolith/cluster \
  --output table

AWS_PROFILE=terraform-process aws logs tail /aws/eks/skripsi-monolith/cluster \
  --region ap-southeast-1 \
  --since 30m
```

---

## When to Use This Reference Versus Scripts

Prefer repository scripts and Make targets for the normal lifecycle:

- `make eks-setup-contexts`
- `make eks-deploy-monolith`
- `make eks-deploy-msa`
- `make run-benchmark-parallel`
- `make run-benchmark-suite`
- `make terraform-recovery-check`

Use this reference when:

- a script fails and you need to inspect the exact resource,
- you want to rerun one job without rerunning the full flow,
- you need to verify whether the problem is in Kubernetes or AWS,
- you need to understand whether the failure is app-level, scheduling-level,
  quota-level, or infrastructure-level.
