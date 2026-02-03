# SRE GitOps

[![CI](https://github.com/ahmedbadawy4/sre-gitops/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/ahmedbadawy4/sre-gitops/actions/workflows/pr-checks.yml)

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
# Build + push multi-arch to GHCR (requires docker login to ghcr.io).
make docker-build-image
# Install Traefik ingress controller (if not already present).
make traefik-install
# Install Argo CD via Helm using tools/argocd-values.yaml.
make argocd-install
# Deploy Argo CD apps (app-of-apps).
make argocd-deploy-apps
# Port-forward Argo CD locally.
make argocd-url
```

Port-forward app URLs:

```bash
make app-urls
```

Web app ingress (default cert):

- Dev: `https://web-app-dev.local` (add `127.0.0.1 web-app-dev.local` to `/etc/hosts`).
- Prod: `https://web-app-prod.local` (add `127.0.0.1 web-app-prod.local` to `/etc/hosts`).

Monitoring (Grafana + Prometheus):

```bash
make monitoring-urls
```

Upstream values reference: `https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml`

Grafana login: `admin` / (generated password). Import the sample dashboard from `tools/grafana-web-app-dashboard.json`.
Grafana password (generated):
```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode
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
- Traefik values can be customized in `tools/traefik-values.yaml`.

### Production (real domain + valid TLS):

- Use a real DNS name, e.g., `argocd.example.com`.
- Point DNS to your ingress IP / load balancer.
- Use cert-manager + Let’s Encrypt (recommended) to issue a valid cert.
  Example (outline):

  ```bash
  # 1) Install cert-manager (once)
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

  # 2) Create a ClusterIssuer (Let’s Encrypt)
  kubectl apply -f - <<'YAML'
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt
  spec:
    acme:
      email: you@example.com
      server: https://acme-v02.api.letsencrypt.org/directory
      privateKeySecretRef:
        name: letsencrypt
      solvers:
      - http01:
          ingress:
            class: traefik
  YAML

  # 3) Configure Argo CD ingress to request a cert
  # (set these in tools/argocd-values.yaml)
  # server:
  #   ingress:
  #     annotations:
  #       cert-manager.io/cluster-issuer: "letsencrypt"
  #     tls:
  #       - secretName: argocd-server-tls
  #         hosts:
  #           - argocd.example.com
  ```

## Image build and release (GitOps flow)

- On push to `main`, CI builds and pushes `ghcr.io/ahmedbadawy4/sre-gitops:main`.
- On Git tag push (e.g., `v0.0.1`), CI builds and pushes that tag and the **Release (Prod Tag Update)** workflow updates `charts/values-prod.yaml`.

Notes:
- Argo CD Helm chart version is pinned via `ARGOCD_CHART_VERSION` in `Makefile`.

Rollback (GitOps):

- Revert the commit that bumped `charts/values-*.yaml` and push.
- Argo CD will sync back to the previous image tag.

## Reliability and security

- Health checks: readiness and liveness probes are configured in the Helm chart.
- Resource requests/limits: set per environment in `charts/values-*.yaml`.
- Environment separation: dev/prod use different namespaces and values files.
- Metrics: `/metrics` endpoint exposes basic Prometheus-style counters.
- Argo CD RBAC: default policy is readonly, admin is explicitly mapped in `tools/argocd-values.yaml`.
- Web app sets basic security headers (CSP, X-Frame-Options, etc.) in `app/httpd.conf`.

## Assumptions and tradeoffs

- Uses local clusters (kind/minikube/Docker Desktop) for simplicity.
- Argo CD is installed via Helm to keep installation declarative and reproducible.
- Image tags are derived from Git tags/commits; pushing a new tag requires a Git update to values files.

## Private repo credentials (optional)

If the repo is private, Argo CD needs credentials. One approach is to create a repo secret:

```bash
kubectl -n argocd create secret generic private-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/ORG/REPO.git \
  --from-literal=username=GIT_USERNAME \
  --from-literal=password=GIT_TOKEN

kubectl -n argocd label secret private-repo \
  argocd.argoproj.io/secret-type=repository
```

## Cleanup

```bash
# Stop local port-forward processes and remove temp pid/log files.
make argocd-cleanup-port-forward
# Delete Argo CD Application objects so Argo CD stops reconciling them.
make argocd-cleanup-apps
# Delete only this repo's apps and namespaces (safe for shared clusters).
make cleanup
```

## PR checks and local linting

- GitHub Actions runs Helm lint + YAML checks + Dockerfile lint on pull requests.
- For local checks:

  ```bash
  pre-commit install
  pre-commit run --all-files
  ```

Useful targets:

```bash
# Sync Argo CD apps (requires argocd CLI).
make argocd-sync
# Show namespaces and Argo CD apps.
make status
# Run lint checks locally.
make lint
```

## TODOs (production hardening)

- Enable SSO or OIDC for Argo CD and disable the default admin user.
- Add Argo CD repo credentials (only needed for private repos).
- Store repo credentials in a secret manager (External Secrets/Sealed Secrets).
- Enforce TLS on Argo CD server and restrict network access (ingress + firewall).
- Define least-privilege RBAC for users and automation.
- Add centralized logging and/or alerts for sync failures.
- Add CI/CD pipeline to build/push images and open PRs to bump image tags.
- Add alerting rules for Prometheus/Grafana.
