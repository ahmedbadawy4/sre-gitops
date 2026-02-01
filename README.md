# SRE GitOps

Use the Makefile to bootstrap Argo CD, build the app image, and deploy via GitOps.

## Architecture (high level)

- Diagram:
  ```
  Git Repo (app + Helm)
            |
            v
        Argo CD
            |
            v
   Kubernetes Cluster
     - web-app-dev
     - web-app-prod
  ```

- Git repo holds application code and Helm chart.
- Argo CD watches the repo and syncs desired state into the cluster.
- Two environments (dev/prod) are separated by namespaces and values files.

## Prereqs
- One Kubernetes option: Docker Desktop, kind, minikube, or an existing cluster
- `kubectl` + `docker` + `helm` CLIs available
- Internet access for Argo CD manifest fetch
- Optional for local linting: `pre-commit` (and `helm` + `hadolint`)

## Create or select a cluster (first)

Choose one of the following so all subsequent steps target the right cluster:

```
make kind-up KIND_CLUSTER=sre-gitops
make minikube-up MINIKUBE_PROFILE=sre-gitops
make use-context K8S_CONTEXT=<existing-context>
```

Suggested pinned versions (optional):

- Kind: create the cluster with a pinned node image (e.g., `kindest/node:v1.29.4`).
- Minikube: start with a pinned Kubernetes version (e.g., `--kubernetes-version=v1.29.4`).

## Quickstart (Makefile-first)

```
# Verify Docker is installed and running.
make check-docker
# Verify kubectl context.
make check-k8s
# Build the app image locally (default IMAGE_TAG=main).
make build-image
# Install Argo CD via Helm using tools/argocd-values.yaml.
make install-argocd
# Deploy the dev Application (REPO_URL must be your fork).
make deploy-dev REPO_URL=https://github.com/ahmedbadawy4/sre-gitops.git
```

Port-forward Argo CD + app URLs:

```
make helm-urls
```

## Deploy prod

```
make deploy-prod REPO_URL=https://github.com/ahmedbadawy4/sre-gitops.git
```

## Update image tag (GitOps flow)

```
make update-image-tag ENV=dev IMAGE_TAG=main
git add charts/values-dev.yaml
git commit -m "release: main"
git push
```

Notes:
- Argo CD Helm chart version is pinned via `ARGOCD_CHART_VERSION` in `Makefile`.
- Image tags default to `git describe --tags --always` (falls back to `main`).

## Reliability and security

- Health checks: readiness and liveness probes are configured in the Helm chart.
- Resource requests/limits: set per environment in `charts/values-*.yaml`.
- Environment separation: dev/prod use different namespaces and values files.
- Metrics: `/metrics` endpoint exposes basic Prometheus-style counters.
- Argo CD RBAC: default policy is readonly, admin is explicitly mapped in `tools/argocd-values.yaml`.

## Assumptions and tradeoffs

- Uses local clusters (kind/minikube/Docker Desktop) for simplicity.
- Argo CD is installed via Helm to keep installation declarative and reproducible.
- Image tags are derived from Git tags/commits; pushing a new tag requires a Git update to values files.

## What I would improve with more time

- Add Argo CD repo credentials and secrets management (e.g., External Secrets or Sealed Secrets).
- Add centralized logging and/or alerts for sync failures.
- Add CI/CD pipeline to build/push images and open PRs to bump image tags.

## Cleanup

```
# Stop local port-forward processes and remove temp pid/log files.
make cleanup-port-forward
# Delete Argo CD Application objects so Argo CD stops reconciling them.
make cleanup-argocd-apps
# Aggressive: deletes app namespaces and Argo CD CRDs/cluster roles (cluster-wide impact).
make cleanup-app
# Delete the Argo CD namespace (use with care if other Argo CD apps exist).
make cleanup-argocd
```

## PR checks and local linting

- GitHub Actions runs Helm lint + YAML checks + Dockerfile lint on pull requests.
- For local checks:
  ```
  pre-commit install
  pre-commit run --all-files
  ```

## TODOs (production hardening)

```
- Enable SSO or OIDC for Argo CD and disable the default admin user.
- Store repo credentials in a secret manager (External Secrets/Sealed Secrets).
- Enforce TLS on Argo CD server and restrict network access (ingress + firewall).
- Define least-privilege RBAC for users and automation.
```
