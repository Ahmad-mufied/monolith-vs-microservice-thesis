# Local Environment Files

This directory stores generated local environment files.

Run:

```bash
make env-init-base
```

The generated `*.env` files are intentionally ignored by Git because they can
contain local passwords or secrets.

Generated files:

- `postgres.env`
- `api-gateway.env`
- `auth-service.env`
- `item-service.env`
- `transaction-service.env`
- `api-gateway.compose.env`
- `auth-service.compose.env`
- `item-service.compose.env`
- `transaction-service.compose.env`

For local microservices env files, run:

```bash
make env-init-microservices
```

For local monolith env files, run:

```bash
make env-init-monolith
```

`make env-init-base` creates the shared local PostgreSQL env:

- `postgres.env`

`make env-init-monolith` creates the monolith-specific env files:

- `monolith.env`
- `db-bootstrap.env`

The non-compose microservices env files use `localhost` and are intended for
`go run` from the host.

The `*.compose.env` files use Docker Compose service names such as `postgres`,
`auth-service`, `item-service`, and `transaction-service`.
