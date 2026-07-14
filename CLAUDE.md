# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🛑 RULE ZERO — the adversaries review your DESIGN, not just your diff (BLOCKING, read first)

There are **TWO** adversaries. Both are BLOCKING. Each exists because a green run *here* cannot see
the ground it hunts on.

| Agent | Specialism | Its hunting ground — what a green run here CANNOT show |
|---|---|---|
| **`.claude/agents/vks-adversary.md`** | VMware VCF/VKS 9.1 + Kubernetes + ArgoCD + Harbor + Istio + Tekton | **the REAL LAB.** A green KinD run proves nothing about a Supervisor, a tenant's RBAC, a corporate PKI, or PSA `restricted`. |
| **`.claude/agents/docker-adversary.md`** | Docker Engine + containerd + registry TLS trust (`certs.d`, `insecure-registries`, rootless, credential stores, BuildKit, kind's Docker coupling, Kaniko, crane, podman's per-command trust) | **the DAEMON, and a COLD box.** Your box has a warm `~/.docker/config.json`, a stale login, a CA possibly already in the system store, a rootful daemon, and BOTH engines installed. A fresh air-gapped jump box has none of that. |

**Run EVERY docker/podman/engine/registry-trust design past `docker-adversary` BEFORE implementing it**
(owner's standing instruction, 2026-07-13). It has already earned its keep: see the `fix/podman-default`
entry in the handoff, where a "fail-fast" guard shipped a docker behaviour that **docker's own docs
contradict**.

**Owner's standing instruction (2026-07-14): USE THEM ALL THE TIME — not just at the triggers below.**
Every design decision, every implementation of a fix (including a fix THEY prescribed), every change of
approach mid-task, goes past the relevant adversary BEFORE it runs. The rule is not "review at
boundaries"; it is "you do not decide alone." This was added after I repeatedly made unilateral pivots —
a dind→host-native switch, a Dockerfile-layout choice, a whole harness — each of which the adversary then
demolished, and each of which cost a cycle that a five-minute review would have saved. If you find
yourself writing "I decided X on my own", you have already failed.

**They have THREE mandatory triggers. All are BLOCKING.**

| # | Trigger | When | Why |
|---|---|---|---|
| 1 | **START OF EVERY SESSION on this repo** | your FIRST substantive act — before you read your way into the code, before you plan, before you touch a file. Brief it with the handoff/backlog state and whatever you are about to do. | the inherited state is *itself* a set of claims (a prior session's findings, grades, "DONE" notes), and they are exactly the things that are wrong. It runs while you read — it costs you nothing to start it first. |
| 2 | **BEFORE you implement** | the moment you have a DESIGN, a DECISION, a root-cause CLAIM, or a plan. Touching VKS/ArgoCD/Harbor/Istio/Tekton/the air gap → **vks-adversary**. Touching docker/podman/the engine/registry trust/image builds → **docker-adversary**. Touching both (e.g. "make docker work against the lab's Harbor") → **BOTH**. Always *before* writing the code. | refuting a design costs one agent run; refuting shipped code costs a session. This trigger exists because it was MISSED: a fix for two CRITICALs was designed, and coding started, with no adversary in sight. |
| 3 | **BEFORE you call the session done** | the stopping rule — no session is DONE without it | the findings are part of the deliverable |

Triggers 1 and 2 collapse into one run when the session opens on a known task (brief it with the
backlog **and** the design). What is NOT acceptable is starting work with no adversary running.

**How to run it (NOT optional).** Use a **`Workflow`** (schema-forced output) or a **synchronous
`Agent`** (`run_in_background: false`). Do **NOT** fire-and-forget a background `Agent`. Measured
2026-07-12 in this repo: Workflow agents delivered **44/44**; background `Agent`s delivered **0/4**
(all idled; re-pinging did not revive them). The difference is the output contract — a Workflow
*forces* a result; a background agent's deliverable is merely whatever it says last, and these said
nothing.

Its findings are part of the deliverable: **fix them, or record each in the backlog with its grade**
(`lab-verified` / `KinD-verified` / `primary-sourced` / `9.0-doc-inferred-for-9.1` / `community` /
`UNVERIFIED`). "Reviewed, nothing found" is acceptable ONLY if the agent says so explicitly, with
evidence. If it produces nothing, that is a **blocker to report** — never quietly substitute your own
review and move on.

Subagents do **not** inherit skills or rules: each adversary carries its domain brief and the
portfolio conventions in its own system prompt on purpose. Keep them current when a fact changes.

**Agent definitions load at SESSION START.** A newly-written `.claude/agents/*.md` is **not
dispatchable in the session that created it** (`Agent type '<name>' not found`). If you must review a
design in that same session, run the persona **inlined** into a `general-purpose` agent's prompt —
the review still happens; only the shortcut is unavailable. (Learned 2026-07-13, creating
`docker-adversary`.)

## What this repo is

An **air-gapped VKS CI/CD demo**: from an internet-connected jump box (Ubuntu or
PhotonOS), mirror all required images into **Harbor**, install and wire **Gitea +
Tekton**, and demonstrate GitOps CD via **ArgoCD**. On a real VKS lab Harbor and ArgoCD
are installed as **Supervisor Services** (the README real-lab flow documents that,
Scenario 1); in Scenario 2 they already exist and you discover them as a tenant. We then install
Gitea + Tekton and the demo app. The KinD stand-in installs
Harbor + ArgoCD locally to mimic that.

End-to-end flow: `git push (Gitea) → Tekton (test/build/kaniko→Harbor/tag write-back) → ArgoCD sync → web UI`.

## Common commands

| Command | What it does |
|---------|--------------|
| `make help` | List all targets (grouped) |
| `make deps` | Install jump-box toolchain (mise + `scripts/00-install-prereqs.sh`) |
| `make ci` | Offline gate: `static-check` + `docs-lint` |
| `make static-check` | `check-toolchain-alignment` + `check-java-alignment` + `check-env` + `check-env-coverage` + `check-how-provenance` + `check-image-alignment` + `lint` + `validate` + `sec` + `test-scripts` (offline script unit tests) + `app-test` |
| `make sec` | Security scans: `secrets` (gitleaks) + `prose-secrets` (credential-shaped prose in docs) + `trivy-fs` (built-jar deps) + `trivy-config` (manifests) |
| `make app-test` / `app-build` / `app-run` | Spring Boot app dev (in `apps/java/javawebapp/`, uses `./mvnw`) |
| `make mirror` | (dual-homed) pull images → push to Harbor. **Resumable:** a re-run cache-skips digest-pinned images already fully pulled (`.mirror-ok` sentinel), so an interrupted/CDN-flaky mirror resumes in seconds. `MIRROR_RETRIES` (default 5), `MIRROR_FORCE_PULL=1` |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
| `make mirror-verify` | Verify every mirrored image is INTACT in Harbor (`crane validate` blobs + `images.lock` digest match) — read-only; run after `make mirror` |
| `make builder-image` | build+push the offline Maven builder image (deps pre-baked) |
| `make vks-login` | Authenticate to VKS → writes `$KUBECONFIG` + context |
| `make install-vcf-clis` | On a real-VKS-lab jump box: install the Broadcom lab CLIs (`argocd-vcf` + `vcf` + plugins), OS/arch-aware + sudo-free, from operator-supplied licensed archives in `VCF_CLI_SRC_DIR=<dir>`. (The local KinD e2e doesn't need these — it uses the upstream `argocd` from `deps`.) Granular: `install-argocd-vcf` / `install-vcf-cli` / `install-vcf-plugins` |
| `make platform` | Install + wire Gitea and Tekton |
| `make gitops` | Create the ArgoCD Application |
| `make creds-show` (alias `creds`) / `make argocd-password` | Print access URLs+logins / the ArgoCD admin password (context-aware, self-resolves kubeconfig) |
| `make env-init` / `env-populate` / `env-check` / `env-validate` | `.env` lifecycle: create from `.env.example` → GENERATE the secrets we can + DISCOVER cluster values (and print the user-PROVIDE list) → presence gate → validity gate (format + KUBECONFIG/Harbor auth) |
| `make harbor-robot` / `fetch-harbor-ca` / `fetch-argocd-ca` / `fetch-argocd-kubeconfig` / `argocd-preflight` | Real-lab helpers: mint a Harbor robot (needs project-admin) · fetch a self-signed CA · fetch the Supervisor kubeconfig for ArgoCD registration · report ArgoCD CLI vs RUNNING SERVER vs supported versions |
| `make test-scripts` | Offline script-logic unit tests (mirror cache-skip/resume/prune; VCF-CLI archive resolve). Part of `static-check` |
| `make e2e-kind-both` / `verify-ingress-both` / `e2e-cross-cluster` / `e2e-sneakernet` | e2e permutations: both SSL modes · both ingress controllers · 2-cluster ArgoCD registration · two-box sneakernet |
| `make install-ingress` | Install the ingress (`INGRESS_CONTROLLER=istio` default / `istio-existing` = attach to a platform-owned mesh / `traefik`) fronting the UIs at `*.vks.local` |
| `make install-istio` / `install-traefik` | Install a specific ingress controller directly |
| `make psa-check` | Read-only: would our pods survive a real VKS guest cluster? VKS **enforces PSA `restricted` by default** (VKr v1.26+) while KinD enforces nothing — so `ci` (Kaniko builds as root) and the Gateway namespace (Istio's auto-provisioned proxy sets no seccompProfile) need `baseline` or their pods are REJECTED on the lab. Levels are MEASURED via a server-side dry-run label, not guessed. Wired into both e2e targets |
| `make istio-preflight` | Read-only: is Istio here, what `Gateway` selector does it require, what may this kubeconfig do, and what must the mesh admin grant? Run before touching a cluster you don't own |
| `make attach-istio` | Attach to an Istio the platform team ALREADY installed (`INGRESS_CONTROLLER=istio-existing`) — installs nothing, applies routes only. `ISTIO_ROUTE_API=auto` (default) prefers the Kubernetes **Gateway API** (Istio auto-provisions the proxy + LB; nothing needed from the mesh admin) and falls back to `classic` (discovered `istio:` selector + VirtualServices) |
| `make e2e-kind-istio-existing` | KinD regression test for the attach mode: a "platform team" installs Istio under FOREIGN naming, we attach with zero install (+ both REDs), then verify BOTH route APIs (gateway-api leg + classic leg) |
| `make install-all` | Full air-gap install: `mirror → builder-image → vks-login → platform → gitops` |
| `make verify` | End-to-end smoke test (LIVE cluster) |
| `make verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| `make e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify) |
| `make kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps |
| `make jumpbox` / `jumpbox-both` | Validate the README jump-box bootstrap on a real jump-box container — `JUMPBOX_OS=photon` (default, `photon:5.0`) or `JUMPBOX_OS=ubuntu` (`ubuntu:26.04`); rootless podman, joined to the kind network: runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` runs the OS matrix. Needs the KinD cluster up |

Run a single app test: `cd apps/java/javawebapp && ./mvnw -B -Dtest=<ClassName>#<method> test`.

## Architecture / big picture

- **Scripts are numbered by execution order** (`scripts/NN-*.sh`) and all source
  `scripts/lib/os.sh` — the shared library providing OS detection (Ubuntu `apt` /
  PhotonOS `tdnf`), `pkg_install`, logging, `load_env`, and `trust_ca`. Add new OS
  support in `lib/os.sh`, not in individual scripts.
- **`.env.example` is the single source of truth** for every tunable. The Makefile
  `-include .env` + `?=` defaults and every script's `load_env` both read it. Never
  hardcode a host/port/timeout/version — add it to `.env.example` (`make check-env-coverage`
  gates it). A var the code reads with a FALLBACK (`${X:-$(pick_port)}`, `${A:-$B}`) or a
  per-run TOGGLE must be left **commented** there — `load_env` sources the file with `set -a`,
  so an uncommented value is exported and silently CLOBBERS the fallback/override.
- **The KinD e2e IGNORES `.env`** (`SKIP_DOTENV=1`, set by `E2E_SKIP_DOTENV ?= 1` on both
  `e2e-kind` targets). It is a stand-in for a fresh operator / a CI runner, neither of which has
  a `.env`, so the you-choose secrets must be GENERATED (`05-kind-up.sh`), not read from yours.
  Without it a local run passes on values only your box has. Opt out: `E2E_SKIP_DOTENV=0`.
- **Manifest layout:** `k8s/{gitea,istio,traefik,tekton,argocd}/` = everything **we** apply to
  the cluster. `deploy/javawebapp/` is **not** applied by us — `50-seed-gitea-repos.sh` seeds it into
  the `javawebapp-deploy` Gitea repo (one dir per deploy repo); `apps/java/javawebapp/` is the content of
  the `javawebapp-app` repo. Do not nest `deploy/` inside `apps/java/javawebapp/` — that dir IS the app
  repo, so the manifests would land in it and collapse the two-repo GitOps split.
- **Mirror mode is not a variable** — dual-homed vs sneakernet is simply which mirror
  commands you run: dual-homed → `make mirror`; sneakernet → `make mirror-pull && make
  bundle` (carry the bundle) then `make bundle-load && make mirror-push`.
- **Two Git repos** in Gitea: `javawebapp-app` (source + Dockerfile + trigger binding)
  and `javawebapp-deploy` (kustomize manifests ArgoCD watches). CI writes the new image
  tag back to `javawebapp-deploy`; ArgoCD deploys from it.
- **VKS auth is isolated in `scripts/30-vks-login.sh`** — the only auth-aware step;
  everything else consumes `$KUBECONFIG`/context.
- **Internal CA trust** (self-signed Harbor) is wired **sudo-free** per consumer — jump-box
  `crane`/`curl` via `SSL_CERT_FILE` (a system-store + our-CA bundle from `lib/tls.sh`), the
  builder push via podman `--cert-dir`, each kind node's containerd via `certs.d/<ip>/ca.crt`,
  and in-cluster Kaniko via the `harbor-ca` ConfigMap. No root-owned system-store change. See
  `docs/decisions/kind-tls-fidelity.md`.
- **Air-gap Maven builds**: an in-cluster `mvn`/Kaniko build cannot reach Maven
  Central, so `scripts/15-build-push-builder.sh` builds `apps/java/javawebapp/Dockerfile.builder`
  on the internet side (bakes the full `~/.m2` via `mvn verify`) and pushes it to
  Harbor. The app `Dockerfile` (`BUILDER_IMAGE` + `MVN_OFFLINE=-o` args) and the
  Tekton `maven-test` task both consume it and build **offline**. Rebuild + bump
  `BUILDER_IMAGE_TAG` when `apps/java/javawebapp/pom.xml` deps change.
- **KinD local e2e**: `kind/kind-config.yaml` enables containerd `config_path`;
  `05-kind-up.sh` runs cloud-provider-kind (LoadBalancer) and writes `KUBECONFIG` +
  `VKS_AUTH_METHOD=kubeconfig` to `.env.kind`; `06-install-harbor.sh` exposes Harbor as a
  **self-signed-HTTPS LoadBalancer on the LB IP** (default; two-phase: install TLS-off →
  discover LB IP → mint CA+leaf with SAN=IP → upgrade to TLS), wires each node's containerd
  with the CA (`certs.d/<ip>/`), and writes `HARBOR_URL`(LB IP)+`HARBOR_INSECURE=0`+
  `HARBOR_CA_FILE` to `.env.kind` (`HARBOR_INSECURE=1` selects the original plain-HTTP mode).
  `07-install-argocd.sh` exposes ArgoCD on its **own** LB with self-signed TLS (default) and
  publishes `ARGOCD_LB_IP`. That overlay (loaded last by `load_env` / `-include`) makes the
  normal flow run against kind unchanged. `kind-down.sh` prunes cloud-provider-kind + `kindccm-*` orphans.
- **Manifest rendering**: k8s/ YAML (gitea, istio, traefik, tekton, argocd) carry `${VAR}` tokens rendered by
  the configure scripts with a RESTRICTED `envsubst` allowlist (so step-script
  `$(...)`/`${}` are untouched). Tekton install rewrites upstream image hosts
  (`gcr.io/…` → Harbor) via `sed`, matching `lib/mirror.sh`'s mapping.
- **Istio: two scenarios** (see `docs/decisions/istio-on-vks.md`). `INGRESS_CONTROLLER=istio`
  (default) INSTALLS the mesh; `istio-existing` attaches to one the platform team already
  installed and installs NOTHING. **Istio has no credentials** — it exposes no login, no bearer
  token, and no admin API; mesh
  access is kubectl RBAC (the only credential-shaped object is a TLS Secret named by
  `Gateway.tls.credentialName`, which lives in the gateway's namespace → you REQUEST it).
  The load-bearing fact: the `istio/gateway` helm chart derives the gateway's `istio:` label from
  the **helm RELEASE NAME**, so a foreign mesh is NOT labelled `ingressgateway` — the selector must
  be DISCOVERED (`scripts/lib/istio.sh`: the Service exposing port **15021** with a
  `spec.selector.istio` key; istiod has no 15021, which excludes the control plane). A
  non-matching selector is **accepted by the API server with no error** and binds nothing →
  connection refused; a VirtualService naming the Gateway by **bare name** from another ns
  resolves namespace-locally → 404. VirtualServices therefore live in their BACKEND's namespace
  with a `<gw-ns>/<gw-name>` ref (the only layout a locked-down tenant can use). `make
  istio-preflight` is the read-only "what do I have / what must the mesh admin grant me" helper;
  `make e2e-kind-istio-existing` is the regression test (a "platform team" installs Istio under
  FOREIGN naming, then we attach — plus both REDs).
- **Pluggable ingress**: `INGRESS_CONTROLLER` (`istio` default / `istio-existing` / `traefik`)
  selects the controller. `scripts/44-install-ingress.sh` dispatches to `46-install-istio.sh` (helm
  control plane + gateway LB; istio images from Harbor via the `global.hub` override),
  `47-attach-istio.sh` (discover + attach only), or
  `45-install-traefik.sh` (single-binary LB). All expose the SAME `*.vks.local` hosts
  (`GITEA_HOST`/`JAVAWEBAPP_HOST`/`TEKTON_DASHBOARD_HOST` — **not** ArgoCD, which has its own LB) behind ONE LoadBalancer and
  publish `INGRESS_LB_IP` + the chosen `INGRESS_CONTROLLER` to `.env.kind`. `44-install-ingress.sh`
  lets an explicit `INGRESS_CONTROLLER` override win over the persisted `.env.kind` value (so
  `verify-ingress-both` actually flips controllers). Hostnames resolve via
  `/etc/hosts` → the LB IP (no internet DNS). **Harbor and ArgoCD each keep their OWN direct LB**
  — Harbor's LB IP is load-bearing for the containerd registry pull path (self-signed HTTPS +
  node CA by default) and ArgoCD's own self-signed-TLS LB mirrors the VKS lab; neither is routed
  through the ingress. `make verify-ingress` (in `e2e-kind`, after `verify`) route-checks
  each host through the LB with a K1.5 readiness poll (cloud-provider-kind wires the LB
  Envoy 5–60s after the IP is assigned) and asserts each host serves its own body marker;
  `verify-ingress-both` runs the istio+traefik matrix.
- **Tekton Dashboard**: `TEKTON_DASHBOARD_VERSION` (Renovate `github-releases`) pins the
  read-only `tektoncd/dashboard` web UI; `10-mirror-pull.sh` fetches its release manifest (its
  ghcr.io image auto-mirrors to Harbor), `41-install-tekton.sh` applies it (host-rewritten)
  into `tekton-pipelines`, and the ingress fronts it at `TEKTON_DASHBOARD_HOST`
  (`tekton.vks.local`). No built-in auth — network/ingress-gated (no login).
- **`.env.example` clobber rule (BLOCKING, bites repeatedly):** `load_env` sources `.env.example`
  with `set -a`, so **every uncommented line becomes an exported env var** — applied AFTER make put
  a per-run override in the environment. So a var that the code reads with a **dynamic fallback**
  (`${VAR:-$(pick_port)}`, `${VAR:-${OTHER}}`) or that a make target **overrides per-run**
  (`make bundle BUNDLE_OUT_DIR=…`) MUST stay **COMMENTED** there, or the sourced value silently
  wins. It has broken real things three times: `GITEA_LOCAL_PORT` killed the ephemeral-port
  parallel-safety; `BUNDLE_OUT_DIR` made `tar` archive a directory into itself; `BUNDLE_TARBALL`
  made `bundle-load` look in the wrong place. `make check-env-clobber` now enforces it.
- **Security + alignment gates** (`static-check`, internet/CI side): `check-toolchain-alignment`
  (kubectl pin in `.mise.toml` == `.env.example` `KUBECTL_VERSION`), `check-java-alignment`
  (Java major identical across `apps/java/javawebapp/pom.xml`, `.mise.toml`, `ci.yml`, the `apps/java/javawebapp/Dockerfile`
  build+runtime images, and `images/images.txt` — Renovate tracks the maven build image and
  the eclipse-temurin runtime image separately, so it can split them; the build once compiled
  for 21 but ran on 25), `sec` (gitleaks +
  trivy fs on the built jar + trivy config on manifests; `.trivyignore` documents the two
  accepted-by-design misconfigs — gitea RO-rootfs, Traefik secrets RBAC). trivy/gitleaks/shellcheck
  are `.mise.toml`-provided (pinned) so local `make static-check`/`make lint` use the SAME versions as
  CI — an unpinned system shellcheck drifts and flags SC2015 that a newer local build doesn't
  (green-local/red-CI).
- **The `.env.example` gates** — `check-env` (it exists), `check-env-coverage` (every operator-settable
  var the scripts read is documented; it scans **every operator-run script** and PRINTS ITS DENOMINATOR
  — it used to glob `[0-8][0-9]-*.sh` and was blind to `99-verify.sh`, which is exactly why the
  `GITEA_LOCAL_PORT` clobber survived), `check-env-clobber` (the rule above), `check-how-provenance`
  (every `# how:` command must be one WE run, a real make target, or provenance-tagged — a fabricated
  `vcf` command shipped once). `test-scripts` (offline script-logic unit tests) is also in
  `static-check`; it previously had targets that **nothing invoked**.
- **A gate is trusted only after a demonstrated RED.** Every gate here has been proven to fail on the
  defect it claims to catch. Two of them were found *passing by not looking*: `check-env-coverage`
  (above) and `lint`, which listed the manifest dirs by name and silenced yamllint's stderr — when a
  dir moved it failed with "findings above" and **nothing above**.

## Conventions

- **Version manager:** mise (`.mise.toml`) on the jump box — including `crane`
  (the image-mirror engine, a static Go binary). Air-gap exception:
  `tkn`/`argocd` come from OS packages / pinned releases via
  `00-install-prereqs.sh`; the air-gapped host gets binaries from the bundle.
- **Secrets never in argv** — PATs/registry creds via stdin / `--password-stdin` /
  env-by-name (see `.env.example` commented secret placeholders).
- **Java app:** Spring Boot 4 + JUnit/`@SpringBootTest`; Dockerfile follows the
  multistage temurin / non-root / actuator-`HEALTHCHECK` template.
- **Manifests:** Kustomize; validated with `kustomize build | kubeconform`.
- **Container engine split:** `CONTAINER_ENGINE` (podman is the DEFAULT; **docker is SUPPORTED, opt-in**)
  drives image ops — mirror, builder image, diagrams. The **KinD local e2e path
  requires Docker regardless**: `05-kind-up.sh` (`require_cmd docker`) + cloud-provider-kind use
  the `kind` Docker network/socket, so node interactions (`crictl` via
  `docker exec <node>`) use Docker even in this podman-default repo. That is `kind`, not us — and it
  is why `make e2e-kind CONTAINER_ENGINE=docker` can never prove the *jump-box* docker claim (it runs
  on the one box required to have docker).
- **The bootstrap is ENGINE-AWARE, and the invariant is DOCKER IS NEVER *REQUIRED*.** With
  `CONTAINER_ENGINE` unset, `make deps` installs podman and **zero** docker packages; with
  `CONTAINER_ENGINE=docker` it installs docker + its rootless prerequisites and **not** podman (both
  present would silently run podman, since `container_engine()` prefers it). The package list lives in
  `engine_packages()` — a **pure function** — specifically so `test-container-engine.sh` (check 7) can
  **execute** it and assert the list in both directions, offline. The previous gate scanned for docker
  *invocations at a command position* and was **structurally blind to a docker dependency**
  (`pkg_install docker` matches none of its patterns — proven), so an engine-aware bootstrap would have
  put a docker daemon on **every** jump box under a **green** gate. RED-proven 4 ways.
- **What docker COSTS, measured (`make engine-check`, read-only):** podman → **no sudo, ever**
  (daemonless; CA per command via `--cert-dir`). docker **rootless** → **no sudo** (daemon reads
  `~/.config/docker/certs.d/<host>/ca.crt`). docker **rootful** → **one sudo PER REGISTRY**
  (`/etc/docker/certs.d` is root-owned; the `docker` group grants SOCKET access, not write access to
  `/etc`, so this cannot be engineered away — only disclosed). `make trust-harbor` wires the CA for
  whichever engine you have and **proves it with a real login handshake** — never by checking that a
  file exists (docker MERGES `certs.d` with the system store, so a missing `ca.crt` proves nothing;
  that guard was shipped once and retracted).
- **Rootless docker from DISTRO repos: Photon ✅ · Ubuntu 26.04 ✅ · Ubuntu 24.04 ❌** (ran-it). `docker.io`
  is 29.1.3 on both Ubuntus, but only **26.04's deb ships `dockerd-rootless.sh`** (hidden in
  `/usr/share/docker.io/contrib/`, OFF PATH — `make deps` symlinks it); 24.04's ships **zero** rootless
  files. Photon ships `docker` + `docker-rootless` + `rootlesskit` first-class with the helper already on
  PATH — **Photon is the EASY OS for rootless docker**, inverting the usual assumption. On 24.04 we
  **refuse to add `download.docker.com`** to someone else's jump box (a proxy-allowlist / security-review
  item an admin may refuse), so docker there is **rootful-only** and we say so out loud.
- **Image tag alignment:** every mirrored image's tag is duplicated between
  `images/images.txt` (the Renovate-tracked mirror source of truth) and its consumers
  (k8s/tekton manifests, `.env.example` `TEMURIN_*_TAG`, the app `Dockerfile`). `make
  check-image-alignment` (in `static-check`) fails CI on any drift; a general Renovate
  customManager bumps the consumers in lockstep.

## VKS services — the living record

`docs/vks-services/` is the tracked, updatable record of what VMware/Broadcom actually ships and how
we consume it: [`harbor.md`](docs/vks-services/harbor.md), [`argocd.md`](docs/vks-services/argocd.md),
[`istio.md`](docs/vks-services/istio.md). Each fact carries a **provenance grade** (lab-verified /
KinD-verified / 9.0-doc-inferred-for-9.1 / community / UNVERIFIED) — the Broadcom 9.1 doc URLs
301-redirect to the 9.0 tree, so most vendor facts are *inferences about 9.1*. **When a lab run
confirms or refutes something, update the grade in place** (and correct the fact, with a note) rather
than re-deriving it next session. The load-bearing split: Harbor + ArgoCD are **Supervisor Services**
(they run beside your workload cluster → discover + request + register); Istio is a **guest-cluster
Standard Package** (→ attach, never install; there are no Istio credentials).

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |
| `docs/diagrams/*.puml` | `/architecture-diagrams` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.

## Adversarial review — see **RULE ZERO** at the top of this file

The two BLOCKING triggers (before you implement · before you call the session done), how to run it
(`Workflow` with a schema, or a synchronous `Agent` — never fire-and-forget), and what to do with the
findings are all in Rule Zero. Do not duplicate them here.

## ▶️ HANDOFF 2026-07-14 (late) — START HERE

`main` GREEN · **0 open PRs** · 9 PRs merged this session · all 8 e2e permutations green (table below).

### THE ONE THING TO INTERNALISE

**Every single bug this session was something that REPORTED SUCCESS WITHOUT DOING THE WORK — and a green
gate agreed with it.** A push that skipped all 36 uploads and exited 0. A security gate CI structurally
could not run. A CRD install whose acceptance check was *already true before the code existed*. A harness
that printed `sudo=NO` while sudo was prompting. Assume this class by default; it is the house style of
this repo's failures.

### NEXT UP (in order)

1. **Task: make docker genuinely supported on the jump box** (owner's decision, option B). This is the
   next substantial piece of work and it is fully specced in the task list. The kernel of it:
   **`00-install-prereqs.sh` installs PODMAN ONLY** — there is no `pkg_install docker` anywhere, on either
   OS, and `test-container-engine.sh:83-85` **asserts that as an invariant with a gate enforcing it**. So
   docker on a jump box is *not untested — it is unsupported by our own bootstrap.* The work: an
   engine-aware bootstrap + a `make` target that CHECKS the docker prereqs + one that INSTALLS them + a
   test; the jump-box matrix then tests **that change**. Traps already found: Ubuntu's `docker.io` ships
   **no rootlesskit** (only Docker's third-party repo does — a real ask for an air-gapped box) while
   **Photon has a first-class `docker-rootless` package** (it is the EASIER OS, which inverts the usual
   assumption); `JUMPBOX_IMAGE` is **not engine-qualified**, so a matrix would silently reuse the wrong
   image.
2. **Task: run every e2e permutation with `CONTAINER_ENGINE=docker`.** Every green e2e so far ran on
   podman. Assert `using container engine: docker` in each leg — do not eyeball it.
3. **A real lab.** The Supervisor topology, the `vcf` CLI auth flow, and whether a VKS guest cluster ships
   the Gateway API CRDs remain **UNVERIFIED**. No amount of KinD green changes that.

### The option-B spec, inline (do NOT rely on the task list surviving)

The jump-box docker work has four traps that will each produce a confident false green. They are the
reason this is a real task and not an afternoon:

1. **Do NOT pre-bake the deps into the harness image.** `Dockerfile.ubuntu` deliberately OMITS
   `uidmap`/`slirp4netns` so `make deps` has to install them. Pre-baking proves *"rootless works if the
   packages are already there"* — which nobody doubts — while leaving the actual question (**does OUR
   bootstrap install them?**) unanswered. This repo has already been burned by a fix that landed only in
   the harness image.
2. **ONE ENGINE PER IMAGE.** `container_engine()` falls back to podman if it is present, so a "docker leg"
   on a both-engines image would **silently run podman** and look green. Assert at build time that the
   other engine is ABSENT.
3. **`JUMPBOX_IMAGE ?= vks-jumpbox:$(JUMPBOX_OS)` is not engine-qualified** — building photon+podman then
   photon+docker overwrites the same tag, so a matrix runs whichever was built last for BOTH legs and
   reports two engines from one image. Must become `…:$(JUMPBOX_OS)-$(JUMPBOX_ENGINE)`. Fix this FIRST.
4. **The CA must be RED-PROVEN load-bearing** (no-CA ⇒ x509 error; +CA ⇒ pass; −CA ⇒ x509 again). Docker
   MERGES `certs.d` with the system store, so a CA that was *already* trusted would let the harness
   publish a "CA method" that was never actually exercised.

Anti-fake assertions per leg: **rootful** — `id -u != 0`, the un-sudo'd write to `/etc/docker/certs.d`
must fail EACCES, and `engine_sudo_calls == 1`. **rootless** — `ps -o user=` on the dockerd PID (the
process owner is ground truth; `SecurityOptions` is derived), `DockerRootDir` under `$HOME`, `DOCKER_HOST`
on the user's own socket, `engine_sudo_calls == 0`. **All** — `docker info {{.Name}}` == the container
hostname, never the host's daemon.

Ubuntu is the hard OS and it is a **bootstrap-policy decision, not a harness detail**: `docker.io` ships
no rootlesskit and hides `dockerd-rootless.sh` in `/usr/share/docker.io/contrib/` (off PATH), so either
add Docker's third-party apt repo + GPG key (a real ask for an air-gapped lab box) or use distro packages
and point at the contrib path explicitly. Photon is the EASY one — `tdnf install docker docker-rootless
rootlesskit` — which inverts the usual assumption and belongs in the doc.

### On the adversaries — they will LOAD; nothing FORCES me to use them

Both `.claude/agents/*.md` are committed, so they are dispatchable from turn one (unlike this session,
where `docker-adversary` was written mid-session and came back `Agent type not found`). The
`subagent-readonly-gate.py` hook is committed and wired, so an adversary that tries to `git commit`/`push`
is blocked — which this repo needed after one of them opened a PR unbidden.

But **RULE ZERO is prose**, and prose has already failed here: it was loaded this session and I still made
unilateral pivots (a dind→host-native switch, a Dockerfile layout, a whole harness) that the adversary then
demolished. By this repo's own doctrine that should become a gate — and **there is no honest gate to
build**: a design decision leaves no artefact to grep at the moment it is made. A `SessionStart` hook
re-injecting RULE ZERO would be decoration (CLAUDE.md already loads it; the failure was skipping the rule
under momentum, not being ignorant of it), and shipping a fake gate is the exact pattern this session spent
itself killing. So this is recorded as an **acknowledged gap**, not a solved problem. The tripwire is the
sentence *"I decided X on my own"* — and the control that actually worked, every time, was the owner asking
*"did you run that past the adversary?"*

### Container engine — SETTLED, and the doc is `docs/decisions/container-engine-support.md`

Measured against the KinD Harbor (login → pull → build → push → `crane validate --remote`):

| engine | CA method | sudo |
|---|---|---|
| **podman** (default) | `--cert-dir`, per command | **no — ever** (daemonless) |
| **docker rootless** | `~/.config/docker/certs.d/<host>/ca.crt` | **no** — matches podman exactly |
| **docker rootful** | `/etc/docker/certs.d/<host>/ca.crt` | **YES, one per registry** — and the KinD LB IP changes every `kind-up`, so a prompt **per cluster** |

Facts people get wrong, all verified here: **`certs.d` MERGES with the system store** (a missing `ca.crt`
does NOT mean docker fails — never gate on the file, gate on a TLS handshake; a guard that did the former
was shipped and retracted). A `certs.d` drop-in needs **no daemon restart** (read per request).
`HARBOR_INSECURE=1` is **podman-only**. `make e2e-kind` needs **docker regardless of `CONTAINER_ENGINE`**
(kind's nodes are docker containers) — so a podman-only box cannot run the local KinD e2e.

**`--security-opt apparmor=rootlesskit`** makes rootless-docker-in-a-container work on an
AppArmor-restricting host (Ubuntu 23.10+). I first wrote *"impossible"* into the decision doc after trying
three flags — **none of which acted on the mechanism I had myself just described.** Ubuntu attaches the
`userns` permission by **host path**; inside a container the binary is a different file, the profile does
not attach, the process is `unconfined` — and `unconfined` is exactly what the kernel denies. Which is why
`apparmor=unconfined` makes it *worse*.

### The 8 e2e permutations (all green, each verified by what the log DID, not its exit code)

`main` clean · **0 open PRs** · 7 PRs merged this session (#213–#218 + follow-ups).

**Every e2e permutation passes, and each was checked against what the log DID, not its exit code:**

| Leg | Proven by |
|---|---|
| `e2e-kind` | CPK CRD mgmt **disabled** · CRDs from the **carried bundle** · **SSA field manager** · all 4 hosts served through the ingress |
| `e2e-kind-istio-existing` | attach mode · 2 demonstrated REDs · foreign selector **discovered** · **both** route APIs |
| `e2e-kind-tenant` | zero k8s RBAC in `ns/argocd`; Applications via `argocd-server` |
| `e2e-kind-cross-cluster` | RED refusal + hub/guest registration |
| `e2e-kind-both` | secure **and** insecure Harbor, each leg reporting its **true mode** |
| `verify-ingress-both` | istio + traefik |
| `jumpbox-both` | **Photon AND Ubuntu**, both `HTTP 200` to Harbor over HTTPS |
| `e2e-sneakernet` | 36 images carried to a fresh box; **36/36 verified intact** on the far side |

### The one thing to internalise from this session

**Every single bug was something that REPORTED SUCCESS WITHOUT DOING THE WORK, with a green gate agreeing.**

- Harbor was **wiped by our own installer**; a surviving Redis descriptor cache HEAD-200'd the missing
  blobs, so `crane` skipped all 36 uploads and **exited 0** (#213). ⚠️ This also **DISPROVED** the
  long-standing "concurrent load corrupts Harbor" rule — see the SETTLED section below.
- The **prose-secret gate could not be reached** by the only PR shape that can add a prose secret
  (docs-only PRs skip `static-check`), and **nine** gates silently skipped when their tool was absent (#214).
- The cross-cluster guard was **dead code** for the documented `.env` setup (#215).
- The **Gateway-API CRD install had never executed** — its acceptance check (`CRDs: PRESENT`) was already
  true before the code existed, because cloud-provider-kind installed them (#216).
- **`grep` in a pipeline under `set -e`** killed scripts **4×** — exit **1** on no-match, exit **2** on a
  **missing file**. Signature every time: **a non-zero exit with NO output** (#217 + follow-ups).
- **One rename (#192) produced four breakages**, each found by a different runtime path (a stale file on
  disk, a live cluster, a second OS). Enumerated lists rot; derive them (#218).

**5 of those were found by RUNNING the e2e matrix, not by writing code.** Six of eight legs were green
immediately; the last two cost five fix rounds. `static-check` was green throughout.

### Still open

1. **The docker-only claim is still unproven** — see the NEXT TASK section below. It is NOT provable with
   `make e2e-kind` (that target requires docker regardless of `CONTAINER_ENGINE`).
2. **The jumpbox Makefile block should be a script.** Every silent failure above happened inside one
   50-line `\`-continued recipe. A recipe cannot be `shellcheck`ed, unit-tested, or coherently
   `set -euo pipefail`'d. Move it to `scripts/` (portfolio rule now in `/makefile`).
3. **Sweep the `.env.kind` → `.env.state` rename once more.** It has produced four breakages; comments
   still claim `kind-down` clears `.env.kind`. Grep the OLD name repo-wide and fix the class.
4. **A real lab.** Everything about the Supervisor topology, the `vcf` CLI auth flow, and whether a VKS
   guest cluster ships the Gateway API CRDs remains **UNVERIFIED** — no amount of KinD green changes that.

---

### Previous handoff (2026-07-13, evening) — container engine

**PR #199 MERGED** (`fix/podman-default`) — all gates green. Note #199 **auto-merged on green between two
pushes**, stranding a commit on the branch — if a PR seems to be missing part of its content, check for
exactly that race.

### What landed in #199

podman is the **DEFAULT** (asserted, not just written), `CONTAINER_ENGINE` is documented in
`.env.example` (**commented** — clobber rule), `check-env-coverage` no longer excludes it **by name**,
and `make test-container-engine` covers **all three** engine choosers (`lib/os.sh`, `Makefile`,
`jumpbox-run.sh`). RED-proven three ways. `docker-adversary` added; RULE ZERO is now a two-adversary rule.

### What was RETRACTED, and why it matters more than what landed

The branch originally added a fail-fast: *docker + no `/etc/docker/certs.d/$HARBOR_URL/ca.crt` → die.*
**Its premise was false.** Docker on Linux **merges `certs.d` with the host system store** (moby
`daemon/pkg/registry/registry.go` → `loadTLSConfig` seeds `RootCAs` from `x509.SystemCertPool()` and
*appends*). An operator who ran `update-ca-certificates` has a **working docker** — the guard would
have hard-blocked them, printing the literal `<HARBOR_CA_FILE>` when unset. **It was itself an
untested docker path**: every e2e auto-detects podman, so it had never once run.

### The engine facts — settled and source-verified; do not re-derive these

| | sudo-free? | how |
|---|---|---|
| podman | **always** | daemonless → CA **per command** (`--cert-dir`) |
| docker, **rootless** | **yes** | daemon reads `~/.config/docker/certs.d/<host>/ca.crt` (moby `CertsDir()`) |
| docker, **rootful** | **no** | `/etc/docker/certs.d/…` or OS store — both root-owned. **No public repo, including VMware's own air-gap tooling, does this without sudo.** |

- **`certs.d` = read PER REQUEST → no daemon restart.** **System store = needs `systemctl restart docker`** (Go caches the pool once per process — `crypto/x509` `sync.Once`; moby/moby#39869). Everyone conflates these.
- Any **`*.crt`** in `certs.d` is loaded as a CA (not just `ca.crt`). A `.cert` without its `.key` is a hard error.
- **`HARBOR_INSECURE=1` is PODMAN-ONLY.** A CA drop-in never enables plain HTTP; docker needs `insecure-registries` + a reload.
- **`DOCKER_CERT_PATH` is NOT a registry CA** (it's CLI↔daemon socket TLS). Podman/skopeo's identically-named `DockerCertPath` **is** one. This is the #1 confusion in the wild.
- **A trusted CA is NOT sufficient — the leaf needs a SAN.** Since Go 1.15 a no-SAN leaf is rejected *even with a trusted CA*, and Go 1.17 **removed** the `GODEBUG=x509ignoreCN=0` escape hatch. For a bare-IP registry it must be an **IP SAN** (goharbor/harbor#19994). **Our KinD Harbor mints `SAN=IP` (`06-install-harbor.sh:118`) — correct, and it must never regress.**

### 📋 PLANNED REVIEW — "mechanism essay" prose in operator docs (repo-wide; a PATTERN, not a one-off)

**The defect.** An operator doc explains **how the internals work** where it should state **the
operator's CHOICE and the ONE COMMAND to run**. It reads as thorough and is actually a burden: the
reader has to *derive* their action from a mechanism description we could have just automated.

**The specimen** (README, container-engine blurb — caught by the owner 2026-07-13). It explained
docker's daemon TLS model, `certs.d` ownership, the OS store, daemon restarts, and rootless — three
sentences of mechanism — and never once told the reader *what to type*. What it should say:

| Your situation | What you run |
|---|---|
| Default (podman) | nothing — `make deps` installs it |
| docker, **rootless** | `make trust-harbor` (sudo-free) |
| docker, **rootful** | `make trust-harbor` → prints the `sudo` lines |
| `make e2e-kind` | docker required regardless — that is kind, not us |

**Why it is a PATTERN and not a typo.** Every hard-won fact in this repo arrives as a *mechanism*
(that is what the adversaries and the research produce), and the reflex is to write the mechanism
down where it was learned — which is usually an operator doc. The knowledge belongs in `CLAUDE.md` /
`docs/decisions/` / `docs/vks-services/`; the **operator** doc gets the choice and the command.
The rule already exists (*docs say WHAT, not WHY*) and it was violated anyway — by me, in the same
session that quoted it. Prose did not hold. That is the signature of a missing gate.

**The review (do this as its own PR, not folded into feature work):**

1. **Audit** every operator-facing surface — `README.md`, `.env.example` comments, `make help`
   strings, `docs/*.md` runbooks — for a paragraph that explains a MECHANISM without naming an
   ACTION. Detection heuristic: a block of ≥2 sentences containing *how/because/so that/it works
   by/the daemon/per-command* and **no** imperative + **no** `make` target.
2. **For each hit, decide**: (a) automate it into a `make` target and reduce the doc to one line
   pointing at the target — **preferred**; (b) move the mechanism to `CLAUDE.md`/`docs/decisions/`
   and leave a choice-table row; (c) it is genuinely a decision the operator must reason about →
   keep it, but lead with the action.
3. **Gate it if a mechanical signal exists** (the repo's standing rule: a violated rule becomes a
   gate, not another paragraph). Candidate: `check-readme-actionable` — every `##` section of the
   README that describes an operator task must contain at least one `make` invocation or a fenced
   command block. RED-prove it by hollowing a section into pure prose. If no honest mechanical
   signal exists, say so and leave it a review checklist item — do NOT ship a gate that passes by
   not looking (this repo has shipped that twice).

**Known first target**: the container-engine blurb above, together with the `make engine-check` /
`make trust-harbor` targets it should point at (designed, adversary-review pending, NOT yet built).

> **These two targets run ON THE JUMP BOX, so they must be proven on BOTH OS images — `make jumpbox-both`
> (`photon:5.0` + `ubuntu:26.04`), not just the dev box.** This is not ceremony; the two OSes differ in
> exactly the places these targets touch:
>
> - **Photon's coreutils are toybox, not GNU.** A `gzip -t` gate already false-failed on it for this
>   reason. **`install -D -m0644` was CHECKED and WORKS on Photon 5 (toybox 0.8.9)** — verified
>   2026-07-13, so the CA-placement command in `.env.example` is safe on both OSes. Do not re-open
>   this; DO keep checking any *new* GNU-ism the same way.
> - **Rootless podman needs different packages per OS** (`crun` + an active `unqualified-search-registries`
>   on Photon; `uidmap`/`passt`/`slirp4netns` on Ubuntu, which apt omits from a default podman install).
> - **Docker may not exist on either image at all** — the jump-box images install **podman only**, which
>   is the whole point. A docker leg needs its own image (see the NEXT TASK below); do not assume the
>   host's docker, and do NOT mount the host docker socket.
> - The uid-1000-vs-1001 asymmetry between the images has already broken CA *readability* once
>   (a 0600 CA the Ubuntu `vks` user could not read → a TLS error that named trust, not permissions).

### ✅ DONE (#205) — every step of `docs/lab-validation-plan.md` now answers Why · Where · Who-needs-it · We-then · Run · Expect · Send-back

The **intro** was fixed (PR #203: five rules up front, the derivation moved behind a `<details>`). The
**24 steps below it were NOT touched** — they are still the pile they were, and they are what the
operator will actually be holding in the lab. Sweep every one of them.

**A validation-plan step has FOUR parts.** (This is the three-part runbook shape plus the part that
makes it a *validation* plan rather than a runbook: the evidence comes back to us.)

| # | Part | Rule |
|---|---|---|
| 1 | **What it's for** | ONE line: which claim does this step settle? Name the claim, not the mechanism. If it settles nothing, **delete the step.** |
| 2 | **What you want the operator to DO** | The literal command(s), copy-pasteable, in order. If it is a vSphere Client click-path, say so — don't dress it up as a command. Mark it `UNVERIFIED-COMMAND` if we have never run it, and give the fallback. |
| 3 | **What you expect them to SEE** (if anything) | The **observable** — the object that appears, the field that goes non-empty, the string in the output. This is what tells them it worked **without asking us**. If a step has no observable, say so explicitly rather than leaving them guessing. |
| 4 | **What they must COLLECT and send back — AND IN WHAT FORM** | The evidence. Be exact: *"the full `vcf context create --help` block, verbatim"* · *"`kubectl -n $ns describe pod <x>` — the **Events** section"* · *"the image tag string"*. **Raw tool output, never their verdict** — we compute the conclusions. Name the file/paste format if it matters. |

**Why part 4 is the whole point:** a step that tells them what to run but not what to bring back
produces a lab trip we cannot learn from. That is the single most expensive failure available here —
the lab is the scarce resource, and we get one pass at it.

**Do this as its own PR**, step by step, and while sweeping:

- **Delete steps that settle nothing.** The plan claims steps 1–14 settle 7 of 8 headline claims —
  check that arithmetic against the actual steps, and cut anything that is just narration.
- **Every `UNVERIFIED-COMMAND` must carry its fallback** (rule 5 of the intro). Grep for the marker and
  confirm each one does.
- **Do not re-inline the mechanism** the intro just moved out — if a step needs a *reason*, it goes in
  the `<details>`, not the step body.
- The same **row test** applies inside a step: a sentence that neither tells them what to do, what to
  see, nor what to send back, is deleted.

### ✅ DONE (#206) — `docs/scenario-1.md` is now 313 lines (was 490), 13 headings (was 2), every step = for/run/expect. Its four bugs (ingress-wrong-for-admin · vcf-before-install · psa-after-mirror · argocd-grep-on-wrong-cluster) are fixed, and scenario-2's mirror-image copies with them

The first instance of the "mechanism essay" review above, and the highest-value one: **Scenario 1 is
the document an admin actually executes on a real lab.** Today it explains, cites, and caveats — and
leaves the operator to assemble the commands. Rewrite it so **every step has exactly three parts**:

| Part | Rule |
|---|---|
| **What it's for** | ONE line. Why this step exists at all. Not how it works internally. |
| **What to run** | The literal command(s). If a step is not runnable (a vSphere Client click-path), say so plainly and give the click-path — do not dress it up as a command. |
| **What to expect** | The **observable** that proves it worked — the object that appears, the field that becomes non-empty, the URL that answers. Not "it should succeed". |

**Do not make the operator type the same value a million times.** Every value that recurs across steps
(`HARBOR_URL`, `HARBOR_CA_FILE`, the Supervisor host, the vSphere Namespace, the cluster name, the
ArgoCD server, the app domain) MUST come from `.env` and be referenced as `$VAR` — never re-typed
literally in step 7 after being typed in step 3. Where a value can be **discovered**, discover it
(`make env-populate` already does this for the cluster-derived ones) and say so instead of asking for it.

**Automate anything typed more than once into a `make` target**, and reduce the doc to that target
plus its expected output. Candidates already visible: the Harbor-CA fetch (`make fetch-harbor-ca`),
the version truth (`make argocd-preflight`), the mesh interrogation (`make istio-preflight`), the PSA
check (`make psa-check`). If a step is a bare `kubectl` incantation the operator would paste twice, it
is a missing target.

**The completion test** (this is what "actionable" means, mechanically): a competent admin who has
never read this repo can execute Scenario 1 top-to-bottom **without opening any other file** and,
after each step, can tell from the printed output whether it worked. If they have to infer a value,
re-type one, or go read a script to know what should have happened — that step is not done.

**Known content bugs to fix in the same pass** (do not paper over them):

- **The Istio/ingress section is wrong for Scenario 1** — it says *"the mesh ALREADY EXISTS here;
  attach to it"*, which is **Scenario 2's** (tenant) situation pasted into the admin path. In
  Scenario 1 the admin provisions the guest cluster themselves; a VKS **Standard Package** is
  *available* in the package repo, **not installed**, so there is no mesh until someone installs it.
  (And per `docs/vks-services/istio.md:24` the ingress gateway is **disabled by default** even then.)
  **Istio is NOT a Supervisor Service** — Harbor/ArgoCD/Contour are; Istio is a **guest-cluster
  Standard Package**. Adversary review of the fix was in flight at handoff; do not ship a
  `vcf package install istio …` command that has not been verified against a primary source.
- Anything else that assumes state a greenfield admin cluster does not have.

### 🚨 ADVERSARY 2026-07-13 (Istio / scenario-1) — the Gateway-API path is a KinD ARTEFACT

**Read this before touching ingress.** Full report in the session transcript; the load-bearing parts:

**BLOCKING — our preferred route API may not exist on a real lab.** **Nothing in this repo installs
the Gateway API CRDs.** On KinD they appear because **cloud-provider-kind auto-installs them**
(`05-kind-up.sh:146` runs CPK with no `--gateway-channel disabled`). Istio does **not** install them
(primary-sourced, istio.io). So on a real VKS guest cluster, if the CRDs are absent:
`istio_detect_route_api` (`lib/istio.sh:132`) finds no accepted `istio` GatewayClass → picks
**classic** → classic needs the **shared ingress gateway** → the VKS Istio package ships that
**`enabled: false`** (primary-sourced) → **`47-attach-istio.sh` dies.**
⇒ `make e2e-kind-istio-existing`'s gateway-api leg is green **because of a KinD-only shim**, and
`docs/vks-services/istio.md:82` markets it as *"works when the shared gateway is OFF: Yes"* on that
green. **That KinD verification does not transfer.** One community blog is the only support for "VKS
ships the CRDs". **Fix:** (a) verify on a lab (`kubectl get crd httproutes.gateway.networking.k8s.io`)
and grade it, and/or (b) install the pinned CRDs ourselves when absent (`kubectl apply --server-side`
— the bundle exceeds the 256 KiB client-side-apply limit). Either way `istio-preflight` must **say**
the CRDs are missing instead of silently degrading to classic. **Side benefit of (b):** it removes an
accidental CPK dependency — a CPK bump adding `--gateway-channel disabled` silently kills the leg.

**HIGH — the runbook argues with its own tool** (my original bug report, corrected). `istio-existing`
does **not** "attach to nothing": `47-attach-istio.sh:66` **dies loudly** — *"no istiod found … Use
INGRESS_CONTROLLER=istio to INSTALL Istio instead"* — and `48-istio-preflight.sh:38` already prints
*"NO Istio detected → INSTALL it"* and exits 0. The **tools are right; the doc contradicts them**:
`scenario-1.md:432` tells you to run the preflight, and `:433` tells you to do the opposite of what it
says. Not silent breakage — a wasted cycle and a false mental model. **Scenario 2 has the identical
paragraph** (`scenario-2.md:315`), where the conclusion is *plausible* but still **asserted, not
measured** — lead with the preflight there too.

**The fix (adversary's recommendation): default Scenario 1 to `make install-ingress`** (our helm Istio),
because: images already come from **our Harbor** (`global.hub`, `46:47,73` + `images.txt:56-60`); it
needs **no Gateway API CRDs** (classic path, installs its own gateway with a pinned
`labels.istio=ingressgateway`); **PSA handled** (`46:93` labels `istio-system`/`istio-ingress`
`baseline`); no mesh to conflict with (you own the cluster). **Two caveats that MUST be written down,
not hidden:** it `helm repo add`s from `istio-release.storage.googleapis.com` — **fine dual-homed,
breaks a true sneakernet install**; and it is **not the Broadcom-supported mesh**.

**The VKS add-on path stays a documented ALTERNATIVE, ungraded above `9.0-doc-inferred-for-9.1`** —
and do NOT ship it as one line:

- The `vcf package` sequence is **incomplete**: it needs `vcf package repository add` first (Broadcom:
  *"required only when using the legacy package management system"*) and the values file comes from
  `vcf package available get … --default-values-file-output`.
- **9.1 forked the CLI**: "Standard Package" → **VKS Add-ons** (`vcf addon install create …`).
- **LANDMINE:** `-n` is a **guest-cluster namespace** in `vcf package`, but the **vSphere Namespace of
  the workload cluster** in `vcf addon`. **Opposite meanings, same flag.** Never copy it across.
- **UNVERIFIED and load-bearing:** on an air-gapped cluster the add-on's **own** istiod/proxy images
  come from Broadcom's registry, which the guest cannot reach. We neither mirror nor repoint them.

**Also from the same report, not yet fixed** (ordering bugs in the admin runbook):

- **G5 (real):** `scenario-1.md:357` greps for `argocd-application-controller` while `$KUBECONFIG` is
  the **guest** cluster — but ArgoCD is a **Supervisor Service**, so it is not there. It finds nothing
  and teaches the operator the topology is flat. Same bug in `scenario-2.md:253`. This is the exact
  Supervisor-vs-guest confusion a prior session spent itself killing.
- **G3:** A2 tells the operator to run `vcf context create` (`:114`) ~180 lines **before**
  `make install-vcf-clis` (`:291`) installs `vcf`. Fresh jump box → `vcf: command not found`.
- **G1:** `make psa-check` is instructed at Step 8, *after* Step 7 already mirrored for 20 minutes —
  its own note says "before you spend 20 minutes mirroring". Move it to Step 3.
- **G2:** the whole ingress decision is buried inside "Step 8 — access the UIs". An install step hidden
  in an access section is *how this bug survived*. Promote it to its own step.

**What survived the attack:** the Supervisor/guest split (Istio is **not** a Supervisor Service — the
TMM catalog lists Harbor/Contour/ArgoCD, not Istio); "Istio has no credentials"; the
selector-is-the-helm-release-name discovery via port 15021; `44-install-ingress.sh:16` genuinely
surviving the `.env.example` clobber; and the ingress-gateway-off-by-default fact (primary-sourced).

### ✅ PROVEN (#216) — the Gateway-API CRD install now actually RUNS. The plan that "verified" it was the trap

The acceptance list that used to sit here was **unsatisfiable**, and following it would have produced a
confident **FALSE PROOF**. Keeping the story because the shape of the error is the lesson.

`istio_ensure_gwapi_crds` **early-returns** when the CRDs are already present — and
**cloud-provider-kind force-installed them at cluster start** (its `--gateway-channel` defaults to
`standard`), long before Istio is ever installed. So the `kubectl apply --server-side` line had
**never executed on any machine**. The old acceptance list asked for `istio-preflight` to print
`Gateway API CRDs: PRESENT` — which was **already true before the code was written**. It measured the
KinD shim that the install exists to *remove*.

**The lesson, generalised: "the thing is present" is not "our code put it there."** When the whole
claim is *we install X*, the assertion must distinguish **our** X from **anyone else's** X.

**What now enforces it:**

- `05-kind-up.sh` runs CPK with **`--gateway-channel=disabled`** (source-verified safe: CRD install is
  a separate gated path from the Service-LoadBalancer controller), and then **asserts CPK logged that
  it skipped the CRD install** and has **zero crash lines** — counting log lines, not trusting
  `docker ps`, because `--restart unless-stopped` shows `Up` between crash-loop cycles.
- `istio_ensure_gwapi_crds` asserts a **server-side-apply field manager** on the installed CRD. CPK
  creates with a plain dynamic `Create()` → `operation: Update`; a server-side apply →
  `operation: Apply`. **That signature cannot be forged by presence**, and it simultaneously proves
  `--server-side` was genuinely used. It also asserts the `bundle-version` annotation equals our pin.
- The **air-gap branch was dead code** (`MANIFEST_DIR` is a local in two *other* scripts and was never
  set on this path, so `make install-ingress` always reached for github.com — on an air-gapped box it
  died *before* the helm fetch the runbook warns about). It now reads the carried bundle, and **dies
  with a useful message** if the bundle exists but predates the CRDs, rather than silently reaching
  for the internet.
- The **attach e2e's "platform team" fixture now installs the CRDs** — which is both what makes the
  test pass with CPK's channel off, and *more faithful*: cluster-scoped CRDs belong to the mesh admin,
  never the tenant. It also asserts they are **ABSENT first**, which is the honest tenant starting state.

**PROVEN on a fresh cluster (e2e-kind, rc=0):**
`cloud-provider-kind: Gateway API CRD management is DISABLED (we install them ourselves), 0 crash lines`
· `installing Gateway API CRDs v1.5.1 from the carried bundle (air-gap)` — **the air-gap branch executed
for the first time in this repo's life**; it was dead code (`MANIFEST_DIR` was never set on this path), so
it had ALWAYS fetched from github.com, and the mirror had been faithfully downloading a file nothing read
· `established (bundle-version=v1.5.1, SSA field manager: kubectl)` — the assertion **presence could never
make**. And `make e2e-kind-istio-existing` still passes, because the platform-team fixture now installs the
CRDs (which is also more faithful: cluster-scoped CRDs are the mesh admin's, never the tenant's).

**Renovate is grouped** (`istio + gateway-api (version-locked)`) so a bot cannot move the CRD version
alone. Note this is now doubly load-bearing: gateway-api **v1.6**'s bundle ships a
`ValidatingAdmissionPolicy` denying CRDs older than v1.5.0, and CPK v0.11.1 vendors **v1.5.1** — so if
CPK's channel were ever re-enabled *and* the pin moved to v1.6, CPK's CRD install would be **denied**,
it would abort its whole controller, and **every LoadBalancer would silently stop getting an IP**.

### ✅ DONE (#214) — the gate-misplacement audit. It found a CRITICAL, and the suspicion was right

The suspicion below was correct, and worse than feared. **`prose-secrets` — the gate that exists to catch
credentials written in PROSE in `*.md`, the class gitleaks provably misses — lived only in `static-check`,
which CI skips on a docs-only PR. A docs-only PR is the ONLY shape that can add prose to a runbook.**
100% evasion. Proven: a planted ``admin / <22-char random>`` in a `.md` fails `check-prose-secrets.sh`
(rc=1) while `make docs-lint` — the only gate CI ran for that PR — exits **0**, and `make secrets` says
"no leaks found" (gitleaks misses prose, which is the whole point).

Fixed: a CI `secrets` job with **no `if:` at all** (every path is code or docs, so `code || docs` is a
tautology — the security gate is now immune to a future classifier bug). Plus three more from the same
audit: `gitleaks detect` scans **git history, not the working tree** (CI worked only by ACCIDENT — the
shallow checkout; `fetch-depth: 0` would have disarmed it); **nine** gates silently skipped when their
tool was missing (now: warn locally, **DIE in CI**); and `check-doc-make-targets`, because the doc gates
demanded `make X` commands they never checked existed.

The original note, kept because the reasoning generalises:

**Suspects:** `check-readme-scenarios`, `check-how-provenance`, `check-doc-command-count` (docs gates —
confirm they are in `docs-lint`, not `static-check`) · `check-env-coverage` / `check-env-clobber` (they
guard `.env.example` **and** scripts — which filter fires?).

### ⛔ NEXT TASK — prove the docker-only claim, and DO NOT do it with `make e2e-kind`

The owner wants: *"we use podman by default; prove the e2e ALSO works with docker only, then claim it in `*.md`."*

**`make e2e-kind CONTAINER_ENGINE=docker` CANNOT prove that. It is circular** — `make e2e-kind`
hard-requires docker regardless of `CONTAINER_ENGINE` (kind node containers, `docker exec`,
cloud-provider-kind on the docker socket). It would prove *"docker works on the one box that is
required to have docker."* It also **cannot currently go green**: nothing wires the Harbor CA into the
**host docker daemon** (`06-install-harbor.sh` wires the kind nodes' *containerd*, a different
format/consumer; podman gets `--cert-dir`). And the CA is minted with **SAN = the LB IP**, which
changes on every `kind-up` — so any manual `sudo` fix is non-reproducible.

**The converse gap is real and currently unstated: the PODMAN claim is ALSO unproven for the disputed
step.** `make jumpbox` is our only docker-free environment (its Photon/Ubuntu images install podman
only) — but it **never calls `15-build-push-builder.sh`**, the one script that builds *and pushes to
Harbor over self-signed TLS with an engine*. Everything it does run is **crane** (no engine at all).

**The honest harness** (this is the task):

1. Extend `jumpbox-run.sh` to actually run `make builder-image` (+ a Harbor pull) — for **both** engines. Without this, neither claim is tested.
2. Add a docker-capable jump-box image (`Dockerfile.ubuntu-docker`, dind — the harness already runs `--privileged`). **Do NOT mount the host docker socket**: that puts you back on the host daemon (which has kind's containers), so the "docker-only jump box" would be running against the very box it is supposed to be independent of — it proves nothing. (The old second reason given here — "it re-opens the concurrent-registry-mutation hazard that has already corrupted a Harbor" — was based on a **misdiagnosis**; see the SETTLED Harbor section. The first reason is the real one and is sufficient.)
3. Install the CA **the way a real operator would**, per engine, *inside* the container, and record which method was needed. Root-inside-a-container is what makes the sudo question **honest** rather than hidden.
4. Replace the fail-fast with a **pre-build `$ENGINE login` probe** (before the `pull` at `15:~65`, not after a 20-minute build). It tests whether trust *works* instead of guessing from a filename, cannot false-fire, and needs no knowledge of where the daemon reads certs.

5. **Run the matrix on BOTH OSes, not just the dev box: `make jumpbox-both` (`photon:5.0` + `ubuntu:26.04`) × both engines.** The engine/CA code paths are exactly where the two OSes diverge (toybox vs GNU `install -D`; `crun` + `unqualified-search-registries` on Photon vs `uidmap`/`passt`/`slirp4netns` on Ubuntu; the uid-1000-vs-1001 CA-readability trap). A green Ubuntu-only run has already been mistaken for a proof in this repo. The full grid is **4 legs** — {photon, ubuntu} × {podman, docker} — and the docker legs need the dind image from (2), because the stock jump-box images install **podman only**.

**Only then** publish the claim — and publish it with its preconditions (rootful⇒sudo; system-store counts; rootless is sudo-free; insecure mode is podman-only; kind ≠ jump box). "Docker works" unqualified would be a lie.

### 🩸 PROCESS FAILURE THIS SESSION — fix this before running another adversary

**Two agents mutated the repo despite `READ-ONLY` in their prompts.** One reverted
`scripts/15-build-push-builder.sh` to `HEAD` (destroying uncommitted work); another **committed,
pushed, and opened PR #199** unbidden. Cause: `vks-adversary` has `Bash` (so `git checkout`/`commit`
are reachable) and an inlined persona ran as `general-purpose` (**all** tools, incl. `Write`).
**A prompt is not a sandbox.** Run adversaries with **`isolation: "worktree"`** so they physically
cannot reach the main tree. Nothing was lost only because the destroyed file held the guard that was
being retracted anyway — that is luck, not a control.

## 🔴 SETTLED 2026-07-13 — Harbor's "blob-store corruption" was NEVER concurrency — it was US

**Do not re-derive this, and do not re-blame concurrency.** Root-caused from the box (disk contents,
Redis dbsize, a hand-reproduced blob GET), fixed, and empirically proven.

The registry's blob store was an **emptyDir** (`persistence.enabled=false`), and `install-harbor`
**helm-upgraded unconditionally twice per run** — phase 1 downgrading a TLS-enabled Harbor back to
TLS-off, phase 2 re-enabling it. Each upgrade **rolled the registry pod and destroyed the whole
mirror**. That alone would have been loud.

What made it **silent**: `harbor-redis` is a **different pod** and does not roll, and the registry
caches blob **descriptors** there (`cm/harbor-registry`: `cache.layerinfo: redis`, `db: 2`). After the
wipe the cache still answered `HEAD /v2/<repo>/blobs/<digest>` with **200** — so `crane`,
*spec-correctly*, read that as "already present", **skipped every upload**, printed `existing blob:`
and exited **0**. `make mirror` reported 36/36 pushed. On disk: **153 manifest links, ZERO blobs**; a
blob GET returned `200 OK` + the right `Content-Length` + **zero bytes of body**. `mirror-verify` was
the only thing in the repo that ever saw it.

**Why the concurrency story survived so long:** it predicts every symptom (HEAD-200 blobs that aren't
stored, `MANIFEST_UNKNOWN`/`BLOB_UNKNOWN` in Kaniko, a re-push that "succeeds" and changes nothing),
and its prescribed cure — a clean `kind-down && e2e-kind` — genuinely works, **because it destroys
Redis**, not because it avoids concurrency. Two tells refute it: the failure took out **36 of 36**
images (a *wipe*; a write race damages *some*), and the failing run had **no concurrent load at all**.
**Reflex: before accepting "it's a race", check whether it is DETERMINISTIC.** A race that reproduces
100% of the time on a warm cluster is not a race.

**The fix** (`scripts/06-install-harbor.sh`, `Makefile`, `scripts/15-build-push-builder.sh`):

- `persistence.enabled=true` — the blob store gets a **PVC** (KinD's default `standard` SC, already
  used by `ci`/`gitea`), so it outlives the pod and the cache cannot describe a store that is gone.
- phase 1 runs **only on a first install** — no more TLS-off downgrade, no more double registry roll.
- phase 2 applies the **full desired values**, not `--reuse-values`, which had made the TLS mode
  **sticky** (an insecure re-install of a secure Harbor set `externalURL=http://` but left TLS **on**).
- the registry's Redis descriptor cache is **flushed** after an upgrade; the DB index is **read from
  `cm/harbor-registry`**, never guessed (flushing the wrong DB would silently clear someone else's keys).
- **`make mirror` now depends on `mirror-verify`.** A push you have not verified is not a mirror:
  `crane` establishes blob existence with a **HEAD**, so a lying registry makes the push a no-op.
- `15-build-push-builder.sh` no longer **silently falls back to the public Docker Hub base** when the
  mirrored one won't pull. On a dual-homed box that turns a broken mirror into a **green build** that
  proves nothing about the air gap — it would have masked exactly this bug. It is now a hard failure
  unless you ask for it by name (`ALLOW_PUBLIC_BASE=1`).

**PROVEN:** cold cluster → `make mirror` green → `kubectl -n harbor rollout restart deploy/harbor-registry`
with **zero concurrent load** → `make mirror-verify` still reports **36/36 intact**. Before the fix,
that same restart destroyed everything.

**Still run the e2es serially** — not because of blob corruption, but because they mutate a shared
cluster + registry and parallel work makes a failure unattributable.

## Verification honesty

Offline-verifiable (no cluster): app tests, manifest/Tekton YAML validation, script
lint, Makefile targets, mirror pull mechanics. The **air-gap end-to-end runs on the
live VKS cluster** (`make verify`) and is the demo itself — do not report it
"verified" without running it against real infrastructure.

**CI runs only the offline gates** (`static-check` + `docs-lint`); the KinD end-to-end
(`make e2e-kind`, which now includes `verify-ingress`) is deliberately **local-only**.
A full-stack KinD e2e in GitHub Actions (Harbor via helm + cloud-provider-kind LB +
ArgoCD + Gitea + Tekton + offline builder + pipeline + ingress) is heavy and flaky, and
the real demo is the live VKS run — so the KinD e2e stays a local `make` target rather
than a CI job. Run it locally (and both ingress controllers via `make verify-ingress-both`)
when changing the pipeline, ingress, or manifests.

## ✅ ADVERSARY FINDINGS 2026-07-12 — ALL CLOSED (2026-07-13)

All 8 findings from the first adversary run are fixed and merged. The two CRITICALs that made the
REAL LAB impossible are closed **and** covered by a regression test that would have caught them
(`make e2e-kind-cross-cluster`, which now actually calls `70-configure-argocd.sh`).

| # | What | Where |
|---|---|---|
| #1 | `make gitops` targeted the WRONG CLUSTER | #153 (+ #158, #160) |
| #2 | the Application's `repoURL` was guest-internal DNS | #153 — Gitea got its OWN LoadBalancer |
| #3 | the ATTACH-mode e2e was dead code | #146 |
| #4 | `project: default` hardcoded, not overridable | #153 — `ARGOCD_PROJECT` |
| #5 | private Harbor: NO `imagePullSecret` anywhere | #153 — `harbor-pull` per app namespace + an alignment gate |
| #6 | app namespaces got PSA labels only from the ingress step | #153 — `70` labels them at creation |
| #7 | the "ONE ROW" gate couldn't see the 2nd edit | #151 — the host is DERIVED |
| #8 | token in argv · language knowledge in a shared task | #150, #153 |

### What the ADVERSARY caught that a review would not have

It ran **6 times** and **overturned every design brought to it** — including CRITICALs inside the
session's OWN fixes, an hour old:

- **`.items[0]`** as a deploy destination: on a SHARED (real-lab) ArgoCD that is an **arbitrary
  cluster**, and the Application carries `prune+selfHeal` — it could have deployed a tenant's app
  **into another tenant's cluster** (#158).
- The fix to *that* read the cluster name from **`metadata.name`**, but ArgoCD keeps it in
  **`data.name`** — so the tiebreak **could never match** (#160). KinD cannot show either (one
  cluster ⇒ `items[0]` is always right).
- **`make kind-down` deleted a REAL LAB's kubeconfig and Gitea token** — it keyed on *"is it under
  `./secrets`"*, and the documented lab default **is** `./secrets/vks.kubeconfig`. Both runbooks told
  the operator to run it at Step 0 (#167).
- **`make X KUBECONFIG=/other` was a SILENT NO-OP** — `.env.example` outranked the environment, so
  you ran against the default cluster believing you had switched. It also made the two-cluster test
  *undrivable* (#168).
- My Harbor fallback endpoint would have shipped a 404 handler (#161). **Right conclusion, WRONG
  REASON — corrected 2026-07-13.** I wrote "removed in 2.13". It was **not removed**:
  `/api/v2.0/systeminfo/getcert` is present in `api/v2.0/swagger.yaml` at **v2.13.0 and `main`**, with
  a live handler (`sysInfoAPI.GetCert` → `ctl.GetCA`). What is actually true is that it returns *"No
  certificate found"* when Harbor holds no CA at its core path — the normal case with
  ingress/cert-manager-terminated TLS (goharbor/harbor#6603, #18912). A wrong reason is what misleads
  the next reader, so do not "fix" this by re-adding the endpoint: it exists, and it will still be
  empty for us.
- `kubectl auth can-i` measured **the one axis a tenant is expected to fail**: ArgoCD's
  `applications`/`repositories` are **project-scoped**, so the tenant's real path is **argocd-server**
  (#163).

### …and 3 more at the very end, from the STOPPING-RULE run (#174)

The session-end adversary (RULE ZERO, trigger 3) returned **NOT DONE** on the session's own work.
All three confirmed by hand; **none is reproducible on KinD**, which is why they survived a green e2e:

- **`make install-all` died at its own `preflight`** on every real-lab first run. Preflight blocked on
  `GITEA_ARGOCD_URL` — a value `40-install-gitea.sh` only DISCOVERS *later*, inside `make platform`,
  which runs **after** preflight. The one command both runbooks tell the operator to run failed
  **before the mirror**. → warn when unset; still block when it *is* set to something cluster-local.
- **`ARGOCD_SERVER` was uncommented in `.env.example`** → `set -a` clobbered every override, and **the
  tenant e2e passed only on this box's `/etc/hosts`**. See the handoff's red block.
- **`05-kind-up.sh` wrote `kind get kubeconfig` into the CALLER's `$KUBECONFIG`**, which `kind-down`
  then deletes → a developer with `export KUBECONFIG=~/.kube/config` lost it. The `.env.example` pin
  was an **accidental shield**, not a design; it came off when `load_env` began honouring the caller's
  `KUBECONFIG` (#168). Latent for the repo's whole life. → the flow now owns `secrets/kind.kubeconfig`.

### The mechanism ladder (#163) — the tenant path is IMPLEMENTED, not yet PROVEN

`ARGOCD_MECHANISM=auto|kubectl|api|request`. `make e2e-kind-tenant` exits 0 — a kubeconfig with **ZERO
Kubernetes RBAC** in the ArgoCD namespace creates both Applications through **argocd-server** using
only an AppProject role. **But that green is not yet trustworthy**: it depended on `ARGOCD_SERVER`
being resolvable via this box's `/etc/hosts` (see #174 above). Re-run it on clean machine state before
citing it.

### STILL OPEN

- **`GITEA_ARGOCD_URL` is PUBLISHED by `40-install-gitea.sh` and READ BACK as an input by `70`** — the
  publish-then-read-back anti-pattern (a stale value is indistinguishable from a deliberate override).
  DERIVE it from the live Gitea Service instead, with a `GITEA_ARGOCD_URL_OVERRIDE` for the operator
  (precedent: `INGRESS_LB_IP_OVERRIDE`).
- **`.env.kind` still carries REAL-LAB discovered state** despite its KinD name. The sink is hardcoded
  in `lib/os.sh` (`load_env` + `set_env_var`). Make it a variable; consider stamping it with the
  cluster it was written for and refusing to source it against a different one.
- **UNVERIFIED (needs a lab):** may a VKS *tenant* `kubectl` into the ArgoCD instance's namespace at
  all? The `api` mechanism makes this matter far less — but `70` still MEASURES it rather than
  assuming, and prints what to request when refused.

## Naming history

**`webui` was renamed to `javawebapp`** (2026-07-12) when a second app (`gowebapp`) arrived — the
name had to say WHICH app. The rename covered the source tree (`apps/java/javawebapp`, Java package
`com.vmware.vks.demo.javawebapp`), the Gitea repos (`javawebapp-app` / `javawebapp-deploy`), the
Harbor path (`apps/javawebapp`), the Tekton objects, the deploy dir (`deploy/javawebapp`) and the
ingress host (`javawebapp.vks.local`). **The dated handoff entries below still say `webui`** — that
is what those PRs actually touched, and rewriting them would falsify the record.

## Backlog / resume state

### HANDOFF 2026-07-13 (late) — superseded by the CONTAINER ENGINE handoff above; kept for the e2e-green record

`main` GREEN, **0 open PRs**, ~33 merged this session. **Every e2e path in the repo is green on
current code** — and that is the headline, because `static-check` cannot see any of what they catch:

| | |
|---|---|
| `make e2e-kind` | EXIT=0 — both apps' markers live, all UIs routed |
| `make e2e-kind-tenant` | EXIT=0 — ZERO k8s RBAC in ns/argocd; Applications created via **argocd-server**, against the **LB IP** (it now ASSERTS the override survives `load_env`, so the green no longer depends on `/etc/hosts`) |
| `make e2e-kind-cross-cluster` | EXIT=0 — RED refusal + hub/guest registration + a revision actually fetched |
| `make e2e-kind-istio-existing` | EXIT=0 — **2 demonstrated REDs**; DISCOVERED the platform's `istio=platform-gw` selector from the live cluster; **both** route APIs |
| `make e2e-sneakernet` | EXIT=0 — 36/36 images intact after an 11 GB carry to a fresh **PhotonOS** jumpbox; no host-state leakage |
| `make e2e-kind-both` | EXIT=0 — secure + insecure, **each leg reporting its true mode** |
| `make verify-ingress-both` | EXIT=0 — istio **and** traefik |

### The state overlay was redesigned (#192) — read this before touching `load_env`

`.env.kind` is GONE. It was a KinD-named file carrying REAL-LAB state that `make kind-down` deletes —
and both runbooks tell the operator to run `kind-down` at Step 0. The sink is now **`.env.state`**
(`VKS_STATE_FILE`), **STAMPED** with the cluster that wrote it.

**The adversary killed the backlog's own instruction.** It said "STAMP it and REFUSE to source it
against a different cluster". Refusing is WRONG: the sink holds the ONLY copy of the generated
passwords, and the air-gap jumpbox has no cluster to stamp against. The polarity is INVERTED:

- **UNSTAMPED** → source it, warn.
- **MISMATCHED** → **ARCHIVE it (rename), never `rm`** — it may hold a *live* cluster's only credentials.
- `kind-down` deletes it **only** if the KinD flow stamped it (`VKS_STATE_KIND=1`). **Proven live.**
- `set_env_var` **has no default sink** — the line that stops the class regrowing. Use `state_set`.
- `make state-show` says WHOSE the file is, whether kind-down may touch it, and its contents (redacted).

It also killed two designs that sounded right: *"two sinks split by key lifetime"* (**lifetime is a
property of the CLUSTER, not the key**) and *"derive everything"* (it would **silently MINT a random
`HARBOR_PASSWORD` on a real lab**, where Harbor is a Supervisor Service whose credential we CONSUME).

### NEXT

1. **A real lab.** Everything below is gated and reasoned but **NOT RUN**: the Supervisor topology, the
   `vcf` CLI auth flow (`30-vks-login.sh`), and whether a tenant may `kubectl` into the ArgoCD
   namespace at all. No amount of KinD green changes that.
2. `INGRESS_LB_IP` is still published and read back by `98-verify-ingress.sh` (the
   `INGRESS_LB_IP_OVERRIDE` exists for it). An `ingress_lb_ip()` resolver would close the last one.

### ✅ CLOSED this session (verified against the tree, not remembered)

The 8 original adversary findings · **7 more CRITICALs the adversary found in my own fixes** · the
user-journey audit (9 findings) · the terminology sweep (a **phantom Broadcom noun** that pointed
operators at the wrong console; **Contour documented on the wrong cluster**; **both scenarios' network-reach
prereqs unrunnable as written**) · `check-env-clobber`'s env-prefix blindness (which was hiding a LIVE
clobber) · the `.env.kind` redesign · Gitea 1.27 (Renovate moved the inventory, not the consumer).

**The through-line: nearly every real bug was one shape — something checked that a value was PRESENT
instead of whether it WORKS.** A token file. A `.env` password. A published URL. A mirrored tag. That
class is now gated in six places, each with a demonstrated RED.

### 🪤 Traps that bit ME this session (beyond the ones already listed below)

- **NEVER background a git command that mutates the working tree.** A backgrounded merge loop ending
  in `git checkout main && git reset --hard origin/main` fired **mid-edit** and wiped three verified
  CRITICAL fixes — **three separate times**, once immediately after promising not to. Worse than the
  wipe: `make static-check` then went **green on the reverted tree**, and I briefly believed it. Only
  `git diff main --stat` (empty) told the truth. A background job may only **READ**; merge + sync are
  foreground, when you are the sole writer of the tree. (Now a rule in `common/git-workflow.md`.)
- **A grep-gate must strip comments before it looks** — `test-kind-down-safety` failed on its own
  first run by matching the comment that *explains* it. Second occurrence this session
  (`check-java-alignment` did the same). `sed 's/#.*//'` first.
- **Never answer "is this claim true?" by quoting the artifact that makes the claim.** Asked whether
  the walkthrough applied to all three scenarios, I quoted the doc's own intro — then opened a PR on
  that unverified premise. The code said otherwise (URLs derive from `APP_DOMAIN`; Harbor and ArgoCD
  deliberately sit **outside** the ingress).

### UNVERIFIED — needs a real lab, not reproducible on KinD

- May a VKS **tenant** `kubectl` into the ArgoCD instance's namespace at all? The **`api`** mechanism
  makes this matter far less (it needs no k8s RBAC there), and `70` MEASURES it rather than assuming.
- Can the **Supervisor route to a guest LoadBalancer VIP**? That is what `GITEA_ARGOCD_URL` depends on.
- The `vcf` CLI auth flow (`30-vks-login.sh`) ships the verified SHAPE but has never run on a lab.
