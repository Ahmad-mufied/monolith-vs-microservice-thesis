# Database Connection Pooling Strategy (Monolith vs. Microservices)

## 1. Background & Context

In a high-throughput transactional database benchmark, **connection pooling** is a critical element of stability and performance. Improperly configured pools can lead to:
* **Connection starvation** (request latency spikes while waiting for a database socket).
* **Database connection exhaustion** (PostgreSQL running out of available file descriptors or connection slots, leading to fatal client rejection).
* **High context-switching overhead** in PostgreSQL (if too many concurrent connections are established on a database server with limited CPU cores).

This project uses `github.com/jackc/pgx/v5/pgxpool` as the database client pool manager for both monolith and microservice architectures.

---

## 2. Budgeting & Symmetrical Scaling Formula

To guarantee database stability during load test scale-out (up to the maximum replica count of pods scheduled by the Horizontal Pod Autoscaler), we apply the **Connection Budgeting Formula**.

### 2.1 The Connection Budgeting Formula

The sum of all connections that can possibly be opened by all active application pod replicas must not exceed **80%** of the database server's absolute `max_connections` limit:

\[
\sum_{i} (\text{Max Replicas}_i \times \text{DB\_POOL\_MAX\_CONNS}_i) \le 0.8 \times \text{max\_connections\_database}
\]

The remaining **20%** of connection capacity is reserved for:
1. **Migrations**: Database schema updates run via Goose migration Kubernetes Jobs.
2. **Seed scripts**: Data population/reset runs executed between benchmark runs.
3. **Observability**: Metrics collection connections (e.g., Datadog PostgreSQL Agent).
4. **Administration**: Emergency access for administrators/DBA tools.

### 2.2 Symmetrical Pool Budgeting

For academic research validity, the connection pool limit is configured **symmetrically** across all three database-accessing microservices (`auth-service`, `item-service`, `transaction-service`). This ensures configuration fairness and consistency.

Applying the formula for microservices on the optimized Vultr DB VM specs:
* **PostgreSQL `max_connections`**: 200 (optimized).
* **Connection Budget (80%)**: 160 connections.
* **Services**: 3 (`auth-service`, `item-service`, `transaction-service`).
* **HPA Max Replicas per Service**: 5.
* **Total Max Replicas**: 15 pods.

Solving for the symmetrical pool size limit \(K\):

\[
15 \times K \le 160 \implies K \le 10.67
\]

Therefore, the maximum safe symmetrical value is **`DB_POOL_MAX_CONNS = 10`**.

---

## 3. Configuration Parameters

The database pool is configured via environment variables mapped to [pgxpool](file:///pkg/postgres/postgres.go#L15-L29):

* `DB_POOL_MAX_CONNS`: Maximum active connections in the pool.
* `DB_POOL_MIN_CONNS`: Minimum idle connections kept alive.
* `DB_POOL_MAX_CONN_LIFETIME`: Maximum lifetime of a connection in the pool before rotation.
* `DB_POOL_MAX_CONN_IDLE_TIME`: Maximum idle duration before closing an idle connection.
* `DB_PING_TIMEOUT`: Initial connection verification timeout.

### 3.1 Monolith vs. Microservices (Cluster Defaults)

| Configuration Key | Monolith | Microservices (Each) |
|---|---|---|
| `DB_POOL_MAX_CONNS` | **25** | **10** |
| `DB_POOL_MIN_CONNS` | **2** | **1** |
| `DB_POOL_MAX_CONN_LIFETIME` | **5m** | **15m** |
| `DB_POOL_MAX_CONN_IDLE_TIME` | **1m** | **1m** |
| `DB_PING_TIMEOUT` | **5s** | **5s** |

---

## 4. PostgreSQL VM Instance Optimization (Vultr)

On Vultr, the database runs on a dedicated compute VM (`voc-c-2c-4gb-50s-amd`) with 2 Dedicated AMD vCPUs and 4 GB RAM. We override default Ubuntu/PostgreSQL package parameters via [postgres-cloud-init.yaml.tftpl](file:///infra/terraform/modules/vultr-vke-benchmark-cluster/templates/postgres-cloud-init.yaml.tftpl) to maximize the hardware potential:

```ini
# /etc/postgresql/18/main/postgresql.conf

# Connections
max_connections = 200                # Safely accommodates the 130-150 potential microservices connections

# Memory Tuning
shared_buffers = 1GB                 # 25% of 4GB RAM (recommended standard for caching)
effective_cache_size = 3GB           # 75% of 4GB RAM (helps PG query planner with index utilization)
maintenance_work_mem = 256MB         # Speeds up index creations and schema updates
work_mem = 10MB                      # Maximizes sorting operations inside memory before swapping to disk

# Disk/WAL Performance
min_wal_size = 1GB
max_wal_size = 4GB                   # Reduces checkpoint frequency under write pressure
checkpoint_completion_target = 0.9   # Flushes writes smoothly over checkpoint duration
wal_buffers = 16MB                   # Buffer size for writing transactional logs

# NVMe SSD Optimization
random_page_cost = 1.1               # NVMe storage cost (default 4.0 assumes spinning HDD)
effective_io_concurrency = 200       # Allows PostgreSQL to spawn concurrent read threads on NVMe storage
default_statistics_target = 100
```
