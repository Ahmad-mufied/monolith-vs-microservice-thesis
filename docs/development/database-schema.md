# Database Schema

## 1. Purpose

This document describes the final database schema design for the thesis benchmark project.

The project compares:

1. Monolithic Architecture
2. Microservices Architecture

Both architectures use PostgreSQL 18 and equivalent logical data, but their database ownership models are different.

This document defines:

- database layout,
- table ownership,
- primary key strategy,
- audit metadata,
- table relationships,
- monolith schema,
- microservices schema,
- index strategy,
- fairness rules.

---

## 2. Database Engine

Target database:

```text
PostgreSQL 18
```

Reason:

The project uses database-side UUIDv7 generation through:

```sql
uuidv7()
```

All primary keys use native PostgreSQL `UUID` type.

---

## 3. Global Schema Rules

All main tables must use:

```sql
id UUID PRIMARY KEY DEFAULT uuidv7()
```

For tables with composite primary keys, foreign/reference UUID fields still use:

```sql
UUID
```

All main tables must include:

```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
```

Application code must not generate UUID manually during normal runtime inserts.

All create operations must use:

```sql
INSERT ... RETURNING id
```

Use:

```text
item
amount
available_amount
transaction
transaction_items
```

External REST API naming follows `openapi.yaml`. In that contract, an item's externally visible availability field is named `available_amount`, which maps directly to the database column `items.available_amount`.

Avoid:

```text
product
stock
quantity
cart
checkout
payment
```

---

## 4. Database Layout

Use one RDS PostgreSQL 18 instance with separate databases:

```text
RDS PostgreSQL 18
├── mono_db
├── auth_db
├── item_db
└── transaction_db
```

Ownership:

| Database | Owner |
|---|---|
| `mono_db` | monolith |
| `auth_db` | auth-service |
| `item_db` | item-service |
| `transaction_db` | transaction-service |

API Gateway owns no database.

---

## 5. Monolith Database Model

The monolith uses one database:

```text
mono_db
```

Tables:

- `users`,
- `items`,
- `transactions`,
- `transaction_items`.

Because all tables are owned by one application, foreign keys are allowed across tables.

Logical relationship:

```text
users
  |
  | 1:N
  v
transactions
  |
  | 1:N
  v
transaction_items
  ^
  | N:1
  |
items
```

Foreign keys:

```text
transactions.user_id -> users.id

transaction_items.transaction_id -> transactions.id

transaction_items.item_id -> items.id
```

---

## 6. Microservices Database Model

The microservices architecture uses database-per-service ownership.

```text
auth-service
    |
    v
auth_db.users

item-service
    |
    v
item_db.items

transaction-service
    |
    v
transaction_db.transactions
transaction_db.transaction_items
```

The Transaction Service stores:

```text
transactions.user_id
transaction_items.item_id
```

as UUID references only.

It must not create foreign keys to:

```text
auth_db.users
item_db.items
```

Allowed foreign key inside `transaction_db`:

```text
transaction_items.transaction_id -> transactions.id
```

Reason:

Cross-service foreign keys break service autonomy and couple the Transaction Service to databases owned by other services.

---

## 7. Table: users

Purpose:

Stores user identity and authentication information.

Used by:

- monolith Auth module,
- Auth Service in microservices,
- login benchmark,
- enriched transaction benchmark.

Schema:

```sql
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
```

Notes:

- `password_hash` must never be returned in API responses,
- `email` uniqueness is enforced case-insensitively via `idx_users_email_lower_unique`,
- password hashing uses bcrypt.

Owned by:

| Architecture | Owner |
|---|---|
| Monolith | `mono_db.users` |
| Microservices | `auth_db.users` |

---

## 8. Table: items

Purpose:

Stores generic allocatable items.

Used by:

- monolith Item module,
- Item Service in microservices,
- create transaction benchmark,
- enriched transaction benchmark.

Schema:

```sql
CREATE TABLE items (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  name TEXT NOT NULL,
  available_amount INT NOT NULL CHECK (available_amount >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Notes:

- `available_amount` represents available allocatable amount,
- `available_amount` is used as a validation boundary during transaction creation,
- REST API `Item.available_amount` maps to this column,
- do not use `stock`, `quantity`, or `availability`.

Owned by:

| Architecture | Owner |
|---|---|
| Monolith | `mono_db.items` |
| Microservices | `item_db.items` |

---

## 9. Table: transactions

Purpose:

Stores transaction header data.

Used by:

- monolith Transaction module,
- Transaction Service in microservices.

Monolith schema:

```sql
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id UUID NOT NULL REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'SUCCESS',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Microservices schema:

```sql
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'SUCCESS',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Difference:

```text
Monolith:
user_id has FK to users.id

Microservices:
user_id is UUID reference only, no FK to auth_db.users
```

---

## 10. Table: transaction_items

Purpose:

Stores item-level details inside a transaction.

Relationship:

```text
one transaction has many transaction_items
```

Monolith schema:

```sql
CREATE TABLE transaction_items (
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  item_id UUID NOT NULL REFERENCES items(id),
  amount INT NOT NULL CHECK (amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (transaction_id, item_id)
);
```

`amount` stores the amount requested for an item in a transaction. The current REST `TransactionItem` response in `openapi.yaml` exposes `item_id` and `amount` only.

Microservices schema:

```sql
CREATE TABLE transaction_items (
  transaction_id UUID NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  item_id UUID NOT NULL,
  amount INT NOT NULL CHECK (amount > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (transaction_id, item_id)
);
```

Difference:

```text
Monolith:
item_id has FK to items.id

Microservices:
item_id is UUID reference only, no FK to item_db.items
```

Primary key:

```sql
PRIMARY KEY (transaction_id, item_id)
```

Meaning:

The same item appears only once in the same transaction.

For the microservices architecture, item availability is validated by Item Service before persistence. Transaction Service stores only the requested `amount`, not a post-validation availability snapshot.

---

## 11. Transaction Header and Detail Pattern

The schema separates:

```text
transactions
transaction_items
```

Meaning:

```text
transactions:
transaction header / parent record

transaction_items:
item detail lines inside the transaction
```

Example:

```text
transactions:
TX-1, user_id, SUCCESS, created_at

transaction_items:
TX-1, item_A, amount 2
TX-1, item_B, amount 1
```

Reason:

One transaction can contain multiple items.

This avoids duplicating transaction header data for every item row.

---

## 12. Why No Snapshot Fields

The table `transaction_items` does not store:

```text
item_name_snapshot
user_name_snapshot
```

Reason:

Benchmark 3 intentionally evaluates enrichment behavior.

Monolith:

```text
single SQL JOIN
```

Microservices:

```text
Transaction Service
-> Auth Service GetUsersByIds
-> Item Service GetItemSummariesByIds
-> in-memory enrichment
```

If snapshots are stored directly in `transaction_items`, the enrichment benchmark becomes less meaningful.

---

## 13. Index Strategy

Current indexes used in migrations:

```sql
CREATE UNIQUE INDEX idx_users_email_lower_unique
ON users(lower(email));

CREATE INDEX idx_transactions_user_id_created_at_id
ON transactions(user_id, created_at DESC, id DESC);

CREATE INDEX idx_transactions_created_at_id
ON transactions(created_at DESC, id DESC);

CREATE INDEX idx_transaction_items_item_id
ON transaction_items(item_id);
```

Purpose:

| Index | Purpose |
|---|---|
| `users(lower(email))` | case-insensitive email uniqueness |
| `transactions(user_id, created_at DESC, id DESC)` | get own transactions |
| `transactions(created_at DESC, id DESC)` | admin transaction listing |
| `transaction_items(item_id)` | item reference lookup or analysis |

Note:

Because `transaction_items` has a composite primary key `(transaction_id, item_id)`, lookups by `transaction_id` are already covered by the primary key index. A separate `transaction_id` index is not created in the current migrations.

---

## 14. Monolith Full Schema Summary

```text
mono_db
├── users
├── items
├── transactions
└── transaction_items
```

Relationships:

```text
users.id -> transactions.user_id

transactions.id -> transaction_items.transaction_id

items.id -> transaction_items.item_id
```

The monolith can use:

- SQL JOIN,
- foreign keys,
- single database transaction across all tables.

---

## 15. Microservices Full Schema Summary

```text
auth_db
└── users

item_db
└── items

transaction_db
├── transactions
└── transaction_items
```

Relationships:

```text
transaction_items.transaction_id -> transactions.id
```

References without FK:

```text
transactions.user_id references auth_db.users.id logically

transaction_items.item_id references item_db.items.id logically
```

The microservices architecture must use gRPC to resolve user and item details.

---

## 16. Create Transaction Data Flow

## 16.1 Monolith

```text
Begin DB transaction
    |
    v
Validate items.available_amount
    |
    v
Update items.available_amount
    |
    v
Insert transactions RETURNING id
    |
    v
Insert transaction_items
    |
    v
Commit
```

All operations are inside `mono_db`.

---

## 16.2 Microservices

```text
Transaction Service
    |
    v
Item Service ValidateTransactionItems
    |
    v
item_db validates active items against available_amount
    |
    v
Transaction Service inserts transaction
    |
    v
transaction_db inserts transaction_items
```

Operations are split across service-owned databases.

This research does not deeply evaluate saga or distributed transaction patterns.

---

## 17. Seed Data Implications

Because IDs are generated by PostgreSQL:

```sql
DEFAULT uuidv7()
```

Seed scripts must capture generated IDs:

```sql
INSERT ... RETURNING id
```

Seed scripts must maintain mappings:

```text
logical_user_key -> generated user_id
logical_item_key -> generated item_id
logical_transaction_key -> generated transaction_id
```

Monolith and microservices UUID values do not need to be identical.

But data must be logically equivalent:

```text
same user count
same item count
same transaction count
same available_amount distribution
same amount distribution
same benchmark access pattern
```

---

## 18. Fairness Rules

Schema fairness requirements:

- both architectures use PostgreSQL 18,
- both architectures use UUIDv7 database-generated IDs,
- both architectures use audit metadata,
- both architectures use equivalent logical data,
- equivalent indexes should exist where query behavior is comparable,
- equivalent constraints should exist where ownership allows it.

Differences allowed by architecture:

| Difference | Reason |
|---|---|
| Monolith has FK to users/items | one database ownership |
| Microservices has no FK to auth/item DBs | service ownership boundary |
| Monolith uses SQL JOIN | all data in one DB |
| Microservices uses gRPC enrichment | data owned by separate services |

---

## 19. Out of Scope

The schema does not include:

- payment tables,
- cart tables,
- stock tables,
- product tables,
- order cancellation,
- event outbox,
- Kafka event log,
- Redis cache,
- saga state,
- audit log table,
- soft delete columns.

These may be added only if the research scope changes.

---

## 20. Summary

Final schema rules:

```text
Database engine       : PostgreSQL 18
Primary key type      : UUID
ID generation         : DEFAULT uuidv7()
Runtime insert        : INSERT ... RETURNING id
Audit metadata        : created_at, updated_at
Monolith database     : mono_db
MSA databases         : auth_db, item_db, transaction_db
Seed strategy         : central seed scripts with ID mapping
```

Monolith:

```text
one database with full foreign keys
```

Microservices:

```text
database per service with no cross-service foreign keys
```
