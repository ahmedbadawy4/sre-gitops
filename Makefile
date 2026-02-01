SHELL := /bin/bash

ARGOCD_VERSION ?= v2.10.9
ARGOCD_NAMESPACE ?= argocd
APP_SERVICE ?= web-app
APP_DEV_NAMESPACE ?= web-app-dev
APP_PROD_NAMESPACE ?= web-app-prod
APP_DEV_LOCAL_PORT ?= 8080
APP_PROD_LOCAL_PORT ?= 8082
REPO_URL ?=
REVISION ?= main
IMAGE_NAME ?= sre-gitops/app
IMAGE_TAG ?= main
KIND_CLUSTER ?= sre-gitops
MINIKUBE_PROFILE ?= sre-gitops
K8S_CONTEXT ?=

.PHONY: help check-docker check-k8s build-image install-argocd argocd-password helm-urls deploy-dev deploy-prod update-image-tag cleanup-port-forward cleanup-argocd-apps cleanup-app cleanup-argocd kind-up minikube-up use-context

help:
	@echo "Targets:"
	@echo "  check-docker          Verify Docker Desktop is installed and running"
	@echo "  check-k8s             Verify kubectl context is docker-desktop"
	@echo "  kind-up               Create a kind cluster (KIND_CLUSTER)"
	@echo "  minikube-up           Start a minikube profile (MINIKUBE_PROFILE)"
	@echo "  use-context           Switch kubectl context (K8S_CONTEXT)"
	@echo "  build-image IMAGE_TAG=...   Build the app image locally (default: main)"
	@echo "  install-argocd         Install Argo CD (pinned version)"
	@echo "  argocd-password        Show Argo CD admin password"
	@echo "  helm-urls              Port-forward and list Argo CD + app URLs"
	@echo "  deploy-dev             Apply Argo CD Application for dev"
	@echo "  deploy-prod            Apply Argo CD Application for prod"
	@echo "  update-image-tag ENV=dev IMAGE_TAG=main  Update image tag in values"
	@echo "  cleanup-port-forward   Stop port-forwards and remove local pid/log files"
	@echo "  cleanup-argocd-apps    Delete Argo CD Applications (dev/prod)"
	@echo "  cleanup-app            Delete app namespaces (dev/prod)"
	@echo "  cleanup-argocd         Delete Argo CD namespace"

check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found. Install Docker Desktop."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "docker daemon not running. Start Docker Desktop."; exit 1; }
	@echo "docker ok"

check-k8s:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
	@ctx=$$(kubectl config current-context); \
	if [[ "$$ctx" != "docker-desktop" ]]; then \
	  echo "warning: context is '$$ctx' (expected docker-desktop)"; \
	else \
	  echo "kubectl context ok ($$ctx)"; \
	fi

kind-up:
	@command -v kind >/dev/null 2>&1 || { echo "kind not found"; exit 1; }
	@kind get clusters | grep -qx "$(KIND_CLUSTER)" || kind create cluster --name "$(KIND_CLUSTER)"
	@kubectl config use-context "kind-$(KIND_CLUSTER)"

minikube-up:
	@command -v minikube >/dev/null 2>&1 || { echo "minikube not found"; exit 1; }
	@minikube start -p "$(MINIKUBE_PROFILE)"
	@kubectl config use-context "minikube"

use-context:
	@if [[ -z "$(K8S_CONTEXT)" ]]; then echo "K8S_CONTEXT is required"; exit 1; fi
	@kubectl config use-context "$(K8S_CONTEXT)"

build-image:
	@docker build -t "$(IMAGE_NAME):$(IMAGE_TAG)" app
	@echo "built $(IMAGE_NAME):$(IMAGE_TAG)"

install-argocd:
	@command -v helm >/dev/null 2>&1 || { echo "helm not found"; exit 1; }
	@ns=$(ARGOCD_NAMESPACE); \
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null; \
	helm repo update >/dev/null; \
	helm upgrade --install argocd argo/argo-cd -n "$$ns" --create-namespace -f tools/argocd-values.yaml

argocd-password:
	@ns=$(ARGOCD_NAMESPACE); \
	if kubectl -n "$$ns" get secret argocd-initial-admin-secret >/dev/null 2>&1; then \
	  kubectl -n "$$ns" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; \
	  echo; \
	else \
	  echo "argocd initial admin secret not found (admin may be disabled or already rotated)."; \
	fi

helm-urls:
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

deploy-dev:
	@if [[ -z "$(REPO_URL)" ]]; then echo "REPO_URL is required"; exit 1; fi
	@ns=$(ARGOCD_NAMESPACE); \
	template="deploy/argocd/application-dev.yaml.tmpl"; \
	if [[ ! -f "$$template" ]]; then echo "missing template: $$template" >&2; exit 1; fi; \
	TEMPLATE_PATH="$$template" REPO_URL="$(REPO_URL)" REVISION="$(REVISION)" \
	python3 -c 'from pathlib import Path; import os; text=Path(os.environ["TEMPLATE_PATH"]).read_text(); print(text.replace("{{REPO_URL}}", os.environ["REPO_URL"]).replace("{{REVISION}}", os.environ.get("REVISION","main")))' \
	| kubectl apply -n "$$ns" -f -

deploy-prod:
	@if [[ -z "$(REPO_URL)" ]]; then echo "REPO_URL is required"; exit 1; fi
	@ns=$(ARGOCD_NAMESPACE); \
	template="deploy/argocd/application-prod.yaml.tmpl"; \
	if [[ ! -f "$$template" ]]; then echo "missing template: $$template" >&2; exit 1; fi; \
	TEMPLATE_PATH="$$template" REPO_URL="$(REPO_URL)" REVISION="$(REVISION)" \
	python3 -c 'from pathlib import Path; import os; text=Path(os.environ["TEMPLATE_PATH"]).read_text(); print(text.replace("{{REPO_URL}}", os.environ["REPO_URL"]).replace("{{REVISION}}", os.environ.get("REVISION","main")))' \
	| kubectl apply -n "$$ns" -f -

update-image-tag:
	@if [[ -z "$(ENV)" || -z "$(IMAGE_TAG)" ]]; then echo "usage: make update-image-tag ENV=dev IMAGE_TAG=main"; exit 1; fi
	@ENVIRONMENT="$(ENV)" IMAGE_TAG="$(IMAGE_TAG)" \
	python3 -c 'from pathlib import Path; import os,re; env=os.environ["ENVIRONMENT"]; tag=os.environ["IMAGE_TAG"]; path=Path(f"charts/values-{env}.yaml"); \
		( path.exists() or (_ for _ in ()).throw(SystemExit(f"unknown environment: {env}")) ); \
		text=path.read_text(); pattern=r"(tag:\\s*)\"?[^\\n\\\"]+\"?"; new_text,count=re.subn(pattern, rf"\\1\"{tag}\"", text, flags=re.MULTILINE); \
		( count or (_ for _ in ()).throw(SystemExit("failed to update image tag")) ); path.write_text(new_text); print(f"updated {path} to tag {tag}")'

cleanup-port-forward:
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

cleanup-argocd-apps:
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-dev --ignore-not-found || true
	@kubectl get crd applications.argoproj.io >/dev/null 2>&1 && \
	  kubectl -n "$(ARGOCD_NAMESPACE)" delete application web-app-prod --ignore-not-found || true

cleanup-app: cleanup-port-forward cleanup-argocd-apps
	@kubectl delete namespace "$(APP_DEV_NAMESPACE)" --ignore-not-found
	@kubectl delete namespace "$(APP_PROD_NAMESPACE)" --ignore-not-found
	@kubectl delete crd applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io --ignore-not-found
	@kubectl delete clusterrole argocd-application-controller --ignore-not-found
	@kubectl delete clusterrolebinding argocd-application-controller --ignore-not-found
	@kubectl delete clusterrole argocd-server --ignore-not-found
	@kubectl delete clusterrolebinding argocd-server --ignore-not-found

cleanup-argocd: cleanup-port-forward
	@kubectl delete namespace "$(ARGOCD_NAMESPACE)" --ignore-not-found
