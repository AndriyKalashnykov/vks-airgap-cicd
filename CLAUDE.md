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
- **Container engine split:** `CONTAINER_ENGINE` (podman-preferred, docker fallback)
  drives image ops — mirror, builder image, diagrams. The **KinD local e2e path
  requires Docker**: `05-kind-up.sh` (`require_cmd docker`) + cloud-provider-kind use
  the `kind` Docker network/socket, so node interactions (`crictl` via
  `docker exec <node>`) use Docker even in this podman-default repo.
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

## ▶️ HANDOFF 2026-07-13 (evening) — CONTAINER ENGINE — START HERE

**PR #199 MERGED** (`fix/podman-default`) — all gates green. **PR #201 open** (this handoff + the
subagent read-only gate). Note #199 **auto-merged on green between two pushes**, stranding a commit
on the branch — if a PR seems to be missing part of its content, check for exactly that race.

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

### 📋 PLANNED — make `docs/scenario-1.md` ACTIONABLE (it is the admin runbook; it currently reads like a paper)

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
2. Add a docker-capable jump-box image (`Dockerfile.ubuntu-docker`, dind — the harness already runs `--privileged`). **Do NOT mount the host docker socket**: that puts you back on the host daemon (which has kind's containers) and proves nothing, and it re-opens the concurrent-registry-mutation hazard that has already corrupted a Harbor here.
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
