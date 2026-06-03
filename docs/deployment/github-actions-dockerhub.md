# Docker Hub Build and Push Automation via GitHub Actions

## 1. Overview

This document describes the automated CI/CD pipeline that builds and pushes the 7 benchmark Docker images to Docker Hub. This automation ensures consistency between local code changes and deployed cluster images, eliminates manual push mistakes, and simplifies the operator's benchmark lifecycle on Vultr and Hetzner.

The active workflow configuration is located in:
[.github/workflows/docker-build-push.yml](file:///mnt/Cons/Amikom/semester/Semester%207/Skrips/experimen/april/code/monolith-vs-microservice-thesis/.github/workflows/docker-build-push.yml)

---

## 2. Pipeline Mechanics & Optimization

```text
Developer PR Merge to main
  -> GitHub Actions Triggered
  -> Logs in to Docker Hub using GitHub Encrypted Secrets
  -> Resolves Git Short Commit SHA (e.g. 9e274a4)
  -> Spawns 7 Parallel Build Jobs (one runner per image)
  -> Docker Buildx pulls cache from GitHub Cache (type=gha)
  -> Builds image layers concurrently
  -> Pushes images concurrently to docker.io/<namespace>/<image>:<sha>
```

### Build Concurrency (Parallel Strategy)
- Define a GitHub Actions matrix that handles each service (`monolith`, `api-gateway`, `auth-service`, `item-service`, `transaction-service`, `seed-runner`, and `k6-runner`) inside its own independent runner.
- The total pipeline execution time drops from the sum of all builds (10-15 minutes) to the execution time of the slowest single build (typically 1.5 - 2 minutes on cold runs).
- Failures are isolated: If one service fails to compile, only that specific service's job fails, allowing for quick inspection and target-specific rebuilds.

### Docker Layer Caching (`type=gha`)
- The pipeline utilizes the **GitHub Actions Cache backend** (`type=gha`) with `mode=max` to store and export build layers (specifically Go package downloads and intermediate compiles).
- Each service has an isolated cache `scope` (`scope=${{ matrix.service.name }}`) to prevent cache pollution and invalidations between services.
- **Cache Hit Benefit**: When `go.mod` / `go.sum` and internal packages remain unchanged, subsequent merge builds complete in **under 30 seconds** as almost all build stages are skipped.

---

## 3. GitHub Secrets Configuration (One-time Setup)

To allow the GitHub Actions runner to authenticate and push to your Docker Hub registry, you must configure two Repository Secrets:

1. **Get a Docker Hub Token**:
   - Log in to your Docker Hub account.
   - Go to **Account Settings** > **Security** > **Personal Access Tokens**.
   - Click **Generate New Token**. Give it a descriptive name (e.g., `github-actions-benchmark`) and select **Read & Write** permissions.
   - Copy the generated token.

2. **Add Secrets to GitHub**:
   - Go to your repository page on GitHub.
   - Navigate to **Settings** > **Secrets and variables** > **Actions**.
   - Click **New repository secret** and add:
     - Name: `DOCKERHUB_USERNAME`
       Value: `<your-dockerhub-username>` (e.g., `ahmadryzen`)
     - Name: `DOCKERHUB_TOKEN`
       Value: `<paste-copied-docker-hub-token>`

---

## 4. Operator Workflow Integration

Once the GitHub Actions workflow is running and secrets are set, you can integrate it into your benchmark execution lifecycle:

### Step 1 — Make code changes and push to main
Merge your code/schema changes into the `main` branch. GitHub Actions will start building and pushing the images immediately. You can track progress under the **Actions** tab of your repository.

### Step 2 — Sync your local repository
Pull the latest merged commit to your local developer machine:
```bash
git checkout main
git pull
```

### Step 3 — Pin the image tag locally
Run the pin command. Since your local HEAD now matches the commit on `main`, running the pin target without arguments will automatically resolve to the correct short commit SHA:
```bash
make pin-image-tag
```
This writes the SHA to `env/image-tag.env` so that all local deploy and check scripts know which image tag to target.

### Step 4 — Run preflight check
Run preflight check to verify that all images are visible on Docker Hub:
```bash
make vultr-preflight-check
```

### Step 5 — Deploy and benchmark
Run your normal deploy and benchmark commands. The manifests rendered by `make vultr-render-manifests` will automatically point to the newly built image tag!
```bash
SCALING_MODE=fixed make vultr-deploy-all
```

---

## 5. Troubleshooting & Caching

### 1. Re-downloading dependencies on every build (Cache Miss)
- **Cause**: If `go.mod` or `go.sum` is modified, the cache layer for Go package downloads will be invalidated, triggering a fresh download. This is expected.
- **Fix**: No action is needed. The subsequent build will cache the new dependencies automatically.

### 2. Job fails on ECR references
- **Cause**: Standard manifests under EKS overlays still point to placeholders or AWS ECR.
- **Fix**: The pre-render script `render-vultr-manifests.sh` automatically patches registry namespaces to `docker.io/<username>`. Verify that `vultr.env` has the correct `DOCKERHUB_NAMESPACE` configured.
