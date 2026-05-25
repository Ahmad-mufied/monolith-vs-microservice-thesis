# Architecture Comparison Diagram

This diagram compares the two runtime architectures exposed through the same
external REST API.

```mermaid
flowchart LR
  client["Client / k6"]

  subgraph mono["Monolith architecture"]
    monoApp["Monolith application<br/>one deployable unit"]
    monoAuth["Auth module"]
    monoItem["Item module"]
    monoTx["Transaction module"]
    monoDb["mono_db<br/>users, items, transactions, transaction_items"]
  end

  subgraph msa["Microservices architecture"]
    gateway["api-gateway<br/>REST entry point<br/>JWT validation<br/>REST to gRPC mapping"]
    auth["auth-service<br/>register, login, users"]
    item["item-service<br/>items, validation, summaries"]
    tx["transaction-service<br/>transactions and transaction_items"]
    authDb["auth_db<br/>users"]
    itemDb["item_db<br/>items"]
    txDb["transaction_db<br/>transactions, transaction_items"]
  end

  client -->|"REST HTTP"| monoApp
  monoApp -->|"in-process call"| monoAuth
  monoApp -->|"in-process call"| monoItem
  monoApp -->|"in-process call"| monoTx
  monoAuth -->|"pgx / SQL"| monoDb
  monoItem -->|"pgx / SQL"| monoDb
  monoTx -->|"pgx / SQL"| monoDb

  client -->|"REST HTTP"| gateway
  gateway -->|"gRPC"| auth
  gateway -->|"gRPC"| item
  gateway -->|"gRPC"| tx
  tx -->|"gRPC validate items"| item

  auth -->|"pgx"| authDb
  item -->|"pgx"| itemDb
  tx -->|"pgx"| txDb
```

## Comparison Points

| Aspect | Monolith | Microservices |
|---|---|---|
| Deployment unit | One application | Four services |
| Internal communication | In-process function calls | gRPC |
| Database ownership | One database | Database per service |
| Create transaction | One database transaction | Transaction service plus item validation over gRPC |
| Enrichment | SQL JOIN | API Gateway distributed join / fan-out |
| Scaling unit | Whole application | Per service |
