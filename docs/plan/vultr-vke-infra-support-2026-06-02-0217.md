# Vultr VKE Infrastructure Support Progress Tracker

Date: 2026-06-02 02:17 Asia/Jakarta

## Objective

Add Vultr as an additive benchmark provider using Vultr Kubernetes Engine (VKE),
Vultr Compute PostgreSQL nodes, AWS S3 artifact storage, Docker Hub public
images, Datadog observability, and Terraform-managed lifecycle.

## Progress

- [x] Phase 0: Audit current docs, scripts, manifests, Terraform, and worktree status.
- [x] Phase 1: Add provider dispatch helper for aws/hetzner/vultr.
- [x] Phase 2: Add Vultr env init and tfvars renderer.
- [x] Phase 3: Add Vultr Terraform shared, parallel, and sequential stacks.
- [x] Phase 4: Add Vultr kubecontext setup and node-label/taint validation.
- [x] Phase 5: Add Vultr secret creation scripts.
- [x] Phase 6: Add Vultr resource baseline measurement.
- [x] Phase 7: Add Vultr manifest renderer and rendered-asset validation.
- [x] Phase 8: Wire Vultr into deploy-all, deploy sequential, benchmark single-run, and benchmark suite scripts.
- [x] Phase 9: Add Vultr Make targets.
- [x] Phase 10: Update infra, experiment, architecture, diagram, and secret docs.
- [x] Phase 10a: Add Vultr mechanism, configuration, topology diagram, and end-to-end runbook docs.
- [x] Phase 11: Run static validation.
- [ ] Phase 12: Run live sequential fixed/HPA smoke.
- [ ] Phase 13: Run live parallel fixed/HPA smoke.
- [ ] Phase 14: Verify S3 artifact guard, destroy flow, and cost-leak cleanup.

## Implementation Notes

- VKE must use legacy Vultr VPC Network, not VPC 2.0.
- Vultr render path must fail if `env/vultr-resource-baseline.env` is missing.
- Vultr benchmark paths must never fall through to EKS renderer or EKS Terraform metadata.
- Fixed mode must remove stale HPA objects before benchmark execution.
- HPA mode must verify expected HPA objects and metrics-server readiness before benchmark execution.
- Documentation must point operators to the Vultr-specific architecture,
  configuration reference, topology diagram, and runbook instead of leaving only
  AWS/EKS or Hetzner-oriented guidance.
