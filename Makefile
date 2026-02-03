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

.PHONY: help docker-check k8s-check docker-build-image argocd-install traefik-install monitoring-urls argocd-password argocd-url app-urls argocd-deploy-apps argocd-sync status lint cleanup k8s-kind-up k8s-minikube-up k8s-use-context

help:
	@echo "Targets:"
	@echo "  docker-check          Verify Docker Desktop is installed and running"
	@echo "  k8s-check             Verify kubectl context (kind-* or docker-desktop)"
	@echo "  k8s-kind-up           Create a kind cluster (KIND_CLUSTER); preferred over Docker Desktop"
	@echo "  k8s-minikube-up       Start a minikube profile (MINIKUBE_PROFILE)"
	@echo "  k8s-use-context       Switch kubectl context (K8S_CONTEXT)"
	@echo "  docker-build-image IMAGE_TAG=...   Build and push multi-arch image to GHCR"
	@echo "  traefik-install        Install Traefik ingress controller"
	@echo "  argocd-install         Install Argo CD (pinned version)"
	@echo "  monitoring-urls        Port-forward Grafana and Prometheus"
	@echo "  argocd-password        Show Argo CD admin password"
	@echo "  argocd-url             Port-forward Argo CD UI only"
	@echo "  app-urls               Port-forward app URLs (dev/prod)"
	@echo "  argocd-deploy-apps     Apply parent Argo CD Application (app-of-apps)"
	@echo "  argocd-sync            Sync Argo CD apps (requires argocd CLI)"
	@echo "  status                 Show namespaces and Argo CD apps"
	@echo "  lint                   Run pre-commit and helm lint"
	@echo "  cleanup                Delete this repo's apps and namespaces"
	@echo ""
	@echo "Bootstrap from scratch (Kind): k8s-kind-up -> docker-check -> k8s-check -> docker-build-image -> traefik-install -> argocd-install -> argocd-deploy-apps -> argocd-url"

docker-check:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found. Install Docker Desktop."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "docker daemon not running. Start Docker Desktop."; exit 1; }
	@echo "docker ok"

k8s-check:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
	@ctx=$$(kubectl config current-context); \
	if [[ "$$ctx" = "docker-desktop" ]] || [[ "$$ctx" = kind-* ]]; then \
	  echo "kubectl context ok ($$ctx)"; \
	else \
	  echo "warning: context is '$$ctx' (expected kind-$(KIND_CLUSTER) or docker-desktop)"; \
	fi

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

docker-build-image:
	@docker buildx build --platform linux/amd64,linux/arm64 \
	  -t "$(IMAGE_NAME):$(IMAGE_TAG)" --push app

argocd-install:
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@ns=$(ARGOCD_NAMESPACE); \
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null; \
	helm repo update >/dev/null; \
	helm upgrade --install argocd argo/argo-cd -n "$$ns" --create-namespace \
	  --version "$(ARGOCD_CHART_VERSION)" -f tools/argocd-values.yaml

traefik-install:
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@helm repo add traefik https://traefik.github.io/charts >/dev/null; \
	helm repo update >/dev/null; \
	helm upgrade --install traefik traefik/traefik -n traefik --create-namespace -f tools/traefik-values.yaml

monitoring-urls:
	@kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80 >/tmp/grafana-port-forward.log 2>&1 & \
	kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >/tmp/prometheus-port-forward.log 2>&1 & \
	echo "Grafana: http://localhost:3000"; \
	echo "Prometheus: http://localhost:9090"

argocd-password:
	@ns=$(ARGOCD_NAMESPACE); \
	if kubectl -n "$$ns" get secret argocd-initial-admin-secret >/dev/null 2>&1; then \
	  kubectl -n "$$ns" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; \
	  echo; \
	else \
	  echo "argocd initial admin secret not found (admin may be disabled or already rotated)."; \
	fi

argocd-url:
	@kubectl -n argocd port-forward svc/argocd-server 8081:443 >/tmp/argocd-port-forward.log 2>&1 & \
	echo "Argo CD UI: https://localhost:8081"

app-urls:
	@kubectl -n $(APP_DEV_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_DEV_LOCAL_PORT):80 >/tmp/$(APP_DEV_NAMESPACE)-port-forward.log 2>&1 & \
	kubectl -n $(APP_PROD_NAMESPACE) port-forward svc/$(APP_SERVICE) $(APP_PROD_LOCAL_PORT):80 >/tmp/$(APP_PROD_NAMESPACE)-port-forward.log 2>&1 & \
	echo "App (dev):  http://localhost:$(APP_DEV_LOCAL_PORT)"; \
	echo "App (dev) metrics:  http://localhost:$(APP_DEV_LOCAL_PORT)/metrics"; \
	echo "App (prod): http://localhost:$(APP_PROD_LOCAL_PORT)"; \
	echo "App (prod) metrics: http://localhost:$(APP_PROD_LOCAL_PORT)/metrics"

argocd-deploy-apps:
	@kubectl apply -n argocd -f deploy/argocd/applications.yaml


argocd-sync:
	@command -v argocd >/dev/null 2>&1 || { echo "argocd CLI not found"; exit 1; }
	@argocd app sync sre-gitops-apps || true

status:
	@kubectl get ns | grep -E "argocd|web-app-dev|web-app-prod|monitoring" || true
	@kubectl -n argocd get applications.argoproj.io 2>/dev/null || true

lint:
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not found"; exit 1; }
	@pre-commit run --all-files
	@helm lint charts/web-app

cleanup:
	@rm -f /tmp/argocd-port-forward.log \
	      /tmp/$(APP_DEV_NAMESPACE)-port-forward.log \
	      /tmp/$(APP_PROD_NAMESPACE)-port-forward.log \
	      /tmp/grafana-port-forward.log \
	      /tmp/prometheus-port-forward.log
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && ( \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application sre-gitops-apps --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-dev --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-prod --ignore-not-found; \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application monitoring --ignore-not-found; \
	) || true
	@kubectl delete namespace "$(APP_DEV_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace "$(APP_PROD_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace monitoring --ignore-not-found
