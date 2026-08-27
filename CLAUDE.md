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
| 3 | **BEFORE you call the session done** | the stopping rule — no session is DONE without it. **Also run `make handoff-status`** here: it prints what merged since the handoff was last edited, and a handoff written before the last merge is stale by construction. Measured: at session START it reads 0 (the previous session wrote it as its last act); at the moment this repo's handoff was actually stale it read **31**. | the findings are part of the deliverable |

Triggers 1 and 2 collapse into one run when the session opens on a known task (brief it with the
backlog **and** the design). What is NOT acceptable is starting work with no adversary running.

**Trigger 2 IS NOW A HOOK, because prose did not hold — it was skipped on 2026-07-14 by the very
session that had just re-read it.** `.claude/hooks/adversary-first-gate.py` (wired in
`.claude/settings.json`) **BLOCKS `Edit`/`Write`** until an adversary has run. Read the truth from its
own constants, not from prose. There are **FOUR**, and reading only the obvious pair is a measured
trap: `GUARDED_PREFIXES`, **`GUARDED_FILES`**, `EXEMPT_PREFIXES`, `EXEMPT_FILES`. On 2026-08-24 a
session hand-typed the first, third and fourth into an AST reader, missed `GUARDED_FILES =
("Makefile",)`, and concluded the Makefile was ungated — it is guarded, at line 215's
`rel.startswith(GUARDED_PREFIXES) or rel in GUARDED_FILES`.

⚠️ **A value table used to sit here and was DELETED on 2026-08-24, deliberately.** It was a prose
duplicate of an in-repo constant — exactly the class the sentence above forbids — and it had already
drifted once (`tekton/`). Do not reinstate it; a gate to police it was designed, prototyped and
**REFUTED at 50% false-RED**, with two of the five false-REDs being documentation *improvements*.
The authoritative answer is the hook's own verdict: feed it a `Write` payload for the path and read
the rc (**2 = guarded, 0 = ungated**). The exemptions exist so the plan/backlog can always be
written down first.

⚠️ **Two corrections, 2026-08-16.** `tekton/` was in GUARDED and was **dead**: `git ls-files tekton`
= 0; the manifests are at `k8s/tekton/` (9 files), already covered by `k8s/`. And `BACKLOG.md` was
in NEITHER list, so a bookkeeping commit ("close row B92") re-armed the gate and destroyed a valid
review — the exemption had tracked the FILE (`CLAUDE.md`) rather than the ROLE, and the backlog
moved out in f7f6c30 (2026-07-22) without it. Measured: 24 of the last 200 commits are BACKLOG-only.
It is **not** a bypass — a git exclude pathspec is per-FILE, so a MIXED commit still re-arms
(`test-adversary-gate-rearm.sh` now pins both directions).
🔴 **Known and NOT fixed:** `.env.example` (touched in **21 of the last 200 commits** — measured at `cd542ff` 2026-08-24; it
read **29** at `0fdd6ac` on 2026-08-16, i.e. this very figure rots ~28% in a week, so re-measure
before quoting it — and this file
calls it *"the single source of truth for every tunable"*), `.mise.toml`, `images/`, `deploy/`,
`kind/`, `.gitleaks.toml`, `.trivyignore` and the 155-line `bootstrap-jumpbox.sh` are in NEITHER
tuple — writable with **zero** review. Guarding them is a new control design and needs its own
idea-round. **The false-block cost was measured 2026-08-24 and is ~15x SMALLER than the ~15% this
line used to claim: 2 of 200 commits (1%).** Of the 21 commits touching `.env.example`, **19 are
MIXED with an already-guarded path**, so the session had to engage an adversary anyway and a new
guard adds nothing; only 2 are `.env.example`-without-any-guarded-path. That makes this cheaper than
it looked — and correspondingly lower value.

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

### RULE ZERO-A0 — TO REACH ANYTHING IN THE LAB, USE THE REPO'S TARGET. NEVER HAND-ROLL A PROBE (BLOCKING)

This repo already contains a purpose-built, measured tool for every lab question you will have. Every
time a session hand-rolls `curl`/`kubectl`/`crane` at the lab instead, it re-derives a wrong answer —
and this has recurred for WEEKS. The tools are not optional and they are not a fallback.

**START HERE, ALWAYS:** `make preflight` (read-only composite: check-tools · engine-check · env-check
· argocd-preflight · lab-preflight · psa-check) and `make env-validate` (format + KUBECONFIG + Harbor
connectivity AND auth). Between them they answer "can this lab do the thing" in two commands.

⚠️ **THE COMMON CASE IS A LAB WE DO NOT OWN.** Most of the time this repo runs as a **TENANT**
(Scenario 2): Harbor and ArgoCD already exist, we have **NO Supervisor access**, and everything we
know arrives as **variables in `.env`** that a platform team hands us. So the FIRST question about
any recovery step is *"does this work from `.env` alone?"* — a target that reads a Supervisor secret
is unavailable to the audience that needs it most, and telling a tenant to run one is a dead end.

| you want | the target | tenant-safe? |
|---|---|---|
| is Harbor serving? | `make harbor-reachable` | ✅ from `.env` |
| does my Harbor credential WORK? | `make env-validate` | ✅ from `.env` |
| make my engine trust Harbor | `make trust-harbor` (proves it with a real login handshake) | ✅ from `.env` |
| does the ArgoCD credential work? | `make argocd-auth-check` | ✅ from `.env` |
| ArgoCD versions / topology | `make argocd-version` · `make argocd-preflight` | ✅ from `.env` |
| endpoints + logins for the CURRENT context | `make creds-show` | ✅ from `.env` |
| would our pods be admitted? | `make psa-check` | ✅ guest kubeconfig |
| does the guest trust our Harbor? | `make vks-trust-probe` | ✅ guest kubeconfig |
| a push/pull credential | `make harbor-robot` | ⚠️ needs Harbor **project-admin** — a tenant without it must REQUEST robot credentials |
| recover the admin credential | `make harbor-admin-password` | ❌ **SUPERVISOR ONLY** |
| the Harbor CA when it is not on the wire | `make harbor-ca-from-cluster` | ❌ **SUPERVISOR ONLY** (`make fetch-harbor-ca` is the tenant path — it reads the wire) |
| ArgoCD's LB address | `make argocd-address` | ❌ **SUPERVISOR ONLY** |
| the Supervisor kubeconfig for ArgoCD | `make fetch-argocd-kubeconfig` | ❌ **SUPERVISOR ONLY** |

**A TENANT WHOSE CREDENTIAL IS STALE CANNOT RECOVER IT — they must REQUEST a new one.** There is no
self-service path, and no target will invent one. `make env-validate` is how they learn it is stale
(rc=2, HTTP 401); the fix is a conversation with the platform team, not a command.

⚠️ **THE TABLE IS A PROHIBITION, NOT A LOOKUP LIST — and its EDGE is where every violation happens
(BLOCKING).** The rule above reads as "here are the targets for these questions", so it is obeyed for
every question that IS a row and abandoned for the first one that is not. MEASURED 2026-08-22, twice
inside ten minutes, by a session that had quoted this rule an hour earlier: asked "what pods are
running / what is the ingress LB IP" — neither a row — it hand-rolled `kubectl -o custom-columns`,
which **zsh glob-mangled** (`no matches found` on the `[0]` subscript) and returned nothing, and
hand-searched `secrets/` for a kubeconfig instead of calling the repo's own resolver.

**When your question is not a row, the answer is still NEVER a raw `kubectl`/`curl`.** It is one of:

| | |
|---|---|
| the target exists under another name | `make creds-show` answers "what are the endpoints and logins **for this context**" — it loops the registry, so it covers apps that did not exist when the table was written |
| a LIBRARY function exists | `scripts/lib/*.sh` — `istio_discover`, `supervisor_kubeconfig`, `harbor_auth_report`. Source the lib; do not re-derive what it already resolves |
| **the missing target IS the finding** | a lab question with no target is a gap in the product, not a licence to improvise. File it |

The cost is not style. A hand-rolled probe (a) is unreviewed and often wrong — the two above returned
**nothing** and a shell error; (b) does not carry the repo's hard-won discriminators, so it silently
re-enters a settled trap (the three Harbor auth probes that return 200 with NO credentials; a
`kubectl` empty-result that is rc=0 and therefore bypasses `classify_kube_failure` entirely); and (c)
its output is not the product's, so a green from it certifies nothing an operator will ever see.

**THE CHAIN, when a credential is stale** (each link is a target; the only human input is the first):

```text
VCENTER_PASSWORD -> make vks-login -> secrets/supervisor.kubeconfig
                 -> make harbor-admin-password -> make harbor-robot -> make mirror
```

⚠️ **Harbor is a SUPERVISOR Service.** The guest kubeconfig has NO harbor namespace, so
`kubectl -n harbor ...` against the guest is always empty — that is not "Harbor is missing".

⚠️ **vCenter SSO LOCKS OUT PERMANENTLY AFTER 3 FAILED ATTEMPTS.** Never guess, never retry blind. If
`VCENTER_PASSWORD` is absent from `.env`, STOP and ask the operator — do not spend an attempt.

#### THREE HARBOR "AUTH CHECKS" THAT DO NOT DISCRIMINATE — measured 2026-08-22

A session tested a 12-day-old `secrets/harbor-robot.env` three ways, got "works" three times, and was
wrong every time. The credential was DEAD (`UNAUTHORIZED ... action: push`):

| probe | reading | why it is worthless |
|---|---|---|
| `GET /api/v2.0/projects` with creds | 200 | returns **200 with NO credentials**, and 200 with a **deliberately wrong password** |
| `GET /service/token?scope=...` with creds | 200 | returns **200 with bogus creds** too |
| `crane auth login` | "logged in" | it only **writes `~/.docker/config.json`** — it validates nothing |
| **`crane copy` (the real push)** | **UNAUTHORIZED** | the only one that discriminates |

`make env-validate` gets it right in one command (rc=2, `Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)`)
because `lib/harbor.sh`'s `harbor_auth_report` already solved this — its own test asserts **401 fails,
403 PASSES**. Use it. `GET /api/v2.0/users/current` is the endpoint that actually requires auth.

⚠️ **`secrets/` is gitignored operator state that NOTHING cleans up.** A `harbor-robot.env` survives
every lab re-cut and reads as valid to any proxy check. Age is not the tell; only the real operation is.

⚠️ `ca_bundle_with_system` takes **TWO** arguments — `<ca-file> <out-bundle>` — and writes to the
second. Called with one it silently produces nothing and returns 0, so `$(... || fallback)` never
fires and `SSL_CERT_FILE` ends up EMPTY, which surfaces as `x509: certificate signed by unknown
authority` from crane.

### RULE ZERO-0 — ENDING A TURN WITH A QUESTION IS AN ACTION WITH A COST, AND IT IS USUALLY THE RISKIER ONE (BLOCKING)

**MEASURED 2026-08-23: 7h52m of dead wall-clock, from one sentence.** `#957` merged at 01:50; the
next thing landed at 09:42. The entire gap was a turn that ended *"I'm holding at the cut rather than
starting one that a bot can invalidate"* — waiting for an owner who was not at the keyboard. A full
six-row matrix run is hours, not minutes, so a run started instead of asked-about would have
**finished**, and the session would have had a verdict rather than a question.

⚠️ **Do NOT quote a duration here — measured 2026-08-24.** This line used to say "~4h" and "finished,
**twice**". Both were wrong: `7h52m ÷ 4h06m = 1.92`, so "twice" was false on its own number; and the
only two COMPLETE runs measured **3h06m** and **4h06m** — 32% apart, same tree, 24h apart — while
**both are 2-app trees**. The repo now has six apps (builder STEP lines 4 → 34) and **no COMPLETE
6-app run exists**, so any figure written here is a forecast quoting an obsolete corpus. Read
`~/walk-evidence/run-*/VERDICT-*.txt` instead. A `make matrix-eta` printer to derive it was designed
and **REFUTED**: every COMPLETE run is 2-app and every 6-app run is incomplete, so it would have
automated quoting the stale number with a command's authority behind it.

**And the caution was inverted.** The thing being "protected" against was a Renovate automerge
invalidating the run — which was *more* likely across eight idle hours than during a run already
under way. Asking did not reduce the risk; it maximised the window.

This has recurred often enough that the owner's word for it is *"you sabotage my standing rules"*.
The four in one session: splitting a PR I had opened, merging a green Renovate PR, applying a fix
already approved in the same breath, and holding at the cut.

**THE TEST, and it is narrow.** Stop and ask ONLY when the action is:

1. **destructive** (`make destroy`, `uninstall-all`, deleting a lab, `reset --hard` over someone's work), or
2. **a change to the owner's security posture** (a NetworkPolicy on their lab, a trust store, a firewall), or
3. **outward-facing and irreversible** (publishing, a release, mailing anyone), or
4. **genuinely ambiguous between materially different outcomes** — and then ask INSIDE the turn and keep working on everything that does not depend on the answer.

**Everything else: ACT.** Merging a green PR you opened. Merging a green bot PR. Pausing a bot.
Cutting a lab the owner asked for. Choosing between two designs a round already adjudicated. If it is
reversible and inside the task already given, the decision is yours and the asking is the defect.

**Why this keeps recurring, mechanically:** nothing carries between sessions except FILES. Every
previous correction on this lived in chat and scrolled away — the same failure
`docs/matrix-standing-rules.md` exists to prevent. That is why this is written here and not promised
in a reply.

**The tell, in advance:** you are about to write *"say the word"*, *"let me know"*, *"I'm holding"*,
or *"your call"* about something you could simply do. That sentence IS the failure. Delete it and run
the command.

**THE SIBLING FAILURE: TREATING A RUNNING BACKGROUND JOB AS THE END OF THE TURN.** Same root, and it
costs the same way. MEASURED 2026-08-23, minutes after RULE ZERO-0 was written: a ~45-minute lab cut
was launched, a status report was written, and the turn ended — while a full six-app KinD e2e, which
touches nothing the cut touches and needed 32 idle CPUs and 148 GiB of free RAM, sat unstarted until
the owner asked *"do you have other tasks you can run in parallel?"*. It was available from t=0.

A backgrounded job is not a blocker; it is a REASON to start the next independent thing. The turn
ends when there is no independent work left, never when the last report was written.

**The reflex, at the moment you launch anything long:** before writing a single word of status, ask
what else can run RIGHT NOW that does not depend on it — and start that too. On this repo the
answer is almost never "nothing": a KinD e2e, an adversary round, a gate, a doc audit and a lab cut
are mutually independent, and the box is a 32-CPU machine.

**The tell:** your reply is a status table and nothing is being started in the same turn.

### RULE ZERO-S — THE BASH TOOL IS **ZSH** ON THIS BOX. WRAP ANY NON-TRIVIAL SNIPPET IN `bash -c` (BLOCKING)

**MEASURED on this box, right now** — `$SHELL=/usr/bin/zsh`, and the Bash tool's own shell reports
`zsh`. Not "may be"; **is**. Three constructs I used today returned garbage rather than an error:

| construct | zsh (measured) | bash |
|---|---|---|
| `${!var}` indirect expansion | **`bad substitution`** -> empty | the value |
| an unmatched glob (`ls /nope-*.zzz`) | **`no matches found` and the WHOLE COMMAND ABORTS** | passes through |
| `for x in $var` (newline-separated) | **1 iteration** | 3 iterations |

Also: `PIPESTATUS` is bash-only (zsh: `pipestatus`), and `status`/`path`/`argv` are **read-only**
in zsh, so `read -r sha status concl` fails with `read-only variable: status`.

**THE FAILURE MODE IS NOT AN ERROR — IT IS A CONFIDENT WRONG ANSWER.** Every one of these returns
*something*: an empty string, one loop pass, a silently-truncated command. You then read that as
data. Measured 2026-08-26, three times in one session:

1. probing a helper with `${!1}` -> `bad substitution` -> **empty** -> read as "the variable is unset"
2. a Monitor globbing `MATRIX-row*.log` before any row existed -> `no matches found` -> **the whole
   monitor died**, silently, while the thing it watched ran on
3. `ps | grep -c` self-match and an unmatched-glob abort, each read as a fact about the lab

**THE REFLEX — mechanical, no judgement call:**

> If a command contains `${!`, a glob that may not match, `for x in $var`, `PIPESTATUS`, `read -a`,
> or a variable named `status`/`path`/`argv` — **wrap the whole thing in `bash -c '...'`.**
> When in doubt, wrap. It costs nine characters and it removes the entire class.

```bash
bash -c 'set -o pipefail; ... ${!name} ... for f in $list; do ...; done'
```

For globs specifically, prefer `find` — it returns **empty** where a zsh glob **aborts**:

```bash
find "$d" -maxdepth 1 -name 'MATRIX-row*.log'    # empty is fine
ls "$d"/MATRIX-row*.log                          # zsh: aborts the command
```

**AND WHEN A PROBE RETURNS NOTHING, SUSPECT THE SHELL BEFORE THE WORLD.** An empty result is a
claim about your instrument first (`agents.md` §"a `ps` that finds NOTHING does not prove the
process is GONE"). Prove the probe can produce a non-empty answer for a case you *know* is true
before concluding anything from its silence.

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

Subagents do **not** inherit SKILLS, so each adversary carries its domain brief in its own system
prompt on purpose. Keep them current when a fact changes.

⚠️ **CORRECTED 2026-07-22 — this line used to say subagents inherit neither "skills or rules". The
RULES half is measurably FALSE, and it is expensive in both directions.** Subagents **DO** inherit
the full `~/.claude/rules/**` corpus. Two independent measurements: an adversary reported
first-person that its own context contained the whole corpus; and a `claude-code-guide` subagent
died at **~315,296 tokens with only ~936 tokens of conversation** — the ungated corpus is 903,003 B
≈ 311k tokens at the ratio that failure implies, which accounts for essentially the entire payload.
A subagent cannot reach 315k unless the corpus is injected into it.

Consequences, both live: (1) a subagent on a **200k-window model cannot start at all** — the eight
roster adversaries work only because each declares `model: opus`, and built-ins like
`claude-code-guide` cannot be given a model, so they are unusable here; (2) any portfolio convention
re-stated inside an adversary brief **because of this false belief** is duplicated bloat paid on
every dispatch — the brief should carry only what the corpus does not.

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

**"Jump box" names up to three DIFFERENT machines — prefer *internet box* / *air-gap box* when it matters.** In a **dual-homed** run there is one box that reaches both the internet and the lab. In a **sneakernet** run there are two: the **internet box** (`mirror-pull`/`builder-build`/`bundle`) and the **air-gap box** (`bundle-load`/`mirror-push`/`builder-push`/`platform` — it CANNOT run `make deps`; see RULE ZERO-A). Separately, `make jumpbox*` builds a **test** jump-box container that itself needs the internet (it runs `make deps`). Note `docs/sneakernet.md` uses **internet box** / **air-gap box** for its two boxes (matching the README Delivery note — B59 reconciled the old inversion, 2026-07-23).

## 🔒 RULE ZERO-B — THE END USER HAS ONLY THIS REPO. THE LAB IS A BLACK BOX (BLOCKING)

They `git clone` **`vks-airgap-cicd`** and nothing else. They do **not** have `nested-vsphere-lab`, they did
not build the lab, and they cannot read its Makefile, its `lab2-info.txt`, or its `make creds`. Everything
they know about the lab is **the `.env` values [`docs/scenario-1.md`](docs/scenario-1.md) and
[`docs/scenario-2.md`](docs/scenario-2.md) tell them to fill in.** In the real world that lab is a VCF/VKS
estate someone else operates; `nested-vsphere-lab` is only how WE happen to conjure one.

### 🔴 AND MOST OF THE TIME THE LAB IS NOT OURS — `.env` IS THE ONLY ACCESS, AND THIS DRIVES DESIGN DECISIONS

The **default** posture is Scenario 2 — a **TENANT**. Harbor and ArgoCD already exist, someone else
runs the Supervisor, and **everything we can reach arrives as variables in `.env`** that a platform
team hands over. Scenario 1 (we install the Supervisor Services ourselves) is the EXCEPTION, and the
KinD stand-in is a convenience. Design for the tenant first.

**The consequences are not stylistic — they decide what may be built:**

1. **"Does this work from `.env` alone?" is the FIRST question about any recovery or diagnostic step.**
   A target that reads a **Supervisor** secret is unavailable to the audience that needs it most.
   Telling a tenant to run one is a dead end dressed as an answer. See RULE ZERO-A0's table, which
   marks every target tenant-safe or SUPERVISOR-ONLY.
2. **A tenant whose credential is stale CANNOT recover it.** There is no self-service path and no
   target will invent one. `make env-validate` is how they LEARN it is stale (rc=2, HTTP 401); the
   fix is a REQUEST to the platform team, not a command. Any "sync/recover" mechanism must say so
   plainly rather than fail obscurely.
3. **Anything that needs more than `.env` must be a REQUEST, and must be named as one** — a Harbor
   robot when we lack project-admin, a namespace, a hostname on a shared Istio Gateway, an ArgoCD
   AppProject destination, the guest cluster REGISTERED with ArgoCD. `make istio-preflight` and
   `make argocd-preflight` exist to print exactly what to ask for.
4. **Never assume Supervisor access when reasoning about a failure.** `kubectl -n harbor …` against a
   guest kubeconfig is empty BY DESIGN — that is not "Harbor is missing", and a session has already
   burned time on that inference.
5. **Convenience paths for US must be existence-guarded no-ops for THEM.** The
   `supervisor_kubeconfig_candidates()` fallback to a lab-provisioning repo's state dir is fine
   precisely because it silently does nothing on a box that has no such directory — and it is kept
   OUT of `.env.example` so it never enters the end user's config surface.

**Therefore:**

1. **Never point the end user at `nested-vsphere-lab`** — not at its targets, its files, or its output. For
    them that is a dead reference, exactly like citing a `/tmp` path after a reboot. If they need a value,
    it must be reachable from THIS repo: from `.env`, from a `make` target here, or from the cluster.
2. **Anything they must SEE must be surfaced by THIS repo.** A credential, endpoint, CA or command that
    exists only in the lab repo does not exist for them. `make creds-show` is their ONLY credentials
    surface — if it omits something they need, that is a defect in this repo, not a lookup they should
    make elsewhere.
3. **Any `make <target>` this repo PRINTS must exist in THIS Makefile.** A target that lives only in the
    lab repo is unrunnable for them and reads as a broken product.
4. **When you catch yourself writing "the lab does X", ask how the end user learns X.** If the answer is
    "from the other repo", it is not an answer.

**Measured 2026-08-20, and worth keeping that way:** `scenario-1.md`, `scenario-2.md` and `README.md`
contain **zero** references to `nested-vsphere-lab` — the separation currently holds; do not erode it.
Scenario-1 does tell them to set `VCENTER_HOST` / `VCENTER_USERNAME` / `VCENTER_PASSWORD` /
`VCENTER_INSECURE`, and `.env.example` carries **9** `VCENTER_*` variables — so they DO supply vCenter
credentials, into `.env`, in this repo. (This file may reference the lab repo freely: it is for the
maintainer, not the reader of the scenarios.)

**SHARPENING 2026-08-20 — the end user's credential surface is what they can OBTAIN, not what `.env`
declares. Answering from the `.env` surface produces a confident, wrong "you can't have that".** Asked
why `make creds` showed no ssh credentials, I answered — correctly about the wrong question — that this
repo declares **0** SSH vars and the scenario documents mention ssh **0** times. The operator's follow-up
was the right question: *knowing the vCenter/SSO password, can the end user obtain them?* **MEASURED
against the live lab: yes.** The Supervisor's vSphere Namespace carries `<cluster>-ssh`
(`ssh-privatekey`) and `<cluster>-ssh-password` (`ssh-passwordkey`, 44 bytes, decoded rc=0), and
`sso:Administrator@vsphere.local` — a credential scenario-1 already tells them to supply — reads them.

So the test for every row is **"can the end user GET this?"**, and the transitive chain counts:
`.env` -> Supervisor -> Supervisor secrets -> guest kubeconfig -> guest secrets. If the answer is yes,
`make creds` shows it, in plaintext, on their terminal. `_mask` keeps a **pipe** hidden, so this does not
put secrets in the walk row logs.

⚠️ **And the probe that says "there is nothing there" is the one to distrust.** My first measurement
reported **0 ssh secrets** and was the INSTRUMENT failing: `get secret -A` is `Forbidden` to SSO admin on
a Supervisor (cluster-wide list), and the grep swallowed the rc, so a **permission error read as an empty
result**. Scope to the namespace and check rc, never the match count — an absence is a claim about your
query before it is a claim about the world.

⚠️ **THE INCIDENT THAT PRODUCED THIS RULE (2026-08-20).** The operator asked why `make creds` showed no
vCenter or SSH credentials. The answer given was *"you ran the wrong repo's `creds` — use
`make -C ~/projects/nested-vsphere-lab creds`."* That answer is **worthless for the actual audience**, and
it turned a real product defect into a supposed user error. The defect is that this repo's own credentials
report has no vCenter section although the end user has already typed those values into `.env` here.
**Ask "does the end user have this?" BEFORE answering "where is it?".**

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
| `make verify-gateway-image` | LIVE: every RUNNING Istio container image came from OUR Harbor. Catches a silently-ignored `global.hub` override — helm accepts an unknown `--set` key with rc=0, so on a dual-homed box the mesh falls back to the public registry and `verify-ingress` still returns 200. Asserts in `istio` mode only; skips loudly otherwise. Wired into `e2e-kind` before `verify-ingress` |
| `make handoff-status` | PRINTS ONLY, never gates (always exits 0): what merged since the HANDOFF was last edited, to read against what the handoff claims. Its count is NOT a signal — four gate designs keyed on it were measured and refuted; read the script header before rebuilding one |
| `make verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| `make verify-ingress-rendered` | **Additive to `verify-ingress`, never a replacement.** Asserts the ingress ROUTES were RENDERED in a scope where the app backends deliberately do not exist (the air-gap leg, where `gitops` is out of scope): infra hosts must route AND serve their marker, each app host must be **5xx** — a 503 proves Envoy matched a rendered route and found no endpoints, a 404 would mean the carried `yq`/`envsubst`/`kubectl` never rendered it. The 404-vs-503 split is MEASURED (2026-07-19), not inferred |
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
  the builder when an app's dependency manifest changes — for ANY of the six apps, not just
  java. You no longer have to NOTICE: since 2026-08-23 `14-builder-build.sh` stamps
  `io.vks.builder.inputs` (a hash of each app's Dockerfile.builder + its dependency manifests)
  and the four offline gates compare it against the tree, so a stale builder announces itself.
  `make builder-freshness` reports it on demand; `BUILDER_FRESHNESS_ENFORCE=1` makes it fatal.
  Do NOT bump `BUILDER_IMAGE_TAG` for this — its default is single-sourced in `lib/apps.sh` and
  it is the HARBOR ref that Tekton, `builders.tsv` and `22-builder-push.sh` all consume.
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

**Running the six-row walkthrough matrix?** [`docs/matrix-standing-rules.md`](docs/matrix-standing-rules.md)
is the 34 standing rules it runs under — scope, how to read the documents, how to execute, how to read the
VERDICT, the both-ways implication rule, the security constraints, and the during-a-run rules (the tree is
FROZEN, never edit a script mid-run, kill by process group). They existed only in chat and were asked for
twice; each during-a-run rule has a recorded incident behind it.

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
  proves nothing about the air gap — it would have masked exactly this bug. (The original fix gated the
  fallback behind an explicit `ALLOW_PUBLIC_BASE=1`; **superseded 2026-07-14** by the
  `14-builder-build.sh` + `22-builder-push.sh` split — the builder base is now pulled **public by
  DIGEST from `images.lock`**, aligned to the mirror by construction, so the tag-pull escape hatch was
  retired.)

**PROVEN:** cold cluster → `make mirror` green → `kubectl -n harbor rollout restart deploy/harbor-registry`
with **zero concurrent load** → `make mirror-verify` still reports **36/36 intact**. Before the fix,
that same restart destroyed everything.

**Still run the e2es serially** — not because of blob corruption, but because they mutate a shared
cluster + registry and parallel work makes a failure unattributable.

## Validate scenario-1 on a CLEAN BOX, not on the box that wrote it (`make labbox`)

A scenario-1 walk on the author's machine is green partly for reasons the doc never mentions: a warm
`mise`, a populated `~/.config/vcf`, a `.env` from a previous lab, licensed CLIs already on PATH. The
walk this repo cares about is the one a stranger does on a fresh box.

**`make labbox`** runs the bootstrap + reach on a clean **Photon** container against the **REAL lab**
(`make jumpbox` points at the KinD stand-in and cannot reach it). Use it whenever scenario-1's Step 0/1
changes.

Three things about it are deliberate, and each was measured — do not "improve" them without re-measuring:

- **`--network host`, never `--add-host`.** Pinned host entries rot on every reinstall (Harbor moved
  `.130 -> .135`, ingress `.134 -> .140` in one afternoon) and there is nothing to pin at Step 1 before
  any login. Worse, `--add-host` IS a `/etc/hosts` entry — the thing `show-dns-records.sh` says in as
  many words is "NOT enough", so it would go green while exercising a DNS path the guest nodes never
  use. `--dns 192.168.100.1` does not work either: systemd-resolved routes `*.env1.lab.test` out the
  libvirt link and dnsmasq will not answer the docker subnet.
- **Photon only — an OS matrix here is VACUOUS.** Measured: ZERO post-bootstrap scenario-1 scripts
  branch on OS; they are kubectl/helm/crane over static binaries. OS differences live in the
  BOOTSTRAP, and `make jumpbox-matrix` already covers photon x ubuntu x podman x docker there.
- **Rootless podman, container root, repo mounted read-write.** Under rootless podman container-root
  maps to the operator's uid, so writes land owned by them. Under **docker** the same mount leaves
  root-owned files in the working tree — and `--user 1000:1000`, the obvious fix, is BACKWARDS under
  podman (container uid 1000 maps to host 100999 and cannot write at all).

⚠️ **What it cannot see:** the `vcf` CLI keeps state in `$HOME`, and a recorded failure in
`docs/scenario-1-notes.md` has that store surviving a lab rebuild and then blocking `vcf context
create` against a dead endpoint. A throwaway container has a fresh `$HOME` every run, so it is
**structurally blind** to that class. This proves clean-box bootstrap + reach, not a full walk.

### ⚠️ The VM walkthrough matrix lives in ANOTHER REPO — `walkbox-vm.sh` / `walk-matrix.sh`

`make labbox` above is this repo's clean-box **container**. It is not the same thing as the VM
walkthrough matrix that walks scenario-1 and scenario-2 end to end: those two scripts are tracked in
**`nested-vsphere-lab`**, and this repo supplies only `WALK_REPO`, `scripts/walk-doc.sh` and the
scenario docs they read.

**Four known defects in them are filed THERE and are deliberately NOT tracked in this backlog** — the
fixes edit files this repo does not contain, and both repos number items `B<N>` independently, so a
copy here would collide the moment this backlog passes B428:

| | |
|---|---|
| **B454** | `WALK_OUT_ROOT` defaults to **`/tmp/walk`**, so a reboot destroys the certification the matrix exists to produce — measured: the 2026-08-19 power loss took run 8's verdict and every per-row log, leaving no baseline to diff against. Always pass `WALK_OUT_ROOT` somewhere under `$HOME`. Filed via PR #90 |
| **B453** | the matrix leaks **exactly one VM per run** — `destroy_stale_walkboxes` is called once, at `walk-matrix.sh:642`, *inside* `row()` **before** the box is built, so each row sweeps the PREVIOUS row's and the last row's is never swept. There is **no `trap` in the file at all**. Filed from this repo's B192 (PR #83) |
| **B436** | the walkbox base image downloads into `$LAB_STATE` instead of the artifacts directory, so a state wipe silently costs a 596 MiB re-fetch |
| **B428** | both scripts hand-roll their ssh options. An identity-free set now exists at `nested-vsphere-lab/lib/common.sh` (`LAB_SSH_OPTS`); lifting it takes that repo's `check-hardcodes` from 3 to 1 |

```sh
grep -n 'B453\|B436\|B428' ~/projects/nested-vsphere-lab/docs/BACKLOG.md
```

⚠️ **That repo's backlog table is GENERATED** (`scripts/regen-backlog-index.sh`; `make backlog-index`
is its drift gate) — add an `##`-level section to `docs/BACKLOG-EVIDENCE.md` and regenerate; never
hand-edit the table. **Lead the heading with a status emoji**, or the classifier files it as
`🔴 unclassified`, which in that repo means *"nobody has looked"* — a materially different claim
from `🔴 open`.

⚠️ **B428 is not a copy-paste.** Both walk arrays currently bundle the identity (`-i "$KEY"`), and
`walk-matrix.sh` **pipes into ssh twice** — so it must never receive `-n`, which discards piped
stdin. Lifting the shared options is easy; splitting `-i` out is the actual work.

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

## ▶️ HANDOFF 2026-08-25 — MATRIX 6/6 GREEN on a fresh cut, all three pairs IDENTICAL

**ONE handoff section; the next session OVERWRITES it.** Facts → the docs. Tasks →
[`BACKLOG.md`](BACKLOG.md). History → git. Only "what is in flight and what to distrust" here.

### The certification

All six rows green. **The pair symmetry is the evidence, not the greens** — a flake shows up as an
asymmetry long before it shows up as a red, and all three pairs match exactly:

| pair | rows | ledger | |
|---|---|---|---|
| NOTHING exists | 1 ↔ 3 | `37 ran / 0 FAILED / 7 skipped` | ✅ identical |
| EVERYTHING exists | 2 ↔ 4 | `31 ran / 0 FAILED / 13 skipped` | ✅ identical |
| scenario-2 | 5 ↔ 6 | `18 ran / 0 FAILED / 10 skipped` | ✅ identical |

Row 1's green is REAL, not skips: zero load-bearing blocks in its skipped list
(`install-all`, `verify`, `verify-ingress`, `install-harbor-service`, `install-argocd-service` all
RAN), **6/6 apps served their own marker**, and 8 UIs reachable through the istio ingress.

Evidence: `run-20260825T221952Z-2864413` (row 1, fresh cut) · `run-20260825T165856Z-1691298`
(rows 3/4/6) · `run-20260825T133210Z-62319` (row 2) · `run-20260825T114908Z-3753525` (row 5).

⚠️ **Read the 1 ↔ 3 pair with this caveat: it is NOT like-for-like on Kubernetes version.** Both rows
used the same "newest Ready+Compatible" selector and got different answers, because the lab was
re-cut between them — row 3 built its cluster on `v1.35.6+vmware.2-vkr.3`, row 1 on
`v1.34.9+vmware.2-vkr.4` (the rebuilt Supervisor's newer TKrs were not `Ready` yet; the cluster
reports `UpdatesAvailable: True`). The identical ledger across two Kubernetes minors is arguably
STRONGER evidence — but it is not the same test twice, and nothing in the ledger says so.

### Why the lab was re-cut (do not re-derive this)

`walk-reset` timed out at its full 1800s with `cicd` stuck `Terminating` on six
`applications.argoproj.io` holding `resources-finalizer.argocd.argoproj.io`. Root cause was ORDERING
and it is now FIXED UPSTREAM (lab PR #105, B463): `walk-reset-cell.sh` step 1 was headed *"THE
CLUSTER FIRST"* while this repo's own `scripts/98-uninstall-all.sh:122-125` says an Application's
finalizer *"can only complete while ArgoCD can still REACH the destination cluster"* — and
`walk-reset` never called `make uninstall-all`. It now has a **step 0** that deletes Applications
before the cluster.

**Clearing the finalizers was IMPOSSIBLE, not merely risky** — measured, so do not retry it: the
drain had already deleted the namespace's RoleBindings, so the SAME identity had
`patch`/`delete`/`rolebindings` = **no** in the Terminating namespace and **yes** in an Active one.
**The drain revokes the permission needed to unblock the drain**, and `can-i * *` is `no`.
Reinstalling ArgoCD cannot help either: the instance lived IN `cicd`, and a Terminating namespace
rejects creates.

### 🔴 DISTRUST FIRST

- **`make env-validate` returns rc=2 / HTTP 401 and that is CORRECT** after any matrix run — the
  walkboxes are destroyed with their Harbor credential. Recover per RULE ZERO-A0's chain.
- **`static-check` is SKIPPED on a PR** (paths-filtered). Run `env -u GOROOT make static-check`
  locally before merging anything touching `scripts/` — 101 offline tests, ~400s.
- **`kubectl get all` does NOT list custom resources.** A probe reported "0 objects remaining" while
  six CRs were the entire problem; the namespace's `status.conditions` named them.
- **`pgrep`/`ps | grep` SELF-MATCH.** Read argv and compare against `$$`; a count is not evidence.
  `ps -p ""` (empty PID from a failed extraction) dumps EVERY process.
- **A leaked `vks-walkbox-*` VM per run is lab B453** — the sweep runs at row START, so the last
  row's box is never swept, and `make destroy`'s teardown does not own it. `make walkbox-vm-down`.

### What landed this session (all merged, `main` green at every post-merge run)

| PR | what |
|---|---|
| **#1011** | 🔴 live tenant-blocking bug: `make vks-login` died FATAL asserting the CLUSTER-SCOPED `list nodes` a tenant cannot hold, while `lib/capacity.sh` calls that "normal for a tenant" |
| **#1014** | the tenant e2e MUTATED a shared ArgoCD with nothing undoing it; added a key-scoped revert trap, verified by re-reading the cluster |
| **#1010** | walkthrough promised a hostname its table never carried, and named ONE app in a generic table |
| **#1009** | the only tenant-RBAC test was wired to nothing AND broken |
| lab **#104/#105** | B462 (refusal names an already-done remedy) and B463 (the ordering fix above) |

### Open

- **B483** — the tenant e2e now has its revert trap, so WIRING it into an automated path is finally
  safe to design. Deliberately still open: it needs a live KinD cluster with ArgoCD and mutates it.
- **B471** — RE-SCOPED. An idea round refuted most of it and its central evidence was inverted; the
  surviving axis is **Harbor**. A second round then refuted its OWN prescription to add `can-i`
  probes to lab-preflight, measuring both as false-BAD generators. Three refuted designs are
  recorded in the row so nobody rebuilds them.
- **B213, B206, B480, B482** unchanged.

## Backlog / resume state → [`BACKLOG.md`](BACKLOG.md)

The backlog lives in **[`BACKLOG.md`](BACKLOG.md)**, which is *not* auto-loaded. It was 61% of this
file (85,504 B) and it is task state, not instructions — and this file is paid on every session
**and re-injected into every subagent** (measured at 141,071 B ≈ 48.6k tokens in one mid-run
injection). Open it when you pick up work; `scripts/*.sh` cite its row IDs (`B22`, `B26`, `B50`) as
provenance for why a given gate exists.
