# Local Environment Files

This directory stores generated local environment files.

Run:

```bash
make env-init
```

The generated `*.env` files are intentionally ignored by Git because they can
contain local passwords or secrets.

Generated files:

- `postgres.env`
- `monolith.env`
- `db-bootstrap.env`

