# k6 Data Files

This directory is optional runtime input for k6 scripts.

It is not a database seed source. Database seed data is owned by the `seed/`
module and must be loaded before k6 runs.

Use these files only when a k6 run needs explicit user credentials or item IDs
instead of the deterministic values generated from environment variables.

Examples:

```bash
USERS_FILE=k6/data/users.sample.json ./k6/runner/run-k6.sh
ITEM_IDS_FILE=k6/data/item-ids.sample.json ./k6/runner/run-k6.sh
```
