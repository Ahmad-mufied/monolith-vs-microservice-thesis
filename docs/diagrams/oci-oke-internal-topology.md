# OCI OKE Internal Kubernetes Topology — Complete Reference

This document describes the **internal Kubernetes architecture** of the OCI sequential deployment. It covers node pools, namespace layout, pod placement rules, Kubernetes resource objects, inter-service gRPC communication, and the Datadog APM telemetry path.

---

## 1. Cluster Overview

Sequential mode uses a single OKE cluster with two node pools. Both benchmark architectures share the same physical nodes — they are isolated at the namespace level and executed sequentially.

```text
OKE Cluster          : skripsi-oci-sequential (kubectl context: monolith)
Region               : ap-kulai-2 (Malaysia)
Kubernetes Version   : v1.36.0

Node Pools:
  app-nodes          : 1 x VM.Standard.E5.Flex (4 OCPUs / 8 vCPUs / 16 GB RAM)
                       Allocatable Capacity: 7800m CPU / 15000Mi RAM
  testing-nodes      : 1 x VM.Standard.E5.Flex (4 OCPUs / 8 vCPUs / 16 GB RAM)
                       Taint: workload=benchmark:NoSchedule

Namespaces:
  mono               : Monolith application deployment (monolith pod)
  msa                : Microservices application deployments (api-gateway, auth-service, item-service, transaction-service)
  benchmark          : One-shot jobs (db-bootstrap-job, migration jobs, seed jobs, k6 runner jobs)
  datadog            : Observability agent DaemonSet and API key secret
```

---

## 2. Dynamic Node Labeling & Pod Scheduling

```mermaid
flowchart TB
  subgraph cluster["OKE Cluster: skripsi-oci-sequential"]

    subgraph app_pool["App Node Pool — node-group=app"]
      app_node["Node: app-node-1
VM.Standard.E5.Flex (4 OCPUs / 16 GB RAM)
Label: node-group=app
Dynamic Label: architecture=monolith OR architecture=msa
Schedulable: 7800m CPU / 15000Mi RAM"]
    end

    subgraph test_pool["Testing Node Pool — node-group=testing"]
      test_node["Node: testing-node-1
VM.Standard.E5.Flex (1 OCPU / 4 GB RAM)
Label: node-group=testing
Taint: workload=benchmark:NoSchedule"]
    end

    subgraph mono_ns["Namespace: mono"]
      mono_pod["monolith pod
nodeSelector: node-group=app, architecture=monolith
Requests: 3900m CPU / 7680Mi RAM
Limits:   7800m CPU / 15000Mi RAM"]
    end

    subgraph msa_ns["Namespace: msa"]
      gw_pod["api-gateway pod
nodeSelector: node-group=app, architecture=msa
Requests: 975m CPU / 1920Mi RAM
Limits:   1950m CPU / 3750Mi RAM"]
      auth_pod["auth-service pod
nodeSelector: node-group=app, architecture=msa
Requests: 975m CPU / 1920Mi RAM
Limits:   1950m CPU / 3750Mi RAM"]
      item_pod["item-service pod
nodeSelector: node-group=app, architecture=msa
Requests: 975m CPU / 1920Mi RAM
Limits:   1950m CPU / 3750Mi RAM"]
      tx_pod["transaction-service pod
nodeSelector: node-group=app, architecture=msa
Requests: 975m CPU / 1920Mi RAM
Limits:   1950m CPU / 3750Mi RAM"]
    end

    subgraph bench_ns["Namespace: benchmark"]
      k6_pod["k6 runner job
tolerations: workload=benchmark:NoSchedule
nodeSelector: node-group=testing"]
    end

    subgraph dd_ns["Namespace: datadog"]
      dd_ds["Datadog Agent DaemonSet
runs on all nodes"]
    end

  end

  app_node -->|"Phase 1: architecture=monolith"| mono_pod
  app_node -->|"Phase 2: architecture=msa"| gw_pod
  app_node -->|"Phase 2: architecture=msa"| auth_pod
  app_node -->|"Phase 2: architecture=msa"| item_pod
  app_node -->|"Phase 2: architecture=msa"| tx_pod
  test_node --> k6_pod
  app_node --- dd_ds
  test_node --- dd_ds
```

---

## 3. Microservices Inter-Service Communication & DNS Resolution

```mermaid
flowchart TD
  subgraph msa_ns["Namespace: msa"]
    gw["api-gateway (REST Port: 8080)"]
    auth["auth-service (gRPC Port: 50051)"]
    item["item-service (gRPC Port: 50052)"]
    tx["transaction-service (gRPC Port: 50053)"]

    auth_svc["Headless Service: auth-service-headless
ClusterIP: None | Port: 50051"]
    item_svc["Headless Service: item-service-headless
ClusterIP: None | Port: 50052"]
    tx_svc["Headless Service: transaction-service-headless
ClusterIP: None | Port: 50053"]
  end

  gw -->|"AUTH_SERVICE_ADDR: dns:///auth-service-headless.msa.svc.cluster.local:50051"| auth_svc
  gw -->|"ITEM_SERVICE_ADDR: dns:///item-service-headless.msa.svc.cluster.local:50052"| item_svc
  gw -->|"TRANSACTION_SERVICE_ADDR: dns:///transaction-service-headless.msa.svc.cluster.local:50053"| tx_svc
  tx -->|"ITEM_SERVICE_ADDR: dns:///item-service-headless.msa.svc.cluster.local:50052"| item_svc

  auth_svc --- auth
  item_svc --- item
  tx_svc --- tx
```

---

## 4. Resource Quotas & Scheduling Enforcement

To ensure mathematical equivalence between Monolith and Microservices, a Kubernetes `ResourceQuota` object is applied to namespaces `mono` and `msa`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mono-resource-quota
  namespace: mono
spec:
  hard:
    limits.cpu: "7800m"
    limits.memory: "15000Mi"
    requests.cpu: "3900m"
    requests.memory: "7680Mi"
```

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: msa-resource-quota
  namespace: msa
spec:
  hard:
    limits.cpu: "7800m"
    limits.memory: "15000Mi"
    requests.cpu: "3900m"
    requests.memory: "7680Mi"
```

---

## 5. Telemetry & Artifact Lifecycle Pipeline

1. **Load Generation (k6 Job)**:
   - Emits real-time load test metrics via DogStatsD to Datadog Agent (`datadog.datadog.svc.cluster.local:8125`).
   - Writes result JSON files to local job volume (`summary.json`, `raw.json.gz`, `metadata.json`, `thresholds.json`).
2. **AWS S3 Artifact Upload**:
   - Uploads complete result bundle to `s3://skripsi-benchmark-results/experiments/{run_id}/{architecture}/{scenario}/{rps}rps/attempt-01/`.
3. **Datadog Observability**:
   - Application pods emit APM traces to `DD_AGENT_HOST:8126` (`status.hostIP`).
   - Datadog Agent forwards traces, metrics, and logs to `us5.datadoghq.com`.
