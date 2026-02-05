SHELL := /bin/bash

ARGOCD_CHART_VERSION ?= 6.7.12
ARGOCD_NAMESPACE ?= argocd
APP_SERVICE ?= web-app
APP_DEV_NAMESPACE ?= web-app-dev
APP_PROD_NAMESPACE ?= web-app-prod
APP_DEV_LOCAL_PORT ?= 8080
APP_PROD_LOCAL_PORT ?= 8082
IMAGE_NAME ?= ghcr.io/ahmedbadawy4/sre-gitops
IMAGE_TAG ?= $(shell git describe --tags --always 2>/dev/null || echo main)
KIND_CLUSTER ?= sre-gitops
KIND_NODE_IMAGE ?= kindest/node:v1.35.0
MINIKUBE_PROFILE ?= sre-gitops
MINIKUBE_K8S_VERSION ?= v1.35.0
K8S_CONTEXT ?=

.DEFAULT_GOAL := help

.PHONY: help tools-check docker-check k8s-check docker-build-image docker-build-image-local \
	docker-build-image-kind k8s-kind-up k8s-minikube-up k8s-use-context traefik-install \
	argocd-install argocd-deploy-apps argocd-sync argocd-password argocd-url app-urls \
	monitoring-urls status cleanup-port-forwards cleanup-apps argocd-cleanup-port-forward \
	argocd-cleanup-apps cleanup lint bootstrap-kind bootstrap-minikube up down pf-stop \
	apps-delete kind-load

help:
	@echo "Targets:"
	@echo "  tools-check           Verify required CLIs are installed"
	@echo "  docker-check          Verify Docker Desktop is installed and running"
	@echo "  k8s-check             Verify kubectl context (kind-*, docker-desktop, or minikube)"
	@echo "  k8s-kind-up           Create a kind cluster (KIND_CLUSTER); preferred over Docker Desktop"
	@echo "  k8s-minikube-up       Start a minikube profile (MINIKUBE_PROFILE)"
	@echo "  k8s-use-context       Switch kubectl context (K8S_CONTEXT)"
	@echo "  docker-build-image IMAGE_TAG=...   Build and push multi-arch image to GHCR"
	@echo "  docker-build-image-local IMAGE_TAG=...   Build local image (no push)"
	@echo "  docker-build-image-kind IMAGE_TAG=...    Build local image and load into kind"
	@echo "  kind-load IMAGE_TAG=...            Load local image into kind"
	@echo "  traefik-install        Install Traefik ingress controller"
	@echo "  argocd-install         Install Argo CD (pinned version)"
	@echo "  argocd-deploy-apps     Apply parent Argo CD Application (app-of-apps)"
	@echo "  argocd-sync            Sync Argo CD apps (requires argocd CLI)"
	@echo "  argocd-password        Show Argo CD admin password"
	@echo "  argocd-url             Port-forward Argo CD UI only"
	@echo "  app-urls               Port-forward app URLs (dev/prod)"
	@echo "  monitoring-urls        Port-forward Grafana and Prometheus"
	@echo "  status                 Show namespaces and Argo CD apps"
	@echo "  cleanup-port-forwards  Stop local port-forward processes and remove temp files"
	@echo "  cleanup-apps           Delete Argo CD Applications for this repo"
	@echo "  argocd-cleanup-port-forward  Alias for cleanup-port-forwards"
	@echo "  argocd-cleanup-apps          Alias for cleanup-apps"
	@echo "  bootstrap-kind        One-shot local setup on kind"
	@echo "  bootstrap-minikube    One-shot local setup on minikube"
	@echo "  up                    Deploy apps via Argo CD (GitOps)"
	@echo "  down                  Remove apps and namespaces (cleanup)"
	@echo "  pf-stop               Stop port-forwards"
	@echo "  apps-delete           Delete Argo CD Applications for this repo"
	@echo "  cleanup                Delete this repo's apps and namespaces"
	@echo "  lint                   Run pre-commit and helm lint"
	@echo ""
	@echo "Bootstrap from scratch (Kind): tools-check -> k8s-kind-up -> docker-check -> k8s-check -> docker-build-image -> traefik-install -> argocd-install -> argocd-deploy-apps -> argocd-url"

# Preflight checks

tools-check:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "docker not found. Install Docker Desktop."; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@echo "tools ok"

docker-check:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found. Install Docker Desktop."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "docker daemon not running. Start Docker Desktop."; exit 1; }
	@echo "docker ok"

k8s-check:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
	@ctx=$$(kubectl config current-context); \
	if [[ "$$ctx" = "docker-desktop" ]] || [[ "$$ctx" = kind-* ]] || [[ "$$ctx" = "minikube" ]]; then \
	  echo "kubectl context ok ($$ctx)"; \
	else \
	  echo "warning: context is '$$ctx' (expected kind-$(KIND_CLUSTER), docker-desktop, or minikube)"; \
	fi

# Cluster lifecycle

k8s-kind-up:
	@command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
	@kind get clusters | grep -qx "$(KIND_CLUSTER)" || kind create cluster --name "$(KIND_CLUSTER)" --image "$(KIND_NODE_IMAGE)"
	@kubectl config use-context "kind-$(KIND_CLUSTER)"

k8s-minikube-up:
	@command -v minikube >/dev/null 2>&1 || { echo "minikube not found"; exit 1; }
	@minikube start -p "$(MINIKUBE_PROFILE)" --kubernetes-version="$(MINIKUBE_K8S_VERSION)"
	@kubectl config use-context "minikube"

k8s-use-context:
	@if [[ -z "$(K8S_CONTEXT)" ]]; then echo "K8S_CONTEXT is required"; exit 1; fi
	@kubectl config use-context "$(K8S_CONTEXT)"

# Build / publish

docker-build-image:
	@docker buildx build --platform linux/amd64,linux/arm64 \
	  -t "$(IMAGE_NAME):$(IMAGE_TAG)" --push app

docker-build-image-local:
	@docker build -t "$(IMAGE_NAME):$(IMAGE_TAG)" app

docker-build-image-kind:
	@command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
	@docker build -t "$(IMAGE_NAME):$(IMAGE_TAG)" app
	@kind load docker-image "$(IMAGE_NAME):$(IMAGE_TAG)" --name "$(KIND_CLUSTER)"

kind-load:
	@command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
	@kind load docker-image "$(IMAGE_NAME):$(IMAGE_TAG)" --name "$(KIND_CLUSTER)"

# Platform installs

traefik-install:
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@helm repo add traefik https://traefik.github.io/charts >/dev/null; \
	helm repo update >/dev/null; \
	helm upgrade --install traefik traefik/traefik -n traefik --create-namespace -f tools/traefik-values.yaml

argocd-install:
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@ns=$(ARGOCD_NAMESPACE); \
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null; \
	helm repo update >/dev/null; \
	helm upgrade --install argocd argo/argo-cd -n "$$ns" --create-namespace \
	  --version "$(ARGOCD_CHART_VERSION)" -f tools/argocd-values.yaml

# GitOps deploy

argocd-deploy-apps:
	@kubectl apply -n "$(ARGOCD_NAMESPACE)" -f deploy/argocd/applications.yaml

argocd-sync:
	@command -v argocd >/dev/null 2>&1 || { echo "argocd CLI not found"; exit 1; }
	@argocd app sync sre-gitops-apps || true

# Access / UX

argocd-password:
	@ns=$(ARGOCD_NAMESPACE); \
	if kubectl -n "$$ns" get secret argocd-initial-admin-secret >/dev/null 2>&1; then \
	  kubectl -n "$$ns" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; \
	  echo; \
	else \
	  echo "argocd initial admin secret not found (admin may be disabled or already rotated)."; \
	fi

argocd-url:
	@pid=/tmp/argocd-port-forward.pid; log=/tmp/argocd-port-forward.log; \
	if [[ -f $$pid ]]; then \
	  if kill -0 "$$(cat $$pid)" >/dev/null 2>&1; then \
	    echo "Argo CD port-forward already running (pid $$(cat $$pid))"; exit 0; \
	  else \
	    rm -f $$pid $$log; \
	  fi; \
	fi; \
	kubectl -n "$(ARGOCD_NAMESPACE)" port-forward svc/argocd-server 8081:443 >$$log 2>&1 & \
	echo $$! > $$pid; \
	echo "Argo CD UI: https://localhost:8081"

app-urls:
	@pid=/tmp/$(APP_DEV_NAMESPACE)-port-forward.pid; log=/tmp/$(APP_DEV_NAMESPACE)-port-forward.log; \
	if [[ -f $$pid ]]; then \
	  if kill -0 "$$(cat $$pid)" >/dev/null 2>&1; then \
	    echo "App dev port-forward already running (pid $$(cat $$pid))"; \
	  else \
	    rm -f $$pid $$log; \
	    kubectl -n $(APP_DEV_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_DEV_LOCAL_PORT):80 >$$log 2>&1 & \
	    echo $$! > $$pid; \
	  fi; \
	else \
	  kubectl -n $(APP_DEV_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_DEV_LOCAL_PORT):80 >$$log 2>&1 & \
	  echo $$! > $$pid; \
	fi; \
	pid=/tmp/$(APP_PROD_NAMESPACE)-port-forward.pid; log=/tmp/$(APP_PROD_NAMESPACE)-port-forward.log; \
	if [[ -f $$pid ]]; then \
	  if kill -0 "$$(cat $$pid)" >/dev/null 2>&1; then \
	    echo "App prod port-forward already running (pid $$(cat $$pid))"; \
	  else \
	    rm -f $$pid $$log; \
	    kubectl -n $(APP_PROD_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_PROD_LOCAL_PORT):80 >$$log 2>&1 & \
	    echo $$! > $$pid; \
	  fi; \
	else \
	  kubectl -n $(APP_PROD_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_PROD_LOCAL_PORT):80 >$$log 2>&1 & \
	  echo $$! > $$pid; \
	fi; \
	echo "App (dev):  http://localhost:$(APP_DEV_LOCAL_PORT)"; \
	echo "App (dev) metrics:  http://localhost:$(APP_DEV_LOCAL_PORT)/metrics"; \
	echo "App (prod): http://localhost:$(APP_PROD_LOCAL_PORT)"; \
	echo "App (prod) metrics: http://localhost:$(APP_PROD_LOCAL_PORT)/metrics"

monitoring-urls:
	@pid=/tmp/grafana-port-forward.pid; log=/tmp/grafana-port-forward.log; \
	if [[ -f $$pid ]]; then \
	  if kill -0 "$$(cat $$pid)" >/dev/null 2>&1; then \
	    echo "Grafana port-forward already running (pid $$(cat $$pid))"; \
	  else \
	    rm -f $$pid $$log; \
	    kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 >$$log 2>&1 & \
	    echo $$! > $$pid; \
	  fi; \
	else \
	  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 >$$log 2>&1 & \
	  echo $$! > $$pid; \
	fi; \
	pid=/tmp/prometheus-port-forward.pid; log=/tmp/prometheus-port-forward.log; \
	if [[ -f $$pid ]]; then \
	  if kill -0 "$$(cat $$pid)" >/dev/null 2>&1; then \
	    echo "Prometheus port-forward already running (pid $$(cat $$pid))"; \
	  else \
	    rm -f $$pid $$log; \
	    kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >$$log 2>&1 & \
	    echo $$! > $$pid; \
	  fi; \
	else \
	  kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >$$log 2>&1 & \
	  echo $$! > $$pid; \
	fi; \
	echo "Grafana: http://localhost:3000"; \
	echo "Prometheus: http://localhost:9090"

# Status / diagnostics

status:
	@kubectl get ns | grep -E "$(ARGOCD_NAMESPACE)|web-app-dev|web-app-prod|monitoring" || true
	@kubectl -n "$(ARGOCD_NAMESPACE)" get applications.argoproj.io 2>/dev/null || true

# Cleanup

cleanup-port-forwards:
	@for f in /tmp/argocd-port-forward.pid /tmp/$(APP_DEV_NAMESPACE)-port-forward.pid /tmp/$(APP_PROD_NAMESPACE)-port-forward.pid /tmp/grafana-port-forward.pid /tmp/prometheus-port-forward.pid; do \
	  if [[ -f $$f ]]; then \
	    pid="$$(cat $$f)"; \
	    if ps -p "$$pid" -o command= 2>/dev/null | grep -q "kubectl port-forward"; then \
	      kill "$$pid" >/dev/null 2>&1 || true; \
	    fi; \
	    rm -f $$f; \
	  fi; \
	done
	@rm -f /tmp/argocd-port-forward.log \
	      /tmp/$(APP_DEV_NAMESPACE)-port-forward.log \
	      /tmp/$(APP_PROD_NAMESPACE)-port-forward.log \
	      /tmp/grafana-port-forward.log \
	      /tmp/prometheus-port-forward.log

cleanup-apps:
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && ( \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application sre-gitops-apps --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-dev --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-prod --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application monitoring --ignore-not-found; \
	) || true

argocd-cleanup-port-forward: cleanup-port-forwards

argocd-cleanup-apps: cleanup-apps

cleanup: argocd-cleanup-port-forward argocd-cleanup-apps
	@kubectl delete namespace "$(APP_DEV_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace "$(APP_PROD_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace monitoring --ignore-not-found

# Aliases

bootstrap-kind: k8s-kind-up docker-check k8s-check docker-build-image-local kind-load traefik-install argocd-install argocd-deploy-apps argocd-url

bootstrap-minikube: k8s-minikube-up docker-check k8s-check docker-build-image-local traefik-install argocd-install argocd-deploy-apps argocd-url

up: argocd-deploy-apps

down: cleanup

pf-stop: cleanup-port-forwards

apps-delete: cleanup-apps

# Lint

lint:
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not found"; exit 1; }
	@pre-commit run --all-files
	@helm lint charts/web-app
