#!/usr/bin/env bash
# creds.sh — print the access summary (URLs + logins) for the CURRENT context, AND SAY WHICH CONTEXT
# THAT IS.
#
# One command for every flow: it resolves URLs from `.env` plus the state overlay the installers publish
# (`.env.state` — NOT `.env.kind`, which was renamed in #192), and the ArgoCD password via
# argocd-password.sh (which self-selects the right source).
#
# It leads with a CONTEXT block, because the table alone is a lie of omission: with nothing installed it
# prints the `.env.example` DEFAULTS (`harbor.vks.local` / `Gitea12345!`), which look exactly like real,
# live credentials. The reader must be told whether the values are DISCOVERED or DEFAULT before they read
# a single row.
#
# Printing these to the operator's own terminal is the intended function, not a leak (no value touches
# argv). On a real lab the passwords are the operator's own or the lab's; they are only "demo" credentials
# in the KinD stand-in.
#
# ⚠️ THE MASK BELOW DOES NOT CLOSE THE CLASS, AND SAYING SO IS THE POINT (B182 F1).
# The row that prescribed this guard claimed `creds-show` was "the single upstream point". Its idea
# round REFUTED that: `docs/scenario-1.md:376` runs `make argocd-password` inside a live bash block at
# **Step 5, eight steps before creds-show**, and `scripts/argocd-password.sh` printfs the password to
# stdout UNCONDITIONALLY. So this guard takes a walk row's leak from *3 credentials at step 13 + 1 at
# step 5* down to *1 at step 5* — the log still contains a live ArgoCD admin password, and the row
# now LOOKS remediated. That is B153's own recorded shape (a fix that covered 1 of 2 real credential
# lines) repeating one level up.
#
# AND THE OBVIOUS COMPLETION IS BLOCKED: creds.sh calls argocd-password.sh through a COMMAND
# SUBSTITUTION (see the `argo_pw=` assignment below), i.e. always a pipe, so porting `[ -t 1 ]` into
# that script would make this table's Password cell read `<hidden…>` on the operator's own terminal.
# The thing that actually closes the class is the VALUE-KEYED redactor B153 prefers — the pattern
# already exists in-tree at `50-seed-gitea-repos.sh:111` and `:149`. Do not describe this file's
# guard as "the leak is fixed".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── SHOW_SECRETS IS SNAPSHOTTED **BEFORE** load_env, AND THAT ORDER IS THE WHOLE FIX (B182 F5) ────
# `load_env` sources `.env.example` and `.env` with `set -a`, so a `SHOW_SECRETS=1` line an operator
# adds to their OWN `.env` — tired of typing it — would be EXPORTED over the caller's environment
# and permanently re-arm the leak, INCLUDING inside the walk, invisibly (absence of masking produces
# no output). `check-env-clobber.sh` cannot catch it: it scans `.env.example` only, and lib/os.sh:501
# records this exact gap verbatim. The naive `${SHOW_SECRETS:-0}` read AFTER load_env fails this.
# So: read it from the PRE-load_env environment and honour only that.
_show_secrets_snapshot="${SHOW_SECRETS:-0}"

# ── CREDS_NO_PROBE, SNAPSHOTTED FOR THE SAME REASON AS SHOW_SECRETS ─────────────────────────────
# Set it to 1 to forbid every cluster read below. `test-creds-show.sh` sets it so the OFFLINE suite
# — which runs inside `static-check` and `make ci` — can never dial a live lab: two of its fixtures
# carry REAL lab IPs, so an unguarded read would fire at real infrastructure from a unit test.
# Snapshotted BEFORE load_env because `set -a` would otherwise let a `.env` line re-arm the probe
# invisibly (lib/os.sh:501 records that exact clobber class).
_no_probe_snapshot="${CREDS_NO_PROBE:-0}"

# creds.sh had NO trap at all — the pre-existing `_argo_err` mktemp leaks on every error path.
# ⚠️ _ssh_verr ADDED 2026-09-05. It was MY OWN leak, and it is precisely the class this trap was
# introduced for (the pre-existing _argo_err mktemp leaked on every error path): any death between
# its mktemp and its rm left a temp file per run.
trap 'rm -f "${_argo_err:-}" "${_lab_err:-}" "${_ssh_verr:-}" "${_h_err:-}" "${_route_dead:-}" 2>/dev/null || true' EXIT

# B528/F3 — the route probe's COST BOUND. Every ingress row targets the SAME LB, so once one HTTP
# probe fails to complete, the remaining eight will too — and each costs a full timeout.
# MEASURED 2026-09-07 against a responder that accepts TCP then never replies (the shape a rolling
# or outlier-ejected Envoy presents): 9 rows serial at the 2s default = 18.1s, at 1s = 9.1s, and
# 1.0s once the first failure stops the rest. An 18-second credentials report is one nobody runs.
# It is a FILE and not a variable ON PURPOSE: `_reach_ingress` is called inside $( ), a SUBSHELL,
# so an assignment there is discarded — the function's own comment says so. A file crosses.
_route_dead="${TMPDIR:-/tmp}/.creds-route-dead.$$"

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# Silence the internal state-stamp warning for this report only: it names .env.state and its
# "stamp", which is maintainer vocabulary, and the Context block below already states the same
# fact in plain English. Every other caller of load_env still gets the warning.
load_env 2> >(grep -v "does not record which cluster it belongs to" >&2)

# NOW RE-ARM THE SNAPSHOT ONE-WAY: probe-OFF wins, probe-ON can never be granted by a file.
#
# The snapshot above is taken BEFORE load_env on purpose — a `.env` line must never be able to
# turn probing back ON, because two offline fixtures carry REAL lab IPs and a unit test would then
# dial real infrastructure. That guard is right and stays.
#
# But it was SYMMETRIC, and only one direction is a safety property. MEASURED 2026-09-07 with
# `CREDS_NO_PROBE=1` in `.env` — the placement `.env.example` itself documents — the report made
# FIVE live calls, including `kubectl -n headlamp create token --duration=24h`, which MINTS A
# CREDENTIAL. The operator's own documented lever did nothing, and (before this commit) the banner
# read the live variable and cheerfully announced "nothing was probed" over all five.
#
# So: OR the two. A `.env` may only ever make the report QUIETER, never louder.
[ "${CREDS_NO_PROBE:-0}" = 1 ] && _no_probe_snapshot=1
export CREDS_NO_PROBE="$_no_probe_snapshot"   # child scripts (argocd-password.sh, …) inherit the DECIDED value

# ── the reveal decision, made once ───────────────────────────────────────────────────────────────
# A terminal is the operator reading their own screen — the intended function, and unchanged.
# A NON-terminal is a redirect, a pipe, a CI capture, an agent transcript, or the walk harness, which
# runs every documented command with stdout redirected to a per-row log. That is how live Gitea,
# Harbor and ArgoCD passwords reached /tmp/walk/MATRIX-row*.log on previous runs.
#
# ⚠️ A PTY-BASED CAPTURE COUNTS AS A TERMINAL AND WILL REVEAL. `[ -t 1 ]` asks "is fd 1 a tty", not
# "is a human reading this" — so `script(1)`, `ssh -t`, `unbuffer`, and some CI runners allocate a pty
# and get the CLEARTEXT into their capture file. MEASURED:
#     script -qec './scripts/creds.sh' /dev/null | grep -c CANARY   ->  1      (a plain pipe -> 0)
# This is NOT a gap in today's walk (measured: walk-doc.sh runs each statement through a PIPE, and
# nested-vsphere-lab/scripts/walk-matrix.sh's ssh option array has no `-t`), but it IS the honest
# boundary of what the mask covers, and the reader must be told rather than left to infer "captured
# == masked". Do NOT try to distinguish a pty-with-a-human from a pty-with-a-recorder: that is
# undecidable, and any heuristic for it would break the intended function on a real terminal.
# ⚠️ DELIBERATELY `= "1"` AND NOT THE REPO'S `is_true` — do NOT "fix" this for consistency.
# `is_true` accepts 1|true|yes|y|on (case-insensitively). MEASURED 2026-08-18 across 9 values, the
# two predicates diverge on 5 — true / TRUE / yes / y / on — and EVERY divergence is in the
# fail-CLOSED direction: the shipped form MASKS where is_true would REVEAL. Widening a predicate
# that uncovers a password, for tidiness, is the wrong trade in the only direction that matters.
# An adversary flagged the inconsistency (correctly) and prescribed is_true; that prescription is
# declined on this measurement. The cost is an operator who types SHOW_SECRETS=true getting no
# output -- and the mask message names the accepted value verbatim, so it is self-correcting.
if [ -t 1 ] || [ "$_show_secrets_snapshot" = "1" ]; then _reveal=1; else _reveal=0; fi

# _mask <secret> — apply ONLY to values that are REAL secrets.
# ⚠️ MASK THE VALUES, NOT THE COLUMN (B182 F4). Four things that appear in the Password column are
# NOT secrets and MUST stay legible: the `<no login; …>` notes, the `_unset_pw` placeholders, the
# `<ARGOCD_AUTH_TOKEN from .env — not a password>` row, and the `<- INITIAL secret; superseded …`
# annotation. A column-level mask deletes the tenant/KinD/lab distinction that ~60 lines of comments
# in this file exist to preserve — so the mask is applied at the three assignment sites only, and
# the annotation is appended OUTSIDE it.
_mask() {
  if [ "$_reveal" = 1 ]; then printf '%s' "$1"
  else printf '<hidden: not a terminal; SHOW_SECRETS=1>'; fi
}

# ── _settle_note <indent> — the ONE place that names the remedies (B202 F3) ──────────────────────
# Three arms of this report describe a possibly-stale credential, and until 2026-08-20 they named
# DIFFERENT remedies or NONE: the STORED arm — the one a post-matrix box with a surviving overlay
# actually lands in, and the one with the strongest "may be from a lab that no longer exists"
# language — named no target at all. That is the operator's original complaint reproduced verbatim.
# One helper, called from every arm, so the copies cannot drift.
#
# The two commands do DIFFERENT JOBS and the distinction is the point: env-validate DIAGNOSES (it
# authenticates and reports the 401); harbor-admin-password FIXES (it reads the INSTALLED admin
# credential and writes a working one). Naming only the diagnosis leaves the reader knowing they are
# broken with no way forward.
# DELEGATES to harbor_settle_note (lib/os.sh) as of 2026-08-22: this same text was duplicated into the
# GATES (02-env.sh env_validate, lib/harbor.sh harbor_api + harbor_auth_report), so the single-source
# rationale above now points at ONE definition rather than at this copy. stderr->stdout because this
# is a REPORT and its other arms print to stdout. (B209)
_settle_note() { harbor_settle_note "${1:-        }" 2>&1; }


# --- resolve URLs ---------------------------------------------------------------------
# Harbor keeps its OWN LB (not behind the ingress); http when HARBOR_INSECURE=1 (KinD).
harbor_scheme="https"; [ "${HARBOR_INSECURE:-0}" = "1" ] && harbor_scheme="http"
harbor_url="${harbor_scheme}://${HARBOR_URL:-harbor.vks.local}"
# Harbor's cert is SELF-SIGNED too (minted with an IP SAN by 06-install-harbor.sh), so a browser warns —
# exactly as it does for ArgoCD, whose row has always said so. Saying it for one and not the other is the
# same lie-by-contrast that made the ArgoCD/Harbor rows inconsistent before: the reader concludes Harbor's
# cert is trusted and ArgoCD's is not. Found by reading the REAL post-install table, not a simulated one.
if [ "${HARBOR_INSECURE:-0}" != "1" ] && [ -n "${HARBOR_CA_FILE:-}" ]; then
  harbor_url="${harbor_url} (untrusted cert)"
fi
# GITEA / TEKTON / THE APPS ARE ONLY REACHABLE AT *.vks.local IF THE INGRESS EXISTS.
# The ingress is OPTIONAL in this repo (`make verify` proves the whole GitOps loop over a port-forward,
# precisely so it needs none). Printing `http://gitea.vks.local` on a cluster with no ingress is a LIE:
# nothing serves that host, and no /etc/hosts entry can make it. The script already knew this — it hides
# the /etc/hosts hint when INGRESS_LB_IP is unset — and printed the URLs anyway.
# Harbor and ArgoCD are NOT affected: they keep their own LoadBalancers.
# ⚠️ PRESENCE IS NOT LIVENESS, and this variable is the worst place for that confusion because it is
# published to the state overlay by an install and SURVIVES A REBUILD. MEASURED 2026-08-05 after a
# rebuild: .env.state carried INGRESS_LB_IP=192.168.101.135 from a lab that no longer existed — no
# ping, tcp/80 closed, no such LoadBalancer in the cluster — and this report printed an /etc/hosts
# line for it plus four http://*.vks.local URLs. The operator pastes a hosts entry pointing at
# nothing and then debugs their browser.
# So: a bounded TCP connect decides whether the ingress is real. One connect, 2s, no dependency on
# kubectl or a cluster round-trip. It can only DOWNGRADE the claim — an ingress that answers is
# reported exactly as before.
# ⚠️ A FALSE 'dead' IS THE RISK TO AVOID: this deliberately probes the ADVERTISED port and treats
# anything other than a refused/timed-out connect as alive. If it cannot decide, it keeps the value.
_ing="${INGRESS_LB_IP:-}"
_ing_live=1
if [ -n "$_ing" ]; then
  # ⚠️ GATED ON THE SNAPSHOT, and the literal 2 replaced by the documented variable.
  # MEASURED 2026-09-05 (adversary, HIGH): with CREDS_NO_PROBE=1 -- which this report ITSELF
  # advertises as "skip every probe and report configuration only" -- this call still ran. Two
  # points, CREDS_NO_PROBE=1 in both: no INGRESS_LB_IP -> 0.190s; a black-holed INGRESS_LB_IP ->
  # 2.188s. The delta IS this hardcoded `timeout 2`. So the product's own escape hatch did not
  # reach it, the OFFLINE test suite dialled the operator's network from inside `make ci`, and
  # the report printed "nothing probed" after having probed.
  # `$_no_probe_snapshot` (:52) rather than the live variable, for the same reason SHOW_SECRETS is
  # snapshotted: load_env's `set -a` can clobber it from the operator's .env.
  if [ "$_no_probe_snapshot" != "1" ]; then
    timeout "${CREDS_PROBE_TIMEOUT_SECONDS:-2}" bash -c "exec 3<>/dev/tcp/${_ing}/${INGRESS_PROBE_PORT:-80}" 2>/dev/null || _ing_live=0
  fi
fi
ingress_url() {  # ingress_url <host> -> the URL, or an honest marker when no ingress exists
  # ⚠️ DO NOT WITHHOLD THE URL WHEN THE PROBE FAILS. A first version printed
  # "<ingress NOT ANSWERING>" in the URL column, and test-creds-show refused it with the argument
  # that settles it: "Over-correcting into silence is its own defect: with an ingress, those URLs
  # are exactly what the operator wants." The URL is still the right answer; the liveness warning
  # belongs ABOVE the table, once, not smeared across every row where it destroys the column.
  if [ -n "$_ing" ]; then printf 'http://%s' "$1"; else printf '<needs ingress>'; fi
}
gitea_url="${GITEA_URL:-$(ingress_url "${GITEA_HOST:-gitea.vks.local}")}"
# ArgoCD is on its OWN LoadBalancer (like real VKS): KinD publishes ARGOCD_LB_IP to .env.state
# (scheme https unless ARGOCD_INSECURE=1); a real lab uses the lab's own ArgoCD URL.
argo_scheme="https"; [ "${ARGOCD_INSECURE:-0}" = "1" ] && argo_scheme="http"
_argo_tls_flag=0   # set when the URL is https AT A BARE IP; the footnote below keys on THIS, not on text
# ⚠️ ARGOCD_SERVER IS TESTED FIRST, AND THE ORDER IS THE FIX (B168). It used to be the other
# way round, so a DISCOVERED, file-sourced ARGOCD_LB_IP outranked an operator's EXPLICIT
# ARGOCD_SERVER — inverting this repo's own rule that config may supply a DEFAULT but may not
# overrule an explicit choice (lib/os.sh:436). ARGOCD_SERVER is in load_env's snapshot-protected
# list (os.sh:499) AND in check-env-clobber.sh's SELECTORS; ARGOCD_LB_IP is in NEITHER — so the
# unprotected value was beating the protected one. MEASURED: `ARGOCD_SERVER=argocd-server
# make creds-show` printed `https://192.168.101.131 (self-signed; --insecure)` — the bare IP plus
# the literal --insecure that #745 tells operators never to use, against a cert with NO IP SAN.
#
# A KIND-STAMP DISCRIMINATOR WAS CONSIDERED AND REFUTED, measured across 5 states: keying on
# VKS_STATE_KIND=1 repairs 1 of 3 defective states and REGRESSES one (a legacy .env.kind sink,
# which os.sh:560 sources with no stamp at all), because every KinD sink carrying ARGOCD_LB_IP
# also carries the stamp — the added conjuncts are true exactly when the bug fires. Inverting
# the precedence repairs 3 of 3 with no stamp, no discriminator and no new mechanism.
# ── TELL THE OPERATOR SOMETHING IS HAPPENING ───────────────────────────────────────────────────
# ⚠️ Six seconds of SILENCE reads as HUNG, and this notice MUST PRECEDE THE FIRST BLOCKING CALL.
# MEASURED: a first version sat just above the table and printed "checks done in 0s" while the
# command had already taken 6.33 s -- the wait is the CLUSTER lookups below, not the reachability
# probes. A progress line printed after the wait is decoration. This command exists to be run interactively when someone
# wants in, so it must say what it is doing and bound the wait out loud. To STDERR deliberately:
# stdout is the report, and test-creds-show captures it -- progress must not become data.
# The numbers are the real bounds, read from the same variables the probes use, so this line cannot
# drift from the behaviour it describes.
if [ "$_no_probe_snapshot" = 1 ]; then
  printf '  (reporting configuration only — nothing was probed)\n' >&2
fi
_probe_t0=$(date +%s 2>/dev/null || echo 0)

# _argo_tls_note — append a SHORT marker when the ArgoCD URL is https AT A BARE IP.
# WHY AN IP IS THE DISCRIMINATOR, measured 2026-09-05 against this lab's live ArgoCD:
#     subject/issuer  O = Argo CD   (self-signed)
#     SANs            DNS:localhost, argocd-server, argocd-server.<ns>, ...   -- NO IP SAN
#     curl https://<ip>/     -> rc=60, http=000      (cannot verify)
#     curl -sk https://<ip>/ -> http=200             (works with --insecure)
# So a BARE IP can never verify against that cert, whereas a NAME the cert carries can. We only
# mark what we know: the IP case is a fact, the name case is not ours to assert (an operator may
# have installed a properly-named cert).
# ⚠️ THE SENTENCE GOES IN A FOOTNOTE, NOT THE CELL. creds.sh already states the rule -- "A SENTENCE
# IN A URL COLUMN DESTROYS THE TABLE" -- and an adversary measured the table at 171 chars with ONE
# data row, so it already wraps at 80 AND 120. This marker is 22 chars.
# ⚠️ AND --insecure IS NOT A BLANKET REMEDY. docs/scenario-2.md:482 records that the WRITE path does
# not accept it, so this must never read as "just add --insecure and you are fine". The footnote
# says what the verifying path actually needs.
_argo_tls_note() {
  case "$1" in
    https://[0-9]*.[0-9]*.[0-9]*.[0-9]*|https://[0-9]*.[0-9]*.[0-9]*.[0-9]*[:/]*)
      printf ' (untrusted cert; see note)' ;;
    *) : ;;
  esac
}

if [ -n "${ARGOCD_SERVER:-}" ]; then
  # A REAL LAB. ARGOCD_LB_IP is published only by the KinD flow (07-install-argocd.sh), so on a lab
  # this used to print the literal '<your lab's ArgoCD URL>' — while the operator had ALREADY told us
  # the address in ARGOCD_SERVER (both scenario runbooks have them discover and set it, and every
  # argocd-CLI call uses it). We were asking them to look up a value we were holding.
  case "$ARGOCD_SERVER" in
    http://*|https://*) argocd_url="$ARGOCD_SERVER" ;;
    *)                  argocd_url="${argo_scheme}://${ARGOCD_SERVER}" ;;
  esac
  _argo_note="$(_argo_tls_note "$argocd_url")"
  if [ -n "$_argo_note" ]; then argocd_url="${argocd_url}${_argo_note}"; _argo_tls_flag=1; fi
elif [ -n "${ARGOCD_LB_IP:-}" ]; then
  # KinD publishes this (07-install-argocd.sh). It is a DEFAULT — it applies only when the
  # operator has not said otherwise.
  argocd_url="${argo_scheme}://${ARGOCD_LB_IP} (untrusted cert)"
else
  # DISCOVER IT before giving up. MEASURED 2026-08-05: this printed `<not set>` and a footnote telling
  # the operator to "set ARGOCD_SERVER in .env" — while `kubectl -n <ns> get svc argocd-server` returned
  # 192.168.101.131 in one call. Asking someone to look up a value we can read ourselves is the same
  # defect the ARGOCD_SERVER branch above was already written to fix, one level down.
  # ⚠️ BOUNDED and NON-FATAL: --request-timeout, `|| true` on every leg, and it must never turn a
  # read-only summary into a hang or a die on an unreachable cluster. Failure just leaves <not set>.
  _argo_ip=""
  if [ -n "${ARGOCD_KUBECONFIG:-}${KUBECONFIG:-}" ] && have kubectl; then
    _argo_ns="${ARGOCD_NAMESPACE:-}"
    [ -n "$_argo_ns" ] || _argo_ns="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" env KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}" kubectl --request-timeout=3s </dev/null \
        get svc -A -o jsonpath='{range .items[?(@.metadata.name=="argocd-server")]}{.metadata.namespace}{end}' 2>/dev/null || true)"
    if [ -n "$_argo_ns" ]; then
      # ⚠️ `timeout` AS WELL AS `--request-timeout`. MEASURED 2026-09-05: this exact call took
      # 9.17 s against an unreachable API server DESPITE --request-timeout=3s, because that flag
      # bounds the API REQUEST, not the DNS resolution and TCP connect that precede it. It was the
      # single largest cost in `make creds` (21.7 s total, of which the reachability probes are
      # 0.02 s). An access command must never inherit an unbounded wait from a dead cluster.
      # Guarded like every other probe: MEASURED 2026-09-07 this still fired
      # under CREDS_NO_PROBE while the banner said nothing had been probed.
      if [ "$_no_probe_snapshot" != 1 ]; then
        _argo_ip="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" env KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}" kubectl --request-timeout=3s </dev/null -n "$_argo_ns" \
        get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      fi
    fi
  fi
  if [ -n "$_argo_ip" ]; then
    # ONE parenthetical, not two. `(discovered) (--insecure; see note)` reads as a stutter and
    # cost 24 columns in a table already measured at 171 chars with one data row.
    _argo_note="$(_argo_tls_note "${argo_scheme}://${_argo_ip}")"
    if [ -n "$_argo_note" ]; then argocd_url="${argo_scheme}://${_argo_ip} (discovered; --insecure — see note)"; _argo_tls_flag=1
    else                          argocd_url="${argo_scheme}://${_argo_ip} (discovered)"; fi
  else
    # A SENTENCE IN A URL COLUMN DESTROYS THE TABLE. Keep the cell short; the instruction goes in a footnote.
    argocd_url="<not set>"
  fi
fi
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# ⚠️ lib/harbor.sh is sourced for harbor_reachable_state() — the THREE-STATE reachability probe
# (unresolved | silent | serving) that already existed and that this script structurally could not
# call, because it sourced only os.sh and apps.sh. os.sh:1938 records that exact class as measured:
# calling a harbor.sh function from a non-sourcing script is `command not found` under
# `set -euo pipefail`, ON THE FAILURE PATH ONLY, which a green run never reaches.
# VERIFIED side-effect-free to source (ran-it): rc=0, no output, no env change, +17 functions.
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
# shellcheck source=scripts/lib/headlamp.sh
. "${SCRIPT_DIR}/lib/headlamp.sh"
tekton_url="$(ingress_url "${TEKTON_DASHBOARD_HOST:-tekton.vks.local}")"  # Tekton Dashboard (read-only UI)

_sink="$(state_file)"
_have_sink=0; [ -f "$_sink" ] && _have_sink=1

# ⚠️ `_VKS_STATE_SOURCED=0` CONFLATES TWO STATES — "refused" and "there was nothing to source".
# `load_env` sets it from `state_check`, which is false in BOTH cases, so keying on it alone made the
# no-overlay case report REFUSED instead of DEFAULT. STATE 1 of test-creds-show caught that
# immediately ("the output does NOT declare values-provenance: DEFAULT ... the exact lie this gate
# exists for") -- a fix landing a new defect in the opposite direction. A refusal REQUIRES a sink to
# have existed. `if`, not `A && B && C=1`: that form returns non-zero when A is false.
# ⚠️ COMPUTED HERE, NOT AT THE FLOW BLOCK 130 LINES DOWN, because its FIRST USE is `_unset_pw`
# below -- and under `set -u` a later definition is an ABORT, not a default. MEASURED: the first
# version set it at the flow block and `creds.sh` died with `line 240: _sink_refused: unbound
# variable` on any box whose .env does NOT carry HARBOR_PASSWORD, i.e. exactly the fresh-box state
# the KinD e2e reproduces with SKIP_DOTENV=1. It passed a live run only because the author's .env
# happened to supply the password, so `_unset_pw` was never called -- a fixture accident.
_sink_refused=0
if [ "$_have_sink" = 1 ] && [ "${_VKS_STATE_SOURCED-1}" = "0" ]; then _sink_refused=1; fi


# --- resolve logins -------------------------------------------------------------------
#
# NOTE (a fix I wrote and then DELETED, so nobody re-writes it): I added a "still the .env.example
# default" marker for the passwords. It is DEAD CODE — HARBOR_PASSWORD and GITEA_ADMIN_PASSWORD are
# COMMENTED in .env.example (they are you-choose secrets), so there is no default to compare against and
# the marker can never fire. The values shown come either from the operator's OWN .env (legitimately
# theirs) or from the state overlay (discovered), and the Context block already distinguishes those.
# Shipping a check that cannot fire is worse than shipping nothing: it looks like a guarantee.
# AN UNSET PASSWORD IS NOT AUTOMATICALLY "YOU MUST SET IT".
# The placeholder used to read `<set HARBOR_PASSWORD in .env>` — which is WRONG for the KinD flow, where
# 05-kind-up.sh GENERATES these (gen_password) whenever they are unset and publishes them to the state
# overlay. Telling a KinD operator to go and set a password is inventing a chore for them, and it is the
# same defect as the old ArgoCD note. Only a REAL LAB must supply one (there, Harbor/ArgoCD are given to
# you, not created by us).

# `_renew_how` now lives in lib/os.sh as `supervisor_renew_how` — argocd-password.sh needs the
# SAME sentence and cannot source creds.sh, so a hand-duplicated copy drifted (a round measured the
# two DISAGREEING on the undecidable arm, and the "locks out PERMANENTLY" clause missing from one).
_renew_how() { supervisor_renew_how "$@"; }

# newline-joined -> space-joined, without `tr` (photon:5.0 has none). The consumer is the
# "none is <cluster>-ssh-password: <LIST>" message; an empty LIST there names no options at all.
# ⚠️ KEEPS THE TRAILING SPACE. The format it feeds is `...: %s— set VKS_CLUSTER_NAME...`, so the
# old `tr '\n' ' '` supplied a trailing space that ran the last name into the em-dash without one.
# A `sed 's/$/ /'` was tried to restore it and DOUBLED every internal separator — and made the
# blank-line skip below dead, because a blank line became " ", which is non-empty. Emit the
# trailing space here instead: one join, one separator, blank lines still skipped.
tr_free_join() { local _l _o=""; while IFS= read -r _l || [ -n "${_l:-}" ]; do [ -n "$_l" ] || continue; _o="${_o}${_l} "; done; printf '%s' "$_o"; }

_unset_pw() {  # _unset_pw <VAR> -> what an unset password actually means, per flow
  # ⚠️ "check the state overlay" IS THE FOURTH FALSE CLAIM, and the most dangerous of them: under a
  # REFUSAL the password WAS published -- for another cluster -- so this sent the operator to read a
  # foreign credential out of the very file the Context block four lines above has just said is not
  # in play. Reachable in B517's own scenario: on a KinD box 05-kind-up.sh GENERATES these into the
  # overlay (.env.example leaves them commented), so an operator who ran KinD and then pointed at a
  # lab lands here.
  # ⚠️ SHORT CELL, SENTENCE IN THE FOOTNOTE. These arms were 40-76 chars inside a column whose
  # width is a max over ALL rows, and an adversary measured the table at 171-173 chars -- wrapping
  # on BOTH 80- and 120-col terminals -- with the nothing-installed arm (the COMMONEST state) the
  # dominant driver. creds.sh already states the rule at the ArgoCD URL arm: "A SENTENCE IN A URL
  # COLUMN DESTROYS THE TABLE. Keep the cell short; the instruction goes in a footnote." It was
  # enforced for the URL column and violated here.
  # NOTHING IS LOST: the footnote re-derives WHICH arm fired from the same two globals
  # ($_sink_refused, $_have_sink). It cannot use a flag set in here -- `_unset_pw` is always
  # called inside `$( )`, a SUBSHELL, so an assignment could never escape.
  if [ "$_sink_refused" = 1 ]; then printf '<REFUSED overlay — see note>'
  elif [ "$_have_sink" = 1 ]; then printf '<not published — see note>'
  else printf '<generated at install — see note>'; fi
}
harbor_user="${HARBOR_USERNAME:-admin}"
# The `:-` form cannot be kept: it would feed the PLACEHOLDER through _mask and hide the one thing a
# reader needs when nothing is installed. Branch instead — mask a real value, print the explanation.
if [ -n "${HARBOR_PASSWORD:-}" ]; then harbor_pw="$(_mask "$HARBOR_PASSWORD")"
else harbor_pw="$(_unset_pw HARBOR_PASSWORD)"; fi
# NOT a `gitea_admin` fallback: it disagreed with .env.example's GITEA_ADMIN_USER=admin, so this
# printer could name an account the pipeline never used. It is also dead code — load_env sources
# .env.example unconditionally (SKIP_DOTENV skips only .env), so the value is always set. If it
# somehow is not, SAY SO rather than inventing a name. This is a printer; it must still exit 0.
gitea_user="${GITEA_ADMIN_USER:-<unset — see GITEA_ADMIN_USER in .env.example>}"
if [ -n "${GITEA_ADMIN_PASSWORD:-}" ]; then gitea_pw="$(_mask "$GITEA_ADMIN_PASSWORD")"
else gitea_pw="$(_unset_pw GITEA_ADMIN_PASSWORD)"; fi
# ArgoCD via the context-aware resolver; exit 3 => VKS-provided / not knowable locally.
# `--wait 0` is an ARGUMENT, not an env var: this is a PRINTER and must never block. argocd-password
# defaults to a 900s wait for the still-reconciling case, and an env-var opt-out would be defeated by
# the .env.example clobber class (load_env sources it with `set -a` AFTER the caller's environment).
# Measured cost of getting that wrong: creds.sh renders three times inside `make static-check` ->
# test-scripts -> test-creds-show, i.e. a 45-minute CI hang.
# ⚠️ `2>/dev/null` DISCARDED THE ONE THING THE READER NEEDS TO KNOW ABOUT THIS VALUE.
# argocd-password.sh emits, on stderr, "this is the INITIAL admin password — if you have run
# 'argocd account update-password' it no longer works." Swallowing it handed the operator a bare
# password with no sign it was the PRE-ROTATION one — on a runbook (scenario-1 §5) that TOLD them
# to rotate it. That is the confident-wrong-credential shape, and it is exactly why a live auth
# PROBE was once proposed here: the probe would have reported a true 401 about a value this repo
# already knew was superseded. Keep the stderr; render the provenance instead of a bare secret.
_argo_rc=0; _argo_err="$(mktemp)"
# `--raw` for the SAME reason as `--wait 0`: an ARGUMENT, which nothing in any .env can reach.
# argocd-password.sh now applies its own non-tty mask (B153: two of the 16 measured leaks are its
# BARE invocation at docs/scenario-1.md Step 5, which no downstream redactor could ever key on,
# because the value comes from a k8s Secret and never lands in .env or .walk-env). But we capture it
# in `$( )` -- always a pipe -- so without --raw we would receive the SENTINEL and render it into
# the cell below, and the operator would never see their password even on a real terminal. We take
# the plaintext and apply the identical decision ourselves, three lines down.
# ⚠️ BOUNDED. MEASURED 2026-09-05: this call cost ~10 s against an UNREACHABLE cluster, and the two
# guest-node-SSH kubectl calls below allowed 20 s EACH -- `make creds` took 21.7 s total, of which my
# reachability probes were 0.06 s. An ACCESS command that takes 22 s to tell you what you can reach
# has failed at its job. `--wait 0` bounds the script's own polling; it does not bound the kubectl
# underneath it, so the timeout must be here.
# ⚠️ UNDER CREDS_NO_PROBE THIS IS SKIPPED -- but ONLY when the value is not already configured.
# MEASURED 2026-09-05 by tracing the script: with CREDS_NO_PROBE=1 the report still spent the FULL
# ${CREDS_KUBE_TIMEOUT_SECONDS:-3}s here (a 3.00s gap at this line), i.e. it made a live cluster
# call while printing "nothing probed" -- slow AND untrue, the two complaints that opened this work.
# It is NOT gated unconditionally: argocd-password.sh has TWO exit-0 paths, one of which returns an
# operator-supplied ARGOCD_ADMIN_PASSWORD without touching a cluster. That value is CONFIGURATION,
# and "report configuration only" must still report it. So we skip only the arm that would dial.
if [ "$_no_probe_snapshot" = "1" ]; then
  # Under no-probe we do not shell out AT ALL. Configuration is still reported: if the operator
  # supplied ARGOCD_ADMIN_PASSWORD we use it directly.
  # ⚠️ WHY NOT CALL THE CHILD WITH THE VALUE SET -- MEASURED 2026-09-05, and it is a PRE-EXISTING
  # defect this exposed rather than caused: `SKIP_DOTENV=1 ARGOCD_ADMIN_PASSWORD=x
  # argocd-password.sh --wait 0 --raw` HANGS to rc=124, i.e. it does not short-circuit on the
  # configured value under SKIP_DOTENV. Without SKIP_DOTENV the same call is rc=0 and fast. So
  # delegating here would spend the full timeout to rediscover a value we are already holding.
  if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then argo_pw="$ARGOCD_ADMIN_PASSWORD"; _argo_rc=0
  else                                         argo_pw=""; _argo_rc=0; _argo_noprobe=1; fi
else
  argo_pw="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" "${SCRIPT_DIR}/argocd-password.sh" --wait 0 --raw 2>"$_argo_err")" || _argo_rc=$?
fi
# THREE states now, not one hedge. argocd-password.sh compares argocd-secret's admin.passwordMtime
# against argocd-initial-admin-secret's creationTimestamp — free, because it already talks to that
# namespace. UNKNOWN keeps the old honest hedge rather than guessing CURRENT.
_argo_initial=0; _argo_state=UNKNOWN; _argo_changed_at=""
if grep -q 'ArgoCD admin password: CURRENT' "$_argo_err" 2>/dev/null; then
  _argo_initial=1; _argo_state=CURRENT
elif grep -q 'ArgoCD admin password: STALE' "$_argo_err" 2>/dev/null; then
  _argo_initial=1; _argo_state=STALE
  _argo_changed_at="$(grep -oE 'CHANGED at [^,]+' "$_argo_err" 2>/dev/null | head -1 | sed 's/CHANGED at //' || true)"
elif grep -q 'INITIAL admin password' "$_argo_err" 2>/dev/null; then
  _argo_initial=1
fi
rm -f "$_argo_err"
if [ "${_argo_noprobe:-0}" = 1 ]; then
  argo_pw="<not read: CREDS_NO_PROBE=1 (reading it is a live cluster call)>"
elif [ "$_argo_rc" = 0 ]; then
  # A REAL secret was obtained — mask it. The `<- INITIAL secret; superseded …` annotation is
  # appended further down, OUTSIDE this, so the provenance survives masking. That annotation is the
  # reason a column-level mask was refused: it exists precisely so a bare value is not read as
  # "this is your password".
  #
  # ⚠️ EMPTY IS NOT A SECRET. `_mask` renders its sentinel unconditionally, so an rc=0-with-no-output
  # would advertise a hidden password that does not exist and send the reader to SHOW_SECRETS=1 for
  # an empty cell. NOT reachable today — both of argocd-password.sh's exit-0 paths are guarded
  # non-empty (`[ -n "$enc" ]` and `[ -n "$ARGOCD_ADMIN_PASSWORD" ]`) — so this is latent, and it
  # arms the moment a third exit-0 path is added. Say what happened instead of masking nothing.
  # (`if`, not `[ -n … ] && …`: the AND-list form returns 1 on the empty branch, which is the
  # tail-of-a-block trap rules/shell/coding-style.md forbids.)
  if [ -n "$argo_pw" ]; then
    argo_pw="$(_mask "$argo_pw")"
  else
    argo_pw="<empty — argocd-password.sh exited 0 but printed nothing>"
  fi
else
  # SAME CLASS AS THE TWO ABOVE, third row: "<VKS-provided — get it from your lab>" is only true on a real
  # lab. On a KinD box ArgoCD's password is GENERATED at install like the others, so telling the operator
  # to go and get it from a lab they do not have is a third invented chore. Answer per flow.
  argo_pw="$(_unset_pw ARGOCD_ADMIN_PASSWORD)"
  # NOT "get it from your lab" — that sentence sent an operator to fetch something that was TWELVE
  # SECONDS away (measured, walk row 1: this printed at 19:42:25Z, the ArgoCD operator created
  # argocd-initial-admin-secret at 19:42:37Z). This printer passes --wait 0 by design, so "absent
  # right now" and "absent for good" are indistinguishable HERE; name the target that can tell them
  # apart rather than inventing a chore.
  # ...but "it waits" is a DEAD END when the Supervisor token is expired: argocd-password reads the
  # secret from the SAME Supervisor, so it will fail the same way, and the operator learns that only
  # after the wait. `_kube_classify` is defined LATER in this file (line ~1091) and so cannot be
  # called here; `kube_token_expiry` comes from lib/os.sh, is offline, and answers the one question
  # that decides which of the two sentences is true.
  if [ "$_have_sink" = 1 ]; then
    _ap_exp="$(kube_token_expiry "$(supervisor_kubeconfig 2>/dev/null || true)" 2>/dev/null || printf 'UNKNOWN')"
    case "$_ap_exp" in
      EXPIRED*) argo_pw="<not read — Supervisor token EXPIRED ${_ap_exp#EXPIRED }; renew that credential first, then: make argocd-password>" ;;
      # A LIVE token that the Supervisor rejects is rotated/revoked, not expired — and waiting
      # cannot fix that, so do not send the reader into `argocd-password`'s wait.
      VALID*)   argo_pw="<not read — the Supervisor token is still valid (${_ap_exp#VALID }); if it is being REJECTED the credential was rotated — ask whoever owns the lab>" ;;
      *)        argo_pw="<not read — run: make argocd-password (it waits)>" ;;
    esac
  fi
fi

# THE ArgoCD USERNAME WAS HARDCODED TO `admin`, AND THAT IS FALSE FOR A TENANT.
# Found by READING the table as each persona, which no grep would have surfaced:
#   * KinD / Scenario 1 (you install ArgoCD)  -> you ARE admin. Fine.
#   * Scenario 2 (you are a TENANT)           -> you are NOT. The platform team grants you an AppProject
#                                                role, and this repo's own tenant path authenticates with
#                                                ARGOCD_AUTH_TOKEN. Handing them "admin" is a login they do
#                                                not have and cannot use — and it quietly teaches the wrong
#                                                mental model of who owns ArgoCD.
# So: report the credential THEY will actually use.
if [ -n "${ARGOCD_AUTH_TOKEN:-}" ]; then
  argo_user="(token)"
  argo_pw="<ARGOCD_AUTH_TOKEN from .env — not a password>"
else
  argo_user="${ARGOCD_USERNAME:-admin}"
fi

# --- CONTEXT: where do these values COME FROM? ----------------------------------------
#
# Without this block the table is a LIE OF OMISSION. With no cluster and no state overlay it prints
# `harbor.vks.local` / `Gitea12345!` under the header "local demo credentials" — but those are
# .env.example DEFAULTS, not anything that exists. The reader cannot tell whether they are looking at
# values DISCOVERED from a live cluster or at placeholders for a cluster nobody has built, nor which flow
# they are in. A table that looks authoritative and is not is worse than no table.
#
# So: say which state sink is in effect, whose it is, whether the cluster answers, and — the line that
# actually matters — whether the values below are DISCOVERED or DEFAULT.

# ⚠️ THE SINK MAY EXIST AND STILL NOT BE IN PLAY. `load_env` REFUSES an overlay stamped for another
# cluster (state.sh: "NOT sourcing it — its LB IPs, CA paths and passwords belong to the other
# cluster") and publishes `_VKS_STATE_SOURCED=0` when it does. Every question below used to be
# answered by GREPPING THE FILE, so a refused overlay was read as authoritative anyway:
#
#   MEASURED 2026-08-28, one command against a real lab guest cluster --
#     level=ERROR  state: .env.state was written for a DIFFERENT cluster. NOT sourcing it
#     ...six lines later...
#       values below : DISCOVERED — the overlay is stamped for the cluster you are talking to
#       flow         : KinD stand-in (the state overlay is stamped by the KinD flow)
#
#   The header contradicted the loader's own ERROR block, and `_ing` below was empty for the same
#   reason, so all eight hosts read `<needs ingress>` while the cluster served 8/8 HTTP 200. One
#   defect, three symptoms. (B517.)
#
# `state.sh:90` has keyed on this signal since B142 ("do not edit a sink this process never
# sourced"); this file referenced it ZERO times. `${_VKS_STATE_SOURCED-1}` defaults to 1 so a
# caller that never ran load_env is unchanged.

# Whose state is it? The KinD flow STAMPS the sink (VKS_STATE_KIND=1); a real lab's does not.
if [ "$_sink_refused" = 1 ]; then
  _flow="undetermined — a state overlay exists but was REFUSED (stamped for another cluster), so
                   nothing in it is in play here"
elif [ "$_have_sink" = 1 ] && grep -q '^VKS_STATE_KIND=1' "$_sink" 2>/dev/null; then
  _flow="KinD stand-in"
elif [ "$_have_sink" = 1 ]; then
  _flow="real lab"
elif [ "${VKS_AUTH_METHOD:-}" = "vcf" ]; then
  _flow="real VKS lab"
else
  _flow="undetermined (KinD: 'make e2e-kind' · lab: docs/scenario-1.md or scenario-2.md)"
fi
# ⚠️ THE FLOW LINE NAMES THE FLOW. IT MUST NOT CLAIM WHAT IS INSTALLED — it cannot know.
# It is computed from `_have_sink` + VKS_AUTH_METHOD only, and `_cluster` is measured LIVE about
# twenty lines below and was never consulted, so the claim was INVARIANT under reachability.
# MEASURED 2026-08-20 against a lab running Harbor + ArgoCD + Gitea + Tekton + two apps, 31
# namespaces visible: this printed `cluster: reachable — context 'nested-lab'` directly beneath
# `flow: real VKS lab (VKS_AUTH_METHOD=vcf), nothing installed yet`. Two adjacent, contradictory
# lines; the operator believed the wrong one and chased a 401 that had nothing to do with it.
#
# `_have_sink` answers "has an installer ON THIS BOX published anything" — a fact about THIS
# CHECKOUT, not about the world. `.env.state` is gitignored and per-clone, so the false claim is
# reachable by an ordinary end user with no harness in sight: a colleague installed and they cloned
# the repo; a second operator on a second box; or scenario-2's TENANT, who by definition never
# installs Harbor or ArgoCD. Do not re-add an installation claim here. If one is ever wanted it must
# come from a live probe, and note that "installed" spans TWO clusters with TWO kubeconfigs —
# Harbor/ArgoCD are Supervisor services while Gitea/Tekton are guest-cluster — so no single cheap
# probe answers it. Pinned by STATE 8 in scripts/test-creds-show.sh.

# Does the cluster actually answer? Bounded — never hang the summary on an unreachable API server.
_cluster="not reachable (or KUBECONFIG unset)"
# </dev/null ON EVERY kubectl HERE, and it is load-bearing. MEASURED 2026-08-16: with stdin an open
# pipe that never reaches EOF -- which is what this inherits when run from a test harness or a make
# recipe -- `kubectl version` blocks in unix_stream_data_wait INDEFINITELY. It hung `make ci` for 22
# and 27 minutes on two occasions. --request-timeout CANNOT bound it: the process never gets far
# enough to issue a request. Proven by varying ONLY stdin against the same kubeconfig:
#     stdin=/dev/null -> rc=1 in 0s | stdin=open pipe -> HUNG | open pipe + </dev/null -> rc=1 in 0s
# I twice mis-diagnosed this as a network/address problem and "fixed" it twice without fixing it;
# every standalone probe was fast because an interactive shell's stdin is a terminal.
  # `_no_probe_snapshot` FIRST: this is a live cluster call, and the banner claims none was made.
if [ "$_no_probe_snapshot" != 1 ] && [ -n "${KUBECONFIG:-}" ] && have kubectl; then
  # ⚠️ CAPTURE THE EXIT CODE. The default above claims "not reachable", which is a statement about
  # the WORLD — and it is false when our OWN budget expired: `timeout` exits 124 without the server
  # having said anything at all. MEASURED (B544): with the outer budget equal to `--request-timeout`
  # the process is killed before kubectl can print, so "not reachable" was being asserted on the
  # strength of us not waiting. Say what we know instead.
  timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s version -o json \
    >/dev/null 2>&1 </dev/null && _reach_rc=0 || _reach_rc=$?
  case "$_reach_rc" in
    0)       _cluster="reachable — context '$(kubectl config current-context </dev/null 2>/dev/null || echo '?')'" ;;
    124|137) _cluster="UNDETERMINED — my own ${CREDS_KUBE_TIMEOUT_SECONDS:-3}s budget expired before it answered (rc=${_reach_rc}); this is not a statement about the cluster" ;;
  esac
fi

# CANONICAL PROVENANCE TOKEN — the machine-checkable claim, independent of any wording around it.
# MACHINE-ONLY: the gate asks for it (CREDS_TOKEN=1); a human should not have to read a token to learn
# something the Context block below tells them in words. A test's needs do not get to clutter the product.
# ⚠️ THIS WAS A BINARY AND NEEDED A THIRD STATE. "An overlay exists" was reported as DISCOVERED —
# but an overlay SURVIVES A REBUILD, so its values may belong to a cluster that no longer exists.
# MEASURED 2026-08-05 after a lab rebuild, all three from ONE run of this report:
#   * the ArgoCD password printed as current was REJECTED by the live API (HTTP 401);
#   * INGRESS_LB_IP 192.168.101.135 had no ping, tcp/80 closed, and no such LoadBalancer;
#   * ArgoCD's address printed <not set> while `kubectl get svc argocd-server` returned .131.
# A report that DISPLAYS a stale credential is worse than one that fails: you copy it, get 401, and
# nothing says why. The repo already had the discriminator — state.sh stamps VKS_STATE_SERVER — it
# just was not used here.
#   STAMPED + matches the reachable cluster -> DISCOVERED (this cluster wrote it)
#   overlay present, UNSTAMPED or mismatched -> STORED    (may predate this cluster)
#   no overlay                               -> DEFAULT   (placeholders; nothing is installed)
# ⚠️ `|| true` IS REQUIRED. An UNSTAMPED overlay is the COMMON case and the one this tri-state
# exists for — grep then exits 1, the assignment returns 1, and `set -e` kills the report before it
# prints anything. Measured: `make creds` died with "Error 1" and no output at all.
# sed, not tr: on a tr-less box this would be EMPTY, and an empty stamp falls through to the
# "may be from a lab that no longer exists" banner over a correctly-stamped overlay — the exact
# false alarm the comment below says was fixed.
_stamp="$(grep -m1 '^VKS_STATE_SERVER=' "$_sink" 2>/dev/null | cut -d= -f2- | sed 's/"//g' || true)"
# ⚠️ Read the live server through THE SAME FUNCTION THAT WROTE THE STAMP (state.sh's
# state_kubeconfig_server), not a hand-rolled jsonpath. The stamp is minified and this read was NOT,
# so on any multi-cluster kubeconfig they compared DIFFERENT servers and could never be equal —
# MEASURED on a real lab: the writer resolves https://192.168.101.132:6443 (the current context)
# while the un-minified read returns https://192.168.101.128:443 (the Supervisor, merely first in
# the file). A real VKS kubeconfig ALWAYS holds both, so provenance could never reach DISCOVERED:
# every `make creds-show` printed the alarming "may be from a lab that no longer exists" banner over
# a correctly-stamped, current overlay. One definition, because the normalisation is the drift-prone
# part. (It parses the file and never dials, so it needs no --request-timeout.)
_live_srv="$(state_kubeconfig_server "${KUBECONFIG:-}" || true)"
# ⚠️ A REFUSED OVERLAY IS, FOR PROVENANCE PURPOSES, NO OVERLAY -- and it must NOT become a fourth
# enum value. B204 refuted that exact move eight days ago, on the ground that `_prov` and
# `env-populated` are ORTHOGONAL axes: a fourth value either duplicates the pair or wins whenever
# .env is populated and DESTROYS the DISCOVERED/STORED split. Measured on the first version of this
# fix, both losses arrived: with env-populated=0 it asserted "from YOUR .env ONLY" when there was NO
# .env (the values were .env.example PLACEHOLDERS, printed unmarked), and it was the only arm naming
# no remedy at all. So the refusal is reported on its OWN line and its own token -- B204's own
# prescribed shape -- and `_prov` keeps its three values, computed as if the sink were absent, which
# when it was refused is literally true. (B517.)
if   [ "$_sink_refused" = 1 ] || [ "$_have_sink" != 1 ];       then _prov=DEFAULT
elif grep -q '^VKS_STATE_KIND=1' "$_sink" 2>/dev/null;                 then _prov=DISCOVERED
elif [ -n "$_stamp" ] && [ "$_stamp" = "${_live_srv:-__none__}" ]; then _prov=DISCOVERED
else                                                                _prov=STORED
fi
# Does the operator's OWN .env carry uncommented assignments?
#
# ⚠️ THIS IS THE *SOURCE* QUESTION, AND IT IS THE ONLY ONE ANSWERABLE HERE. FRESHNESS IS NOT:
# `.env` carries no cluster stamp (only the overlay does, via VKS_STATE_SERVER), so a password left
# over from a destroyed lab and one the operator typed thirty seconds ago render BYTE-IDENTICALLY.
# MEASURED — two states, same output, same `values-provenance: DEFAULT`, same footnote. So this
# report must never label a value STALE: on the repo's own documented real-lab flow (the runbooks
# tell the operator to set HARBOR_PASSWORD by hand BEFORE install, 02-env.sh:177) that label would
# be false, and it would send them to rotate a working credential.
#
# It also must not do the obvious "compare it to the committed example value" — that is DEAD CODE
# for exactly the values it would be about: HARBOR_PASSWORD, HARBOR_USERNAME and
# GITEA_ADMIN_PASSWORD are all COMMENTED in .env.example (measured: uncommented=0 for each), so
# there is nothing to compare against and every password would fall to the "stale" arm.
_env_populated=0
if [ "${SKIP_DOTENV:-0}" != "1" ] && [ -f "${REPO_ROOT}/.env" ] \
   && grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' "${REPO_ROOT}/.env" 2>/dev/null; then
  _env_populated=1
fi
[ "${CREDS_TOKEN:-0}" = "1" ] && printf 'values-provenance: %s\n' "$_prov"
[ "${CREDS_TOKEN:-0}" = "1" ] && printf 'env-populated: %s\n' "$_env_populated"
# The THIRD orthogonal axis, on its own line for the same reason `env-populated` is: an overlay can
# be absent, in play, or present-and-REFUSED, and that is not the same question as where the values
# came from. A machine keys on this; the prose below is for the human.
if   [ "$_sink_refused" = 1 ]; then _overlay_state=REFUSED
elif [ "$_have_sink"    = 1 ]; then _overlay_state=SOURCED
else                               _overlay_state=NONE
fi
[ "${CREDS_TOKEN:-0}" = "1" ] && printf 'state-overlay: %s\n' "$_overlay_state"
printf '\n  Context\n'
case "$_prov" in
  DISCOVERED) printf '    values below : read from the cluster you are talking to now\n' ;;
  # ⚠️ REWORDED 2026-09-07. It used to read "saved by an earlier run, and not tied to this cluster
  # — some may be from a lab that no longer exists." Every word of that is defensible and the whole
  # sentence was still wrong to print, because it fires on EVERY real lab, ALWAYS: `state_stamp` has
  # exactly two callers (05-kind-up.sh and a manual `make state-stamp`) and NOTHING on the real-lab
  # path calls it — recorded at test-creds-show.sh:211 (B87). A warning that cannot vary carries no
  # information while reading as one, and an operator staring at a fully-serving lab reasonably asks
  # what the hell it means.
  #
  # MEASURED: this arm is reached ONLY when the sink is UNSTAMPED. A stamped-and-contradicted sink is
  # refused by state_check, which sets _sink_refused=1 -> _prov=DEFAULT (the branch above) and gets
  # its own REFUSED block. So STORED does not mean "possibly stale"; it means "carries no stamp",
  # which on a real lab is simply the normal state.
  #
  # A round refuted the obvious fix (make the real-lab path call `state_stamp`): a guest-side stamp
  # ARMS state_check's mismatch-refusal against the Supervisor-side commands both scenario docs tell
  # you to run, and the report then loses all six live overlay keys and downgrades to "nothing is
  # installed yet" — strictly worse. BACKLOG.md:1811 (B86) refuted it once already, with an A/B.
  # So: no writes. Say what is true, and point at the column that carries the per-row answer.
  #
  # ⚠️ THE ARM IS SPLIT, because "STORED means unstamped" is FALSE. I asserted it, and an
  # implementation round REFUTED it by running the thing: line 610's `elif [ -n "$_stamp" ] && [
  # "$_stamp" = "$_live_srv" ]` sends a MATCHING stamp to DISCOVERED, and everything else — including
  # a stamp for a DIFFERENT cluster — falls to this `else`. It reaches here rather than being refused
  # because `state_check` returns 0 early when `_VKS_EXPLICIT_KUBECONFIG` is empty; lib/os.sh:666-669
  # records that measurement in the repo's own words ("three keys were stripped from a sink stamped
  # for ANOTHER cluster and state_check never refused").
  #
  # MEASURED with a sink stamped `https://192.168.101.999:6443` and no explicit KUBECONFIG: the
  # single-arm reword printed "carries no cluster stamp" over a sink that carries one for a dead lab,
  # and printed that lab's Harbor and ArgoCD endpoints as the operator's. The sentence I deleted was
  # CORRECT AND ACTIONABLE in exactly that state — so removing it traded real noise for real silence.
  #
  # The original complaint stands: an alarm that cannot vary carries no information. The fix is to
  # make it VARY, not to delete it. Unstamped (the normal real-lab state) is neutral; stamped-and-
  # contradicted names BOTH servers, so it is a fact the reader can check rather than a mood.
  STORED)     if [ -z "$_stamp" ]; then
                printf '    values below : your .env, plus values discovered at install time. Nothing here records\n'
                printf '                   WHICH cluster they came from, which is NORMAL on a real lab and does NOT\n'
                printf '                   mean they are stale. The Reachable column BELOW is the live answer.\n'
                printf '                   To re-check credentials: make env-validate\n'
              else
                printf '    values below : ⚠️ the state overlay is stamped for a DIFFERENT cluster. Its endpoints and\n'
                printf '                   passwords below belong to that one, not to the cluster you are talking to.\n'
                printf '                   stamped for : %s\n' "$_stamp"
                printf '                   you are on  : %s\n' "${_live_srv:-<could not read a server from KUBECONFIG>}"
                printf '                   Inspect it with: make state-show   |   re-check: make env-validate\n'
              fi ;;
  *)          if [ "$_env_populated" = 1 ]; then
                printf '    values below : from YOUR .env — the values you supplied. This report cannot\n'
                printf '                   confirm they are still current. Check: make env-validate\n'
              else
                printf '    values below : PLACEHOLDERS from .env.example — nothing is installed yet\n'
              fi ;;
esac
if [ "$_sink_refused" = 1 ]; then
  printf '    state overlay: %s — REFUSED\n' "$_sink"
  printf '                   It is stamped for a DIFFERENT cluster, so none of its LB IPs, CA paths\n'
  printf '                   or passwords are in play here. Anything an installer published is\n'
  printf '                   therefore MISSING from this report, which is NOT the same as absent\n'
  printf '                   from the cluster. The ERROR block above names which cluster it belongs\n'
  printf '                   to; inspect it with: make state-show\n'
elif [ "$_have_sink" != 1 ]; then
  printf '    values below : nothing has been installed yet\n'
fi
printf '    flow         : %s\n' "$_flow"
# ⚠️ "cluster", NOT "guest cluster" — and the ambiguity is DELIBERATE until something can resolve it.
# On a real lab there are always TWO (the Supervisor, where Harbor and ArgoCD run as Services, and
# the guest/workload cluster). Relabelling this "guest cluster:" was tried on 2026-09-07 and REVERTED
# the same day: `_cluster` is computed from whatever $KUBECONFIG names, with ZERO guest/Supervisor
# discrimination, so the label is an assertion the code cannot support. MEASURED by an implementation
# round: with a Supervisor kubeconfig it rendered `guest cluster: reachable — context
# '192.168.101.128'`. That state is DOCUMENTED, not hypothetical — docs/scenario-1.md:322 exports
# KUBECONFIG=./secrets/supervisor.kubeconfig and never re-exports the guest before :357 invites
# `make creds-show` 35 lines later, in the same shell (scenario-2.md:148 is the same).
# An ambiguous label is worse than a precise one; a FALSE one is worse than both.
# To revisit: give it a real discriminator (does the server match VKS_STATE_SERVER? does the context
# resolve a Cluster CRD?) and label it only when the answer is known.
printf '    cluster      : %s\n' "$_cluster"

echo
echo "Access the UIs:"

# --- /etc/hosts helper (only when an ingress LB actually exists) -----------------------
if [ -n "${INGRESS_LB_IP:-}" ] && [ "$_ing_live" != 1 ]; then
  echo
  echo "  ⚠️  the recorded ingress ${INGRESS_LB_IP} is NOT ANSWERING on port ${INGRESS_PROBE_PORT:-80}."
  echo "      It is a STORED value and survives a rebuild, so it is probably a previous lab's."
  echo "      NOT printing an /etc/hosts line for it — a hosts entry pointing at nothing sends you"
  echo "      to debug your browser. Re-run the ingress install, or reach the services on their own"
  echo "      LoadBalancers (shown in the table)."
elif [ -n "${INGRESS_LB_IP:-}" ]; then
  echo
  echo "  add once to /etc/hosts so the *.vks.local hosts resolve to the ingress LB:"
  # The trailing space the per-app loop leaves is TRIMMED: this line is COPIED into /etc/hosts.
  _hosts_line="$(printf '%s' "$(ingress_infra_hosts)$(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)" | sed 's/[[:space:]]*$//')"
  echo "    ${INGRESS_LB_IP}  ${_hosts_line}"
fi

# --- table ----------------------------------------------------------------------------
# WIDTHS ARE COMPUTED FROM THE DATA, never hardcoded. The old `%-9s %-32s %-14s` broke on real input:
# `javawebapp` is 10 chars (so it pushed every following column out of line), and a long value in the URL
# cell shunted Username/Password off into the distance. A table whose alignment depends on nobody ever
# adding a longer app name is a table that will be misaligned — and the registry EXISTS so people add apps.

rows=""
# ── REACHABILITY: a FOURTH column, never a replacement for the provenance tokens ────────────────
# ⚠️ B204 refuted collapsing these axes, and the reason is sharper than tidiness: a TCP/HTTP probe
# proves THE HOST ANSWERS. It proves NOTHING about the credential beside it. RULE ZERO-A0 measures
# three Harbor "auth checks" that return 200 with NO credentials at all. So a row marked `serving`
# next to an unverified password is a claim about the PORT, not about the login — collapsing them
# into one "AVAILABLE" verdict rebuilds the confident-wrong-credential shape one layer up.
# Hence: `Reachable` sits BESIDE `Username`/`Password`, and says only what was actually proven.
#
# COST (ran-it 2026-09-05): a name that does NOT resolve is FREE (getent fails in 0.002 s; our
# harbor.env1.lab.test in 0.01 s). Only an IP that black-holes costs the full bound. So the state
# an operator hits after a rebuild -- nothing resolves -- is ~0.01 s, and the worst case is
# bounded by CREDS_PROBE_TIMEOUT_SECONDS per target.
# ⚠️ NEVER call `make harbor-reachable` here: its 900 s is a WAIT LOOP in the target
# (04-harbor-reachable.sh:45). The target's job is to wait; this printer's job is to report.
# CREDS_NO_PROBE=1 (already snapshotted at :52) skips every probe -- the CI lever.
_probe_tcp() {                    # <host> <port> -> 0 if something answers, non-zero otherwise
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  timeout "${CREDS_PROBE_TIMEOUT_SECONDS:-2}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}
# ingress-backed rows (Gitea, Tekton, and EVERY app) resolve from the SINGLE _ing_live probe that
# this script already took -- zero extra cost, and the expensive case cannot occur (F12).
#
# ⚠️ IT MUST ALSO ASK WHETHER THE NAME RESOLVES *HERE*, and that is not a nicety.
# MEASURED 2026-09-05: this reported `serving` for headlamp.vks.local while a browser on the same
# box got DNS_PROBE_FINISHED_NXDOMAIN. Both facts were true — the LB really does serve it (curl with
# an explicit `Host:` header returns 200) — but the probe reached the LB *by IP* and so measured a
# path NO HUMAN TAKES. The one thing standing between the operator and the UI was the very thing
# the probe skipped. A report that says `serving` about a URL you cannot open is worse than one
# that says nothing: it sends you to debug the app instead of your resolver.
# So the verdict is now two facts, not one:
#   serving       — the LB answers AND this machine can resolve the name (you can click it)
#   no DNS here   — the LB answers, the NAME does not resolve on this box (add the /etc/hosts line
#                   printed above, or create the A records; the service itself is fine)
#   stale DNS     — the LB answers and the NAME resolves, but to a DIFFERENT address than this
#                   ingress: almost always a /etc/hosts line left by a PREVIOUS lab. The service is
#                   fine and the link is dead, which is the case a plain "does it resolve" check
#                   cannot see. ⚠️ Its remedy is NOT the append the `no DNS here` note gives —
#                   but NOT for the reason this comment used to give ("/etc/hosts honours the
#                   FIRST match"), which is false. MEASURED 2026-09-07, ubuntu:24.04, glibc, two
#                   /etc/hosts lines for one name on ordinary LAN addresses: with `multi on` in
#                   /etc/host.conf `getent` returns BOTH, and the client tries them in order, so
#                   an appended line helps ONLY IF THE STALE ADDRESS IS DEAD (served the new
#                   backend) and does nothing if the previous lab is still up (served the stale
#                   one). Replacing works in both cases, which is why we say replace.
#                   ⚠️ Do not re-derive this on loopback: RFC 6724 sorts 127/8 specially and an
#                   early arm there wrongly showed "append always works".
#   silent        — the LB itself does not answer
# `getent` on a non-resolving name is FREE (measured 0.002 s) and is already bounded by timeout
# above, so this costs nothing on the happy path.
_reach_ingress() {
  [ "${_no_probe_snapshot:-${CREDS_NO_PROBE:-0}}" = 1 ] && { printf 'not probed'; return; }
  [ -n "${_ing:-}" ] || { printf 'no ingress';  return; }
  if [ "${_ing_live:-0}" != 1 ]; then printf 'silent'; return; fi
  # A previous row already proved the LB does not complete an HTTP request (see _route_dead above).
  # `LB up` is the SAME thing this function says when it has no host to name: the TCP probe passed
  # and we did not learn anything about this route. It is not a new meaning.
  [ -e "${_route_dead:-/nonexistent}" ] && { printf 'LB up'; return; }
  local _h="${1:-}"
  # ⚠️ RESOLVING IS NOT ENOUGH — IT MUST RESOLVE TO *THIS* INGRESS.
  # MEASURED 2026-09-06 on the live lab: /etc/hosts still carried a PREVIOUS lab's ingress
  # (192.168.101.135) while the current one was .134. The name RESOLVED, so this arm passed; the
  # probe below then reached the LB BY IP with a Host header and got 200; and the table printed
  # `serving` for NINE rows that a browser could not open. Verified three ways -- curl on the URL as
  # printed: HTTP 000 x9; Chrome: error page; curl --resolve to .134: 200 x9 with each app serving
  # its own marker. So the LAB was healthy and the REPORT was wrong, which is the worse failure.
  #
  # This is the THIRD overclaim in this family (the two fixed 2026-09-05 are recorded above), and it
  # slipped past both because it sits in the gap between them: the DNS arm asked "does it resolve AT
  # ALL", the route arm asked "does the LB answer", and NEITHER asked "does the name this reader will
  # click resolve to the LB we just probed". `serving` is defined ten lines up as "you can click it".
  local _raw="" _res="" _grc=0
  if [ -n "$_h" ]; then
    # NOTE: do NOT set a global here to signal the footnote — this function runs inside $( ),
    # a SUBSHELL, so any assignment is discarded (rules/shell). The caller detects the condition
    # by scanning the rendered rows instead.
    #
    # ⚠️ "DOES IT RESOLVE" IS THE EXIT-STATUS QUESTION, exactly as before this change — do NOT
    # re-key it on whether output was captured. A first version did, and test-creds-reach-ingress
    # caught it immediately: that test stubs `getent` as `#!/bin/sh exit 0`, i.e. SUCCESS WITH NO
    # OUTPUT, so an output-keyed check reported `no DNS here` for every host and took 9 of 14 cases
    # red — including cases that had nothing to do with DNS. Real getent ties rc and output
    # together, so the two forms agree in production and disagree only under the stub; the stub is
    # right to isolate the arm, and the status is the honest question.
    _raw="$(timeout "${CREDS_PROBE_TIMEOUT_SECONDS:-2}" getent hosts "$_h" 2>/dev/null)" || _grc=$?
    [ "$_grc" -eq 0 ] || { printf 'no DNS here'; return; }
    _res="$(printf '%s\n' "$_raw" | awk 'NR==1{print $1}')"
    # Only claim STALE when we actually know the ingress address. If `$_ing` is a NAME rather than an
    # address, or is empty, comparing them would invent a fault -- say nothing and fall through to
    # the route probe, which is still a true statement about the LB.
    # Compare ONLY when we actually have an address AND the ingress is one. An empty `$_res`
    # (a resolver that succeeded but printed nothing) or a NAME-shaped `$_ing` cannot be compared,
    # and claiming `stale DNS` there would INVENT a fault — fall through and let the route probe
    # make the weaker, true statement instead.
    case "$_res" in '') : ;; *)
      case "$_ing" in
        *[!0-9.]*|'') : ;;
        *) [ "$_res" = "$_ing" ] || { printf 'stale DNS'; return; } ;;
      esac ;;
    esac
  fi
  # ── B528: ASK THE ROUTE, NOT JUST THE LB ────────────────────────────────────────────────────────
  # MEASURED 2026-09-05 on the live lab with every app pod in ImagePullBackOff:
  #     javawebapp.vks.local -> HTTP 503     and this column printed:  serving
  #     gitea.vks.local      -> HTTP 200                               serving
  # The `_ing_live` TCP probe above is shared by EVERY ingress-backed row and cannot see a backend,
  # but `serving` is a claim ABOUT THE BACKEND — the reader clicks a URL the report promised works
  # and gets an error page. Same class as the DNS overclaim fixed the same day.
  #
  # The status DISCRIMINATES three things a single verdict cannot, and each sends the reader
  # somewhere different — which is the whole reason not to collapse them:
  #   2xx/3xx -> serving      the route resolves to a healthy backend
  #   503     -> no backend   the route is RENDERED, nothing healthy behind it. This is the NORMAL
  #                           state after `make install-all`, which builds no app image (B529) —
  #                           so it means "run the pipeline", not "the ingress is broken".
  #   404     -> no route     the ingress does not know this host: a rendering/attach fault.
  #   000     -> silent       nothing answered at all (curl could not complete).
  #
  # ⚠️ HOST HEADER, NOT DNS. We reach the LB by IP and name the vhost, so this works on a box with
  # no /etc/hosts entry — and it must, because the DNS arm above already returned for that case.
  # ⚠️ `--max-time` is the SAME knob the rest of this file uses, so one env var still bounds the
  # whole report: CREDS_PROBE_TIMEOUT_SECONDS.
  # ⚠️ -o /dev/null: we want the STATUS, never the body — a 12 MB error page must not land in a
  # command substitution that becomes a table cell.
  # No host to name => we cannot ask the ROUTE, only the LB. Say what we actually know rather than
  # sending `Host: ` (which the ingress answers 404 for, i.e. we would invent a "no route" fault).
  [ -n "$_h" ] || { printf 'LB up'; return; }
  # ⚠️ F2 — THE PORT. `_ing` is `${INGRESS_LB_IP}`, a BARE IP (creds.sh:166), while the TCP gate at
  # :179 dials `${INGRESS_PROBE_PORT:-80}`. This curl used to hardcode port 80, so the two probes
  # disagreed: on an ingress listening anywhere else the gate said ALIVE and every one of the nine
  # rows then reported `silent` on a completely healthy lab — the `false dead` this file's own
  # comment calls THE RISK TO AVOID. `.env.example` documents the knob as "the port your ingress
  # actually listens on", so it exists for exactly this case.
  # The `*:*` arm keeps `test-creds-reach-ingress.sh` green: it sets `_ing=127.0.0.1:$PORT`, a shape
  # production never produces, which is why 14/14 passed over this defect for the arm's whole life.
  local _u="$_ing"
  case "$_ing" in *:*) : ;; *) _u="${_ing}:${INGRESS_PROBE_PORT:-80}" ;; esac
  local _code
  _code="$(curl -sS -o /dev/null -w '%{http_code}' \
             --max-time "${CREDS_ROUTE_TIMEOUT_SECONDS:-${CREDS_PROBE_TIMEOUT_SECONDS:-2}}" \
             -H "Host: ${_h}" "http://${_u}/" 2>/dev/null || true)"
  case "$_code" in
    # 000 is curl's "the request did not complete" (connect refused, timeout, TLS abort). It is
    # NUMERIC, so it would fall past every arm below into the catch-all and print `HTTP 000` — which
    # reads as a status a server returned. Nothing answered; that is `silent`, the same word the
    # LB-down arm above uses. Caught by test-creds-reach-ingress.sh, not by review.
    ''|000|*[!0-9]*) : > "${_route_dead:-/dev/null}" 2>/dev/null || true; printf 'silent' ;;
    2??|3??)     printf 'serving' ;;
    # 401/403 proves MORE than a 200 would about the thing this row is about: the route resolved
    # AND a live app answered AND it wants the credential printed beside it. Filing that under the
    # `HTTP %s` catch-all made the strongest possible confirmation read as an anomaly.
    401|403)     printf 'serving' ;;
    404)         printf 'no route' ;;
    5??)         printf 'no backend' ;;
    *)           printf 'HTTP %s' "$_code" ;;
  esac
}
_reach_harbor() {
  [ "${_no_probe_snapshot:-${CREDS_NO_PROBE:-0}}" = 1 ] && { printf 'not probed'; return; }
  [ -n "${HARBOR_URL:-}" ] || { printf 'not set'; return; }
  HARBOR_PROBE_TIMEOUT_SECONDS="${CREDS_PROBE_TIMEOUT_SECONDS:-2}" harbor_reachable_state 2>/dev/null || printf 'unknown'
}
_reach_argocd() {
  [ "${_no_probe_snapshot:-${CREDS_NO_PROBE:-0}}" = 1 ] && { printf 'not probed'; return; }
  # ⚠️ PROBE THE ADDRESS THE ROW ACTUALLY SHOWS, not just ARGOCD_SERVER. MEASURED 2026-09-05: with
  # ARGOCD_SERVER unset but the address DISCOVERED from the cluster, the row printed
  # "https://192.168.101.131 (discovered from the cluster)" while this column said "not set" --
  # the table contradicting itself in adjacent cells, which is worse than either answer alone.
  # $argocd_url is the rendered cell and may carry a trailing "(discovered ...)" note, so strip it.
  local _h="${ARGOCD_SERVER:-}"
  [ -n "$_h" ] || _h="${argocd_url%% *}"
  case "$_h" in ''|'<not set>') printf 'not set'; return ;; esac
  _h="${_h#https://}"; _h="${_h#http://}"; _h="${_h%%/*}"
  local _port="${_h##*:}"; case "$_h" in *:*) : ;; *) _port=443 ;; esac
  _h="${_h%%:*}"
  # BOUNDED for the same measured reason as lib/harbor.sh's pair: neither timeout variable
  # reaches getent, and a stale resolver turns this into a 20s hang with no output.
  timeout "${CREDS_PROBE_TIMEOUT_SECONDS:-2}" getent hosts "$_h" >/dev/null 2>&1 || case "$_h" in
    *[!0-9.]*) printf 'unresolved'; return ;;      # a NAME that does not resolve
  esac
  _probe_tcp "$_h" "$_port" && printf 'serving' || printf 'silent'
}
add_row() { rows="${rows}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\t'"${5:--}"$'\n'; }


# Ordered by the pipeline flow: Gitea (push) -> Tekton (build) -> Harbor (registry) -> ArgoCD (deploy) -> apps.
add_row "Gitea"  "$gitea_url"  "$gitea_user"  "$gitea_pw"  "$(_reach_ingress "${GITEA_HOST:-}")"
add_row "Tekton" "$tekton_url" "-"            "(no login; read-only dashboard)" "$(_reach_ingress "${TEKTON_DASHBOARD_HOST:-}")"

# ---- headlamp -------------------------------------------------------------------------------
# ⚠️ THE TOKEN IS MINTED HERE, AT REPORT TIME, AND STORED NOWHERE. `kubectl create token` issues a
# BOUND, EXPIRING token (1h by default), so writing one into .env or the state overlay would
# reproduce exactly the stale-credential complaint this whole report exists to fix: the operator
# copies it, gets 401, and nothing says why. A long-lived Secret-based token was REJECTED for the
# same reason plus a worse one -- it is a permanent credential at rest in etcd that survives every
# teardown. This mirrors what the ArgoCD row already does by shelling out per run.
# ⚠️ AND IT MUST NOT HANG OR DIE. This is a READ-ONLY summary that runs against labs that are half
# up; every failure degrades to a marker. Bounded by the same CREDS_KUBE_TIMEOUT_SECONDS as every
# other cluster call, `</dev/null` because kubectl blocks forever on an open pipe, and `|| true` so
# a failure cannot trip `set -e`.
headlamp_url="$(ingress_url "${HEADLAMP_HOST:-headlamp.vks.local}")"
headlamp_tok="<not read>"
if [ "$_no_probe_snapshot" = "1" ]; then
  headlamp_tok="<not read: CREDS_NO_PROBE=1 (minting a token is a live cluster call)>"
elif [ -n "${KUBECONFIG:-}" ] && have kubectl; then
  _hl_ns="${HEADLAMP_NAMESPACE:-headlamp}"; _hl_sa="${HEADLAMP_SA:-headlamp-viewer}"
  # ⚠️ --duration, OR THE TOKEN DIES IN AN HOUR. `kubectl create token` with no --duration gets the
  # API SERVER DEFAULT, which is 3600s — MEASURED on this lab by decoding the JWT's exp-iat. An
  # operator who opens Headlamp, works for an hour and refreshes gets "Cluster main is not healthy:
  # Unauthorized" and is bounced to the paste-a-token screen, with nothing on either screen saying
  # the token merely expired. MEASURED on the same lab: --duration=24h is HONOURED, not capped
  # (86400s), so the server's --service-account-max-token-expiration is at least 24h here.
  # A shorter cap elsewhere silently clamps this, which is fine: the request is a ceiling.
  _hl_t="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s \
             -n "$_hl_ns" create token "$_hl_sa" --duration="${HEADLAMP_TOKEN_DURATION:-24h}" \
             </dev/null 2>/dev/null || true)"
  # _mask, NOT _lab_secret: that wrapper is defined ~380 lines BELOW this line, so calling it
  # here dies `_lab_secret: command not found`. It only ever fired once headlamp was installed AND
  # a token minted — a path that did not exist until 2026-09-05, which is why it shipped green.
  if [ -n "$_hl_t" ]; then
    headlamp_tok="$(_mask "$_hl_t")"
    # ⚠️ PRINT WHEN IT DIES. The operator's complaint was never "the TTL is wrong" — it was "expired
    # AGAIN, wtf": Headlamp's own screen says only "Unauthorized" and offers a paste box, and this
    # report said nothing either, so an expiry was indistinguishable from a broken install. Decoding
    # the JWT's own `exp` reports what the API SERVER granted, not what we asked for — the request
    # is a ceiling and a cluster with a lower --service-account-max-token-expiration silently
    # clamps it. The exp is NOT a secret; only the token is, and that stays masked above.
    # ⚠️ ONE PARSER, shared with kube_token_expiry. This was a hand-rolled COPY and the two
    # diverged: it kept a greedy `.*` (LAST match wins, so a nested `exp` beat the real one), a
    # `[0-9]*` (zero-or-more), and no sanity ceiling — so a microsecond epoch rendered
    # "valid until 55679083-07-23T03:33Z" as a stated fact. A round found them disagreeing on the
    # same input. `jwt_exp_seconds` refuses on ambiguity rather than picking; empty => we simply
    # do not print an expiry, which is the pre-existing behaviour for an unparseable token.
    _hl_exp="$(jwt_exp_seconds "$_hl_t")"
    # ⚠️ WARN WHEN THE COOKIE WILL OUTLIVE THE TOKEN DURATION. `-session-ttl` is a DEPLOY-TIME
    # flag: it cannot track a token minted here. So `make creds HEADLAMP_TOKEN_DURATION=8h` against
    # a Deployment still at 24h hands the operator an 8h token in a 24h cookie, and for the other
    # 16h the browser re-presents a DEAD credential. MEASURED: a 600s token in an 86400s cookie.
    #
    # ⚠️ COMPARE THE TWO *CONFIGURED* NUMBERS, NEVER THE TOKEN'S REMAINING LIFE. Two adversary
    # rounds refuted the first version, which did `ttl > (exp - now)`. That decays: at 24h/24h --
    # the perfectly ALIGNED state this whole fix exists to produce -- `left` is 86399 one second
    # after the mint, so it warned. MEASURED on the lab, three consecutive runs: 1s elapsed ->
    # WOULD WARN, 0s -> silent, 0s -> silent. A coin flip on API round-trip latency, and this
    # repo's own memory records that a RESUMED estate's clock is uniformly behind, which makes it
    # deterministic there. Worse, its remedy ("re-run install-headlamp") cannot change elapsed
    # time, so the operator would loop -- the same shape as the bug being fixed. Configured vs
    # configured has no clock in it at all.
    #
    # ⚠️ `|| true` IS LOAD-BEARING (both rounds, CRITICAL). This file's own header says the report
    # "MUST NOT HANG OR DIE ... every failure degrades to a marker". Under `set -euo pipefail` an
    # unguarded cluster call here KILLS the whole table -- Gitea, Harbor, ArgoCD, VKS and SSH rows
    # all lost, at line ~820 of 1570. Reachable on routine paths: a tenant kubeconfig that may
    # `create token` but not `get deploy` (the DEFAULT posture), or headlamp installed by a
    # platform team under another release name, or the 3s timeout expiring on a slow lab.
    # headlamp_deployed_ttl() cannot fail by construction; the `|| true` is belt and braces.
    _hl_ttl="$(headlamp_deployed_ttl "$_hl_ns" || true)"
    _hl_want="$(headlamp_ttl_seconds "${HEADLAMP_TOKEN_DURATION:-24h}" || true)"
    # ⚠️ A DURATION WE CANNOT MODEL MUST BE LOUD, NOT SILENT. kubectl's parser is a strict
    # SUPERSET of ours: `--duration=1h30m` and `=1.5h` are ACCEPTED by kubectl (measured -- they
    # reach the connection attempt) while headlamp_ttl_seconds rejects them, so `_hl_want` is empty
    # and the comparison was SKIPPED WITHOUT A WORD. That is a 5400s token in an 86400s cookie: a
    # 23-hour dead-cookie window, with the row still printing "(valid until ...)" so it reads
    # healthy. .env.example promises the opposite in as many words -- "creds.sh warns when they
    # disagree" -- so silence here makes the documentation a lie.
    if [ -n "${_hl_ttl:-}" ] && [ -z "${_hl_want:-}" ]; then
      log_warn "headlamp: HEADLAMP_TOKEN_DURATION='${HEADLAMP_TOKEN_DURATION:-24h}' is a duration"
      log_warn "  kubectl accepts but this check cannot model, so the cookie-vs-token comparison was"
      log_warn "  SKIPPED. Use a SINGLE unit (<n>h, <n>m or <n>s) so both halves agree."
    elif [ -n "${_hl_ttl:-}" ] && [ -n "${_hl_want:-}" ] && [ "$_hl_ttl" -gt "$_hl_want" ]; then
      log_warn "headlamp: the session COOKIE lives ${_hl_ttl}s but this token lasts only ${_hl_want}s"
      log_warn "  (HEADLAMP_TOKEN_DURATION=${HEADLAMP_TOKEN_DURATION:-24h}). For the difference the"
      log_warn "  browser re-presents a DEAD token: 401 everywhere and a bounce to the paste screen,"
      log_warn "  with nothing saying why. Fix BOTH halves:"
      log_warn "    make install-headlamp HEADLAMP_TOKEN_DURATION=${HEADLAMP_TOKEN_DURATION:-24h}"
      log_warn "  then paste a FRESH token in the browser -- a Max-Age is fixed when the cookie is"
      log_warn "  created, so the one already in your browser keeps its old lifetime regardless."
    fi
    if [ -n "${_hl_exp:-}" ]; then
      headlamp_tok="${headlamp_tok} (valid until $(date -u -d "@${_hl_exp}" '+%Y-%m-%dT%H:%MZ' 2>/dev/null || printf 'epoch %s' "$_hl_exp"))"
    fi
  else                     headlamp_tok="<not read — is headlamp installed? make install-headlamp>"; fi
else
  headlamp_tok="<not read — no KUBECONFIG>"
fi
add_row "headlamp" "$headlamp_url" "(token)" "$headlamp_tok" "$(_reach_ingress "${HEADLAMP_HOST:-}")"
# ⚠️ KEYED ON A HEADLAMP FACT, NOT ON AN ARGOCD ONE. This note first shipped nested inside
# `if [ "${_argo_initial_note:-0}" = 1 ]`, which is set only when ArgoCD's INITIAL admin secret is
# still readable -- so the one sentence that breaks the "paste a stale token -> bounce -> paste
# again" loop was INVISIBLE on a hardened lab (someone ran `argocd account update-password`), on a
# tenant with no ArgoCD access, and on any cluster with headlamp but no ArgoCD at all. Both
# adversary rounds flagged it, and it sat two lines above this file's own warning about keying a
# note on the wrong flag. It is now gated on the token having actually been read.
case "$headlamp_tok" in
  '<not read'*) : ;;
  *) _headlamp_note=1 ;;
esac
# ── WHY THIS ROW IS NOT READ LIVE FROM THE CLUSTER (B202 F5/D) ──────────────────────────────────
# NOT because "a printer must not probe" — it demonstrably does: the guest-node SSH row below runs
# two live kubectl calls (PR #901). Stating that as the reason would be refuted by this very file.
#
# The real reason is a PRIVILEGE INVERSION. After scenario-1 Step 9, `.env` holds the LEAST-PRIVILEGE
# robot (22-harbor-robot.sh publishes `robot$<project>+<name>`) while the Supervisor secret holds
# ADMIN. "Prefer the cluster" would therefore promote admin over the account the pipeline actually
# runs as — and taking only the PASSWORD rebuilds the mixed pair whose 401 is already MEASURED at
# 22-harbor-robot.sh:200-206. There are four states where `.env` is authoritative and the cluster is
# stale: the Step 9 robot; a ROTATED admin password (goharbor applies HARBOR_ADMIN_PASSWORD only at
# first bootstrap); a re-install over a surviving DB; and values the cluster does not carry at all.
#
# ⚠️ IF ANYONE EVER DOES ADD A LIVE READ HERE: username and secret move as ONE ATOMIC PAIR from ONE
# source, never field-by-field. `make harbor-admin-password` already does this correctly
# (env_publish_all writes BOTH keys, and since B202 F4 it REFUSES to overwrite a robot$ pair).
# test-creds-show.sh asserts this mechanically — a comment alone is not the control.
add_row "Harbor (registry)" "$harbor_url" "$harbor_user" "$harbor_pw" "$(_reach_harbor)"
# ── _rejected_why — say WHEN the token died, not "usually an EXPIRED token" ──────────────────────
# kubectl reports an expired token and a revoked/rotated credential IDENTICALLY as `Unauthorized`,
# so the classifier cannot separate them and this used to hedge. The token's own `exp` claim can,
# offline and without spending one of the THREE vCenter SSO attempts before permanent lockout —
# which is exactly why the hedge was the right call until kube_token_expiry existed.
# Naming the renewal is safe ONLY on the EXPIRED branch, where the cause is a fact. Everywhere else
# it degrades to the hedge rather than guess.
_rejected_why() {
  local kc _e
  kc="$(supervisor_kubeconfig 2>/dev/null || true)"
  _e="$(kube_token_expiry "$kc" 2>/dev/null || printf 'UNKNOWN')"
  case "$_e" in
    EXPIRED*)
      printf 'the Supervisor token EXPIRED at %s. %s' "${_e#EXPIRED }" "$(_renew_how)" ;;
    VALID*)
      # The DEFINITIVE rotated/revoked signal, and the whole reason to read `exp` at all: the
      # Supervisor rejected a token that has NOT expired. Sending this to the hedge below would
      # assert "carries no readable expiry" about an expiry we just read — a false sentence — and
      # would discard the one discrimination kubectl cannot make.
      # Delegates like the others, so the wording cannot drift between the two consumers.
      # (An earlier version of this comment said a hand-written arm is "invisible to the structural
      # control" — that stopped being true when the control began matching the LITERAL command as
      # well as the call, so a hand-written prescription is now caught either way. Delegation is
      # about single-sourcing the sentence, not about evading a blind spot that no longer exists.)
      printf 'the token has NOT expired (valid until %s), so the Supervisor rejected a LIVE token — this is a ROTATED or REVOKED credential, not an expiry. Re-authenticating will NOT help. %s' "${_e#VALID }" "$(_renew_how --ask-only)" ;;
    *)
      printf 'the Supervisor REJECTED this kubeconfig, and its token carries no readable expiry (a client-cert kubeconfig has none, and an ambiguous one is refused rather than guessed), so this is NOT necessarily expiry — it may be a rotated or revoked credential. Do not re-authenticate blind: vCenter SSO locks out PERMANENTLY after 3 failures. %s' "$(_renew_how --no-command)" ;;
  esac
}

# ── _kube_classify <errfile> <prefix> — ONE mapping of a kube failure class to (token, sentence) ──
# BOTH call sites in the SSH probe go through this. The first version had two: a full case at the
# listing site and a THREE-ARM case at the read site, whose `*)` swallowed five real classes. The
# repo's own `check-classifier-consumers` gate caught it (Makefile:383) — it requires every consumer
# of classify_kube_failure to handle EVERY class, precisely because a `*)` that says "not one we
# classify" is FALSE for a class that exists and drops the remedy that class carries.
# One function = one place to be complete, and the gate has one consumer to check.
#
# HOISTED 2026-09-07 and renamed off `_ssh_`: the HARBOR admin-password cell needs the same
# mapping, and it renders ~450 lines EARLIER. Outputs are `_kube_tok`/`_kube_state` so the SSH
# block keeps `_ssh_tok`/`_ssh_state` as its own state (it sets them on arms this function never
# sees — <ambiguous>, <none>, <no key>, <empty>); each SSH call site copies across explicitly.
# A second hand-rolled taxonomy was REFUTED (round 2026-09-07): a 4-value enum drops five of the
# eight classes, and `check-classifier-consumers` exists precisely to stop that.
_kube_classify() {
  local _e="$1" _p="$2" _rc="${3:-}"
  # 🔴 OUR OWN BUDGET EXPIRING IS NOT A FACT ABOUT THE LAB — branch on it BEFORE the classifier.
  # `timeout` exits 124 on expiry (137 with -s KILL/-k). MEASURED: with the outer budget equal to
  # `--request-timeout`, kubectl is killed before it can print the summary line the UNREACHABLE arm
  # matches, so the errfile arrives EMPTY and the classifier correctly says UNKNOWN — a true answer
  # to the wrong question. NINE call sites in this file set outer == inner, so this was the normal
  # case, not an edge one.
  #
  # ⚠️ WHY IT IS THE EXIT CODE AND NOT A BIGGER BUDGET. A round measured that no budget is
  # derivable: against an unreachable endpoint kubectl emitted 6 stderr lines by 25s, but against a
  # blackhole (10.255.255.1:443) it emitted ZERO BYTES at 60s — `--request-timeout` bounds nothing on
  # that fault shape. Two points disagreeing by >2x is not a model. The exit code is deterministic
  # and fault-independent and needs no retry knowledge.
  #
  # ⚠️ AND IT IS THE SSO GUARANTEE. This arm must NEVER fall through to UNAUTHORIZED, whose remedy
  # names a vSphere SSO bind — and vCenter locks out PERMANENTLY after THREE failures. Keying on the
  # exit code guarantees that regardless of what the fault happens to write to stderr, which no
  # string-matching model can promise.
  case "$_rc" in
    124|137)
      _kube_tok="<could not ask>"
      _kube_state="${_p} — MY OWN timeout expired before the server answered (rc=${_rc}). This says
      NOTHING about the lab: give it longer with CREDS_KUBE_TIMEOUT_SECONDS (or CREDS_K8S_TIMEOUT
      for the Supervisor reads) and re-run."
      return 0 ;;
  esac
  case "$(classify_kube_failure "$_e")" in
    FORBIDDEN)           _kube_tok="<forbidden>";     _kube_state="${_p} — FORBIDDEN: this identity may not read that in '${VKS_NAMESPACE:-?}'. Ask your platform admin." ;;
    # ⚠️ "Re-run: make vks-login" WAS A NO-OP FOR THIS FAILURE, and it cost a real session.
    # MEASURED 2026-09-07: with VKS_AUTH_METHOD=kubeconfig that arm (30-vks-login.sh:42-45) is a
    # [ -s ] test on the GUEST kubeconfig plus `kubectl cluster-info`; it never touches the
    # Supervisor. docs/scenario-1.md:616-626 already said so and this file had not heard.
    # 🔴 IT NAMES THE SSO COMMAND ON EXACTLY ONE ARM: EXPIRED, where the cause is a FACT read from
    # the token's own `exp`. Every other arm names NO command at all; the one arm that must EXPLAIN
    # the absence calls `_renew_how --no-command` (exactly one call site). The obvious remedy —
    # VKS_AUTH_METHOD=vcf make vks-login — performs a vSphere SSO BIND (30-vks-login.sh:397), and
    # vCenter locks out PERMANENTLY after 3 failures, so it must never be prescribed for a state
    # this report cannot decide. (This comment said "DELIBERATELY NAMES NO SSO COMMAND" and was
    # falsified by the commit that added the EXPIRED arm; a round caught it.) The message costs ZERO
    # attempts; prescribing that one costs >=1 PER INVOCATION of a report people re-run, and this
    # arm cannot tell "token expired, password fine" from "password rotated" (30-vks-login.sh:582-585
    # says so), so on the second it burns an attempt every time. vCenter locks out PERMANENTLY at 3.
    # The NEGATIVE below is decidable and free, and it is the half that actually unblocks the reader.
    UNAUTHORIZED)        _kube_tok="<auth failed>";   _kube_state="${_p} — $(_rejected_why)" ;;
    STALE_CA)            _kube_tok="<stale CA>";      _kube_state="${_p} — the Supervisor answered but its CA does not verify (kubeconfig from a destroyed lab?)" ;;
    UNREACHABLE)         _kube_tok="<unreachable>";   _kube_state="${_p} — the Supervisor is unreachable from here" ;;
    PLAINTEXT)           _kube_tok="<plaintext>";     _kube_state="${_p} — the Supervisor endpoint answered PLAINTEXT where TLS was expected" ;;
    NO_KUBE_TARGET)      _kube_tok="<no target>";     _kube_state="${_p} — the kubeconfig names no cluster" ;;
    KUBECONFIG_UNUSABLE) _kube_tok="<bad kubeconfig>"; _kube_state="${_p} — the kubeconfig is unusable (something it NAMES is missing)" ;;
    *)                   _kube_tok="<kubectl failed>"; _kube_state="${_p} — kubectl failed for a reason we do not classify" ;;
  esac
}

# A ROBOT CANNOT LOG INTO THE HARBOR WEB UI -- measured on the live lab: the `robot$...` pair returns
# 412 from /api/v2.0/users/current while admin returns 200 (controls: admin+wrong-password 401,
# no-credentials 401). The row above is the REGISTRY credential the pipeline pushes with, which is
# deliberately least-privilege (22-harbor-robot.sh mints push+pull only, so admin is never baked into
# Tekton's push Secret). But this table is headed "Access the UIs", so the UI credential gets its own
# row rather than a footnote explaining its absence.
#
# ⚠️ ATOMIC PAIR FROM ONE SOURCE, per the rule above: the username is `admin` BY DEFINITION of this
# secret and the password comes from that same secret -- never field-by-field from two places.
# Supervisor-only by nature (RULE ZERO-B): a tenant without it gets the command, not a broken cell.
#
# 🔴 THE REMEDY THIS CELL USED TO NAME COULD NEVER WORK. It printed
# `<not read — run: make harbor-admin-password>`. But this whole block is gated on
# `harbor_username_is_robot`, so whenever that sentence renders, HARBOR_USERNAME *is* a robot — and
# in exactly that state `28-harbor-admin-password.sh` either exits 0 without reading the admin
# secret (:60-62, "already authenticates - leaving it alone") or DIES REFUSING (:79, "is a ROBOT
# account ... that would silently downgrade a least-privilege setup"). So the report sent the
# operator to a command that, in the only state where the advice appeared, cannot produce the value.
# A shipped RULE ZERO-V violation, found by a round on 2026-09-07 that was chartered to look at
# something else entirely. Falsifier, non-mutating:
#   bash -c 'set -a; . .env; set +a; case "$HARBOR_USERNAME" in robot\$*) echo "cell renders AND the
#            command refuses";; esac'
#
# It now says WHAT HAPPENED, from `_kube_classify` — the same eight-class mapping the SSH row uses,
# so "expired" and "forbidden" and "the lab is off" stop collapsing into one sentence. The reason is
# a FOOTNOTE, not a cell: the password column's width is a max over every row (the SSH block records
# the measurement that forced that split).
if harbor_username_is_robot "${HARBOR_USERNAME:-}"; then
  _h_admin_pw="<not read>"; _h_admin_why=""
  _h_sup="$(supervisor_kubeconfig 2>/dev/null || true)"
  if [ -z "$_h_sup" ]; then
    # A TENANT HAS NO SUPERVISOR AND THAT IS NORMAL (RULE ZERO-B: it is the DEFAULT posture), so this
    # is not an error and must not name `make vks-login` — the round refuted that: `absent` cannot be
    # told apart from "scenario-1 operator who has not logged in yet", and asserting the wrong one at
    # a persona who is fine reads as a broken product.
    _h_admin_why="no Supervisor kubeconfig here — this password lives on the Supervisor, so ask your platform team for it"
  elif [ "$_no_probe_snapshot" = 1 ]; then
    _h_admin_why="not probed (CREDS_NO_PROBE=1)"
  fi
  if [ -n "$_h_sup" ] && [ "$_no_probe_snapshot" != 1 ]; then
    _h_err="$(mktemp)"; _h_ns="${HARBOR_SERVICE_NAMESPACE:-}"
    # `|| true` IS LOAD-BEARING, and its absence killed the WHOLE report. MEASURED 2026-09-07:
    # without it a failing kubectl makes the pipeline non-zero, and because the substitution is the
    # LAST command of the `[ -n ] ||` list, `set -e` fires — the run exited rc=7 having printed only
    # the Context block. The services table, the lab-access table and every footnote were LOST.
    # Its SIBLING two lines down already had the guard; this one did not. Reachable whenever the
    # Supervisor is slow, the token has expired, or the caller is a tenant (Forbidden).
    # stderr is CAPTURED, not discarded. `2>/dev/null` is what made every failure here look
    # identical — the conflation of "I could not ask" with "the answer is no" that this file's own
    # comment says was already fixed twice elsewhere.
    # ⚠️ THE rc IS CAPTURED, NOT INFERRED FROM EMPTINESS. The first cut of this block branched on
    # "is the output empty", and an implementation round MEASURED two ways that is wrong:
    #   * rc=0 + EMPTY is a SUCCESS — kubectl asked and there is genuinely no namespace labelled
    #     serviceId=harbor (Harbor not installed as a Supervisor Service, a routine Scenario-2
    #     shape). Classifying it printed "kubectl failed for a reason we do not classify" about a
    #     kubectl that exited 0. That is the SAME conflation this change exists to remove, inverted.
    #   * classify_kube_failure on an EMPTY errfile returns UNKNOWN, so the sentence was not merely
    #     wrong, it was maximally uninformative.
    # No `| head -1 | sed` either: a pipeline hides the rc, and `head` early-exits (the SIGPIPE trap
    # in rules/shell/coding-style.md). Parameter expansion does the same job with no forks and no
    # status to lose.
    if [ -z "$_h_ns" ]; then
      _h_nsraw="$(KUBECONFIG="$_h_sup" timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl \
          --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-5s}" get ns \
          -l appplatform.vmware.com/serviceId=harbor -o name 2>"$_h_err")" && _h_rc=0 || _h_rc=$?
      _h_ns="${_h_nsraw%%$'\n'*}"; _h_ns="${_h_ns#namespace/}"
      if [ "$_h_rc" -ne 0 ]; then
        _kube_classify "$_h_err" "could not ask the Supervisor for the Harbor service namespace" "$_h_rc"
        _h_admin_pw="$_kube_tok"; _h_admin_why="$_kube_state"
      elif [ -z "$_h_ns" ]; then
        _h_admin_pw="<no harbor ns>"
        _h_admin_why="the Supervisor answered, and has NO namespace labelled appplatform.vmware.com/serviceId=harbor — Harbor is not a Supervisor Service on this lab, so there is no admin secret here to read"
      fi
    fi
    if [ -n "$_h_ns" ]; then
      # ⚠️ SAME TREATMENT, and the guard that used to be here was DEAD CODE. It read
      # `[ -z "$_h_admin_pw" ]`, but the initialiser two blocks up sets `<not read>` — a 10-character
      # string — so the test was ALWAYS false and `_kube_classify` was NEVER reached on this call.
      # MEASURED with two stubs (NotFound rc=1; rc=0 with the key renamed): both rendered a bare
      # `<not read>` with no footnote at all. The stderr capture added on the same line was written
      # to a file nothing read.
      _h_enc="$(KUBECONFIG="$_h_sup" timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl \
          --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-5s}" -n "$_h_ns" get secret harbor-core-ver-1 \
          -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>"$_h_err")" && _h_rc2=0 || _h_rc2=$?
      if [ "$_h_rc2" -ne 0 ]; then
        _kube_classify "$_h_err" "could not read harbor-core-ver-1 in ${_h_ns}" "${_h_rc2:-${_h_rc:-}}"
        _h_admin_pw="$_kube_tok"; _h_admin_why="$_kube_state"
      elif [ -z "$_h_enc" ]; then
        # rc=0 and nothing back: the SECRET is there, the KEY is not. Do not say kubectl failed.
        _h_admin_pw="<no key>"
        _h_admin_why="harbor-core-ver-1 in ${_h_ns} carries no HARBOR_ADMIN_PASSWORD key (renamed upstream?)"
      else
        _h_admin_pw="$(printf '%s' "$_h_enc" | base64 -d 2>/dev/null || true)"
        if [ -z "$_h_admin_pw" ]; then
          _h_admin_pw="<undecodable>"
          _h_admin_why="harbor-core-ver-1 in ${_h_ns} holds a HARBOR_ADMIN_PASSWORD that is not valid base64"
        fi
      fi
    fi
    rm -f "$_h_err"
  fi
  case "$_h_admin_pw" in
    '<'*) : ;;                                   # a placeholder — print it, never mask it
    *)    _h_admin_pw="$(_mask "$_h_admin_pw")" ;;
  esac
  add_row "Harbor (web UI)" "$harbor_url" "admin" "$_h_admin_pw" "$(_reach_harbor)"
fi
# Render the PROVENANCE with the value. A bare secret here reads as "this is your password",
# and on the primary runbook it is the pre-rotation one from Step 5 onward — which is the state
# that produced a live 401 and a backlog row proposing a network probe to detect it.
# ⚠️ THE SENTENCE LEAVES THE CELL. It used to be appended to the PASSWORD cell -- 77 characters
# inside a column whose width is a max over all rows. An adversary measured the table at 171 chars
# with ONE data row (header 171, Harbor row 170), i.e. already wrapping on BOTH 80- and 120-col
# terminals, and identified this sentence -- not the URL markers -- as the offender. creds.sh's own
# rule at the ArgoCD URL arm says it: "A SENTENCE IN A URL COLUMN DESTROYS THE TABLE. Keep the cell
# short; the instruction goes in a footnote." That rule was enforced for the URL column and violated
# for the Password column. The provenance is NOT dropped: the flag survives and the footnote states
# it in full, where it costs no width.
_argo_initial_note=0
if [ "${_argo_initial:-0}" = 1 ] && [ -n "$argo_pw" ]; then _argo_initial_note=1; fi
add_row "ArgoCD" "$argocd_url" "$argo_user"   "$argo_pw"   "$(_reach_argocd)"
# CAPTURE INTO VARIABLES FIRST -- do NOT inline these `$( )` into add_row's ARGUMENTS.
# MEASURED 2026-08-22 with a newly-enrolled app whose app_health_path() branch did not yet exist:
#     FATAL  app 'nodejswebapp': add a branch to app_health_path()
#     nodejswebapp  <needs ingress>  -  (no login; health at )      <- rendered anyway, EMPTY
#     rc=0                                                          <- and reported SUCCESS
# A `die` inside `$( )` in ARGUMENT position does not trip `set -e`: the substitution's subshell
# exits, the empty string is substituted, and the caller carries on. An ASSIGNMENT propagates it.
# Same class as the trivy-fs fail-open fixed earlier today, and as `for x in $(dying_fn)`.
# DEGRADE on the REGISTRY read; stay FATAL on the per-app accessors. Those are different faults:
# an unknown language is a wiring BUG that must not render a blank field, but an unreadable or
# comments-only registry must not delete the Gitea/Harbor/ArgoCD rows and the whole Lab-access
# section, none of which depend on it. This file is a PRINTER (see :245, :194) and :389 records the
# exact incident: "set -e kills the report before it prints anything ... died with 'Error 1' and no
# output at all."
# MEASURED: the naive `_apps="$(app_names)"` took test-creds-show.sh from 42-ok/0-FAIL to
# 34-ok/8-FAIL -- every assertion reading output printed AFTER this loop. `app_names` also exits 1
# on a COMMENTS-ONLY registry (its grep -vE matches nothing), which is a documented workflow here
# ("FINISH the app, THEN add its row"), not a fault.
# `if ! x="$( )"` is a condition context, so set -e is correctly suspended for this read only.
if ! _apps="$(app_names)"; then
  log_warn "app registry unreadable or empty — omitting the per-app rows"
  _apps=""
fi
while read -r _a; do
  [ -n "$_a" ] || continue
  _host="$(app_host "$_a")"
  _health="$(app_health_path "$_a")"
  _url="$(ingress_url "$_host")"
  # ⚠️ LATENT, NOT CATCHING ANYTHING TODAY -- said plainly, because a check that cannot fire reads
  # as a guarantee (:222 deleted a previous marker for exactly that reason). MEASURED: no arm of
  # app_health_path returns rc=0-with-empty-output, so the assignment above already does the work.
  # This arms the moment one does -- app_build_args' go arm (an intentional empty printf) is the
  # precedent for a per-language accessor that legitimately prints nothing.
  [ -n "$_health" ] || die "app '$_a': app_health_path() returned nothing — refusing to print a credentials row with a blank health path."
  add_row "$_a" "$_url" "-" "(no login; health at ${_health})" "$(_reach_ingress "$(app_host "$_a")")"
done <<EOF
${_apps}
EOF

# how long the probing ACTUALLY took -- printed so the estimate above stays honest. If this ever
# reads much larger than the stated bounds, a probe has escaped its timeout, and that is a defect
# the operator can see rather than one they merely endure.
if [ "$_no_probe_snapshot" != 1 ]; then
  _probe_t1=$(date +%s 2>/dev/null || echo 0)
fi

# --- NO SINGLE VALUE MAY BLOW OUT THE TABLE ------------------------------------------------------
# MEASURED 2026-09-05: adding headlamp put a ~1000-character ServiceAccount JWT in the Password
# cell. The widths below are a MAX OVER ALL ROWS, so that one token padded EVERY row to ~1000
# columns and the table became unreadable on any screen. A JWT is not a password and does not
# belong in a fixed-width cell.
# So: any cell longer than CREDS_MAX_CELL is replaced by a short marker and its full value is
# printed BELOW the table, one per line, where width does not matter. The reader still gets the
# value; the table stays a table.
CREDS_MAX_CELL="${CREDS_MAX_CELL:-44}"
_long_notes=""
_rows_capped=""
while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
  [ -n "$c1" ] || continue
  # A MARKER (`<...>`) is a placeholder, not a value — never footnote one. Measured: capping at 44
  # sent the 53-char "hidden, re-run with SHOW_SECRETS=1" marker to the footnote, which then read
  # "full value (too long for the table): <hidden: ...>". The cap exists for real secrets that are
  # genuinely too long (a JWT), not for text the report wrote itself.
  case "$c4" in '<'*'>') _is_marker=1 ;; *) _is_marker=0 ;; esac
  if [ "$_is_marker" = 0 ] && [ "${#c4}" -gt "$CREDS_MAX_CELL" ]; then
    _long_notes="${_long_notes}${c1}"$'\t'"${c4}"$'\n'
    c4="<full value below>"
  fi
  _rows_capped="${_rows_capped}${c1}"$'\t'"${c2}"$'\t'"${c3}"$'\t'"${c4}"$'\t'"${c5}"$'\n'
done <<EOF
$rows
EOF
rows="${_rows_capped%$'\n'}"

# Measure every column against every row (headers included), then print.
w1=7; w2=3; w3=8; w4=8   # header widths are the floor: Service, URL, Username, Password
while IFS=$'\t' read -r c1 c2 c3 c4 _c5; do
  [ -n "$c1" ] || continue
  [ "${#c1}" -gt "$w1" ] && w1="${#c1}"
  [ "${#c2}" -gt "$w2" ] && w2="${#c2}"
  [ "${#c3}" -gt "$w3" ] && w3="${#c3}"
  [ "${#c4}" -gt "$w4" ] && w4="${#c4}"
done <<EOF
$rows
EOF

printf '\n  %-*s  %-*s  %-*s  %-*s  %s\n' "$w1" "Service" "$w2" "URL" "$w3" "Username" "$w4" "Password" "Reachable"
printf '  %-*s  %-*s  %-*s  %-*s  %s\n' \
  "$w1" "$(printf '%*s' "$w1" '' | tr ' ' '-')" \
  "$w2" "$(printf '%*s' "$w2" '' | tr ' ' '-')" \
  "$w3" "$(printf '%*s' "$w3" '' | tr ' ' '-')" \
  "$w4" "$(printf '%*s' "$w4" '' | tr ' ' '-')" \
  "$(printf '%*s' 9 '' | tr ' ' '-')"
# ── PRINT WHAT IS AVAILABLE; SUMMARISE THE REST IN ONE LINE ────────────────────────────────────
# ⚠️ The contract is "show a picture of the cluster and let me access what is available". Eight rows
# for services that do not exist are NOISE, and they buried the two rows that mattered: measured,
# 55 lines of which 2 carried a usable URL+credential. test-creds-show:160 states the licence for
# this explicitly -- "Nothing serves those hosts (the ingress is OPTIONAL). Say <needs ingress>, OR
# SAY NOTHING." So: reachable rows get the table; the rest get one line naming them and the command.
# ⚠️ They are SUMMARISED, NOT DROPPED. creds.sh's own history records that deleting rows outright is
# a defect (a degraded registry read must not delete Gitea/Harbor/ArgoCD), and an operator still
# needs to know the thing EXISTS and is merely unreachable.
_un_ing=""; _un_oth=""
while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
  [ -n "$c1" ] || continue
  # ⚠️ SPLIT ON "IS THERE AN ADDRESS TO GIVE YOU", **NOT** ON THE PROBE RESULT.
  # A first version sent every non-`serving` row to the summary line, and test-creds-show caught it
  # immediately: with an ingress PRESENT but the probe unable to confirm (a fixture, no network,
  # CREDS_NO_PROBE), the *.vks.local URLs DISAPPEARED -- "over-correcting into silence is its own
  # defect", which this file already records. A probe that COULD NOT ASK is not a service that said
  # no. So: if the row has a real URL, it stays in the table WITH its reachability, whatever that
  # says; only rows with nothing to show (<needs ingress>, <not set>) collapse into one line.
  # THE ROW IS ALWAYS PRINTED. The summary below is an ADDITION, never a replacement.
  # MEASURED 2026-09-05 (adversary, CRITICAL): the previous form DROPPED the row whenever the URL
  # cell was empty -- and the row carries the PASSWORD. Two runs differing only in ARGOCD_SERVER:
  #     unset        -> `grep -c ZZARGOSECRET` = 0   (the credential was GONE from the report)
  #     =10.0.0.9    -> `grep -c ZZARGOSECRET` = 1
  # The password was in a variable in BOTH runs. The URL is the half a user can often discover for
  # themselves; the credential is the half they cannot get anywhere else -- so the drop threw away
  # the irreplaceable one. The block's own comment claimed "SUMMARISED, NOT DROPPED"; measured, the
  # summary line carries ONLY the service name -- no username, no password, no reachability.
  # It also left the --raw nested-sentinel SECURITY assertion permanently vacuous (no row => nothing
  # to assert on: a red converted into a green that can never fire) and re-opened B517.
  printf '  %-*s  %-*s  %-*s  %-*s  %s\n' "$w1" "$c1" "$w2" "$c2" "$w3" "$c3" "$w4" "$c4" "$c5"
  case "$c2" in
    '<needs ingress>') _un_ing="${_un_ing:-}${_un_ing:+, }${c1}" ;;
    '<not set>'|'')    _un_oth="${_un_oth:-}${_un_oth:+, }${c1}" ;;
  esac
done <<EOF
$rows
EOF

# THE ONE THING BETWEEN THE OPERATOR AND THE UI. If any row came back `no DNS here`, the service is
# fine and the NAME is what is broken — say so, and say it right under the table rather than leaving
# the reader to conclude the app is down. (2026-09-05: a browser got DNS_PROBE_FINISHED_NXDOMAIN on
# a host this report had just called `serving`.)
# ⚠️ A ROBOT CANNOT LOG INTO THE HARBOR WEB UI, and this table's whole purpose is "Access the UIs".
# MEASURED 2026-09-06 on the live lab: the configured `robot$...` credential returns HTTP 412 from
# /api/v2.0/users/current ("get current user not available for security context: robot"), while the
# Supervisor's admin returns 200 -- with both controls (admin+wrong-password 401, no-credentials
# 401). So the row was handing the reader a credential that cannot do the thing the row is for.
#
# ⚠️ LABEL ONLY -- NO LIVE READ. The block above states the rule: username and secret move as ONE
# ATOMIC PAIR from ONE source, never field-by-field. Fetching admin here would violate that and would
# also need Supervisor access, which a RULE ZERO-B tenant does not have. So we say what the credential
# IS and where the other one comes from, and let the operator choose.
#
# The `robot$` test is a pure STRING test, and this repo records that such a test must never GATE an
# auth decision. It does not gate here -- it only decides whether to print a hint, so its residual
# (an unusual robot name prefix) costs a missing hint, never a false claim.
case "$rows" in
  *'stale DNS'*)
    printf '\n  ⚠️  Some hosts above RESOLVE ON THIS MACHINE TO A DIFFERENT ADDRESS than the ingress\n'
    printf '      that is serving them — almost always an /etc/hosts line left by a PREVIOUS lab.\n'
    printf '      The service is NOT broken; the link is. A browser here will fail to connect.\n'
    printf '      ⚠️ APPENDING a second line is UNRELIABLE: it helps only if the stale address is\n'
    printf '      dead, and if that lab is still running the stale entry keeps winning. REPLACING\n'
    printf '      works either way (needs root) — check what is there first:\n'
    printf '        grep -n vks.local /etc/hosts\n'
    printf '        sudo sed -i "s/^[0-9.]\\+\\( \\+.*vks\\.local\\)/%s\\1/" /etc/hosts\n' "${INGRESS_LB_IP:-<ingress-lb-ip>}"
    printf '      Then re-run this report; every affected row should turn to serving.\n'
    ;;
  *'no DNS here'*)
    printf '\n  ⚠️  Some hosts above are SERVED by the ingress but do not RESOLVE on this machine,\n'
    printf '      so a browser here gets DNS_PROBE_FINISHED_NXDOMAIN. The service is not broken —\n'
    printf '      the name is. Add the /etc/hosts line printed above (needs root):\n'
    printf '        sudo sh -c '"'"'printf "%%s  %%s\\n" "%s" "%s" >> /etc/hosts'"'"'\n' \
      "${INGRESS_LB_IP:-<ingress-lb-ip>}" "$(ingress_infra_hosts)$(app_names | while read -r _a; do if [ -n "$_a" ]; then printf '%s ' "$(app_host "$_a")"; fi; done)"
    printf '      Or create those names as A records pointing at %s in your DNS: make show-dns-records\n' "${INGRESS_LB_IP:-<ingress-lb-ip>}"
    ;;
esac

# The values too long to sit in a cell, printed where width does not matter. One per line, the
# service named, so it is still copy-pasteable — which is the whole point of this report.
if [ -n "${_long_notes:-}" ]; then
  while IFS=$'\t' read -r _ln_svc _ln_val; do
    [ -n "$_ln_svc" ] || continue
    printf '\n  %s — full value (too long for the table):\n    %s\n' "$_ln_svc" "$_ln_val"
  done <<EOF
$(printf '%s' "$_long_notes")
EOF
fi
# ⚠️ THE NOTE MAY ONLY STATE A FACT ABOUT THIS REPORT, NEVER ABOUT THE CLUSTER (B517, and it
# took two PRs to land). "no ingress, so no URL to show" READS AS a cluster claim -- and we
# frequently cannot support it: when the guest cluster is unreachable we do not know whether an
# ingress exists, whether the component is installed, or whether it is happily serving. What we
# DO know is that no ingress address is configured HERE, which is a fact about this box.
# The phrase "not about the cluster" is asserted by STATE 12 in test-creds-show.sh; so is
# "port-forward" (the only remedy correct in every persona). Do not drop either.
if [ -n "${_un_ing:-}" ]; then
  printf '\n  no URL in this report for: %s\n' "$_un_ing"
  printf '    That is a fact about THIS REPORT, not about the cluster — no ingress address\n'
  printf '    is configured here.  URL: make install-ingress   |   now: kubectl -n <ns> port-forward svc/<svc> 8080:<port>\n'
fi
if [ -n "${_un_oth:-}" ]; then
  printf '\n  no address configured here for: %s\n' "$_un_oth"
  printf '    Again a fact about THIS REPORT, not about the cluster.\n'
fi

# The <... — see note> markers in the Password column, explained where width is free.
# Re-derived from the SAME globals `_unset_pw` branches on, so cell and note cannot drift.
if printf '%s' "${rows:-}" | grep -q -- '— see note'; then
  if [ "${_sink_refused:-0}" = 1 ]; then
    printf '\n  note: those passwords are held by an overlay this report REFUSED — it belongs to a\n'
    printf '        DIFFERENT cluster. Do NOT use them.\n'
  elif [ "${_have_sink:-0}" = 1 ]; then
    printf '\n  note: those passwords are not published in the state overlay this report is using.\n'
  else
    printf '\n  note: those passwords do not exist yet. KinD GENERATES them at install; for a real\n'
    printf '        lab, set them in .env (see .env.example for the variable names).\n'
  fi
fi

# ---- notes the TABLE CELLS point at. A cell may carry a short marker; the sentence lives here.
# A marker that says "see note" with no note is a citation that resolves to nothing -- worse than no
# marker at all, because it reads as sourced.
if [ "${_headlamp_note:-0}" = 1 ]; then
  printf '\n  Headlamp: if the token screen comes straight back, the token expired — copy a fresh one above.\n'
fi
# WHY the Harbor admin password is missing, and what to ACTUALLY do about it. Printed only when the
# cell did not resolve, so a healthy run stays quiet.
#
# ⚠️ TOP-LEVEL, and it was NOT. The first cut landed INSIDE `if [ "${_headlamp_note:-0}" = 1 ]`, so
# it rendered only when the HEADLAMP token had been read — two unrelated facts welded together. An
# implementation round MEASURED perfect discrimination on identical input: headlamp read -> footnote
# present; headlamp unread -> footnote SILENT while the cell still showed its token. The persona who
# loses most is the one this whole change is for: a tenant (RULE ZERO-B default) with no Supervisor
# AND no headlamp, who got a bare token and no explanation — strictly LESS than the wrong-remedy
# sentence it replaced.
#
# ⚠️ THE REFUSAL SENTENCE IS NOT AN ABSOLUTE. 28-harbor-admin-password.sh has TWO robot behaviours:
# :58-62 exits 0 leaving a WORKING robot credential alone, and :78-89 dies refusing. Saying it
# "REFUSES" unconditionally is false in the healthy state scenario-1 Step 9 produces — the operator
# runs it, gets rc=0 and two INFO lines, and still has no password. Say what is true of BOTH arms.
if [ -n "${_h_admin_why:-}" ]; then
  printf '\n  Harbor admin password NOT read: %s\n' "$_h_admin_why"
  # No backticks: shellcheck reads them as command substitution inside a single-quoted printf
  # (SC2016), and they are pure decoration in terminal output.
  printf '    make harbor-admin-password will NOT produce it: with a robot HARBOR_USERNAME (yours\n'
  printf '    is one, which is why this row is here at all) it either leaves the working robot\n'
  printf '    credential alone and exits 0, or refuses outright rather than downgrade a\n'
  printf '    least-privilege credential to full admin. This value is read from the Supervisor.\n'
fi
if [ "${_argo_initial_note:-0}" = 1 ]; then
  case "${_argo_state}" in
    CURRENT)
      printf '\n  ArgoCD: this password is CURRENT — it has not been changed since the instance was created.\n' ;;
    STALE)
      printf '\n  ArgoCD: the password above is DEAD — it was changed%s. The current one cannot be\n' \
        "${_argo_changed_at:+ at ${_argo_changed_at}}"
      printf '          recovered (only a hash is kept); ask whoever changed it, or reset it.\n' ;;
    *)
      printf '\n  ArgoCD: cannot tell whether this password is still current. Check: make argocd-auth-check\n' ;;
  esac
fi
# ⚠️ KEYED ON A FLAG, NOT ON THE RENDERED STRING. This case used to match the URL text, and the
# very next edit -- rewording the marker from `(--insecure; see note)` to
# `(discovered; --insecure — see note)` -- silently stopped matching it. MEASURED: the note count
# went to 0 while the cell still said "see note", i.e. a citation resolving to NOTHING, which reads
# as sourced and is worse than no marker at all. Display text is not a control channel.
case "${_argo_tls_flag:-0}" in
  1)
    printf '\n  note: rows marked "untrusted cert" are not signed by a CA your machine trusts.\n'
    printf '        In a browser: click through the warning. With curl/CLI: --insecure.\n'
    printf '        ArgoCD is also at a BARE IP and its cert carries no IP SAN, so no client can\n'
    printf '        verify it at that address at all; a verifying path needs a DNS name.\n' ;;
esac

# --- footnote: WHAT IS NOT REAL YET, and whose job it is to fix ------------------------
#
# ArgoCD used to be the ONLY row with a note, and that made the table LIE BY CONTRAST: ArgoCD honestly
# printed `<not set>` while Harbor printed `https://harbor.vks.local` / `Harbor12345` — values that are
# EQUALLY unreal (they are .env.example defaults). A reader concludes "Harbor is configured, ArgoCD is
# not", when NEITHER is. ArgoCD only looked different because it happens to have no default, which is an
# accident of .env.example, not a fact about the system.
#
# So the footnote is about the STATE, not about one service:
#   * nothing installed  -> EVERY value here is a default. Say which ones fill themselves in (KinD) and
#                           which the operator must supply (a real lab).
#   * installed, but ArgoCD's address still unknown -> that IS a genuine per-service gap; name it.
if [ "$_have_sink" = 0 ] && [ "$_env_populated" = 1 ]; then
  # ⚠️ THE OTHER ARM BELOW MAKES A POSITIVE, CHECKABLE CLAIM THAT IS FALSE HERE, and that is worse
  # than vagueness: a reader who checks it finds it false. It says every value came from
  # .env.example and "none of them exists" — but HARBOR_PASSWORD is COMMENTED in .env.example
  # (measured: uncommented=0), so a value on screen CANNOT have come from there, and on a real lab
  # the address is a live one the operator typed. Being told "placeholder" about a real credential
  # is how it ends up in a ticket, a screenshot or a chat, unrotated.
    # ⚠️ DELIBERATELY SILENT — do NOT re-add prose here. This arm printed a five-line paragraph
    # plus a SECOND copy of _settle_note (the Context block above already prints both), and a KinD
    # line in a report whose flow may be a real VKS lab. MEASURED 2026-09-05: `make creds` was 71
    # lines of which 13 carried a value — 82% prose — with the ~10-line remedy block VERBATIM TWICE.
    # ⚠️ THE `if` CONDITION MUST SURVIVE, EMPTY. Deleting this arm outright is a bash SYNTAX ERROR
    # (measured: "syntax error near unexpected token 'elif'"), and promoting the `elif` instead makes
    # this state fall into the PLACEHOLDER arm below, which claims "None of them exists" about live
    # .env credentials — the B161 finding (its gate catches it, rc=1).
    # The one fact this arm carried that Context did not — "treat every credential as LIVE" — is now
    # IN Context. Everything else was a restatement, and the honest PER-ROW answer is the Reachable
    # column, which is where a reader actually looks.
    : # intentionally no output
elif [ "$_have_sink" = 0 ]; then
  printf '\n  note: EVERY value above is a PLACEHOLDER from .env.example, not a credential —\n'
  printf '        including Harbor'\''s and Gitea'\''s. None of them exists.\n'
  printf '          KinD     : the real addresses and passwords are discovered and filled in for you by\n'
  printf '                     the install (make e2e-kind / make install-all). Set nothing by hand.\n'
  printf '          Real lab : you supply HARBOR_URL + HARBOR_PASSWORD (and ARGOCD_SERVER) in .env —\n'
  printf '                     see docs/scenario-1.md (you install) or docs/scenario-2.md (you are a tenant).\n'
else
  if [ -z "$_ing" ]; then
    # ⚠️ SAY WHAT WE KNOW, NOT A FACT ABOUT THE WORLD. "no ingress is installed ... nothing serves
    # those hosts" is a claim about the CLUSTER derived from a VARIABLE. When the overlay was
    # refused the variable is merely absent, and the measured case had all eight hosts serving 200
    # while this note said nothing did. (B517.)
    if [ "$_sink_refused" = 1 ]; then
    # ⚠️ DO NOT PRESCRIBE `make verify-ingress` HERE. It is HARD-GUARDED on the very variable whose
    # absence produced this note (98-verify-ingress.sh aborts with INGRESS_LB_IP unset), so it dies
    # without checking anything -- a remedy that cannot run. Nor `make install-ingress`: its default
    # INGRESS_CONTROLLER=istio HELM-INSTALLS a mesh, and a Scenario-2 TENANT does not own the
    # cluster's mesh (they attach with istio-existing). The port-forward is the only remedy that is
    # read-only and correct in EVERY persona, which is why the arm below has always carried it and
    # why a first version of this note deleting it was a regression: it repaired the CLAIM and broke
    # the ACTION.
    # ⚠️ the ingress explanation now lives in the ONE grouped line above the table.
    # It was printed twice: once there and once here, in different words.
    :
    else
    # ⚠️ THIS BRANCH IS THE ONE THE MATRIX HITS, AND IT WAS LEFT UNREPAIRED. The B517 fix repaired the
    # REFUSED arm directly above and stopped there, so the false world-claim survived in the arm that
    # actually runs: `state-overlay: SOURCED`, `values-provenance: STORED`, no INGRESS_LB_IP -- i.e. a
    # box that simply has not installed an ingress, which is every scenario-2 row. MEASURED on one
    # cluster, 72m30s apart: row 3 at 05:08:15Z printed `SUCCESS — all 8 UI(s) reachable through the
    # istio ingress at 192.168.101.134` with 8/8 body markers; row 6 at 06:20:45Z printed
    # `<needs ingress>` x8 plus `nothing serves those hosts`. In row 6's ENTIRE log the string
    # `vks.local` occurs exactly ONCE -- inside that sentence.
    #
    # `INGRESS_LB_IP` is a fact about THIS BOX'S STATE OVERLAY. It is not a fact about the cluster,
    # and this report has no other evidence about the cluster's ingress -- so it must not make one.
    # The port-forward STAYS: a first repair of the sibling arm deleted it and that was a regression,
    # because it is the only remedy correct in every persona (:681-687 records it).
    # ⚠️ The ingress explanation now lives in the ONE grouped line printed above, beside the
    # rows it concerns. It used to be said TWICE, in different words, in the same report.
    :
    fi
  fi
  if [ "$argocd_url" = "<not set>" ]; then
    # Same class as the ingress note one row up, and it was left untouched by the first fix: under a
    # REFUSAL the overlay's ARGOCD_LB_IP is not ABSENT, it is out of scope -- so a flow claim
    # ("KinD fills it in automatically") explains a MISSING as an absence, on a report whose flow
    # line now reads "undetermined".
    if [ "$_sink_refused" = 1 ]; then
    printf '\n  note: ArgoCD'\''s address is not shown because the state overlay that would carry it was\n'
    printf '        REFUSED — not because none exists. Set ARGOCD_SERVER in .env to name it explicitly.\n'
    else
    printf '\n  note: ArgoCD'\''s address is not set. KinD fills it in automatically when ArgoCD is installed;\n'
    printf '        on a real lab, set ARGOCD_SERVER in .env.\n'
    fi
  fi
fi

# ── Lab access — the values the END USER supplies, and which NO installer publishes ──────────────
# RULE ZERO-B: the end user clones THIS repo only. The lab is a black box to them; everything they
# know about it arrives through `.env`, which the scenario documents tell them to fill.
#
# These rows were MISSING ENTIRELY, which is what the operator hit: they asked "why don't I see
# vCenter credentials" and the answer was that nothing here ever printed them. MEASURED 2026-08-20:
# `.env.example` declares 31 credential/endpoint-shaped vars; 20 of them never reached this report.
# The 7 below are exactly the ones the scenario documents instruct the reader to SET (VCENTER_HOST 3
# mentions, VKS_USERNAME 6, SUPERVISOR_HOST 6, VCF_CLI_VSPHERE_PASSWORD 5, VCENTER_USERNAME 1,
# VCENTER_PASSWORD 1, VKS_PASSWORD 1). The other 13 are timeouts, CA paths and kube-contexts — not
# credentials, and not rows.
#
# ⚠️ NEVER AUTHENTICATE TO vCENTER FROM THIS PRINTER, AND NEVER REFRESH AN EXPIRED SUPERVISOR TOKEN
# HERE. vSphere SSO locks the account PERMANENTLY after 3 failed binds (docs/matrix-standing-rules.md
# §F.2, and lib/vcenter.sh:155-163 dies on the FIRST 401 for this reason). The precedent that it is
# fine to VERIFY a credential does NOT extend to this row: Harbor's penalty is a ~1.5s per-principal
# sleep and Gitea has none, so "we verify Harbor" is not an argument for touching vCenter.
# `supervisor_kubeconfig()` only RESOLVES an existing file and never refreshes — keep it that way, or
# merely rendering this section becomes an SSO bind. This section SHOWS; it never verifies.
#
# There is NO ssh row, and that is a measurement, not an omission: `.env.example` declares 0 SSH vars
# and the scenario documents mention ssh 0 times. SSH to the lab appliances belongs to the LAB repo,
# which the end user does not have. Do not invent a row for it.
#
# Secrets go through `_mask` exactly like the table above, so a TTY reveals and a PIPE hides. That is
# what keeps the walk row logs secret-free; any future row added here MUST use `_mask` for the same
# reason, or `/tmp/walk/MATRIX-row*.log` starts carrying live lab credentials.
_lab_rows=""
_lab_add() { _lab_rows="${_lab_rows}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\n'; }
# ⚠️ EMPTY IS NOT A SECRET (same trap as :251) — `_mask` renders its sentinel unconditionally, so an
# unset password would advertise a hidden value that does not exist and send the reader to
# SHOW_SECRETS=1 for nothing.
# ── B207: what `make vks-login` stops on FIRST, for the ACTIVE method ──────────────────────────
# The report printed `flow : real VKS lab (VKS_AUTH_METHOD=vcf)` and, two sections below, a
# credential that method needs as `<not set>` — holding both halves and never joining them. It
# then said `run: make vks-login`, which in that state cannot succeed.
#
# ⚠️ THE MAP IS HAND-TYPED ON PURPOSE. "Derive it from 30-vks-login.sh's dispatch" was REFUTED
# (idea round 2026-08-21): 6 of 11 mentions of these names in that file are COMMENTS, one a
# NOT-WIRED design note (:309-311) that a deriver reads as the wiring — the docstring-matching
# class in gates.md. `make check-vks-login-requires` asserts this map agrees with the script.
#
# ⚠️ THE ORDER IS THE DISPATCH ORDER, and ONLY the checks that `die` are listed.
# VCF_CLI_VSPHERE_PASSWORD is deliberately ABSENT: under `vcf` it only WARNS (30-vks-login.sh:350),
# so it is not a blocker. Naming it as "the" blocker was this fix's first draft, and it was wrong —
# vks-login dies on SUPERVISOR_HOST (:59) long before it looks at the password.
_vks_login_requires() {
  printf 'KUBECONFIG\n'                                   # :33  — global, every method
  case "${VKS_AUTH_METHOD:-}" in
    vcf)     printf 'SUPERVISOR_HOST\nVKS_CONTEXT_NAME\nVCF_CLI_VSPHERE_PASSWORD\n' ;;             # :59 :60, then :380
    vsphere) printf 'SUPERVISOR_HOST\nVKS_NAMESPACE\nVKS_CLUSTER_NAME\nVKS_USERNAME\nVKS_PASSWORD\n' ;; # :462-466
  esac
}
# ⚠️ TWO KINDS OF FATAL, and the message must not conflate them. The `:?` variables above kill
# vks-login at a requirement check. VCF_CLI_VSPHERE_PASSWORD does NOT: it only WARNS
# (30-vks-login.sh:351) and then `vcf context create` runs with `</dev/null` UNCONDITIONALLY (:380),
# so it cannot prompt and fails there instead. Measured 2026-08-21: there is NO short-circuit
# between the warn and the call. Leaving it out entirely was this fix's SECOND draft — and it made
# the note SILENT on the exact box the operator reported, which is the whole defect.
_unmet_why() {
  case "$1" in
    VCF_CLI_VSPHERE_PASSWORD) printf 'vcf context create runs with </dev/null, so it cannot prompt for it' ;;
    *)                        printf 'vks-login stops at that check' ;;
  esac
}
# Prints the FIRST unset requirement, or nothing. This is an OBSERVATION of THIS process after
# load_env — never a prediction about a future one: `VAR=… make vks-login` authenticates fine, so
# the wording below says "not set in .env or this environment", not "cannot authenticate".
_first_unmet() {
  local _v
  while IFS= read -r _v; do
    [ -n "$_v" ] || continue
    [ -n "${!_v-}" ] || { printf '%s' "$_v"; return 0; }
  done < <(_vks_login_requires)
  return 1
}

_lab_plain() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '<not set>'; fi; }
_lab_secret() { if [ -n "${1:-}" ]; then _mask "$1"; else printf '<not set>'; fi; }

_vc_ep=""; if [ -n "${VCENTER_HOST:-}" ]; then _vc_ep="https://${VCENTER_HOST}"; fi
_sup_ep=""; if [ -n "${SUPERVISOR_HOST:-}" ]; then _sup_ep="https://${SUPERVISOR_HOST}"; fi
_lab_add "vCenter"   "$(_lab_plain "$_vc_ep")"  "$(_lab_plain "${VCENTER_USERNAME:-}")" "$(_lab_secret "${VCENTER_PASSWORD:-}")"
# VKS / SSO's password cell is the ONE lab row that does not use _lab_secret, because a bare
# `<not set>` here is FALSE-BY-CONTRAST: the rows above and below show a value for the SAME account
# (administrator@vsphere.local), so the operator reads "you are missing something" when they are not.
# MEASURED on a live 9.1 lab: VKS_USERNAME == VCENTER_USERNAME, VCENTER_PASSWORD set,
# VCF_CLI_VSPHERE_PASSWORD set, VKS_PASSWORD unset — and unset is CORRECT, because .env.example:1761
# documents VKS_PASSWORD as "vsphere method only" and every reader confirms it (02-env.sh:245,
# 30-vks-login.sh:486-488, and the vsphere arm of _vks_login_requires below). This is creds.sh:318's
# own doctrine — AN UNSET PASSWORD IS NOT AUTOMATICALLY "YOU MUST SET IT" — which the services table
# already applies via _unset_pw() and the lab rows never got.
#
# ⚠️ TWO REFUTED FIXES, recorded so they are not rebuilt (idea round, 2026-09-05):
#  1. "show VCF_CLI_VSPHERE_PASSWORD here instead" — WRONG SECRET UNDER THE WRONG LABEL.
#     .env.example:1591 says the two keys are the same value "on a STANDARD lab", which is permission
#     to differ, not identity; and the vcf CLI row one line below ALREADY shows it. An operator whose
#     keys differ would take that value to `kubectl vsphere login` and spend one of THREE attempts
#     before PERMANENT SSO lockout. Under a pipe both cells render `<hidden…>`, so the wrong-secret
#     render is invisible in exactly the walk logs that would catch it.
#  2. "render `<not needed: VKS_AUTH_METHOD=…>`" — has FOUR states, and the fourth is the SHIPPED
#     DEFAULT: .env.example:1192 ships VKS_AUTH_METHOD COMMENTED, and creds.sh reads it as
#     `${VKS_AUTH_METHOD:-}` (not the `:-kubeconfig` that 02-env.sh/30-vks-login.sh apply), so the
#     commonest configuration renders `<not needed: VKS_AUTH_METHOD=>`. It is also a claim about the
#     OPERATOR'S OBLIGATION, which docs/matrix-standing-rules.md:469 requires to be TRUE of the
#     cluster at that moment — and it is false under the vsphere method.
# So the marker states what is unconditionally true of the VARIABLE. Whether it BLOCKS you now is
# answered where it belongs: _vks_login_requires' vsphere arm already names VKS_PASSWORD as a blocker.
_lab_add "VKS / SSO" "$(_lab_plain "$_sup_ep")" "$(_lab_plain "${VKS_USERNAME:-}")"     "$(if [ -n "${VKS_PASSWORD:-}" ]; then _mask "$VKS_PASSWORD"; else printf '<not set — vsphere method only>'; fi)"
_lab_add "vcf CLI"   "(the VKS / SSO account)"  "$(_lab_plain "${VKS_USERNAME:-}")"     "$(_lab_secret "${VCF_CLI_VSPHERE_PASSWORD:-}")"

# ── guest-node SSH — READ LIVE, because the END USER CAN READ IT ────────────────────────────────
# The operator asked whether knowing the vCenter/SSO credentials yields ssh access. MEASURED
# 2026-08-20 against the live lab: YES. The Supervisor's vSphere Namespace carries
#     <cluster>-ssh                 -> ssh-privatekey
#     <cluster>-ssh-password        -> ssh-passwordkey   (44 bytes, decoded rc=0)
# and an `sso:Administrator@vsphere.local` kubeconfig reads them. So by the standing rule — if the
# end user can obtain it, this report shows it — it belongs here.
#
# ⚠️ MY FIRST MEASUREMENT SAID "0 ssh secrets" AND WAS THE INSTRUMENT FAILING. `get secret -A`
# is Forbidden to SSO admin on a Supervisor (cluster-wide list), and the grep swallowed the rc, so a
# permission error read as an empty result. Scope to the NAMESPACE; check rc, not the match count.
#
# ⚠️ DISCOVER the secret, never construct it from VKS_CLUSTER_NAME. MEASURED: `.env` said
# `cicd-gc1` while the live secrets were `cicd-gc0819222721-ssh-password`. Same class as the
# `harbor-core-ver-1` trap — a name that looks derivable and is not.
#
# No SSO bind happens here: `supervisor_kubeconfig` only RESOLVES an existing file and never
# refreshes a token. Keep it that way (see the prohibition above).
# ⚠️ CORRECTED 2026-08-20 (B202 F7). The comment above said "check rc, not the match count" and the
# FIRST version of this block did the opposite: `_lab_err` was written at two sites and NEVER READ,
# the rc was discarded by `|| true`, and the branch tested `[ -n "$_ssh_sec" ]` — the match count.
# So Forbidden, an expired Supervisor token and an unreachable API ALL rendered `<not readable>`,
# indistinguishable from "this cluster has no such secret". That is the same "I could not ask" vs
# "the answer is no" conflation this repo already fixed twice (harbor_auth_verdict's three outcomes,
# classify_kube_failure's eight classes) — and it failed in the REASSURING direction, in the file
# RULE ZERO-B makes the end user's only credentials surface.
#
# The LISTING MUST NOT BE A PIPELINE. `kubectl ... | sed | grep | head` yields HEAD's status, so the
# rc is meaningless before it is even discarded. Capture kubectl alone, read its rc, then filter.
# _ssh_pick <newline-separated-candidates> <cluster-name> — echo the chosen secret name, or
# NOTHING when the choice is not determinable. PURE: no kubectl, no globals, no side effects, so
# scripts/test-creds-ssh-pick.sh can exercise every branch OFFLINE.
#
# WHY IT IS A FUNCTION (adversary HIGH, 2026-09-05): the gate sets CREDS_NO_PROBE=1 for every
# rendered case, and this whole block short-circuits on that flag — so the gate could not execute
# ONE line of the selection logic and its green was evidence about a subset that EXCLUDED the
# change. Extracting the choice is what makes it testable at all.
#
# ORDER, and each arm earns its place:
#   1. EXACT `${cluster}-ssh-password` if present  — the only answer that is certainly right.
#   2. the SOLE candidate                          — preserves single-cluster behaviour, and the
#      recorded lab where .env said cicd-gc1 while the live secret was cicd-gc0819222721-ssh-password
#      (which is why the list is DISCOVERED and never constructed from the name).
#   3. otherwise NOTHING                           — >=2 candidates and no match is not determinable;
#      the caller refuses. A wrong password is worse than "I could not tell".
# grep -Fx: FIXED-string, WHOLE-line. A name carrying a regex metachar must not alternate into a
# sibling entry (rules/shell: interpolating a derived value into a regex).
_ssh_pick() {
  local _list="$1" _cl="$2" _hit="" _n
  if [ -n "$_cl" ]; then
    _hit="$(printf '%s\n' "$_list" | grep -Fx -- "${_cl}-ssh-password" || true)"
  fi
  if [ -n "$_hit" ]; then printf '%s' "$_hit"; return 0; fi
  _n="$(printf '%s' "$_list" | grep -c . || true)"
  # sed, not tr — this is the sole-candidate secret NAME; empty silently disables the path.
  if [ "${_n:-0}" -eq 1 ]; then printf '%s' "$(printf '%s' "$_list" | sed '/^$/d' | head -1)"; fi
  return 0
}

_ssh_pw=""; _lab_err=""; _ssh_sec=""; _ssh_state="not probed"; _ssh_tok="<not probed>"
_ssh_ep="<not probed>"   # the ENDPOINT cell: an address, or a marker naming why there is none
if [ "$_no_probe_snapshot" = "1" ]; then
  _ssh_state="not probed (CREDS_NO_PROBE=1)"; _ssh_tok="<not probed>"
elif [ -z "${VKS_NAMESPACE:-}" ]; then
  _ssh_state="not probed (VKS_NAMESPACE unset)"; _ssh_tok="<not probed>"
else
  _sup_kc="$(supervisor_kubeconfig 2>/dev/null || true)"
  if [ -z "$_sup_kc" ] || [ ! -f "$_sup_kc" ]; then
    # ⚠️ THIS MUST NOT NAME `make vks-login`, and it did until 2026-09-07 (B548). The rule is
    # already adjudicated and written out at :1116-1121 for the Harbor cell — the SIBLING of this
    # branch, fixed in f0b7d07 while THIS one was left behind. A 1-of-2 partial fix, and the half
    # that shipped carries the refutation of the half that did not.
    #
    # `absent` is UNDECIDABLE: it cannot be told apart from "scenario-1 operator who has not logged
    # in yet", and for the DEFAULT persona — a scenario-2 tenant, RULE ZERO-B — having no Supervisor
    # kubeconfig is NORMAL, not a fault. Undecidability is a property of the EVIDENCE, not of the
    # consumer: a report may say "I could not ask"; it may not attach a remedy, because THE REMEDY IS
    # WHAT ENCODES THE GUESS.
    #
    # 🔴 And this particular guess has an irreversible tail: `make vks-login` spends one of THREE
    # vCenter SSO attempts before PERMANENT lockout. Measured by a round: on a configured tenant
    # (VKS_NAMESPACE set, no Supervisor kubeconfig) this fired on EVERY `make creds`.
    #
    # ⚠️ NOT A BLANKET BAN — :1076 legitimately names it. That arm is UNAUTHORIZED: a kubeconfig that
    # EXISTS and was REJECTED. That state is DECIDABLE and re-authenticating is the right answer. The
    # distinction is decidability, not the string.
    _ssh_state="no Supervisor kubeconfig here — the node password lives on the Supervisor, so ask your platform team for it"
    # `_first_unmet` describes what `make vks-login` would stop on. Keep it ONLY for an operator who
    # has already declared they intend to run it by choosing a method; on the default it would
    # smuggle the same prescription back in through a subordinate clause.
    _um_ssh="$(_first_unmet || true)"
    [ -z "$_um_ssh" ] || [ -z "${VKS_AUTH_METHOD:-}" ] \
      || _ssh_state="${_ssh_state} (and if you DO own this lab: make vks-login needs ${_um_ssh}, not set)"
    _ssh_tok="<no kubeconfig>"
  else
    _lab_err="$(mktemp)"
    # `&& rc=0 || rc=$?` and NOT `; rc=$?` — the latter dies under `set -e` (rules/shell).
    _ssh_list="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                   -n "$VKS_NAMESPACE" get secret -o name </dev/null 2>"$_lab_err")" && _ssh_rc=0 || _ssh_rc=$?
    if [ "$_ssh_rc" -ne 0 ]; then
      # THE WHOLE POINT: name WHY we could not ask, so it is never mistaken for "there is none".
      _kube_classify "$_lab_err" "could not ask" "$_ssh_rc"; _ssh_tok="$_kube_tok"; _ssh_state="$_kube_state"
    else
      # SCOPE TO THIS CLUSTER (B-scope). MEASURED 2026-09-05: with cicd-gc1 and cicd-gc2 both in
      # namespace 'cicd', the old `| head -1` picked cicd-gc1's secret ALPHABETICALLY and the report
      # printed a DELETED cluster's SSH password as if it were live. `head -1` over a multi-cluster
      # namespace is a silent wrong answer, not a missing one.
      # The comment above still stands — do NOT CONSTRUCT the name (a lab had
      # `cicd-gc0819222721-ssh-password` while .env said cicd-gc1) — so this DISCOVERS the list
      # first and only then PREFERS the entry matching this cluster. Order: exact match -> the one
      # and only candidate -> REFUSE (naming what it saw), never an arbitrary pick.
      _ssh_cands="$(printf '%s' "$_ssh_list" | sed 's|^secret/||' | grep -E -- '-ssh-password$' || true)"
      # COUNT with grep -c, not a `for` over an unquoted var: measured, `for x in $C` counts 2 under
      # bash and 1 under zsh on the same newline-separated capture, and the unquoted expansion is
      # also subject to pathname expansion. grep -c is shell-independent and cannot glob.
      _ssh_nc="$(printf '%s' "$_ssh_cands" | grep -c . || true)"; _ssh_nc="${_ssh_nc:-0}"
      _ssh_sec="$(_ssh_pick "$_ssh_cands" "${VKS_CLUSTER_NAME:-}")"
      if [ -z "$_ssh_sec" ] && [ "$_ssh_nc" -gt 1 ]; then
        _ssh_tok="<ambiguous>"
        _ssh_state="$(printf '%s candidates in %s and none is %s-ssh-password: %s— set VKS_CLUSTER_NAME in .env to one of these' \
                        "$_ssh_nc" "${VKS_NAMESPACE}" "${VKS_CLUSTER_NAME:-<unset>}" \
                        "$(printf '%s' "$_ssh_cands" | tr_free_join)")"
      fi
      # GUARD ON "WE HAVE A NAME", NOT ON THE COUNT (adversary CRITICAL, 2026-09-05).
      # It read `[ -z "$_ssh_sec" ] && [ "$_ssh_nc" -eq 0 ]`, so the AMBIGUOUS case (>=2 candidates,
      # none matching) fell through to the else and ran `kubectl get secret ""` with an EMPTY name.
      # That fails, and _kube_classify then OVERWRITES the `<ambiguous>` refusal with
      # `<kubectl failed>` — so the refusal this whole block exists to produce was UNREACHABLE, in
      # exactly the two-cluster namespace it was written for, and it wasted a Supervisor request.
      if [ -z "$_ssh_sec" ]; then
        if [ "$_ssh_nc" -eq 0 ]; then
          _ssh_tok="<none>"; _ssh_state="none in '${VKS_NAMESPACE}' — this cluster publishes no node-SSH secret"
        fi
        # >=2 candidates: _ssh_tok/_ssh_state were set to the <ambiguous> refusal above. Do NOT
        # read, and do NOT overwrite them.
      else
        # stderr to a FILE, never 2>&1: a server `Warning:` header concatenates in front of the
        # base64 on a SUCCESSFUL read and base64 -d then emits partial garbage (lib/argocd.sh:327).
        _ssh_b64="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                      -n "$VKS_NAMESPACE" get secret "$_ssh_sec" \
                      -o jsonpath='{.data.ssh-passwordkey}' </dev/null 2>>"$_lab_err")" && _ssh_rc=0 || _ssh_rc=$?
        # purity-check before decoding, or a partial decode ships a WRONG password.
        case "$_ssh_b64" in ''|*[!A-Za-z0-9+/=]*) _ssh_b64="" ;; esac
        if [ "$_ssh_rc" -ne 0 ]; then
          _kube_classify "$_lab_err" "could not read ${_ssh_sec}" "$_ssh_rc"; _ssh_tok="$_kube_tok"; _ssh_state="$_kube_state"
        elif [ -z "$_ssh_b64" ]; then
          _ssh_tok="<no key>"; _ssh_state="${_ssh_sec} carries no usable ssh-passwordkey"
        else
          _ssh_pw="$(printf '%s' "$_ssh_b64" | base64 -d 2>/dev/null || true)"
          if [ -z "$_ssh_pw" ]; then _ssh_tok="<empty>"; _ssh_state="${_ssh_sec} decoded empty"; fi
        fi
      fi
    fi

    # ---- node ADDRESS: what the Endpoint column is supposed to contain ---------------------
    # THE ENDPOINT COLUMN MAY NEVER CARRY A LOOKUP KEY. This row used to render $_ssh_sec -- a
    # SECRET NAME -- under a header reading `Endpoint` (verified: header at the `_lab_add` widths
    # block below), so the report invited `ssh vmware-system-user@cicd-gc1-ssh-password`, which
    # cannot resolve to anything. The secret name is PROVENANCE and already appears in the note
    # under the table; it does not belong in a column that promises an address.
    # NOTE THE RULE IS "NO LOOKUP KEY", NOT "ONLY AN ADDRESS": the sibling `vcf CLI` row correctly
    # renders `(the VKS / SSO account)` because a local binary has no endpoint at all.
    # WE DO NOT CLAIM ROUTABILITY. Whether a jump box can reach the node network is UNVERIFIED
    # here, and asserting reachability we have not measured is exactly how this report earned the
    # complaint that started this work. We print what the cluster says, and nothing more.
    _ssh_verr="$(mktemp)"
    # SCOPE TO THIS CLUSTER. MEASURED 2026-09-05: an unfiltered `get vm` over a namespace holding
    # TWO clusters returned the DELETED cluster's node first (.38, while this cluster's nodes are
    # .45/.46/.43), so the report handed the operator an address that answers for the wrong cluster
    # -- or for nothing at all. CAPI labels every node VM `cluster.x-k8s.io/cluster-name`; measured
    # on this lab, the selector returns exactly this cluster's 3 nodes.
    # FALL BACK, never fail: an older//different platform may not carry the label, and a report that
    # prints nothing is worse than one that prints an unscoped address AND SAYS SO.
    _ssh_scoped=1
    _ssh_addr="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                   -n "$VKS_NAMESPACE" get vm -l "cluster.x-k8s.io/cluster-name=${VKS_CLUSTER_NAME:-}" \
                   -o jsonpath='{range .items[*]}{.status.network.primaryIP4}{" "}{end}' \
                   </dev/null 2>"$_ssh_verr")" && _ssh_vrc=0 || _ssh_vrc=$?
    # sed, not tr: bare photon:5.0 has NO tr, and on such a box this substitution would be empty,
    # making the emptiness test ALWAYS true — a silent wrong branch. (MEASURED: photon:5.0 ships
    # base64/date/sed/head/cut and no tr; the script that would install it is internet-side only.)
    if [ "${_ssh_vrc:-1}" -eq 0 ] && [ -z "$(printf '%s' "${_ssh_addr:-}" | sed 's/[[:space:]]//g')" ]; then
      _ssh_scoped=0
      _ssh_addr="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                     -n "$VKS_NAMESPACE" get vm \
                     -o jsonpath='{range .items[*]}{.status.network.primaryIP4}{" "}{end}' \
                     </dev/null 2>"$_ssh_verr")" && _ssh_vrc=0 || _ssh_vrc=$?
    fi
    # squeeze the jsonpath separators; an item with no primaryIP4 contributes an empty field.
    # sed, not tr — same reason. WORSE here: this is a bare assignment from a pipeline under
    # `set -euo pipefail`, so a missing tr does not merely blank it, it KILLS the script; and if it
    # did not, the cell would read "<no node address yet>" for a cluster that just returned three.
    _ssh_addr="$(printf '%s' "${_ssh_addr:-}" | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//')"
    # ⚠️ ONE address in the cell, the rest in the note. MY OWN BUG, caught by an adversary: the
    # jsonpath collects EVERY node's primaryIP4 space-separated, so a 3-node guest cluster puts
    # ~44 chars into a column whose width is a max over all rows -- re-creating the width defect
    # fixed in the same session. It is also not pasteable into ssh.
    _ssh_n=0; for _a in ${_ssh_addr:-}; do _ssh_n=$((_ssh_n + 1)); done
    _ssh_first="${_ssh_addr%% *}"
    if [ "${_ssh_vrc:-1}" -ne 0 ]; then
      # An absence is a claim about the QUERY first. A tenant may simply not be allowed to list VMs.
      if grep -qi 'forbidden' "$_ssh_verr" 2>/dev/null; then _ssh_ep="<not allowed to read addresses>"
      else                                                   _ssh_ep="<could not read node addresses>"; fi
    elif [ -z "$_ssh_addr" ]; then
      _ssh_ep="<no node address yet>"
    elif [ "$_ssh_n" -gt 1 ]; then
      if [ "${_ssh_scoped:-1}" = 1 ]; then
        _ssh_ep="${_ssh_first} (+$((_ssh_n - 1)) more — see note)"
      else
        _ssh_ep="${_ssh_first} (+$((_ssh_n - 1)) more; NOT cluster-scoped)"
      fi
    else
      _ssh_ep="$_ssh_first"
    fi
    rm -f "$_ssh_verr"
  fi
fi
# `vmware-system-user` — VERIFIED 2026-08-20 on VKS GUEST NODES, and scoped to that claim: `ssh -i <ssh-privatekey from the
# <cluster>-ssh secret> vmware-system-user@<node>` returned `id -un` = vmware-system-user and the
# node's own hostname. The `?` this row shipped with earlier that day is removed on that evidence.
# ⚠️ SHORT TOKEN IN THE COLUMN; THE SENTENCE GOES UNDER THE TABLE (impl round, MED).
# `_ssh_state` used to render into the ENDPOINT column, whose width is a max over all rows —
# MEASURED: the FORBIDDEN arm took that column to 110 chars and the line to ~170, wrapping ALL FOUR
# rows on an 80/120-col terminal. FORBIDDEN is the TENANT case: the reader least able to fix it and
# most in need of a legible table.
# The Password cell separates NOT ATTEMPTED from ATTEMPTED-AND-FAILED — on a `not probed` arm
# nothing was tried, so "not readable" would imply a failed read that never happened, which is the
# very conflation this block exists to fix.
if [ -n "$_ssh_pw" ]; then
  _lab_add "guest node SSH" "$(_lab_plain "$_ssh_ep")" "vmware-system-user" "$(_lab_secret "$_ssh_pw")"
else
  # `_ssh_tok` IS the classification, and it is finer than the two buckets this used to carry:
  # <forbidden> / <auth failed> / <stale CA> / <no kubeconfig> / <none> / <no key> / <empty>, versus
  # a flat <not readable>. It lived in the ENDPOINT column until 2026-09-05, which was the wrong
  # home -- "why the password is missing" is a fact about the PASSWORD, not an address. Moving it
  # here preserves every distinction AND keeps the NOT-ATTEMPTED vs ATTEMPTED-AND-FAILED split the
  # previous form existed to make: every not-probed arm already sets _ssh_tok="<not probed>", so
  # nothing here implies a read that never happened. Without this move _ssh_tok would be assigned
  # on eight paths and read on none.
  _ssh_pwcell="$_ssh_tok"
  _lab_add "guest node SSH" "$_ssh_ep" "vmware-system-user" "$_ssh_pwcell"
fi

# Widths, mirroring the table above. `if/then/fi` and NOT `[ ] && x` — a false test as the loop
# body's last command returns non-zero and trips `set -e` (rules/shell: the `A && B` tail trap).
_lw1=6; _lw2=8; _lw3=8
while IFS=$'\t' read -r c1 c2 c3 c4; do
  if [ -z "$c1" ]; then continue; fi
  if [ ${#c1} -gt "$_lw1" ]; then _lw1=${#c1}; fi
  if [ ${#c2} -gt "$_lw2" ]; then _lw2=${#c2}; fi
  if [ ${#c3} -gt "$_lw3" ]; then _lw3=${#c3}; fi
done <<EOF
$_lab_rows
EOF

# ⚠️ THE HEADER IS A CLAIM, AND IT WAS FALSE FOR THE READER WHO DID EVERYTHING RIGHT (B536).
# It read "the values you put in .env". On a scenario-2 TENANT render the vCenter row is three
# blanks — because `docs/scenario-2.md` never asks for those values (measured: 13 VCENTER_* mentions
# in scenario-1, ZERO in scenario-2). So the header asserted an action the reader had not taken,
# above a row they were never supposed to fill, and a reader who had done everything right would
# conclude they had missed something and go hunting. RULE ZERO-V tell (3): they would DO something
# different.
# ⚠️ `Lab access` MUST REMAIN THE LEADING TOKEN. `test-creds-show.sh:191` splits the report with
# `sed '/Lab access/,$d'`, and with no match sed deletes NOTHING — `out_services` silently becomes
# the whole report and every services assertion starts scanning the lab rows. That failure is
# QUIET; the three sibling `grep -q 'Lab access'` assertions are loud. It is also a live Expect
# literal in scenario-1.md:1100,:1101 and scenario-2.md:812. The TAIL is free — measured, the
# phrase "the values you put in .env" appears nowhere else in the repo.
# ⚠️ THE ABSOLUTE IS SCOPED TO `<not set>` ON PURPOSE. A first draft said "a blank is ... never a
# statement about the lab", which the FOURTH ROW OF THIS TABLE contradicts: `_kube_classify` renders
# `<auth failed>` ("the Supervisor REJECTED this kubeconfig"), `<forbidden>`, `<none>` ("this cluster
# publishes no node-SSH secret"), `<unreachable>` and `<stale CA>` — every one of them a statement
# about the lab, and scenario-1.md:1102 documents that intent ("never a blank that would read as
# this cluster has none"). A reader applying the absolute would discount an actionable lab fact.
printf '\n  Lab access — from your .env. A <not set> means THIS REPORT does not have the value;\n'
printf '                it does not mean the lab lacks one. The guest node SSH row is read live.\n'
printf '\n  %-*s  %-*s  %-*s  %s\n' "$_lw1" "Target" "$_lw2" "Endpoint" "$_lw3" "Username" "Password"
printf '  %-*s  %-*s  %-*s  %s\n' \
  "$_lw1" "$(printf '%*s' "$_lw1" '' | tr ' ' '-')" \
  "$_lw2" "$(printf '%*s' "$_lw2" '' | tr ' ' '-')" \
  "$_lw3" "$(printf '%*s' "$_lw3" '' | tr ' ' '-')" \
  "$(printf '%*s' 8 '' | tr ' ' '-')"
while IFS=$'\t' read -r c1 c2 c3 c4; do
  if [ -z "$c1" ]; then continue; fi
  printf '  %-*s  %-*s  %-*s  %s\n' "$_lw1" "$c1" "$_lw2" "$c2" "$_lw3" "$c3" "$c4"
done <<EOF
$_lab_rows
EOF

# ── the note the SSH row's "see note" marker CITES ────────────────────────────────────────────
# MEASURED 2026-09-08 on the live lab: the row rendered `192.168.101.63 (+2 more — see note)` and
# NOTHING in the 55-line output explained it — a citation resolving to nothing, which line 1461
# already calls "worse than no marker at all, because it reads as sourced". The existing emitter at
# ~1448 scans `$rows` (the SERVICES table) and is structurally blind to this one, which lives in
# `$_lab_rows`. Gated on the marker being PRESENT so cell and note cannot drift apart.
# ⚠️ KEYED ON THE FLAGS, NOT ON THE RENDERED STRING. creds.sh:1503-1507 records the measured
# incident: rewording a marker silently stopped matching it and the cell cited a note that no
# longer printed. Display text is not a control channel. `_ssh_n` is the same variable the cell
# branches on (verified in scope: plain if/fi, no subshell), so cell and note cannot drift — and
# this form also covers the `NOT cluster-scoped` arm, which carries no marker and so could never
# have matched a text key at all.
if [ "${_ssh_vrc:-1}" -eq 0 ] && [ "${_ssh_n:-0}" -gt 1 ]; then
  # ⚠️ THE CLAIM IS SCOPED. The password comes from ONE per-cluster secret, so "same for every
  # node" holds only where the addresses were filtered to THIS cluster. In the un-scoped arm the
  # list can span clusters, and those nodes take a DIFFERENT secret — asserting one password for
  # them would be a false sentence about someone else's cluster (RULE ZERO-V).
  if [ "${_ssh_scoped:-1}" = 1 ]; then
    printf '\n  note: every node of this cluster takes the SAME user and password; the row shows the first.\n'
  else
    printf '\n  note: these addresses are NOT filtered to this cluster, so some may belong to another\n'
    printf '        one — and a node of another cluster takes that cluster'"'"'s password, not this row'"'"'s.\n'
  fi
  if [ -n "${_ssh_addr:-}" ]; then
    printf '        All node addresses: %s\n' "$_ssh_addr"
  fi
fi

# ⚠️ SCOPED TO THE vCenter ROW, AND STATED ABOUT THE DOCUMENTS — NOT THE READER (B536).
# A whole-table condition would re-import the three-meanings problem this note exists to remove:
# on a doc-following tenant render the ONLY bare tokens left are these three, and they carry ONE
# meaning. MEASURED: nothing-set fixture = 7 bare tokens (the CI/e2e state, not a person);
# a tenant who supplies what scenario-2 ASKS FOR (VKS_USERNAME, SUPERVISOR_HOST,
# VCF_CLI_VSPHERE_PASSWORD) = 3, all on this row.
#
# ⚠️ IT MUST NOT SAY "you are a tenant" OR "you are not expected to have these". That is a claim
# about WHO THE READER IS and what they possess, which this report cannot know — a colleague of the
# VI admin may well hold vCenter credentials. `creds.sh` already legislates this for the flow line
# ("IT MUST NOT CLAIM WHAT IS INSTALLED — it cannot know"). So the note states a fact about two
# FILES, hands the reader the discriminator, and lets them place themselves.
# The fact is CHECKABLE and GATED: `check-vcenter-scenario-split` asserts scenario-1 mentions
# VCENTER_* and scenario-2 does not, so this note goes RED the day it stops being true.
# ⚠️ TEST THE THREE SOURCE VARS, NOT THE RENDERED BLOB. The first version was
#     case "$_lab_rows" in *"vCenter"*"<not set>"*)
# and its comment claimed it was "scoped to the vCenter row". IT WAS NOT: `_lab_rows` is a
# MULTI-ROW blob and a glob spans newlines, so `*"vCenter"*` matched row 1 and `*"<not set>"*`
# matched ANY LATER ROW. MEASURED — the note printed "The vCenter row is blank" directly beneath a
# FULLY POPULATED vCenter row on 3 of 3 reachable triggers (VCF_CLI_VSPHERE_PASSWORD, SUPERVISOR_HOST
# or VKS_USERNAME unset). The worst is SUPERVISOR_HOST: `.env.example` stages VCENTER_* "before Step
# 1b" and scenario-1 Step 0 collects the vCenter FQDN explicitly "NOT the Supervisor IP", so
# "vCenter filled, Supervisor not yet" is the DOCUMENTED INTERMEDIATE STATE of scenario-1 — and the
# note told that reader "you have not set them yet" about values they had just typed. That is this
# change's own defect, restored one screen lower and contradicted by the table directly above it.
# ⚠️ My admin fixture had NO other bare token, so it could not discriminate — a control that cannot
# fail in the direction you are testing is not a control.
if [ -z "${VCENTER_HOST:-}" ] && [ -z "${VCENTER_USERNAME:-}" ] && [ -z "${VCENTER_PASSWORD:-}" ]; then
    printf '\n  The vCenter row is blank. That is expected on the scenario-2 walk: docs/scenario-2.md\n'
    printf '     never asks for VCENTER_HOST / VCENTER_USERNAME / VCENTER_PASSWORD, while\n'
    printf '     docs/scenario-1.md does. If you are following scenario-1 and it is blank, you have\n'
    printf '     not set them yet.\n'
fi

printf '\n  ⚠️ vCenter SSO locks the account PERMANENTLY after 3 failed attempts. This report SHOWS these\n'
printf '     values and NEVER authenticates with them, so a wrong one is not spent here. If one is\n'
printf '     rejected, STOP and confirm it with whoever owns the lab — do not retry.\n'
# ⚠️ NOT DERIVED, and it no longer pretends to be (impl round, MED). The previous version looped over
# a HARDCODED 7-element literal counting its own elements — MEASURED: injecting an 8th row still
# printed 7. It tracked neither the rows, nor .env.example, nor the scenario docs, and reading as
# "derived" made it WORSE than the literal it replaced. NAMING the variables is the honest form: the
# list IS the claim, so it cannot go stale silently.
_um="$(_first_unmet || true)"
if [ -n "$_um" ]; then
  printf '\n  \u26a0\ufe0f  make vks-login (VKS_AUTH_METHOD=%s) checks its requirements in order and the first\n' "${VKS_AUTH_METHOD:-<unset>}"
  printf '     one not satisfied is %s — not set in .env or in this environment.\n' "$_um"
  printf '     %s. Set it before any step that needs a kubeconfig.\n' "$(_unmet_why "$_um")"
fi
# ⚠️ CONDITIONAL, and that is the whole point (impl round, MED). These sentences printed
# UNCONDITIONALLY, so a run that read NOTHING still claimed "READ LIVE from the Supervisor" and
# asserted `Source: <none found>` — an absence about a namespace we may never have been able to
# query. The exact conflation the probe rewrite above exists to fix, re-committed two lines below it.
if [ -z "$_ssh_pw" ]; then
  printf '  Guest-node SSH password NOT read: %s\n' "$_ssh_state"
fi

echo
