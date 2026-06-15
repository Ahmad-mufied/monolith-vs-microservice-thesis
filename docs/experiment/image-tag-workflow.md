# Image Tag Workflow

## Purpose

This document defines the image tag workflow for final benchmark experiments.
It focuses on the active Vultr path, where benchmark images are stored in
Docker Hub and Kubernetes manifests are rendered with one explicit image tag.

The goal is to keep all deployables on the same application revision during a
measured run.

Required Docker Hub repositories:

```text
monolith
api-gateway
auth-service
item-service
transaction-service
seed-runner
k6-runner
```

All seven repositories must have the selected `IMAGE_TAG` before deployment.

---

## 1. List Available Tags

Use this command when choosing which Docker Hub tag to use:

```bash
make dockerhub-list-images
```

By default, this lists available tags for the required Docker Hub repositories.
It reads `DOCKERHUB_NAMESPACE` from the shell or from `env/vultr.env`.

Optional hardening for repeated operator use:

- `DOCKERHUB_TOKEN=<token>` adds an authenticated Docker Hub API header.
- `DOCKERHUB_USER=<user>` plus `DOCKERHUB_TOKEN=<token>` uses Basic auth.
- The script retries a small number of times for Docker Hub API rate limiting
  or transient `5xx` failures.

Limit the number of tags shown per service:

```bash
make dockerhub-list-images DOCKERHUB_TAG_LIMIT=3
```

The output uses the operator timezone. The default timezone is
`Asia/Jakarta`, unless `DOCKERHUB_TIMEZONE` or `TZ` is set.

Example override:

```bash
DOCKERHUB_TIMEZONE=UTC make dockerhub-list-images DOCKERHUB_TAG_LIMIT=3
```

---

## 2. Check One Candidate Tag

After choosing a candidate tag, verify that it exists for all seven images:

```bash
make dockerhub-list-images IMAGE_TAG=670736c
```

Expected result:

```text
status      : FOUND
```

for every required service.

If any service is `MISSING`, do not deploy that tag. Rebuild and push all
images with the same tag:

```bash
make dockerhub-push-all IMAGE_TAG=670736c
```

Then rerun the check.

---

## 3. Pin the Selected Tag

Pinning writes the selected tag to `env/image-tag.env`:

```bash
make pin-image-tag IMAGE_TAG=670736c
make show-image-tag
```

Pinning provides a stable default for deploy and benchmark commands.

The resolution order is:

1. explicit `IMAGE_TAG=...` passed to the command,
2. `env/image-tag.env`,
3. legacy `env/image-tag.eks.env`,
4. current Git short SHA.

For final experiments, pin the selected tag and let deploy/suite commands use
that pinned default. Pass `IMAGE_TAG=<tag>` explicitly only when intentionally
overriding the pin for one command, and never pass an empty `IMAGE_TAG`.

---

## 4. Deploy or Run With the Selected Tag

Sequential Vultr deploy example:

```bash
ARCHITECTURE=monolith \
SCALING_MODE=fixed \
make deploy-workloads
```

Sequential Vultr suite example:

```bash
SCALING_MODE=fixed \
K6_PROFILE=steady \
RUN_ID=rq1-fixed-vultr-sequential \
make run-benchmark-suite
```

Override the pinned tag only when needed:

```bash
IMAGE_TAG=670736c make run-benchmark-suite
```

For sequential Vultr suites, `make run-benchmark-suite` deploys each
architecture phase internally with the fixed suite baseline and the selected
`IMAGE_TAG`. Supplemental HPA measurements are executed outside the suite via
`make run-benchmark-case`, `make run-benchmark-sequential`, or
`make run-benchmark-parallel`.

When a suite run omits `RUN_ID` but sets `EXPERIMENT_NAME`, the current
benchmark runners include the active `IMAGE_TAG` in the default generated
`RUN_ID`. This keeps the run folder readable for operators while still tying it
to the exact deployable image revision that was measured.

---

## 5. Final Experiment Rules

- Use one `IMAGE_TAG` for all deployables in one measured experiment session.
- Do not rebuild a different commit into an existing experiment tag.
- If code changes, create a new tag and push all seven images again.
- Verify the selected tag with `make dockerhub-list-images IMAGE_TAG=<tag>`
  before deploy.
- Pin the selected tag for operator safety.
- Let deploy and fixed benchmark suite commands use the pinned tag unless you are
  intentionally overriding it with a non-empty `IMAGE_TAG=<tag>`.
- Verify benchmark metadata includes the expected `image_tag`.
