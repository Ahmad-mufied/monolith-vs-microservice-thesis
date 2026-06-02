# AWS S3 Writer Separation Plan - 2026-06-02 13:34

## Worktree

Implementation path:

```text
/mnt/Cons/Amikom/semester/Semester 7/Skrips/experimen/april/code/worktrees/chore__separate-s3-writer-terraform-stack
```

## Goal

Separate external k6 S3 writer credentials for Vultr and Hetzner from the
AWS/EKS shared Terraform stack so operators do not need to run
`make eks-shared-apply` or provision AWS VPC/NAT/Budget/EKS resources just to
upload benchmark artifacts.

The benchmark artifact contract remains unchanged:

```text
s3://<bucket>/experiments/<run_id>/<architecture>/<scenario>/<rps>rps/<attempt>/
```

## Design Decisions

- Keep AWS S3 as the benchmark result backend to avoid breaking existing
  consumers.
- Add a small Terraform stack at `infra/terraform/aws-s3-writer` that creates
  only an IAM user, access key, and least-privilege S3 prefix policy.
- Scope writer access to `s3://<bucket>/experiments/*`.
- Keep the legacy writer in `infra/terraform/shared` untouched to avoid
  destructive state churn for existing EKS/Hetzner users.
- Make `vultr-sequential-apply`, `vultr-parallel-apply`,
  `hetzner-sequential-apply`, and `hetzner-parallel-apply` depend on
  `aws-s3-writer-apply`.
- Treat `aws_iam_access_key.secret` as sensitive Terraform state data. The
  state is ignored by git and must not be committed.

## Progress Tracker

- [x] Audit existing Makefile, Terraform, scripts, and docs for S3 writer usage.
- [x] Add `infra/terraform/aws-s3-writer` minimal stack.
- [x] Add `scripts/terraform-aws-s3-writer.sh` wrapper with env auto-load and
      guarded destroy.
- [x] Add Makefile targets for plan/apply/destroy-confirmed.
- [x] Wire Vultr and Hetzner apply targets to run `aws-s3-writer-apply` first.
- [x] Update Vultr and Hetzner S3 credential helpers to prefer the new stack.
- [x] Add fail-fast credential checks to Vultr secret creation and preflight.
- [x] Update docs to remove S3-only dependency on `eks-shared-apply`.
- [x] Run Terraform formatting and validation.
- [x] Verify plan blast radius only includes IAM writer resources.
- [x] Run shell syntax checks for changed scripts.

## Validation Commands

```bash
chmod +x scripts/terraform-aws-s3-writer.sh
terraform fmt -recursive infra/terraform/aws-s3-writer
TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-aws-s3-writer.sh init
TERRAFORM_AWS_PROFILE=terraform-process bash scripts/terraform-aws-s3-writer.sh validate
make aws-s3-writer-plan
git diff --check
```

Expected `make aws-s3-writer-plan` blast radius:

```text
aws_iam_user.external_k6_s3_writer
aws_iam_access_key.external_k6_s3_writer
aws_iam_user_policy.external_k6_s3_writer
```

It must not include VPC, subnet, NAT, Budget, Lambda, EKS, RDS, Hetzner, Vultr,
or Kubernetes resources.

## Troubleshooting

- If `make aws-s3-writer-apply` fails with missing bucket config, ensure
  `S3_BUCKET` exists in `env/vultr.env`, `env/hetzner.env`, or shell env.
- If AWS auth fails, refresh the `terraform-process` profile before applying.
- If Vultr or Hetzner preflight says S3 writer credentials are unavailable, run
  `make aws-s3-writer-apply` or set manual fallback credentials in the provider
  env file.
- If Docker image checks fail, push the pinned image tag before preflight.

## Rollback

- To stop using Terraform-managed writer credentials, set
  `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` manually in the provider env
  file.
- To destroy the writer stack, first verify benchmark artifacts exist in S3,
  then run:

```bash
make aws-s3-writer-destroy-confirmed
```

Do not destroy the S3 bucket until thesis benchmark artifacts have been backed
up or explicitly declared safe to remove.
