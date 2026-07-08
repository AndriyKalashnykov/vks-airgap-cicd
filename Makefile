# vks-cicd — orchestration for the air-gapped VKS CI/CD demo.
#
# Layered targets: `make deps` → `make mirror` → `make vks-login` → `make platform`
# → `make gitops` → `make verify`. Or run the whole thing with `make install-all`.
#
# Every tunable comes from .env (gitignored) via `-include .env`, falling back to
# the `?=` defaults below (mirrors .env.example). `.env` wins for `make` too.

# Load operator overrides FIRST so they win over the ?= defaults. `-include`
# (leading '-') silently skips a missing file. .env.kind is written by the KinD
# flow and overrides .env for local end-to-end testing.
-include .env
-include .env.kind

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---- Defaults (mirror .env.example; env/.env override) ----
RUN_MODE            ?= dual-homed
HARBOR_URL          ?= harbor.vks.local
HARBOR_INFRA_PROJECT?= cicd
HARBOR_APP_PROJECT  ?= apps
GITEA_NAMESPACE     ?= gitea
CI_NAMESPACE        ?= ci
TEKTON_NAMESPACE    ?= tekton-pipelines
ARGOCD_NAMESPACE    ?= argocd
ARGOCD_DEST_NAMESPACE ?= webui
APP_NAME            ?= webui
APP_DEV_PORT        ?= 8080
BUNDLE_DIR          ?= ./bundle
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION    ?= 1.2025.4
# Container engine — podman preferred, docker fallback. Override: CONTAINER_ENGINE=docker
CONTAINER_ENGINE    ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

SCRIPTS := ./scripts
APP_DIR := ./app
MVN     := ./app/mvnw

# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\nvks-cicd targets\n\n"} \
	  /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0,5)}' $(MAKEFILE_LIST)
	@echo ""

##@ Prerequisites
.PHONY: deps
deps: ## Install jump-box toolchain (mise tools + skopeo/tkn/argocd via prereqs script)
	@command -v mise >/dev/null 2>&1 && mise install || echo "mise not found; skipping mise install"
	@$(SCRIPTS)/00-install-prereqs.sh

.PHONY: check-env
check-env: ## STOPPER gate — fail if the committed .env.example source of truth is missing
	@test -f .env.example || { \
	  echo "ERROR: .env.example is missing (BLOCKING). It is the committed source of truth"; \
	  echo "       for every operator-tunable value. Restore it before continuing."; \
	  exit 1; }
	@echo "check-env: .env.example present"

.PHONY: check-ports
check-ports: ## Fail early if the local app-dev port is already in use (names the holder)
	@port="$(APP_DEV_PORT)"; \
	if (exec 3<>/dev/tcp/127.0.0.1/$$port) 2>/dev/null; then \
	  exec 3>&- 3<&-; \
	  holder=$$(command -v docker >/dev/null 2>&1 && docker ps --filter "publish=$$port" --format '{{.Names}}' | head -1 || true); \
	  echo "ERROR: port $$port already in use$${holder:+ by container '$$holder'}."; \
	  echo "       Free it or override APP_DEV_PORT (e.g. make app-run APP_DEV_PORT=8081)."; \
	  exit 1; \
	else echo "check-ports: $$port free"; fi

##@ Air-gap image mirroring
.PHONY: mirror-pull
mirror-pull: check-env ## (internet) Pull every image in images/images.txt into the local cache
	@$(SCRIPTS)/10-mirror-pull.sh

.PHONY: bundle
bundle: ## (sneakernet) Package pulled images + manifests into a transferable bundle
	@$(SCRIPTS)/11-bundle.sh

.PHONY: bundle-load
bundle-load: ## (sneakernet, air-gap host) Unpack a transferred bundle
	@$(SCRIPTS)/20-bundle-load.sh

.PHONY: mirror-push
mirror-push: check-env ## Push all mirrored images into Harbor
	@$(SCRIPTS)/21-mirror-push.sh

.PHONY: mirror
mirror: mirror-pull mirror-push ## (dual-homed) Pull + push in one run

.PHONY: builder-image
builder-image: check-env ## (internet) Build + push the air-gap Maven builder image (deps pre-baked)
	@$(SCRIPTS)/15-build-push-builder.sh

##@ VKS access
.PHONY: vks-login
vks-login: check-env ## Authenticate to VKS (VCF 9 + Supervisor) → writes KUBECONFIG/context
	@$(SCRIPTS)/30-vks-login.sh

##@ Platform install (Gitea + Tekton)
.PHONY: install-gitea
install-gitea: check-env ## Install Gitea on VKS (images from Harbor)
	@$(SCRIPTS)/40-install-gitea.sh

.PHONY: seed-gitea
seed-gitea: check-env ## Create + seed webui-app and webui-deploy repos in Gitea
	@$(SCRIPTS)/50-seed-gitea-repos.sh

.PHONY: install-tekton
install-tekton: check-env ## Install Tekton Pipelines + Triggers (image refs remapped to Harbor)
	@$(SCRIPTS)/41-install-tekton.sh

.PHONY: configure-tekton
configure-tekton: check-env ## Apply pipeline/tasks/triggers + registry/git secrets
	@$(SCRIPTS)/60-configure-tekton.sh

.PHONY: platform
platform: install-gitea seed-gitea install-tekton configure-tekton ## Install + wire Gitea and Tekton

##@ GitOps CD (ArgoCD)
.PHONY: configure-argocd
configure-argocd: check-env ## Register the deploy repo + create the ArgoCD Application
	@$(SCRIPTS)/70-configure-argocd.sh

.PHONY: gitops
gitops: configure-argocd ## Wire ArgoCD to track webui-deploy

##@ KinD local end-to-end (simulates VKS-provided Harbor + ArgoCD locally)
.PHONY: kind-up
kind-up: check-env ## Create the KinD cluster + cloud-provider-kind LoadBalancer
	@$(SCRIPTS)/05-kind-up.sh

.PHONY: install-harbor
install-harbor: check-env ## Install Harbor (LoadBalancer, HTTP) into KinD; wire containerd + .env.kind
	@$(SCRIPTS)/06-install-harbor.sh

.PHONY: install-argocd
install-argocd: check-env ## Install ArgoCD into KinD
	@$(SCRIPTS)/07-install-argocd.sh

.PHONY: kind-down
kind-down: ## Tear down the KinD cluster (prunes cloud-provider-kind + kindccm-* orphans)
	@$(SCRIPTS)/kind-down.sh

.PHONY: e2e-kind
e2e-kind: kind-up install-harbor install-argocd install-all verify ## Full local end-to-end in KinD

##@ Full pipeline
.PHONY: install-all
install-all: mirror builder-image vks-login platform gitops ## Run the complete air-gap install end to end

.PHONY: verify
verify: check-env ## e2e: push a change → Tekton build → Harbor → ArgoCD sync → HTTP check (LIVE cluster)
	@$(SCRIPTS)/99-verify.sh

##@ Demo application (local dev)
.PHONY: app-test
app-test: ## Run the Spring Boot app unit/integration tests
	@cd $(APP_DIR) && ./mvnw -B test

.PHONY: app-build
app-build: ## Build the Spring Boot app jar
	@cd $(APP_DIR) && ./mvnw -B -DskipTests package

.PHONY: app-run
app-run: check-ports ## Run the app locally (http://localhost:$(APP_DEV_PORT))
	@cd $(APP_DIR) && APP_INTERNAL_PORT=$(APP_DEV_PORT) ./mvnw -B spring-boot:run

##@ Quality gates
.PHONY: lint
lint: ## shellcheck scripts, yamllint manifests, hadolint Dockerfile
	@$(SCRIPTS)/lint.sh

.PHONY: validate
validate: ## kustomize build + kubeconform manifests; kubectl dry-run Tekton YAML
	@$(SCRIPTS)/validate.sh

# podman rootless needs --userns=keep-id so the mapped uid can write the mounted
# output dir; docker does not. Empty for docker.
PODMAN_USERNS := $(if $(filter podman,$(CONTAINER_ENGINE)),--userns=keep-id,)

# Render helper: $(1) = output subdir under docs/diagrams (created if missing).
# --network=none + -DRELATIVE_INCLUDE="." force the VENDORED c4/*.puml (offline,
# deterministic — no fetch from githubusercontent at render time).
define _render_diagrams
	mkdir -p docs/diagrams/$(1); \
	$(CONTAINER_ENGINE) run --rm $(PODMAN_USERNS) --network=none -u "$$(id -u):$$(id -g)" \
		-e PLANTUML_SECURITY_PROFILE=UNSECURE -e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
		-v "$$PWD/docs/diagrams:/work" -w /work docker.io/plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o $(1) -DRELATIVE_INCLUDE="." context.puml container.puml deployment.puml pipeline-flow.puml
endef

.PHONY: diagrams
diagrams: ## Render docs/diagrams/*.puml → docs/diagrams/out/*.png ($(CONTAINER_ENGINE))
	@$(call _render_diagrams,out)
	@echo "diagrams: rendered → docs/diagrams/out/  (commit the PNGs)"

.PHONY: diagrams-check
diagrams-check: ## CI-safe: every .puml renders AND has a committed PNG (PlantUML PNGs are not byte-reproducible across machines, so no byte-diff). Run `make diagrams` before committing .puml edits.
	@rm -rf docs/diagrams/.check
	@$(call _render_diagrams,.check)
	@rc=0; for d in context container deployment pipeline-flow; do \
		test -s docs/diagrams/.check/$$d.png || { echo "ERROR: $$d.puml failed to render"; rc=1; }; \
		test -s docs/diagrams/out/$$d.png    || { echo "ERROR: committed docs/diagrams/out/$$d.png missing — run 'make diagrams'"; rc=1; }; \
	done; rm -rf docs/diagrams/.check; \
	if [ $$rc -eq 0 ]; then echo "diagrams-check: all .puml render + committed PNGs present"; else exit 1; fi

.PHONY: docs-lint
docs-lint: diagrams-check ## Lint markdown + verify diagrams are current
	@if command -v markdownlint >/dev/null 2>&1; then markdownlint '**/*.md' --ignore app --ignore bundle; \
	elif command -v npx >/dev/null 2>&1; then npx --yes markdownlint-cli '**/*.md' --ignore app --ignore bundle; \
	else echo "markdownlint not installed — skipping (install markdownlint-cli)"; fi

.PHONY: static-check
static-check: check-env lint validate app-test ## Composite code gate (lint + manifests + app tests)

.PHONY: ci
ci: static-check docs-lint ## Full local pipeline (offline-verifiable parts)

##@ Housekeeping
.PHONY: clean
clean: ## Remove build output and the air-gap bundle
	@rm -rf $(BUNDLE_DIR) $(APP_DIR)/target
	@echo "clean: removed $(BUNDLE_DIR) and app target/"
