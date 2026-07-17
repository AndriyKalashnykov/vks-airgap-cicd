# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🛑 RULE ZERO — the adversaries review your DESIGN, not just your diff (BLOCKING, read first)

The two headline adversaries for THIS repo are below. Both are BLOCKING. Each exists because a green run
*here* cannot see the ground it hunts on. **The whole roster is now GLOBAL** — `vks-adversary`,
`adversary-docker`, `adversary-java`, `adversary-bash-git-cli`, `adversary-go`, `adversary-k8s`,
`adversary-identity-auth`, `adversary-security-secrets` all live in `~/projects/claude-config/agents`
(symlinked to `~/.claude/agents`) — dispatch any of them by name. `vks-adversary` went global on
2026-07-16 **keeping its lab specifics** (owner decision, reversing 2026-07-15): its domain knowledge had
already moved to `claude-config/reference/`, and the noise it makes in a non-VKS repo is an accepted cost.
The `adversary-first-gate` hook **stays project-local** — it encodes THIS repo's paths and would
false-block everywhere else.

| Agent | Specialism | Its hunting ground — what a green run here CANNOT show |
|---|---|---|
| **`vks-adversary`** (global, VKS-specific) | VMware VCF/VKS 9.1 + Kubernetes + ArgoCD + Harbor + Istio + Tekton | **the REAL LAB.** A green KinD run proves nothing about a Supervisor, a tenant's RBAC, a corporate PKI, or PSA `restricted`. It also carries the Docker/registry-trust facts SPECIFIC to this lab (`HARBOR_URL` shape, the `certs.d`-keyed guard trap, the real Harbor blob-store incident). |
| **`adversary-docker`** (global) | Docker Engine + containerd + registry TLS trust (`certs.d`, `insecure-registries`, rootless, credential stores, BuildKit, kind's Docker coupling, Kaniko, crane, podman's per-command trust) | **the DAEMON, and a COLD box.** Your box has a warm `~/.docker/config.json`, a stale login, a CA possibly already in the system store, a rootful daemon, and BOTH engines installed. A fresh air-gapped jump box has none of that. |

**Run EVERY docker/podman/engine/registry-trust design past `adversary-docker` BEFORE implementing it**
(owner's standing instruction, 2026-07-13). It has already earned its keep: a "fail-fast" guard that
died when `/etc/docker/certs.d/<host>/ca.crt` was missing was **retracted** on its evidence — docker
MERGES `certs.d` with the system store, so the guard would have hard-blocked working operators. Full
mechanism: `docs/decisions/container-engine-support.md` §"Three facts that are routinely gotten wrong".

**INVENTING A NEW CONTROL is the act that most needs the idea-round — and it is the one that feels
exempt (DISCIPLINE, not a gate; 2026-07-16).** Writing a `check-*.sh`, a hook, or a new gate does not
feel like new design — it feels like *following through* on a reviewed fix, because "violated rules
become gates" is a correct reflex here. It is new design, it is usually the riskiest thing in the
diff, and the receipt from the *previous* design review authorizes it (the gate is scoped to TIME,
not CONTENT — its own header, line ~31, names that residual). Measured: a review of design X cleared
a 109-line shell-grammar gate nobody had ever seen; an implementation adversary later scored it
**7/20** (10 bypasses — `Passw0rd$1`→`Passw0rd`, the docs' own `robot$<name>`, every indented line —
and it could not express its own counter-example, so filing the review that found it would have
reddened `static-check`). **Do not try to gate this.** `agents.md:762` already settled it,
adversary-vetted: idea-first is enforceable only by a human, and a path-scoped receipt was
**refuted** on 2026-07-16 by running its own extractor against the very prompt asking for the review
— the prompt that names the file to review **authorizes** it (negations authorize too), it stamps at
spawn not delivery, it clears the *refuted* design while blocking the *prescribed* fix, and it
false-blocks 34% of commits. The residual is real, un-gateable, and the thing that caught it was the
owner asking "are you running your designs by adversaries?".

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
| 2 | **BEFORE you implement** | the moment you have a DESIGN, a DECISION, a root-cause CLAIM, or a plan. Touching VKS/ArgoCD/Harbor/Istio/Tekton/the air gap → **vks-adversary**. Touching docker/podman/the engine/registry trust/image builds → **adversary-docker**. Touching both (e.g. "make docker work against the lab's Harbor") → **BOTH**. Always *before* writing the code. | refuting a design costs one agent run; refuting shipped code costs a session. This trigger exists because it was MISSED: a fix for two CRITICALs was designed, and coding started, with no adversary in sight. |
| 3 | **BEFORE you call the session done** | the stopping rule — no session is DONE without it | the findings are part of the deliverable |

Triggers 1 and 2 collapse into one run when the session opens on a known task (brief it with the
backlog **and** the design). What is NOT acceptable is starting work with no adversary running.

**Trigger 2 IS NOW A HOOK, because prose did not hold — it was skipped on 2026-07-14 by the very
session that had just re-read it.** `.claude/hooks/adversary-first-gate.py` (wired in
`.claude/settings.json`) **BLOCKS `Edit`/`Write`** until an adversary has run. Read the truth from its
own constants, not from prose — they are `GUARDED_PREFIXES` / `EXEMPT_*` at the top of the file:

| | |
|---|---|
| **GUARDED** | `docs/` · `README.md` · `scripts/` · `jumpbox/` · `k8s/` · `tekton/` · `apps/` · `Makefile` |
| **EXEMPT** | `.claude/` · `.github/` · `CLAUDE.md` — this file IS the plan/backlog, so you can always write it down first |

**It clears only until your NEXT COMMIT, not for the session.** The receipt records the adversary's
wall-clock time and a guarded write passes only while that time is newer than HEAD's commit — so
committing re-arms it. That is deliberate (#244): a session-lifetime receipt meant one design review of
task A silently authorized the unreviewed implementation of task B three tasks later. Proven by
`make test-adversary-gate-rearm` (13 cases, including the re-arm). Escape hatch, on the record:
`ADVERSARY_GATE_OFF=1`.

Its sibling — the subagent read-only gate, now GLOBAL as `~/.claude/hooks/subagent-readonly.py` (a
merged superset; the old repo-local `subagent-readonly-gate.py` was promoted + merged into it) —
shipped with a HOLE it took a real incident to find: it
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
replacement — it stops file writes the hook cannot see.) The hook itself is **live-verified end-to-end
against a real subagent** (2026-07-14: it fired, carried `agent_id`, and REFUSED a real `git commit`;
re-confirmed 2026-07-16 after it went global). Check it yourself in seconds:
`python3 ~/.claude/hooks/subagent-readonly.py --selftest` → ALL PASS (138 cases as of 2026-07-16 —
the count grows; read the tail line, not this number, which was already stale at 90/90 when the real
corpus was 117).

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

**A newly-written `.claude/agents/*.md` may or may not be dispatchable in the session that created it —
TRY IT, do not assume.** It was once believed that definitions load at SESSION START (observed
2026-07-13, creating `docker-adversary`: `Agent type '<name>' not found`), but a by-name dispatch of a
same-session agent has since been observed running to completion — the harness re-reads the registry
live in at least some builds. So: **attempt the by-name dispatch first** (it is cheap and self-
announcing). Only if it genuinely 404s, run the persona **inlined** into a `general-purpose` agent's
prompt — the review still happens; only the shortcut is unavailable. Whatever you rely on, state it as
a thing you TESTED. Assumptions about harness timing have been wrong here more than once.

⚠️ An inlined persona in a `general-purpose` agent has **ALL** tools, including `Write` — a prompt is
not a sandbox. Give it `isolation: "worktree"` regardless.

## What this repo is

An **air-gapped VKS CI/CD demo**: from an internet-connected jump box (Ubuntu or
PhotonOS), mirror all required images into **Harbor**, install and wire **Gitea +
Tekton**, and demonstrate GitOps CD via **ArgoCD**. On a real VKS lab Harbor and ArgoCD
are installed as **Supervisor Services** (the README real-lab flow documents that,
Scenario 1); in Scenario 2 they already exist and you discover them as a tenant. We then install
Gitea + Tekton and the demo app. The KinD stand-in installs
Harbor + ArgoCD locally to mimic that.

End-to-end flow: `git push (Gitea) → Tekton (test/build/kaniko→Harbor/tag write-back) → ArgoCD sync → web UI`.

**"Jump box" names up to three DIFFERENT machines — prefer *internet box* / *air-gap box* when it matters.** In a **dual-homed** run there is one box that reaches both the internet and the lab. In a **sneakernet** run there are two: the **internet box** (`mirror-pull`/`builder-build`/`bundle`) and the **air-gap box** (`bundle-load`/`mirror-push`/`builder-push`/`platform` — it CANNOT run `make deps`; see RULE ZERO-A). Separately, `make jumpbox*` builds a **test** jump-box container that itself needs the internet (it runs `make deps`). Note `docs/sneakernet.md` calls its inside box the "jump box" and the internet one the "staging box" — the opposite of Scenario 1's usage.

## Common commands

| Command | What it does |
|---------|--------------|
| `make help` | List all targets (grouped) |
| `make deps` | Install jump-box toolchain (mise + `scripts/00-install-prereqs.sh`) |
| `make ci` | Offline gate: `static-check` + `docs-lint` + `diagrams-check` (PlantUML render drift) |
| `make static-check` | Composite offline code gate — the **authoritative** prereq list is the `static-check:` line in the Makefile (alignment + `check-agent-frontmatter` + doc/terminology gates + env/app gates + `lint` + `validate` + `sec` + `test-scripts` + `app-test`). Do NOT re-enumerate it here — a hand-typed subset rots on the first Makefile edit. |
| `make sec` | Security scans: `secrets` (gitleaks) + `prose-secrets` (credential-shaped prose in docs) + `trivy-fs` (built-jar deps) + `trivy-config` (manifests) |
| `make app-test` / `app-build` / `app-run` | Build/test **every** app (java: `./mvnw`, go: `go test`/`go build`); one app: `APP=javawebapp\|gowebapp` (`app-run` defaults to javawebapp). Apps are the rows of `apps/registry.tsv`. |
| `make mirror` | (dual-homed) pull images → push to Harbor. **Resumable:** a re-run cache-skips digest-pinned images already fully pulled (`.mirror-ok` sentinel), so an interrupted/CDN-flaky mirror resumes in seconds. `MIRROR_RETRIES` (default 5), `MIRROR_FORCE_PULL=1` |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
| `make mirror-verify` | Verify every mirrored image is INTACT in Harbor (`crane validate` blobs + `images.lock` digest match) — read-only; run after `make mirror` |
| `make builder-image` | (dual-homed) build+push the offline Maven builder image (deps pre-baked) |
| `make builder-build` / `builder-push` | sneakernet builder split: `builder-build` builds the Maven builder INTO the bundle on the internet box (needs Maven Central, NOT Harbor); `builder-push` pushes the CARRIED builder into Harbor on the air-gap box (carried crane, no container engine) |
| `make vks-login` | Authenticate to VKS → writes `$KUBECONFIG` + context |
| `make install-vcf-clis` | On a real-VKS-lab jump box: install the Broadcom lab CLIs (`argocd-vcf` + `vcf` + plugins), OS/arch-aware + sudo-free, from operator-supplied licensed archives in `VCF_CLI_SRC_DIR=<dir>`. (The local KinD e2e doesn't need these — it uses the upstream `argocd` from `deps`.) Granular: `install-argocd-vcf` / `install-vcf-cli` / `install-vcf-plugins` |
| `make platform` | Install + wire Gitea and Tekton |
| `make gitops` | Wire ArgoCD to each `<app>-deploy` repo (one Application per app; registers the guest cluster first when that is actually needed AND permitted) |
| `make creds-show` (alias `creds`) / `make argocd-password` / `make argocd-version` | Print access URLs+logins / the ArgoCD admin password (context-aware, self-resolves kubeconfig) / the ArgoCD CLI vs RUNNING-server vs repo-pin versions (read-only, never gates, exits 0 even with no cluster) |
| `make env-init` / `env-populate` / `env-check` / `env-validate` | `.env` lifecycle: create from `.env.example` → GENERATE the secrets we can + DISCOVER cluster values (and print the user-PROVIDE list) → presence gate → validity gate (format + KUBECONFIG/Harbor auth) |
| `make harbor-robot` / `fetch-harbor-ca` / `fetch-argocd-ca` / `fetch-argocd-kubeconfig` / `argocd-preflight` | Real-lab helpers: mint a Harbor robot (needs project-admin) · fetch a self-signed CA · fetch the Supervisor kubeconfig for ArgoCD registration · report ArgoCD CLI vs RUNNING SERVER vs supported versions |
| `make test-scripts` | Offline script-logic unit tests (mirror cache-skip/resume/prune; VCF-CLI archive resolve). Part of `static-check` |
| `make e2e-kind-both` / `verify-ingress-both` / `e2e-kind-cross-cluster` / `e2e-sneakernet` | e2e permutations: both SSL modes · both ingress controllers · 2-cluster ArgoCD registration · two-box sneakernet |
| `make install-ingress` | Install the ingress (`INGRESS_CONTROLLER=istio` default / `istio-existing` = attach to a platform-owned mesh / `traefik`) fronting the UIs at `*.vks.local` |
| `make install-istio` / `install-traefik` | Install a specific ingress controller directly |
| `make psa-check` | Read-only: would our pods survive a real VKS guest cluster? VKS **enforces PSA `restricted` by default** (VKr v1.26+) while KinD enforces nothing — so `ci` (Kaniko builds as root) and the Gateway namespace (Istio's auto-provisioned proxy sets no seccompProfile) need `baseline` or their pods are REJECTED on the lab. Levels are MEASURED via a server-side dry-run label, not guessed. Wired into both e2e targets |
| `make istio-preflight` | Read-only: is Istio here, what `Gateway` selector does it require, what may this kubeconfig do, and what must the mesh admin grant? Run before touching a cluster you don't own |
| `make attach-istio` | Attach to an Istio the platform team ALREADY installed (`INGRESS_CONTROLLER=istio-existing`) — installs nothing, applies routes only. `ISTIO_ROUTE_API=auto` (default) prefers the Kubernetes **Gateway API** (Istio auto-provisions the proxy + LB; nothing needed from the mesh admin) and falls back to `classic` (discovered `istio:` selector + VirtualServices) |
| `make e2e-kind-istio-existing` | KinD regression test for the attach mode: a "platform team" installs Istio under FOREIGN naming, we attach with zero install (+ both REDs), then verify BOTH route APIs (gateway-api leg + classic leg) |
| `make install-all` | Full air-gap install: `preflight → mirror → mirror-verify → builder-image → vks-login → platform → gitops`. `preflight` runs FIRST and is read-only — it stops a 20-min mirror on a box that can't finish; `mirror-verify` is the blob-integrity gate. |
| `make verify` | End-to-end smoke test (LIVE cluster) |
| `make verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| `make e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify). Reuses a warm cluster by default (fast) and says so LOUDLY at the end; **`E2E_FRESH=1`** forces a cold cluster (`kind-down` first — proves namespace create-ordering) |
| `make kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps |
| `make jumpbox` / `jumpbox-both` / `jumpbox-matrix` | Validate the README jump-box bootstrap in a **test** jump-box container (itself needs the internet — it runs `make deps`), joined to the kind network, on `JUMPBOX_OS` × `JUMPBOX_ENGINE` (photon\|ubuntu × podman\|docker; defaults photon+podman): runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` = the OS matrix (podman); `jumpbox-matrix` = the full 4-cell OS×engine matrix. Needs the KinD cluster up |

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
  commands you run: dual-homed → `make mirror && make builder-image`; sneakernet →
  `make mirror-pull && make builder-build && make bundle` (carry the bundle) then
  `make bundle-load && make mirror-push && make builder-push`. The builder image is
  part of the mode split too — `builder-build`/`builder-push` are its sneakernet halves.
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
  `VKS_AUTH_METHOD=kubeconfig` (via `state_set`) to the **stamped state overlay `.env.state`**
  (`VKS_STATE_FILE`; `.env.kind` is read-only back-compat only, nothing writes it);
  `06-install-harbor.sh` exposes Harbor as a
  **self-signed-HTTPS LoadBalancer on the LB IP** (default; two-phase: install TLS-off →
  discover LB IP → mint CA+leaf with SAN=IP → upgrade to TLS), wires each node's containerd
  with the CA (`certs.d/<ip>/`), and `state_set`s `HARBOR_URL`(LB IP)+`HARBOR_INSECURE=0`+
  `HARBOR_CA_FILE` to `.env.state` (`HARBOR_INSECURE=1` selects the original plain-HTTP mode).
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
  publish `INGRESS_LB_IP` + the chosen `INGRESS_CONTROLLER` to `.env.state` (via `state_set`). `44-install-ingress.sh`
  lets an explicit `INGRESS_CONTROLLER` override win over the persisted `.env.state` value (so
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

- **Version manager:** mise (`.mise.toml`) on the internet-side jump box — including
  `crane` (the image-mirror engine, a static Go binary). Air-gap exception:
  `tkn`/`argocd` come from OS packages / pinned releases via `00-install-prereqs.sh`,
  which (INTERNET-side only) ALSO installs the floor packages a bare `photon:5.0`
  lacks: `gawk`, `openssl`, `gettext`(envsubst), `git`, `curl` (NOT `make` — that
  script is invoked BY `make`, so make must pre-exist). The
  **bundle carries 5 pinned static binaries** — `crane`, `kubectl`, `helm`, `jq`, `yq`
  (`11-bundle.sh`) — the **Istio helm charts** and the **Tekton + Gateway-API manifests**
  (`10-mirror-pull.sh`), and the image cache (`bundle-load` → `mirror-push` →
  `mirror-verify` → `install-*`). It used to carry **nothing** (then, briefly, *only*
  crane), while this line claimed otherwise; the e2e hid that by letting its "air-gap"
  box run `make deps` over the internet. What the bundle CANNOT stage is the **OS-package
  floor** (git, make, openssl, gettext/envsubst, gawk, curl, tar, coreutils) — the
  air-gap box provisions those from its **internal package mirror**, NOT by running
  `00-install-prereqs.sh` (internet-side only). Per-tool: without `awk` `mirror-verify`
  dies, without `envsubst` the manifest render dies, without `openssl` cert minting dies.
  See [`docs/sneakernet.md`](docs/sneakernet.md).
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
KinD-verified / 9.1-doc / 9.0-doc-inferred-for-9.1 / community / UNVERIFIED) — explicit Broadcom
`/9-1/` URLs serve genuine 9.1 content (200) or 404; only `/latest/` 301s into the `/9-0/` tree (the
"9.1 URLs redirect to 9.0" belief was measured FALSE 2026-07-14), so the 9.1 **release notes** are
9.1-primary while some **package-reference/`vcf`-CLI** pages resolve only to `/9-0/`. **When a lab run
confirms or refutes something, update the grade in place** (and correct the fact, with a note) rather
than re-deriving it next session. The load-bearing split: Harbor + ArgoCD are **Supervisor Services**
(they run beside your workload cluster → discover + request + register); Istio is a **guest-cluster
Standard Package** (→ attach, never install; there are no Istio credentials).

**Going to a real lab?** [`docs/lab-validation-plan.md`](docs/lab-validation-plan.md) is the runbook for
the trip: every open question as a numbered step with its command, its expected observable, and what to
send back. The lab is the scarce resource — a step you run without knowing what to collect is a trip we
cannot learn from.

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

## Naming history

**`webui` was renamed to `javawebapp`** (2026-07-12) when a second app (`gowebapp`) arrived — the
name had to say WHICH app. The rename covered the source tree (`apps/java/javawebapp`, Java package
`com.vmware.vks.demo.javawebapp`), the Gitea repos (`javawebapp-app` / `javawebapp-deploy`), the
Harbor path (`apps/javawebapp`), the Tekton objects, the deploy dir (`deploy/javawebapp`) and the
ingress host (`javawebapp.vks.local`). **Git history and `docs/reviews/*` still say `webui`** — that
is what those PRs actually touched, and rewriting them would falsify the record.

## ▶️ HANDOFF 2026-07-17 (session 3) — READ, THEN REPLACE (do not append)

**ONE handoff section; the next session OVERWRITES it.** Facts → the docs. Tasks → the Backlog.
History → git. Only "what is in flight and what to distrust" belongs here.

**State: `main` GREEN @ `9bf7586`+, tree clean, everything pushed. NOTHING is half-done.**
**This session (s3):** (1) confirmed **B29, B30(a/b), F8, B41, B44** were already SHIPPED in #295–#297
(the backlog still listed them OPEN — two consecutive picks landed on already-done rows, so the backlog
itself was the bug), pruned those five + collapsed **B26/B33** + folded B23 into B22 (PR #302); (2) ran
the **B37 idea-round → REFUTED** `make red-prove` (below); (3) shipped **B30c** — `test-namespace-gates.sh`,
the honest unit test for the two namespace/inject gates (PR #304, two adversary rounds, post-merge CI
green); (4) ran the **cold `make kind-down && make e2e-kind` (B34) → GREEN end to end** — `PSA OK, 7
namespaces measured` on a FRESH cluster (every namespace labelled at creation → the B29 ordering fix
holds on a real cluster), both apps' GitOps pipelines SUCCESS, mirror 36/36, ingress reachable; (5)
fixed **B42** — a warm `make e2e-kind` now prints a LOUD final stdout verdict that create-ordering was
NOT proven, and `E2E_FRESH=1` forces a cold run (05-kind-up publishes `KIND_REUSED`, a verdict script
reads it, `test-e2e-fresh` gates it — two adversary rounds). **B30, B34, B42 are now DONE.** **No
cluster is up** — the e2e cluster was torn down + verified BY ARTIFACT (0 clusters, 0 `kindccm-*` orphans, 0
cloud-provider-kind, no `/etc/docker/certs.d`), it deleted only what it created and
**preserved** `.env` + `secrets/vks.kubeconfig`, and nothing was written outside the repo.

**Two Renovate PRs are deliberately OPEN**: **#298** (markdownlint-cli 0.49.1) and **#300** (uv
0.11.29). Every CI check on #298 passes — both are held by **`renovate/stability-days`**, the
minimum-release-age gate. They are NOT broken and must NOT be force-merged: that gate quarantines a
release until a compromised publish would have surfaced. They merge themselves when the cooldown
elapses.

### Shipped, each verified on a REAL cluster (not a green gate)

| | |
|---|---|
| **B29/B30** | `make install-all` labelled **neither gitea nor tekton** — the label landed **never**, not late. On a VKS guest: every pod rejected. Their only `ensure_namespace` calls lived in `lib/istio.sh`, reachable only from `install-ingress`, which `install-all` does not run. |
| **B36** | the carried-chart pin was **decorative** — helm IGNORES `--version` for a local `.tgz`; the tree was installing a **MIXED MESH**. |
| **B44** | the attach e2e simulated a mesh that injects **NOTHING**. It now proves B26: `CONTROL ok — [p istio-init istio-proxy]`, then `[p ]` in a labelled ns. |
| **B41** | `psa.sh`'s comment was wrong TWICE in opposite directions, and omitted the rule that IS the hazard. |
| also | `tekton-pipelines-resolvers` (never labelled by anything), the SSA `enforce` takeover, traefik's missing controls, and an e2e `psa-check` that measured **0** and reported nothing. |

### 🔴 Distrust these — measured, not reasoned

- **F1 IS DEAD. Raised twice, refuted twice, ~750k tokens a round.** Recorded in **B38**: our path is
  istiod's auto-provisioned template (`istiod/files/kube-gateway.yaml`, `image: auto` → 0 hits, sets
  `sidecar.istio.io/inject:"false"` on the pod), NOT the `istio/gateway` HELM CHART the claim quoted.
  **Both raisings were the same error — grepping the WRONG ARTIFACT** (a doc about a different chart;
  then our manifests for an istiod chart file). Do not re-raise.
- **`make e2e-kind` reuses a warm cluster by default** (fast) — this is now LOUD (a final stdout
  verdict says "create-ordering NOT proven"; B42 FIXED s3), and `E2E_FRESH=1` forces a cold run. A
  reused run still exits 0, so for guaranteed create-ordering evidence use `E2E_FRESH=1`.
- **`--watch` HANGS on a code-only PR** — `docs-lint`/`diagrams-check` register as `skipping`, which
  `--watch` never treats as terminal, while the PR is already `CLEAN`. Gate on `mergeStateStatus`.
- Every VKS injector fact is **upstream-1.30.3-rendered**. `1.28.2+vmware.1-vks.1` is
  **UNVERIFIED-BY-US** — and the injector `policy` field is load-bearing too, so the lab visit needs
  BOTH commands, named in `psa.sh`'s grade block.

### Next

- **B39** (an instrument must reproduce a known answer first) still needs its OWN idea-round — the
  cheapest remaining discipline item. Then the code rows: B13/B14/B31 (Harbor-credential cluster),
  B26-fix-3 (offline helm-template inject gate), B3 (sneakernet Step-4 harness coverage).
- **B37 is REFUTED — do NOT rebuild `make red-prove`** (idea-round this session; flip-detection is
  blind to a coverage gap → it would certify the blind test it is named after; full record in the B37
  row). **B45** (the gate's time-vs-content re-arm) is real but must NOT be a content-scoped receipt
  (refuted 2026-07-16).

### The one thing to carry forward

**Every gate I wrote this session was green on its own bug at first draft — three for three** — and
each was caught by an **implementation round** *after* the design round had approved it. The
`check-namespace-labelled` first draft grepped `scripts/` repo-wide; an adversary deleted BOTH
installers' calls (restoring the bug exactly) and it reported **OK rc=0**. My RED-proofs passed only
because I mutated **the code I had just written** instead of the defect as it shipped.

Nine instrument failures were counted — self-matching `pgrep` ×3, a zsh no-word-split, `RC=$?` lost
in a subshell, a grep matching the log line that *explains* the label, a `die` killing its own test,
a doc about the wrong mechanism, a RED-proof against my own mutation. **All nine were rules already
loaded.** Prose does not fire at keystroke time; that is what B37/B39 are for.

And the mirror image, worth equal weight: **I refuted the adversaries twice** (F1, F-A) — both times
because they reasoned from the wrong artifact, the same error I made first. A round's verdict is a
claim. Render it yourself; it takes thirty seconds and it settled every dispute this session.

## Backlog / resume state

Every item below is the OPEN set, re-verified against the tree — most recently on **2026-07-17
(session 3)**, when **B29, F8, B41, B44, B23, B30, B34 and B42 were REMOVED** because they
shipped/resolved (#295–#297 + #304 + the B42 fix; evidence in each PR + the code), and **B26, B33 were
COLLAPSED** to their open residuals (their done parts dropped). The history that produced these is in git and `docs/reviews/`;
carrying a closed item forward is the class this file was pruned to end.

**Code — no lab needed:**

| ID | Item |
|----|------|
| **B3** | **The sneakernet runbook's Step 4 is executed by NOTHING.** `docs/sneakernet.md` names `platform` / `gitops` / `install-ingress` / `verify`; neither `scripts/e2e-sneakernet.sh` nor `scripts/jumpbox-run.sh` runs any of them — so the half an operator performs *after carrying 11 GB* has never run. This is the condition under which `install-ingress`'s doc row once lied for hours while every test stayed green. Close it by **extending the harness**. Do **not** build a doc-parser: that design was adversary-killed twice (it cannot see a prose claim about a MODE, and it goes green over the covered half — `rules/common/testing.md` §"BINDING DOCS TO CODE"). |
| **B13** | **A CLASS of 7 vacuous guards, not one.** `.env.example` commits `HARBOR_URL=harbor.vks.local` + `HARBOR_USERNAME=admin` UNCOMMENTED and `load_env` exports them, so `: "${HARBOR_URL:?}"` can never fire — in `19-trust-harbor.sh:23,24`, `21-mirror-push.sh:35,36`, `22-builder-push.sh`, `22-harbor-robot.sh:25,26`, `60-configure-tekton.sh:20,21`, `jumpbox-launch.sh:41,42`, `lib/harbor.sh:13`. Fixing only `19-` ships the class. `harbor_url_is_placeholder` lives in **`02-env.sh:37`, NOT `lib/`**, so no caller outside that file can reach it — moving it into `lib/harbor.sh` is step one (keep the sentinel literal INSIDE a function body: a top-level var is clobbered by `load_env`'s `set -a`). ⚠️ **Blocked on a DECISION, not code:** rejecting the sentinel is a real FALSE-BLOCK — `.vks.local` is *this repo's own* domain (`gitea.vks.local`…), so an operator following our own convention lands on `harbor.vks.local` legitimately, and it is byte-identical to the sentinel. Settle first: a `<SET-IN-.env>`-shaped sentinel, or key on PROVENANCE (came-from-`.env.example`) rather than value. |
| **B14** | `HARBOR_USERNAME=admin` is committed UNCOMMENTED in `.env.example:138` (`HARBOR_PASSWORD` is correctly commented). A tenant who sets only `HARBOR_PASSWORD=<robot-secret>` gets `admin`+robot-secret → **401 across ~40 read-sites**. Nothing sources `secrets/harbor-robot.env` — it is manual copy-paste. **The deeper bug: ONE var, TWO identities** — `22-harbor-robot.sh` consumes it as the **admin** (to MINT the robot), `21-mirror-push.sh`/`60-configure-tekton.sh` as the **robot** (to push). 🔴 **The 2026-07-16 corrections — do not re-derive these wrong:** (1) **B14 is lethal ALONE**; commenting it FATALs `make e2e-kind` (SKIP_DOTENV=1) at **`21-mirror-push.sh:36`** — `19-trust-harbor.sh` is in NEITHER `e2e-kind` NOR `install-all`, so **B13 is irrelevant to it**. (2) **`state_set HARBOR_USERNAME` in `05-kind-up.sh` is NOT the fix** — measured, it CLOBBERS a tenant's `.env` from the ungated `.env.state` (sourced later; not snapshot-protected). (3) An adversary argues B14 is **not live as filed** (`.env` beats `.env.example`; `scenario-2.md:87` says "set in .env only") while another calls it deterministic — **the axis is WHICH DOC the tenant follows**: `scenario-1.md:121` says `HARBOR_USERNAME=admin  # or a robot account`. The real defect is **three docs disagreeing**; fix that and both readings resolve. |
| **B15** | `INGRESS_LB_IP` is **published and read back as an input** by ONE remaining reader: `98-verify-ingress.sh:27` takes it with `:?` (`45-install-traefik.sh` / `46-install-istio.sh` `state_set` it). A stale value is indistinguishable from a deliberate override. The fix pattern is already applied in `47-attach-istio.sh:51-52` (`unset INGRESS_LB_IP` + `INGRESS_LB_IP_OVERRIDE`) and cited by `40-install-gitea.sh:59-64` — it just needs back-porting to `98`. |
| **B16** | `98-verify-ingress.sh:11,27,111` still say `.env.kind` in a comment and two operator-facing messages — an unlisted member of the stale-comment class the `d3ba8ec` sweep fixed in `05`/`06`/`44` (`47-attach-istio.sh:42` has it too). |
| **B17** | The doc-truth audit's HIGH/MEDIUM remainder — concentrated in `scenario-2.md`, `prerequisites-manual.md`, and CLAUDE.md gate-list drift. Status table: `docs/reviews/2026-07-14-doc-truth-audit.md` §"Remediation status". |
| **B22** | **PSA defaults live in THREE places** and drift silently: `lib/psa.sh` (`:=` empty), the installers (`${PSA_LEVEL_X:-baseline}` / `:-restricted`), and `.env.example` (uncommented literals). Single-source them in `lib/psa.sh` (`: "${PSA_LEVEL_INGRESS:=baseline}"` …), let every consumer read `$PSA_LEVEL_X` bare, and comment the six `.env.example` lines as `# PSA_LEVEL_X=<default>`. **Do NOT just comment them** — `49-psa-check.sh` reads `${PSA_LEVEL_X:-}` with an **empty** default, so commenting alone silently kills its drift hint ("configured level is X but the namespace carries Y") while the gate stays green. Fixing the triplication is what makes both work. (`PSA_LEVEL_*` is in `check-env-coverage`'s INTERNAL exempt list, so commenting breaks no gate.) Side-effect: the per-run `make X PSA_LEVEL_Y=z` clobber goes away too — today only the **`.env`** path works, and that is the only path any doc prescribes, so this is hardening, **not** a live bug. **(Was B23, resolved 2026-07-16: NO gate change needed — `check-env-coverage.sh:80` matches `^#?[[:space:]]*${v}=`, i.e. it accepts a commented line, and the six PSA lines pass PASS 2 legitimately; the only coupling is the drift hint above.)** |
| **B24** | **Enrich the Istio knowledge of `vks-adversary` and the skills** beyond what the two 2026 community walkthroughs gave us (folded in 2026-07-16: `docs/vks-services/istio.md` §"Field evidence"). Open gaps: **multi-primary multi-cluster has ZERO coverage** (no script, no e2e, no graded fact); the `-n istio-installed` vs `-n tkg-system` variant is unresolved; the gateway-ns PSA minimum is lab-only. The **manifests and the air-gap delta live in `~/projects/claude-config/reference/istio-on-vks.md`** (private — this repo is public, and unrun manifests do not belong in a provenance-graded record). Three things in it are flagged **UNVERIFIED-BY-US** and a lab settles each in one command: whether cert-manager's `cacerts` (`tls.crt`/`tls.key`/`ca.crt`) is even readable by istiod (upstream documents `ca-cert.pem`/`ca-key.pem`/`root-cert.pem`/`cert-chain.pem`); whether `clusterProfile` exists in the VKS package schema (`vcf package available get … --default-values-file-output` dumps it); and the gateway-ns PSA minimum (`make psa-check`). |
| **B25** | **Validate Scenario 1's Istio material end-to-end with the enriched `vks-adversary` — and land it as EXECUTABLE AUTOMATION, not prose.** Every Istio claim in `scenario-1.md` + `istio.md` + the install/attach scripts gets re-judged against the enriched brief and `~/projects/claude-config/reference/istio-on-vks.md`. **The deliverable is code**: each verifiable claim becomes an assertion in `make istio-preflight` / `verify-ingress` / a new gate — not a paragraph. Concrete candidates already identified: assert `server: istio-envoy` on the response (the PATH, not just the body marker); assert the route **PROGRAMMED** into the proxy (`istioctl proxy-config routes …`), not merely `Accepted`; report mTLS mode from `istioctl x describe pod`; assert the mirrored-image alignment for any istioctl-rendered image. Anything that cannot become an assertion goes to `lab-validation-plan.md` as a numbered step with its command, its expected observable, and what to send back — never as a doc sentence. |
| **B26** | 🔴 **Fixes (1)(2)(4) SHIPPED (#295/#296); this row is now fix (3) ONLY.** The pod templates carry `sidecar.istio.io/inject: "false"` (all 4, `check-pod-inject-label` green); `ensure_namespace` stamps `istio-injection=disabled` (`psa.sh:174`); the attach e2e now injects, not simulates the safe case (shipped #296). **Fix (3) UNBUILT:** an **offline `helm template` gate** in `static-check` that renders the carried istiod chart under all 3 configs (base / `enableNamespacesByDefault` / revision-tag) and asserts every webhook rule is defeated by BOTH our ns-label and our pod-label — the RED-proof that survives a chart bump. ⚠️ **Lab-gated residual:** the shipped fixes are upstream **1.30.3**-rendered; VKS ships `1.28.2+vmware.1-vks.1` [community] and Broadcom could patch the injector template. One command settles it: `kubectl get mutatingwebhookconfiguration -o yaml \| grep -A8 namespaceSelector`. |
| **B45** | **The adversary-first gate is scoped to TIME, not CONTENT — so a DOCS commit re-arms it for CODE that was already reviewed.** Hit 2026-07-17 while writing the `psa.sh` mechanism correction (the former B41): a vks-adversary round reviewed that exact correction and delivered; I then committed a docs/handoff change; the gate refused the reviewed code because HEAD was newer than the receipt. Used `ADVERSARY_GATE_OFF=1` on the record (the commit message states why, and the round's three prescriptions are all in that diff). ⚠️ **This is a real residual, NOT a licence to override casually** — the gate's time-scoping is exactly what closes the hole it was built for (#244: a session-lifetime receipt let one design review authorize three tasks' worth of unreviewed implementation). A content-scoped receipt was **REFUTED** on 2026-07-16 and must not be rebuilt (`hooks.md`: the prompt that NAMES the file to review AUTHORISES it; negations authorise too; 34% false-block; it clears the *refuted* design and blocks the *prescribed* fix). Possible narrow fix: exempt a commit whose diff touches ONLY the gate's own EXEMPT_* paths (`.claude/`, `.github/`, `CLAUDE.md`) from re-arming — a docs commit is not new design, and that is checkable from the commit's file list rather than from a prompt. Needs an idea-round: the last two "obvious" control designs here were both refuted, one by its own author. Until then the honest workflow is: batch code changes BETWEEN commits, and if a docs commit strands a fresh review, override ON THE RECORD with the round's verdict cited. |
| **B28** | **The `check-doc-env-quoting` gate, built PROPERLY** (drafted + CUT from #288 at 7/20). The class is real and recurs by construction — a Harbor robot is always `robot$<name>`. Do NOT rebuild the v1 shape. The refuted bypasses, all measured: `$` + **non-letter** (`Passw0rd$1`→`Passw0rd`, `$@ $* $$ $! $?` — **passwords are where `$` lives**); the docs' own `robot$<name>` (5× in `scenario-2.md`; `<name>` parses as a redirect → var UNSET); **every INDENTED** prescription (the anchor traded v1's false-blocks for blindness); backticks; `'robot'$vks'-cicd'` (the single-quote test is a prefix/suffix test). False-BLOCKS on already-correct forms: `robot\$vks-cicd`, `robot'$vks'-cicd`, `"a"'$b'`. And it **could not express its own counter-example** — filing the review that found it would red `static-check`. The prescribed shape (prototyped at 19/20): a **two-stage quote-aware scanner** — (1) does the first value token, respecting quotes, consume the rest of the line? → it is a COMMAND, skip; (2) else walk the value tracking quote state, flag any `$`/`` ` `` outside single quotes and not backslash-escaped. Plus: allow indentation, an `# env-expand-ok:` marker (`KUBECONFIG=$PWD/secrets/x` is LEGITIMATE), and `scripts/test-doc-env-quoting.sh` pinning **all 20 shapes both directions** (18 sibling gates have a test; this had none). Alternative if that is too much: narrow it to `check-doc-robot-quoting`, scanning `robot$` only — ~100% on the class that actually recurs. |
| **B27** | **Harbor's runnable artifact was never saved.** `docs/vks-services/harbor.md` cites a working third-party jump-box transcript (`ogelbric/LAB — Create_Harbor`) as a Source and keeps **ZERO code blocks**, while `argocd.md` keeps 6. The paths we implement are fine — the scripts ARE the artifact, which is better. What is missing is the runnable form of the community-graded rows we do NOT implement and cannot settle without a lab (16/32-char key constraints, `tlsSecretLabels`, the double-base64 CA, same-Supervisor auto-trust). There is a B24 for Istio; there is no equivalent for Harbor. Per `agents.md` §"A research pass that saves GRADED CLAIMS and not the ARTIFACT", it is owed — likely `claude-config/reference/harbor-on-vks.md` (private: third-party-derived and unrun). |
| **B31** | **A `.env` value is read by TWO parsers that disagree — and we now WRITE the shape only one of them likes.** `Makefile:20` does `-include .env`; `load_env` sources it with `set -a`. MEASURED: for the line `HARBOR_USERNAME='robot$vks-cicd'` that `22-harbor-robot.sh` now emits, **bash reads `robot$vks-cicd` (correct) and make reads `'robotks-cicd'`** — quotes LITERAL, `$vks` eaten, and a `#` would truncate. Harmless **today** (no recipe expands `HARBOR_*`), latent for the first one that does, and it violates the repo's own `.env` format rule (`configuration.md`: no quotes, `$$` for a literal `$`). Decide: keep the bash-correct quoting and document that `HARBOR_*` must never be read make-side, or find a shape both parsers agree on (there may not be one — that is the finding). |
| **B32** | **B13 IS MIS-SCOPED — its grep would miss a whole class, and the denominator is worse than anyone said.** MEASURED: **61** vars are `:?`-guarded across `scripts/`; **44 (72%) of those guards are VACUOUS** — 42 because `.env.example` ships the var UNCOMMENTED (B13's class), and **2 because `load_env` unconditionally exports a CODE DEFAULT** (`ARGOCD_NAMESPACE` → `${ARGOCD_NAMESPACE:-argocd}`; `KUBECONFIG` → `${KUBECONFIG:-…/secrets/vks.kubeconfig}`) — a class B13's "grep for uncommented lines" hunt **cannot see**, so it would close 42/44 and read DONE. Widen the detection to BOTH mechanisms. Only **17** guards can actually fire. |
| **B33** | **Loose ends from the 2026-07-17 rounds — (a)(b) DONE, (c)(d)(e) OPEN (verified 2026-07-17 s3).** ✅ (a) the dead `: "${ARGOCD_NAMESPACE:?}"` is gone from `45-install-traefik.sh` (a comment records why). ✅ (b) `90-e2e-istio-existing.sh:257` now uses `ensure_namespace "$PROBE_NS"` (the bare creates at :170/:196 are the deliberate bare-ns CONTROL cells). ⚠️ (c) `22-harbor-robot.sh`'s `mkdir -p` (:144) is still outside the `umask 077` subshell (:148) — the FILE is 0600 (a `rm -f` precedes it) but `secrets/` is 0775; a dirname is not a secret, so minor. 🔴 (d) `scenario-2.md` still restates `robot$<name>` (:87, :283) — reference `secrets/harbor-robot.env`, not the literal (the "credentials in docs must REFERENCE their single source of truth" rule). 🔴 (e) `test-classify-changes.sh` has no `.claude/**` case — a hook / `settings.json` change could route to the docs-only path and skip `static-check`, the one control that enforces RULE ZERO. |
| **B35** | **B26's revision-tag case is NOT covered by the shipped design.** A platform mesh installed with a REVISION TAG renders only **2** webhook rules and **ignores `enableNamespacesByDefault` entirely** (ran-it, upstream 1.30.2) — so a revision-tag e2e would silently stop exercising the hazard. B26's own text names the revision-tag case. Our `istio-injection=disabled` label DOES still defeat the rev-tagged rule (it demands `istio-injection DoesNotExist`), so this is a COVERAGE gap, not a correctness one — but a gate that cannot fire on the revisioned shape must say so rather than imply it. |
| **B18** | The subagent-readonly hook's worktree exemption keys on the **target path**, not the owning agent — a subagent could write into *another* agent's worktree by absolute path. Needs a live `getcwd()` probe from a real `isolation:"worktree"` subagent before a cwd-anchored fix is safe; blunted meanwhile by worktree isolation itself. |
| **B37** | 🔴 **`make red-prove` — a RED-proof must mutate the PRODUCT AS IT SHIPPED, not the code you just wrote.** The rule already exists (`testing.md:281`, *"would this still pass if I deleted the feature?"*; `testing.md:1426`, *"distrust your own RED-TEST"*), was loaded, and was violated anyway on 2026-07-17 — so per the escalation doctrine the deliverable is a GATE, not another paragraph. **The incident:** `test-ensure-namespace-labels.sh` was RED-proven by mutating the `allow-inject` **branch in `psa.sh` that had just been written**, and passed. An adversary then reintroduced the bug **at the call site** (`istio.sh:285`, where #290's defect actually lived) and the gate reported **10/10 ok, rc=0** — blind to the very defect it was named after. I RED-proved the INSTRUMENT, not the DEFECT: the self-authored mutation encodes my own model of the bug, which is exactly what is wrong when the model is wrong. **Design:** run the test against a `git worktree` of `origin/main` with **only the test file transplanted in** (a worktree, NOT `git stash`/`reset --hard` — it cannot touch the working tree, dodging both the data-loss traps), then **diff the per-case verdicts**. The house `ok    <name>` / `FAIL  <name>` format makes that mechanical. A case that does NOT flip `FAIL`→`ok` is a case measuring nothing. ⚠️ **A whole-file red-prove is INSUFFICIENT — I refuted my own first draft in 30 seconds:** any *other* case failing on the pre-change tree turns the file red and masks the blind case (`test-ensure-namespace-labels`'s typo-dies case would have flipped, hiding that the F1 case never did). It MUST be per-case. ⚠️ Applies to **regression** tests only — a test of pre-existing behaviour correctly fails to flip, so the tool must distinguish, or it false-blocks every ordinary unit test. 🔴 **REFUTED a SECOND time — do NOT build the automatic `make red-prove` (idea-round, 2026-07-17 session 2, `adversary-bash-git-cli`, findings VERIFIED against the tree):** **(F1, the killer)** flip-detection measures whether the test's EXISTING cases discriminate baseline↔current — but the incident was a **COVERAGE GAP** (the test asserted "the helper labels" — always true — and never "the installer REACHES the helper", which was the bug). A missing assertion is invisible to a flip-detector, so red-prove would **CERTIFY the exact blind test it is named after** (mutate the helper on baseline → the helper-case flips → "GOOD"). The incident's real remedy is STRUCTURAL and already shipped: `check-namespace-labelled.sh`, keyed on the psa-check inventory ("every namespace we own must be REACHED by an ensure_namespace call") — that is what catches a missing call; a unit-test-flip cannot. **(F2, verified)** a `set -e` house test that sources a helper absent on baseline aborts `rc=1` with **ZERO `ok`/`FAIL` lines** (reproduced in /tmp) — so a loose predicate ("not-ok on baseline") false-PASSES red-prove on a test that never ran, and a strict one ("`FAIL` on baseline") false-BLINDs a good test. **(F3, verified)** `origin/main:scripts/lib/istio.sh:277-279` ALREADY carries the `ensure_namespace` calls — the fix is merged, split across #290/#295/#296/#297, so "baseline = origin/main" finds no bug → false BLIND; there is **no automatic baseline**, and a manually-named one reintroduces the author's-mental-model risk the tool exists to kill. **(F4)** red-prove has no self-check constructible without circularity (the known-blind fixture must be author-fabricated with the same model) → it violates B39, the rule it is filed under. **Conclusion:** the incident class (coverage gap) is **un-gateable by flip-detection** — keep the structural gate (`check-namespace-labelled.sh`, shipped) + B39's per-instrument known-answer discipline, labelled discipline. A NARROWER `red-prove` the adversary sketched (operator-named baseline + explicit `# redcase:` manifest + literal-`FAIL`/literal-`ok` predicate treating any abort as ERROR + a committed known-good/known-blind self-check pair) IS sound but catches a **different, lesser** bug ("a regression test whose declared RED case does not discriminate the pre-fix code") and by the adversary's own verdict **does NOT close this incident** — so it would need its own idea-round before building, not this row. |
| **B39** | 🔴 **AN INSTRUMENT MUST REPRODUCE A KNOWN ANSWER BEFORE I BELIEVE AN UNKNOWN ONE.** The single highest-frequency failure in this repo, and it is ONE failure, not many: *I invent an instrument, trust its output, and it lies.* **Nine times in the 2026-07-17 session alone**, every one already covered by a rule that was loaded at the time: (1-3) `pgrep`/`ps` for live agents **self-matched ×3** — the waiter literally printed *"an agent came back alive"* when the true count was **0**; (4) `for v in $guards` — **zsh does not word-split**, so it ran ONCE and reported 1 vacuous of 44; (5) `RC=$?` inside `$( )` — a subshell, so RC never escaped and two die-cases reported "did NOT die" against code that dies correctly; (6) a `grep 'istio-injection'` that matched **the log message explaining the label**, not the label; (7) a bare `run_case` whose `die` killed the test script itself — 5 cases, no FAIL line, read as a pass; (8) the F1 "verification" that fetched **a doc about a different mechanism**; (9) an F1 gate RED-proven by mutating **the branch just written**, so it was green on its own bug. **The fix is not another rule — prose does not fire at keystroke time.** The repo already contains the answer and keeps not generalising it: the **`scanned 0 → die` denominator guard**, which an adversary said *"earns its place"* because it caught **its own harness bug** (`$S` unexported) before it could report a false result. Generalise it: **every instrument carries a self-check whose answer is already known.** A counter → does it SUM to the total? (28+0≠44 caught the zsh split — the check existed and I skipped it twice.) A detector → does it fire on a known-POSITIVE **and** stay silent on a known-NEGATIVE? A liveness probe → does it report 0 when nothing is running? (5 seconds; it reported 1.) A RED-proof → mutate **`origin/main`**, never the code just written (that is B37). Cheap, mechanical, and unlike a rule it produces a number to check. **NOT BUILT — needs an adversary idea-round** (the last two "obvious" control designs were both refuted, one by its own author). |
| **B40** | **The syntax chokepoint gate (B30a) — DESIGN REFUTED, still unbuilt.** An adversary built and RAN my design against a real corpus: it caught **0 of 8** namespace-creating forms, one **live on the tree** (`hub create namespace` at `e2e-cross-cluster.sh:57`). Namespaces appear here by **SEVEN mechanisms** and a literal-`kubectl` grep sees three: a **wrapper** (`hub`/`guest`/`ka`/`kg` — 6 wrappers across 5 scripts), an **upstream manifest** (tekton's release YAML), a **controller** (ArgoCD `CreateNamespace=true`, from no file at all), a chart's own Namespace, helm `--create-namespace`, an in-tree `kind: Namespace`, and the literal form. **The structural lesson: I enumerated the bypasses with the gate's OWN grep, so the gate could not fail on what the premise missed** — self-confirming, the same shape as the F1 gate one level up. Two concrete bypasses to pin in its test: `echo "# ns-ok: lol"; kubectl create namespace sneaky` **exempts itself** (the raw-line marker check does not parse quotes, and it inflates the `exempt` count); and `${line%%#*}` **false-negatives** on `${#HITS[@]}`, `${v#pfx}`, `grep "#foo"`, and a URL fragment — so do NOT strip comments for detection (a flagged commented-out call is the cheaper error). Refuted hypotheses, do not re-raise: `kubectl create ns foo` and a TAB separator **are** caught; the gap is *internal* whitespace. **`check-namespace-labelled.sh` (shipped) covers the real hazard better** — keyed on the INVENTORY, immune to all six blind spots — so this row is "no NEW bare create appears", a genuine but lesser guard. Needs the 7-mechanism model + a bypass corpus before it is built. |
| **B43** | **THE CROSS MATRIX: {podman,docker} x {photon,ubuntu} x {1-jumpbox dual-homed, 2-jumpbox sneakernet} = 8 cells. No single target runs it, and 2 cells have NEVER run** (owner ask, 2026-07-17). SURVEYED, not recalled: `make jumpbox-matrix` covers the DUAL-HOMED flow's 4 cells ({photon,ubuntu} x {podman,docker}, each pushing to the real Harbor). `make e2e-sneakernet` covers the 2-BOX flow with a real OS axis (`SNEAKERNET_OS`, photon default; `make e2e-sneakernet-both` = photon + ubuntu). So **6 of 8 are covered by two targets that do not know about each other; the gap is sneakernet x docker** — B19 already records that `make e2e-sneakernet CONTAINER_ENGINE=docker` has never run. ⚠️ **Do NOT build the 8-cell grid naively — part of it is VACUOUS BY CONSTRUCTION and a green there would be a lie.** The sneakernet AIR-GAP box is **crane-only and engine-agnostic** (its job is a static binary; `e2e-sneakernet.sh:39` records that both boxes are launched by the HOST's docker regardless of `CONTAINER_ENGINE`), so "sneakernet x docker" does NOT test a docker air-gap box. The only REAL engine delta in that flow is the **INTERNET box's builder `<engine> build` -> `<engine> save` -> `crane push` round-trip**, which `make test-builder-save-crane` already guards in miniature (deliberately NOT in static-check: needs docker + a network registry:2). So the honest deliverable is: (a) a `make e2e-matrix` that runs the cells and prints a GRID with a per-cell verdict; (b) each vacuous cell **named and skipped LOUDLY** (`SKIPPED — the air-gap box is crane-only; this axis is tested by test-builder-save-crane`), never silently passed — a silent skip in a matrix reads as coverage, which is this repo's house failure; (c) close B19 by running the internet-box builder half under docker for real. Print the denominator (cells run / skipped-with-reason / failed) — a matrix that cannot tell you what it did not run is not a matrix. |
| **B38** | **A claim about an upstream ARTIFACT must cite THE ARTIFACT, not prose that uses the same words — candidate gate: an anchor-resolving `[src:]` for upstream code.** 2026-07-17: an adversary claimed the Gateway-API auto-provisioned proxy ships `image: auto`, so `istio-injection=disabled` on `vks-ingress` would break it (filed CRITICAL "F1"). I "verified" it by fetching `istio.io/latest/docs/setup/additional-setup/gateway/`, which says exactly that — **about the `istio/gateway` HELM CHART** (`gateway/templates/deployment.yaml:73`). Our path is istiod's **auto-provisioned template**, `istiod/files/kube-gateway.yaml`: **`image: auto` → 0 hits**, renders `.ProxyImage`, and sets `sidecar.istio.io/inject:"false"` on the pod itself (`:62`) — it is IMMUNE (ran-it, `release-1.30` AND `release-1.28` = what VKS ships, identical). Same sentence, same words, **different mechanism**: I matched the STRING and called it verification, then deleted a TRUE comment from `psa.sh:78-79` and shipped a FALSE one into a control's rationale. Caught only by a second adversary round refuting the first's own prescription. **Candidate gate:** extend `check-vks-provenance`'s citation-resolution to upstream-code claims — `[src:<repo>@<ref>:<path>#<anchor>]`, gate FETCHES the file at the pinned ref and asserts the anchor string is present. It WOULD have caught this instance (the premise was "that file contains `image: auto`"; the fetch returns 0 hits → RED). ⚠️ **Honest limit — it does NOT close the class:** it verifies a citation RESOLVES, never that the INTERPRETATION is right. The interpretive half (*"this file is the template the webhook applies TO a gateway"* — backwards) is a **judgment act and is UN-GATEABLE** (`hooks.md`). Do not report B38 as closing B38's class. The un-gateable residual stays **DISCIPLINE, labelled as discipline**: when a claim names an artifact, the evidence must BE that artifact at a pinned ref — a doc that uses the same words is not the artifact, and neither is an adversary that quotes it. |

**Needs a real lab or a heavy run:**

| ID | Item |
|----|------|
| **B2** | **The Gateway-API CRD version, not its presence.** A VKS 9.1 guest ships the CRDs from the VKr (ON by default, opt-out label), while `istio_ensure_gwapi_crds` server-side-applies our pinned `GATEWAY_API_VERSION` — so we may be fighting the VKS add-on manager. Settle with the `bundle-version` jsonpath + the add-on label. Full grading: `docs/vks-services/istio.md` §4. |
| **B19** | `make e2e-sneakernet CONTAINER_ENGINE=docker` has never been run (the leg is podman-only; the engine axis that matters is the internet box's `<engine> save → crane push`, guarded in miniature by `make test-builder-save-crane`). |
| **B20** | Research whether `vcf context create` accepts a password via **stdin or an env var** (never argv), so the operator does not re-enter it at every `make vks-login` / `make fetch-argocd-kubeconfig`. If not, document `VKS_AUTH_METHOD=vsphere` as the sanctioned store-once path. TODO at `scripts/30-vks-login.sh:68`. |

**The rest of the real-lab unknowns** — the Supervisor topology, the `vcf` auth flow, tenant RBAC into
the ArgoCD namespace, and whether the Supervisor can route to a guest LoadBalancer VIP — are tracked in
[`docs/lab-validation-plan.md`](docs/lab-validation-plan.md), in a better form than a backlog line: each
is a numbered step with its command, its expected observable, and what to send back.
