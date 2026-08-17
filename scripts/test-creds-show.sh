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
export REPO_ROOT="$PWD"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

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
restore() { rm -f "$SINK" "${_kc_hostile:-}"; }
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
      "${_CREDS_REPO}/scripts/creds.sh" 2>/dev/null )
  rm -rf "$t"
}

# ---- STATE 1: nothing installed. Every value is a default; the output must SAY SO. -------------------
out="$(render "")"
# Key on the CANONICAL TOKEN, never on prose. The first version of this check grepped three English
# phrasings — so when I mutated two of them the gate stayed GREEN and reported the defect as caught. A
# gate that greps prose is testing the prose.
if printf '%s' "$out" | grep -q 'values-provenance: DEFAULT'; then
  ok "no overlay -> declares values-provenance: DEFAULT (placeholders, not credentials)"
else
  bad "no overlay -> the output does NOT declare values-provenance: DEFAULT. It prints
      harbor.vks.local / Harbor12345 as if they were real. That is the exact lie this gate exists for."
fi
if printf '%s' "$out" | grep -qiE 'NOTHING IS INSTALLED YET|are a default'; then
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
if printf '%s' "$out" | grep -qiE 'NOTHING IS INSTALLED YET|<not set>|<needs ingress>'; then
  bad "fully installed -> the output still carries a 'not set'/'needs'/'nothing installed' marker:
      $(printf '%s' "$out" | grep -oiE 'NOTHING IS INSTALLED YET|<not set>|<needs ingress>' | head -2 | tr '\n' ' ')"
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
if printf '%s' "$out" | grep -qi 'may be from a lab that no longer exists'; then
  ok "...and warns the HUMAN that the values may predate this cluster"
else
  bad "...but the human is not told. The token alone is not the deliverable."
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
if printf '%s' "$out" | grep -qiE 'NOTHING IS INSTALLED YET|are a default'; then
  ok "an EMPTY .env still gets the original placeholders wording (the fix is additive)"
else
  bad "an EMPTY .env lost the original wording" "the fix rewrote an arm it was supposed to leave alone"
fi
if printf '%s' "$out" | grep -q 'env-populated: 0'; then
  ok "an EMPTY .env reports env-populated: 0"
else
  bad "an EMPTY .env does not report env-populated: 0" "the discriminator cannot tell the two states apart"
fi

printf '\nSUCCESS — creds-show tells the truth in every state (nothing installed / no ingress /\n         fully installed / UNSTAMPED overlay = the real-lab state / stamped-and-matching /\n         NO overlay but a POPULATED .env = where a real operator sits)\n'
else
  printf '\ncreds-show FAILED the truth check above.\n' >&2
fi
exit "$fail"
