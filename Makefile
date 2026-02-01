SHELL := /bin/bash

ARGOCD_VERSION ?= v2.10.9
ARGOCD_CHART_VERSION ?= 6.7.12
ARGOCD_NAMESPACE ?= argocd
APP_SERVICE ?= web-app
APP_DEV_NAMESPACE ?= web-app-dev
APP_PROD_NAMESPACE ?= web-app-prod
APP_DEV_LOCAL_PORT ?= 8080
APP_PROD_LOCAL_PORT ?= 8082
REPO_URL ?= https://github.com/ahmedbadawy4/sre-gitops.git
REVISION ?= main
IMAGE_NAME ?= sre-gitops/app
IMAGE_TAG ?= $(shell git describe --tags --always 2>/dev/null || echo main)
KIND_CLUSTER ?= sre-gitops
KIND_NODE_IMAGE ?= kindest/node:v1.35.0
MINIKUBE_PROFILE ?= sre-gitops
MINIKUBE_K8S_VERSION ?= v1.35.0
K8S_CONTEXT ?=

.PHONY: help docker-check k8s-check docker-build-image argocd-install traefik-install argocd-password argocd-urls argocd-url app-urls helm-deploy-dev helm-deploy-prod helm-update-image-tag argocd-cleanup-port-forward argocd-cleanup-apps argocd-cleanup-app cleanup k8s-kind-up k8s-minikube-up k8s-use-context

help:
	@echo "Targets:"
	@echo "  docker-check          Verify Docker Desktop is installed and running"
	@echo "  k8s-check             Verify kubectl context is docker-desktop"
	@echo "  k8s-kind-up           Create a kind cluster (KIND_CLUSTER)"
	@echo "  k8s-minikube-up       Start a minikube profile (MINIKUBE_PROFILE)"
	@echo "  k8s-use-context       Switch kubectl context (K8S_CONTEXT)"
	@echo "  docker-build-image IMAGE_TAG=...   Build the app image locally (default: main)"
	@echo "  argocd-install         Install Argo CD (pinned version)"
	@echo "  traefik-install        Install Traefik ingress controller"
	@echo "  argocd-password        Show Argo CD admin password"
	@echo "  argocd-urls            Port-forward and list Argo CD + app URLs"
	@echo "  argocd-url             Port-forward Argo CD UI only"
	@echo "  app-urls               Port-forward app URLs (dev/prod)"
	@echo "  helm-deploy-dev        Apply Argo CD Application for dev"
	@echo "  helm-deploy-prod       Apply Argo CD Application for prod"
	@echo "  helm-update-image-tag ENV=dev IMAGE_TAG=main  Update image tag in values"
	@echo "  argocd-cleanup-port-forward   Stop port-forwards and remove local pid/log files"
	@echo "  argocd-cleanup-apps    Delete Argo CD Applications (dev/prod)"
	@echo "  argocd-cleanup-app     Delete app namespaces and Argo CD CRDs/roles"
	@echo "  cleanup                Delete Argo CD namespace and app resources"

docker-check:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found. Install Docker Desktop."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "docker daemon not running. Start Docker Desktop."; exit 1; }
	@echo "docker ok"

k8s-check:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
	@ctx=$$(kubectl config current-context); \
	if [[ "$$ctx" != "docker-desktop" ]]; then \
	  echo "warning: context is '$$ctx' (expected docker-desktop)"; \
	else \
	  echo "kubectl context ok ($$ctx)"; \
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
	@docker build -t "$(IMAGE_NAME):$(IMAGE_TAG)" app
	@echo "built $(IMAGE_NAME):$(IMAGE_TAG)"

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
	helm upgrade --install traefik traefik/traefik -n traefik --create-namespace

argocd-password:
	@ns=$(ARGOCD_NAMESPACE); \
	if kubectl -n "$$ns" get secret argocd-initial-admin-secret >/dev/null 2>&1; then \
	  kubectl -n "$$ns" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; \
	  echo; \
	else \
	  echo "argocd initial admin secret not found (admin may be disabled or already rotated)."; \
	fi

argocd-urls:
	@argocd_ns=$(ARGOCD_NAMESPACE); \
	argocd_log="/tmp/argocd-port-forward.log"; \
	argocd_pid="/tmp/argocd-port-forward.pid"; \
	kubectl -n "$$argocd_ns" port-forward svc/argocd-server 8081:443 >"$$argocd_log" 2>&1 & \
	echo $$! > "$$argocd_pid"; \
	app_dev_ns=$(APP_DEV_NAMESPACE); \
	app_dev_log="/tmp/$(APP_DEV_NAMESPACE)-port-forward.log"; \
	app_dev_pid="/tmp/$(APP_DEV_NAMESPACE)-port-forward.pid"; \
	if kubectl -n "$$app_dev_ns" get svc "$(APP_SERVICE)" >/dev/null 2>&1; then \
	  kubectl -n "$$app_dev_ns" port-forward svc/$(APP_SERVICE) $(APP_DEV_LOCAL_PORT):80 >"$$app_dev_log" 2>&1 & \
	  echo $$! > "$$app_dev_pid"; \
	else \
	  echo "warning: svc/$(APP_SERVICE) not found in $$app_dev_ns (skipping dev app port-forward)"; \
	fi; \
	app_prod_ns=$(APP_PROD_NAMESPACE); \
	app_prod_log="/tmp/$(APP_PROD_NAMESPACE)-port-forward.log"; \
	app_prod_pid="/tmp/$(APP_PROD_NAMESPACE)-port-forward.pid"; \
	if kubectl -n "$$app_prod_ns" get svc "$(APP_SERVICE)" >/dev/null 2>&1; then \
	  kubectl -n "$$app_prod_ns" port-forward svc/$(APP_SERVICE) $(APP_PROD_LOCAL_PORT):80 >"$$app_prod_log" 2>&1 & \
	  echo $$! > "$$app_prod_pid"; \
	else \
	  echo "warning: svc/$(APP_SERVICE) not found in $$app_prod_ns (skipping prod app port-forward)"; \
	fi; \
	echo "Argo CD UI: https://localhost:8081"; \
	echo "App (dev):  http://localhost:$(APP_DEV_LOCAL_PORT)"; \
	echo "App (dev) metrics:  http://localhost:$(APP_DEV_LOCAL_PORT)/metrics"; \
	echo "App (prod): http://localhost:$(APP_PROD_LOCAL_PORT)"; \
	echo "App (prod) metrics: http://localhost:$(APP_PROD_LOCAL_PORT)/metrics"; \
	echo "port-forward pids: $$(cat $$argocd_pid 2>/dev/null || echo '?') $$(cat $$app_dev_pid 2>/dev/null || echo '?') $$(cat $$app_prod_pid 2>/dev/null || echo '?')"

argocd-url:
	@argocd_ns=$(ARGOCD_NAMESPACE); \
	argocd_log="/tmp/argocd-port-forward.log"; \
	argocd_pid="/tmp/argocd-port-forward.pid"; \
	kubectl -n "$$argocd_ns" port-forward svc/argocd-server 8081:443 >"$$argocd_log" 2>&1 & \
	echo $$! > "$$argocd_pid"; \
	echo "Argo CD UI: https://localhost:8081"; \
	echo "port-forward pid: $$(cat $$argocd_pid 2>/dev/null || echo '?')"

app-urls:
	@app_dev_ns=$(APP_DEV_NAMESPACE); \
	app_dev_log="/tmp/$(APP_DEV_NAMESPACE)-port-forward.log"; \
	app_dev_pid="/tmp/$(APP_DEV_NAMESPACE)-port-forward.pid"; \
	if kubectl -n "$$app_dev_ns" get svc "$(APP_SERVICE)" >/dev/null 2>&1; then \
	  kubectl -n "$$app_dev_ns" port-forward svc/$(APP_SERVICE) $(APP_DEV_LOCAL_PORT):80 >"$$app_dev_log" 2>&1 & \
	  echo $$! > "$$app_dev_pid"; \
	else \
	  echo "warning: svc/$(APP_SERVICE) not found in $$app_dev_ns (skipping dev app port-forward)"; \
	fi; \
	app_prod_ns=$(APP_PROD_NAMESPACE); \
	app_prod_log="/tmp/$(APP_PROD_NAMESPACE)-port-forward.log"; \
	app_prod_pid="/tmp/$(APP_PROD_NAMESPACE)-port-forward.pid"; \
	if kubectl -n "$$app_prod_ns" get svc "$(APP_SERVICE)" >/dev/null 2>&1; then \
	  kubectl -n "$$app_prod_ns" port-forward svc/$(APP_SERVICE) $(APP_PROD_LOCAL_PORT):80 >"$$app_prod_log" 2>&1 & \
	  echo $$! > "$$app_prod_pid"; \
	else \
	  echo "warning: svc/$(APP_SERVICE) not found in $$app_prod_ns (skipping prod app port-forward)"; \
	fi; \
	echo "App (dev):  http://localhost:$(APP_DEV_LOCAL_PORT)"; \
	echo "App (dev) metrics:  http://localhost:$(APP_DEV_LOCAL_PORT)/metrics"; \
	echo "App (prod): http://localhost:$(APP_PROD_LOCAL_PORT)"; \
	echo "App (prod) metrics: http://localhost:$(APP_PROD_LOCAL_PORT)/metrics"; \
	echo "port-forward pids: $$(cat $$app_dev_pid 2>/dev/null || echo '?') $$(cat $$app_prod_pid 2>/dev/null || echo '?')"

helm-deploy-dev:
	@if [[ -z "$(REPO_URL)" ]]; then echo "REPO_URL is required"; exit 1; fi
	@ns=$(ARGOCD_NAMESPACE); \
	template="deploy/argocd/application-dev.yaml.tmpl"; \
	if [[ ! -f "$$template" ]]; then echo "missing template: $$template" >&2; exit 1; fi; \
	TEMPLATE_PATH="$$template" REPO_URL="$(REPO_URL)" REVISION="$(REVISION)" \
	python3 -c 'from pathlib import Path; import os; text=Path(os.environ["TEMPLATE_PATH"]).read_text(); print(text.replace("{{REPO_URL}}", os.environ["REPO_URL"]).replace("{{REVISION}}", os.environ.get("REVISION","main")))' \
	| kubectl apply -n "$$ns" -f -

helm-deploy-prod:
	@if [[ -z "$(REPO_URL)" ]]; then echo "REPO_URL is required"; exit 1; fi
	@ns=$(ARGOCD_NAMESPACE); \
	template="deploy/argocd/application-prod.yaml.tmpl"; \
	if [[ ! -f "$$template" ]]; then echo "missing template: $$template" >&2; exit 1; fi; \
	TEMPLATE_PATH="$$template" REPO_URL="$(REPO_URL)" REVISION="$(REVISION)" \
	python3 -c 'from pathlib import Path; import os; text=Path(os.environ["TEMPLATE_PATH"]).read_text(); print(text.replace("{{REPO_URL}}", os.environ["REPO_URL"]).replace("{{REVISION}}", os.environ.get("REVISION","main")))' \
	| kubectl apply -n "$$ns" -f -

helm-update-image-tag:
	@if [[ -z "$(ENV)" || -z "$(IMAGE_TAG)" ]]; then echo "usage: make helm-update-image-tag ENV=dev IMAGE_TAG=main"; exit 1; fi
	@ENVIRONMENT="$(ENV)" IMAGE_TAG="$(IMAGE_TAG)" \
	python3 -c 'from pathlib import Path; import os,re; env=os.environ["ENVIRONMENT"]; tag=os.environ["IMAGE_TAG"]; path=Path(f"charts/values-{env}.yaml"); \
		( path.exists() or (_ for _ in ()).throw(SystemExit(f"unknown environment: {env}")) ); \
		text=path.read_text(); pattern=r"(tag:\\s*)\"?[^\\n\\\"]+\"?"; new_text,count=re.subn(pattern, rf"\\1\"{tag}\"", text, flags=re.MULTILINE); \
		( count or (_ for _ in ()).throw(SystemExit("failed to update image tag")) ); path.write_text(new_text); print(f"updated {path} to tag {tag}")'

argocd-cleanup-port-forward:
	@pids="/tmp/argocd-port-forward.pid /tmp/$(APP_DEV_NAMESPACE)-port-forward.pid /tmp/$(APP_PROD_NAMESPACE)-port-forward.pid"; \
	for pidfile in $$pids; do \
	  if [[ -f "$$pidfile" ]]; then \
	    pid=$$(cat "$$pidfile" 2>/dev/null || true); \
	    if [[ -n "$$pid" ]]; then kill "$$pid" >/dev/null 2>&1 || true; fi; \
	    rm -f "$$pidfile"; \
	  fi; \
	done; \
	rm -f /tmp/argocd-port-forward.log \
	      /tmp/$(APP_DEV_NAMESPACE)-port-forward.log \
	      /tmp/$(APP_PROD_NAMESPACE)-port-forward.log; \
	echo "port-forward cleanup complete"

argocd-cleanup-apps:
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-dev --ignore-not-found || true
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-prod --ignore-not-found || true

argocd-cleanup-app: argocd-cleanup-port-forward argocd-cleanup-apps
	@kubectl delete namespace "$(APP_DEV_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace "$(APP_PROD_NAMESPACE)" --ignore-not-found
	@kubectl delete crd applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io --ignore-not-found
	@kubectl delete clusterrole argocd-application-controller --ignore-not-found
	@kubectl delete clusterrolebinding argocd-application-controller --ignore-not-found
	@kubectl delete clusterrole argocd-server --ignore-not-found
	@kubectl delete clusterrolebinding argocd-server --ignore-not-found

cleanup: argocd-cleanup-app
	@kubectl delete namespace "$(ARGOCD_NAMESPACE)" --ignore-not-found
