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
#
# SKIP_DOTENV=1 ignores `.env` — at the MAKE level here, and inside every script
# (scripts/lib/os.sh `load_env`). The KinD e2e passes it (E2E_SKIP_DOTENV below) so a
# local run reproduces a FRESH operator's box, where the you-choose secrets do not exist
# and must be GENERATED. It is deliberately env-only: it does NOT touch the image cache,
# so a re-run still cache-skips the mirror (no re-download).
ifneq ($(SKIP_DOTENV),1)
-include .env
endif
# The STAMPED state overlay (was `.env.kind` — a KinD-named file that carried REAL-LAB state, which is
# how `make kind-down` came to destroy a lab's kubeconfig). VKS_STATE_FILE overrides the path.
-include $(if $(VKS_STATE_FILE),$(VKS_STATE_FILE),.env.state)
-include .env.kind

# The KinD e2e is a stand-in for a brand-new operator / a CI runner — neither has a `.env`.
# Ignoring it by default keeps "make e2e-kind needs zero .env" an ENFORCED property instead
# of a claim that happens to hold on the author's box. Opt back in with E2E_SKIP_DOTENV=0.
E2E_SKIP_DOTENV ?= 1

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ---- Defaults (mirror .env.example; env/.env override) ----
HARBOR_URL          ?= harbor.vks.local
HARBOR_INFRA_PROJECT?= cicd
HARBOR_APP_PROJECT  ?= apps
HARBOR_CA_FILE      ?= ./secrets/harbor-ca.crt
GITEA_NAMESPACE     ?= gitea
CI_NAMESPACE        ?= ci
TEKTON_NAMESPACE    ?= tekton-pipelines
ARGOCD_NAMESPACE    ?= argocd
# NO APP_NAME / ARGOCD_DEST_NAMESPACE: with more than one app these are PER-APP, and live in
# apps/registry.tsv (scripts/lib/apps.sh). A global here would be exported into the scripts and
# clobber the per-app value — every app would deploy as javawebapp.
APP_DEV_PORT        ?= 8080
BUNDLE_DIR          ?= ./bundle
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION    ?= 1.2026.6
# renovate: datasource=npm depName=renovate
RENOVATE_VERSION    ?= 43.257.6
# renovate: datasource=npm depName=markdownlint-cli
MARKDOWNLINT_VERSION ?= 0.49.0
# Container engine — podman is the DEFAULT, docker only a fallback. Override: CONTAINER_ENGINE=docker
# This duplicates container_engine() (scripts/lib/os.sh) because make needs it at parse time; the two
# MUST agree, and `make test-container-engine` asserts both put podman first.
CONTAINER_ENGINE    ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

SCRIPTS := ./scripts

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

deps-mise: ## Install mise itself (if absent) + the mise-managed tools from .mise.toml (java, maven, kubectl, helm, trivy, ...)
# This used to `exit 1` with "mise not found — install it first (see README → Prerequisites)" — while
# the README's Prerequisites said mise is "installed by `make deps`". A new user following the KinD
# row (Have: Docker · Run: make deps) hit a documentation LOOP and could not get past step one.
# bootstrap-jumpbox.sh already installs mise the same way; `make deps` now does too, so the README
# claim is true. mise lands in ~/.local/bin, which may not be on PATH yet in THIS shell — so resolve
# the binary explicitly rather than trusting `command -v` right after installing it.
	@if ! command -v mise >/dev/null 2>&1 && [ ! -x "$$HOME/.local/bin/mise" ]; then \
	   echo "mise not found — installing it (https://mise.run)"; \
	   curl -fsSL https://mise.run | sh || { echo "mise install failed — install it manually: https://mise.jdx.dev/getting-started.html"; exit 1; }; \
	 fi; \
	 MISE="$$(command -v mise 2>/dev/null || echo "$$HOME/.local/bin/mise")"; \
	 [ -x "$$MISE" ] || { echo "mise still not found after install — install it manually: https://mise.jdx.dev/getting-started.html"; exit 1; }; \
	 "$$MISE" trust "$(CURDIR)/.mise.toml"; "$$MISE" install; \
	 command -v mise >/dev/null 2>&1 || { \
	   echo ""; \
	   echo "NOTE: mise is installed at $$HOME/.local/bin/mise but is NOT on your PATH."; \
	   echo "      For this shell:  export PATH=\"$$HOME/.local/bin:$$PATH\""; \
	   echo "      Permanently:     echo 'eval \"\$$(mise activate bash)\"' >> ~/.bashrc   # or ~/.zshrc"; \
	 }

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

##@ Environment (.env lifecycle) — GENERATE / DISCOVER / user-PROVIDE
.PHONY: env-init env-populate env-check env-validate
env-init: ## Create a fresh .env from .env.example (backs up an existing .env → .env.bak)
	@$(SCRIPTS)/02-env.sh init
env-populate: ## Mint the secrets we can + discover cluster values (best-effort) into .env; print what only you can provide
	@$(SCRIPTS)/02-env.sh populate
env-check: ## Presence gate — fail if a required .env value is missing/placeholder (fast, no network)
	@$(SCRIPTS)/02-env.sh check
env-validate: ## Validity gate — format + KUBECONFIG/Harbor connectivity+auth (fail fast; secrets never on argv)
	@$(SCRIPTS)/02-env.sh validate

.PHONY: check-readme-scenarios
check-readme-scenarios: ## Gate: the README is SCENARIO-BASED — each scenario must answer every decision itself
	@$(SCRIPTS)/check-readme-scenarios.sh

.PHONY: check-env-coverage
check-env-coverage: ## Gate: every operator-settable var the scripts read must be documented in .env.example
	@$(SCRIPTS)/check-env-coverage.sh

.PHONY: state-show state-stamp state-migrate
state-show: ## Show the state overlay: WHICH CLUSTER wrote it, when, and what is in it (secrets redacted)
	@bash -c '. scripts/lib/os.sh; state_show'

state-stamp: ## Stamp the state overlay with the cluster it belongs to (run once against a live cluster)
	@bash -c '. scripts/lib/os.sh; load_env; state_stamp; state_show'

state-migrate: ## Move a legacy .env.kind to the stamped overlay
	@bash -c 'set -e; . scripts/lib/os.sh; \
	  [ -f .env.kind ] || { echo "no .env.kind — nothing to migrate"; exit 0; }; \
	  f="$$(state_file)"; cat .env.kind >> "$$f"; chmod 0600 "$$f"; rm -f .env.kind; \
	  echo "migrated .env.kind -> $$(basename "$$f") (stamp it: make state-stamp)"'

.PHONY: check-vks-terminology
check-vks-terminology: ## Gate: Broadcom's product nouns (the vendor says "Supervisor Service"; phantom hybrids are banned)
	@./scripts/check-vks-terminology.sh

.PHONY: check-how-provenance
check-how-provenance: ## Gate: every `# how:` acquisition command must be runnable-by-us, a real make target, or provenance-tagged
	@$(SCRIPTS)/check-how-provenance.sh

.PHONY: check-env-clobber
check-env-clobber: ## Gate: an UNCOMMENTED .env.example value must not shadow a dynamic fallback or a per-run override
	@$(SCRIPTS)/check-env-clobber.sh

.PHONY: check-app-hardcodes
check-app-hardcodes: ## Gate: no shared script/manifest/Makefile/.env.example may NAME an app — everything derives from apps/registry.tsv
	@$(SCRIPTS)/check-app-hardcodes.sh

.PHONY: check-app-toolchains
check-app-toolchains: ## Gate: every app's language toolchain must be pinned in .mise.toml, or CI cannot test/scan that app
	@$(SCRIPTS)/check-app-toolchains.sh

.PHONY: check-tools
check-tools: ## Read-only: is this jump box able to run the flow? (required vs optional CLIs + versions)
	@$(SCRIPTS)/03-check-tools.sh

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

.PHONY: mirror-verify
mirror-verify: check-env ## Verify every mirrored image is INTACT in Harbor (crane validate blobs + images.lock digest match) — run after 'make mirror'
	@$(SCRIPTS)/23-mirror-verify.sh

.PHONY: mirror-verify-red-test
mirror-verify-red-test: check-env ## NEGATIVE test (LIVE Harbor): delete one mirrored image, assert mirror-verify FAILS, then restore — proves the integrity gate catches corruption
	@$(SCRIPTS)/24-mirror-verify-red-test.sh

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

.PHONY: preflight argocd-preflight
preflight: check-tools argocd-preflight psa-check ## Read-only: can this lab actually run the flow? Run it BEFORE the 20-minute mirror (first prereq of install-all)

.PHONY: argocd-preflight
argocd-preflight: ## ArgoCD version + TOPOLOGY + write-mechanism + AppProject + Gitea reachability (two-cluster aware; non-zero on a blocking finding)
	@$(SCRIPTS)/23-argocd-preflight.sh

##@ Platform install (Gitea + Tekton)
.PHONY: install-gitea
install-gitea: check-env ## Install Gitea on VKS (images from Harbor)
	@$(SCRIPTS)/40-install-gitea.sh

.PHONY: seed-gitea
seed-gitea: check-env ## Create + seed javawebapp-app and javawebapp-deploy repos in Gitea
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

.PHONY: fetch-argocd-kubeconfig
fetch-argocd-kubeconfig: check-env ## Real lab: obtain the SUPERVISOR kubeconfig (where ArgoCD runs) -> $ARGOCD_KUBECONFIG, so `make gitops` can register the guest
	@$(SCRIPTS)/31-fetch-argocd-kubeconfig.sh

.PHONY: argocd-register-guest
argocd-register-guest: ## Register the guest cluster as an ArgoCD destination (real-lab cross-cluster: ArgoCD on the Supervisor; ADMIN-only; needs ARGOCD_KUBECONFIG + KUBECONFIG)
	@$(SCRIPTS)/71-argocd-register-guest.sh

.PHONY: gitops
gitops: ## Wire ArgoCD to each <app>-deploy repo (registers the guest cluster first, but only if that is actually needed AND permitted)
	@# 71 DERIVES whether registration is needed (ArgoCD off-cluster? guest not registered yet?) and
	@# whether we may do it. It used to be gated on `[ -n "$$ARGOCD_KUBECONFIG" ]` — i.e. REMEMBERING,
	@# which also force-ran the ADMIN-only register (it mints a cluster-admin ClusterRoleBinding) even
	@# when both kubeconfigs pointed at the SAME cluster.
	@$(SCRIPTS)/71-argocd-register-guest.sh
	@$(MAKE) configure-argocd

##@ Access (URLs + logins)
.PHONY: creds-show creds
creds-show: ## Print the access summary (URLs + logins) for the current context
	@$(SCRIPTS)/creds.sh
creds: creds-show  ## Alias for creds-show (back-compat)

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
install-ingress: check-env ## Install/attach the ingress (INGRESS_CONTROLLER=istio|istio-existing|traefik) fronting the UIs at *.vks.local
	@$(SCRIPTS)/44-install-ingress.sh

.PHONY: install-istio
install-istio: check-env ## Install Istio ingress (control plane + gateway LB) — the default; we OWN the mesh
	@$(SCRIPTS)/46-install-istio.sh

.PHONY: attach-istio
attach-istio: check-env ## Attach to an Istio the platform team ALREADY installed (installs nothing; routes only)
	@$(SCRIPTS)/47-attach-istio.sh

.PHONY: istio-preflight
istio-preflight: check-env ## Read-only: is Istio here, what selector does it need, what must the mesh admin grant?
	@$(SCRIPTS)/48-istio-preflight.sh

.PHONY: psa-check
psa-check: check-env ## Read-only: would our pods survive a VKS guest cluster (PSA enforce=restricted by default)?
	@$(SCRIPTS)/49-psa-check.sh

.PHONY: install-traefik
install-traefik: check-env ## Install Traefik ingress (one LB) — the lighter option
	@$(SCRIPTS)/45-install-traefik.sh

.PHONY: kind-down
kind-down: ## Tear down the KinD cluster (prunes cloud-provider-kind + kindccm-* orphans)
	@$(SCRIPTS)/kind-down.sh

# Target-specific export: every recipe line below (sub-makes AND direct script calls) runs
# with SKIP_DOTENV in its environment, so `.env` is ignored end-to-end. Make also treats an
# environment variable as a make variable, so the sub-make's `ifneq ($(SKIP_DOTENV),1)` sees it.
.PHONY: e2e-kind
e2e-kind: export SKIP_DOTENV = $(E2E_SKIP_DOTENV)
e2e-kind: ## Full local end-to-end in KinD (+ ingress route check + PSA/VKS admission check). Runs with .env IGNORED (fresh-box fidelity); E2E_SKIP_DOTENV=0 to use yours
	@$(MAKE) kind-up install-harbor install-argocd install-all install-ingress verify verify-ingress psa-check

.PHONY: e2e-kind-both
e2e-kind-both: ## Matrix: run the full KinD e2e in BOTH SSL modes (secure self-signed TLS, then insecure plain-HTTP)
	@echo "==> e2e-kind matrix [1/2]: SECURE mode (self-signed TLS — the default)"
	@$(MAKE) kind-down          # clear any stale .env.kind so the mode is deterministic
	@$(MAKE) e2e-kind
	@echo "==> e2e-kind matrix [2/2]: INSECURE mode (HARBOR_INSECURE=1 ARGOCD_INSECURE=1 — plain HTTP)"
	@$(MAKE) kind-down          # kind-down clears .env.kind → the insecure toggle is not clobbered by a persisted HARBOR_INSECURE=0
	@$(MAKE) e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1
	@$(MAKE) kind-down
	@echo "e2e-kind-both: both SSL modes verified end-to-end"

##@ Air-gap sneakernet end-to-end (KinD)
# The fresh staging dir the "carried" bundle tarball lands in — simulates the transfer
# medium (USB/optical) between the internet host and the air-gapped host. Overridable;
# when empty a fresh `mktemp -d` is used per run (and removed on exit), so nothing
# pre-exists. Kept out of BUNDLE_DIR/IMAGE_CACHE_DIR so it survives load_env re-sourcing.
SNEAKERNET_TRANSFER ?=

.PHONY: e2e-kind-cross-cluster
e2e-kind-cross-cluster: ## Faithful 2-KinD-cluster validation of the cross-cluster ArgoCD registration (HUB ArgoCD registers a GUEST cluster + syncs an app INTO it — the real-lab Supervisor→guest topology)
	@$(SCRIPTS)/e2e-cross-cluster.sh

.PHONY: e2e-sneakernet
e2e-sneakernet: ## Faithful TWO-BOX sneakernet on KinD: [host=internet box] mirror-pull → bundle → carry ONLY the tarball → [FRESH jumpbox container=air-gap box] bundle-load → mirror-push → mirror-verify
	@transfer="$(SNEAKERNET_TRANSFER)"; [ -n "$$transfer" ] || transfer="$$(mktemp -d)"; \
	 cleanup() { \
	   if [ -z "$(SNEAKERNET_TRANSFER)" ]; then rm -rf "$$transfer"; fi; \
	   $(MAKE) kind-down || true; \
	 }; \
	 trap cleanup EXIT; \
	 echo "==> sneakernet e2e: staging transfer dir = $$transfer"; \
	 $(MAKE) kind-up install-harbor; \
	 echo "==> [internet box / host] pull images into $(BUNDLE_DIR)"; \
	 $(MAKE) mirror-pull; \
	 echo "==> [internet box / host] bundle into the transfer dir"; \
	 $(MAKE) bundle BUNDLE_OUT_DIR="$$transfer"; \
	 tarball=""; \
	 for f in "$$transfer"/vks-airgap-cicd-bundle-*.tar.zst "$$transfer"/vks-airgap-cicd-bundle-*.tar.gz; do \
	   [ -f "$$f" ] && { tarball="$$f"; break; }; \
	 done; \
	 [ -n "$$tarball" ] || { echo "ERROR: bundle produced no tarball in $$transfer"; exit 1; }; \
	 echo "==> carry ONLY $$(basename "$$tarball") across the air gap into a FRESH jump box"; \
	 echo "==> [air-gap box] a fresh jumpbox container (only the tarball; host cache excluded) reconstructs the cache, pushes to Harbor, and integrity-verifies"; \
	 $(MAKE) jumpbox JUMPBOX_TARBALL="$$tarball"; \
	 echo "e2e-sneakernet: OK — a FRESH air-gap jump box reconstructed the cache from ONLY the carried tarball, pushed it into Harbor, and integrity-verified it (true two-box round-trip, no host-state leakage)"

##@ Full pipeline
.PHONY: install-all
# mirror-verify runs RIGHT AFTER mirror (images pushed) and BEFORE builder-image /
# platform / gitops consume them — so a corrupt/incomplete Harbor copy fails HERE (the
# integrity gate) instead of surfacing later as a mid-pipeline Kaniko MANIFEST_UNKNOWN.
# Read-only + non-disruptive to a healthy mirror. Prereqs update left-to-right (sequential).
install-all: preflight mirror mirror-verify builder-image vks-login platform gitops ## Run the complete air-gap install end to end (preflight FIRST, then mirror integrity-verified, then the pipeline)

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

# Same fresh-box fidelity as e2e-kind (a trailing '#' comment here would land INSIDE the
# value — make keeps the whitespace — so the note lives on its own line).
.PHONY: e2e-kind-tenant
e2e-kind-tenant: ## Prove the TENANT write path (argocd-server, zero k8s RBAC in the ArgoCD ns) — run after e2e-kind
	@$(SCRIPTS)/91-e2e-tenant-mechanism.sh

.PHONY: e2e-kind-istio-existing
e2e-kind-istio-existing: export SKIP_DOTENV = $(E2E_SKIP_DOTENV)
e2e-kind-istio-existing: ## KinD e2e for the ATTACH mode: a "platform team" installs Istio (foreign naming) -> we attach, installing nothing
	@echo "==> e2e-kind-istio-existing: fresh cluster, platform-owned Istio, attach-only"
	@$(MAKE) kind-down          # clear stale .env.kind so the ingress mode is deterministic
	@$(MAKE) kind-up install-harbor install-argocd install-all
	@$(SCRIPTS)/90-e2e-istio-existing.sh   # RED 1 + RED 2 + install Istio as the "platform team"
	@$(MAKE) istio-preflight
	@echo "==> leg 1/2: attach via the KUBERNETES GATEWAY API (the default, and what VKS uses)"
	@$(MAKE) install-ingress INGRESS_CONTROLLER=istio-existing ISTIO_ROUTE_API=gateway-api
	@$(MAKE) verify
	@$(MAKE) verify-ingress
	@echo "==> leg 2/2: attach via the CLASSIC Gateway/VirtualService API (shared platform gateway)"
	@$(MAKE) install-ingress INGRESS_CONTROLLER=istio-existing ISTIO_ROUTE_API=classic
	@$(MAKE) verify-ingress
	@$(MAKE) psa-check INGRESS_CONTROLLER=istio-existing
	@echo "==> e2e-kind-istio-existing PASSED — the UIs route through an Istio we did not install (BOTH route APIs)"

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
	@kind_name="$$(grep -h '^KIND_CLUSTER_NAME=' .env .env.example 2>/dev/null | head -1 | cut -d= -f2 || true)"; \
	 kind get kubeconfig --name "$$kind_name" --internal > .jumpbox/kubeconfig
	@harbor_url="$$(grep '^HARBOR_URL=' .env.kind 2>/dev/null | cut -d= -f2 || true)"; \
	 [ -n "$$harbor_url" ] || { echo "ERROR: HARBOR_URL not in .env.kind — run 'make install-harbor' first"; exit 1; }; \
	 harbor_insecure="$$(grep '^HARBOR_INSECURE=' .env.kind 2>/dev/null | cut -d= -f2 || true)"; harbor_insecure="$${harbor_insecure:-0}"; \
	 harbor_ca="$$(grep '^HARBOR_CA_FILE=' .env.kind 2>/dev/null | cut -d= -f2 || true)"; \
	 extra=""; \
	 if [ "$$harbor_insecure" != "1" ] && [ -n "$$harbor_ca" ] && [ -f "$$harbor_ca" ]; then \
	   cp "$$harbor_ca" .jumpbox/harbor-ca.crt; chmod 0644 .jumpbox/harbor-ca.crt; \
	   extra="$$extra -v $(PWD)/.jumpbox/harbor-ca.crt:/run/jumpbox/harbor-ca.crt:ro"; \
	 fi; \
	 if [ -n "$(JUMPBOX_VCF_SRC)" ] && [ -d "$(JUMPBOX_VCF_SRC)" ]; then \
	   extra="$$extra -v $(abspath $(JUMPBOX_VCF_SRC)):/run/vcf-artifacts:ro -e VCF_CLI_SRC_DIR=/run/vcf-artifacts"; \
	 fi; \
	 tb_flags=""; hpw=""; \
	 if [ -n "$(JUMPBOX_TARBALL)" ]; then \
	   tbabs="$(abspath $(JUMPBOX_TARBALL))"; tbbase="$$(basename "$$tbabs")"; \
	   [ -f "$$tbabs" ] || { echo "ERROR: JUMPBOX_TARBALL not found: $$tbabs"; exit 1; }; \
	   : "harbor-robot writes these single-quoted (the name is robot$$<x>, the secret can hold metachars)."; \
	   : "cut keeps the quotes, so an unstripped value logs in as \047robot$$...\047 and 401s."; \
	   huser="$$(grep -h '^HARBOR_USERNAME=' .env.kind .env .env.example 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$$//")"; \
	   hpw="$$(grep -h '^HARBOR_PASSWORD=' .env.kind .env 2>/dev/null | head -1 | cut -d= -f2- | sed -e "s/^['\"]//" -e "s/['\"]$$//")"; \
	   [ -n "$$hpw" ] || { echo "ERROR: HARBOR_PASSWORD not in .env.kind/.env — the air-gap half needs push creds"; exit 1; }; \
	   tb_flags="-v $$tbabs:/run/bundle/$$tbbase:ro -e JUMPBOX_MODE=airgap-half -e JUMPBOX_TARBALL=/run/bundle/$$tbbase -e HARBOR_USERNAME=$$huser -e HARBOR_PASSWORD"; \
	   echo "running $(JUMPBOX_OS) AIR-GAP jump box (sneakernet half) on the kind network (Harbor=$$harbor_url, tarball=$$tbbase)"; \
	 else \
	   echo "running $(JUMPBOX_OS) jump box on the kind network (Harbor=$$harbor_url, insecure=$$harbor_insecure)"; \
	 fi; \
	 HARBOR_PASSWORD="$$hpw" docker run --rm --privileged --network kind \
	   -e HARBOR_URL="$$harbor_url" -e HARBOR_INSECURE="$$harbor_insecure" \
	   -v "$(PWD):/src:ro" \
	   -v "$(PWD)/.jumpbox/kubeconfig:/run/jumpbox/kubeconfig:ro" \
	   $$extra $$tb_flags \
	   $(JUMPBOX_IMAGE) bash /src/scripts/jumpbox-run.sh

.PHONY: jumpbox-both
jumpbox-both: ## Validate the jump-box flow on BOTH Photon and Ubuntu (matrix)
	@$(MAKE) jumpbox JUMPBOX_OS=photon
	@$(MAKE) jumpbox JUMPBOX_OS=ubuntu

.PHONY: bootstrap-test
bootstrap-test: ## Validate bootstrap-jumpbox.sh from-nothing on BARE OS images (BOOTSTRAP_TEST_OSES matrix) + unsupported-OS reject
	@$(SCRIPTS)/bootstrap-test.sh

##@ Demo applications (local dev) — every app in apps/registry.tsv, dispatched by language
.PHONY: app-test
app-test: ## Test EVERY app (mvn test / go test). One app: APP=gowebapp
	@$(SCRIPTS)/app-test.sh test $(APP)

.PHONY: app-build
app-build: ## Build EVERY app (mvn package / go build). One app: APP=gowebapp
	@$(SCRIPTS)/app-test.sh build $(APP)

.PHONY: app-run
app-run: check-ports ## Run ONE app locally (APP=javawebapp|gowebapp; default javawebapp) on http://localhost:$(APP_DEV_PORT)
	@$(SCRIPTS)/app-run.sh $(APP)

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

.PHONY: check-pull-secret-alignment
check-pull-secret-alignment: ## Every app's deploy manifest must reference the image-pull Secret the flow actually creates
	@$(SCRIPTS)/check-pull-secret-alignment.sh

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
	echo "check-toolchain-alignment: kubectl aligned ($$mise_v)"; \
	go_mise=$$(grep -E '^go ' .mise.toml | sed -E 's/.*"([^"]+)".*/\1/'); \
	go_img=$$(grep -oE '^golang:[0-9.]+' images/images.txt | head -1 | sed 's|golang:||'); \
	if [ -n "$$go_mise" ] && [ -n "$$go_img" ] && [ "$$go_mise" != "$$go_img" ]; then \
	  echo "ERROR: Go version drift (BLOCKING) — .mise.toml=$$go_mise vs images/images.txt golang:$$go_img."; \
	  echo "       The pipeline BUILDS the Go app with the mirrored golang image; local/CI must TEST it"; \
	  echo "       with the same toolchain, or you test something the pipeline never builds."; \
	  exit 1; \
	fi; \
	echo "check-toolchain-alignment: go aligned ($$go_mise)"

##@ Offline script tests (unit tests for script logic; NOT in static-check/ci)
# Fast, fully-offline (no network/cluster/registry) unit tests for script logic that
# otherwise only breaks on a real lab box / mid-mirror. Deliberately NOT wired into
# static-check/ci so the core gate stays fast — run explicitly via `make test-scripts`.
.PHONY: test-vcf-cli-resolve
test-vcf-cli-resolve: ## Unit-test 01-install-vcf-clis.sh archive resolve + tar-vs-gz branch logic (offline, synthetic fixtures)
	@$(SCRIPTS)/test-vcf-cli-resolve.sh

.PHONY: test-mirror-cache
test-mirror-cache: ## Unit-test lib/mirror.sh cache-skip / resume / prune logic (offline, synthetic fixtures)
	@$(SCRIPTS)/test-mirror-cache.sh

.PHONY: test-classify-changes
test-classify-changes: ## Unit-test the CI gate selector (a docs-only change must NOT pay for a build)
	@$(SCRIPTS)/test-classify-changes.sh

.PHONY: test-argocd-topology
test-argocd-topology: ## Unit-test lib/argocd.sh: off-cluster derivation + the clonable-repoURL guard (the two CRITICALs)
	@$(SCRIPTS)/test-argocd-topology.sh

.PHONY: test-harbor-robot-payload
test-harbor-robot-payload: ## Unit-test the Harbor robot payloads (system vs project level) — offline, no Harbor
	@$(SCRIPTS)/test-harbor-robot-payload.sh

.PHONY: test-kind-down-safety
test-kind-down-safety: ## Unit-test that kind-down deletes ONLY what the KinD flow created (it used to eat a real lab's kubeconfig)
	@$(SCRIPTS)/test-kind-down-safety.sh

.PHONY: test-scripts
test-scripts: test-vcf-cli-resolve test-mirror-cache test-classify-changes test-argocd-topology test-harbor-robot-payload test-kind-down-safety test-state-overlay test-container-engine test-subagent-readonly-gate ## Run all offline script-logic unit tests

.PHONY: test-subagent-readonly-gate
test-subagent-readonly-gate: ## Offline: subagents are MECHANICALLY read-only (git/gh mutations blocked); the main agent is untouched
	@./scripts/test-subagent-readonly-gate.sh

.PHONY: test-container-engine
test-container-engine: ## Offline: podman is the DEFAULT engine (docker only as fallback); no operator-flow script requires docker
	@./scripts/test-container-engine.sh

.PHONY: test-state-overlay
test-state-overlay: ## Offline: the stamped state overlay (unstamped=source, mismatch=ARCHIVE not delete, kind-down's delete contract)
	@./scripts/test-state-overlay.sh

##@ Security scanning (internet/CI side; not part of the air-gap install)
.PHONY: secrets
secrets: ## gitleaks — scan git history + working tree for committed secrets
	@if command -v gitleaks >/dev/null 2>&1; then gitleaks detect --no-banner --redact; \
	else echo "gitleaks not installed — run 'make deps' (mise) — skipping"; fi

.PHONY: trivy-fs
trivy-fs: app-build ## trivy — scan EVERY app's built artifact (jar / Go binary) for fixable HIGH/CRITICAL CVEs
	@$(SCRIPTS)/trivy-fs.sh

.PHONY: trivy-config
trivy-config: ## trivy — scan k8s/Tekton manifests for HIGH/CRITICAL misconfigurations (.trivyignore documents accepted findings)
	@if command -v trivy >/dev/null 2>&1; then \
	  trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet \
	    --skip-dirs bundle --skip-dirs apps --skip-dirs docs --skip-dirs .claude \
	    --skip-files jumpbox/Dockerfile.bootstrap .; \
	else echo "trivy not installed — run 'make deps' (mise) — skipping"; fi

.PHONY: prose-secrets
prose-secrets: ## grep *.md for prose credentials gitleaks misses (natural-language secrets in runbooks)
	@bash scripts/check-prose-secrets.sh

.PHONY: sec
sec: secrets prose-secrets trivy-fs trivy-config ## Run all security scanners (gitleaks + prose-secrets + trivy fs/config)

##@ Diagrams & composite gates
# podman rootless needs --userns=keep-id so the mapped uid can write the mounted
# output dir; docker does not. Empty for docker.
PODMAN_USERNS := $(if $(filter podman,$(CONTAINER_ENGINE)),--userns=keep-id,)

# Render helper: $(1) = output subdir under docs/diagrams (created if missing).
# --network=none + -DRELATIVE_INCLUDE="." force the VENDORED c4/*.puml (offline,
# deterministic — no fetch from githubusercontent at render time).
# PLANTUML_LIMIT_SIZE raises PlantUML's 4096px default max canvas so a wide diagram
# renders COMPLETE instead of silently truncating (the javawebapp node + legend were being
# clipped off pipeline-flow at 4096px). Deterministic — it caps, it does not scale.
define _render_diagrams
	mkdir -p docs/diagrams/$(1); \
	$(CONTAINER_ENGINE) run --rm $(PODMAN_USERNS) --network=none -u "$$(id -u):$$(id -g)" \
		-e PLANTUML_SECURITY_PROFILE=UNSECURE -e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
		-e PLANTUML_LIMIT_SIZE=16384 \
		-v "$$PWD/docs/diagrams:/work" -w /work docker.io/plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o $(1) -DRELATIVE_INCLUDE="." airgap.puml context.puml container.puml deployment.puml pipeline-flow.puml vks-topology.puml istio-ingress.puml
endef

.PHONY: diagrams
diagrams: ## Render docs/diagrams/*.puml → docs/diagrams/out/*.png ($(CONTAINER_ENGINE))
	@$(call _render_diagrams,out)
	@echo "diagrams: rendered → docs/diagrams/out/  (commit the PNGs)"

.PHONY: diagrams-check
diagrams-check: ## CI drift gate: re-render every .puml and byte-compare vs the committed PNG. The pinned plantuml image + vendored c4/ render byte-deterministically (verified: same image → identical sha256), so a mismatch means the .puml changed without re-rendering. Run `make diagrams` before committing .puml edits.
	@rm -rf docs/diagrams/.check
	@$(call _render_diagrams,.check)
	@rc=0; for d in airgap context container deployment pipeline-flow vks-topology; do \
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
docs-lint: check-readme-scenarios ## Lint markdown (tracked AND new-but-unignored) + the README-scenario gate
	@# NOTE: diagrams-check is deliberately NOT a prerequisite here. It `docker run`s the pinned
	@# PlantUML image (a ~478 MB pull, cold) and re-renders every .puml — so making it unconditional
	@# meant a README-only PR paid for a full JVM render of seven diagrams it never touched. `make ci`
	@# still runs it (below), so the LOCAL gate is unchanged and still a superset of CI; CI runs it
	@# only when a diagram source / committed PNG / the renderer pin actually changed
	@# (scripts/classify-changes.sh emits `diagrams=`, unit-tested in test-classify-changes.sh).
	@# `--others --exclude-standard` adds UNTRACKED-but-not-gitignored markdown. Without it the
	@# gate lints only COMMITTED files, so a brand-new doc is invisible to `make ci` and its
	@# first lint happens in CI *after* it is pushed — a guaranteed green-local/red-CI round trip
	@# for every new document. (Exactly how an MD040 shipped: the file was written, `make ci` went
	@# green because git had never heard of it, and CI failed the moment it was committed.)
	@files=$$(git ls-files --cached --others --exclude-standard '*.md'); \
	[ -n "$$files" ] || { echo "docs-lint: no markdown"; exit 0; }; \
	if command -v markdownlint >/dev/null 2>&1; then markdownlint $$files; \
	elif command -v npx >/dev/null 2>&1; then npx --yes markdownlint-cli@$(MARKDOWNLINT_VERSION) $$files; \
	else echo "markdownlint not installed — skipping (install markdownlint-cli)"; fi

.PHONY: static-check
static-check: check-toolchain-alignment check-java-alignment check-vks-terminology check-env check-env-coverage check-env-clobber check-app-hardcodes check-app-toolchains check-how-provenance check-image-alignment check-pull-secret-alignment lint validate sec test-scripts app-test ## Composite code gate (alignment + lint + manifests + security + script unit tests + app tests)

.PHONY: ci
ci: static-check docs-lint diagrams-check ## Full local pipeline (offline-verifiable parts)

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
