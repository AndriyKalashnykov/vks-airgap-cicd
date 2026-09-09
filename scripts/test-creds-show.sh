#!/usr/bin/env bash
# test-creds-show.sh — `make creds-show` must NEVER claim something that is not true in the CURRENT state.
#
# WHY THIS EXISTS (it is a gate born of a repeated failure, not a hypothetical)
# ---------------------------------------------------------------------------
# creds-show is the one command an operator trusts to tell them what exists and how to reach it. Three
# separate defects reached the OWNER — not me — because each fix was verified against THE DIFF instead of
# against THE WHOLE OUTPUT IN EVERY STATE:
#
#   1. it printed `.env.example` defaults (`harbor.vks.local`, `Harbor12345`) under the header "local demo
#      credentials" when NOTHING was installed — placeholders that look exactly like live credentials;
#   2. it singled out ArgoCD as `<not set>` while Harbor confidently printed an equally-unreal default, so
#      the table lied BY CONTRAST ("Harbor is configured, ArgoCD is not" — neither was);
#   3. it printed `http://gitea.vks.local` / `tekton` / the apps on a cluster with NO INGRESS — hosts that
#      nothing serves, and that no /etc/hosts entry can make work.
#
# Each was found only when a human read the whole table. A human reading the whole table is not a control.
# THIS is the control: render the command in each state and assert the invariant that the human was
# applying by eye — "every line must be TRUE right now".
#
# THE INVARIANT: creds-show may only advertise what the state supports.
#   * no state overlay      -> it must SAY the values are defaults (nothing is installed)
#   * no INGRESS_LB_IP      -> it must NOT print a *.vks.local URL (nothing serves those hosts)
#   * ingress present       -> it MUST print them (a gate that only ever checks the negative is half a gate)
#   * fully installed       -> no "not set"/"needs"/"default" markers at all
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# Absolute repo root, captured AFTER the cd above — render_with_env needs a path that does not
# depend on the caller's cwd (see its own note).
_CREDS_REPO="$(pwd)"
# ⚠️ A THROWAWAY ROOT, NOT THE REAL ONE. This suite's verdict used to be a function of BOX STATE:
# measured on one box, same commit, `secrets/supervisor.kubeconfig` present vs absent changed the
# result, and a stray `.env.kind` flipped 36 assertions (95 ok -> 59 ok / 5 FAIL). Neither file is
# tracked, so CI and every worktree see a different suite from the maintainer.
#
# ⚠️ IT IS THE GLOBAL EXPORT, NOT `render()`. creds.sh is invoked from TEN sites here; five already
# take a throwaway root and five used the real one — and the two cases that actually failed are
# DIRECT invocations that never call render(). Patching render() would have been 1-of-5: the same
# partial-fix shape this file records at the B548 case below, which neutralised the resolver's LAST
# candidate and left an EARLIER one.
#
# ⚠️ apps/ IS COPIED ON PURPOSE. Without it `app_names` fails, creds.sh takes its "app registry
# unreadable" warn path with stderr discarded, and the report silently loses SIX app rows while this
# suite still reports 95 ok. That vacuity is PRE-EXISTING (all five older fixtures omit apps/ too)
# and is its own row — copying it here just stops this change from widening it.
#
# ⚠️ THE OLD HEADER SAID THIS "changes what ~100 cases read — a separate change, not a comment."
# MEASURED: zero cases break, and creds.sh's output is byte-identical. The number was never taken.
_CREDS_SANDBOX="$(mktemp -d)"
cp "$PWD/.env.example" "$_CREDS_SANDBOX/.env.example"
cp -a "$PWD/apps" "$_CREDS_SANDBOX/apps"
export REPO_ROOT="$_CREDS_SANDBOX"

# ⚠️ AND PIN RESOLVER CANDIDATE #1. A throwaway root closes candidate #2
# (${REPO_ROOT}/secrets/supervisor.kubeconfig) but NOT #1 — measured: with the root sandboxed and a
# real file reachable via VKS_SUPERVISOR_KUBECONFIG the suite still went 94 ok / 1 FAIL. The suite
# already pins #3 (ARGOCD_KUBECONFIG) and #4 (the lab slot); this completes all four.
export VKS_SUPERVISOR_KUBECONFIG="/nonexistent/test-creds-show-sandbox.supervisor"

# ⚠️ PIN THE SIBLING LAB SLOT FOR EVERY FIXTURE, not just the two that override REPO_ROOT.
# `supervisor_kubeconfig_candidates()`'s last slot is `${VKS_LAB_STATE_DIR:-$HOME/.local/state/
# nested-lab}` -- the nested-vsphere-lab repo's state dir. RULE ZERO-B: no operator has it, so any
# fixture it can reach is measuring THIS MACHINE. An implementation round measured that a per-fixture
# pin covered 2 of the 5 fixtures that execute creds.sh; `render()` (which deliberately uses the real
# REPO_ROOT) was the largest exposure and was untouched. One export closes the axis everywhere.
#
# MEASURED SAFE, with the positive control the round prescribed -- varying the LAB slot alone proves
# nothing while `secrets/supervisor.kubeconfig` (an EARLIER candidate) still resolves:
#     lab slot pinned                          -> suite output BYTE-IDENTICAL, rc=0
#     lab slot pinned AND repo secrets/ moved  -> suite output BYTE-IDENTICAL, rc=0
# so no assertion depends on either candidate today. That is LATENT, not safe forever: the moment a
# case asserts on a Supervisor-derived cell it would break CI-only, the #1191 shape exactly.
#
# ⚠️ NOT CLOSED: `render()` can still reach the repo's own `secrets/supervisor.kubeconfig`, because
# it uses the real REPO_ROOT on purpose. Measured harmless today (above). Closing it means giving
# render() a throwaway root, which changes what ~100 cases read -- a separate change, not a comment.
export VKS_LAB_STATE_DIR="${TMPDIR:-/tmp}/creds-show-no-lab-$$"

fail=0
_ran=0
ok()  { _ran=$((_ran + 1)); printf 'ok    %s\n' "$1"; }
bad() { _ran=$((_ran + 1)); printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# The state overlay is the thing under test, so it must be OURS — and the way to make it ours is to
# POINT SOMEWHERE ELSE, not to borrow the operator's file and promise to give it back.
#
# It used to save/delete/restore the REAL sink, and that save-and-restore had two defects, both
# measured 2026-08-12:
#   1. IT DOWNGRADED THE MODE OF A SECRET FILE. `render()` does `rm -f "$SINK"` then recreates it
#      under the default umask, and `cp "$SAVED" "$SINK"` preserves the DESTINATION's mode — so a
#      0600 sink came back 0664. Measured exactly: 600 -> 664. `.env.state` holds the GENERATED
#      Harbor/Gitea/ArgoCD passwords, and this gate runs in `test-scripts` -> `static-check` ->
#      `make ci`, so every CI run on a box with a real sink left those passwords group- and
#      world-readable, permanently.
#   2. It raced anything else using the sink (a live lab walk publishes to it mid-run), and a
#      `kill -9` between delete and restore lost it outright.
# `state_file()` honours VKS_STATE_FILE (lib/state.sh), and it ships COMMENTED in .env.example, so
# exporting it here redirects every reader — the product's `load_env` included — at a temp file.
# Nothing of the operator's is touched, which is also why this gate is now safe to run during a walk.
export VKS_STATE_FILE="${VKS_STATE_FILE:-$(mktemp)}"
SINK="$VKS_STATE_FILE"
# Nothing to put back any more — the sink IS ours. The old save/restore branch is deliberately gone
# rather than left inert: a guard that can never fire reads as a guarantee it does not give.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
# Also removes the hostile-stdin fixture. A SECOND `trap ... EXIT` would REPLACE this one
# rather than run alongside it, so everything that needs cleaning goes here.
restore() { rm -f "$SINK" "${_kc_hostile:-}"; rm -rf "${_CREDS_SANDBOX:-}"; }
trap restore EXIT

# SKIP_DOTENV=1 IS LOAD-BEARING. Without it `load_env` sources the operator's real ./.env and
# ./.env.state, and the "no overlay" fixture below is no longer a no-overlay state at all: it
# inherits whatever that box has. MEASURED 2026-08-11 -- 6 of 6 assertions failed on a box whose
# .env carried HARBOR_URL=harbor.env1.lab.test and whose .env.state still held an INGRESS_LB_IP
# from a lab that had been DESTROYED. The same test passes in CI, where no .env exists, so the
# failure looks like a code regression and is a test that reads its own environment.
# ...AND SO IS SANDBOXING KUBECONFIG, for exactly the same reason one door along. creds.sh dials
# the cluster (`kubectl --request-timeout=3s version`, :198) and also probes for ArgoCD (:88-93), so
# an AMBIENT KUBECONFIG makes this "offline" suite reach a REAL cluster and its verdict depend on
# that cluster's state. MEASURED 2026-08-16: during a Supervisor Service uninstall the lab accepted
# TCP and then stalled, and `make ci` HUNG for 22+ minutes inside this file, in a target whose own
# help text says "Offline script-logic unit tests".
#
# --request-timeout is NOT at fault, and a `timeout` wrapper would have been the wrong fix.
# MEASURED at BOTH failure modes -- a packet-drop black hole (192.0.2.1) AND an accept-then-stall
# listener (a socket that accepts and never writes, which is what the lab was doing) -- kubectl
# exits at 3s in both. The 22 minutes is arithmetic, not a broken timeout: creds.sh makes ~2-3
# kubectl calls per case, this suite has 11 cases, and every one of them paid the full 3s.
#
# RED-PROVEN, with the confounder held constant (the lab had ALSO stopped stalling by then, so a
# plain re-run would have proved nothing): against the same accept-then-stall listener, this suite
# takes 0s WITH the sandbox and 78s WITHOUT it. Both exit 0 -- the defect was never a failure, it
# was an "offline" unit test quietly dialling a live cluster.
#
# A NONEXISTENT path rather than unsetting: it keeps `[ -n "$KUBECONFIG" ]` true, so the realistic
# "configured but unusable" branch is what gets exercised, and kubectl fails on stat in milliseconds.
# Per-case overrides (`KUBECONFIG="$_kc" render ...`) still win, which is how the one case that
# genuinely wants a kubeconfig keeps working.
export KUBECONFIG="/nonexistent/test-creds-show-sandbox.kubeconfig"
export ARGOCD_KUBECONFIG="$KUBECONFIG"

render() { rm -f "$SINK"; [ -n "${1:-}" ] && printf '%s' "$1" > "$SINK"; SKIP_DOTENV=1 CREDS_TOKEN=1 ./scripts/creds.sh 2>/dev/null; }

# ⚠️ EVERY CASE ABOVE AND BELOW HOLDS `.env` AT EMPTY, and that made this gate STRUCTURALLY BLIND to
# B161 for its whole life: it varies only the OVERLAY axis, so "no overlay but a POPULATED .env" —
# the state where a real operator sits — was unreachable by construction. Three prior sessions
# worked on this file and none could see it. `render_with_env` adds the missing axis.
#
# It uses a THROWAWAY REPO_ROOT rather than writing the operator's real ./.env: this suite must
# never touch a file that carries live credentials, and creds.sh resolves .env from REPO_ROOT.
# SKIP_DOTENV is deliberately NOT set here — reading the .env is the entire point of the case.
render_with_env() {
  local envbody="$1" sinkbody="${2:-}" t
  t="$(mktemp -d)"
  cp .env.example "$t/.env.example"
  printf '%s' "$envbody" > "$t/.env"
  [ -n "$sinkbody" ] && printf '%s' "$sinkbody" > "$t/.env.state"
  # ⚠️ NOT ${OLDPWD}. This file cd's to the repo root at the top, so OLDPWD is whatever directory
  # the CALLER happened to be in — the repo root when you run the script by hand, something else
  # under run-test-set.sh. That made these cases silently render NOTHING and fail on the greps while
  # the product was correct: the instrument, not the product. Capture the root explicitly.
  # ⚠️ VKS_STATE_FILE MUST BE REDIRECTED INTO $t TOO, and this is the whole reason these cases first
  # came back red against a CORRECT product. This file exports ONE shared sink (line ~54) and
  # `render()` clears it per case; render_with_env did not, so it INHERITED whatever the previous
  # case had published. creds.sh then saw _have_sink=1, never reached the DEFAULT arm, and the
  # source split it exists to test could not fire. Point the sink at $t and the case is hermetic in
  # both axes — overlay AND .env — which is the point of adding the second axis at all.
  ( cd "$t" && REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" CREDS_TOKEN=1 \
      CREDS_NO_PROBE=1 "${_CREDS_REPO}/scripts/creds.sh" 2>/dev/null )
  rm -rf "$t"
}

# ---- STATE 1: nothing installed. Every value is a default; the output must SAY SO. -------------------
out="$(render "")"
# Key on the CANONICAL TOKEN, never on prose. The first version of this check grepped three English
# phrasings — so when I mutated two of them the gate stayed GREEN and reported the defect as caught. A
# gate that greps prose is testing the prose.
if printf '%s' "$out" | grep -q 'values-provenance: DEFAULT'; then
  # ⚠️ THE GLOSS, NOT THE TOKEN, WAS THE STALE PART (B204). It used to read "(placeholders, not
  # credentials)" as if DEFAULT meant that unconditionally. It does NOT: DEFAULT is ONE axis (no
  # usable state overlay) and `env-populated` is the OTHER (did .env supply values). This case
  # renders with SKIP_DOTENV=1 (see `render`), so env-populated=0 and "placeholders" IS true HERE —
  # but the PAIR carries the meaning, and STATE 6 below pins the other cell of it.
  ok "no overlay + SKIP_DOTENV -> values-provenance: DEFAULT with env-populated: 0 (placeholders)"
else
  bad "no overlay -> the output does NOT declare values-provenance: DEFAULT. It prints
      harbor.vks.local / Harbor12345 as if they were real. That is the exact lie this gate exists for."
fi
# ⚠️ The wording changed 2026-08-20 and the INTENT did not: the human must be told these are
# PLACEHOLDERS. What was removed is the world-claim ("nothing is installed yet"), which this command
# cannot know — it can only know where the values came from. Match the property, not the old prose.
if printf '%s' "$out" | grep -qiE 'ARE PLACEHOLDERS|is a PLACEHOLDER|are a default'; then
  ok "no overlay -> and it says so in words a human will read, not only in the token"
else
  bad "no overlay -> the token says DEFAULT but nothing tells the HUMAN. Both must be true."
fi

# ---- STATE 2: installed, but NO INGRESS. The *.vks.local hosts do not exist. --------------------------
out="$(render 'VKS_STATE_KIND=1
HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
')"
if printf '%s' "$out" | grep -qE 'https?://[a-z0-9.-]*\.vks\.local'; then
  bad "no ingress -> creds-show still advertises a *.vks.local URL:
      $(printf '%s' "$out" | grep -oE 'https?://[a-z0-9.-]*\.vks\.local' | head -3 | tr '\n' ' ')
      Nothing serves those hosts (the ingress is OPTIONAL). Say <needs ingress>, or say nothing."
else
  ok "no ingress -> no *.vks.local URL is advertised (nothing serves them)"
fi
if printf '%s' "$out" | grep -qiE 'port-forward|install-ingress'; then
  ok "no ingress -> the output tells the operator how to reach the services anyway"
else
  bad "no ingress -> the output withholds the URL but does not say what to do instead (port-forward /
      make install-ingress). Removing a lie is not the same as being useful."
fi

# ---- STATE 3: fully installed WITH ingress. Now the URLs are real and must be shown. ------------------
out="$(render 'VKS_STATE_KIND=1
HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
INGRESS_LB_IP=10.0.0.3
')"
if printf '%s' "$out" | grep -qE 'https?://gitea\.vks\.local'; then
  ok "ingress present -> the *.vks.local URLs ARE advertised (the gate checks the positive too)"
else
  bad "ingress present -> creds-show fails to advertise the *.vks.local URLs. Over-correcting into
      silence is its own defect: with an ingress, those URLs are exactly what the operator wants."
fi
# ⚠️ SCOPED TO THE SERVICE TABLE, and the scoping IS the assertion. Its intent is "a fully-installed
# PIPELINE has no unset SERVICE". The `Lab access` section added 2026-08-20 is a DIFFERENT CLASS: its
# rows are values an operator types into .env for a REAL lab, and this fixture is KinD-shaped, so
# `<not set>` there is the CORRECT answer. Grepping the whole output fails on a TRUTHFUL render — and
# the tempting fix (drop `<not set>` from the pattern) would blind it to the service rows it exists
# for. Cut at the section header instead; STATE 9 covers the lab rows on their own terms.
out_services="$(printf '%s' "$out" | sed '/Lab access/,$d')"
if printf '%s' "$out_services" | grep -qiE 'NOTHING IS INSTALLED YET|<not set>|<needs ingress>'; then
  bad "fully installed -> the SERVICE table still carries a 'not set'/'needs'/'nothing installed' marker:
      $(printf '%s' "$out_services" | grep -oiE 'NOTHING IS INSTALLED YET|<not set>|<needs ingress>' | head -2 | tr '\n' ' ')"
else
  ok "fully installed -> no stale 'not set' / 'needs ingress' / 'defaults' markers remain"
fi
if printf '%s' "$out" | grep -q 'values-provenance: DISCOVERED'; then
  ok "fully installed -> declares values-provenance: DISCOVERED (the token FLIPS; it is not a constant)"
else
  bad "fully installed -> still claims values-provenance: DEFAULT. A token that never changes proves nothing."
fi
if printf '%s' "$out" | grep -q '10.0.0.3'; then
  ok "ingress present -> the /etc/hosts line is printed with the real LB IP"
else
  bad "ingress present -> no /etc/hosts hint, so the *.vks.local URLs it just printed cannot resolve"
fi

# ---- STATE 4: THE REAL-LAB STATE. An overlay that is present but NOT stamped. -------------------
# Every state above sets VKS_STATE_KIND=1, which short-circuits creds.sh's provenance ladder BEFORE
# the stamp comparison — so until now this gate never rendered the STORED branch at all, and STORED
# is the ONLY branch a real lab reaches: nothing on the real-lab path calls state_stamp (its two
# callers are 05-kind-up.sh and a manual `make state-stamp`). The gate written to keep creds-show
# honest "in every state" was blind to the state the operator is actually in. (B87)
out="$(render 'HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
')"
if printf '%s' "$out" | grep -q 'values-provenance: STORED'; then
  ok "unstamped overlay, non-KinD -> declares values-provenance: STORED"
else
  bad "unstamped overlay, non-KinD -> did NOT declare STORED. This is the REAL-LAB state, and the
      whole point of the tri-state is that it is distinguishable from DISCOVERED."
fi
# ⚠️ The phrase this greps for spans a LINE BREAK in the rendered output, and it used to match
# only because of a DUPLICATED WORD ("...some may\n   may be from a lab..."). Fixing that typo
# (2026-09-07) took this assertion red — an Expect literal and the string that satisfies it are two
# copies with nothing asserting they agree, and here the second copy lived in a TEST, not a doc, so
# `check-expect-literals` could not see it. Match a fragment that is on ONE line and carries no
# accident: `be from a lab that no longer exists`.
#
# ⚠️ THE ASSERTION MOVED 2026-09-07, and the INVARIANT it protects did not. It used to require the
# literal "be from a lab that no longer exists". That sentence was removed on purpose: it fires on
# EVERY real lab, always (nothing on the real-lab path calls state_stamp — see :211 above), so it
# could not vary and therefore carried no information while reading as an alarm. The operator
# complaint that produced the change was, verbatim, "what is this shit" over a fully-serving lab.
# What must still hold is the ORIGINAL intent: the human is told, not just the machine token. Grep a
# one-line fragment of the replacement that states the actual reason.
# ⚠️ KEYED ON THE PROPERTY, NOT THE PHRASE. This grepped 'carries no cluster stamp' — the exact
# wording — so it fired RED when that phrase was replaced for being internal jargon a reader cannot
# parse ("cluster stamp" is our word, not theirs). The intent above is that the human is told the
# REASON; assert THAT, so the reason can be worded better without breaking the control.
if printf '%s' "$out" | grep -qiE 'which cluster they came from|carries no cluster stamp'; then
  ok "...and tells the HUMAN why (it cannot tell which cluster), not just the token"
else
  bad "...but the human is not told WHY. The token alone is not the deliverable."
fi
# The banner must NOT re-acquire an alarm it cannot justify. This is the RED-proof for the change:
# re-adding the old sentence turns this red, so nobody can quietly restore it.
if printf '%s' "$out" | grep -qi 'no longer exists'; then
  bad "the unconditional 'lab that no longer exists' alarm is back — it fires on EVERY real lab"
else
  ok "...and makes no staleness claim it cannot support"
fi

# ---- B168: an operator's EXPLICIT ARGOCD_SERVER must OUTRANK a discovered ARGOCD_LB_IP. ---------
# ARGOCD_SERVER appeared ZERO times across every fixture in this file, so creds.sh's entire real-lab
# ArgoCD branch had NO coverage at all — and the fixture captioned "THE REAL-LAB STATE" above sets
# the KinD sentinel ARGOCD_LB_IP, so even it exercised the KinD branch. MEASURED before the fix:
# `ARGOCD_SERVER=argocd-server make creds-show` printed `https://192.168.101.131 (self-signed;
# --insecure)` — the bare IP plus the literal --insecure that #745 tells operators never to use,
# against a cert this lab MEASURED as carrying DNS SANs only (no IP SAN), i.e. an address that can
# never verify. ARGOCD_SERVER is snapshot-protected (os.sh) and in check-env-clobber's SELECTORS;
# ARGOCD_LB_IP is in NEITHER, so an unprotected file value was beating a protected explicit one.
out="$(ARGOCD_SERVER=argocd-server.example render 'HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
')"
if printf '%s' "$out" | grep -q 'argocd-server\.example'; then
  ok "explicit ARGOCD_SERVER outranks a discovered ARGOCD_LB_IP"
else
  bad "explicit ARGOCD_SERVER was IGNORED — an unprotected discovered value beat a protected explicit one"
fi
# The two things #745 says must never reach an operator, asserted on the ArgoCD line specifically so
# a bare IP elsewhere in the summary cannot mask a regression here.
_argoline="$(printf '%s' "$out" | grep -i '^[[:space:]]*ArgoCD' || true)"
case "$_argoline" in
  *--insecure*) bad "the ArgoCD line still offers --insecure despite an explicit ARGOCD_SERVER" ;;
  *)            ok "...and the ArgoCD line does NOT offer --insecure" ;;
esac
case "$_argoline" in
  *10.0.0.2*) bad "the ArgoCD line still shows the bare LB IP, which this lab measured has no IP SAN" ;;
  *)          ok "...and it does NOT show the bare LB IP" ;;
esac
# CONTROL: with no ARGOCD_SERVER the KinD sentinel must STILL be used, or the fix has simply broken
# KinD. Its writer 09-argocd-address.sh is Supervisor-only, so nothing sets ARGOCD_SERVER there.
out="$(render 'HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
')"
if printf '%s' "$out" | grep -q '10\.0\.0\.2'; then
  ok "CONTROL: with no ARGOCD_SERVER, the discovered LB IP is still used (KinD unbroken)"
else
  bad "CONTROL FAILED: the KinD path lost its endpoint — the fix broke the case it must preserve"
fi

# ---- STATE 5: STAMPED and MATCHING -> DISCOVERED, without the KinD shortcut. --------------------
# state_kubeconfig_server PARSES the kubeconfig and never dials, so a stamped overlay plus a
# matching kubeconfig is fully offline. This is the branch VKS_STATE_KIND=1 has been standing in
# for, so the stamp comparison itself has never been exercised by this gate.
# The server below is a CLOSED LOCAL PORT, deliberately. What this case tests is that a stamp
# MATCHING the kubeconfig's server yields DISCOVERED — the two strings agreeing is the mechanism;
# whether anything answers is incidental. It used to be https://127.0.0.1:1, which creds.sh
# DIALS for real, and twice (2026-08-16) that dial ran 23 MINUTES and blocked `make ci` entirely
# while the box was saturated by a lab cut.
#   ⚠️ NOT because that address is slow — measured on an idle box, it, a closed local port and a
#   TEST-NET black hole all fail in 0s. The defect is that an OFFLINE unit test dialled the network
#   at all, so its cost is whatever contention makes it. 127.0.0.1:1 cannot leave the box.
_kc="${TMPDIR:-/tmp}/creds-test-kc.$$"
cat > "$_kc" <<'KC'
apiVersion: v1
kind: Config
current-context: c
clusters:
- name: k
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: c
  context:
    cluster: k
    user: u
users:
- name: u
  user: {}
KC
out="$(KUBECONFIG="$_kc" render 'VKS_STATE_SERVER=https://127.0.0.1:1
HARBOR_URL=10.0.0.1
HARBOR_PASSWORD=x
ARGOCD_LB_IP=10.0.0.2
')"
rm -f "$_kc"
if printf '%s' "$out" | grep -q 'values-provenance: DISCOVERED'; then
  ok "stamp MATCHES the live kubeconfig -> DISCOVERED (no KinD shortcut involved)"
else
  bad "stamp MATCHES the live kubeconfig but provenance is not DISCOVERED. The stamp comparison is
      the mechanism under test; every older state bypasses it via VKS_STATE_KIND=1."
fi


# ⚠️ DEFINED HERE, ABOVE THE FAIL-GATE, DELIBERATELY. It used to live inside the
# `if [ "$fail" = 0 ]` block below while a caller sat outside it, so the FIRST real failure
# produced three extra `render_with_cluster: command not found` FAILs that buried it — and,
# worse, a NEGATIVE assertion ("must be SILENT") passed VACUOUSLY on the empty string an
# undefined function returns. RED-proved by an implementation round: injecting `fail=1` before
# the gate yielded 3 false FAILs and 1 vacuous ok. `render` and `render_with_env` were already
# top-level; this was the odd one out.
render_with_cluster() {
  local envbody="$1" reachable="$2" t
  t="$(mktemp -d)"; mkdir -p "$t/bin"
  cp .env.example "$t/.env.example"
  printf '%s' "$envbody" > "$t/.env"
  if [ "$reachable" = 1 ]; then
    printf '#!/bin/sh\ncase "$*" in\n  *current-context*) echo stub-ctx ;;\n  *version*) exit 0 ;;\nesac\nexit 0\n' > "$t/bin/kubectl"
  else
    printf '#!/bin/sh\nexit 1\n' > "$t/bin/kubectl"
  fi
  chmod +x "$t/bin/kubectl"
  : > "$t/kc"
      # curl + getent stubbed TOO, so the isolation is the stubbed PATH and nothing else.
      #
      # ⚠️ THIS STATE DELIBERATELY DOES NOT SET CREDS_NO_PROBE. It used to, and that made the
      # whole axis VACUOUS the moment creds.sh began honouring the flag properly (2026-09-07):
      # the reachability probe short-circuited before the stub was ever consulted, and this
      # STATE's own anti-vacuity check caught it -- "the stub was NOT honoured, so every
      # assertion in STATE 8 is vacuous." A state that asserts on a probe cannot also switch
      # the probe off. B530 records the same defect one level up.
      printf '#!/bin/sh\nexit 1\n' > "$t/bin/curl"
      printf '#!/bin/sh\nexit 1\n' > "$t/bin/getent"
      chmod +x "$t/bin/curl" "$t/bin/getent"
  ( cd "$t" && PATH="$t/bin:$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      KUBECONFIG="$t/kc" CREDS_TOKEN=1 "${_CREDS_REPO}/scripts/creds.sh" 2>/dev/null )
  rm -rf "$t"
}

if [ "$fail" = 0 ]; then
  _kc_hostile="${TMPDIR:-/tmp}/creds-hostile-kc.$$"
cat > "$_kc_hostile" <<'KCH'
apiVersion: v1
kind: Config
current-context: c
clusters:
- name: k
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: c
  context: {cluster: k, user: u}
users:
- name: u
  user: {}
KCH
# ── creds.sh must survive a HOSTILE STDIN ────────────────────────────────────────────────────
# THE defect that hung `make ci` twice, for 22 and 27 minutes. kubectl blocks in
# unix_stream_data_wait when stdin is an open pipe that never reaches EOF -- which is exactly what
# it inherits from a make recipe or a test harness. --request-timeout CANNOT bound it: the process
# never gets far enough to issue a request, so there is nothing for a request timeout to cut off.
#
# PROVEN by varying ONLY stdin against one kubeconfig: /dev/null -> rc=1 in 0s; an open pipe ->
# HANGS; open pipe with </dev/null -> rc=1 in 0s. Removing the guard from creds.sh reproduces the
# hang here in 40s.
#
# The timeout is the assertion. Without it a regression does not FAIL this suite -- it hangs it,
# which is how the bug reached `make ci` twice without ever being called a test failure.
_fifo="$(mktemp -u)"; mkfifo "$_fifo"; exec 9<>"$_fifo"
if timeout 45 env SKIP_DOTENV=1 CREDS_TOKEN=1 KUBECONFIG="$_kc_hostile" ./scripts/creds.sh >/dev/null 2>&1 <&9; then
  ok "creds.sh completes with a HOSTILE stdin (an open pipe that never sees EOF)"
elif [ $? -eq 124 ]; then
  bad "creds.sh completes with a HOSTILE stdin" "it HUNG -- a kubectl in creds.sh is missing </dev/null"
else
  ok "creds.sh completes with a HOSTILE stdin (an open pipe that never sees EOF)"
fi
exec 9>&-; rm -f "$_fifo"

# ---- STATE 6 (B161): NO OVERLAY, but a POPULATED .env — where a real operator actually sits. ---------
# The runbooks tell the operator to set HARBOR_URL/HARBOR_PASSWORD by hand BEFORE installing
# (02-env.sh:177), and .env survives a lab rebuild. So this state holds values that may be live OR
# left over from a destroyed lab — and they are BYTE-IDENTICAL on screen, which is why creds-show
# must answer SOURCE and never claim FRESHNESS in either direction.
# The fixture value is deliberately LOW-ENTROPY and self-describing. The first version used a
# realistic 16-char random string, to look like what env-populate generates, and gitleaks flagged it
# (leaks found: 1) — correctly: a committed file carrying a credential-shaped high-entropy token is
# exactly what that gate exists for. The code under test only asks whether .env holds an uncommented
# KEY= assignment, so the VALUE is irrelevant to what this case proves. Do not make it realistic.
out="$(render_with_env 'HARBOR_URL=192.168.101.130
HARBOR_PASSWORD=fixture-value-not-a-real-secret
')"
# ── B204: PIN THE TWO TOKENS TOGETHER, because neither means anything alone ─────────────────────
# B204 claimed `values-provenance: DEFAULT` contradicts the prose "Treat every credential here as
# LIVE". MEASURED: it does not — DEFAULT and env-populated are ORTHOGONAL AXES, and the pair
# (DEFAULT, env-populated=1) already identifies "no overlay, but YOUR .env supplied real values"
# uniquely. A fourth enum value (`SUPPLIED`) was proposed and REFUTED: it is either exactly that pair
# (redundant), or it wins whenever .env is populated and DESTROYS the DISCOVERED/STORED split — the
# branch carrying "be from a lab that no longer exists", built after a measured 3-way failure.
# So: NO product change. Pin the PAIR, which nothing did before — STATE 1 pins DEFAULT with
# env-populated=0, and this state pinned env-populated=1 while saying NOTHING about provenance.
if printf '%s' "$out" | grep -q 'values-provenance: DEFAULT'; then
  ok "B204: populated .env + no overlay -> DEFAULT *paired with* env-populated: 1 (not placeholders)"
else
  bad "B204: populated .env + no overlay did NOT declare values-provenance: DEFAULT" \
      "the two tokens are orthogonal axes; if either drifts, the pair stops identifying the state"
fi
if printf '%s' "$out" | grep -q 'env-populated: 1'; then
  ok "B161: a populated .env is DETECTED (env-populated: 1)"
else
  bad "B161: a populated .env is NOT detected" "the source split cannot fire, so the false footnote below still ships"
fi
# THE HIGH FINDING. The old footnote asserted every value came from .env.example and that none of
# them exists. HARBOR_PASSWORD is COMMENTED in .env.example (measured: uncommented=0), so that claim
# is not merely vague — it is checkably FALSE, about a value that may be a live credential.
if printf '%s' "$out" | grep -q 'None of them exists'; then
  bad "B161: it still claims 'None of them exists' over values that came from .env" \
      "a reader who checks that claim finds it false, and treats a live credential as a placeholder"
else
  ok "B161: it does NOT claim the values are non-existent placeholders"
fi
if printf '%s' "$out" | grep -qi 'from YOUR .env'; then
  ok "B161: it names the real SOURCE (.env) instead of asserting freshness"
else
  bad "B161: it does not name .env as the source" "source is the only question answerable offline"
fi
if printf '%s' "$out" | grep -q 'env-validate'; then
  ok "B161: it points at the one thing that SETTLES it (make env-validate authenticates for real)"
else
  bad "B161: no referral to env-validate" "telling a reader a value is unconfirmable without saying how to confirm it is half a message"
fi
# It must NEVER say STALE: on the documented real-lab flow that label is FALSE, and it would send an
# operator to rotate a working credential.
if printf '%s' "$out" | grep -qi '\bstale\b'; then
  bad "B161: it labels the values STALE" "freshness is NOT computable here — .env carries no cluster stamp"
else
  ok "B161: it never claims the values are STALE (that is not knowable offline)"
fi

# ---- STATE 7: the CONSTRAINT — an EMPTY .env must keep the original wording, unchanged. -------------
# The fix adds an ARM; it must not reword the genuinely-empty case, which the assertions at the top
# of this file pin. A fresh clone with no .env is a real persona and "these are placeholders" is TRUE
# for them.
out="$(render_with_env '')"
# ⚠️ Matches the PROPERTY this case's own comment states — "these are placeholders" is TRUE for a
# fresh clone — not the 2026-08-20 prose. The world-claim ("nothing is installed yet") was removed
# from every arm because the command cannot know it; the placeholder claim was kept because it can.
if printf '%s' "$out" | grep -qiE 'ARE PLACEHOLDERS|is a PLACEHOLDER|are a default'; then
  ok "an EMPTY .env still says the values are placeholders (the fix is additive)"
else
  bad "an EMPTY .env lost the original wording" "the fix rewrote an arm it was supposed to leave alone"
fi
if printf '%s' "$out" | grep -q 'env-populated: 0'; then
  ok "an EMPTY .env reports env-populated: 0"
else
  bad "an EMPTY .env does not report env-populated: 0" "the discriminator cannot tell the two states apart"
fi

# ---- STATE 7: THE SECRET GUARD (B182). Two cases, and they are MANDATORY because without them the
# whole suite would run the HIDDEN arm and notice nothing. MEASURED before this was added: grepping
# this file for any Password-column sentinel returned ZERO hits — the gate made no assertion on that
# column at all, and `render()` calls creds.sh inside `$( )`, i.e. a pipe, i.e. non-tty. So after the
# guard landed, all 11 existing cases would have exercised the masked path silently.
#
# ⚠️ EACH CASE ASSERTS BOTH DIRECTIONS. "the sentinel is present" alone is satisfiable by a creds.sh
# that prints the sentinel unconditionally; "the value is absent" alone is satisfiable by one that
# prints nothing. Only the conjunction distinguishes a working guard from either failure.
_SECRET='ZZTESTSECRET-do-not-match-anything-else'

out="$(HARBOR_PASSWORD="$_SECRET" render '')"
if printf '%s' "$out" | grep -qF 'hidden: not a terminal' \
   && ! printf '%s' "$out" | grep -qF "$_SECRET"; then
  ok "piped + SHOW_SECRETS unset -> the password is MASKED and the value is absent"
else
  bad "piped + SHOW_SECRETS unset -> expected the hidden-sentinel AND no cleartext value. Got:
$(printf '%s' "$out" | grep -E '^ *Harbor ' || printf '%s' "$out" | tail -3)"
fi

out="$(SHOW_SECRETS=1 HARBOR_PASSWORD="$_SECRET" render '')"
if printf '%s' "$out" | grep -qF "$_SECRET"; then
  ok "piped + SHOW_SECRETS=1 -> the escape hatch REVEALS (docs/access-uis.md depends on this)"
else
  bad "piped + SHOW_SECRETS=1 -> the documented escape hatch did NOT reveal the value. Got:
$(printf '%s' "$out" | grep -E '^ *Harbor ' || printf '%s' "$out" | tail -3)"
fi

# THE `--raw` HANDSHAKE (B153). argocd-password.sh now applies its OWN non-tty mask, because two of
# the 16 credential occurrences measured in run 6's walk logs are its BARE invocation at
# docs/scenario-1.md Step 5 — a value read from a k8s Secret, which never lands in .env or
# .walk-env, so NO downstream redactor could ever key on it. creds.sh therefore has to ask for the
# plaintext explicitly (`--raw`) and apply the decision itself.
#
# ⚠️ WITHOUT A CASE HERE THE REGRESSION IS INVISIBLE IN THE DIRECTION THAT MATTERS. Drop `--raw`
# from creds.sh and the *masked* arm still looks perfect — a sentinel is what it expects — while the
# REVEAL arm silently renders argocd-password's sentinel instead of the operator's password. So the
# assertion is on the reveal arm, and it demands the VALUE and the ABSENCE of a nested sentinel:
# either alone is satisfiable by the broken build.
# ⚠️ AND THE OBVIOUS FORM OF THIS CASE IS VACUOUS — MEASURED, not reasoned. The first version set
# SHOW_SECRETS=1 and asserted the value appears. Dropping `--raw` from creds.sh then still PASSED
# (rc=0), because SHOW_SECRETS is inherited by the CHILD too: argocd-password.sh's own snapshot sees
# it and reveals, so the fixed and broken builds produce identical output. A case that cannot tell
# them apart is not a RED-proof however carefully it is worded.
#
# The state that DISCRIMINATES is the real-operator one: creds.sh on a TERMINAL with SHOW_SECRETS
# UNSET. creds.sh then reveals (tty), while argocd-password.sh — captured in `$( )`, always a pipe —
# masks. With `--raw` the plaintext still arrives; without it the cell renders a NESTED SENTINEL.
# `script(1)` gives us that terminal, and this is also the pty behaviour docs/access-uis.md now
# documents: a pty capture COUNTS as a terminal and reveals.
_ARGO='ZZARGOSECRET-do-not-match-anything-else'

# ---- NON-PTY POSITIVE CONTROL. This is the ONLY guard for the row itself on a box without
# script(1), and it is the box this repo targets: bare Photon and minimal containers ship no
# util-linux. MEASURED 2026-09-05 by an adversary: with script(1) simulated absent, the gate
# printed "SUCCESS -- creds-show tells the truth in every state" at rc=0, 52 ok, 0 FAIL, while
# `grep -c ZZARGOSECRET` over the report was 0 -- the ArgoCD row AND its password had been
# deleted and CI was green. A guard that self-skips on the target platform is not a guard.
#
# WHY THIS ONE DISCRIMINATES WHERE THE PTY CASE BELOW DOES NOT, and vice versa -- they test
# DIFFERENT properties and neither replaces the other:
#   * THIS case asks "is the row, and the credential it carries, IN THE REPORT AT ALL?"
#     SHOW_SECRETS=1 is fine here: we want the value revealed so we can grep for it.
#   * The PTY case asks "does the --raw handshake stop a NESTED SENTINEL leaking into the cell?"
#     There SHOW_SECRETS=1 is VACUOUS -- the child argocd-password.sh inherits it and reveals
#     too, so the fixed and broken builds are byte-identical. That case NEEDS a terminal.
# Adversary-proven to discriminate: 0 before the row-drop fix, 1 after. RE-PROVEN here 2026-09-05
# by mutation: re-adding the row-drop made THIS case fire BY NAME ("the ArgoCD credential is
# ABSENT"), and restoring returned the gate to rc=0 with a clean tree.
# ⚠️ KNOWN AND NOT YET EXPLAINED: this same command run in a BARE shell yields 0 matches, while it
# yields >=1 inside this harness. So the harness environment differs from a plain invocation in a
# way that changes the ArgoCD password path -- do NOT use a standalone run of this command as an
# A/B baseline for creds.sh timing or behaviour; they are not comparable. The property THIS case
# asserts (the row and its credential are printed at all) is sound and mutation-proven either way.
# The likely cause is the pre-existing defect noted in creds.sh: with SKIP_DOTENV set AND the
# admin password supplied through the environment, `argocd-password.sh --wait 0 --raw` HANGS to
# rc=124 instead of short-circuiting on the value it was handed. Settle it before relying on this
# case's environment.
# ⚠️ DESCRIBED IN PROSE, NOT AS AN ASSIGNMENT, DELIBERATELY. Written as a `KEY=value` shell
# fragment this comment tripped gitleaks' generic-api-key rule and reddened the `secrets` job --
# a wrapped line STARTING with a credential-shaped assignment is indistinguishable from a real
# one. Describe such an invocation; do not spell it.
_np_out="$( SHOW_SECRETS=1 SKIP_DOTENV=1 CREDS_TOKEN=1 ARGOCD_ADMIN_PASSWORD="$_ARGO" \
            timeout 90 ./scripts/creds.sh 2>/dev/null || true )"
if printf '%s' "$_np_out" | grep -qF "$_ARGO"; then
  ok "no pty needed: the ArgoCD row still carries its password (the row was not dropped)"
else
  bad "the ArgoCD credential is ABSENT from the report. A row whose URL cell is empty must still
      be printed -- it carries the PASSWORD, which is the half the operator cannot obtain any
      other way. This guard runs WITHOUT script(1), so it is the one that fires on Photon."
fi
unset _np_out

if ! command -v script >/dev/null 2>&1; then
  # LOUD, not silent. A skipped case that says nothing is indistinguishable from a passing one.
  printf '  SKIP  --raw handshake: script(1) not on PATH, so no pty is available to discriminate\n' >&2
else
  # -q quiet, -e return the child's status, -c command, output to /dev/null (we read stdout).
  # \r strip: a pty terminates lines with CRLF, which would defeat a plain grep -F on the tail.
  _pty_out="$(script -qec "SKIP_DOTENV=1 CREDS_TOKEN=1 ARGOCD_ADMIN_PASSWORD='${_ARGO}' ./scripts/creds.sh" /dev/null 2>/dev/null | tr -d '\r')"
  _argo_row="$(printf '%s' "$_pty_out" | grep -iE '^ *ArgoCD ' | head -1)"
  if printf '%s' "$_argo_row" | grep -qF "$_ARGO" \
     && ! printf '%s' "$_argo_row" | grep -qF 'hidden: not a terminal'; then
    ok "on a TTY with SHOW_SECRETS unset -> the ArgoCD cell carries the VALUE (the --raw handshake holds)"
  else
    bad "on a TTY -> the ArgoCD cell must carry the password and NO nested sentinel. Dropping --raw
        from creds.sh's argocd-password.sh call is what produces the sentinel here. Got:
${_argo_row:-<no ArgoCD row rendered at all -- the assertion is vacuous, fix the fixture first>}"
  fi
fi

# The .env-IMMUNITY case. This is the arm the round named as most likely to be got wrong: the naive
# `${SHOW_SECRETS:-0}` read AFTER load_env fails it, because load_env's `set -a` exports whatever is
# in the operator's .env over the caller's environment. A throwaway REPO_ROOT is used so the
# operator's real ./.env is never touched.
# ⚠️ THE .env.example COPY IS LOAD-BEARING, and its absence made the FIRST version of this case
# VACUOUS. Without it `load_env` FATALs (".env.example missing at <throwaway>"), creds.sh emits ONE
# error line, and "the secret is absent" is trivially true — so the case passed against BOTH a
# no-guard mutant AND the naive read-after-load_env mutant it exists to catch. Copy it, exactly as
# render_with_env:108 does.
_envdir="$(mktemp -d)"
cp .env.example "${_envdir}/.env.example"
printf 'SHOW_SECRETS=1\n' > "${_envdir}/.env"
out="$( cd "$_CREDS_REPO" && REPO_ROOT="$_envdir" HARBOR_PASSWORD="$_SECRET" \
        CREDS_TOKEN=1 ./scripts/creds.sh 2>/dev/null )"
# POSITIVE CONTROL: the render must have produced a real table, not an error. Without this the
# absence assertion below can pass on any failure mode at all.
if ! printf '%s' "$out" | grep -qE '^ *Harbor '; then
  bad ".env-immunity case rendered NO Harbor row — the render failed, so the assertion is vacuous"
elif ! printf '%s' "$out" | grep -qF "$_SECRET"; then
  ok ".env cannot re-arm the leak -> SHOW_SECRETS is snapshotted BEFORE load_env"
else
  bad ".env RE-ARMED the leak: a SHOW_SECRETS=1 line in the operator's .env revealed the value.
      The snapshot is being read AFTER load_env. See lib/os.sh:501 for this clobber class."
fi
rm -rf "$_envdir"

# ---- STATE 8: THE THIRD AXIS — CLUSTER REACHABILITY. ------------------------------------------------
# ⚠️ THIS AXIS DID NOT EXIST, and its absence is why this gate could not fail on the defect the OWNER
# hit. The header above says this suite "varies only the OVERLAY axis"; render_with_env added the .env
# axis. Neither can reach the state a real operator sits in on a REAL LAB: no overlay on THIS checkout,
# a populated .env, and a cluster that ANSWERS. Measured 2026-08-20 against a live lab with Harbor,
# ArgoCD, Gitea, Tekton and two apps running and 31 namespaces visible, the report printed:
#     cluster      : reachable — context 'nested-lab'
#     flow         : real VKS lab (VKS_AUTH_METHOD=vcf), nothing installed yet
# Two adjacent lines contradicting each other. The flow line is computed from `_have_sink` +
# VKS_AUTH_METHOD ONLY (creds.sh:304-312) and NEVER consults `_cluster`, which is measured live two
# lines below it — so it is INVARIANT under reachability. A/B proved it: identical flow line whether
# the cluster answered or not.
#
# `_have_sink` is a fact about THIS CHECKOUT ("has an installer on THIS BOX published anything"), not
# about the world. `.env.state` is gitignored and per-clone, so an end user hits the false claim
# whenever the install happened elsewhere: a colleague installed and they cloned; a second operator on
# a second box; or scenario-2's TENANT, who by definition never installs Harbor or ArgoCD at all.
#
# The stub is the whole point: no cluster, no credentials, no SSO attempt — just a kubectl on PATH that
# answers `version` 0. creds.sh:324 gates reachability on exactly that call.

_real_env='HARBOR_URL=harbor.example.test
HARBOR_USERNAME=admin
HARBOR_PASSWORD=fixture-value-not-a-real-secret
GITEA_ADMIN_PASSWORD=fixture-value-not-a-real-secret-two
VKS_AUTH_METHOD=vcf'

out="$(render_with_cluster "$_real_env" 1)"

# -- A ROBOT CANNOT LOG INTO THE HARBOR WEB UI (2026-09-06) -------------------------------------
# MEASURED on the live lab: the configured `robot$...` credential returns HTTP 412 from
# /api/v2.0/users/current, while the Supervisor's admin returns 200 -- with both controls
# (admin+wrong-password 401, no-credentials 401). This table's heading is "Access the UIs", so
# printing a robot there hands the reader a credential that cannot do the thing the row is for.
# The operator who hit it put it plainly: "why not admin? where is admin for harbor?"
#
# BOTH DIRECTIONS. A footnote that always prints is worthless -- the admin fixture above must NOT
# produce it, or this case cannot fail.
_robot_env="$(cat <<'ROBOTENV'
HARBOR_URL=harbor.example.test
HARBOR_USERNAME='robot$fixture-not-a-real-robot'
HARBOR_PASSWORD=fixture-value-not-a-real-secret
VKS_AUTH_METHOD=vcf
ROBOTENV
)"
_rout="$(render_with_cluster "$_robot_env" 1)"
# The UI credential must be a ROW, not prose. A first version shipped a nine-line footnote
# EXPLAINING why admin was absent; the operator's response was "what the fuck is this poem for? i
# want Harbor admin here" -- and this repo's own rule says it: docs say WHAT, not WHY, and a
# mechanism essay does not belong in an instruction slot. The credential goes in the table.
if printf '%s' "$_rout" | grep -qE '^  Harbor \(web UI\)'; then
  ok "harbor: a ROBOT registry credential gets a separate 'Harbor (web UI)' row"
else
  bad "harbor: a 'Harbor (web UI)' row must appear when the registry credential is a robot" \
      "the table offers only a robot under 'Access the UIs', and a robot cannot log in there"
fi
if printf '%s' "$_rout" | grep -qE '^  Harbor \(web UI\).*  admin '; then
  ok "harbor: the UI row names the admin USER"
else
  bad "harbor: the UI row names admin" "$(printf '%s' "$_rout" | grep -E '^  Harbor' | head -2)"
fi
# THE CONTROL: with a non-robot username there is nothing to disambiguate, so no extra row.
if printf '%s' "$out" | grep -qE '^  Harbor \(web UI\)'; then
  bad "harbor: the web UI row must NOT appear for a non-robot username" \
      "it printed for HARBOR_USERNAME=admin -- a row that always appears is not a signal"
else
  ok "harbor: no extra UI row when the credential is already admin (it discriminates)"
fi

# POSITIVE CONTROL FIRST. Without it the assertion below passes VACUOUSLY whenever the stub is not
# found, the probe changes shape, or creds.sh stops consulting PATH — i.e. exactly when the gate has
# stopped measuring anything. A negative assertion needs proof the mechanism fired.
if printf '%s' "$out" | grep -q 'cluster      : reachable'; then
  ok "cluster axis: the stub kubectl is honoured — the report reads the cluster as reachable"
else
  bad "cluster axis: the stub was NOT honoured, so every assertion in STATE 8 is vacuous.
      The report did not print 'cluster      : reachable'. Fix the stub before trusting this state."
fi

# THE DEFECT. This is the OWNER's A/B frozen as an assertion.
# ⚠️ MATCH EVERY PHRASING, not the one I happened to fix. The first version of this grepped
# 'nothing installed yet' (no "is") and went GREEN while `NOTHING IS INSTALLED YET` survived one line
# above it, from a DIFFERENT print site. There are five sites in creds.sh that make this claim; a gate
# keyed on one phrasing tests that phrasing, not the property.
if printf '%s' "$out" | grep -qiE 'nothing (is )?installed yet'; then
  bad "reachable cluster + populated .env + no overlay -> the report STILL claims 'nothing installed yet'.
      That is a claim about THE WORLD inferred from '\$_have_sink', a fact about THIS CHECKOUT. The
      cluster answered; the report never asked it. Measured on a live lab running the whole demo."
else
  ok "reachable cluster -> the report does NOT claim nothing is installed"
fi

# The sharper form: not merely wrong, SELF-CONTRADICTORY within one render.
if printf '%s' "$out" | grep -q 'cluster      : reachable' \
   && printf '%s' "$out" | grep -qiE 'nothing (is )?installed yet'; then
  bad "the SAME render says 'cluster: reachable' and 'nothing installed yet' two lines apart.
      A reader cannot tell which to believe, and the report gives them no way to decide."
else
  ok "no render contradicts itself about reachability vs installation"
fi

# The UNREACHABLE arm must keep working — a fix must not simply delete the claim in every state.
out="$(render_with_cluster "$_real_env" 0)"
if printf '%s' "$out" | grep -q 'cluster      : reachable'; then
  bad "cluster axis: the UNREACHABLE stub was reported as reachable — the axis does not discriminate."
else
  ok "cluster axis: an unreachable cluster is reported as such (the axis discriminates)"
fi

# ---- STATE 9: the LAB ACCESS section — the operator asked "why don't I see vCenter credentials" ---
# The answer was that nothing ever printed them. MEASURED 2026-08-20: of 31 credential/endpoint-shaped
# vars in .env.example, 20 never reached this report, including every VCENTER_* and VKS_*.
#
# Both directions, because each fails differently:
#   set   -> the values must APPEAR (a section that drops them IS the original defect)
#   unset -> the section must still RENDER (one that vanishes when empty leaves the reader with no
#            idea the values exist — which is how they stayed missing for so long)
out="$(render_with_env '
VCENTER_HOST=vcsa.example.test
VCENTER_USERNAME=administrator@vsphere.local
SUPERVISOR_HOST=10.0.0.9
VKS_USERNAME=administrator@vsphere.local
')"
if printf '%s' "$out" | grep -q 'Lab access'; then
  ok "lab vars set -> the Lab access section is rendered"
else
  bad "lab vars set -> no Lab access section" "the vCenter/VKS rows the operator asked for are missing"
fi
if printf '%s' "$out" | grep -q 'vcsa.example.test' && printf '%s' "$out" | grep -q '10.0.0.9'; then
  ok "lab vars set -> vCenter and Supervisor endpoints are actually SHOWN"
else
  bad "lab vars set -> the endpoints are not shown" "the section renders but drops its values"
fi
# The lockout warning must travel WITH the row in EVERY arm — a caveat that prints only sometimes is
# the trap rules/common/coding-style.md records.
if printf '%s' "$out" | grep -qi 'PERMANENTLY after 3 failed'; then
  ok "lab vars set -> the vCenter permanent-lockout warning is present"
else
  bad "lab vars set -> no lockout warning" "showing a vCenter credential without it invites a retry"
fi
# NEVER VERIFIED: this printer must not authenticate to vCenter — 3 failed binds lock the SSO account
# PERMANENTLY. Harbor's penalty is a ~1.5s per-principal sleep and Gitea has none, so "we verify
# Harbor" is not an argument for touching this one. Guards the file against a future convenience.
# ---- STATE 9b: the VKS / SSO password cell must not INVENT A CHORE (idea round, 2026-09-05) ----
# MEASURED on a live 9.1 lab: VKS_USERNAME == VCENTER_USERNAME (same account), VCENTER_PASSWORD and
# VCF_CLI_VSPHERE_PASSWORD set, VKS_PASSWORD unset — and unset is CORRECT (.env.example:1761,
# "vsphere method only"). The row rendered a bare `<not set>` between two rows showing a value for
# that same account, so it lied BY CONTRAST: the operator reads a missing credential they do not owe.
#
# ⚠️ CASE (ii) IS THE RED-PROOF, NOT CASE (i). A blanket "not needed" would pass (i) and be FALSE
# under the vsphere method, where the operator genuinely does owe VKS_PASSWORD. Only (ii) catches
# that over-correction — which is why the fix states a fact about the VARIABLE, not about the method.
_ss_vcf="$(render_with_env '
SUPERVISOR_HOST=10.0.0.9
VKS_USERNAME=administrator@vsphere.local
VKS_AUTH_METHOD=vcf
VCF_CLI_VSPHERE_PASSWORD=vcf-secret
')"
# Vacuity guard FIRST: every assertion below is a grep over $out, so an empty render passes them all.
if printf '%s' "$_ss_vcf" | grep -q 'Lab access'; then
  ok "VKS/SSO (i) vcf: the Lab access section rendered at all (vacuity guard)"
else
  bad "VKS/SSO (i) vcf: nothing rendered" "the cases below would pass vacuously on empty output"
fi
if printf '%s' "$_ss_vcf" | grep -qE 'VKS / SSO.*<not set>[[:space:]]*$'; then
  bad "VKS/SSO (i) vcf: cell is a bare <not set>" "invents a chore: unset is CORRECT under the vcf method"
else
  ok "VKS/SSO (i) vcf: cell is not a bare <not set>"
fi
# (ii) vsphere + unset: the operator DOES owe it here, so the obligation must stay visible.
# ⚠️ THE FIXTURE MUST SATISFY EVERY EARLIER REQUIREMENT. _vks_login_requires' vsphere arm is ordered
# SUPERVISOR_HOST -> VKS_NAMESPACE -> VKS_CLUSTER_NAME -> VKS_USERNAME -> VKS_PASSWORD, and STATE 10
# pins that the trailer names only the FIRST unmet one and then goes silent. My first draft omitted
# VKS_NAMESPACE/VKS_CLUSTER_NAME, so the trailer correctly named VKS_NAMESPACE and this case failed
# against a CORRECT product — the instrument, not the product (rules/common/gates.md: distrust your
# own RED-test first). Setting them makes VKS_PASSWORD genuinely first-unmet, which is the state
# whose obligation this case exists to assert.
_ss_vsp="$(render_with_env '
SUPERVISOR_HOST=10.0.0.9
VKS_NAMESPACE=demo-ns
VKS_CLUSTER_NAME=demo-cluster
VKS_USERNAME=administrator@vsphere.local
VKS_AUTH_METHOD=vsphere
')"
if printf '%s' "$_ss_vsp" | grep -q 'VKS_PASSWORD'; then
  ok "VKS/SSO (ii) vsphere+unset: VKS_PASSWORD is still named as a requirement"
else
  bad "VKS/SSO (ii) vsphere+unset: the obligation vanished" "under vsphere the operator DOES owe VKS_PASSWORD; a blanket 'not needed' is FALSE here"
fi
# (iii) vsphere + set: the normal path must be unbroken — the value reaches the cell.
_ss_set="$(render_with_env '
SUPERVISOR_HOST=10.0.0.9
VKS_USERNAME=administrator@vsphere.local
VKS_AUTH_METHOD=vsphere
VKS_PASSWORD=vks-secret
')"
if printf '%s' "$_ss_set" | grep -qE 'VKS / SSO.*(vks-secret|<hidden)'; then
  ok "VKS/SSO (iii) vsphere+set: the value renders (masked or revealed)"
else
  bad "VKS/SSO (iii) vsphere+set: the value did not render" "the marker swallowed a real credential"
fi
# (iv) VKS_AUTH_METHOD UNSET — the SHIPPED DEFAULT (.env.example:1192 ships it COMMENTED), and the
# state a method-keyed marker would render as gibberish (`<not needed: VKS_AUTH_METHOD=>`).
_ss_dflt="$(render_with_env '
SUPERVISOR_HOST=10.0.0.9
VKS_USERNAME=administrator@vsphere.local
')"
if printf '%s' "$_ss_dflt" | grep -qE 'VKS_AUTH_METHOD=[[:space:]>]'; then
  bad "VKS/SSO (iv) method unset: gibberish marker" "a method-keyed cell renders an empty value in the SHIPPED default state"
else
  ok "VKS/SSO (iv) method unset: no gibberish marker in the shipped default state"
fi

# ── B202 F6: the ATOMIC-PAIR guard, as an ASSERTION rather than a comment ───────────────────────
# A Harbor credential read that sets the password WITHOUT the username in the same statement rebuilds
# the mixed pair whose 401 is MEASURED at 22-harbor-robot.sh:200-206, and promotes admin over the
# Step 9 robot.
#
# ⚠️ THE FIRST VERSION OF THIS ASSERTION WAS VACUOUS and printed a FALSE ALL-CLEAR (impl round,
# HIGH 2). It grepped `HARBOR_PASSWORD=` — but the variable that actually feeds the Harbor row is
# `harbor_pw` (creds.sh assigns it, the table renders it). MEASURED: a real
# `harbor_pw="$(kubectl ... | base64 -d)"` rendered GREEN and printed "the atomic-pair hazard stays
# closed". It only fired on `HARBOR_PASSWORD=`, the one shape nobody would write. So it modelled the
# hazard it could imagine rather than the one the file can actually grow.
#
# TWO fixes, both load-bearing:
#   * match BOTH names, and
#   * FOLD `\`-continuations first — the read is likely to be wrapped across lines, and a
#     line-oriented grep cannot see a pair split over two of them.
# NO `grep -qv`: the impl round measured that the harness grep (ugrep) returns 0 for
# `<empty> | grep -qv X` where GNU grep returns 1 — i.e. the exact construct whose exit code cannot
# be trusted across implementations. Capture the text and test the STRING instead.
_creds_folded="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "${_CREDS_REPO}/scripts/creds.sh")"
_atomic_bad="$(printf '%s\n' "$_creds_folded" \
  | grep -nE '^[^#]*(HARBOR_PASSWORD|harbor_pw)=.*(kubectl|jsonpath|base64 -d)' \
  | grep -v 'HARBOR_USERNAME')"
if [ -n "$_atomic_bad" ]; then
  bad "creds.sh gained a live Harbor credential read with no HARBOR_USERNAME in the same statement:
      $(printf '%s' "$_atomic_bad" | head -2)" \
      "username and secret must move as ONE atomic pair from ONE source; a mixed pair is a MEASURED 401"
else
  ok "creds.sh has no field-by-field Harbor credential read (the atomic-pair hazard stays closed)"
fi
if grep -qE 'vc_login|vc_api' "${_CREDS_REPO}/scripts/creds.sh"; then
  bad "creds.sh acquired a vCenter auth call" "3 failed binds lock the SSO account PERMANENTLY; this file SHOWS, never verifies"
else
  ok "creds.sh still never authenticates to vCenter (no vc_login / vc_api)"
fi
out="$(render_with_env '')"
if printf '%s' "$out" | grep -q 'Lab access'; then
  ok "lab vars UNSET -> the section still renders (it does not vanish and hide that the values exist)"
else
  bad "lab vars UNSET -> the section vanished" "the reader cannot learn these values exist"
fi

fi

# ── STATE 10 — B207: the report must name the FIRST unmet vks-login requirement, and go SILENT ──
# The defect: `flow : real VKS lab (VKS_AUTH_METHOD=vcf)` printed while the credential that method
# needs read `<not set>` two sections below, and the report then prescribed `make vks-login`, which
# in that state cannot run. Three things are pinned here, and the THIRD is the one that keeps this
# from becoming the false-advice class it was written to remove.
_b207() {  # _b207 <env-body> -> the rendered report
  render_with_cluster "$1" 1
}

# (a) UNHEALTHY: names the first unmet requirement IN DISPATCH ORDER.
out="$(_b207 'VKS_AUTH_METHOD=vcf
HARBOR_URL=harbor.example.test')"
if printf '%s' "$out" | grep -q 'first\n*.*not satisfied is SUPERVISOR_HOST' \
   || printf '%s' "$out" | tr '\n' ' ' | grep -q 'not satisfied is SUPERVISOR_HOST'; then
  ok "B207: names SUPERVISOR_HOST — the FIRST requirement vks-login dies on under vcf"
else
  bad "B207: did not name SUPERVISOR_HOST as the first unmet requirement.
      This is the ordering bug the idea round caught: naming VCF_CLI_VSPHERE_PASSWORD would send the
      operator to fix the THIRD blocker while 30-vks-login.sh:59 dies on the FIRST."
fi

# (b) It MUST name the password once the `:?` requirements are met — and give the RIGHT reason.
# ⚠️ This assertion was INVERTED in the first draft ("must NOT name it"), on the strength of the
# idea round's correct observation that VCF_CLI_VSPHERE_PASSWORD only WARNS. It does warn — and
# then `vcf context create` runs with `</dev/null` UNCONDITIONALLY (30-vks-login.sh:380) with NO
# short-circuit between them, so it fails anyway. Measured. Leaving it out made the note SILENT on
# the exact box the operator reported, i.e. the whole defect survived its own fix.
out_pw="$(_b207 'VKS_AUTH_METHOD=vcf
SUPERVISOR_HOST=supervisor.example.test
VKS_CONTEXT_NAME=fixture-context
HARBOR_URL=harbor.example.test')"
if printf '%s' "$out_pw" | tr '\n' ' ' | grep -q 'not satisfied is VCF_CLI_VSPHERE_PASSWORD'; then
  ok "B207: names VCF_CLI_VSPHERE_PASSWORD once the die-on-unset requirements are satisfied"
else
  bad "B207: went SILENT with only the password missing - that is the operator's exact box."
fi
if printf '%s' "$out_pw" | tr '\n' ' ' | grep -q 'cannot prompt for it'; then
  ok "B207: gives the RIGHT reason for the password (</dev/null, not a requirement check)"
else
  bad "B207: named the password but not WHY - it does not die at a check, it fails at context create."
fi

# (c) HEALTHY: SILENCE. gates.md — advice guarded on the FINDING, never the category; and ask what
# happens if the operator DOES what you told them. Without this case the note fires on a correct box.
out_ok="$(_b207 'VKS_AUTH_METHOD=vcf
SUPERVISOR_HOST=supervisor.example.test
VKS_CONTEXT_NAME=fixture-context
VCF_CLI_VSPHERE_PASSWORD=fixture-value-not-a-real-secret
HARBOR_URL=harbor.example.test')"
if printf '%s' "$out_ok" | tr '\n' ' ' | grep -q 'not satisfied is'; then
  bad "B207: the note FIRED on a box with every requirement satisfied — false advice."
else
  ok "B207: SILENT when every vks-login requirement is met"
fi

# ── STATE 12 — the branch the MATRIX hits, which the B517 fix left unrepaired. ────────────────────
# `state-overlay: SOURCED`, `values-provenance: STORED`, no INGRESS_LB_IP: a box that simply has not
# installed an ingress, i.e. EVERY scenario-2 row. The B517 fix repaired the REFUSED arm and stopped
# there, so the false world-claim survived in the arm that actually runs. MEASURED on one cluster,
# 72m30s apart: row 3 printed `SUCCESS — all 8 UI(s) reachable ... at 192.168.101.134` with 8/8 body
# markers; row 6 printed `<needs ingress>` x8 plus `nothing serves those hosts`.
_kc12="$(mktemp)"
cat > "$_kc12" <<'KC12'
apiVersion: v1
kind: Config
current-context: c
clusters:
- name: c
  cluster: {server: 'https://127.0.0.1:1'}
contexts:
- name: c
  context: {cluster: c, user: u}
users:
- name: u
  user: {token: t}
KC12
# ⚠️ ITS OWN RENDER, NOT `render`. Routing this case through the shared helper produced an $out in
# which the note was ABSENT -- measured: the identical fixture rendered by hand contained the
# mutated sentence (1 match) while the suite reported 0 FAILs, so the case pinned NOTHING and its
# green was indistinguishable from a passing product. `render` resolves the sink through
# `state_file()`; this pins VKS_STATE_FILE explicitly, which is the form proven to reach the arm.
_sink12="$(mktemp)"
printf 'VKS_STATE_KIND=1\nVKS_STATE_SERVER=https://127.0.0.1:1\nHARBOR_URL=h.example\n' > "$_sink12"
out="$( VKS_STATE_FILE="$_sink12" KUBECONFIG="$_kc12" SKIP_DOTENV=1 CREDS_TOKEN=1 \
        timeout 90 ./scripts/creds.sh 2>/dev/null )"
rm -f "$_kc12" "$_sink12"

if [ -z "$out" ]; then bad "STATE 12: creds.sh produced NO OUTPUT — every assertion below is vacuous"; fi
if printf '%s' "$out" | grep -q '^state-overlay: SOURCED'; then ok "STATE 12: the overlay IS in play — this is the matrix's own cell, not the refused one"
else bad "STATE 12: state-overlay is '$(printf '%s' "$out" | grep -m1 '^state-overlay:' || echo NONE)'; the fixture never reached the SOURCED arm, so this case tests nothing"; fi
if printf '%s' "$out" | grep -q 'nothing serves those hosts'; then
  bad "STATE 12: the SOURCED arm still asserts 'nothing serves those hosts' — a claim about the CLUSTER derived from a variable about THIS BOX, in the arm every scenario-2 row hits"
else ok "STATE 12: the SOURCED arm makes no claim about the cluster"; fi
if printf '%s' "$out" | grep -q 'not about the cluster'; then ok "STATE 12: ...and says so explicitly, so a reader cannot infer one"
else bad "STATE 12: the note never says the absence is about this report; a reader will take it as a fact about the cluster"; fi
if printf '%s' "$out" | grep -q 'port-forward'; then ok "STATE 12: and the port-forward remedy survives"
else bad "STATE 12: the port-forward is gone — the only remedy correct in every persona"; fi

# ⚠️ THE VERDICT IS RE-EVALUATED HERE, and it must be. The `if [ "$fail" = 0 ]` that opens at ~line 300
# is a FAIL-FAST gate deciding whether to RUN the later states — it is not the verdict. It was also
# PRINTING the verdict from inside its own branch, so its condition was read ONCE at line 300 and the
# SUCCESS banner then fired unconditionally at the end. Measured 2026-08-20 while adding STATE 8: the
# suite printed two `FAIL` lines and then "SUCCESS — creds-show tells the truth in every state".
# `exit "$fail"` was correct throughout, so CI never mis-reported — but a HUMAN reading the output saw
# SUCCESS above their own failures, which is the one thing this gate exists to not do.
# ── STATE 11 — B517: an overlay the LOADER REFUSED must not be reported as authoritative ──────────
# THE STATE THAT WAS UNREACHABLE HERE. Every case above varies the overlay's CONTENT while the
# kubeconfig stays sandboxed, so "a sink exists, is well-formed, and `load_env` REFUSED it because it
# is stamped for a DIFFERENT cluster" could not be constructed — and that is precisely the state the
# owner hit. MEASURED 2026-08-28, one command against a real lab guest cluster:
#
#     level=ERROR  state: .env.state was written for a DIFFERENT cluster. NOT sourcing it
#     ...six lines later...
#       values below : DISCOVERED — the overlay is stamped for the cluster you are talking to
#       flow         : KinD stand-in (the state overlay is stamped by the KinD flow)
#       Gitea / Tekton / all six apps   <needs ingress>
#       note: no ingress is installed, so ... nothing serves those hosts
#
# while that cluster served 8/8 HTTP 200 through a Gateway with attachedRoutes=8. The header
# contradicted the loader's own ERROR six lines above it, because every question was answered by
# GREPPING THE SINK rather than by reading `_VKS_STATE_SOURCED`, which `load_env` has exported all
# along and `state.sh:90` has keyed on since B142.
#
# The fixture needs a REAL kubeconfig file (creds.sh parses it; it never dials for this), stamped
# against a DIFFERENT server. That mismatch is the whole trigger.
# ⚠️ 127.0.0.1:1, NOT A ROUTABLE ADDRESS. A first version used 10.255.255.9, which `ip route get`
# resolves via the box's DEFAULT GATEWAY -- so this "offline" suite DIALLED a third-party host on
# every CI run (`test-creds-show` carries no ci-tier marker, so it is in TEST_FAST -> test-scripts ->
# static-check -> make ci). MEASURED: the suite went 3.92s -> 17.63s, one render 13.33s vs 2.22s,
# attributable to argocd-password.sh (10.1s) + `kubectl version` (3.03s) against that address. On a
# corporate LAN with a 10/8 route it reaches someone else's machine. 127.0.0.1:1 gives the identical
# REFUSED verdict in 0.36s with zero off-box packets. It also DEFEATS the KUBECONFIG sandbox this
# file RED-proved at its top (78s -> 0s), which is the reason that sandbox exists.
_refused_kc="$(mktemp)"
cat > "$_refused_kc" <<'KCEOF'
apiVersion: v1
kind: Config
current-context: refused-test
clusters:
- name: refused-test
  cluster: {server: 'https://127.0.0.1:1'}
contexts:
- name: refused-test
  context: {cluster: refused-test, user: refused-test}
users:
- name: refused-test
  user: {token: not-a-real-token}
KCEOF
# Stamped for a DIFFERENT server than the kubeconfig above, and KinD-stamped so the arm that used to
# short-circuit to DISCOVERED is the one under test.
_refused_sink="$(printf 'VKS_STATE_KIND=1\nVKS_STATE_SERVER=https://127.0.0.1:44444\nVKS_STATE_CONTEXT=kind-elsewhere\nINGRESS_LB_IP=10.9.9.9\nHARBOR_URL=harbor.elsewhere\n')"
out="$(KUBECONFIG="$_refused_kc" render "$_refused_sink")"
rm -f "$_refused_kc"

# ⚠️ THE OVERLAY AXIS IS ITS OWN TOKEN, NOT A FOURTH `values-provenance` VALUE. B204 refuted a 4th
# enum on the ground that `_prov` and `env-populated` are ORTHOGONAL; a REFUSED overlay is a THIRD
# axis and gets a third token. So the pin is the TRIPLE: the overlay is REFUSED, and provenance
# behaves exactly as it would with no overlay at all -- which, when it was refused, is literally true.
# ⚠️ AN EMPTY RENDER MAKES EVERY ABSENCE ASSERTION BELOW PASS VACUOUSLY. Measured: an unbound
# variable killed creds.sh, `$out` was empty, and the three "the report does NOT say X" cases went
# GREEN over a report that did not exist. Check the render produced something FIRST.
if [ -z "$out" ]; then
  bad "STATE 11: creds.sh produced NO OUTPUT — it died. Every assertion below is vacuous; run it by hand with the same fixture and read stderr."
fi
if printf '%s' "$out" | grep -q '^state-overlay: REFUSED'; then
  ok "STATE 11: a REFUSED overlay is reported on its OWN token"
else
  bad "STATE 11: state-overlay is '$(printf '%s' "$out" | grep -m1 '^state-overlay:' || echo NONE)' for an overlay load_env refused — the KinD arm greps the FILE, so it matches whatever cluster you point at"
fi
if printf '%s' "$out" | grep -q 'values-provenance: DEFAULT'; then
  ok "STATE 11: and provenance is DEFAULT — not DISCOVERED, and not a fourth enum value (B204)"
else
  bad "STATE 11: provenance is '$(printf '%s' "$out" | grep -m1 'values-provenance:' || echo NONE)'; a refused overlay is, for provenance, NO overlay"
fi
if printf '%s' "$out" | grep -q 'flow *: *undetermined — a state overlay exists but was REFUSED'; then
  ok "STATE 11: and the flow line does not claim the refused overlay's flow"
else
  bad "STATE 11: flow says '$(printf '%s' "$out" | grep -m1 'flow ' || echo NONE)' — computed from a file that is not in scope"
fi
# ⚠️ ASSERT THE ABSENCE OF THE DEFECT'S OWN SENTENCE, NOT THE PRESENCE OF A NEW ONE. A first version
# grepped for two words of the replacement ("This says") and was MUTATION-PROVEN worthless: restoring
# the ORIGINAL FALSE note verbatim and appending "This says it all." kept the suite at 46/46 GREEN,
# including this very case. A gate that greps prose is testing the prose -- STATE 1's own comment
# says so. The defect is the sentence `no ingress is installed, so ... nothing serves those hosts`,
# and its absence is the property.
if printf '%s' "$out" | grep -q 'no ingress is installed'; then
  bad "STATE 11: the ingress note still asserts 'no ingress is installed ... nothing serves those hosts' from a REFUSED overlay — the measured case had all eight hosts serving 200"
else
  ok "STATE 11: the ingress note does NOT assert the cluster has no ingress"
fi
# ...and it must still hand the operator a remedy that WORKS in this state. `make verify-ingress` is
# hard-guarded on the very variable whose absence produced the note, so it dies without checking
# anything; `make install-ingress` would helm-install a mesh into a cluster this report has just
# disclaimed, which a Scenario-2 tenant must never do. The port-forward is read-only and correct in
# every persona.
if printf '%s' "$out" | grep -q 'port-forward'; then
  ok "STATE 11: and it offers the port-forward — the only remedy correct in every persona"
else
  bad "STATE 11: the refused note names no working remedy; a fix that repairs the CLAIM and breaks the ACTION is not a fix"
fi
if printf '%s' "$out" | grep -qE 'note:.*(make verify-ingress|make install-ingress)'; then
  bad "STATE 11: the note prescribes verify-ingress (hard-dies on the missing variable) or install-ingress (installs a mesh into a disclaimed cluster)"
else
  ok "STATE 11: and it prescribes neither a command that cannot run nor one that installs a mesh"
fi
# THE FOURTH FALSE CLAIM. Under a refusal the password WAS published -- for another cluster -- so
# "check the state overlay" sent the operator to read a FOREIGN credential out of the file the
# Context block has just said is not in play.
# ⚠️ THIS WENT VACUOUS ON 2026-09-05 AND WAS CAUGHT THE SAME DAY. It asserted the ABSENCE of the
# literal 'not published — check the state overlay'. That string was then shortened to
# '<not published — see note>' when the password sentences moved to a footnote, so the grep could
# never match again and the case passed unconditionally -- a guard measuring nothing.
# An absence-only assertion cannot distinguish "the product is right" from "my needle no longer
# exists". It now carries a POSITIVE control: the REFUSED arm must SAY it refused.
if printf '%s' "$out" | grep -q 'check the state overlay'; then
  bad "STATE 11: the password column still says 'check the state overlay' — that overlay is another cluster's, and this points the operator straight at its credential"
elif ! printf '%s' "$out" | grep -q 'REFUSED'; then
  bad "STATE 11: the report never says the overlay was REFUSED, so the negative above is VACUOUS —
      it cannot tell a correct report from one whose wording merely changed."
else
  ok "STATE 11: the password column does not send the operator to a foreign cluster's credential, and does say the overlay was REFUSED"
fi
# ...and the refused values must not leak into the table. HARBOR_URL=harbor.elsewhere belongs to the
# other cluster; if it appears, the sink was sourced after all and the refusal is cosmetic.
if printf '%s' "$out" | grep -q 'harbor.elsewhere'; then
  bad "STATE 11: a REFUSED overlay's HARBOR_URL reached the table — it was sourced despite the refusal"
else
  ok "STATE 11: and none of the refused overlay's values reached the table"
fi

# ⚠️ SAY HOW MANY ASSERTIONS ACTUALLY RAN. MEASURED by an adversary: mutating creds.sh to print
# zero rows took `ok` from 52 to 24 while FAIL only went 2 -> 7 -- ~28 assertions VANISHED,
# including BOTH secret-guard cases and the .env-immunity case, with no notice of any kind. A
# reader sees a smaller count and no explanation. This file's own rule, stated on the pty case, is
# that a skipped case saying nothing is indistinguishable from a passing one.
# NO HARDCODED EXPECTED TOTAL, deliberately -- that number rots on the next assertion added, and a
# rotting constant is how a gate starts lying. The honest signal is the count plus the fact that
# the fail-fast block was entered.
# ── STATE 13 — THE vCenter NOTE (B536). Added because this suite was byte-identical before and
# after the change that introduced the note: deleting the header change AND the note left it GREEN.
# "still 136/136" was true and VACUOUS — the corpus had never grown to cover it (gates.md).
#
# The SECOND case is the one that matters. The note's first condition globbed the rendered
# multi-row blob (`case "$_lab_rows" in *"vCenter"*"<not set>"*`), and a glob SPANS NEWLINES — so a
# blank in ANY LATER row satisfied it and the note printed "The vCenter row is blank" directly
# beneath a FULLY POPULATED vCenter row. Worst case measured: VCENTER_* all set but SUPERVISOR_HOST
# not yet, which is the DOCUMENTED INTERMEDIATE STATE of scenario-1 — the note told that reader
# "you have not set them yet" about values they had just typed.
out="$(render_with_env 'VKS_USERNAME=admin@vsphere.local
SUPERVISOR_HOST=sup.example.test
VCF_CLI_VSPHERE_PASSWORD=x')"
if printf '%s' "$out" | grep -q 'The vCenter row is blank'; then
  ok "STATE 13: a tenant with NO VCENTER_* gets the vCenter note (the true positive)"
else
  bad "STATE 13: the vCenter note did not fire for a tenant" \
      "the note is the whole B536 fix; without it the three blanks are unexplained again"
fi

# THE RED-PROOF: vCenter POPULATED, another row blank. Must be SILENT.
out="$(render_with_env 'VCENTER_HOST=vc.example.test
VCENTER_USERNAME=administrator@vsphere.local
VCENTER_PASSWORD=p
VKS_USERNAME=administrator@vsphere.local
SUPERVISOR_HOST=sup.example.test')"
if printf '%s' "$out" | grep -q 'The vCenter row is blank'; then
  bad "STATE 13: the note fired with vCenter POPULATED" \
      "a blank in a LATER row satisfied the condition — the note is now a FALSE claim, printed
       directly beneath a filled-in vCenter row, which is the defect this change exists to remove"
else
  ok "STATE 13: vCenter populated + another row blank -> the note is SILENT (the F1 RED-proof)"
fi


# ── STATE 14 — the HARBOR ADMIN-PASSWORD footnote. Added 2026-09-07 after an implementation round
# found FOUR defects in it that a green 66/66 had shipped: it rendered only when the HEADLAMP token
# had been read; the classifier on the secret read was dead code; a kubectl that SUCCEEDED with no
# matching namespace was reported as "kubectl failed"; and the remedy sentence stated an absolute
# that is false in the healthy state. `grep -c` for its strings in this file was 0 — the change moved
# the suite's denominator by +1, and that +1 was a different change entirely.
_h_render() {  # _h_render <kubectl-body> <headlamp-token-readable:0|1> -> the rendered report
  local kbody="$1" hl="$2" t
  t="$(mktemp -d)"; mkdir -p "$t/bin"
  cp .env.example "$t/.env.example"
  # A ROBOT username is what makes the Harbor web-UI row render at all; without it the block is
  # skipped and every assertion here would be vacuous.
  # ⚠️ SINGLE-QUOTED. `load_env` sources .env with `set -a`, so an unquoted `robot$probe` has its
  # `$probe` EXPANDED BY THE SHELL to empty and HARBOR_USERNAME arrives as plain `robot` — which is
  # not a robot by `harbor_username_is_robot`, so the row is skipped and every assertion below goes
  # vacuous. That is the trap `check-doc-robot-quoting` exists for, and this fixture fell into it on
  # its first run: three assertions failed for a reason that had nothing to do with the code.
  printf "HARBOR_URL=10.0.0.1\nHARBOR_USERNAME='robot\$probe'\nHARBOR_PASSWORD=x\n" > "$t/.env"
  # ⚠️ `$t/sup` MUST BE NON-EMPTY, and `: >` meant this fixture never exercised what it claimed.
  # `supervisor_kubeconfig()` requires `[ -s "$c" ]`, so an EMPTY file is correctly REJECTED and the
  # resolver falls through to `supervisor_kubeconfig_candidates()`, whose last slot is
  # `${VKS_LAB_STATE_DIR:-$HOME/.local/state/nested-lab}` -- the SIBLING lab repo's state dir.
  # MEASURED: on this box that resolved to a REAL lab kubeconfig, so the STATE-14 cases passed by
  # exercising MY MACHINE'S LAB STATE; in CI nothing resolved, `_h_sup` was empty, the report took
  # the "no Supervisor kubeconfig here" branch, and the case failed.
  #
  # ⚠️ THE PRODUCT IS NOT AT FAULT -- I filed it as a product bug first and that was WRONG. Both
  # branches are correct: with no Supervisor it says so and does NOT name `make vks-login` (a round
  # refuted that), and with one it asks and classifies. The fixture never set up the state its
  # assertions describe. `VKS_LAB_STATE_DIR` is pinned too, so a sibling repo can never decide this
  # FIXTURE's outcome again. (The suite-wide pin at the top is what covers the other fixtures --
  # this per-fixture one is belt-and-braces, and the claim is deliberately narrow: an earlier
  # round refuted the wider "this test's outcome" wording, because 3 of 5 fixtures were unpinned.)
  : > "$t/kc"
  # CONTENT IS NEVER PARSED -- kubectl is fully stubbed in this fixture. Only `[ -s ]` matters, so
  # this is a non-empty MARKER, not a kubeconfig. Do not "improve" it into a realistic one.
  printf 'apiVersion: v1\nkind: Config\n' > "$t/sup"
  { printf '#!/bin/sh\n'
    printf 'case "$*" in\n'
    printf '  *current-context*) echo stub-ctx; exit 0 ;;\n'
    printf '  *version*) exit 0 ;;\n'
    if [ "$hl" = 1 ]; then printf '  *"create token"*) echo hl-token; exit 0 ;;\n'; fi
    printf '%s\n' "$kbody"
    printf 'esac\nexit 0\n'; } > "$t/bin/kubectl"
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/curl"
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/getent"
  chmod +x "$t/bin/kubectl" "$t/bin/curl" "$t/bin/getent"
  ( cd "$t" && PATH="$t/bin:$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      KUBECONFIG="$t/kc" VKS_SUPERVISOR_KUBECONFIG="$t/sup" CREDS_TOKEN=1 \
      VKS_LAB_STATE_DIR="$t/no-lab" \
      "${_CREDS_REPO}/scripts/creds.sh" 2>/dev/null )
  rm -rf "$t"
}

# (a) the Supervisor REJECTS us -> the footnote must be present AND name the class, not a bare token.
_hout="$(_h_render '  *"get ns"*) echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;' 1)"
if printf '%s' "$_hout" | grep -q 'Harbor admin password NOT read'; then
  ok "STATE 14: a rejected Supervisor -> the Harbor footnote EXPLAINS it"
else
  bad "STATE 14: a rejected Supervisor -> NO footnote. The cell shows a token with nothing to read it by."
fi

# (b) THE FINDING-1 RED-PROOF. Identical failure, headlamp token NOT readable. The footnote must
# still render: it was nested inside `if [ "${_headlamp_note:-0}" = 1 ]`, so it did not, and the
# persona who lost it was the tenant with neither a Supervisor nor headlamp.
_hout="$(_h_render '  *"get ns"*) echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;' 0)"
if printf '%s' "$_hout" | grep -q 'Harbor admin password NOT read'; then
  ok "STATE 14: ...and it does NOT depend on the headlamp token having been read"
else
  bad "STATE 14: the footnote vanished when headlamp was unread — it is nested inside the headlamp
      block again. Two unrelated facts must not be welded together."
fi

# (c) kubectl SUCCEEDS with no matching namespace. rc=0 is a SUCCESS: Harbor simply is not a
# Supervisor Service here. Reporting "kubectl failed" is the conflation this change exists to remove.
_hout="$(_h_render '  *"get ns"*) exit 0 ;;' 1)"
if printf '%s' "$_hout" | grep -q 'has NO namespace labelled'; then
  ok "STATE 14: rc=0 with no match is reported as ABSENT, not as a kubectl failure"
else
  bad "STATE 14: rc=0 + empty was reported as a failure. kubectl exited 0 and answered correctly;
      saying it failed is the same wrong-cause class, inverted."
fi
if printf '%s' "$_hout" | grep -qi 'kubectl failed for a reason we do not classify'; then
  bad "STATE 14: it claims kubectl failed when kubectl exited 0 (empty errfile -> UNKNOWN)."
else
  ok "STATE 14: ...and makes no claim about a kubectl that did not fail"
fi

# (d) the remedy sentence must not state the refusal as an absolute — 28-harbor-admin-password.sh
# ALSO has an exit-0 arm that leaves a working robot credential alone.
if printf '%s' "$_hout" | grep -q 'REFUSES by design'; then
  bad "STATE 14: the footnote asserts an unconditional refusal. The healthy arm exits 0 instead."
else
  ok "STATE 14: the remedy sentence covers BOTH arms of harbor-admin-password"
fi

# ── B548: an ABSENT Supervisor kubeconfig must NOT prescribe `make vks-login` ────────────────────
# THE PARTIAL-FIX CASE. f0b7d07 fixed the Harbor cell's identical branch (creds.sh:1116-1121) and
# LEFT THIS SIBLING, so the shipped file carried the written refutation of its own other half. This
# pins both halves so a future fix cannot be 1-of-2 again.
#
# `absent` is undecidable — tenant-normal (RULE ZERO-B default) vs scenario-1-not-yet-logged-in — and
# the remedy is what encodes the guess. `make vks-login` spends one of THREE vCenter SSO attempts
# before PERMANENT lockout, so guessing here has an irreversible tail.
# ⚠️ VKS_LAB_STATE_DIR MUST BE NEUTRALISED, and finding that out was itself the B547 defect firing
# inside this test. Without it `supervisor_kubeconfig` falls through its candidate list to
# ~/.local/state/nested-lab/kubeconfig — ANOTHER REPO's lab state dir, which exists on a maintainer
# box — so the fixture silently took the "cluster publishes no node-SSH secret" branch and every
# assertion below was vacuous while printing ok. An end user has no such directory; a maintainer does.
_b548="$(render_with_cluster 'VKS_NAMESPACE=cicd
HARBOR_URL=10.0.0.1
VKS_LAB_STATE_DIR=/nonexistent-for-this-test
' 1)"
if printf '%s' "$_b548" | grep -q 'Guest-node SSH password NOT read'; then
  ok "B548: the tenant fixture reaches the SSH-absent branch (the case is not vacuous)"
else
  bad "B548: fixture never reached the SSH branch — every assertion below would be vacuous."
fi
if printf '%s' "$_b548" | grep -qE 'no Supervisor kubeconfig.*run: make vks-login'; then
  bad "B548: an ABSENT Supervisor kubeconfig prescribes 'make vks-login'. It is undecidable whether
      the reader is a tenant (normal) or an operator who has not logged in, and a wrong guess spends
      one of three vCenter SSO attempts before PERMANENT lockout."
else
  ok "B548: ...and it does NOT prescribe make vks-login for an absent kubeconfig"
fi
if printf '%s' "$_b548" | grep -q 'ask your platform team'; then
  ok "B548: ...it names the only remedy a tenant can actually perform"
else
  bad "B548: it went silent instead. 'I could not ask' must still say WHERE the value lives."
fi
# THE CONTROL, and it is what stops this becoming a blanket ban: the UNAUTHORIZED arm names
# `make vks-login` CORRECTLY, because a kubeconfig that EXISTS and was REJECTED is a DECIDABLE state.
# ⚠️ KEYED ON THE PROPERTY, NOT ON ONE LITERAL. This used to grep
# 'the Supervisor REJECTED this kubeconfig. Re-run: make vks-login' — and that exact string was
# MEASURED WRONG on 2026-09-07: under VKS_AUTH_METHOD=kubeconfig, `make vks-login` verifies the
# GUEST kubeconfig (30-vks-login.sh:42-45) and never touches the Supervisor, so the remedy was a
# no-op for the failure it was printed for. A control pinned to a defective literal fires RED on the
# FIX and green on the defect, so it now asserts what B548 actually adjudicated — the decidable arm
# still points somewhere actionable — plus the specific regression, so the no-op cannot come back.
# B556: the arm now DELEGATES to `_rejected_why`, so the sentence lives one indirection away.
# Pinning to the arm's own text made this control fire RED on a FIX (measured 2026-09-08) -- the
# same location-vs-property defect the comment above already records. Follow the delegation:
# extract the arm AND, if it calls a helper, that helper's body. A control that cannot see where
# the sentence moved is not a weaker control, it is a WRONG one.
_ua="$(sed -n '/UNAUTHORIZED)/,/;;/p' "${_CREDS_REPO}/scripts/creds.sh")"
_ua="${_ua}
$(sed -n '/^_rejected_why() {/,/^}/p' "${_CREDS_REPO}/scripts/creds.sh")"
# ...and one level FURTHER: `_rejected_why` itself delegates the remedy to a helper. Chasing that by
# hand broke this control TWICE in one session (2026-09-08), each time firing RED on a FIX -- so
# follow the delegation MECHANICALLY: pull the body of every `$(_helper)` the extract calls. A
# control that must be hand-updated on every refactor is a control that will be wrong next refactor.
# shellcheck disable=SC2016  # the single quotes are the POINT: `$(` is a LITERAL to match in the
# extracted source, not an expansion. Double-quoting it would make the shell substitute it here.
# ⚠️ SEARCH BOTH FILES. The helper was HOISTED into lib/os.sh (so argocd-password.sh could share
# ONE sentence instead of a hand-duplicated copy that drifted), and a follower that looks only in
# creds.sh then finds an empty body and fires RED on a correct tree. MEASURED: that is exactly what
# happened on the hoist commit. A delegation-follower must follow the delegation ACROSS FILES too.
for _h in $(printf '%s' "$_ua" | grep -oE '\$\(_?[a-z_]+\)' | tr -d '$()' | sort -u); do
  for _src in "${_CREDS_REPO}/scripts/creds.sh" "${_CREDS_REPO}/scripts/lib/os.sh"; do
    _ua="${_ua}
$(sed -n "/^${_h}() {/,/^}/p" "$_src")"
  done
done
# ...and one hop further: `_renew_how` is now a thin alias, so the SENTENCE is one more level down.
for _h in $(printf '%s' "$_ua" | grep -oE 'supervisor_renew_how' | sort -u); do
  _ua="${_ua}
$(sed -n "/^${_h}() {/,/^}/p" "${_CREDS_REPO}/scripts/lib/os.sh")"
done
if printf '%s' "$_ua" | grep -q 'REJECTED this kubeconfig'; then
  ok "B548: the DECIDABLE arm (UNAUTHORIZED) still says what happened"
else
  bad "B548: the UNAUTHORIZED arm lost its diagnosis. A rejected kubeconfig IS a decidable state."
fi
if printf '%s' "$_ua" | grep -qE 'VKS_AUTH_METHOD=vcf'; then
  ok "B548: ...and NAMES the remedy command (make vks-login VKS_AUTH_METHOD=vcf), not a section"
else
  bad "B548: the arm names no way forward. Naming only the diagnosis leaves the reader knowing they
      are broken with no path (lib/os.sh:1964-1965 records that as its own defect)."
fi
# ⚠️ Do NOT try to catch "a bare make vks-login" by pattern. MEASURED 2026-09-08: `make vks-login[^V]*$`
# fires on the arm's own EXPLANATION of why the bare form is wrong -- a false RED on correct text,
# and its only remedy is deleting the explanation. The regression is caught POSITIVELY instead, by
# the VKS_AUTH_METHOD=vcf assertion above: reverting to the bare form removes that string and turns
# THAT control red. This one keeps only the exact defective literal B548 adjudicated.
if printf '%s' "$_ua" | grep -qE 'Re-run: make vks-login'; then
  bad "the arm prescribes a bare 'make vks-login' again. MEASURED 2026-09-07: under
      VKS_AUTH_METHOD=kubeconfig that renews the GUEST kubeconfig and does NOTHING for the
      Supervisor — it is a no-op for the very failure it is printed for."
else
  ok "B548: ...and has not regressed to the no-op remedy"
fi

# ── 🔴 THE SSO-LOCKOUT SAFETY PROPERTY. It regressed TWICE and the suite did not notice. ─────────
# `make vks-login` performs a vSphere SSO BIND, and vCenter locks out PERMANENTLY after THREE
# failures. So it may be named ONLY where the cause is a FACT (the token's own `exp` says EXPIRED)
# and NEVER on a state this report cannot decide.
#
# ⚠️ WHY THIS IS A SEPARATE, BEHAVIOURAL CONTROL. The B548 delegation-follower above pulls the
# helper's WHOLE body, and that body names the command in one of its two branches -- so it is
# GREEN either way and is structurally incapable of seeing this. MEASURED: re-applying the exact
# regression (dropping `--no-command`) left the suite at 77 ok / 0 FAIL, byte-identical. Prose has
# now closed this property three times and been reverted twice; this is the first thing that fails.
_rh="$(sed -n '/^supervisor_renew_how() {/,/^}/p' "${_CREDS_REPO}/scripts/lib/os.sh")"
if [ -z "$_rh" ]; then
  bad "SSO gate: supervisor_renew_how not found in lib/os.sh — this control is measuring NOTHING"
else
  # It must be RUNNABLE, not merely present: source the lib and render both states.
  _sso_cmd="$(bash -c ". '${_CREDS_REPO}/scripts/lib/os.sh' 2>/dev/null; supervisor_renew_how" 2>/dev/null || true)"
  _sso_non="$(bash -c ". '${_CREDS_REPO}/scripts/lib/os.sh' 2>/dev/null; supervisor_renew_how --no-command" 2>/dev/null || true)"

  case "$_sso_cmd" in
    *"make vks-login"*) ok "SSO gate: the DECIDABLE remedy names the command" ;;
    *)                  bad "SSO gate: the decidable remedy no longer names the command — the fix is withheld from the reader who HAS it" ;;
  esac
  case "$_sso_non" in
    *"make vks-login"*) bad "SSO gate: the UNDECIDABLE remedy NAMES make vks-login. That spends one of THREE vCenter SSO attempts before PERMANENT lockout, for a cause this report cannot decide. Regressed twice already." ;;
    "")                 bad "SSO gate: the undecidable remedy rendered EMPTY — cannot tell 'no command' from 'no output'" ;;
    *)                  ok "SSO gate: the UNDECIDABLE remedy names NO SSO command" ;;
  esac
  # --ask-only was introduced with no coverage at all. Two plausible edits break it differently:
  # removing it from the helper's MODE GUARD makes it refused (rc=2), so both VALID arms render
  # an EMPTY remedy; removing it from the RENDERING branch makes them name the command and
  # contradict themselves. Both are asserted below. (An earlier version of this comment named
  # only the second outcome — the mode guard added in the same arc changed it, and the comment
  # did not.)
  _sso_ask="$(bash -c ". '${_CREDS_REPO}/scripts/lib/os.sh' 2>/dev/null; supervisor_renew_how --ask-only" 2>/dev/null || true)"
  case "$_sso_ask" in
    "")                 bad "SSO gate: --ask-only rendered EMPTY" ;;
    *"make vks-login"*) bad "SSO gate: --ask-only NAMES the SSO command — a definite non-expiry diagnosis must not prescribe a bind" ;;
    *"cannot tell you which fix"*) bad "SSO gate: --ask-only carries the UNDECIDABLE clause — that arm HAS a definite diagnosis, so this contradicts it" ;;
    *)                  ok "SSO gate: --ask-only names no command and makes no undecidable claim" ;;
  esac
  # ...and the helper must REFUSE an unknown mode rather than fall through to naming the command.
  if bash -c ". '${_CREDS_REPO}/scripts/lib/os.sh' 2>/dev/null; supervisor_renew_how --nocommand" >/dev/null 2>&1; then
    bad "SSO gate: an UNKNOWN mode was accepted — a one-character flag typo then prescribes an SSO bind"
  else
    ok "SSO gate: an unknown mode is REFUSED (a flag typo cannot silently name the command)"
  fi
  case "$_sso_non" in
    *"locks out PERMANENTLY"*) ok "SSO gate: the undecidable remedy still states WHY there is no command" ;;
    *)                         bad "SSO gate: the undecidable remedy dropped 'locks out PERMANENTLY' — the clause that is the whole reason the command is withheld" ;;
  esac


# ── THE SSO-COMMAND PROPERTY, MEASURED ON THE RENDERED REPORT ─────────────────────────────────
# ⚠️ SCOPE, stated so this green is not over-read: it measures the TWO `kube_token_expiry`
# consumers. Scripts that prescribe the bind from a bare `classify_kube_failure` verdict WITHOUT
# reading an expiry are NOT covered — `26-vks-cluster-status.sh:129` and `lib/istio.sh:406`
# both do, and both are pre-existing. Widening to them is a separate design, not a hole here.

# The grid covers exactly the verdicts kube_token_expiry can RETURN. If a fourth is ever added the
# grid is silently short a cell, so pin the count -- three literal `printf '<VERDICT>` shapes.
# ⚠️ DELETE COMMENT LINES; DO NOT TRUNCATE AT THE FIRST `#`. Both directions are MEASURED:
#   no strip     -> a full-line comment quoting `printf 'REVOKED %s'` reports FOUR shapes: a false
#                   RED whose only remedy is deleting a comment (the refuted-on-sight shape).
#   `s/#.*//`    -> a `#` INSIDE A STRING LITERAL truncates a real verdict line, so a genuine 4th
#                   verdict (`_m="#tag"; printf 'REVOKED %s' "$_m"`) reports THREE and the gate
#                   positively asserts "exactly the 3 verdicts" -- a false GREEN in its own
#                   headline. That is the complementary hole the first fix opened.
#   `/^ *#/d`    -> correct on BOTH. Residual: a TRAILING comment quoting a printf still
#                   false-REDs, and its remedy (move the comment to its own line) deletes nothing.
_kte_shapes="$(sed -n '/^kube_token_expiry() {/,/^}/p' "${_CREDS_REPO}/scripts/lib/os.sh" \
                 | sed '/^[[:space:]]*#/d' | grep -oE "printf '[A-Z]+" | sort -u | wc -l)"
if [ "${_kte_shapes:-0}" -ne 3 ]; then
  bad "SSO gate: kube_token_expiry now returns ${_kte_shapes} verdict shapes, not 3. The grid below
      covers EXPIRED/VALID/UNKNOWN only, so a new verdict is UNMEASURED -- add its cell."
else
  ok "SSO gate: kube_token_expiry returns exactly the 3 verdicts the grid covers"
fi

# ⚠️ THE CONSUMER SET IS DERIVED, and this assertion is why. Deleting the arm scanner deleted its
# derivation with it, and the grid's row table is HAND-TYPED -- so a THIRD consumer would simply not
# be rendered and the suite would stay green. MEASURED by the round that caught this: a consumer
# added to 28-harbor-admin-password.sh naming the command on VALID *and* UNKNOWN left the suite at
# rc=0, 0 FAIL. This asserts SET EQUALITY only; it parses no arms and reads no `case` structure.
# ⚠️ SCAN lib/ TOO, AND MATCH CODE NOT COMMENTS. Two measured defects in the first version:
#   - it globbed `scripts/*.sh` only, so a third consumer reaching the verdict through a lib WRAPPER
#     (`token_verdict() { kube_token_expiry "$@"; }`) contained no literal, the set was unchanged,
#     and a dangerous prescription shipped at rc=0. Including lib/ does not catch that consumer
#     directly -- it fails the moment the WRAPPER is introduced, which is when a human can act.
#     (Its `-r` was also a no-op on a file glob, and `grep -v '/lib/'` matched nothing at all.)
#   - it grepped raw text, so a COMMENT merely mentioning the function registered its file as a
#     consumer -- measured: one added to 49-psa-check.sh turned this RED, prescribing a grid row for
#     a file that renders nothing. In a repo this comment-dense, a live false RED.
_sso_consumers=""
for _f in "${_CREDS_REPO}"/scripts/*.sh "${_CREDS_REPO}"/scripts/lib/*.sh; do
  case "$_f" in */test-*) continue ;; esac
  # ⚠️ HERESTRING, NOT A PIPE. `sed … | grep -q` under pipefail reports a FOUND pattern as ABSENT
  #    when grep exits early and sed takes SIGPIPE — and it is SIZE-DEPENDENT, so it bit exactly the
  #    big files: creds.sh (157 KB) vanished from the set while argocd-password.sh survived. In a
  #    derivation that direction is a false CLEAN: the consumer simply stops being counted.
  if grep -q 'kube_token_expiry' <<< "$(sed '/^[[:space:]]*#/d' "$_f" 2>/dev/null)"; then
    _sso_consumers="${_sso_consumers}$(basename "$_f") "
  fi
done
# os.sh is the DEFINER and stays in the expectation deliberately: excluding it would need a third
# filter, and this list just lost two for being silently dead.
if [ "$_sso_consumers" != "argocd-password.sh creds.sh os.sh " ]; then
  bad "SSO gate: the kube_token_expiry consumer set changed to [${_sso_consumers}]. The grid's rows
      are hand-typed, so a consumer it does not render is UNMEASURED -- add a row for the new file
      (or remove one), then update this expectation."
else
  ok "SSO gate: the kube_token_expiry consumer set is unchanged (${_sso_consumers}-- 2 rendered + the definer)"
fi

# base64 fallback matches the repo's existing pattern (vcenter.sh:375, 60-configure-tekton.sh:92):
# a toybox-like base64 without -w0 must not silently yield an empty token, which would collapse
# every cell to UNKNOWN and report a VACUOUS failure naming the wrong suspect.
_b64u() { printf '%s' "$1" | { base64 -w0 2>/dev/null || base64 | tr -d '\n'; } | tr -d '=' | tr '+/' '-_'; }
_jwt()  { printf 'h.%s.s' "$(_b64u "{\"exp\":$1}")"; }

# One rendering environment, three ROWS. The Supervisor kubeconfig must be NON-EMPTY or
# `kube_token_expiry` short-circuits to UNKNOWN on `[ -s ]` and all three cells collapse into one
# arm -- a grid that agrees with itself for the wrong reason.
#
# ⚠️ THE SINK ROW IS NOT DECORATION. `creds.sh` has TWO kube_token_expiry dispatch sites -- `:1105`
# (`_rejected_why`) and `:496` (the ArgoCD cell) -- and `:496` is gated on `_have_sink=1`. Without a
# sink it never renders, so the dangerous prescription could be placed there and the grid would
# report rc=0. MEASURED.
# ⚠️ CORRECTION 2026-09-08 — this comment used to say "an EMPTY sink file is NOT enough:
# VKS_STATE_KIND=1 is what reaches it". That is FALSE. `creds.sh:322` is
# `_have_sink=0; [ -f "$_sink" ] && _have_sink=1` — mere EXISTENCE. Measured: no file -> 0
# site-2 arms; EMPTY file -> 1; stamped -> 1. The wrong claim came from a probe whose own guard
# skipped CREATING the file when the content was empty, so its "empty sink" row was really "no
# file" — my instrument, not the code. The stamp is kept because it also exercises the
# DISCOVERED/KinD flow; the UNSTAMPED overlay reaches site 2 too and is not separately rendered
# (measured equal today).
_sso_render() {  # _sso_render <creds|argocd-password> <token> <sink-content-or-empty> -> the report
  local which="$1" tok="$2" sink="$3" t; t="$(mktemp -d)"; mkdir -p "$t/bin"
  cp .env.example "$t/.env.example"
  printf "HARBOR_URL=10.0.0.1\nHARBOR_USERNAME='robot\$probe'\nHARBOR_PASSWORD=x\n" > "$t/.env"
  : > "$t/kc"; printf 'apiVersion: v1\nkind: Config\n' > "$t/sup"
  [ -n "$sink" ] && printf '%s\n' "$sink" > "$t/.env.state"
  { printf '#!/bin/sh\ncase "$*" in\n'
    # ⚠️ MATCH THE TOKEN JSONPATH, NOT `config view`. FIVE other sites read that subcommand for
    # `.clusters[0].cluster.server` (lib/argocd.sh:42, lib/state.sh:52, lib/os.sh:957) -- a bare
    # `*"config view"*` arm hands every one of them a JWT where it expected a URL.
    printf '  *user.token*) printf %%s %s; exit 0 ;;\n' "'$tok'"
    printf '  *current-context*) echo stub-ctx; exit 0 ;;\n'
    printf '  *version*) exit 0 ;;\n'
    # Both consumers reach their token-expiry `case` only via an UNAUTHORIZED classification.
    printf '  *"get ns"*|*"get secret"*) echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;\n'
    printf 'esac\nexit 0\n'; } > "$t/bin/kubectl"
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/curl"; cp "$t/bin/curl" "$t/bin/getent"
  chmod +x "$t/bin/kubectl" "$t/bin/curl" "$t/bin/getent"
  ( cd "$t" && PATH="$t/bin:$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      KUBECONFIG="$t/kc" VKS_SUPERVISOR_KUBECONFIG="$t/sup" CREDS_TOKEN=1 \
      VKS_LAB_STATE_DIR="$t/no-lab" \
      "${_CREDS_REPO}/scripts/${which}.sh" 2>&1 )
  rm -rf "$t"
}

# label | binary | sink | EXPIRED marker | VALID marker | UNKNOWN marker
# The markers are the POSITIVE CONTROL: two of every three cells expect a count of ZERO, which is the
# shape that passes by NOT LOOKING, so a cell that never reached its arm must not read as a pass.
# ⚠️ THE MARKERS MOVED 2026-09-09 and the reason matters. The EXPIRED cause and its recipe used to
# be restated on EVERY row that lost a value (measured: 264 chars, printed twice), so any of those
# strings proved the arm. The operator's word for the result was "a poem". The fault and its command
# are now a BANNER at the very top, printed only when something is wrong, and every affected cell
# reads exactly `<not read>` -- so no per-row string can serve as a marker any more.
#
# creds/* EXPIRED therefore pins the BANNER. The site-2 row cannot: the banner fires for site 1 too,
# and this row exists to reach the `:496` ArgoCD dispatch site. Its marker is the banner's
# ArgoCD FOLLOW-UP line, which is emitted only when `_argo_pw_expired=1` -- set by that site's
# EXPIRED arm and nowhere else. That flag IS the observable; the cell text no longer is.
_sso_rows='creds/site1|creds||Supervisor token EXPIRED|has NOT expired|Expiry is unreadable
creds/site2-sink|creds|VKS_STATE_KIND=1|then, for the ArgoCD row: make argocd-password|not read — the Supervisor token is still valid|run: make argocd-password
argocd-password|argocd-password||EXPIRED at|has NOT expired|no readable expiry'

# ⚠️ ASSERT THE PROPERTY, NOT AN EXACT COUNT. EXPIRED must name the command AT LEAST once (measured:
# the EXPIRED report names it TWICE on ONE line, so `grep -c` reported "1 time(s)" and was simply
# false); VALID and UNKNOWN must not name it AT ALL. An equality test also produced a THIRD, wrong
# branch: any `got != want` fell into an `else` that said the remedy was "withheld" while the report
# in fact named it MORE. `-ge 1` / `-eq 0` is the actual property and has no ambiguous case.
while IFS='|' read -r _sso_lbl _sso_bin _sso_sink _sso_mE _sso_mV _sso_mU; do
  [ -n "${_sso_lbl:-}" ] || continue
  for _sso_v in EXPIRED VALID UNKNOWN; do
    case "$_sso_v" in
      EXPIRED) _sso_tok="$(_jwt 1000000000)"; _sso_mark="$_sso_mE" ;;
      VALID)   _sso_tok="$(_jwt 9999999999)"; _sso_mark="$_sso_mV" ;;
      *)       _sso_tok="notajwt";            _sso_mark="$_sso_mU" ;;
    esac
    _sso_out="$(_sso_render "$_sso_bin" "$_sso_tok" "$_sso_sink" || true)"
    # THE CONTROL RUNS FIRST AND THE CELL STOPS ON IT. Running both in parallel let one cell emit a
    # VACUOUS failure and an `ok … 0 time(s)` for the same render -- an `ok` that is false by the
    # gate's own admission in the line above it.
    case "$_sso_out" in
      *"$_sso_mark"*) ;;
      *) bad "SSO gate: ${_sso_lbl}/${_sso_v} never reached its arm (no '${_sso_mark}') -- the cell
      is VACUOUS and its count says nothing. Suspect the kubectl stub, the Supervisor kubeconfig,
      the sink stamp, or base64 -- OR, since 2026-09-09, the code under test itself: these markers
      now pin the BANNER and the ArgoCD dispatch arm, so a reworded banner lands here too."
         continue ;;
    esac
    _sso_got="$(printf '%s' "$_sso_out" | grep -o 'make vks-login' | wc -l | tr -d ' ')"
    if [ "$_sso_v" = EXPIRED ]; then
      if [ "${_sso_got:-0}" -ge 1 ]; then
        ok "SSO gate: ${_sso_lbl} / EXPIRED names the SSO command (${_sso_got}x)"
      else
        bad "SSO gate: ${_sso_lbl}'s EXPIRED report no longer names make vks-login -- the remedy is
      withheld from the one reader whose cause IS a fact."
      fi
    elif [ "${_sso_got:-0}" -eq 0 ]; then
      ok "SSO gate: ${_sso_lbl} / ${_sso_v} names no SSO command"
    else
      bad "SSO gate: ${_sso_lbl}'s ${_sso_v} report NAMES make vks-login (${_sso_got}x). ${_sso_v} is
      not a cause this report can decide, and a vCenter bind for it spends one of THREE attempts
      before a PERMANENT lockout. Withhold the command on this arm."
    fi
  done
done <<SSOROWS
$_sso_rows
SSOROWS

# ── The cause is stated ONCE. This is the property the dedup bought, and nothing else pins it. ────
# The expiry instant used to be restated on every row that lost a value, alongside the renewal
# recipe. MEASURED on this fixture BEFORE the change: the instant appeared 2x (site1) and 3x
# (site2-sink); on the real lab the 264-char recipe line printed TWICE. It is now in the Context
# block and each row says only `see Context`.
# ⚠️ Counted with `grep -o | wc -l` (OCCURRENCES), never `grep -c` (LINES) -- :1571 records that
# `grep -c` reported "1" for a string appearing twice on ONE line and was simply false.
for _dup_sink in '' 'VKS_STATE_KIND=1'; do
  _dup_out="$(_sso_render creds "$(_jwt 1000000000)" "$_dup_sink" || true)"
  _dup_ts="$(printf '%s' "$_dup_out" | sed -n 's/.*token EXPIRED \([0-9][0-9-]*T[0-9:]*Z\).*/\1/p' | head -1)"
  _dup_lbl="site$([ -n "$_dup_sink" ] && printf 2-sink || printf 1)"
  if [ -z "$_dup_ts" ]; then
    bad "dedup: ${_dup_lbl} render names no expiry instant at all -- the cell is VACUOUS and the
      count below would be a pass by not looking. Suspect the stub or the Context block."
    continue
  fi
  _dup_n="$(printf '%s' "$_dup_out" | grep -oF "$_dup_ts" | wc -l | tr -d ' ')"
  if [ "${_dup_n:-0}" -eq 1 ]; then
    ok "dedup: ${_dup_lbl} states the expiry instant ONCE (${_dup_ts})"
  else
    bad "dedup: ${_dup_lbl} states the expiry instant ${_dup_n}x. The cause belongs in the Context
      block once; a row that lost a value says 'see Context'. Restating it per row is what made
      this report unreadable (264-char lines, printed twice on the lab)."
  fi
done


fi

# THE LITERAL TWO SCENARIO DOCUMENTS GATE ON.
# docs/scenario-1.md and docs/scenario-2.md each carry a walk block whose ONLY checkable Expect
# literal is `add once to /etc/hosts`. walk-doc.sh drops literals shorter than 6 chars, ones carrying
# angle brackets or an ellipsis, ones appearing in the block itself, and bare `make <cmd>` -- so that
# one string is the whole gate, and a block whose literals ALL miss is EXPECT_MISS -> the walk exits 1.
#
# So a reword of creds.sh:778 turns a HEALTHY lab RED, hours later, with the failure pointing at a
# document. This pin moves that failure into static-check, next to the edit. Measured before it
# existed: grep for the string across scripts/test-*.sh returned ZERO.
#
# It needs render_with_env, NOT render: the hint requires an ingress LB IP AND a live probe
# (creds.sh:188 is a 2s TCP connect). A fixture IP never answers, so under plain render() creds
# correctly prints the liveness warning INSTEAD of the hint and a naive pin REDs against correct
# code. render_with_env sets CREDS_NO_PROBE=1, which is what makes this assertable at all.
_ing_out="$(render_with_env 'HARBOR_URL=h.example
' 'INGRESS_LB_IP=10.0.0.9
INGRESS_CONTROLLER=istio
')"
if printf '%s' "$_ing_out" | grep -qF 'add once to /etc/hosts'; then
  ok "the /etc/hosts hint is verbatim -- the literal both scenario documents gate on"
else
  bad "creds no longer prints the exact string 'add once to /etc/hosts'. TWO walk blocks
      (scenario-1 and scenario-2) have that as their ONLY checkable Expect literal, so this reword
      turns every healthy matrix row RED with the failure pointing at a document."
fi

# THE CONTROL. Without it the pin passes on a string printed unconditionally -- which would gate
# nothing in the documents either, since the claim is precisely that its PRESENCE distinguishes a
# table of real URLs from a table of needs-ingress markers.
_no_ing_out="$(render_with_env 'HARBOR_URL=h.example
' '')"
if printf '%s' "$_no_ing_out" | grep -qF 'add once to /etc/hosts'; then
  bad "the /etc/hosts hint prints even with NO ingress LB IP. Then its presence distinguishes
      nothing, and the two documents that gate on it are asserting a constant."
else
  ok "...and it is ABSENT with no ingress, so its presence is a real discriminator"
fi

if [ "$fail" != 0 ]; then
  printf '\n  %s assertion(s) ran. The fail-fast block stops later STATES once one fails, so cases\n' "$_ran" >&2
  printf '  after the first failure did NOT run -- fix the failure above and re-run for full coverage.\n' >&2
fi
if [ "$fail" = 0 ]; then
  printf '\nSUCCESS — creds-show tells the truth in every state (nothing installed / no ingress /\n         fully installed / UNSTAMPED overlay = the real-lab state / stamped-and-matching /\n         NO overlay but a POPULATED .env / a REACHABLE cluster / the LAB ACCESS rows)\n'
else
  printf '\ncreds-show FAILED the truth check above.\n' >&2
fi
exit "$fail"
