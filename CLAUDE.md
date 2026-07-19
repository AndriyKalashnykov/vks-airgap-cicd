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
| `make static-check` | Composite offline code gate — the **authoritative** prereq list is the `static-check:` line in the Makefile (alignment + doc/terminology gates + env/app gates + `lint` + `validate` + `sec` + `test-scripts` + `app-test`). Do NOT re-enumerate it here — a hand-typed subset rots on the first Makefile edit. |
| `make sec` | Security scans — authoritative list is the `sec:` line in the Makefile; today `secrets-scan` (= `check-secrets-untracked` + gitleaks + `prose-secrets`) + `trivy-fs` (built-jar deps) + `trivy-config` (manifests) |
| `make app-test` / `app-build` / `app-run` | Build/test **every** app (java: `./mvnw`, go: `go test`/`go build`); one app: `APP=javawebapp\|gowebapp` (`app-run` defaults to javawebapp). Apps are the rows of `apps/registry.tsv`. |
| `make mirror` | (dual-homed) pull images → push to Harbor → **`mirror-verify`** (it is a prereq, not a follow-up: a push you have not verified is not a mirror). **Resumable:** a re-run cache-skips digest-pinned images already fully pulled (`.mirror-ok` sentinel), so an interrupted/CDN-flaky mirror resumes in seconds. `MIRROR_RETRIES` (default 5), `MIRROR_FORCE_PULL=1` |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
| `make mirror-verify` | Verify every mirrored image is INTACT in Harbor (`crane validate` blobs + `images.lock` digest match) — read-only. Runs automatically **inside** `make mirror`; invoke it directly to re-verify an existing mirror |
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
| `make jumpbox` / `jumpbox-both` / `jumpbox-matrix` | Validate the README jump-box bootstrap in a **test** jump-box container (itself needs the internet — it runs `make deps`), joined to the kind network, on `JUMPBOX_OS` × `JUMPBOX_ENGINE` (photon\|ubuntu × podman\|docker; defaults photon+podman): runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` = the OS matrix (podman); `jumpbox-matrix` = the full 4-cell OS×engine matrix. Needs the KinD cluster up **AND a mirrored Harbor** — `jumpbox-matrix` pulls `cicd/maven`, so run `make mirror` first or it fails 4/4 at `engine-trust-check` (auth/trust work; only the un-mirrored base pull fails) |

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

## ▶️ HANDOFF 2026-07-19 (session 4) — READ, THEN REPLACE (do not append)

**ONE handoff section; the next session OVERWRITES it.** Facts → the docs. Tasks → the Backlog.
History → git. Only "what is in flight and what to distrust" belongs here.

**State: both repos GREEN on `main`, trees clean, no branches but `main`, no cluster, no parked
agents.**

### What shipped

Five PRs here (#343–#347) and one in `claude-config` (#52). The session was a single thread:
**extend the vacuity harness from 4 declared gates to 18, and fix what that exposed.**

- **#343** — hardened the harness *before* trusting it to judge: a third `INCONCLUSIVE` verdict, a
  derived coverage count, undeclared gates NAMED, and the blast-radius rule written down.
- **#344** — seven gates that reported `OK` over an EMPTY corpus. Two commits, declarations first,
  so the seven `VACUOUS` lines are recorded in CI rather than asserted.
- **#345** — the `A && B` silent death exists **twice**, and `check-image-alignment` had a blind ARM.
- **#346** (B47) — the end-of-work sentinel nothing had ever read.
- **#347** — the `NS_SPEC` row counter cannot see a literal row; a header certifying coverage it lacks.

**Coverage: 4 → 18 of 21 `check-*.sh`.** The three undeclared are exactly the three the harness
documents as NOT STARVABLE — so every gate that *can* be starved now is.

### 🔴 Distrust these — measured, not reasoned

- **`rc != 0` IS NOT A VERDICT.** A gate can die under starvation for a reason unrelated to its
  denominator. `rc in {126,127}` **or zero output** is INCONCLUSIVE, not a pass. This caught my own
  fix within the hour (below), and a two-verdict harness would have banked it as `ok`.
- **An INCOMPLETE declaration produces a FALSE RED, not a false ok** — the harness *accuses* a
  healthy gate, and the cheapest way to silence that is to weaken the accused gate. Hit twice.
- **A gate is SEVERAL denominators, not one.** `check-image-alignment` has five arms; two were
  vacuous while a third's explicit `gate has gone BLIND` guard made the whole gate *look* covered.
  The current declaration covers **1 of 5 arms** and says so.
- **`harbor` / `argocd` must NOT be added to `NS_SPEC` as `ours`.** Measured: both are deliberately
  passed NO level, psa-check reads an absent label as `restricted`, and psa-check is the FIRST
  prerequisite of `install-all` — the naive fix turns a reporting gap into a broken install.
  Inventing `PSA_LEVEL_HARBOR` is worse (the label would land before `helm install` and can reject
  harbor's own pods; `check-env-coverage` wildcard-exempts `PSA_LEVEL_*` so the var would never be
  required in `.env.example`).
- **A recorded RED-proof that cannot fire is worse than none.** `check-vks-terminology`'s first one
  said "run it from a non-git directory" — that does nothing, because the gate resolves `REPO_ROOT`
  from its own `BASH_SOURCE` and cd's back. The working form COPIES the gate and its lib out.
- **B47's original justification was wrong**: a `|| true` does NOT suppress the sentinel (execution
  continues and it prints). The catchable class is early-exit-with-status-0, nothing wider.
- The `adversary-first-gate` re-arms on every non-exempt commit, so a two-commit sequence prescribed
  BY an adversary re-arms against its own second half. Used the documented override, on the record.

### The two things worth carrying forward

**1. RAN-IT outranks a source-read prediction, including a good one.** The first adversary had
`bash` denied, disclosed it up front, and graded everything `source-read` — and **three of its
predictions were wrong on measurement** (a gate it called vacuous was healthy; one it predicted
would `exit 0` actually died silently at rc=1; one of my own probes was an incomplete starvation).
Every later round had `bash` and measured; those held up. The disclosure is what made the wrong ones
recoverable.

**2. An adversary's PRESCRIPTION is a hypothesis too.** Its fixes were refuted twice: the
`check-vks-terminology` RED-proof above, and a k8s-only starvation pathspec that my own `|| true`
fix silently made incomplete. Verify the patch, not just the finding.

### Next

- **Task: the namespace-inventory remediation (C2/C3/C4)** — fully designed by an adversary, listed
  in the backlog, **gated on one live-cluster measurement**: `make kind-up && make platform`, then
  `kubectl label --dry-run=server ns tekton-pipelines-resolvers pod-security.kubernetes.io/enforce=restricted`.
  Three namespaces (`tekton-pipelines-resolvers`, `argocd`, `harbor`) reach `ensure_namespace` and are
  measured by NEITHER inventory; the drift check is structurally blind because it compares counts.
- **B50** still needs its 404-vs-503 measurement on an air-gap run.
- **B40** — the mechanism inventory is now BUILT and verified (see its row). The gate is still not.
- **LAB-GATED, leave alone:** B2, B20, B24, B25, B27.

## Backlog / resume state

Every item below is the OPEN set, re-verified against the tree — most recently on **2026-07-17
(session 3)**, when **B29, F8, B41, B44, B23, B30, B34 and B42 were REMOVED** because they
shipped/resolved (#295–#297 + #304 + the B42 fix; evidence in each PR + the code), and **B26, B33 were
COLLAPSED** to their open residuals (their done parts dropped). The history that produced these is in git and `docs/reviews/`;
carrying a closed item forward is the class this file was pruned to end.

**Code — no lab needed:**

| ID | Item |
|----|------|
| **B3** | ✅ **DONE 2026-07-18 — the air-gap half now RUNS the runbook's Step 4, and doing so found two real bugs in two runs.** **The gap in one number:** the bundle carries FIVE tools and the air-gap box exercised exactly **ONE** — `crane`. `kubectl`, `helm`, `yq` were carried, installed by `bundle-load`, version-probed by `check-tools`, and then **never used to do anything**; `envsubst` likewise. `make e2e-kind` cannot close that gap — it drives the HOST's mise-installed tools under a GNU userland, not the carried binaries on the far-side OS. So the value is not "the targets work" (e2e-kind proves that) but **"the CARRIED toolchain works, on this OS, from the tarball alone"**. **WHAT RUN 1 FOUND (a real bug, first execution):** `platform` died at `seed-gitea` with `python3: command not found` — `pick_port()` needed python3, which is on neither the Photon image nor the bundle, **and `check-tools` had reported the box FULLY CLEAN seconds earlier because it does not know that dependency exists** (the adding-a-gate-means-adding-its-inputs class). Fixed by making `pick_port` DEGRADE (python3 when present = race-free kernel bind; else probe the ephemeral range, TOCTOU window stated in the code). Adding python3 to the documented OS floor was **rejected**: that floor is what an operator provisions BY HAND on a box with no internet. Verified on bare `photon:5.0`. Then the rest of the contract was DERIVED rather than discovered one 12-min run at a time — probing the real jumpbox image showed python3 is the ONLY binary that is neither carried nor present. **WHAT RUN 2 FOUND (my scoping error, not a product bug):** `platform` and `install-ingress` both PASSED — first time the carried toolchain has ever driven a real install — then `verify-ingress` failed: `gitea.vks.local -> 200`, `tekton.vks.local -> 200` (so the CARRIED helm installed a mesh that genuinely ROUTES), but `javawebapp`/`gowebapp -> 503`, because those backends are deployed by ArgoCD via `gitops`, which is deliberately out of scope. **Feasibility is not the same as "the assertions can pass"** — the idea-round and I both checked network reachability and neither checked the assertion set. `verify-ingress` was REMOVED from the block rather than given a host-subset knob (see **B50**). **SCOPE, deliberate:** `platform` + `install-ingress` + `builder-probe`. `gitops`/`verify` are OUT — both need ArgoCD, which `e2e-sneakernet.sh:112` never installs, so they change the HOST-side setup and roughly triple the leg; their marginal delta over e2e-kind is mostly more `kubectl`, except one genuine thing the probe buys for ~30 s instead of ~10 min. **PROVEN GREEN (3rd run):** `Apache Maven 3.9.16` printed FROM INSIDE the carried builder image — the one artifact whose RUNNABILITY nothing had ever tested (`mirror-verify` and `test-builder-save-crane` prove blob integrity; neither executes the image, so a mangled CONFIG blob survives both and fails later inside a TaskRun). |
| **B50** | 🔵 **THE SKIP DESIGN IS REFUTED (idea-round 2026-07-18, two measured CRITICALs) — but the round produced a BETTER, cheaper replacement that is NOT yet built.** ⛔ **Do NOT make `98-verify-ingress.sh` skip hosts whose backend is absent.** (1) A kubectl predicate **cannot distinguish "backend absent" from "I could not ask"** — measured `rc=1` alike for NotFound, an unreachable API server, AND a bad kubeconfig (which also silently falls back to `http://localhost:8080`, this repo's own C13/B32 hazard). A stale `KUBECONFIG` would make ALL FOUR hosts "absent" → all skip → the gate prints success having checked nothing; on a real lab a tenant lacking get-deployment rights makes Forbidden indistinguishable from NotFound. And it would convert a gate that today needs **only curl** (`:26`) into one requiring cluster API access. (2) **The objects a predicate would key on are created by `install-ingress` ITSELF** — `lib/istio.sh:284,572` `ensure_namespace` per app and `:611` applies the per-app VirtualService unconditionally from the registry — so the namespace and VS ALWAYS exist and discriminate nothing; only Service/Deployment differ, and **Endpoints — the intuitive choice — is wrong in 4 of 6 states because "no endpoints" IS the failure this gate exists to catch**. No workload-keyed predicate gets the ArgoCD-sync-FAILED row right (it looks identical to never-deployed). Also: "fail if ALL were skipped" is theatre here (the air-gap steady state is 2 checked / 2 skipped, so it never fires); the skip would need threading through TWO loops (`:79` route and `:114-119` body); and it would **permanently vacuum two working callers** — `verify-ingress-both` (`Makefile:499-500`) and `e2e-kind-istio-existing` leg 2 (`:522`) run verify-ingress with NO preceding `verify`, so they FAIL loudly and correctly today. 🟢 **BUILD THIS INSTEAD (not yet done): the 503 is EVIDENCE, not an embarrassment.** 503 = Envoy matched a route and resolved a cluster with no healthy endpoints; 404/000 = the route was never configured (this repo says so itself at `98-verify-ingress.sh:140`). So an **ADDITIVE** check in the air-gap leg — leaving `98-verify-ingress.sh` COMPLETELY untouched — asserting gitea+tekton are 2xx/3xx with their body markers AND each app host is **NOT 404, NOT 000, NOT 2xx** proves the carried `yq` appended the app hosts to the Gateway (`lib/istio.sh:588`) and the carried `envsubst`+`kubectl` rendered the per-app VirtualServices (`:611`) — **the carried-toolchain RENDERING path, which nothing currently checks**. Strictly more coverage than the skip, zero blast radius, no kubectl, and it is NOT the rejected host-subset knob because it is a separate check with its own fixed scope that cannot shrink the real gate. ⚠️ **SETTLE ONE THING FIRST — the 404-vs-503 split is graded `inferred`:** on the next air-gap run, `curl` a host with NO VirtualService (e.g. `nosuch.vks.local`) and confirm it is 404/000 while `javawebapp` is 503. If BOTH come back 503, assertion (b) collapses to "not 000" and is much weaker. Also pin the controller: the leg installs istio, and traefik's no-backend status may differ. |
| **B13** | ✅ **DONE (s cont.) — HARBOR_URL COMMENTED in `.env.example`** (the B14 parallel). The "can't comment it — no safe default" objection was REFUTED (adversary idea-round): the "no safe default" is the REASON to comment (an unset value SHOULD `:?`-error with guidance, not silently become a non-resolving placeholder). `06-install-harbor` only WRITES HARBOR_URL (`state_set` the LB IP before any consumer), `load_env` sets no code default, and `harbor.vks.local` is NEVER a working Harbor address (the FQDN-via-`/etc/hosts` variant was superseded — `kind-tls-fidelity.md`) — exactly the HARBOR_USERNAME shape, no helper needed. The ~18 `:?` guards are now non-vacuous; behaviorally inert for the e2e (effective value was always the `.env.state` LB IP). **Impl-round caught a REAL regression** — `env-validate` hard-errored on an empty HARBOR_URL (dead code while `.env.example` shipped the value; activated by commenting); fixed to WARN-skip like KUBECONFIG + the reachability block, `test-env-validate.sh` RED-proves it — plus stale-comment corrections + opportunistic `.env.kind`→`.env.state` in `02-env.sh` (a B32-hygiene miss). **Residual (B — separate, pre-existing, LOW):** whether `harbor_url_is_placeholder` should reject `harbor.vks.local` — a genuine false-block for a self-hosted Harbor literally named `harbor.vks.local`; needs a `<SET-IN-.env>`-shaped sentinel or provenance-keying, unaffected by this fix. |
| **B15** | 🔴 **DISPROVED — do NOT back-port the 47-attach re-resolve into `98-verify-ingress.sh` (vks-adversary idea-round, 2026-07-17 s3; correction now lives in the code comment near `98-verify-ingress.sh:27`).** `98-verify` is a **PURE CONSUMER** of `INGRESS_LB_IP` — it never `state_set`s it (grep-confirmed), so it structurally cannot reproduce the 47 resolve-then-publish-stale false-green. Every caller (`Makefile:421` e2e-kind, `:493-494` verify-ingress-both, `:513/516` istio-existing, `docs/lab-validation-plan.md:561→565`) runs `install-ingress` immediately before `verify-ingress`, republishing the value for the current mode → never stale in any orchestrated/documented path. A stale STANDALONE read is the SAFE direction (a dead IP → loud route FAIL, self-diagnosed at `~98:112`; a false-green would need the "stale" IP to actually route the current hosts to the current backends serving the right markers, i.e. not stale), and the real-lab standalone case is further guarded by `state_check`'s cluster stamp. Back-porting the 47 pattern would DUPLICATE installer logic and depend on `INGRESS_CONTROLLER`, which has the identical read-back class — no net gain. Shipped: the anti-"fix" comment + a published-not-live hint in the failure diagnostic. |
| **B17** | 🔵 **RE-SCOPED 2026-07-18 — as written this row is STALE, and its own audit's "Still open" paragraph is a CLAIM that no longer holds.** Re-verified 39 of the audit's 68 findings against the current tree (all 29 in the named scope): **25 of 29 are FIXED**, 2 were moot. `prerequisites-manual.md` (6/6) and `scenario-2.md` (13/13) are **DONE**. The "CLAUDE.md gate-list drift" half is structurally dead for `static-check` (that row now points at the Makefile as authoritative) and the two rows that HAD rotted — `sec` omitting `check-secrets-untracked`, `mirror` omitting `mirror-verify` — landed in **#320**. **So the named scope is CLOSED.** What survives is a *different*, still-real set of **nine rows found OUTSIDE that scope**, listed in the audit; the highest-value is `docs/scenario-1.md:419` claiming the Istio helm chart still needs internet, which the carried-charts branch in `46-install-istio.sh` and `docs/sneakernet.md:115` both refute — it states a limitation that no longer exists, in the direction a reader will believe. Others: `file(1)` used by `11-bundle.sh:149` but neither installed by `00-install-prereqs.sh` nor gated by `03-check-tools.sh` (HIGH); the scenario-1 SAN `Expect:` line; "install-all starts with mirror" (it starts with `preflight`); the four-vs-three preconditions count; the sneakernet `make deps` rationale; a 12 GB/11 GB bundle-size drift; exFAT listed in both the cannot-use and use-this lists. **All nine landed 2026-07-18** across #322 (the Photon toybox false-die), #323 (six doc rows, two of which an adversary refuted before I wrote them) and #325 (the false rationale inside `test-airgap-toolchain.sh`). **B17 is CLOSED.** |
| **B22** | ✅ **DONE 2026-07-18 — but NOT as this row prescribed; the row's own design was REFUTED TWICE, measured.** ⛔ **Do NOT "single-source them in `lib/psa.sh`" and do NOT make consumers read `$PSA_LEVEL_X` bare.** Round 1 measured that an assign-if-unset moves evaluation from the use site to **SOURCE time**, and the sourcing order is split across the tree (psa.sh-first in 46/47/49/60; load_env-first in 07/40/41/45/70) — so with psa.sh first and an empty value in `.env`, `psa.sh`'s "empty is a no-op" path applies **NO LABEL and returns 0, silently**; on VKS the `ci` namespace then falls back to `restricted` and **Kaniko is REJECTED**. Same `.env`, opposite behaviour depending on sourcing order. Round 2 refuted the repair (`${PSA_LEVEL_CI:-$(psa_level_default ci)}`) twice over: in **argument position a failed command substitution yields EMPTY and `set -e` does NOT fire**, reproducing the same silent no-label; and it is **dead code anyway**, because `load_env` sources `.env.example` unconditionally (`lib/os.sh:337-338`) so the fallback never fires — it would have added a FOURTH copy and gated the live value against it. **WHAT SHIPPED:** the literals stay at the use sites; `lib/psa.sh`'s six `:=` lines are **DELETED** (measured behaviourally inert — all 27 references use a `:-` form, zero bare, so it was never a `set -u` guard); `49-psa-check.sh`'s error message no longer enumerates six key names (it had already rotted — `_TRAEFIK` was missing, so an operator with a traefik finding was handed six names, none of them the right one); and a new **`make check-psa-defaults`** gates that every fallback agrees with `.env.example`, names a real level, and that **no reference hides from it** (a denominator reconciliation: 19 validated + 8 hint-only = 27, all accounted). Round 3 reviewed the GATE and found **three CRITICALs, two of them vacuous greens** — it matched its own die message (RED on a clean tree), its own docstring VOTED on a value (deleting the only real CI use site still passed), and its `[a-z]+` fallback regex silently dropped 7 of 8 realistic forms so a `:-Privileged` shipped green. All fixed; `make test-psa-defaults` pins **12 RED-proofs** including those three. 🔑 **The transferable lesson: a gate that is a script in the tree it scans must not contain the form it looks for** — and the fix is to compose the token at runtime (`printf '${PSA_LEVEL_%s:-%s}'` is invisible to the scan), NOT to exclude the file by name, which would hide every future real finding in it. |
| **B24** | **Enrich the Istio knowledge of `vks-adversary` and the skills** beyond what the two 2026 community walkthroughs gave us (folded in 2026-07-16: `docs/vks-services/istio.md` §"Field evidence"). Open gaps: **multi-primary multi-cluster has ZERO coverage** (no script, no e2e, no graded fact); the `-n istio-installed` vs `-n tkg-system` variant is unresolved; the gateway-ns PSA minimum is lab-only. The **manifests and the air-gap delta live in `~/projects/claude-config/reference/istio-on-vks.md`** (private — this repo is public, and unrun manifests do not belong in a provenance-graded record). Three things in it are flagged **UNVERIFIED-BY-US** and a lab settles each in one command: whether cert-manager's `cacerts` (`tls.crt`/`tls.key`/`ca.crt`) is even readable by istiod (upstream documents `ca-cert.pem`/`ca-key.pem`/`root-cert.pem`/`cert-chain.pem`); whether `clusterProfile` exists in the VKS package schema (`vcf package available get … --default-values-file-output` dumps it); and the gateway-ns PSA minimum (`make psa-check`). |
| **B25** | **Validate Scenario 1's Istio material end-to-end with the enriched `vks-adversary` — and land it as EXECUTABLE AUTOMATION, not prose.** Every Istio claim in `scenario-1.md` + `istio.md` + the install/attach scripts gets re-judged against the enriched brief and `~/projects/claude-config/reference/istio-on-vks.md`. **The deliverable is code**: each verifiable claim becomes an assertion in `make istio-preflight` / `verify-ingress` / a new gate — not a paragraph. Concrete candidates already identified: assert `server: istio-envoy` on the response (the PATH, not just the body marker); assert the route **PROGRAMMED** into the proxy (`istioctl proxy-config routes …`), not merely `Accepted`; report mTLS mode from `istioctl x describe pod`; assert the mirrored-image alignment for any istioctl-rendered image. Anything that cannot become an assertion goes to `lab-validation-plan.md` as a numbered step with its command, its expected observable, and what to send back — never as a doc sentence. |
| **B26** | 🔴 **Fixes (1)(2)(4) SHIPPED (#295/#296); this row is now fix (3) ONLY.** The pod templates carry `sidecar.istio.io/inject: "false"` (all 4, `check-pod-inject-label` green); `ensure_namespace` stamps `istio-injection=disabled` (`psa.sh:174`); the attach e2e now injects, not simulates the safe case (shipped #296). 🔴 **Fix (3) AS SPECIFIED IS REFUTED — `build-a-different-thing` (idea-round 2026-07-18, 28 cells measured with real apimachinery selector semantics). Do NOT build "render the chart and assert every rule is defeated".** The INVARIANT survived scrutiny (the adversary could not refute it): on `istiod-1.30.3.tgz`, base → **4** rules, `enableNamespacesByDefault=true` → **5**, `revision=canary` → **2**, and in every config each rule is defeated **twice over, independently** — by `istio-injection=disabled` on the namespace AND by `sidecar.istio.io/inject="false"` on the pod. **But the GATE built on it is vacuous, and the number that settles it is: ONE NON-ZERO CELL IN TWENTY-EIGHT.** Istio does not inject without a **positive opt-in** (`istio.io/rev In [default]`, `istio-injection In [enabled]`, `inject In [true]`), so an unlabelled namespace satisfies nothing and "every rule is defeated" is satisfied **by the chart, not by us** — delete BOTH our defences and the gate stays **green** on base, as-installed, revision, and revision+ensbd. Only `enableNamespacesByDefault=true` discriminates. **So the proposed RED-proof FALSE-PASSES on the default render**: "drop both labels → must go RED" holds ONLY for `ensbd`; run it on base (the natural thing) and you either "fix" a working gate or conclude it works when it never fired. Two further blockers: `global.operatorManageWebhooks=true` and `global.resourceScope=namespace` render **ZERO** webhooks, so "every rule is defeated" is trivially true over an empty set; and **the gate cannot run in CI at all** — `bundle/` is gitignored (`.gitignore:7`, `git ls-files bundle/` = 0), charts appear only after `10-mirror-pull.sh` (needs the internet), so it would SKIP (the repo's named "passes by not looking") or be permanently red. **Worst of all, its coverage is INVERSE to the hazard:** it renders the chart WE install — where we ALSO set `global.proxy.autoInject=disabled`, a *third* defence rendering `policy: disabled` in the injector ConfigMap — while B26's actual hazard is **attach mode**, where the mesh is VMware's `1.28.2+vmware.1-vks.1` and we render nothing. **IF BUILT, build it as:** (a) assert **DISCRIMINATION**, not defeat — per config compute the verdict *with* and *without* our labels and require they DIFFER, else record that config as "inherently safe, this gate does not measure us here"; (b) **commit the rendered webhook fixtures** (~2 KB, upstream Apache-2.0) so CI evaluates those offline, plus an operator-local drift gate that re-renders when the chart is present; (c) a denominator guard demanding ≥1 MutatingWebhookConfiguration and a per-config minimum rule count; (d) derive the config list from the **template's** `.Values.` references, not a hand list; (e) single-source our label pair from `lib/psa.sh` rather than hardcoding a second copy; and (f) **name it what it is** — a regression gate on the upstream chart we install ourselves, explicitly zero evidence for attach mode or the lab. ⚠️ Also corrected: "the knob is IGNORED on the revision path" is imprecise — it adds no webhook **RULE** there, but still renders into the injector ConfigMap (unreachable when no rule matches). And "defeated twice" is true of the **chart**, false of the **deployment**: `check-pod-inject-label.sh:45` scopes to IN-TREE pod templates, so Harbor/ArgoCD/Tekton/istiod pods carry only the namespace label — do not let the double-coverage framing license weakening the ns label. ⚠️ **Lab-gated residual:** the shipped fixes are upstream **1.30.3**-rendered; VKS ships `1.28.2+vmware.1-vks.1` [community] and Broadcom could patch the injector template. One command settles it: `kubectl get mutatingwebhookconfiguration -o yaml \| grep -A8 namespaceSelector`. |
| **B45** | ✅ **DONE (s cont.) — the re-arm now SKIPS exempt-only commits** (`.claude/hooks/adversary-first-gate.py`). The gate was scoped to TIME, so a DOCS/handoff commit re-armed it for CODE already reviewed (hit twice this session). Fix: `_head_commit_epoch()` → `_last_nonexempt_commit_epoch()` — the `%ct` of the most recent commit touching a NON-EXEMPT path, via `git log -1 --format=%ct -- . ':(exclude)…'` (exclude DERIVED from `EXEMPT_PREFIXES`/`EXEMPT_FILES`, not hand-typed). A commit whose diff is ENTIRELY exempt (`.claude/`/`.github/`/`CLAUDE.md`) no longer re-arms; a guarded OR neither commit still does. **Adversary-vetted (both rounds) that this does NOT re-enter the REFUTED content-scoped-receipt trap:** it keys on git's OWN recorded file-list (which the agent cannot falsify — you can't make git record `scripts/x.sh` as an exempt path), NOT on the review PROMPT. Bypass analysis: no unreviewed guarded code can SHIP (guarded code enters history only via a non-exempt commit = the re-arm event); the residual is a wider WRITE window within a unit, unchanged in KIND. Chose (b): only ALL-exempt commits skip (a NEITHER `.env.example` commit re-arms; fails toward BLOCK). `test-adversary-gate-rearm.sh` RED-proven (revert the call site → the docs-only-ALLOW case fails); docstring updated to the new boundary. |
| **B28** | ✅ **DONE (s3) — shipped the NARROW `check-doc-robot-quoting`** (adversary-bash-git-cli idea+impl rounds). The general env-quoting v1 (cut from #288 at 7/20) was deliberately NOT rebuilt; the narrow `robot$` scope is **complete, not just tractable**: a goharbor robot SECRET is `[a-zA-Z0-9]` (no `$`), so only the USERNAME (`robot$<name>`) carries a `$` — `robot$` is the whole class. Classifier `doc_robot_line_is_bad` is a **pure function in `lib/os.sh`** (so the test EXECUTES it, no bad-form string in a scanned `.md`): flags a shell-assignment line whose value exposes `robot$<letter>` outside a single-quoted span, via an **odd-single-quote-count-before-the-match** span test (a prefix test is not a span test — hooks.md), with the `# env-quote-ok:` marker checked on the RAW line and a trailing-comment strip. Gate `scripts/check-doc-robot-quoting.sh` (thin scanner, denominator + scanned-0 die-guard, `docs/reviews`+`docs/decisions` exempt) scans README + `docs/**` **AND `.env.example`** (the file `load_env` actually sources — scanning only the docs would license false trust in the sourced file; impl-round adversary point), wired into **`docs-lint`** (docs-only PRs skip static-check); `scripts/test-doc-robot-quoting.sh` (both-directions corpus + scanner RED-proof) in `test-scripts`. Accepted residuals documented in `os.sh`: adjacency-break (`'robot'$vks`), `robot$<digit>`/`robot${braced}`, `> KEY=` blockquote-prefixed. Green on the real tree (0 false positives, 22 files); RED-proven; both adversary rounds cleared. |
| **B27** | **Harbor's runnable artifact was never saved.** `docs/vks-services/harbor.md` cites a working third-party jump-box transcript (`ogelbric/LAB — Create_Harbor`) as a Source and keeps **ZERO code blocks**, while `argocd.md` keeps 6. The paths we implement are fine — the scripts ARE the artifact, which is better. What is missing is the runnable form of the community-graded rows we do NOT implement and cannot settle without a lab (16/32-char key constraints, `tlsSecretLabels`, the double-base64 CA, same-Supervisor auto-trust). There is a B24 for Istio; there is no equivalent for Harbor. Per `agents.md` §"A research pass that saves GRADED CLAIMS and not the ARTIFACT", it is owed — likely `claude-config/reference/harbor-on-vks.md` (private: third-party-derived and unrun). |
| **B32** | 🔴 **DISPROVED as a gate (adversary-bash-git-cli idea-round, 2026-07-17 s3). Do NOT build a vacuous-`:?` detector.** The MEASUREMENT holds (~62 `:?` guards; 43 vacuous — 41 uncommented-in-`.env.example` + KUBECONFIG(19 sites)+ARGOCD_NAMESPACE(4) via `load_env` code defaults at `os.sh:406/415`), but **"vacuous" ≠ "harmful"**: the 41 class-A guards each ship a valid, usable default and are **defensive documentation-in-code** — commenting the var out to make the guard fire is a *regression*, deleting the guard loses the assertion, so a hard gate would flag 42 non-defects with no sane remediation → the disabled-gate trap. The ONLY reachable harm is C13 on the KUBECONFIG *read* sites (default is a PATH that may not exist → `:?` proves set-not-present → kubectl silently falls back to `http://localhost:8080`), and it is **LOW** (UX only; no data-loss/fake-green) and **already handled** by `env-check`'s `[ -f ]` (`02-env.sh:130-150`); it only bites on out-of-order/standalone invocation. Shipped (#313): an NB comment at the `os.sh` KUBECONFIG default so no NEW path-valued `load_env` default gets a bare `:?`. **Residual DONE (s3):** an adversary idea-round REFUTED the 16-site sweep (it would regress the read-only preflight ACCUMULATORS `23`/`49`, misfit `71` [already `[ -f ]`s a different file] and `06` [deferred-export]) — narrowed to a `kubeconfig_ready` `[ -f ]` helper in `lib/os.sh` at the 6 standalone-plausible consumers (`40`/`41`/`50`/`60`/`70`/`99`), all producer-first so no false-die in the blessed flows; plus fixed the stale `.env.kind` hint (legacy — nothing writes it) → a producer hint (`make vks-login`/`make kind-up`) at `07`/`45`/`46`/`47`/`48`/`49`. `test-kubeconfig-ready.sh` RED-proves the C13 gate (old bare `:?` passes a missing file; helper dies) + a regression guard that `23`/`49`/`30`/`71`/`06` never call it. |
| **B35** | 🟢 **PREMISE RE-CONFIRMED on 1.30.3, 2026-07-18 (measured offline, `helm template` on the carried chart).** Rule counts: base **4**, `enableNamespacesByDefault=true` **5**, `revision=canary` **2**, `revision=canary`+`enableNamespacesByDefault=true` **2** — the knob is genuinely IGNORED on the revision-tag path. ⚠️ **A doubt was raised and REFUTED by measurement:** `istiod/templates/revision-tags-mwc.yaml:131` *does* contain an `if .Values.sidecarInjectorWebhook.enableNamespacesByDefault` conditional, which reads as if the knob applies — it does not, on the rendered output. Reading the template is not reading the render. (Also worth recording: the first counter I wrote returned **1 for all four configs** — an instrument that gives the same answer for different inputs is broken, not a finding; the pattern was `^  - name:` when webhook entries sit at `^- name:`.) 🔵 **RE-SCOPED 2026-07-18: this is NOT a coverage gap to close — the revision path is INHERENTLY SAFE BY OPT-IN.** Both of its 2 rules require `istio.io/rev In ["canary"]` on the namespace or the pod, and our namespaces never carry that label, so the revision path **structurally cannot exercise the hazard even with zero defences** (measured: 0 undefeated rules with NEITHER label). The original framing — "a revision-tag e2e would silently stop exercising the hazard" — is right about the effect and wrong about the cause: it never could. Record it as inherently-safe, not as a gap. **B26's revision-tag case is NOT covered by the shipped design.** A platform mesh installed with a REVISION TAG renders only **2** webhook rules and **ignores `enableNamespacesByDefault` entirely** — so a revision-tag e2e would silently stop exercising the hazard. B26's own text names the revision-tag case. Our `istio-injection=disabled` label DOES still defeat the rev-tagged rule (it demands `istio-injection DoesNotExist`), so this is a COVERAGE gap, not a correctness one — but a gate that cannot fire on the revisioned shape must say so rather than imply it. |
| **B18** | ✅ **DONE for the FILE TOOLS 2026-07-18** (= `claude-config` HOOK-004, PR #42) — and deliberately NOT marked closed; see the Bash half below. The worktree exemption keyed on the **target path**, so subagent A could write into subagent B's worktree by absolute path. **The blocking unknown was MEASURED, and the technique is the reusable part:** the classifier (correctly) refuses to let an agent write a trace into the live security hook, so instead an **additive, log-only PreToolUse hook** was wired alongside, dispatched against one real `isolation:"worktree"` subagent, read, and removed — it decides nothing and always exits 0. Result: the payload's `cwd` **is** the agent's own worktree (`…/worktrees/agent-<agent_id>`), and it is a better anchor than `os.getcwd()`. The exemption is now CONTAINMENT in the agent's own worktree, `commonpath`-checked, with an identity binding that DEGRADES to containment if the naming convention changes. An adversary refuted two specifics first: a `$`-anchored cwd regex **false-blocks** an agent whose cwd is a SUBDIR of its own worktree, and `startswith(root)` allows a sibling-prefix escape (`agent-a1-EVIL`). RED-proven — reverting flips 5 cases, incl. peer-worktree write going `block=False`. Selftest 270→277; live hook verified on the **deployed** copy, 5/5. **STILL OPEN, and it is the larger half:** the same subagent's **Bash** can still write the caller's tree — `echo >`, `sed -i`, `tee`, `cp`, `truncate`, `rm -rf`, and `>` into a peer worktree are **0 of 8 blocked** (measured). Filed as `claude-config` **HOOK-011** (HIGH), with the enumerated-verb-blocklist direction explicitly refused. Do not infer tree protection from the green file-tool gate. |
| **B37** | 🔴 **`make red-prove` — a RED-proof must mutate the PRODUCT AS IT SHIPPED, not the code you just wrote.** The rule already exists (`testing.md:281`, *"would this still pass if I deleted the feature?"*; `testing.md:1426`, *"distrust your own RED-TEST"*), was loaded, and was violated anyway on 2026-07-17 — so per the escalation doctrine the deliverable is a GATE, not another paragraph. **The incident:** `test-ensure-namespace-labels.sh` was RED-proven by mutating the `allow-inject` **branch in `psa.sh` that had just been written**, and passed. An adversary then reintroduced the bug **at the call site** (`istio.sh:285`, where #290's defect actually lived) and the gate reported **10/10 ok, rc=0** — blind to the very defect it was named after. I RED-proved the INSTRUMENT, not the DEFECT: the self-authored mutation encodes my own model of the bug, which is exactly what is wrong when the model is wrong. **Design:** run the test against a `git worktree` of `origin/main` with **only the test file transplanted in** (a worktree, NOT `git stash`/`reset --hard` — it cannot touch the working tree, dodging both the data-loss traps), then **diff the per-case verdicts**. The house `ok    <name>` / `FAIL  <name>` format makes that mechanical. A case that does NOT flip `FAIL`→`ok` is a case measuring nothing. ⚠️ **A whole-file red-prove is INSUFFICIENT — I refuted my own first draft in 30 seconds:** any *other* case failing on the pre-change tree turns the file red and masks the blind case (`test-ensure-namespace-labels`'s typo-dies case would have flipped, hiding that the F1 case never did). It MUST be per-case. ⚠️ Applies to **regression** tests only — a test of pre-existing behaviour correctly fails to flip, so the tool must distinguish, or it false-blocks every ordinary unit test. 🔴 **REFUTED a SECOND time — do NOT build the automatic `make red-prove` (idea-round, 2026-07-17 session 2, `adversary-bash-git-cli`, findings VERIFIED against the tree):** **(F1, the killer)** flip-detection measures whether the test's EXISTING cases discriminate baseline↔current — but the incident was a **COVERAGE GAP** (the test asserted "the helper labels" — always true — and never "the installer REACHES the helper", which was the bug). A missing assertion is invisible to a flip-detector, so red-prove would **CERTIFY the exact blind test it is named after** (mutate the helper on baseline → the helper-case flips → "GOOD"). The incident's real remedy is STRUCTURAL and already shipped: `check-namespace-labelled.sh`, keyed on the psa-check inventory ("every namespace we own must be REACHED by an ensure_namespace call") — that is what catches a missing call; a unit-test-flip cannot. **(F2, verified)** a `set -e` house test that sources a helper absent on baseline aborts `rc=1` with **ZERO `ok`/`FAIL` lines** (reproduced in /tmp) — so a loose predicate ("not-ok on baseline") false-PASSES red-prove on a test that never ran, and a strict one ("`FAIL` on baseline") false-BLINDs a good test. **(F3, verified)** `origin/main:scripts/lib/istio.sh:277-279` ALREADY carries the `ensure_namespace` calls — the fix is merged, split across #290/#295/#296/#297, so "baseline = origin/main" finds no bug → false BLIND; there is **no automatic baseline**, and a manually-named one reintroduces the author's-mental-model risk the tool exists to kill. **(F4)** red-prove has no self-check constructible without circularity (the known-blind fixture must be author-fabricated with the same model) → it violates B39, the rule it is filed under. **Conclusion:** the incident class (coverage gap) is **un-gateable by flip-detection** — keep the structural gate (`check-namespace-labelled.sh`, shipped) + B39's per-instrument known-answer discipline, labelled discipline. A NARROWER `red-prove` the adversary sketched (operator-named baseline + explicit `# redcase:` manifest + literal-`FAIL`/literal-`ok` predicate treating any abort as ERROR + a committed known-good/known-blind self-check pair) IS sound but catches a **different, lesser** bug ("a regression test whose declared RED case does not discriminate the pre-fix code") and by the adversary's own verdict **does NOT close this incident** — so it would need its own idea-round before building, not this row. |
| **B39** | 🔴 **THE META-GATE IS REFUTED — do NOT build "assert every `check-*.sh` prints a denominator and dies on zero" (idea-round 2026-07-18; the adversary IMPLEMENTED it, ran it against all 21 gates, and measured it **67% accurate — wrong about 7 of 21, in BOTH directions**). It is a FOURTH instance of this row's own class, not a fix for it.** The property that matters is not *"is there a zero-guard"* but **"is the guard on the ITEM count or the FILE count"** — a semantic distinction no regex can see. 🔴 **REPRODUCED INDEPENDENTLY, and it is a live defect:** empty every tracked `.md` (still tracked) and `check-doc-novels` reports `OK — scanned 21 doc(s)` **rc=0**, `check-doc-robot-quoting` reports `OK — scanned 22 file(s)` **rc=0** — healthy denominators over a corpus with **zero content**. `check-doc-make-targets.sh:70` is the cleanest proof: it prints BOTH numbers and emits `0 command(s) across 25 doc(s)` rc=0, and `:40` explicitly `exit 0`s when no docs match. **Filed as B49.** ⚠️ **MY OWN NUMBERS IN THIS ROW WERE WRONG IN BOTH DIRECTIONS, and the error is the row's thesis in miniature:** there are **21** gates not 20; **~17 print a denominator** (not ~10); **10 have a zero-guard** (not 5); only **6** do both on the *meaningful* count. Two of the five I named as "prints a number that gates nothing" are **false** — `check-image-alignment.sh:73` and `check-doc-target-coverage.sh:56` both carry an explicit `the gate has gone BLIND` guard. **I mis-scored `check-image-alignment` BY HAND in exactly the way my classifier had**, i.e. the manual re-check reproduced the instrument's error rather than correcting it. **THE BUILDABLE THING IS NARROWER AND MUST BE CALLED WHAT IT IS: a VACUITY HARNESS for committed gates, via CORPUS STARVATION** — empty each gate's corpus in a throwaway tree and assert rc≠0. It caught the three blind gates the static version *certified*, runs ~30 s for 21 gates, and **cannot be satisfied by `echo "checked 1"`**. Its self-check is non-circular (a committed blind/good fixture pair with a known answer — unlike B37, where the fixture had to encode my own model of the defect). Its own residual: the per-gate corpus declaration is an **enumerated list that will rot**, and a wrong declaration makes the starvation test vacuous — the same class one level up. **THE ORIGINAL INCIDENT CLASS STAYS DISCIPLINE, labelled as discipline:** all three motivating failures were **throwaway instruments in a shell**, which no repo gate can ever see. The discipline is: *an instrument must be shown to DISCRIMINATE before its output is believed* — run it on ≥2 inputs known to differ and confirm the outputs differ. It would have caught the webhook counter instantly (1,1,1,1). **A fourth instance occurred while verifying THIS row**: `bash gate \| tail -2; echo rc=$?` reported `tail`'s status, not the gate's. |
| **B49** | ✅ **DONE — extended 2026-07-19 from 4 declared gates to 18 of 21; EIGHT more were measured VACUOUS.** ⚠️ **The 2026-07-18 entry below said "both gates fixed" — but B39 named THREE, and the third (`check-doc-make-targets`, which B39 called "the cleanest proof") was still blind a day later.** It is fixed now, along with seven others, in #344/#345. The original entry follows, corrected in place: ✅ **DONE 2026-07-18 — two gates fixed and RED-proven, and a starvation harness now guards the CLASS.** The defect was real: `check-doc-novels` and `check-doc-robot-quoting` each reported `OK — scanned N` with **rc=0 over a corpus of EMPTY files**, because their zero-guards counted **files OPENED** while the **ITEM** count carrying the verdict was zero. Fixed by counting and guarding the items — blockquote BLOCKS examined (48 on the real corpus) and LINES examined (4448) — so the success line now states what was judged, not merely what was opened. ⚠️ **A correction to how this was found:** my first starvation emptied only `*.md`, and `check-doc-robot-quoting`'s corpus also includes `.env.example`, so it kept 995 real lines and passed **legitimately** — for a moment that looked like my fix had failed. Re-run with the corpus FULLY starved, the **unfixed** gate passed `rc=0` (so the finding held) and the fixed one dies. **An incomplete starvation is indistinguishable from a healthy gate** — that is the harness's own failure mode, now written into it. **`make test-gate-vacuity`** starves each declared corpus and requires rc≠0; it carries a **non-circular self-check** (a committed blind/good fixture pair whose verdict is known without reference to any real gate) and **prints its coverage honestly** (now **18 of 21**, and the three undeclared are exactly the three it documents as NOT STARVABLE). ⚠️ **That fraction is of `check-*.sh` SCRIPTS, not of "gates"** — `static-check`/`docs-lint`/`sec` also run five inline Makefile recipes plus `lint.sh`, `validate.sh`, `trivy-fs.sh` and `diagrams-check`, none of which are counted. This file restated it as "4 of 21 gates" twice, overstating coverage; the harness now says SCRIPTS in its own output.. Its own two design bugs were caught by running it: it tested `git archive HEAD` rather than the working tree (so it quoted the pre-fix message of a gate I had just fixed), and one case starved `scripts/*.sh`, which **empties the gate under test** — bash then runs an empty file and exits 0, which the harness would have reported as VACUOUS when the gate never ran. |
| **B40** | **The syntax chokepoint gate (B30a) — DESIGN REFUTED, still unbuilt.** An adversary built and RAN my design against a real corpus: it caught **0 of 8** namespace-creating forms, one **live on the tree** (`hub create namespace` at `e2e-cross-cluster.sh:57`). Namespaces appear here by **SEVEN mechanisms** and a literal-`kubectl` grep sees three: a **wrapper** (`hub`/`guest`/`ka`/`kg` — 6 wrappers across 5 scripts), an **upstream manifest** (tekton's release YAML), a **controller** (ArgoCD `CreateNamespace=true`, from no file at all), a chart's own Namespace, helm `--create-namespace`, an in-tree `kind: Namespace`, and the literal form. **The structural lesson: I enumerated the bypasses with the gate's OWN grep, so the gate could not fail on what the premise missed** — self-confirming, the same shape as the F1 gate one level up. Two concrete bypasses to pin in its test: `echo "# ns-ok: lol"; kubectl create namespace sneaky` **exempts itself** (the raw-line marker check does not parse quotes, and it inflates the `exempt` count); and `${line%%#*}` **false-negatives** on `${#HITS[@]}`, `${v#pfx}`, `grep "#foo"`, and a URL fragment — so do NOT strip comments for detection (a flagged commented-out call is the cheaper error). Refuted hypotheses, do not re-raise: `kubectl create ns foo` and a TAB separator **are** caught; the gap is *internal* whitespace. **`check-namespace-labelled.sh` (shipped) covers the real hazard better** — keyed on the INVENTORY, immune to all six blind spots — so this row is "no NEW bare create appears", a genuine but lesser guard. Needs the 7-mechanism model + a bypass corpus before it is built. 🟢 **THE MECHANISM MODEL IS NOW BUILT AND VERIFIED (2026-07-19), and it corrects this row twice.** There are **TEN** mechanisms, not seven, and two of the seven named above **do not exist on the tree**: M1 literal `kubectl create namespace` (3 sites); M2 a kubectl WRAPPER (`e2e-cross-cluster.sh:57` `hub create namespace`); **M3 an in-tree `kind: Namespace` — ZERO, verified, only two comments asserting its deliberate absence**; M4 an upstream manifest we apply (tekton ONLY — gateway-api, tekton-triggers/dashboard and ArgoCD's install.yaml carry none); M5 `helm --create-namespace` (5 sites); **M6 a chart shipping its own Namespace — none in any chart readable offline, and the Harbor chart is pulled at install time so it is UNKNOWN, not absent**; M7 ArgoCD `CreateNamespace=true`; **M8 `ensure_namespace` itself, the repo-local chokepoint**; **M9 `envsubst \| kubectl apply -f -`**; **M10 heredoc `kubectl apply -f - <<EOF` (7 sites)**. Wrapper count corrected: **7 wrappers across 4 scripts** (not 6 across 5), PLUS the universal `run()` at `lib/os.sh:662` — so a gate anchored on `^kubectl` misses all of them. ⛔ **M4 and M6 are PERMANENTLY INVISIBLE TO CI**: they live in `bundle/`, which is gitignored (`git ls-files bundle/` = **0**), so a gate that greps there in CI scans an empty directory and passes vacuously — this repo's named "passes by not looking". Any B40 gate must declare M4/M6 out-of-scope-by-construction rather than claim coverage. **The research also found a live defect worth more than the gate** — see the namespace-inventory row below. |
| **B43** | 🔵 **REFUTED as specified 2026-07-18 — do NOT build `make e2e-matrix` as an 8-cell grid.** An idea-round adversary measured the topology and the "{podman,docker} × {photon,ubuntu} × {dual-homed,sneakernet} = 8 cells" framing is a **category error**: the axes are not orthogonal. Dual-homed runs the engine **on the box under test** → a real 2×2. Sneakernet's engine is a **host-side** property (one machine, shared by both OS legs) → 2 OS legs × 1 engine choice. The cube does not exist. **Proven, not inferred:** the air-gap half of `jumpbox-run.sh` runs `check-tools`→`bundle-load`→`mirror-push`→`builder-push`→`mirror-verify` and then **`exit 0` at :152**; every `"$ENGINE"` invocation and `engine-trust-check` is *after* that line, so `JUMPBOX_ENGINE=docker` on a sneakernet leg executes **zero additional lines** (`22-builder-push.sh:7-9`: "THIS BOX NEEDS NO CONTAINER ENGINE"). The honest artifact is **6 invocations / 8 legs / 3 groups**, not 8 runs — `SNEAKERNET_OS ?= photon ubuntu` already runs both OS legs in ONE invocation. **The proposed "loud SKIP for vacuous cells" was refuted too**, and this is the subtle part: announcing a cell that does not exist manufactures a known-gap and invites a future session to "close" it by building the vacuous leg — the exact outcome this row was written to prevent. Group by what the axis MEANS instead; the headers are the explanation. **Landed from this review:** `jumpbox-matrix`'s verdict is now COMPUTED (it printed a hardcoded `4/4 PASSED` while tracking only `rc` — narrow the axes to one OS and it still said 4/4; the repo's own "the measured column must be MEASURED" failure, in the summary line of its own matrix), and the retired compressor justification is recorded rather than left to rot. **Still open, and it is a QUESTION FOR THE OWNER, not a judgement call:** B19 (the sneakernet builder half under docker) is on the handoff's LAB-GATED leave-alone list, but it needs **docker + KinD, not a VKS lab** — it may be mislabeled. If it is genuinely open, closing it is **one command** (`make e2e-sneakernet CONTAINER_ENGINE=docker`, ~40 min, destroys and recreates the cluster per leg), not a driver. **Also note:** `e2e-sneakernet`'s EXIT trap runs `kind-down` **on success too**, so any matrix leaves a bare box; and B43 would make **B3** twice as expensive, since B3's Step-4 content is engine-irrelevant — land B3 first. |
| **B38** | **A claim about an upstream ARTIFACT must cite THE ARTIFACT, not prose that uses the same words — candidate gate: an anchor-resolving `[src:]` for upstream code.** 2026-07-17: an adversary claimed the Gateway-API auto-provisioned proxy ships `image: auto`, so `istio-injection=disabled` on `vks-ingress` would break it (filed CRITICAL "F1"). I "verified" it by fetching `istio.io/latest/docs/setup/additional-setup/gateway/`, which says exactly that — **about the `istio/gateway` HELM CHART** (`gateway/templates/deployment.yaml:73`). Our path is istiod's **auto-provisioned template**, `istiod/files/kube-gateway.yaml`: **`image: auto` → 0 hits**, renders `.ProxyImage`, and sets `sidecar.istio.io/inject:"false"` on the pod itself (`:62`) — it is IMMUNE (ran-it, `release-1.30` AND `release-1.28` = what VKS ships, identical). Same sentence, same words, **different mechanism**: I matched the STRING and called it verification, then deleted a TRUE comment from `psa.sh:78-79` and shipped a FALSE one into a control's rationale. Caught only by a second adversary round refuting the first's own prescription. 🔴 **THE CANDIDATE GATE IS REFUTED — do NOT build it (idea-round, 2026-07-18, every finding `ran-it`).** This row used to say a fetch-and-assert-anchor gate "WOULD have caught this instance". **That is measurably FALSE, and it is the most important correction in this row.** The false CRITICAL cited `istio/gateway`'s `templates/deployment.yaml`, and `image: auto` **is** at line 73 of that file (`grep -c` = 1) — so the citation **RESOLVES** and the gate goes **GREEN on the exact incident it was designed to catch**. Worse than useless: it would **launder a false CRITICAL into a cited one**, which is the manufactured-confidence failure. Two structural reasons it can never work: (1) the claim was never wrong about the STRING, only about **which chart is our path** — an interpretive error no resolver can see; (2) the fact that IS true is a **NEGATIVE** ("`kube-gateway.yaml` contains ZERO `image: auto`", confirmed upstream), and a presence-asserting gate is structurally incapable of expressing an absence. Also fatal in practice: the token's own extractor (`check-vks-provenance.sh:43`, `\[src:[^]]*\]`) **truncates at the first `]`**, so the most discriminating anchors in this domain — the injector selectors, literally `inject NotIn ['false']` — cannot be expressed and RED with a diagnostic naming the wrong cause (**the same shape as B28, second occurrence**); and the gate would **fail OPEN** on any network blip because the script is `set -uo pipefail` with no `-e`. **DO THIS INSTEAD (the fourth option, already working in-tree): when an upstream fact is load-bearing, do NOT cite it — assert its CONSEQUENCE offline over OUR OWN artifacts.** `check-pod-inject-label.sh` is the model: it parses our in-tree pod templates rather than citing istio's chart, so it fails on the thing that actually hurts us regardless of what any upstream file says. B38 therefore stays open as a **DISCIPLINE row, not a gate row**. ⚠️ **Honest limit — it does NOT close the class:** it verifies a citation RESOLVES, never that the INTERPRETATION is right. The interpretive half (*"this file is the template the webhook applies TO a gateway"* — backwards) is a **judgment act and is UN-GATEABLE** (`hooks.md`). Do not report B38 as closing B38's class. The un-gateable residual stays **DISCIPLINE, labelled as discipline**: when a claim names an artifact, the evidence must BE that artifact at a pinned ref — a doc that uses the same words is not the artifact, and neither is an adversary that quotes it. |

| **B51** | 🔵 **THREE namespaces reach `ensure_namespace` and are measured by NEITHER inventory, and the drift check is STRUCTURALLY BLIND to that** — found while building B40's mechanism model, verified directly. `tekton-pipelines-resolvers` (`41-install-tekton.sh:90`), `argocd` (`07:78`) and `harbor` (`06:151`) are absent from both `49-psa-check.sh`'s `NS_SPEC` and `check-namespace-labelled.sh`'s `OWNED`. The drift check compares `owned_rows + 2` against `spec_rows`, so a namespace missing from **both** keeps the arithmetic balanced — and comparing the two inventories as SETS would not help either; only a **third, independent ground truth** (the `ensure_namespace` call sites) can see it. Sharpest detail: the gate's own die message cites `tekton-pipelines-resolvers` as the precedent for why the inventories must agree, and it is still in neither. ✅ **SHIPPED in #347:** the counter now sees a LITERAL row (it could not, so adding the very row the header asks for would have made the drift check DIE on a correct change — measured 7 vs 8), and the header's false "It is now listed" is corrected. ⛔ **DO NOT "just add all three to both inventories" — that was REFUTED by measurement and is worse than the bug.** `harbor`/`argocd` are deliberately passed NO level by `ensure_namespace`; `psa-check` reads an absent label as `restricted`; both charts are documented as not restricted-clean — so adding them as `ours` makes `psa-check` rc=1, and `psa-check` is the FIRST prerequisite of `install-all`, converting a reporting gap into a **broken install**. Inventing `PSA_LEVEL_HARBOR` is worse still: the label would then land BEFORE `helm upgrade --install` and could reject harbor's own pods at admission, and `check-env-coverage`'s `INTERNAL` list wildcard-exempts `PSA_LEVEL_*` so the new var would never be required in `.env.example` — a trap `07-install-argocd.sh:70-73` already documents. 🟢 **THE DESIGNED REMEDIATION (adversary-vetted, NOT yet built):** **C2** add an ownership column (`ns\|level\|ownership`, `ours\|mesh\|kind-only`) routing platform-owned namespaces through the EXISTING `ours=0` informational branch — this also deletes the `+2` magic constant; **C3** add `tekton-pipelines-resolvers` as `ours` with a **literal-matching** `OWNED` form (do NOT invent `TEKTON_RESOLVERS_NAMESPACE` to satisfy a regex — that would need four coordinated edits including a call-site rewrite); **C4** add the derived call-site cross-check as a **THIRD** assertion, never a replacement — deriving `OWNED` makes the gate tautological and would un-catch the very F2 regression it was written for, and only **12 of 19** call sites are statically resolvable (7 are loop/local vars, two of them ephemeral e2e fixtures that must never enter `NS_SPEC`), so it must PRINT the 7 it cannot resolve with a reason each. ⚠️ **C3 is gated on one live-cluster measurement**: `make kind-up && make platform`, then `kubectl label --dry-run=server ns tekton-pipelines-resolvers pod-security.kubernetes.io/enforce=restricted`. Expect `preflight` may go red once — that red is a TRUE finding about an already-shipped label, and the fix is the level, not backing out the row. |
| **B47** | ✅ **DONE 2026-07-19 (#346).** **`JUMPBOX_SNEAKERNET_OK` is echoed and NEVER read — a marker implying a check that does not exist.** `scripts/jumpbox-run.sh:151` prints it at the end of the air-gap half; `grep -rn JUMPBOX_SNEAKERNET_OK scripts/ Makefile` returns **exactly that one hit** (verified 2026-07-18). It is honest TODAY only because `jumpbox-run.sh` runs `set -euo pipefail` (`:12`) and `jumpbox-launch.sh:97` `exec`s `docker run`, so a failing step aborts and propagates as the container exit code. But the end-of-work sentinel is unasserted, so the day someone adds a `|| true` or a subshell to the air-gap half, the one signal that would have caught it is unread — a latent fake-green in the exact shape this repo keeps getting bitten by. Fix: either have `jumpbox-launch.sh` tee the container output and assert the marker, or DELETE the marker so it stops implying a check. (Found by the B19 idea-round adversary, confirmed by my own grep.) |
| **B48** | ✅ **DONE 2026-07-18 — dropped the no-op `return $rc` from `e2e-sneakernet.sh`'s EXIT trap and recorded the MEASURED semantics in its place.** The claim was inherited as `inferred` (bash semantics from memory), so it was measured before acting — and the measurement is **stronger** than the claim: trap body `return $rc` → rc **7**; `return 0` → **still 7** (returning 0 does *not* mask a failure either); only `exit 3` → **3**. So the real hazard is not `return` at all — it is an **`exit` inside an EXIT trap**, which silently overrides a real failure with the teardown's status. The comment now says that, so the next reader copying the idiom learns the right lesson rather than the reassuring one. |
**Needs a real lab or a heavy run:**

| ID | Item |
|----|------|
| **B2** | **The Gateway-API CRD version, not its presence.** A VKS 9.1 guest ships the CRDs from the VKr (ON by default, opt-out label), while `istio_ensure_gwapi_crds` server-side-applies our pinned `GATEWAY_API_VERSION` — so we may be fighting the VKS add-on manager. Settle with the `bundle-version` jsonpath + the add-on label. Full grading: `docs/vks-services/istio.md` §4. |
| **B19** | ✅ **DONE 2026-07-18 — RAN GREEN.** `make e2e-sneakernet CONTAINER_ENGINE=docker SNEAKERNET_OS=photon`, rc=0 in ~8 min. **What is now proven** (worded to the evidence, do NOT upgrade this): a builder image produced by `docker build` + `docker save` on the internet box — the REAL, large, digest-pinned `Dockerfile.builder` with a baked `~/.m2`, not a fixture — travelled inside the 12 G bundle tar and was pushed into a fresh TLS Harbor by the **carried crane** on a photon air-gap box **with no container engine**, then `crane validate --remote`'d intact (`javawebapp-builder:0.3.0` → `sha256:da1a1ac5…`). `mirror-verify` independently: **36/36 intact, 0 provenance warnings**. This does **not** prove the dual-homed docker path, and does not prove Step 4 (see B3). **The ubuntu leg was skipped DELIBERATELY and it is NOT missing coverage:** `make builder-build` runs at `e2e-sneakernet.sh:86`, **before** the `for os in $SNEAKERNET_OS` loop at `:102`, so both legs consume the SAME docker-produced tarball — leg 2 contributes **zero** engine evidence (it re-tests the OS axis, already covered by every prior podman run). The old row's "that ONE invocation covers both remaining cells" was **wrong**, refuted by an idea-round adversary before the run; the correction is now a rule (`rules/common/testing.md`, "a REAL axis can still have a VACUOUS loop"). 🔴 **The run also REFUTED a claim in `test-builder-save-crane.sh`** — see B46. |
| **B46** | ✅ **CLOSED 2026-07-18 — DECLINED ON EVIDENCE by the owner. Do not re-open without a new reason; the alternatives are measured and two of them do not work.** The finding is real: for identical content, `podman save` emits **623,348,736 B** (docker-archive v1, layers **plain tar**) while `docker save` 29.6.2 emits **286,969,856 B** (**oci-layout + `index.json` + a compat `manifest.json`**, layers **gzip**) — **2.17×**. **The number that decided it:** the saving is **338 MB against a ~12 GB bundle = 2.8% of the carry** (the builder tarball is only 5.2% of the bundle to begin with). Both ways of capturing it add a moving part to the **air-gap path**, which is the one place a failure is most expensive, so the trade was declined. **Options measured, for the record:** (a) `podman save --format oci-archive` → 297,119,232 B but **`crane push` REJECTS it** — `Error: loading …: file manifest.json not found in tar`; docker's archive only works because it is a **hybrid** carrying the compat `manifest.json` alongside the OCI layout. (b) `podman save --compress` → **not supported** for docker-archive (fails). (c) gzip the podman tarball → **285,575,559 B** (i.e. ~97% of docker's win, podman retained) but requires a `gunzip` step + transient disk in `22-builder-push.sh` **on the air-gap box**. (d) prefer docker in `14-builder-build.sh` → 287 MB with no decompress step, but the artifact's shape then depends on which engine the internet box happens to have, and it pushes against the **"docker is opt-in, never required"** invariant that `test-container-engine.sh` check 7 enforces. ⚠️ **The genuinely useful half of this row is NOT the size** — it is that `test-builder-save-crane.sh`'s honesty block claimed both engines default to the SAME format and **that was false**; the claim survived because a successful `crane push` proves crane handles **both** and says nothing about them being the **same**. The discriminating command was `tar tf`. That correction is already in the script's header and in `rules/common/testing.md`. |
| **B20** | Research whether `vcf context create` accepts a password via **stdin or an env var** (never argv), so the operator does not re-enter it at every `make vks-login` / `make fetch-argocd-kubeconfig`. If not, document `VKS_AUTH_METHOD=vsphere` as the sanctioned store-once path. TODO at `scripts/30-vks-login.sh:68`. |

**The rest of the real-lab unknowns** — the Supervisor topology, the `vcf` auth flow, tenant RBAC into
the ArgoCD namespace, and whether the Supervisor can route to a guest LoadBalancer VIP — are tracked in
[`docs/lab-validation-plan.md`](docs/lab-validation-plan.md), in a better form than a backlog line: each
is a numbered step with its command, its expected observable, and what to send back.
