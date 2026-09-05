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
trap 'rm -f "${_argo_err:-}" "${_lab_err:-}" 2>/dev/null || true' EXIT

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

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
  else printf '<hidden: not a terminal — re-run with SHOW_SECRETS=1>'; fi
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
  harbor_url="${harbor_url} (self-signed; --insecure)"
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
  timeout 2 bash -c "exec 3<>/dev/tcp/${_ing}/${INGRESS_PROBE_PORT:-80}" 2>/dev/null || _ing_live=0
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
if [ "${CREDS_NO_PROBE:-0}" = 1 ]; then
  printf '  (CREDS_NO_PROBE=1 — reporting configuration only, nothing probed)\n' >&2
else
  printf '  checking what is reachable — up to %ss per endpoint, %ss per cluster call; a few seconds total.\n' \
    "${CREDS_PROBE_TIMEOUT_SECONDS:-2}" "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" >&2
  printf '  (set CREDS_NO_PROBE=1 to skip every probe and report configuration only)\n' >&2
fi
_probe_t0=$(date +%s 2>/dev/null || echo 0)

if [ -n "${ARGOCD_SERVER:-}" ]; then
  # A REAL LAB. ARGOCD_LB_IP is published only by the KinD flow (07-install-argocd.sh), so on a lab
  # this used to print the literal '<your lab's ArgoCD URL>' — while the operator had ALREADY told us
  # the address in ARGOCD_SERVER (both scenario runbooks have them discover and set it, and every
  # argocd-CLI call uses it). We were asking them to look up a value we were holding.
  case "$ARGOCD_SERVER" in
    http://*|https://*) argocd_url="$ARGOCD_SERVER" ;;
    *)                  argocd_url="${argo_scheme}://${ARGOCD_SERVER}" ;;
  esac
elif [ -n "${ARGOCD_LB_IP:-}" ]; then
  # KinD publishes this (07-install-argocd.sh). It is a DEFAULT — it applies only when the
  # operator has not said otherwise.
  argocd_url="${argo_scheme}://${ARGOCD_LB_IP} (self-signed; --insecure)"
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
      _argo_ip="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" env KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}" kubectl --request-timeout=3s </dev/null -n "$_argo_ns" \
          get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    fi
  fi
  if [ -n "$_argo_ip" ]; then
    argocd_url="${argo_scheme}://${_argo_ip} (discovered from the cluster)"
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
_unset_pw() {  # _unset_pw <VAR> -> what an unset password actually means, per flow
  # ⚠️ "check the state overlay" IS THE FOURTH FALSE CLAIM, and the most dangerous of them: under a
  # REFUSAL the password WAS published -- for another cluster -- so this sent the operator to read a
  # foreign credential out of the very file the Context block four lines above has just said is not
  # in play. Reachable in B517's own scenario: on a KinD box 05-kind-up.sh GENERATES these into the
  # overlay (.env.example leaves them commented), so an operator who ran KinD and then pointed at a
  # lab lands here.
  if [ "$_sink_refused" = 1 ]; then printf '<held by the REFUSED overlay — it is another cluster'"'"'s; do NOT use it>'
  elif [ "$_have_sink" = 1 ]; then printf '<not published — check the state overlay>'
  else printf '<generated at install (KinD) — or set %s in .env for a real lab>' "$1"; fi
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
argo_pw="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" "${SCRIPT_DIR}/argocd-password.sh" --wait 0 --raw 2>"$_argo_err")" || _argo_rc=$?
_argo_initial=0
grep -q 'INITIAL admin password' "$_argo_err" 2>/dev/null && _argo_initial=1
rm -f "$_argo_err"
if [ "$_argo_rc" = 0 ]; then
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
  [ "$_have_sink" = 1 ] && argo_pw="<not read — run: make argocd-password (it waits)>"
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
  _flow="KinD stand-in (the state overlay is stamped by the KinD flow)"
elif [ "$_have_sink" = 1 ]; then
  _flow="real lab (a state overlay exists and is NOT KinD-stamped)"
elif [ "${VKS_AUTH_METHOD:-}" = "vcf" ]; then
  _flow="real VKS lab (VKS_AUTH_METHOD=vcf)"
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
if [ -n "${KUBECONFIG:-}" ] && have kubectl \
   && kubectl --request-timeout=3s version -o json >/dev/null 2>&1 </dev/null; then
  _cluster="reachable — context '$(kubectl config current-context </dev/null 2>/dev/null || echo '?')'"
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
_stamp="$(grep -m1 '^VKS_STATE_SERVER=' "$_sink" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
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
  DISCOVERED) printf '    values below : DISCOVERED — the overlay is stamped for the cluster you are talking to\n' ;;
  STORED)     printf '    values below : STORED — read from a state overlay that is NOT confirmed to belong to\n'
              printf '                   this cluster. An overlay SURVIVES A REBUILD, so a password or an IP\n'
              printf '                   here may be from a lab that no longer exists. Run: make state-stamp\n'
              printf '                   after an install to make it self-identifying; re-run any value that\n'
              printf '                   is rejected rather than assuming it is wrong.\n'
              _settle_note '                   ' ;;
  *)          if [ "$_env_populated" = 1 ]; then
                printf '    values below : from YOUR .env — no installer has published anything, so these are the\n'
                printf '                   values you supplied, not placeholders. .env carries NO cluster stamp, so\n'
                printf '                   this report cannot confirm they belong to the cluster you are talking to;\n'
                printf '                   a value left over from a destroyed lab looks identical to one you just\n'
                printf '                   typed. Treat every credential here as LIVE until you know\n'
                printf '                   otherwise; re-run any value that is rejected rather than assuming it is wrong.\n'
                _settle_note '                   '
              else
                printf '    values below : DEFAULTS from .env / .env.example — these ARE PLACEHOLDERS, not credentials\n'
              fi ;;
esac
if [ "$_sink_refused" = 1 ]; then
  printf '    state overlay: %s — REFUSED\n' "$_sink"
  printf '                   It is stamped for a DIFFERENT cluster, so none of its LB IPs, CA paths\n'
  printf '                   or passwords are in play here. Anything an installer published is\n'
  printf '                   therefore MISSING from this report, which is NOT the same as absent\n'
  printf '                   from the cluster. The ERROR block above names which cluster it belongs\n'
  printf '                   to; inspect it with: make state-show\n'
else
  printf '    state overlay: %s\n' \
    "$([ "$_have_sink" = 1 ] && echo "$_sink" || echo "none — no installer has published anything")"
fi
printf '    flow         : %s\n' "$_flow"
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
  echo "    ${INGRESS_LB_IP}  ${GITEA_HOST:-gitea.vks.local} ${TEKTON_DASHBOARD_HOST:-tekton.vks.local} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
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
_reach_ingress() {
  [ "${CREDS_NO_PROBE:-0}" = 1 ] && { printf 'not probed'; return; }
  [ -n "${_ing:-}" ] || { printf 'no ingress';  return; }
  [ "${_ing_live:-0}" = 1 ] && printf 'serving' || printf 'silent'
}
_reach_harbor() {
  [ "${CREDS_NO_PROBE:-0}" = 1 ] && { printf 'not probed'; return; }
  [ -n "${HARBOR_URL:-}" ] || { printf 'not set'; return; }
  HARBOR_PROBE_TIMEOUT_SECONDS="${CREDS_PROBE_TIMEOUT_SECONDS:-2}" harbor_reachable_state 2>/dev/null || printf 'unknown'
}
_reach_argocd() {
  [ "${CREDS_NO_PROBE:-0}" = 1 ] && { printf 'not probed'; return; }
  local _h="${ARGOCD_SERVER:-}"; [ -n "$_h" ] || { printf 'not set'; return; }
  _h="${_h#https://}"; _h="${_h#http://}"; _h="${_h%%/*}"
  local _port="${_h##*:}"; case "$_h" in *:*) : ;; *) _port=443 ;; esac
  _h="${_h%%:*}"
  getent hosts "$_h" >/dev/null 2>&1 || case "$_h" in
    *[!0-9.]*) printf 'unresolved'; return ;;      # a NAME that does not resolve
  esac
  _probe_tcp "$_h" "$_port" && printf 'serving' || printf 'silent'
}
add_row() { rows="${rows}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\t'"${5:--}"$'\n'; }


# Ordered by the pipeline flow: Gitea (push) -> Tekton (build) -> Harbor (registry) -> ArgoCD (deploy) -> apps.
add_row "Gitea"  "$gitea_url"  "$gitea_user"  "$gitea_pw"  "$(_reach_ingress)"
add_row "Tekton" "$tekton_url" "-"            "(no login; read-only dashboard)" "$(_reach_ingress)"
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
add_row "Harbor" "$harbor_url" "$harbor_user" "$harbor_pw" "$(_reach_harbor)"
# Render the PROVENANCE with the value. A bare secret here reads as "this is your password",
# and on the primary runbook it is the pre-rotation one from Step 5 onward — which is the state
# that produced a live 401 and a backlog row proposing a network probe to detect it.
if [ "${_argo_initial:-0}" = 1 ] && [ -n "$argo_pw" ]; then
  argo_pw="${argo_pw}   <- INITIAL secret; superseded if you ran 'argocd account update-password'"
fi
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
  add_row "$_a" "$_url" "-" "(no login; health at ${_health})" "$(_reach_ingress)"
done <<EOF
${_apps}
EOF

# how long the probing ACTUALLY took -- printed so the estimate above stays honest. If this ever
# reads much larger than the stated bounds, a probe has escaped its timeout, and that is a defect
# the operator can see rather than one they merely endure.
if [ "${CREDS_NO_PROBE:-0}" != 1 ]; then
  _probe_t1=$(date +%s 2>/dev/null || echo 0)
  printf '  reachability checks done in %ss.\n' "$(( _probe_t1 - _probe_t0 ))" >&2
fi

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
while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
  [ -n "$c1" ] || continue
  printf '  %-*s  %-*s  %-*s  %-*s  %s\n' "$w1" "$c1" "$w2" "$c2" "$w3" "$c3" "$w4" "$c4" "$c5"
done <<EOF
$rows
EOF

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
    printf '\n  note: this box has no ingress LB IP — the state overlay that would carry one was REFUSED\n'
    printf '        (stamped for a different cluster), so the *.vks.local URLs cannot be shown. This says\n'
    printf '        NOTHING about whether the cluster HAS an ingress; this report simply cannot see one.\n'
    printf '        Reach the services without it:\n'
    printf '            kubectl -n <namespace> port-forward svc/<service> 8080:<port>\n'
    printf '        Harbor and ArgoCD are unaffected — own LBs.\n'
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
    printf '\n  note: this box has no ingress LB IP, so Gitea / Tekton / the apps have no *.vks.local\n'
    printf '        URL to show. That is a fact about THIS REPORT, not about the cluster: nothing here\n'
    printf '        has asked it whether an ingress exists. Reach the services without one:\n'
    printf '            kubectl -n <namespace> port-forward svc/<service> 8080:<port>\n'
    printf '        To find out, or to install one: make verify-ingress / make install-ingress\n'
    printf '        (Harbor and ArgoCD are unaffected — own LBs).\n'
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
# ── _ssh_classify <errfile> <prefix> — ONE mapping of a kube failure class to (token, sentence) ──
# BOTH call sites in the SSH probe go through this. The first version had two: a full case at the
# listing site and a THREE-ARM case at the read site, whose `*)` swallowed five real classes. The
# repo's own `check-classifier-consumers` gate caught it (Makefile:383) — it requires every consumer
# of classify_kube_failure to handle EVERY class, precisely because a `*)` that says "not one we
# classify" is FALSE for a class that exists and drops the remedy that class carries.
# One function = one place to be complete, and the gate has one consumer to check.
_ssh_classify() {
  local _e="$1" _p="$2"
  case "$(classify_kube_failure "$_e")" in
    FORBIDDEN)           _ssh_tok="<forbidden>";     _ssh_state="${_p} — FORBIDDEN: this identity may not read that in '${VKS_NAMESPACE:-?}'. Ask your platform admin." ;;
    UNAUTHORIZED)        _ssh_tok="<auth failed>";   _ssh_state="${_p} — the Supervisor REJECTED this kubeconfig. Re-run: make vks-login" ;;
    STALE_CA)            _ssh_tok="<stale CA>";      _ssh_state="${_p} — the Supervisor answered but its CA does not verify (kubeconfig from a destroyed lab?)" ;;
    UNREACHABLE)         _ssh_tok="<unreachable>";   _ssh_state="${_p} — the Supervisor is unreachable from here" ;;
    PLAINTEXT)           _ssh_tok="<plaintext>";     _ssh_state="${_p} — the Supervisor endpoint answered PLAINTEXT where TLS was expected" ;;
    NO_KUBE_TARGET)      _ssh_tok="<no target>";     _ssh_state="${_p} — the kubeconfig names no cluster" ;;
    KUBECONFIG_UNUSABLE) _ssh_tok="<bad kubeconfig>"; _ssh_state="${_p} — the kubeconfig is unusable (something it NAMES is missing)" ;;
    *)                   _ssh_tok="<kubectl failed>"; _ssh_state="${_p} — kubectl failed for a reason we do not classify" ;;
  esac
}

_lab_plain() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else printf '<not set>'; fi; }
_lab_secret() { if [ -n "${1:-}" ]; then _mask "$1"; else printf '<not set>'; fi; }

_vc_ep=""; if [ -n "${VCENTER_HOST:-}" ]; then _vc_ep="https://${VCENTER_HOST}"; fi
_sup_ep=""; if [ -n "${SUPERVISOR_HOST:-}" ]; then _sup_ep="https://${SUPERVISOR_HOST}"; fi
_lab_add "vCenter"   "$(_lab_plain "$_vc_ep")"  "$(_lab_plain "${VCENTER_USERNAME:-}")" "$(_lab_secret "${VCENTER_PASSWORD:-}")"
_lab_add "VKS / SSO" "$(_lab_plain "$_sup_ep")" "$(_lab_plain "${VKS_USERNAME:-}")"     "$(_lab_secret "${VKS_PASSWORD:-}")"
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
_ssh_pw=""; _lab_err=""; _ssh_sec=""; _ssh_state="not probed"; _ssh_tok="<not probed>"
if [ "$_no_probe_snapshot" = "1" ]; then
  _ssh_state="not probed (CREDS_NO_PROBE=1)"; _ssh_tok="<not probed>"
elif [ -z "${VKS_NAMESPACE:-}" ]; then
  _ssh_state="not probed (VKS_NAMESPACE unset)"; _ssh_tok="<not probed>"
else
  _sup_kc="$(supervisor_kubeconfig 2>/dev/null || true)"
  if [ -z "$_sup_kc" ] || [ ! -f "$_sup_kc" ]; then
    _ssh_state="no Supervisor kubeconfig — run: make vks-login"
    _um_ssh="$(_first_unmet || true)"
    [ -z "$_um_ssh" ] || _ssh_state="${_ssh_state} (which needs ${_um_ssh}, not set)"
    _ssh_tok="<no kubeconfig>"
  else
    _lab_err="$(mktemp)"
    # `&& rc=0 || rc=$?` and NOT `; rc=$?` — the latter dies under `set -e` (rules/shell).
    _ssh_list="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                   -n "$VKS_NAMESPACE" get secret -o name </dev/null 2>"$_lab_err")" && _ssh_rc=0 || _ssh_rc=$?
    if [ "$_ssh_rc" -ne 0 ]; then
      # THE WHOLE POINT: name WHY we could not ask, so it is never mistaken for "there is none".
      _ssh_classify "$_lab_err" "could not ask"
    else
      _ssh_sec="$(printf '%s' "$_ssh_list" | sed 's|^secret/||' | grep -E -- '-ssh-password$' | head -1 || true)"
      if [ -z "$_ssh_sec" ]; then
        _ssh_tok="<none>"; _ssh_state="none in '${VKS_NAMESPACE}' — this cluster publishes no node-SSH secret"
      else
        # stderr to a FILE, never 2>&1: a server `Warning:` header concatenates in front of the
        # base64 on a SUCCESSFUL read and base64 -d then emits partial garbage (lib/argocd.sh:327).
        _ssh_b64="$(timeout "${CREDS_KUBE_TIMEOUT_SECONDS:-3}" kubectl --request-timeout=3s --kubeconfig "$_sup_kc" \
                      -n "$VKS_NAMESPACE" get secret "$_ssh_sec" \
                      -o jsonpath='{.data.ssh-passwordkey}' </dev/null 2>>"$_lab_err")" && _ssh_rc=0 || _ssh_rc=$?
        # purity-check before decoding, or a partial decode ships a WRONG password.
        case "$_ssh_b64" in ''|*[!A-Za-z0-9+/=]*) _ssh_b64="" ;; esac
        if [ "$_ssh_rc" -ne 0 ]; then
          _ssh_classify "$_lab_err" "could not read ${_ssh_sec}"
        elif [ -z "$_ssh_b64" ]; then
          _ssh_tok="<no key>"; _ssh_state="${_ssh_sec} carries no usable ssh-passwordkey"
        else
          _ssh_pw="$(printf '%s' "$_ssh_b64" | base64 -d 2>/dev/null || true)"
          if [ -z "$_ssh_pw" ]; then _ssh_tok="<empty>"; _ssh_state="${_ssh_sec} decoded empty"; fi
        fi
      fi
    fi
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
  _lab_add "guest node SSH" "$(_lab_plain "$_ssh_sec")" "vmware-system-user" "$(_lab_secret "$_ssh_pw")"
else
  case "$_ssh_state" in
    "not probed"*) _ssh_pwcell="<not attempted>" ;;
    *)             _ssh_pwcell="<not readable>" ;;
  esac
  _lab_add "guest node SSH" "$_ssh_tok" "vmware-system-user" "$_ssh_pwcell"
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

printf '\n  Lab access — you supplied these in .env; no installer publishes them\n'
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
printf '\n  Showing the lab-access values the scenario documents ask you to set: VCENTER_HOST,\n'
printf '  VCENTER_USERNAME, VCENTER_PASSWORD, VKS_USERNAME, VKS_PASSWORD, VCF_CLI_VSPHERE_PASSWORD\n'
printf '  and SUPERVISOR_HOST. There is no ssh row in .env because this repo never asks you for one —\n'
printf '  that credential is not yours to supply, it is the cluster'"'"'s to hand you.\n'
# ⚠️ CONDITIONAL, and that is the whole point (impl round, MED). These sentences printed
# UNCONDITIONALLY, so a run that read NOTHING still claimed "READ LIVE from the Supervisor" and
# asserted `Source: <none found>` — an absence about a namespace we may never have been able to
# query. The exact conflation the probe rewrite above exists to fix, re-committed two lines below it.
if [ -n "$_ssh_pw" ]; then
  printf '  Guest-node SSH password READ LIVE from %s in vSphere Namespace %s.\n' "$_ssh_sec" "${VKS_NAMESPACE:-<unset>}"
else
  printf '  Guest-node SSH password NOT read: %s\n' "$_ssh_state"
fi

echo
