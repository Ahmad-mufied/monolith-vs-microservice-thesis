# Validation Strategy

This repository uses a hybrid request-validation pattern.

The goal is to keep handlers thin, preserve exact API error behavior, and avoid hiding business rules inside struct tags.

## Split of Responsibilities

Use shared validator-based validation for request-shape rules only:

- required request fields
- max and min length rules
- numeric boundary rules such as `gte` and `gt`
- UUID format checks inside request bodies
- collection size rules such as transaction item count

Use service-layer manual validation for normalization, semantic checks, and contract-sensitive behavior:

- trimming and lowercasing request fields before validation when needed
- canonical email validation
- bcrypt 72-byte password limit
- path parameter UUID validation
- "at least one field is required" update semantics
- duplicate item detection in transaction creation
- UUID normalization to canonical lowercase strings
- repository, domain, and transport error translation

## Monolith Policy

In the monolith:

- handlers stay bind-only
- services call the shared validation helper after request normalization
- the shared helper is the only entrypoint for `go-playground/validator`
- validation errors must remain in the public API shape:

```json
{
  "status": "error",
  "error": {
    "code": "BAD_REQUEST",
    "message": "invalid request payload",
    "details": {
      "field_name": "validation message"
    }
  }
}
```

Error details must use public JSON field names such as `name`, `email`, `password`, `available_amount`, `items`, `item_id`, and `amount`.

The shared helper should return one deterministic violation per failure path so service tests remain stable and the API does not change into a broad error dump.

## Microservices Guidance

When the microservices are refactored later, follow the same split:

- keep API Gateway handlers focused on transport concerns
- keep service handlers thin
- centralize request-shape validation behind one shared helper per service or shared package
- preserve service-layer manual validation for normalization, semantic rules, and exact HTTP or gRPC error mapping

Do not move business rules, repository error translation, or benchmark-sensitive behavior into validator tags.
