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
- `datadog.minikube.env`
- `aws-benchmark.env`
- `terraform.shared.env`
- `terraform.experiment.env`
- `datadog.eks.env`
- `monolith.eks.env`
- `api-gateway.eks.env`
- `auth-service.eks.env`
- `item-service.eks.env`
- `transaction-service.eks.env`
- `k6-runner.eks.env`
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

For AWS EKS helper env files, run:

```bash
make env-init-eks
```

`make env-init-base` creates the shared local PostgreSQL env:

- `postgres.env`

`make env-init-datadog-minikube` creates the Datadog helper env for Minikube:

- `datadog.minikube.env`

`make env-init-monolith` creates the monolith-specific env files:

- `monolith.env`
- `db-bootstrap.env`

`make env-init-eks` creates AWS benchmark helper env files:

- `aws-benchmark.env`
- `terraform.shared.env`
- `terraform.experiment.env`
- `datadog.eks.env`
- `monolith.eks.env`
- `api-gateway.eks.env`
- `auth-service.eks.env`
- `item-service.eks.env`
- `transaction-service.eks.env`
- `k6-runner.eks.env`

`k6-runner.eks.env` stores the benchmark admin credentials used by the k6
runner secret during EKS benchmark setup.

- `ADMIN_USER_EMAIL` defaults to `benchmark-user-001@example.com`
- `ADMIN_USER_PASSWORD` is generated automatically as a strong random hex value
- if an existing `k6-runner.eks.env` still contains the legacy weak value
  `Password123!`, `make env-init-eks` rotates it automatically

These files are intended to make EKS setup repeatable:

- `make eks-render-tfvars` renders Terraform `terraform.tfvars` from the
  `env/terraform.*.env` files
- `make create-eks-secrets-monolith` creates monolith cluster secrets from the
  EKS env files
- `make create-eks-secrets-microservices` creates microservices cluster
  secrets from the EKS env files

The non-compose microservices env files use `localhost` and are intended for
`go run` from the host.

The `*.compose.env` files use Docker Compose service names such as `postgres`,
`auth-service`, `item-service`, and `transaction-service`.
