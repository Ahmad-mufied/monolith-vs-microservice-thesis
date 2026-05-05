# RDS PostgreSQL

## Purpose

This document describes the Amazon RDS PostgreSQL strategy for the benchmark project.

Final database engine:

```text
Amazon RDS PostgreSQL 18
```

---

## Final Decision

```text
Database engine       : Amazon RDS PostgreSQL
PostgreSQL version    : 18.x
Access                : private only
Public access         : disabled
Application databases : created by db-bootstrap-job
Schema migration      : Goose migration jobs
Seed data             : seed jobs
```

---

## RDS Instance Role

Terraform provisions the RDS instance.

RDS initially contains one bootstrap database, for example:

```text
bootstrap
```

Terraform does not directly create:

```text
mono_db
auth_db
item_db
transaction_db
```

Those are created by:

```text
db-bootstrap-job
```

---

## Database Layout

```text
RDS PostgreSQL 18
├── bootstrap
├── mono_db
├── auth_db
├── item_db
└── transaction_db
```

Purpose:

| Database | Purpose |
|---|---|
| `bootstrap` | initial database used by DB bootstrap job |
| `mono_db` | monolith database |
| `auth_db` | Auth Service database |
| `item_db` | Item Service database |
| `transaction_db` | Transaction Service database |

---

## DB Bootstrap Job

Job name:

```text
db-bootstrap-job
```

Purpose:

```text
Create internal application databases after RDS is ready.
```

SQL:

```sql
CREATE DATABASE mono_db;
CREATE DATABASE auth_db;
CREATE DATABASE item_db;
CREATE DATABASE transaction_db;
```

Connection env:

```text
BOOTSTRAP_DATABASE_URL
```

Example:

```text
postgres://postgres_admin:<password>@<rds-endpoint>:5432/bootstrap?sslmode=require
```

The job must run before migration jobs.

---

## Migration Jobs

After DB bootstrap:

```text
monolith-migration-job    -> mono_db
auth-migration-job        -> auth_db
item-migration-job        -> item_db
transaction-migration-job -> transaction_db
```

Migration tool:

```text
Goose SQL migration
```

---

## Seed Jobs

After migrations:

```text
seed-monolith-job
seed-microservices-job
```

Seed jobs insert benchmark data and capture generated UUIDs with:

```sql
INSERT ... RETURNING id
```

---

## Security

RDS must be private.

Required rules:

```text
publicly_accessible = false
RDS subnet group uses private subnets
RDS security group allows 5432 only from EKS-related security group
No inbound 0.0.0.0/0 on port 5432
```

Do not expose RDS publicly for local access.

Use a temporary pod inside EKS, bastion, or SSM if manual inspection is needed.

---

## Database URLs

Bootstrap:

```text
BOOTSTRAP_DATABASE_URL=postgres://postgres_admin:<password>@<endpoint>:5432/bootstrap?sslmode=require
```

Monolith:

```text
DATABASE_URL=postgres://postgres_admin:<password>@<endpoint>:5432/mono_db?sslmode=require
```

Auth Service:

```text
DATABASE_URL=postgres://postgres_admin:<password>@<endpoint>:5432/auth_db?sslmode=require
```

Item Service:

```text
DATABASE_URL=postgres://postgres_admin:<password>@<endpoint>:5432/item_db?sslmode=require
```

Transaction Service:

```text
DATABASE_URL=postgres://postgres_admin:<password>@<endpoint>:5432/transaction_db?sslmode=require
```

Do not commit these values.

Store them in Kubernetes Secrets.

---

## PostgreSQL 18 and UUIDv7

The schema uses:

```sql
uuidv7()
```

Primary key pattern:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

Application code must use:

```sql
INSERT ... RETURNING id
```

Application code must not generate UUID manually during normal runtime inserts.

---

## Experiment Cost Settings

Recommended experiment settings:

```text
Multi-AZ              : disabled by default
Deletion protection   : disabled
Final snapshot        : skipped
Backup retention      : minimal or disabled
Allocated storage     : 20 GiB
Max allocated storage : 50 GiB
```

These settings are suitable for short-lived experiment infrastructure, not production.

---

## Validation Checklist

After Terraform:

```text
- RDS instance is available
- RDS endpoint exists
- RDS is private
- RDS security group allows EKS access
```

After DB bootstrap:

```text
- mono_db exists
- auth_db exists
- item_db exists
- transaction_db exists
```

After migrations:

```text
- required tables exist
- required indexes exist
- Goose version table exists
```

After seed:

```text
- expected row counts exist
- benchmark dataset exists
```

---

## Summary

```text
Terraform:
creates RDS instance

db-bootstrap-job:
creates internal databases

migration jobs:
create schema

seed jobs:
insert benchmark data

application deployments:
use prepared databases
```
