# Database Migration

## 1. Purpose

This document describes the database migration strategy for the thesis benchmark project.

The project uses:

```text
Goose SQL migrations
```

Migration is used to manage schema changes for:

- monolith database,
- auth service database,
- item service database,
- transaction service database.

Migration is separate from seed data.

---

## 2. Final Migration Decision

Final decision:

```text
Migration tool      : Goose
Migration format    : SQL migrations
Execution method    : Kubernetes Job
Local execution     : Goose CLI
Seed data           : separate from migration
```

Do not use init containers for migration.

Reason:

Migration must run once per deployment or experiment preparation, not once per pod.

When HPA scales out new pods, init containers would run again for each new pod. That behavior is not appropriate for schema migration.

---

## 3. Migration Ownership

Migration ownership follows database ownership.

Monolith:

```text
monolith owns mono_db
monolith owns monolith/migrations/
```

Microservices:

```text
auth-service owns auth_db
auth-service owns microservices/auth-service/migrations/

item-service owns item_db
item-service owns microservices/item-service/migrations/

transaction-service owns transaction_db
transaction-service owns microservices/transaction-service/migrations/
```

API Gateway owns no database and has no migrations.

---

## 4. Migration Locations

Final migration locations:

```text
monolith/
└── migrations/
    ├── 00001_create_users.sql
    ├── 00002_create_items.sql
    ├── 00003_create_transactions.sql
    └── 00004_create_transaction_items.sql

microservices/
├── auth-service/
│   └── migrations/
│       └── 00001_create_users.sql
│
├── item-service/
│   └── migrations/
│       └── 00001_create_items.sql
│
└── transaction-service/
    └── migrations/
        ├── 00001_create_transactions.sql
        └── 00002_create_transaction_items.sql
```

Not used:

```text
root migrations/
```

Reason:

A central root migration folder would make microservice database ownership less clear.

---

## 5. Migration File Naming

Use incremental numeric prefixes.

Format:

```text
00001_create_users.sql
00002_create_items.sql
00003_create_transactions.sql
```

Rules:

- use zero-padded sequence numbers,
- use descriptive names,
- do not rename applied migrations,
- do not edit applied migrations in shared environments,
- create a new migration for new changes.

---

## 6. Goose SQL Format

Each migration file must include:

```sql
-- +goose Up

-- +goose Down
```

Example:

```sql
-- +goose Up
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_users_email_lower_unique
ON users (lower(email));

-- +goose Down
DROP TABLE users;
```

Rules:

- `Up` applies the schema change,
- `Down` rolls back the schema change,
- keep `Down` safe and understandable,
- test both `up` and `down` locally when possible.

---

## 7. PostgreSQL 18 and UUIDv7

Target database:

```text
PostgreSQL 18
```

All primary keys use:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

Application code must not generate UUID manually during normal runtime inserts.

Application insert pattern:

```sql
INSERT INTO users (name, email, password_hash)
VALUES ($1, $2, $3)
RETURNING id;
```

Migration files should not use UUID strings such as:

```text
USR-001
ITM-001
TX-001
```

---

## 8. Monolith Migrations

Path:

```text
monolith/migrations/
```

Target database:

```text
mono_db
```

Migration order:

```text
00001_create_users.sql
00002_create_items.sql
00003_create_transactions.sql
00004_create_transaction_items.sql
```

Reason for order:

1. `users` must exist before `transactions`,
2. `items` must exist before `transaction_items`,
3. `transactions` must exist before `transaction_items`.

Monolith may use foreign keys:

```text
transactions.user_id -> users.id
transaction_items.transaction_id -> transactions.id
transaction_items.item_id -> items.id
```

---

## 9. Auth Service Migration

Path:

```text
microservices/auth-service/migrations/
```

Target database:

```text
auth_db
```

Migration:

```text
00001_create_users.sql
```

Auth Service owns:

```text
users
```

The Auth Service migration must not create tables for item or transaction data.

---

## 10. Item Service Migration

Path:

```text
microservices/item-service/migrations/
```

Target database:

```text
item_db
```

Migration:

```text
00001_create_items.sql
```

Item Service owns:

```text
items
```

The Item Service migration must not create user or transaction tables.

---

## 11. Transaction Service Migration

Path:

```text
microservices/transaction-service/migrations/
```

Target database:

```text
transaction_db
```

Migrations:

```text
00001_create_transactions.sql
00002_create_transaction_items.sql
```

Transaction Service owns:

```text
transactions
transaction_items
```

Allowed foreign key:

```text
transaction_items.transaction_id -> transactions.id
```

Not allowed:

```text
transactions.user_id -> auth_db.users.id
transaction_items.item_id -> item_db.items.id
```

Reason:

The Transaction Service must not depend directly on databases owned by other services.

---

## 12. Local Migration Commands

Monolith:

```bash
goose -dir monolith/migrations postgres "$MONO_DATABASE_URL" up
```

Auth Service:

```bash
goose -dir microservices/auth-service/migrations postgres "$AUTH_DATABASE_URL" up
```

Item Service:

```bash
goose -dir microservices/item-service/migrations postgres "$ITEM_DATABASE_URL" up
```

Transaction Service:

```bash
goose -dir microservices/transaction-service/migrations postgres "$TRANSACTION_DATABASE_URL" up
```

Rollback example:

```bash
goose -dir monolith/migrations postgres "$MONO_DATABASE_URL" down
```

Status example:

```bash
goose -dir monolith/migrations postgres "$MONO_DATABASE_URL" status
```

---

## 13. Kubernetes Migration Jobs

Migration must run through Kubernetes Jobs in the target environment.

Expected jobs:

```text
monolith-migration-job
auth-migration-job
item-migration-job
transaction-migration-job
```

API Gateway has no migration job.

Migration jobs should run before benchmark execution.

Migration jobs must complete successfully before the related application is considered ready for benchmark.

---

## 14. Example Migration Job Concept

Example concept for Auth Service:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: auth-migration-job
  namespace: msa
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        node-group: app
      containers:
        - name: goose
          image: auth-service:latest
          command:
            - sh
            - -c
            - |
              goose -dir /app/migrations postgres "$DATABASE_URL" up
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: auth-db-secret
                  key: database-url
```

This is a conceptual example. The final manifest may differ depending on Helm and image design.

---

## 15. Image Strategy for Migration

Recommended simple strategy:

```text
Use the service image to run migration.
```

The image should include:

- service binary,
- Goose binary or migration runner,
- service migration files.

Example image content:

```text
/app/server
/app/migrations/
goose
```

Migration command:

```bash
goose -dir /app/migrations postgres "$DATABASE_URL" up
```

Alternative:

```text
Use a dedicated migration-runner image.
```

This is cleaner but adds build complexity.

Recommended for thesis implementation:

```text
Start with service image migration.
```

---

## 16. Migration and Helm

If Helm is used, migration jobs can be implemented as Helm hooks.

Possible annotations:

```yaml
annotations:
  "helm.sh/hook": pre-install,pre-upgrade
  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

However, for experiment clarity, explicit Kubernetes Job execution may be easier to document.

Recommended approach:

```text
Use explicit migration jobs during experiment automation.
```

Reason:

The experiment procedure becomes easier to explain:

```text
run migration job -> run seed job -> deploy app -> run benchmark
```

---

## 17. Migration vs Seed

Migration and seed must stay separate.

Migration:

```text
create table
create index
alter table
schema versioning
```

Seed:

```text
insert benchmark users
insert benchmark items
insert benchmark transactions
reset benchmark data
```

Do not put large benchmark seed data into migration files.

Bad example:

```text
00005_seed_100k_users.sql
```

Reason:

Benchmark data must be reset and reseeded many times. It should not be tied to schema migration history.

---

## 18. Seed Job Relationship

Migration jobs create schema.

Seed jobs insert benchmark data.

Expected flow:

```text
Run migration job
    |
    v
Run seed job
    |
    v
Deploy application
    |
    v
Run benchmark
```

For mutation-heavy scenarios, reset and seed may run before each scenario.

```text
Reset data
    |
    v
Seed data
    |
    v
Run k6 scenario
```

Migration usually does not need to run before every scenario if schema has not changed.

---

## 19. Experiment Execution Flow

Monolith:

```text
terraform apply
    |
    v
run monolith migration job
    |
    v
run monolith seed job
    |
    v
deploy monolith
    |
    v
run k6 scenarios
```

Microservices:

```text
terraform apply
    |
    v
run auth migration job
    |
    v
run item migration job
    |
    v
run transaction migration job
    |
    v
run microservices seed job
    |
    v
deploy microservices
    |
    v
run k6 scenarios
```

Migration and seed must not run during benchmark execution.

---

## 20. Migration Validation

After running migration, validate:

```text
1. Goose status is clean.
2. Expected tables exist.
3. Expected indexes exist.
4. Expected constraints exist.
5. Application can connect to database.
6. Seed job can insert data.
```

Example checks:

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public';

SELECT indexname
FROM pg_indexes
WHERE schemaname = 'public';
```

---

## 21. Reset Strategy

Reset is not migration rollback.

Reset is used to clean benchmark data while keeping schema.

Monolith reset example:

```sql
TRUNCATE TABLE transaction_items, transactions, items, users
RESTART IDENTITY CASCADE;
```

Microservices reset example:

```sql
-- auth_db
TRUNCATE TABLE users RESTART IDENTITY CASCADE;

-- item_db
TRUNCATE TABLE items RESTART IDENTITY CASCADE;

-- transaction_db
TRUNCATE TABLE transaction_items, transactions
RESTART IDENTITY CASCADE;
```

Note:

With UUID primary keys, `RESTART IDENTITY` is not important for IDs but harmless if future sequences exist.

---

## 22. Failure Handling

If migration fails:

```text
1. Stop deployment.
2. Inspect migration job logs.
3. Fix migration file or environment.
4. Re-run migration job.
5. Do not run benchmark until migration succeeds.
```

Do not ignore partial migration failure.

Do not run application against partially migrated schema.

---

## 23. Cost and Safety

Migration jobs must be short-lived.

They should not keep resources running.

After experiment completion, ensure:

- migration jobs are completed or cleaned up,
- seed jobs are completed or cleaned up,
- RDS is destroyed if using create-run-destroy strategy,
- no unnecessary resources remain.

---

## 24. Documentation Rules

When schema changes:

Update:

```text
docs/development/database-schema.md
docs/development/database-migration.md
```

When migration procedure changes:

Update:

```text
docs/experiment/test-execution-procedure.md
docs/infrastructure/rds-postgres.md
```

When seed assumptions change:

Update:

```text
docs/experiment/data-collection.md
seed/README.md
```

---

## 25. Summary

Final migration rules:

```text
Tool              : Goose
Format            : SQL migration
Execution         : Kubernetes Job
Monolith path     : monolith/migrations/
Auth path         : microservices/auth-service/migrations/
Item path         : microservices/item-service/migrations/
Transaction path  : microservices/transaction-service/migrations/
API Gateway       : no migration
Seed data         : separate from migration
Primary key       : UUID DEFAULT uuidv7()
```

Migration creates schema.

Seed inserts benchmark data.

Migration and seed must not run during benchmark execution.
