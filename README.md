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

```bash
make k8s-kind-up KIND_CLUSTER=sre-gitops
make k8s-minikube-up MINIKUBE_PROFILE=sre-gitops
make k8s-use-context K8S_CONTEXT=<existing-context>
```

Suggested pinned versions (optional):

- Kind: `make k8s-kind-up KIND_CLUSTER=sre-gitops KIND_NODE_IMAGE=kindest/node:v1.35.0`.
- Minikube: `make k8s-minikube-up MINIKUBE_PROFILE=sre-gitops MINIKUBE_K8S_VERSION=v1.35.0`.

## Quickstart (Makefile-first)

```bash
# Verify Docker is installed and running.
make docker-check
# Verify kubectl context.
make k8s-check
# Build the app image locally (default IMAGE_TAG=main).
make docker-build-image
# Install Traefik ingress controller (if not already present).
make traefik-install
# Install Argo CD via Helm using tools/argocd-values.yaml.
make argocd-install
# Deploy the dev Application.
make helm-deploy-dev
# Port-forward Argo CD locally.
make argocd-url
```

Port-forward app URLs:

```bash
make app-urls
```

## Argo CD access

Local (port-forward):

```bash
make argocd-url
```

Local (ingress, default/self-signed cert):

- Requires Traefik (or an ingress class named `traefik`).
- Add to `/etc/hosts` for Docker Desktop:
  ```
  127.0.0.1 argocd.local
  ```
- Access: `https://argocd.local` (browser warning is expected).

Production (real domain + valid TLS):

- Use a real DNS name, e.g., `argocd.example.com`.
- Point DNS to your ingress IP / load balancer.
- Use cert-manager + Let’s Encrypt (recommended) to issue a valid cert.

## Deploy prod

```bash
make helm-deploy-prod
```

## Update image tag (GitOps flow)

```bash
make helm-update-image-tag ENV=dev IMAGE_TAG=main
git add charts/values-dev.yaml
git commit -m "release: main"
git push
```

Notes:
- Argo CD Helm chart version is pinned via `ARGOCD_CHART_VERSION` in `Makefile`.
- Image tags default to `git describe --tags --always` (falls back to `main`).
- On Git tag push (e.g., `v0.0.1`), the **Release (Prod Tag Update)** workflow updates `charts/values-prod.yaml` to that tag.

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

```bash
# Stop local port-forward processes and remove temp pid/log files.
make argocd-cleanup-port-forward
# Delete Argo CD Application objects so Argo CD stops reconciling them.
make argocd-cleanup-apps
# Aggressive: deletes app namespaces and Argo CD CRDs/cluster roles (cluster-wide impact).
make argocd-cleanup-app
# Delete Argo CD namespace and app resources (full cleanup).
make cleanup
```

## PR checks and local linting

- GitHub Actions runs Helm lint + YAML checks + Dockerfile lint on pull requests.
- For local checks:
  
  ```bash
  pre-commit install
  pre-commit run --all-files
  ```

## TODOs (production hardening)

- Enable SSO or OIDC for Argo CD and disable the default admin user.
- Add Argo CD repo credentials (only needed for private repos).
- Store repo credentials in a secret manager (External Secrets/Sealed Secrets).
- Enforce TLS on Argo CD server and restrict network access (ingress + firewall).
- Define least-privilege RBAC for users and automation.
