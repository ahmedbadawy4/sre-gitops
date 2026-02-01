# SRE GitOps

Use the Makefile to bootstrap Argo CD, build the app image, and deploy via GitOps.

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
