# vks-airgap-cicd — orchestration for the air-gapped VKS CI/CD demo.
#
# Layered targets: `make deps` → `make mirror` → `make vks-login` → `make platform`
# → `make gitops` → `make verify`. Or run the whole thing with `make install-all`.
#
# Every tunable comes from .env (gitignored) via `-include .env`, falling back to
# the `?=` defaults below (mirrors .env.example). `.env` wins for `make` too.

# Load operator overrides FIRST so they win over the ?= defaults. `-include`
# (leading '-') silently skips a missing file. The KinD flow writes discovered
# state to the stamped `.env.state` overlay (below); `.env.kind` is read-only
# back-compat only — nothing writes it any more.
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

# E2E_FRESH=1 forces `make e2e-kind` to `kind-down` FIRST, so it runs on a freshly-created cluster and
# actually exercises namespace CREATE-ordering (B42). Default 0 keeps the fast dev loop (a warm reuse)
# — but a reused run now says so LOUDLY at the end (scripts/e2e-ordering-verdict.sh), it is no longer
# a silent pass. For `make e2e-kind` directly: e2e-kind-both and e2e-kind-istio-existing already
# `kind-down` first (always cold), so E2E_FRESH is moot there — and they run the sub-steps directly
# rather than `$(MAKE) e2e-kind`, so they do NOT print the ordering verdict (they are always cold, so
# there is nothing to warn about).
E2E_FRESH ?= 0

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
RENOVATE_VERSION    ?= 43.272.3
# renovate: datasource=npm depName=markdownlint-cli
MARKDOWNLINT_VERSION ?= 0.49.1
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

.PHONY: check-doc-command-count
check-doc-command-count: ## Gate: a doc that COUNTS commands ("two commands") must list exactly that many
	@$(SCRIPTS)/check-doc-command-count.sh

.PHONY: check-doc-make-targets
check-doc-make-targets: ## Gate: every `make X` a runbook tells the operator to run must EXIST in the Makefile
	@$(SCRIPTS)/check-doc-make-targets.sh

# The OTHER direction, and the one that kept failing: check-doc-make-targets proves a doc names no DEAD
# command; this proves a LIVE capability is not INVISIBLE. `make builder-build`/`builder-push`/
# `e2e-sneakernet-both` shipped and were merged while appearing in no document a user reads — the third
# time in one day that "a capability change is not done until the operator docs say so" failed as prose.
.PHONY: check-doc-target-coverage
check-doc-target-coverage: ## Gate: every operator-invocable target must be named in SOME doc (CI gates exempt themselves via `## Gate:`)
	@$(SCRIPTS)/check-doc-target-coverage.sh

.PHONY: check-gwapi-istio-alignment
check-gwapi-istio-alignment: ## Gate: GATEWAY_API_VERSION == the version the pinned ISTIO vendors (ground truth: istio's go.mod)
	@$(SCRIPTS)/check-gwapi-istio-alignment.sh

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

.PHONY: check-doc-novels
check-doc-novels: ## Gate: no multi-line re-litigation blockquotes ("this page used to say X … that was FALSE") in operator/reference docs
	@$(SCRIPTS)/check-doc-novels.sh

.PHONY: check-doc-robot-quoting
check-doc-robot-quoting: ## Gate: a Harbor robot credential (robot$<name>) in docs or .env.example must be SINGLE-QUOTED or set -a expands $<name> away -> 401 (B28)
	@$(SCRIPTS)/check-doc-robot-quoting.sh

.PHONY: check-how-provenance
check-how-provenance: ## Gate: every `# how:` acquisition command must be runnable-by-us, a real make target, or provenance-tagged
	@$(SCRIPTS)/check-how-provenance.sh

.PHONY: check-vks-provenance
check-vks-provenance: ## Gate: every fact row in a docs/vks-services Confidence table carries a resolvable [src:] citation token (code refs are opened + verified)
	@$(SCRIPTS)/check-vks-provenance.sh

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
# mirror-verify is a PREREQUISITE, not an optional follow-up. A push you have not verified is not
# a mirror: `crane push` establishes blob existence with a HEAD, so a registry that 200s a blob it
# does not actually hold makes the push a SILENT NO-OP that exits 0 (see 06-install-harbor.sh §3 —
# it happened, 36/36, and only mirror-verify caught it). The mirror's contract is "the images are
# retrievable from Harbor", and crane validate is the only thing here that asserts it.
mirror: mirror-pull mirror-push mirror-verify ## (dual-homed) Pull + push + VERIFY in one run

.PHONY: engine-trust-check
engine-trust-check: check-env ## Does THIS engine (podman|docker) actually work against the self-signed Harbor? Prints its PRECONDITION ROW (CA method + whether sudo was needed). ~60s.
	@$(SCRIPTS)/16-engine-trust-check.sh

.PHONY: engine-trust-check-rootless
engine-trust-check-rootless: check-env ## Is ROOTLESS DOCKER viable? (the ONLY docker mode that matches podman's ergonomics — rootful ALWAYS costs a sudo)
	@$(SCRIPTS)/17-engine-rootless-docker-check.sh

# The offline Maven builder needs TWO networks — Maven Central (to bake ~/.m2) and Harbor (to push).
# A DUAL-HOMED box has both, so `builder-image` does it in one shot. A SNEAKERNET split has NEITHER
# box with both, so it is split: build outside (into the bundle), push inside (with the carried crane).
.PHONY: builder-image
builder-image: check-env ## (dual-homed) Build + push the air-gap Maven builder image (deps pre-baked)
	@$(SCRIPTS)/15-build-push-builder.sh

.PHONY: builder-build
builder-build: check-env ## (sneakernet, INTERNET box) Build the Maven builder into the bundle — needs Maven Central, NOT Harbor
	@$(SCRIPTS)/14-builder-build.sh

.PHONY: builder-push
builder-push: check-env ## (sneakernet, AIR-GAP box) Push the CARRIED Maven builder into Harbor — needs Harbor, NOT the internet (uses the carried crane; no container engine)
	@$(SCRIPTS)/22-builder-push.sh

##@ VKS access
.PHONY: vks-login
vks-login: check-env ## Authenticate to VKS (VCF 9 + Supervisor) → writes KUBECONFIG/context
	@$(SCRIPTS)/30-vks-login.sh

.PHONY: fetch-harbor-ca
fetch-harbor-ca: ## Fetch the CA that ISSUED the lab Harbor's cert → HARBOR_CA_FILE, and VERIFY it (for HTTPS mirror/Kaniko trust)
	@$(SCRIPTS)/fetch-ca.sh "$(HARBOR_URL)" "$(HARBOR_CA_FILE)" harbor

.PHONY: fetch-argocd-ca
fetch-argocd-ca: ## Fetch the CA that ISSUED the ArgoCD server's cert → ARGOCD_CA_FILE, and VERIFY it (endpoint: ARGOCD_LB_IP or ARGOCD_SERVER)
	@ep="$(if $(ARGOCD_LB_IP),$(ARGOCD_LB_IP),$(ARGOCD_SERVER))"; \
	 [ -n "$$ep" ] || { echo "ERROR: set ARGOCD_LB_IP (kind, from the state overlay) or ARGOCD_SERVER (lab argocd-server LB IP) first"; exit 1; }; \
	 $(SCRIPTS)/fetch-ca.sh "$$ep" "$(if $(ARGOCD_CA_FILE),$(ARGOCD_CA_FILE),./secrets/argocd-ca.crt)" argocd

##@ Container engine (podman is the default; docker is supported when you ask for it)
.PHONY: engine-check
engine-check: ## READ-ONLY: does this box have what your engine needs, and will it cost you a sudo? (no cluster, no registry)
	@$(SCRIPTS)/18-engine-check.sh

.PHONY: trust-harbor
trust-harbor: check-env ## Make YOUR engine trust the self-signed Harbor — and PROVE it with a real login handshake
	@$(SCRIPTS)/19-trust-harbor.sh

.PHONY: harbor-robot
harbor-robot: ## Create a least-privilege Harbor CI robot account (push+pull) → secrets/harbor-robot.env; copy into .env
	@$(SCRIPTS)/22-harbor-robot.sh

.PHONY: lab-preflight
lab-preflight: ## Read-only: three cluster preconditions that each kill the run LATER (CRD-create · a DEFAULT StorageClass · a working LoadBalancer provider)
	@$(SCRIPTS)/24-lab-preflight.sh

.PHONY: preflight argocd-preflight
preflight: check-tools argocd-preflight lab-preflight psa-check ## Read-only: can this lab actually run the flow? Run it BEFORE the 20-minute mirror (first prereq of install-all)

.PHONY: argocd-preflight
argocd-preflight: ## ArgoCD version + TOPOLOGY + write-mechanism + AppProject + Gitea reachability (two-cluster aware; non-zero on a blocking finding)
	@$(SCRIPTS)/23-argocd-preflight.sh

.PHONY: argocd-version
argocd-version: ## Read-only: ArgoCD CLI vs RUNNING-server vs repo-pin versions (never gates; exits 0 even with no cluster)
	@$(SCRIPTS)/argocd-version.sh

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
install-harbor: check-env ## Install Harbor into KinD (LoadBalancer; self-signed HTTPS+CA by default, HTTP with HARBOR_INSECURE=1); wire containerd + the .env.state overlay
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
e2e-kind: ## Full local end-to-end in KinD (+ ingress route check + PSA/VKS admission check). .env IGNORED (fresh-box fidelity; E2E_SKIP_DOTENV=0 to use yours). E2E_FRESH=1 forces a COLD cluster (proves create-ordering)
	@if [ "$(E2E_FRESH)" = "1" ]; then echo "==> E2E_FRESH=1: COLD run — tearing down first so namespace create-ordering is actually exercised"; $(MAKE) kind-down; fi
	@$(MAKE) kind-up install-harbor install-argocd install-all install-ingress verify-gateway-image verify verify-ingress
# psa-check in a SEPARATE make invocation, deliberately. It is also a prerequisite of `preflight`
# (:301), which `install-all` (:459) needs — so in ONE invocation make runs it EARLY, against an
# empty cluster, and then reports `Nothing to be done for 'psa-check'` at the end. Measured
# 2026-07-17: the early run said "measured 0 namespace(s) with running pods · 9 absent · PSA
# UNPROVEN — this run measured NOTHING", and the run that would have proven anything never
# happened. The e2e advertised "+ PSA/VKS admission check" and checked nothing.
# psa-check's own output had said it: "Come back and re-run 'make psa-check' AFTER 'make platform'
# — that run is the one that proves it." A second invocation is what does that.
	@$(MAKE) psa-check
# The LAST line the operator reads: did this run prove namespace create-ordering, or reuse a warm
# cluster? (B42 — 05-kind-up.sh published KIND_REUSED; this reads it back, loudly, on stdout.)
	@$(SCRIPTS)/e2e-ordering-verdict.sh

.PHONY: e2e-kind-both
e2e-kind-both: ## Matrix: run the full KinD e2e in BOTH SSL modes (secure self-signed TLS, then insecure plain-HTTP)
	@echo "==> e2e-kind matrix [1/2]: SECURE mode (self-signed TLS — the default)"
	@$(MAKE) kind-down          # clear the stale STATE SINK (.env.state) so the mode is deterministic
	@$(MAKE) e2e-kind
	@echo "==> e2e-kind matrix [2/2]: INSECURE mode (HARBOR_INSECURE=1 ARGOCD_INSECURE=1 — plain HTTP)"
	@$(MAKE) kind-down          # kind-down clears the STATE SINK → the insecure toggle is not clobbered by a persisted HARBOR_INSECURE=0
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

# The air-gap box's OS — BOTH BY DEFAULT, and that is the point. The far side is where Photon and Ubuntu
# actually diverge, and every divergence is invisible on the near side: Photon's coreutils are TOYBOX,
# not GNU (its `tar`, the `gzip -t` that false-failed here once, and the `file` whose 'static' spelling
# false-died `make bundle` on every carried binary until 2026-07-18), and the carried `crane` must exec
# there. (The bundle's COMPRESSOR used to be a third reason — chosen outside, decoded inside — but
# BUNDLE_COMPRESSOR now defaults to `none`, a plain .tar, so there is no decoder to lack.)
#
# This ran Photon-only, which is exactly why a shipping bug survived: the host emitted a .tar.zst that an
# Ubuntu air-gap box CANNOT OPEN, and the Photon leg passed because that image happens to have GNU tar.
# A matrix that only ever runs one leg is decoration. Narrow it deliberately if you must: SNEAKERNET_OS=photon
SNEAKERNET_OS ?= photon ubuntu

.PHONY: e2e-sneakernet
e2e-sneakernet: ## Faithful TWO-BOX sneakernet on KinD: [host=internet box] mirror-pull → bundle → carry ONLY the tarball → [FRESH jumpbox container=air-gap box] bundle-load → mirror-push → mirror-verify
	@SNEAKERNET_OS="$(SNEAKERNET_OS)" SNEAKERNET_TRANSFER="$(SNEAKERNET_TRANSFER)" $(SCRIPTS)/e2e-sneakernet.sh

.PHONY: e2e-sneakernet-both
e2e-sneakernet-both: ## The sneakernet OS matrix: the SAME carried tarball unpacked + pushed by a Photon air-gap box AND an Ubuntu one (each gets a fresh, EMPTY Harbor so its push is a real push)
	@$(MAKE) e2e-sneakernet SNEAKERNET_OS="photon ubuntu"

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

.PHONY: verify-gateway-image
verify-gateway-image: ## LIVE: every running Istio container image came from OUR Harbor (catches a silently-ignored --set global.hub on a dual-homed box)
	@./scripts/96-verify-gateway-image.sh

.PHONY: verify-ingress
verify-ingress: check-env ## Assert the *.vks.local UIs route through the ingress LB (reads INGRESS_LB_IP from the .env.state overlay)
	@$(SCRIPTS)/98-verify-ingress.sh

.PHONY: verify-ingress-rendered
verify-ingress-rendered: check-env ## Assert the ingress ROUTES were RENDERED where app backends deliberately do not exist (air-gap leg; additive to verify-ingress, never a replacement) (B50)
	@./scripts/97-verify-ingress-rendered.sh

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
	@$(MAKE) kind-down          # clear the stale STATE SINK (.env.state) so the ingress mode is deterministic
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
# The INGRESS_CONTROLLER= here is DECORATIVE and kept only for readability: psa-check reads the
# variable AFTER load_env, whose files beat the environment, so this override is EATEN. It works
# because `install-ingress` two lines up already PUBLISHED istio-existing to .env.state — that
# publication, not this argument, is what puts psa-check in attach mode.
	@$(MAKE) psa-check
	@echo "==> e2e-kind-istio-existing PASSED — the UIs route through an Istio we did not install (BOTH route APIs)"

##@ Jump-box validation (Photon / Ubuntu container, rootless podman)
JUMPBOX_OS     ?= photon
JUMPBOX_ENGINE ?= podman
# ENGINE-QUALIFIED, and it must stay that way. `vks-jumpbox:$(JUMPBOX_OS)` was a live footgun: building
# photon+podman and then photon+docker OVERWRITES THE SAME TAG, so a matrix runs whichever image was
# built last for BOTH legs and cheerfully reports two engines from one image — a false green by
# construction. The tag must name every dimension the image varies in.
JUMPBOX_IMAGE  ?= vks-jumpbox:$(JUMPBOX_OS)-$(JUMPBOX_ENGINE)
.PHONY: jumpbox-image
jumpbox-image: ## Build the jump-box test image for JUMPBOX_OS x JUMPBOX_ENGINE (photon|ubuntu x podman|docker)
	@# ENGINE-SPECIFIC DOCKERFILE. The podman images are Dockerfile.<os>; the docker images are
	@# Dockerfile.<os>-docker. This target used to build Dockerfile.<os> unconditionally, so the "docker"
	@# leg of the matrix built the PODMAN image, tagged it :<os>-docker, and ran it with
	@# JUMPBOX_ENGINE=docker — a leg that would have measured the wrong engine entirely. It was caught by
	@# the single-engine assert in jumpbox-run.sh ("this image has BOTH engines"), which is exactly the
	@# false green that assert exists to prevent.
	@df="jumpbox/Dockerfile.$(JUMPBOX_OS)"; \
	 [ "$(JUMPBOX_ENGINE)" = docker ] && df="jumpbox/Dockerfile.$(JUMPBOX_OS)-docker"; \
	 [ -f "$$df" ] || { echo "ERROR: no jump-box image for $(JUMPBOX_OS) x $(JUMPBOX_ENGINE) (expected $$df)"; exit 1; }; \
	 echo "building $(JUMPBOX_IMAGE) from $$df"; \
	 docker build -f "$$df" -t $(JUMPBOX_IMAGE) .

# Can a REAL air-gapped box do the job? The sneakernet e2e could NOT answer this: its "air-gap box" is
# the vks-jumpbox image, which runs `make deps` at BUILD time, so it already had kubectl/helm/jq/yq. This
# runs the bundle-load on a BARE box (OS packages only) with NO NETWORK AT ALL, on both OSes.
.PHONY: airgap-toolchain-test
airgap-toolchain-test: ## Can a BARE, network-less jump box (Photon AND Ubuntu) get its whole toolchain from the carried bundle? (asserts the tools are ABSENT first — else the test is rigged)
	@$(SCRIPTS)/test-airgap-toolchain.sh

.PHONY: bootstrap-engine-test
bootstrap-engine-test: ## CLAIM 1: does `make deps` actually PRODUCE a docker jump box when asked — and a podman one (with ZERO docker) when not? Runs the REAL bootstrap on BARE Photon/Ubuntu images.
	@$(SCRIPTS)/test-bootstrap-engine.sh

.PHONY: jumpbox
jumpbox: jumpbox-image ## Validate the README jump-box flow on JUMPBOX_OS x JUMPBOX_ENGINE against the running KinD cluster
	@# The launcher is a SCRIPT, not a recipe. Every silent failure this harness ever had lived in the
	@# 50-line `\`-continued block that used to be here: five reads of a renamed state file, four
	@# `grep`-under-`set -e` deaths with no output, a CA mounted but never named. A recipe cannot be
	@# shellcheck'd, unit-tested, or coherently `set -euo pipefail`'d; scripts/jumpbox-launch.sh can.
	@JUMPBOX_OS="$(JUMPBOX_OS)" JUMPBOX_ENGINE="$(JUMPBOX_ENGINE)" JUMPBOX_IMAGE="$(JUMPBOX_IMAGE)" \
	 JUMPBOX_VCF_SRC="$(JUMPBOX_VCF_SRC)" JUMPBOX_TARBALL="$(JUMPBOX_TARBALL)" \
	 $(SCRIPTS)/jumpbox-launch.sh

.PHONY: jumpbox-both
jumpbox-both: ## Validate the jump-box flow on BOTH Photon and Ubuntu (podman)
	@$(MAKE) jumpbox JUMPBOX_OS=photon JUMPBOX_ENGINE=podman
	@$(MAKE) jumpbox JUMPBOX_OS=ubuntu JUMPBOX_ENGINE=podman

.PHONY: jumpbox-matrix
jumpbox-matrix: ## THE ENGINE MATRIX: {photon,ubuntu} x {podman,docker}, each pushing to the real Harbor. Same expected outcome, 4/4.
	@# SEQUENTIAL, and that is deliberate: every leg PUSHES to the same Harbor and takes the registry
	@# lock — but the lock lives in the repo copy INSIDE each container, so it does not serialize across
	@# containers. Parallel legs would not corrupt Harbor (that story was a misdiagnosis; see CLAUDE.md),
	@# but a failure would be unattributable, which costs more than the wall-clock saves.
	@# The verdict COUNTS the legs; it does not assert them. `4/4 PASSED` used to be a hardcoded
	@# STRING while the loop tracked only rc — so a run that executed three legs, or a loop whose
	@# axes were later edited, would still have printed "4/4". That is this repo's own "the measured
	@# column must be MEASURED" failure, in the summary line of its own matrix.
	@rc=0; pass=0; total=0; \
	 for os in photon ubuntu; do \
	   for eng in podman docker; do \
	     total=$$((total + 1)); \
	     echo ""; echo "=================== LEG: $$os x $$eng ==================="; \
	     if $(MAKE) jumpbox JUMPBOX_OS=$$os JUMPBOX_ENGINE=$$eng; then \
	       pass=$$((pass + 1)); \
	     else \
	       echo "LEG FAILED: $$os x $$eng"; rc=1; \
	     fi; \
	   done; \
	 done; \
	 echo ""; \
	 if [ $$rc -eq 0 ] && [ $$pass -eq $$total ]; then \
	   echo "JUMPBOX MATRIX: $$pass/$$total PASSED — podman and docker each build and push to the self-signed Harbor, on Photon and Ubuntu"; \
	 else \
	   echo "JUMPBOX MATRIX: $$pass/$$total passed — FAILED"; exit 1; \
	 fi

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

.PHONY: builder-probe
builder-probe: ## Prove the CARRIED builder image is RUNNABLE, not merely fetchable (one pod, ~30s; the cheap half of what `verify` proves)
	@$(SCRIPTS)/24-builder-probe.sh

.PHONY: check-psa-defaults
check-psa-defaults: ## Gate: every PSA level a script falls back to matches .env.example, names a real level, and no reference hides from the check
	@$(SCRIPTS)/check-psa-defaults.sh

.PHONY: check-namespace-labelled
check-namespace-labelled: ## Gate: every namespace we OWN reaches an ensure_namespace call (PSA + no-inject); keyed on the INVENTORY, not on grepping for `kubectl create`
	@$(SCRIPTS)/check-namespace-labelled.sh

.PHONY: check-ns-chokepoint
check-ns-chokepoint: ## Offline: no NEW namespace-creating call outside the ensure_namespace chokepoint (4 of 10 mechanisms; see the header) (B40)
	@./scripts/check-ns-chokepoint.sh

.PHONY: check-grep-q-pipe
check-grep-q-pipe: ## Gate: no FILE-READING producer pipes into `grep -q` (SIGPIPE+pipefail turns a FOUND match into ABSENT, at random)
	@./scripts/check-grep-q-pipe.sh

.PHONY: check-pod-inject-label
check-pod-inject-label: ## Gate: every workload we ship declines sidecar injection in its POD TEMPLATE (a label, not an annotation)
	@$(SCRIPTS)/check-pod-inject-label.sh

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

##@ Offline script tests (unit tests for script logic; RUN BY static-check)
# Fast, fully-offline (no network/cluster/registry) unit tests for script logic that
# otherwise only breaks on a real lab box / mid-mirror.
#
# This header used to say "Deliberately NOT wired into static-check/ci so the core gate stays
# fast". That was FALSE: `static-check` depends on `test-scripts` (see its prereq list), and has
# for a while. A comment that tells you a gate does not run is worse than no comment — someone
# trusts it and skips the run.
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
test-scripts: test-secret-quoting test-vcf-cli-resolve test-mirror-cache test-classify-changes test-argocd-topology test-harbor-robot-payload test-kind-down-safety test-state-overlay test-container-engine test-creds-show test-env-check test-env-validate test-vks-sso-user test-vks-username test-vks-discover-namespace test-argocd-preflight-ns test-argocd-version test-adversary-gate-rearm test-namespace-gates test-psa-defaults test-gate-vacuity test-run-sentinel test-doc-robot-quoting test-kubeconfig-ready test-e2e-fresh test-ingress-state-ordering test-gateway-image test-psa-ownership ## Run all offline script-logic unit tests

.PHONY: test-vks-username
test-vks-username: ## Offline: the SHARED VKS SSO principal resolver — default, VKS_SSO_DOMAIN, C10 idempotency, and that BOTH consumers use it
	@./scripts/test-vks-username.sh

.PHONY: test-vks-discover-namespace
test-vks-discover-namespace: ## Offline: VKS_NAMESPACE discovery resolves the single case and REFUSES to guess when ambiguous (no head -1)
	@./scripts/test-vks-discover-namespace.sh

# NOTE: subagent-readonly + no-gate-in-commit-chain hooks (and their tests) are now GLOBAL
# (~/projects/claude-config, installed into ~/.claude); this repo keeps only the project-local
# adversary-first-gate. See CLAUDE.md "RULE ZERO".
.PHONY: test-adversary-gate-rearm
test-adversary-gate-rearm: ## Offline: the adversary-first gate RE-ARMS on every commit (a review authorizes only until the next commit)
	@./scripts/test-adversary-gate-rearm.sh

.PHONY: handoff-status
handoff-status: ## PRINTS ONLY (never gates, always exits 0): what merged since the handoff was last edited — read it against what the handoff CLAIMS
	@./scripts/handoff-status.sh

.PHONY: test-psa-ownership
test-psa-ownership: ## Offline: 49-psa-check's mesh-OWNERSHIP branch via a fake kubectl (it had ZERO behavioural coverage)
	@./scripts/test-psa-ownership.sh

.PHONY: test-gateway-image
test-gateway-image: ## Offline: RED/GREEN-prove 96-verify-gateway-image.sh's classifier via fixtures (no cluster)
	@./scripts/test-gateway-image.sh

.PHONY: test-ingress-state-ordering
test-ingress-state-ordering: ## Offline: INGRESS_CONTROLLER + INGRESS_LB_IP are published by the SAME script (a failed install must not leave the new controller beside the old IP)
	@./scripts/test-ingress-state-ordering.sh

.PHONY: test-namespace-gates
test-namespace-gates: ## Offline: RED-prove check-namespace-labelled + check-pod-inject-label catch a deleted ensure_namespace CALL / pod-label (B30c)
	@./scripts/test-namespace-gates.sh

.PHONY: test-gate-vacuity
test-gate-vacuity: ## Offline: STARVE each declared gate's corpus and require it to go RED — a gate that judged nothing must not report OK (B39/B49)
	@./scripts/test-gate-vacuity.sh

.PHONY: test-run-sentinel
test-run-sentinel: ## Offline: RED-prove assert_run_sentinel against fixture logs — the jump-box harness's real RED costs a 40-min container run (B47)
	@./scripts/test-run-sentinel.sh

.PHONY: test-psa-defaults
test-psa-defaults: ## Offline: RED-prove check-psa-defaults (12 cases, incl. the 3 vacuous greens an adversary measured in an earlier draft) (B22)
	@./scripts/test-psa-defaults.sh

.PHONY: test-doc-robot-quoting
test-doc-robot-quoting: ## Offline: RED-prove check-doc-robot-quoting flags an unquoted Harbor robot credential (both directions) (B28)
	@./scripts/test-doc-robot-quoting.sh

.PHONY: test-kubeconfig-ready
test-kubeconfig-ready: ## Offline: kubeconfig_ready gates on the FILE existing (C13), and the preflight accumulators/creator do NOT call it (B32)
	@./scripts/test-kubeconfig-ready.sh

.PHONY: test-e2e-fresh
test-e2e-fresh: ## Offline: E2E_FRESH=1 makes e2e-kind cold (kind-down first) + the reuse verdict banner is wired (B42)
	@./scripts/test-e2e-fresh.sh

.PHONY: test-secret-quoting
test-secret-quoting: ## Offline: a secret reaching a curl -K config / a .env line must round-trip and cannot inject
	@$(SCRIPTS)/test-secret-quoting.sh

.PHONY: test-creds-show
test-creds-show: ## creds-show must not claim anything the state does not support (renders it in every state)
	@$(SCRIPTS)/test-creds-show.sh

.PHONY: test-container-engine
test-container-engine: ## Offline: podman is the DEFAULT engine (docker only as fallback); no operator-flow script requires docker
	@./scripts/test-container-engine.sh

.PHONY: test-state-overlay
test-state-overlay: ## Offline: the stamped state overlay (unstamped=source, mismatch=ARCHIVE not delete, kind-down's delete contract)
	@./scripts/test-state-overlay.sh

.PHONY: test-env-check
test-env-check: ## Offline: env-check is a PRESENCE gate — it must FAIL on the HARBOR_URL sentinel + an absent kubeconfig
	@./scripts/test-env-check.sh

.PHONY: test-env-validate
test-env-validate: ## Offline: env-validate FAILS on an untrusted-TLS Harbor (no silent -k); env-populate won't clobber a granted URL
	@./scripts/test-env-validate.sh

.PHONY: test-vks-sso-user
test-vks-sso-user: ## Offline: vks_sso_user() is idempotent on '@' (no double SSO domain) and dies on a bare user with no VKS_SSO_DOMAIN (C10)
	@./scripts/test-vks-sso-user.sh

.PHONY: test-argocd-preflight-ns
test-argocd-preflight-ns: ## Offline: argocd-preflight must NOT block install-all on a guest-default ns-NotFound unless ARGOCD_MECHANISM=kubectl (C12)
	@./scripts/test-argocd-preflight-ns.sh

.PHONY: test-argocd-version
test-argocd-version: ## Offline: argocd_print_versions is exit-0 + never dials a default cluster (read-only version peek)
	@./scripts/test-argocd-version.sh

.PHONY: test-builder-save-crane
test-builder-save-crane: ## DEEP (needs docker + a network registry:2; NOT in static-check): guards the sneakernet builder's '<engine> save' -> 'crane push' round-trip for docker AND podman (skips loudly if a prereq is absent)
	@./scripts/test-builder-save-crane.sh

##@ Security scanning (internet/CI side; not part of the air-gap install)
# A GATE THAT SKIPS BECAUSE ITS TOOL IS MISSING IS A GATE THAT PASSES BY NOT LOOKING.
# Locally, warn + skip (a dev box may lack a scanner). In CI ($(CI) is set by GitHub), DIE — CI
# installs every one of these from .mise.toml, so a missing tool means the toolchain step is broken,
# and a scanner that reports success without running is worse than no scanner at all.
# The script-side gates use require_gate_tool() (scripts/lib/os.sh); these recipes are inline shell.
#
# NOTE the shape: ONE logical line. A multi-line `define` expands RAW NEWLINES into the recipe, so
# make hands each line to a SEPARATE shell — which splits the `{ ... }` block and made the local
# skip path exit 2 instead of 0. Caught by actually running it; it looked fine.
gate_tool_missing = if [ -n "$${CI:-}" ]; then echo "GATE TOOL MISSING IN CI: '$(1)' — run 'make deps' (mise installs it from .mise.toml)."; echo "Refusing to skip: a gate that reports success without running is worse than no gate."; exit 1; else echo "$(1) not installed — this gate is SKIPPED locally (run 'make deps'). It FAILS, not skips, in CI."; exit 0; fi

.PHONY: secrets
secrets: ## gitleaks — scan git HISTORY *and* the working tree for secrets
# `gitleaks detect` scans git HISTORY ONLY. That meant `make secrets` could not catch a secret you
# were ABOUT TO COMMIT — only one already committed, at which point it must be rotated, which is the
# very failure a pre-commit gate exists to prevent. (Proven: a planted high-entropy ghp_ token in an
# untracked file → "no leaks found", rc=0.) CI only worked by ACCIDENT: actions/checkout is shallow,
# so the root commit is diffed against the empty tree and the whole worktree is scanned as additions.
#
# So there are two legs. The second (--no-git) scans the files on disk and needs .gitleaks.toml,
# which allowlists the gitignored operator-local artifacts (self-signed CA/leaf keys, kubeconfigs) —
# without it, it reports 5 private keys on every real box, and a gate that is always red gets ignored.
	@# ONE recipe line (backslash-continued): each Makefile line runs in its OWN shell, so a guard
	@# that `exit 0`s on a separate line only ends the GUARD's shell — make then runs the scan anyway.
	@if ! command -v gitleaks >/dev/null 2>&1; then $(call gate_tool_missing,gitleaks); fi; \
	 gitleaks detect --no-banner --redact && \
	 gitleaks detect --no-git --no-banner --redact --config .gitleaks.toml

.PHONY: check-secrets-untracked
check-secrets-untracked: ## Gate: the paths .gitleaks.toml allowlists must NEVER be tracked by git
# The allowlist above is what lets the working-tree scan be green on a real box. Its one hole is a
# deliberate `git add -f .env` — which would then be INVISIBLE to gitleaks. Close it mechanically
# rather than by trust: those paths are gitignored, so if git is tracking one, something is wrong.
	@bad=""; for p in .env secrets .env.state .jumpbox; do \
	   git ls-files --error-unmatch "$$p" >/dev/null 2>&1 && bad="$$bad $$p"; \
	 done; \
	 if [ -n "$$bad" ]; then \
	   echo "ERROR: these are gitleaks-allowlisted (so NOT scanned) and MUST NOT be tracked:$$bad"; \
	   echo "       Untrack with: git rm --cached -r <path>   (and rotate anything that leaked)"; \
	   exit 1; \
	 fi; \
	 echo "check-secrets-untracked: OK — no allowlisted secret path is tracked"

.PHONY: trivy-fs
trivy-fs: app-build ## trivy — scan EVERY app's built artifact (jar / Go binary) for fixable HIGH/CRITICAL CVEs
	@$(SCRIPTS)/trivy-fs.sh

.PHONY: trivy-config
trivy-config: ## trivy — scan k8s/Tekton manifests for HIGH/CRITICAL misconfigurations (.trivyignore documents accepted findings)
	@if ! command -v trivy >/dev/null 2>&1; then $(call gate_tool_missing,trivy); fi; \
	 trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet \
	    --skip-dirs bundle --skip-dirs apps --skip-dirs docs --skip-dirs .claude \
	    --skip-files jumpbox/Dockerfile.bootstrap .

.PHONY: prose-secrets
prose-secrets: ## grep *.md for prose credentials gitleaks misses (natural-language secrets in runbooks)
	@bash scripts/check-prose-secrets.sh

.PHONY: secrets-scan
# The secret gates guard *.md every bit as much as they guard code — so CI must be able to reach them
# from a DOCS-ONLY PR, which skips static-check entirely (classify-changes.sh: docs=true, code=false).
# That is the ONLY PR shape that can add a prose credential to a runbook, which is precisely what
# prose-secrets exists to catch. Grouped here so the CI `secrets` job can run them WITHOUT dragging in
# trivy-fs's full Java+Go build. `sec` still contains them, so `make static-check` is unchanged.
secrets-scan: check-secrets-untracked secrets prose-secrets ## gitleaks + prose-credential scan (cheap; no build)

.PHONY: sec
sec: secrets-scan trivy-fs trivy-config ## Run all security scanners (gitleaks + prose-secrets + trivy fs/config)

##@ Diagrams & composite gates
# podman rootless needs --userns=keep-id so the mapped uid can write the mounted
# output dir; docker does not. Empty for docker.
PODMAN_USERNS := $(if $(filter podman,$(CONTAINER_ENGINE)),--userns=keep-id,)

# The diagram list is DERIVED from the filesystem, never typed. It used to be typed TWICE — once for
# the render, once for the drift-check loop — and they had already drifted: `istio-ingress` was in the
# render list and NOT in the check loop, so its PNG was rendered and then never gated. A new .puml
# (sneakernet) was in NEITHER, so it was silently not rendered at all. An enumerated list of the things
# a gate covers is the defect; the gate must discover its own denominator.
# `_style.puml` is an include, not a diagram — a leading `_` marks it as such and is filtered out.
DIAGRAMS := $(patsubst docs/diagrams/%.puml,%,$(wildcard docs/diagrams/[!_]*.puml))

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
		-tpng -o $(1) -DRELATIVE_INCLUDE="." $(addsuffix .puml,$(DIAGRAMS))
endef

.PHONY: diagrams
diagrams: ## Render docs/diagrams/*.puml → docs/diagrams/out/*.png ($(CONTAINER_ENGINE))
	@$(call _render_diagrams,out)
	@echo "diagrams: rendered → docs/diagrams/out/  (commit the PNGs)"

.PHONY: diagrams-check
diagrams-check: ## CI drift gate: re-render every .puml and byte-compare vs the committed PNG. The pinned plantuml image + vendored c4/ render byte-deterministically (verified: same image → identical sha256), so a mismatch means the .puml changed without re-rendering. Run `make diagrams` before committing .puml edits.
	@rm -rf docs/diagrams/.check
	@$(call _render_diagrams,.check)
	@echo "diagrams-check: checking $(words $(DIAGRAMS)) diagrams — $(DIAGRAMS)"
	@rc=0; for d in $(DIAGRAMS); do \
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
docs-lint: check-readme-scenarios check-doc-command-count check-doc-make-targets check-doc-target-coverage check-vks-terminology check-doc-novels check-doc-robot-quoting check-vks-provenance ## Lint markdown + the README-scenario, command-count, target-coverage, VKS-terminology, doc-novels and robot-quoting gates
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
	@# docs/reviews/ is EXCLUDED, and it is not a loophole. Those files are the archived, verbatim output
	@# of adversarial audits — one finding per heading, quoted as the agent wrote it. Two agents legitimately
	@# flag the SAME file:line, so headings repeat (MD024); a quoted table cell is a fragment, so column
	@# counts do not balance (MD056). Reformatting them to appease a linter would FALSIFY THE RECORD, which
	@# is the one thing an audit archive must not do. Nobody reads them as a runbook. Every OPERATOR-facing
	@# doc (README + docs/*.md) is still linted.
	@files=$$(git ls-files --cached --others --exclude-standard '*.md' | grep -v '^docs/reviews/'); \
	[ -n "$$files" ] || { echo "docs-lint: no markdown"; exit 0; }; \
	if command -v markdownlint >/dev/null 2>&1; then markdownlint $$files; \
	elif command -v npx >/dev/null 2>&1; then npx --yes markdownlint-cli@$(MARKDOWNLINT_VERSION) $$files; \
	else $(call gate_tool_missing,markdownlint); fi
	@# ^ this branch is INSIDE docs-lint, the one job whose only toolchain step is setup-node. If
	@# someone ever drops that step, markdownlint would vanish and this gate would report SUCCESS
	@# having linted nothing. In CI it now DIES instead.

.PHONY: static-check
static-check: check-namespace-labelled check-ns-chokepoint check-grep-q-pipe check-pod-inject-label check-psa-defaults check-doc-target-coverage check-doc-make-targets check-toolchain-alignment check-java-alignment check-gwapi-istio-alignment check-vks-terminology check-env check-env-coverage check-env-clobber check-app-hardcodes check-app-toolchains check-how-provenance check-vks-provenance check-image-alignment check-pull-secret-alignment lint validate sec test-scripts app-test ## Composite code gate (alignment + lint + manifests + security + script unit tests + app tests)

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
