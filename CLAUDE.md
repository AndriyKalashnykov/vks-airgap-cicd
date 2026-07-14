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

**Trigger 2 IS NOW A HOOK, because prose did not hold — it was skipped on 2026-07-14 by the very
session that had just re-read it.** `.claude/hooks/adversary-first-gate.py` (wired in
`.claude/settings.json`) **BLOCKS `Edit`/`Write` to `scripts/`, `Makefile`, `jumpbox/`, `k8s/`,
`tekton/`, `apps/` until an adversary has been spawned in this session.** `docs/`, `CLAUDE.md` and
`.env.example` are deliberately NOT gated — that is where you write the plan down first. Escape hatch,
on the record: `ADVERSARY_GATE_OFF=1`. RED/GREEN-proven 11 ways.

Its sibling, `subagent-readonly-gate.py`, shipped with a HOLE it took a real incident to find: it
matched **`Bash` only**, so it blocked a subagent's `git push` and happily let it **rewrite the tree
with `Edit`/`Write`** — which is exactly how two READ-ONLY-briefed adversaries edited five files on
2026-07-14, one of them *while the main agent was executing the script*. It now blocks subagent writes
outright. **A sandbox with a door in it is worse than none: it manufactures confidence.**

### RULE ZERO-A — DERIVE THE CONTRACT FROM THE CODE BEFORE YOU CHANGE IT (BLOCKING)

Before writing code that changes **what one side must provide to another** — the air gap, a wire
format, an API, "what the other machine needs" — the FIRST deliverable is the **contract, enumerated
from the code**. Not recalled. Not reasoned. **Grepped.**

```text
what does the far side actually RUN?        (bundle-load, mirror-push, mirror-verify, platform,
                                             gitops, install-ingress, verify)
  ↓ for each, what does it INVOKE?          (grep: binaries; `helm repo add`; https:// fetches;
                                             awk/envsubst/git/openssl; a container engine)
  ↓ for each, mark it:                       CARRIED | PROVISIONED | *** MISSING ***
  ↓ PRINT THE DENOMINATOR                    ("scanned N scripts") — a gate that cannot tell you
                                             what it looked at cannot be trusted to have looked

```

**A list you wrote from memory is not the contract; a grep is.** Ten minutes of this, once, up front,
would have produced *in a single pass* every bug the 2026-07-14 session instead found one at a time
across six round-trips, each looking like a fresh surprise:

| found the hard way | the grep that would have shown it |
|---|---|
| bundle carried `helm` (62 MB) and **ZERO CHARTS** → the DEFAULT ingress could never install | `grep 'helm repo add' scripts/` on the air-gap path |
| `awk` is **not on bare Photon**, and `lib/apps.sh` + `mirror-verify` need it | `grep -w awk scripts/` × what the bare image actually ships |
| `envsubst`/`gawk` missing from `00-install-prereqs.sh` — the box `make deps` BUILDS | diff "what check-tools calls required" vs "what the bootstrap installs" |
| a no-internet box retried **>2 min** then blamed googleapis; and `require_cmd crane` told an air-gapped operator to run a script that **downloads from the internet** | `grep -n 'https\?://'` on every step `install-all` runs |

The tell that you skipped it: you are fixing the SECOND instance of a class you already fixed once.

**🔴 SPAWN EVERY ADVERSARY WITH `isolation: "worktree"`. MANDATORY. NOT NEGOTIABLE.**
A subagent's Bash runs in **your working directory**. Git's current branch is a fact about `.git/HEAD`
**on disk**, not a per-process property — so when an agent runs `git checkout -b`, **you are now on its
branch**, and every commit you make afterwards lands there. That is not a hypothetical: on 2026-07-14 an
adversary did exactly that at **14:40:11**, and the next ~7 commits (mine) went to *its* branch while I
believed I was on `gate/doc-target-coverage`. It had already rewritten five files and opened a PR.
A worktree gives it its own checkout: it **physically cannot** touch your tree or your `HEAD`.
(It does NOT stop a `push` — same remote, same creds — so it is a complement to the read-only hook, not a
replacement. And **the hook itself is currently UNVERIFIED against a real subagent** — see the red section
below before you rely on it.)

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
  `00-install-prereqs.sh`. The **bundle carries `crane`** (the mirror engine) — and *only* crane, which
  is all the mirror half needs (`bundle-load` → `mirror-push` → `mirror-verify`). It used to carry
  **nothing**, while this line claimed otherwise; the e2e hid that by letting its "air-gap" box run
  `make deps` over the internet. A **full** air-gapped install additionally needs `kubectl`/`helm`/`jq`/
  `envsubst` pre-provisioned on the inside box — see [`docs/sneakernet.md`](docs/sneakernet.md).
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

## 🔴 UNVERIFIED CONTROL — THE READ-ONLY HOOK MAY BE BLIND TO SUBAGENTS. TEST IT FIRST. (2026-07-14)

**Do not trust `subagent-readonly-gate.py` until you have run the test below. It has never been proven to
block a real subagent — only to block a JSON payload I hand-fed it.**

### What is PROVEN

| | |
|---|---|
| the hook's LOGIC | ✅ fed a subagent-shaped payload (`agent_type` set + `git commit`), it returns **rc=2, blocked**. 17/17 assertions. |
| the hook is WIRED AND FIRING | ✅ instrumented it to log every invocation, ran a Bash call: `FIRED tool=Bash agent_id=None agent_type=None`. It runs. |
| **a subagent is actually BLOCKED by it** | ❌ **NEVER TESTED.** And the evidence says it is not: on 2026-07-14 at **14:40:11** a subagent ran `git checkout -b`, `git commit`, `git push` and `gh pr create` — **while this hook was wired for `Bash`** (`git reflog` has the proof). |

### The suspected defect — a FAIL-OPEN in our own gate

```python
if not (data.get("agent_id") or data.get("agent_type")):
    return 0                      # "must be the main agent — allow"

```

**If the harness does NOT populate `agent_id`/`agent_type` in the PreToolUse payload for subagents, then
every subagent is indistinguishable from the main agent and the gate waves EVERYTHING through** — while
looking installed, and green. That is this repo's house failure (*a gate that passes by not looking*)
committed by the very thing built to prevent it, and it manufactured false confidence: three unbidden
subagent mutations (two tree-rewrites + a commit/push/PR) happened with the "sandbox" in place.

### THE TEST (5 minutes; do it before relying on any subagent brief)

Hook *wiring* loads at SESSION START, but the hook *script* is re-read from disk on every call — so:

1. Add to the top of `main()` in `subagent-readonly-gate.py`, right after the `json.load`:

   ```python
   open("/tmp/hook-fired.log","a").write("FIRED tool=%s agent_id=%s agent_type=%s\n" % (
       data.get("tool_name"), data.get("agent_id"), data.get("agent_type")))
   ```

2. Spawn ANY subagent and have it run **one Bash command** (`git status --short` — read-only).
3. `grep -v 'agent_id=None' /tmp/hook-fired.log`
   - **a line appears** → subagents ARE identified → the gate is real; the 14:40 incident needs another explanation (find it).
   - **nothing** → **the gate is BLIND. It protects nothing.** Fix it, and do not brief another read-only agent until you have.
4. Remove the probe.

### If it is blind — the two fixes, in order

1. **`isolation: "worktree"` on EVERY adversary spawn, mandatory.** It does not depend on the harness
   populating any field: the agent gets its own checkout and **physically cannot** touch your working tree
   or your `HEAD`. It does NOT stop a `push` (same remote, same creds) — but it stops the two things that
   actually hurt: clobbering in-flight edits, and switching the branch under you.
   **This session's damage would have been prevented by it, and the rules already said to use it. I did not.**
2. **Make the hook FAIL CLOSED**: treat an unidentifiable caller as a subagent unless it proves otherwise.
   A mis-detection then blocks *me*, loudly — instead of letting an agent through, silently. Same
   failure-polarity argument that settled the `check-tools` design: a false RED is recoverable, a false
   GREEN is not.

### Also true, and I only said it after shipping

**A hook added mid-session does NOT protect that session** — the `PreToolUse` wiring in
`.claude/settings.json` is read at session start. `adversary-first-gate.py` (added 2026-07-14) therefore
protected **nothing** on the day it was written. Say that out loud when shipping a hook.

## ✅ THE RE-TEST MATRIX IS DONE — 6/6 GREEN (air-gap toolchain session, 2026-07-14 evening)

**Branch `gate/doc-target-coverage`. Every leg RAN, serially, and each verdict below is the log's OWN
verdict line — not an exit code** (a `| tail` in a backgrounded call reports `tail`'s status, and that has
lied here before).

| leg | verdict |
|---|---|
| `bootstrap-engine-test` | **PASS** — 6 bare-image legs. Proves `make deps` still builds a working jump box on photon:5.0 / ubuntu:24.04 / ubuntu:26.04 × {podman,docker} **with** the new `gawk`/`openssl`/`gettext` |
| `e2e-kind` | **PASS** — the DEFAULT ingress now installs from the CARRIED istio charts; `require_internet` on the mirror path |
| `verify-ingress-both` | **PASS** — istio + traefik |
| `e2e-kind-istio-existing` | **PASS** — attach mode, both route APIs, 2 demonstrated REDs |
| `e2e-sneakernet` | **PASS** — photon + ubuntu; each reconstructed the image cache **and** the toolchain from the carried tarball alone |
| `jumpbox-matrix` | **PASS 4/4** — podman AND docker, on both OSes, each login→pull→build→push→pull-back-verify against the self-signed Harbor, every leg `sudo=NO` |
| `airgap-toolchain-test` | **PASS** — bare, `--network none`; `check-tools` clean in DEFAULT mode after bundle-load (the contract that proves the bundle carries a toolchain) |

**A harness lesson worth keeping:** `jumpbox-matrix` first came back RED with `HARBOR_PASSWORD is not set`.
That was **my harness, not the product** — it pushes to a live KinD Harbor, and I had ordered it *after*
`e2e-sneakernet`, which tears the cluster down. On a red leg, ask "PRODUCT or MY HARNESS?" **first** — and
then prove which, because the converse error (dismissing a real bug as "just my harness") is worse.

**What changed → what it INVALIDATES (re-run these; do NOT assume):**

| changed | why it invalidates | must re-run |
|---|---|---|
| `scripts/00-install-prereqs.sh` — now installs `gawk`, `openssl`, `gettext`/`gettext-base` | it is the script that BUILDS every jump box | `make bootstrap-engine-test` (photon/ubuntu-24.04/ubuntu-26.04 × default/docker = 6 legs) |
| `scripts/10-mirror-pull.sh` — `require_internet` probe + carries the Istio charts | first step of `mirror`; runs in every mirror path | `make e2e-kind`, `make e2e-sneakernet` |
| `scripts/11-bundle.sh` — `stage_tool` now resolves via `mise which` + ASSERTS the `.mise.toml` pin | it decides what crosses the gap | `make e2e-sneakernet` (+ `e2e-sneakernet-both`) |
| `scripts/20-bundle-load.sh` — installs 5 tools, KEEPs the box's own, dies if `BIN_DIR` off PATH | the far side's entry point | `make e2e-sneakernet` |
| `scripts/46-install-istio.sh` — installs from CARRIED charts when present | **istio is the DEFAULT ingress** — this is on the main path | `make e2e-kind`, `make verify-ingress-both`, `make e2e-kind-istio-existing` |
| `scripts/lib/os.sh` — `require_internet()` | sourced by everything (probe only fires in mirror-pull) | covered by the above |

**The permutation matrix the owner asked for (2026-07-14) — none of it has been run since the changes:**

```text
make bootstrap-engine-test      # 6 legs — REQUIRED: 00-install-prereqs.sh changed
make e2e-kind                   # default ingress = istio -> now exercises the carried-chart path
make e2e-kind-both              # secure + insecure Harbor
make e2e-sneakernet             # photon + ubuntu; the whole carry
make jumpbox-matrix             # {photon,ubuntu} x {podman,docker}
make verify-ingress-both        # istio + traefik
make e2e-kind-istio-existing    # attach mode (2 REDs + both route APIs)
make e2e-kind-tenant / -cross-cluster   # unchanged code, but they source lib/os.sh

```

**Run them SERIALLY** — they mutate a shared cluster + registry, and parallel runs make any failure
unattributable. Read each log's OWN verdict line; the harness's "exit code 0" is not one (a `| tail`
in a backgrounded call reports `tail`'s status, and it has lied here before).

**Known-stale docs to fix in the same pass:** `docs/sneakernet.md`'s ingress table still says
`INGRESS_CONTROLLER=istio` (default) ❌ cannot run air-gapped. **That is now FALSE** — the charts are
carried and `helm template` renders them offline on a `--network none` box. Fix the table, and say
where the charts come from.

**Also owed:** the two adversaries went idle and NEVER delivered written reports (their findings exist
only as code, which was reviewed and one defect fixed — `helm repo update` ran unconditionally, failing
on the exact no-network path the carried charts exist to fix). If you want the reports, re-run them.

### THEN — and only then — RE-VALIDATE THE DOCS WITH ADVERSARIES (owner's instruction, 2026-07-14)

**Order is deliberate: the e2e matrix FIRST, the doc audit AFTER.** A doc audit run against code the
matrix is about to change is wasted — and worse, it produces "confirmed" findings that the next commit
falsifies. Run the matrix, fix what it reds, THEN audit the docs against the code that actually shipped.

Every operator-facing doc gets adversarially re-validated **against the code**, claim by claim:
`README.md`, `docs/sneakernet.md`, `docs/scenario-1.md`, `docs/scenario-2.md`,
`docs/prerequisites-manual.md`, `CLAUDE.md`.

Use a **`Workflow` with a schema** (one agent per doc → adversarial verify per finding → synthesize).
A fire-and-forget background `Agent` delivers NOTHING — measured 0/4 in this very session, while a
schema-forced Workflow delivered 44/44. A preliminary run exists (`doc-truth-audit`); treat it as a
SIGNAL, not a verdict, because it ran before the matrix.

The docs are where today's bugs were **stated as facts** — "the air-gapped host gets binaries from the
bundle" (it got none), "these are on any Linux base" (`awk` is not on Photon), "run `make preflight`"
(it needs a live cluster). A doc claim is a CLAIM. Grade each: does the operator FOLLOW it and FAIL?

### AND: `docs/vks-services/*.md` — A GRADE IS NOT A SOURCE (owner's instruction, 2026-07-14)

`docs/vks-services/{harbor,argocd,istio}.md` carry a provenance TAXONOMY — `lab-verified` /
`KinD-verified` / `9.1-doc` / `9.0-doc (inferred for 9.1)` / `community` / `UNVERIFIED`. **That is not
good enough, and the owner is right.** A grade describes the *shape* of the evidence; it does not let
anyone **check** it. `9.0-doc (inferred for 9.1)` names no page, no sentence, no date — so the fact
cannot be re-verified, cannot decay, and cannot be argued with. It is an opinion wearing a badge.

**What is owed: every load-bearing fact must be REFERENCEABLE.** Keep the grade (it is a useful
one-glance signal) but it is now a *summary of a citation*, never a substitute for one. Each fact
carries the evidence that produced it:

| the fact came from | what MUST be recorded beside it |
|---|---|
| a vendor doc | the **exact URL**, the **retrieval date**, and the **quoted sentence** that says it. If the 9.1 URL 301-redirected to the 9.0 tree, record BOTH URLs and say so — that redirect is itself the evidence for the grade |
| a lab / a cluster | the **exact command** and its **actual output** (not a paraphrase) |
| our own code | `FILE:LINE` |
| a blog / field source | URL + **date** + author, and why it is credible |
| nothing | **NOT ESTABLISHED** — plus *what was tried* and *what would settle it*. "UNVERIFIED" alone is a non-deliverable: absence of verification is not evidence of falsehood, and publishing doubt is itself a claim (see `version-discipline.md` — a prior session "corrected" a TRUE Istio fact to UNVERIFIED and shipped the retraction into four files) |

**How to do it:** run it AFTER the e2e matrix, as a `Workflow` (schema-forced) combining **`vks-adversary`**
with the **`deep-research`** skill — one agent per service doc, each required to return, per fact, a
resolvable citation or an explicit NOT ESTABLISHED. Then an adversarial verify pass that tries to
**refute each citation** (does the URL still say that? does it serve 9.1 or 9.0? is the quote real?).

**The gate that makes it stick:** a `check-vks-provenance` script — every fact row in
`docs/vks-services/*.md` must carry a resolvable reference (URL+date+quote, a command+output, or
`FILE:LINE`), else RED. RED-prove it by stripping one citation. Without the gate this rots back to
vibes on the first hurried edit, exactly like every other prose rule in this file did.

## ▶️ HANDOFF 2026-07-14 (docker-on-the-jump-box session) — START HERE

Branch `feat/jumpbox-docker-support`. **Docker is now SUPPORTED on a jump box, opt-in, on both OSes.**
podman remains the default and the only engine that is sudo-free everywhere.

### THE FRAME THAT MADE THIS TRACTABLE

**Docker on a jump box was never "untested" — it was UNSUPPORTED BY OUR OWN BOOTSTRAP.**
`00-install-prereqs.sh` installed podman only, on both OSes, and a gate asserted that as an invariant. So
every "docker works" measurement we had was taken on the developer's laptop: **scoped to the wrong
machine**. Before measuring whether a component works, grep the provisioning path for it — it costs 60
seconds and it reframed this entire task.

### WHAT IS PROVEN (each by a run, not a claim)

- **CLAIM 1 — the bootstrap PRODUCES the box: 6/6 on LITERALLY BARE images** (`make bootstrap-engine-test`;
  photon:5.0, ubuntu:26.04, ubuntu:24.04 × {default, docker}). Default ⇒ podman + **zero** docker packages.
  `CONTAINER_ENGINE=docker` ⇒ docker + rootless prereqs and **not** podman. Asserts **artifacts on the box**,
  not log lines. It runs the REAL bootstrap on an image with nothing pre-installed — a harness that
  pre-bakes the engine would hit "already the newest version", exit 0, and test nothing.
- **Ubuntu 24.04 is the leg that matters**: it has NO distro rootless helper, so the bootstrap installs
  docker, **discloses "rootful-only ⇒ a sudo per registry"**, and **does not add `download.docker.com`** —
  asserted, because adding a third-party apt repo to someone else's jump box is not ours to decide.
- **The engine matrix** (`make jumpbox-matrix`): {photon,ubuntu} × {podman,docker}, each doing
  login → pull → build → **push** → `crane validate --remote` against the real self-signed Harbor.

### THE FACT THAT INVERTS THE USUAL ASSUMPTION (ran-it)

`docker.io` is **29.1.3 on both Ubuntu 24.04 and 26.04**, but only **26.04's deb ships
`dockerd-rootless.sh`** (hidden in `/usr/share/docker.io/contrib/`, OFF PATH — `make deps` symlinks it).
24.04 ships **zero** rootless files. **Photon 5** ships `docker` + `docker-rootless` + `rootlesskit`
first-class with the helper already on PATH. **Photon is the EASY OS for rootless docker.** Do not
re-derive this from docs — an adversary and I disagreed here and we were each right about a different
Ubuntu release.

### WHAT THE ADVERSARIES KILLED (run them FIRST — Rule Zero)

Both delivered, and both demolished my design *before* I wrote it:

- `test-container-engine.sh`'s docker gate was **structurally blind to `pkg_install docker`** (it scans for
  docker *invocations at a command position*). An engine-aware bootstrap would have put a docker daemon on
  **every** jump box under a **green** gate. Fixed by making the package list a **pure function**
  (`engine_packages`) the gate **executes** — RED-proven 4 ways.
- The dind matrix I planned was the **wrong instrument** (root-in-container makes the sudo column
  *unmeasurable*; pre-baking the engine makes `make deps`' docker path never run). The bare-image bootstrap
  test is what actually proves the claim.
- My own premise P2 ("Ubuntu needs a third-party repo") was **half wrong**, and the vks-adversary's
  counter-claim was **half wrong too** — see the release split above. **Ran-it beat both.**

### THE BUGS THE MATRIX FOUND (it earned its keep on its first honest run)

All were **silent no-ops** — the house style of this repo's failures:

- **`HARBOR_URL` was not override-able.** `make mirror HARBOR_URL=<other>` pushed to the DEFAULT registry
  and said nothing: `.env.example`'s uncommented value is sourced back over the caller's. Same for
  `HARBOR_CA_FILE`. Both are now SELECTORS that `load_env` snapshots and restores.
- **`make fetch-harbor-ca` wrote the LEAF certificate into a file called `ca.crt`** (`openssl x509` reads
  only the first PEM block). It works on KinD *only because* our Harbor's leaf is self-signed. On a real
  lab (cert-manager leaf, separate CA) crane/Kaniko fail `x509: unknown authority`. Now takes the issuer
  and **`openssl verify`s** it before writing.
- `jumpbox-image` built the podman Dockerfile for the docker leg — caught by the **single-engine assert**,
  which is exactly the false green it exists to prevent.

### AND THE ONE I ALMOST SHIPPED

`make jumpbox-matrix | tail` reported **exit 0** while the log said **FAILED** — a pipe replaces the gate's
status with `tail`'s. I nearly reported a pass. **Read the gate's own rc, on its own line.** It is written
down in the rules and I still did it.

### A CAPABILITY CHANGE IS NOT DONE UNTIL THE OPERATOR DOCS SAY SO (and this is NOT a gate — see why)

I shipped docker support, updated CLAUDE.md + the decision doc, and **announced it** — while `README.md`,
`.env.example`, `docs/vks-services/harbor.md` and `docs/prerequisites-manual.md` still told the operator
that docker was unsupported and made them hand-type `sudo install -D …` CA commands. The owner caught it,
not me, and nothing in the code could have.

**The rule:** when a change alters *what the project can do* (what `make deps` installs, which engines
work, what a target now automates), the deliverable includes **re-deriving the operator docs from the
post-change state** — README, `.env.example` comments, the per-service reference tables, the prereqs page.
Not "check they still parse": re-read them as someone who only reads *that* page. A new `make` target that
appears only in CLAUDE.md is reachable **from nowhere an operator reads**.

Specific traps this hit, all of which recur:

- the docs described the **old workaround** (hand-typed CA install) that the new target now automates —
  a "mechanism essay" the backlog had *already flagged as a specimen*, and I walked past it;
- a canonical **reference table** ("how does each consumer trust the CA") silently omitted the new
  consumer — a table is exactly where an addition is easiest to forget;
- the negative claims (*"a real air-gap run is podman-only"*) are the ones that rot, because they read
  as background rather than as claims.

**Why there is no gate for this, stated plainly rather than faked:** the only mechanical signal available
("every `##`-documented target must appear in some `.md`") would be permanently red on internal targets,
and a gate that is always red is worse than no gate. `check-doc-make-targets` covers the *other* direction
(a `make X` in a doc must exist). So this one is a **checklist item, not a check** — and it is written down
as such because pretending otherwise is how the fake-green rules get violated.

### THE ONE THING I COULD NOT PROVE, AND WHY (state it; do not quietly retry it)

**`make e2e-kind CONTAINER_ENGINE=docker` cannot be run to completion on a ROOTFUL-docker host without a
sudo password**, and an agent has no tty. This is not a defect — it IS the disclosed cost: rootful docker
must write the Harbor CA into root-owned `/etc/docker/certs.d`, and the `docker` group grants socket
access, not write access to `/etc`. On a **rootless**-docker host it needs no sudo and should just run.

Do not read that gap as "docker is unproven": `make jumpbox-matrix` proves docker **logs in, pulls,
builds, pushes and pull-back-verifies against the real self-signed Harbor, sudo-free, on BOTH OSes**
(4/4). What `e2e-kind CONTAINER_ENGINE=docker` would add is the engine driving the *full pipeline* — and
note it is partly circular anyway, since `kind`'s nodes ARE docker containers, so that target requires
docker regardless of `CONTAINER_ENGINE`.

For an operator on a rootful box, the honest command is:

```bash
make trust-harbor              # prints the ONE sudo line; run it, then:
make e2e-kind CONTAINER_ENGINE=docker

```

### NEXT

1. **A real lab.** The Supervisor topology, the `vcf` CLI auth flow, and whether a VKS guest cluster ships
   the Gateway API CRDs remain **UNVERIFIED**. No amount of KinD green changes that.
2. `docs/scenario-1.md` had an adversary sweep (verdict was NOT_SHIPPABLE; the CRITICALs are fixed). Its
   remaining MEDIUMs are in the report: the `vcf context` namespace scope in A3, and folding the three raw
   `kubectl` preconditions into a `make lab-preflight`.
3. The `jumpbox` Makefile recipe is still a 50-line `\`-continued block. Every silent failure above lived
   in one. Move it to `scripts/`.

---

## Previous sessions — what is SETTLED (details in git history; do not re-derive)

**2026-07-14 (early):** all 8 e2e permutations green (`e2e-kind` · `e2e-kind-istio-existing` ·
`e2e-kind-tenant` · `e2e-kind-cross-cluster` · `e2e-kind-both` · `verify-ingress-both` · `jumpbox-both` ·
`e2e-sneakernet`). Its theme — **every bug REPORTED SUCCESS WITHOUT DOING THE WORK, and a green gate
agreed** — is the house style of this repo's failures. Assume that class by default.

The **option-B docker spec** that lived here is **implemented and merged** (#228 + #232); the
**container-engine decision** is in `docs/decisions/container-engine-support.md`, and the operator-facing
answer is in the README's engine table. Do not re-open either from an old handoff.

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

### ✅ DONE (#233) — the "mechanism essay" review, including the specimen it named

The planned review is finished. The named specimen — the README/`.env.example` container-engine blurb that
explained docker's daemon TLS model and made the operator hand-type `sudo install -D …` CA commands — is
replaced by a **choice table + `make trust-harbor` / `make engine-check`**. `docs/vks-services/harbor.md`'s
CA-trust table gained its missing docker rows.

**The durable rule (it recurs, and I walked past this very specimen once):** an operator doc states the
**CHOICE and the COMMAND**; the *mechanism* goes to `CLAUDE.md` / `docs/decisions/`. Anything typed twice is
a missing `make` target. And a **capability change is not done until the operator docs say so** — see the
section of that name in the current handoff (recorded as a checklist item, deliberately **not** a fake gate).

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

### ✅ REFUTED 2026-07-14 — "the Gateway-API path is a KinD ARTEFACT" was WRONG. VKS SHIPS the CRDs

**The 2026-07-13 BLOCKING finding below is OVERTURNED by primary 9.1 sources** (deep-research +
adversarial refutation, 2026-07-14; full record with URLs and quotes in
[`docs/reviews/2026-07-14-vks-deep-research.md`](docs/reviews/2026-07-14-vks-deep-research.md)).

**A VKS 9.1 guest cluster SHIPS the Gateway API CRDs by default.** They come from the **VKr** — the
VMware Kubernetes release that *is* the guest-cluster image — not from Istio, and not from us:

| VKr | ships gateway-api |
|---|---|
| **1.36.1** | **1.5.1** — *exactly our pin* |
| 1.35.5 / 1.35.2 / 1.35.0 | 1.4.0 |
| 1.34.8 | 1.3.0 |

From **VKS 3.7.0 / VKr 1.36**, VKS manages Gateway API through its **Add-on Management framework** and it
is **no longer in the `ClusterBootstrap` `additionalPackages` list** — but it remains VKS-managed and
**ON by default**: Broadcom documents an explicit **opt-OUT** label
(`addon.addons.kubernetes.vmware.com/gateway-api: unmanaged`), and an opt-out is only meaningful if the
default is opted-IN. The Istio add-on genuinely does **not** ship the CRDs — that part of the old finding
was right — but "therefore you must install them yourself" is a **non-sequitur**: the VKr already did.
This is also *why* Broadcom ships Istio's shared ingress gateway **disabled**: they expect the Gateway
API, which auto-provisions its own gateway. **Our Gateway-API route path is Broadcom's recommended path,
not a workaround.**

**⚠️ THE RISK INVERTS — and this is now the thing to worry about.** The danger was never "the CRDs are
absent". It is that they are **PRESENT, VKS-MANAGED, and at a version the VKr chose** (v1.4.0 on VKr
1.35.x) — while `istio_ensure_gwapi_crds` (`lib/istio.sh`) **server-side-applies our pinned v1.5.1**. On a
real lab we may be **fighting the VKS add-on manager**, or downgrading/upgrading a CRD we do not own.
**NOT YET RESOLVED — do not "fix" it blind.** What settles it: on a lab, read
`kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'`
and the `addon.addons.kubernetes.vmware.com/gateway-api` label on the Cluster, then decide whether we
should install at all, or detect-and-defer to the VKr's version.

**🔴 AND THE BELIEF THIS WHOLE PROVENANCE SYSTEM RESTS ON IS FALSE.** This repo says "Broadcom 9.1 doc
URLs 301-redirect to the 9.0 tree". **Measured with curl, 2026-07-14: NOT ONE `/9-1/` URL redirected.**
They return **200** (the page exists in the 9.1 tree) or **404** (the page was **renamed** — e.g. 9.1
renamed *Standard Packages* to *VKS Add-ons*, so `standard-package-reference` 404s). The thing that
redirects is **`/latest/`** → the **9-0** tree. Since search engines hand you `/latest/` URLs, *that* is
the 9.0-read-as-9.1 trap. **Hand-editing the version into the path to `/9-1/` is SAFE and is how the 9.1
facts above were obtained.** Every "9.0-doc (inferred for 9.1)" grade in `docs/vks-services/` was earned
under a false premise and must be re-checked against a hand-edited `/9-1/` URL.

<details>
<summary>The original (now-refuted) 2026-07-13 finding, kept for the record</summary>

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

*(Its ONE community-blog source was, in fact, correct. The "only a blog says VKS ships the CRDs"
dismissal was the error: Broadcom's own VKr release notes say it, on a 9.1 URL that returns 200. The
finding also over-trusted a VMware blog that said the CRDs "must be installed separately" — its first
clause is true (the Istio add-on does not ship them) and its conclusion is a non-sequitur. Note (b) was
implemented anyway, which is why the repo installs v1.5.1 today — hence the inverted risk above.)*

</details>

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

### ✅ DONE (#228, #232) — the docker claim is MEASURED, not argued

The task that used to sit here ("prove the docker-only claim, and do NOT do it with `make e2e-kind`") is
finished. `make jumpbox-matrix` runs {photon,ubuntu} × {podman,docker} and each leg makes the engine
**log in, pull, build, push and pull-back-verify against the real self-signed Harbor** — 4/4, every leg
`sudo=NO`. `make bootstrap-engine-test` proves the other half on **bare** images: `make deps` yields podman
with **zero docker** by default, and docker only when asked. The old note's claim that "the PODMAN claim is
ALSO unproven for the disputed step" was true then and is false now.

The one thing still unprovable here: **`make e2e-kind CONTAINER_ENGINE=docker` on a ROOTFUL-docker host
needs a sudo** (root-owned `/etc/docker/certs.d`) — that is the disclosed cost, not a defect. See "THE ONE
THING I COULD NOT PROVE" in the current handoff.

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
