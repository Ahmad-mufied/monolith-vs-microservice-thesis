# Create Transaction Sequence Diagram

This sequence diagram shows Benchmark 2, `POST /api/v1/transactions`.

Important semantic rule: this endpoint validates `amount <= available_amount`
but does not deduct `available_amount`.

## Monolith

```mermaid
sequenceDiagram
  participant K6 as Client / k6
  participant M as Monolith
  participant U as Transaction usecase
  participant R as Transaction repository
  participant DB as mono_db

  K6->>M: POST /api/v1/transactions
  M->>U: create transaction(user_id, items)
  U->>R: begin database transaction
  R->>DB: BEGIN
  R->>DB: SELECT items and available_amount
  DB-->>R: item rows
  R-->>U: validation data
  U->>U: validate amount against available_amount
  alt validation fails
    R->>DB: ROLLBACK
    U-->>M: conflict error
    M-->>K6: 409 ErrorResponse
  else validation succeeds
    U->>R: insert transaction
    R->>DB: INSERT transactions RETURNING id
    DB-->>R: transaction id
    U->>R: insert transaction_items
    R->>DB: INSERT transaction_items
    R->>DB: COMMIT
    U-->>M: generated transaction id
    M-->>K6: 201 IdResponse
  end
```

## Microservices

```mermaid
sequenceDiagram
  participant K6 as Client / k6
  participant GW as API Gateway
  participant TS as Transaction Service
  participant IS as Item Service
  participant ItemDB as item_db
  participant TxDB as transaction_db

  K6->>GW: POST /api/v1/transactions
  GW->>GW: validate JWT
  GW->>TS: gRPC CreateTransaction(user_id, items)
  TS->>IS: gRPC ValidateTransactionItems(items)
  IS->>ItemDB: SELECT items and available_amount
  ItemDB-->>IS: item rows
  IS->>IS: validate amount against available_amount
  alt validation fails
    IS-->>TS: conflict validation result
    TS-->>GW: conflict error
    GW-->>K6: 409 ErrorResponse
  else validation succeeds
    IS-->>TS: validation result
    TS->>TxDB: BEGIN
    TS->>TxDB: INSERT transactions RETURNING id
    TxDB-->>TS: transaction id
    TS->>TxDB: INSERT transaction_items
    TS->>TxDB: COMMIT
    TS-->>GW: generated transaction id
    GW-->>K6: 201 IdResponse
  end
```
