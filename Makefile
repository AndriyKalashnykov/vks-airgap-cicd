# vks-airgap-cicd — orchestration for the air-gapped VKS CI/CD demo.
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
HARBOR_CA_FILE      ?= ./secrets/harbor-ca.crt
GITEA_NAMESPACE     ?= gitea
CI_NAMESPACE        ?= ci
TEKTON_NAMESPACE    ?= tekton-pipelines
ARGOCD_NAMESPACE    ?= argocd
ARGOCD_DEST_NAMESPACE ?= webui
APP_NAME            ?= webui
APP_DEV_PORT        ?= 8080
BUNDLE_DIR          ?= ./bundle
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION    ?= 1.2026.6
# renovate: datasource=npm depName=renovate
RENOVATE_VERSION    ?= 43.256.3
# renovate: datasource=npm depName=markdownlint-cli
MARKDOWNLINT_VERSION ?= 0.49.0
# Container engine — podman preferred, docker fallback. Override: CONTAINER_ENGINE=docker
CONTAINER_ENGINE    ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

SCRIPTS := ./scripts
APP_DIR := ./apps/java/webui
MVN     := ./apps/java/webui/mvnw

# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\nvks-airgap-cicd targets\n\n"} \
	  /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0,5)}' $(MAKEFILE_LIST)
	@echo ""

##@ Prerequisites
.PHONY: deps deps-mise deps-prereqs
deps: deps-mise deps-prereqs ## Install the full jump-box toolchain (mise tools + prereqs script)

deps-mise: ## Install mise-managed tools from .mise.toml (java, maven, kubectl, helm, trivy, ...)
	@if command -v mise >/dev/null 2>&1; then \
	   mise trust "$(CURDIR)/.mise.toml"; mise install; \
	 else echo "mise not found — install it first (see README → Prerequisites), then re-run 'make deps'"; exit 1; fi

deps-prereqs: ## Install non-mise CLIs + OS packages (git, tkn, argocd, podman, ...) via 00-install-prereqs.sh
	@$(SCRIPTS)/00-install-prereqs.sh

.PHONY: install-vcf-clis install-argocd-vcf install-vcf-cli install-vcf-plugins
install-vcf-clis: ## Install the Broadcom VCF/VKS lab CLIs (argocd-vcf + vcf + plugins), OS/arch-aware, sudo-free. Licensed artifacts from a folder: VCF_CLI_SRC_DIR=<dir>. Lab-only — not needed for local KinD.
	@$(SCRIPTS)/01-install-vcf-clis.sh all
install-argocd-vcf: ## Install ONLY the VCF-flavored argocd CLI (ARGOCD_VCF_VERSION) for a real lab's ArgoCD
	@$(SCRIPTS)/01-install-vcf-clis.sh argocd
install-vcf-cli: ## Install ONLY the VCF Consumption CLI `vcf` (VCF_CLI_VERSION)
	@$(SCRIPTS)/01-install-vcf-clis.sh vcf
install-vcf-plugins: ## Install ONLY the VCF Consumption CLI plugin bundle (VCF_PLUGINS_VERSION; needs `vcf` first)
	@$(SCRIPTS)/01-install-vcf-clis.sh plugins

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

.PHONY: fetch-harbor-ca
fetch-harbor-ca: ## Fetch a self-signed lab Harbor's CA cert → HARBOR_CA_FILE (for HTTPS mirror/Kaniko trust)
	@hostport="$$(printf '%s' "$(HARBOR_URL)" | sed -E 's#^https?://##; s#/.*##')"; \
	 host="$${hostport%%:*}"; port="$${hostport##*:}"; [ "$$port" = "$$host" ] && port=443; \
	 out="$(HARBOR_CA_FILE)"; mkdir -p "$$(dirname "$$out")"; \
	 echo "fetching Harbor CA from $$host:$$port -> $$out"; \
	 openssl s_client -connect "$$host:$$port" -showcerts </dev/null 2>/dev/null \
	   | openssl x509 -outform PEM > "$$out" \
	   && echo "wrote $$out (now set HARBOR_CA_FILE=$$out in .env)" \
	   || { echo "ERROR: could not fetch a CA from $$host:$$port — is the lab Harbor reachable over HTTPS?"; exit 1; }

.PHONY: fetch-argocd-ca
fetch-argocd-ca: ## Fetch a self-signed ArgoCD server CA cert → ARGOCD_CA_FILE (endpoint: ARGOCD_LB_IP or ARGOCD_SERVER)
	@ep="$(if $(ARGOCD_LB_IP),$(ARGOCD_LB_IP),$(ARGOCD_SERVER))"; \
	 [ -n "$$ep" ] || { echo "ERROR: set ARGOCD_LB_IP (kind, from .env.kind) or ARGOCD_SERVER (lab argocd-server LB IP) first"; exit 1; }; \
	 hostport="$$(printf '%s' "$$ep" | sed -E 's#^https?://##; s#/.*##')"; \
	 host="$${hostport%%:*}"; port="$${hostport##*:}"; [ "$$port" = "$$host" ] && port=443; \
	 out="$(if $(ARGOCD_CA_FILE),$(ARGOCD_CA_FILE),./secrets/argocd-ca.crt)"; mkdir -p "$$(dirname "$$out")"; \
	 echo "fetching ArgoCD CA from $$host:$$port -> $$out"; \
	 openssl s_client -connect "$$host:$$port" -showcerts </dev/null 2>/dev/null \
	   | openssl x509 -outform PEM > "$$out" \
	   && echo "wrote $$out (now set ARGOCD_CA_FILE=$$out in .env)" \
	   || { echo "ERROR: could not fetch a CA from $$host:$$port — is ArgoCD reachable over HTTPS?"; exit 1; }

.PHONY: harbor-robot
harbor-robot: ## Create a least-privilege Harbor CI robot account (push+pull) → secrets/harbor-robot.env; copy into .env
	@$(SCRIPTS)/22-harbor-robot.sh

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

##@ Access (URLs + logins)
.PHONY: creds
creds: ## Print the access summary (URLs + logins) for the current context
	@$(SCRIPTS)/creds.sh

.PHONY: argocd-password
argocd-password: ## Print the ArgoCD 'admin' password (self-resolves kubeconfig; .env value or generated)
	@$(SCRIPTS)/argocd-password.sh


##@ KinD local end-to-end (simulates VKS-provided Harbor + ArgoCD locally)
.PHONY: kind-up
kind-up: check-env ## Create the KinD cluster + cloud-provider-kind LoadBalancer
	@$(SCRIPTS)/05-kind-up.sh

.PHONY: install-harbor
install-harbor: check-env ## Install Harbor into KinD (LoadBalancer; self-signed HTTPS+CA by default, HTTP with HARBOR_INSECURE=1); wire containerd + .env.kind
	@$(SCRIPTS)/06-install-harbor.sh

.PHONY: install-argocd
install-argocd: check-env ## Install ArgoCD into KinD
	@$(SCRIPTS)/07-install-argocd.sh

.PHONY: install-ingress
install-ingress: check-env ## Install the selected ingress (INGRESS_CONTROLLER=istio|traefik) fronting the UIs at *.vks.local
	@$(SCRIPTS)/44-install-ingress.sh

.PHONY: install-istio
install-istio: check-env ## Install Istio ingress (control plane + gateway LB) — the default
	@$(SCRIPTS)/46-install-istio.sh

.PHONY: install-traefik
install-traefik: check-env ## Install Traefik ingress (one LB) — the lighter option
	@$(SCRIPTS)/45-install-traefik.sh

.PHONY: kind-down
kind-down: ## Tear down the KinD cluster (prunes cloud-provider-kind + kindccm-* orphans)
	@$(SCRIPTS)/kind-down.sh

.PHONY: e2e-kind
e2e-kind: kind-up install-harbor install-argocd install-all install-ingress verify verify-ingress ## Full local end-to-end in KinD (+ ingress route check)

##@ Full pipeline
.PHONY: install-all
install-all: mirror builder-image vks-login platform gitops ## Run the complete air-gap install end to end

.PHONY: verify
verify: check-env ## e2e: push a change → Tekton build → Harbor → ArgoCD sync → HTTP check (LIVE cluster)
	@$(SCRIPTS)/99-verify.sh

.PHONY: verify-ingress
verify-ingress: check-env ## Assert the *.vks.local UIs route through the ingress LB (reads INGRESS_LB_IP from .env.kind)
	@$(SCRIPTS)/98-verify-ingress.sh

.PHONY: verify-ingress-both
verify-ingress-both: check-env ## Matrix: install + route-verify BOTH ingress controllers against the running cluster
	@$(MAKE) install-ingress verify-ingress INGRESS_CONTROLLER=istio
	@$(MAKE) install-ingress verify-ingress INGRESS_CONTROLLER=traefik

##@ Jump-box validation (Photon / Ubuntu container, rootless podman)
JUMPBOX_OS    ?= photon
JUMPBOX_IMAGE ?= vks-jumpbox:$(JUMPBOX_OS)
.PHONY: jumpbox-image
jumpbox-image: ## Build the jump-box test image for JUMPBOX_OS (photon|ubuntu; rootless podman inside)
	@docker build -f jumpbox/Dockerfile.$(JUMPBOX_OS) -t $(JUMPBOX_IMAGE) .

.PHONY: jumpbox
jumpbox: jumpbox-image ## Validate the README jump-box flow on JUMPBOX_OS (photon|ubuntu): make deps + rootless podman + cluster reach, vs the running KinD cluster
	@command -v kind >/dev/null 2>&1 || { echo "ERROR: 'kind' not found — the KinD cluster must be up (make kind-up install-harbor ...)"; exit 1; }
	@docker network inspect kind >/dev/null 2>&1 || { echo "ERROR: kind Docker network not found — bring the cluster up first (make kind-up)"; exit 1; }
	@mkdir -p .jumpbox
	@kind_name="$$(grep -h '^KIND_CLUSTER_NAME=' .env .env.example 2>/dev/null | head -1 | cut -d= -f2)"; \
	 kind get kubeconfig --name "$$kind_name" --internal > .jumpbox/kubeconfig
	@harbor_url="$$(grep '^HARBOR_URL=' .env.kind 2>/dev/null | cut -d= -f2)"; \
	 [ -n "$$harbor_url" ] || { echo "ERROR: HARBOR_URL not in .env.kind — run 'make install-harbor' first"; exit 1; }; \
	 harbor_insecure="$$(grep '^HARBOR_INSECURE=' .env.kind 2>/dev/null | cut -d= -f2)"; harbor_insecure="$${harbor_insecure:-0}"; \
	 harbor_ca="$$(grep '^HARBOR_CA_FILE=' .env.kind 2>/dev/null | cut -d= -f2)"; \
	 extra=""; \
	 if [ "$$harbor_insecure" != "1" ] && [ -n "$$harbor_ca" ] && [ -f "$$harbor_ca" ]; then \
	   cp "$$harbor_ca" .jumpbox/harbor-ca.crt; chmod 0644 .jumpbox/harbor-ca.crt; \
	   extra="$$extra -v $(PWD)/.jumpbox/harbor-ca.crt:/run/jumpbox/harbor-ca.crt:ro"; \
	 fi; \
	 if [ -n "$(JUMPBOX_VCF_SRC)" ] && [ -d "$(JUMPBOX_VCF_SRC)" ]; then \
	   extra="$$extra -v $(abspath $(JUMPBOX_VCF_SRC)):/run/vcf-artifacts:ro -e VCF_CLI_SRC_DIR=/run/vcf-artifacts"; \
	 fi; \
	 echo "running $(JUMPBOX_OS) jump box on the kind network (Harbor=$$harbor_url, insecure=$$harbor_insecure)"; \
	 docker run --rm --privileged --network kind \
	   -e HARBOR_URL="$$harbor_url" -e HARBOR_INSECURE="$$harbor_insecure" \
	   -v "$(PWD):/src:ro" \
	   -v "$(PWD)/.jumpbox/kubeconfig:/run/jumpbox/kubeconfig:ro" \
	   $$extra \
	   $(JUMPBOX_IMAGE) bash /src/scripts/jumpbox-run.sh

.PHONY: jumpbox-both
jumpbox-both: ## Validate the jump-box flow on BOTH Photon and Ubuntu (matrix)
	@$(MAKE) jumpbox JUMPBOX_OS=photon
	@$(MAKE) jumpbox JUMPBOX_OS=ubuntu

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

.PHONY: check-image-alignment
check-image-alignment: ## Fail if any mirrored image tag drifts between k8s/tekton manifests and images/images.txt
	@$(SCRIPTS)/check-image-alignment.sh

.PHONY: check-java-alignment
check-java-alignment: ## Fail if the Java major drifts across pom/mise/ci/Dockerfile/images.txt
	@$(SCRIPTS)/check-java-alignment.sh

.PHONY: check-toolchain-alignment
check-toolchain-alignment: ## Fail if kubectl pinned in .mise.toml disagrees with .env.example KUBECTL_VERSION
	@mise_v=$$(grep -E '^kubectl' .mise.toml | sed -E 's/.*"([^"]+)".*/\1/' | tr -d 'v'); \
	env_v=$$(grep -E '^KUBECTL_VERSION=' .env.example | cut -d= -f2 | tr -d 'v'); \
	if [ "$$mise_v" != "$$env_v" ]; then \
	  echo "ERROR: kubectl version drift (BLOCKING) — .mise.toml=$$mise_v vs .env.example KUBECTL_VERSION=$$env_v."; \
	  echo "       Same tool, two pins: jump box (mise) + air-gap fallback (00-install-prereqs.sh). Align them."; \
	  exit 1; \
	fi; \
	echo "check-toolchain-alignment: kubectl aligned ($$mise_v)"

##@ Security scanning (internet/CI side; not part of the air-gap install)
.PHONY: secrets
secrets: ## gitleaks — scan git history + working tree for committed secrets
	@if command -v gitleaks >/dev/null 2>&1; then gitleaks detect --no-banner --redact; \
	else echo "gitleaks not installed — run 'make deps' (mise) — skipping"; fi

.PHONY: trivy-fs
trivy-fs: app-build ## trivy — scan the built app jar's embedded deps for fixable HIGH/CRITICAL CVEs
	@if command -v trivy >/dev/null 2>&1; then \
	  jar=$$(ls $(APP_DIR)/target/*.jar 2>/dev/null | grep -v -- '-sources\|-javadoc' | head -1); \
	  if [ -z "$$jar" ]; then echo "ERROR: no built jar under $(APP_DIR)/target — app-build failed?"; exit 1; fi; \
	  echo "trivy-fs: scanning $$jar (embedded deps, offline)"; \
	  trivy rootfs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --quiet "$$jar"; \
	else echo "trivy not installed — run 'make deps' (mise) — skipping"; fi

.PHONY: trivy-config
trivy-config: ## trivy — scan k8s/Tekton manifests for HIGH/CRITICAL misconfigurations (.trivyignore documents accepted findings)
	@if command -v trivy >/dev/null 2>&1; then \
	  trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet \
	    --skip-dirs bundle --skip-dirs apps/java/webui --skip-dirs docs .; \
	else echo "trivy not installed — run 'make deps' (mise) — skipping"; fi

.PHONY: sec
sec: secrets trivy-fs trivy-config ## Run all security scanners (gitleaks + trivy fs/config)

##@ Diagrams & composite gates
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
		-tpng -o $(1) -DRELATIVE_INCLUDE="." airgap.puml context.puml container.puml deployment.puml pipeline-flow.puml
endef

.PHONY: diagrams
diagrams: ## Render docs/diagrams/*.puml → docs/diagrams/out/*.png ($(CONTAINER_ENGINE))
	@$(call _render_diagrams,out)
	@echo "diagrams: rendered → docs/diagrams/out/  (commit the PNGs)"

.PHONY: diagrams-check
diagrams-check: ## CI drift gate: re-render every .puml and byte-compare vs the committed PNG. The pinned plantuml image + vendored c4/ render byte-deterministically (verified: same image → identical sha256), so a mismatch means the .puml changed without re-rendering. Run `make diagrams` before committing .puml edits.
	@rm -rf docs/diagrams/.check
	@$(call _render_diagrams,.check)
	@rc=0; for d in airgap context container deployment pipeline-flow; do \
		if [ ! -s docs/diagrams/.check/$$d.png ]; then echo "ERROR: $$d.puml failed to render"; rc=1; \
		elif [ ! -s docs/diagrams/out/$$d.png ]; then echo "ERROR: committed docs/diagrams/out/$$d.png missing — run 'make diagrams'"; rc=1; \
		elif ! cmp -s docs/diagrams/.check/$$d.png docs/diagrams/out/$$d.png; then \
			echo "ERROR: docs/diagrams/out/$$d.png is STALE — $$d.puml (or _style.puml) changed but the PNG was not re-rendered. Run 'make diagrams' and commit the PNGs."; rc=1; \
		fi; \
	done; rm -rf docs/diagrams/.check; \
	if [ $$rc -eq 0 ]; then echo "diagrams-check: all committed PNGs match their source (no drift)"; else exit 1; fi

# C4-PlantUML stdlib pin for the vendored docs/diagrams/c4/*.puml. NOT Renovate-tracked
# on purpose: a bump the hosted bot can't re-vendor + re-render is a standing red PR
# (the diagrams-check gate would fail it). Bump manually via `make vendor-diagrams`.
C4_PLANTUML_VERSION ?= v2.11.0

.PHONY: vendor-diagrams
vendor-diagrams: ## Re-download the pinned C4-PlantUML stdlib into docs/diagrams/c4/ (manual bump path; then `make diagrams`)
	@base="https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/$(C4_PLANTUML_VERSION)"; \
	for f in C4 C4_Context C4_Container C4_Component C4_Deployment C4_Dynamic; do \
	  echo "fetching $$f.puml @ $(C4_PLANTUML_VERSION)"; \
	  curl -sSfL "$$base/$$f.puml" -o docs/diagrams/c4/$$f.puml || { echo "ERROR: failed to fetch $$f.puml"; exit 1; }; \
	done; \
	echo "vendor-diagrams: refreshed docs/diagrams/c4/ @ $(C4_PLANTUML_VERSION) — now run 'make diagrams' and verify the offline render"

.PHONY: docs-lint
docs-lint: diagrams-check ## Lint tracked markdown + verify diagrams are current
	@files=$$(git ls-files '*.md'); \
	[ -n "$$files" ] || { echo "docs-lint: no tracked markdown"; exit 0; }; \
	if command -v markdownlint >/dev/null 2>&1; then markdownlint $$files; \
	elif command -v npx >/dev/null 2>&1; then npx --yes markdownlint-cli@$(MARKDOWNLINT_VERSION) $$files; \
	else echo "markdownlint not installed — skipping (install markdownlint-cli)"; fi

.PHONY: static-check
static-check: check-toolchain-alignment check-java-alignment check-env check-image-alignment lint validate sec app-test ## Composite code gate (alignment + lint + manifests + security + app tests)

.PHONY: ci
ci: static-check docs-lint ## Full local pipeline (offline-verifiable parts)

##@ Dependencies (Renovate)
.PHONY: renovate-validate
renovate-validate: ## Validate renovate.json (pinned renovate — needs node on PATH)
	@if [ -n "$${GH_ACCESS_TOKEN:-}" ]; then export GITHUB_COM_TOKEN="$$GH_ACCESS_TOKEN"; \
	else echo "note: GH_ACCESS_TOKEN unset — some lookups may be skipped"; fi; \
	npx --yes renovate@$(RENOVATE_VERSION) --platform=local

##@ Housekeeping
.PHONY: clean
clean: ## Remove build output and the air-gap bundle
	@rm -rf $(BUNDLE_DIR) $(APP_DIR)/target
	@echo "clean: removed $(BUNDLE_DIR) and app target/"
