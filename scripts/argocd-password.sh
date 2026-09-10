#!/usr/bin/env bash
# argocd-password.sh — print the ArgoCD 'admin' password for the CURRENT context.
#
# Fluid across BOTH contexts (VKS-provided ArgoCD and the KinD-installed stand-in):
# it self-resolves KUBECONFIG from .env/.env.kind (no kube-context juggling) and picks
# the password source by precedence, degrading gracefully:
#
#   1. ARGOCD_ADMIN_PASSWORD (.env) — the value the KinD install applied. Works even
#      with the cluster down; the natural path when the operator chose a known login.
#   2. else the auto-generated `argocd-initial-admin-secret`, read from the cluster —
#      the default KinD path, and a real VKS lab that kept the initial secret.
#   3. else ArgoCD is VKS-provided (or the secret was rotated/removed) → print guidance
#      to stderr and exit non-zero; the password is not knowable locally.
#
# stdout carries ONLY the password (so it pipes cleanly); diagnostics go to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠️ ARGV IS PARSED BEFORE load_env, ON PURPOSE — this is the .env.example clobber class.
# load_env sources .env.example with `set -a` AFTER the caller's environment is established, so an
# uncommented value there BEATS a per-run override. The four sibling wait knobs
# (HARBOR_REACHABLE/ARGOCD_ADDRESS/VKS_TKR_WAIT_SECONDS, .env.example:947/956/963) all ship COMMENTED
# for exactly that reason, and ARGOCD_PASSWORD_WAIT_SECONDS joins them. But creds.sh's "do not wait"
# must not depend on anyone remembering that: it passes `--wait 0` as an ARGUMENT, which nothing in
# any .env can reach. Measured cost of getting this wrong: creds.sh renders three times inside
# `make static-check` -> test-scripts -> test-creds-show, so a defeated 0 is a 45-minute CI hang.
# lowercase on purpose: an UPPERCASE name here reads as an OPERATOR KNOB to check-env-coverage,
# which then (correctly) demands it be documented in .env.example. The operator-facing knob is
# ARGOCD_PASSWORD_WAIT_SECONDS; these two are internals.
#
# SHOW_SECRETS IS SNAPSHOT HERE, BEFORE load_env, FOR THE SAME REASON (see creds.sh's copy). It is a
# per-run toggle, so `.env.example` ships it COMMENTED; but the protection must not depend on that
# staying true, because an uncommented line would re-arm the leak permanently and invisibly.
_show_secrets_snapshot="${SHOW_SECRETS:-0}"

# --raw: print the value with NO mask, for a CALLER that applies its own reveal decision.
# ⚠️ It exists because creds.sh captures this script in `$( )` — always a pipe, therefore always
# non-tty — so without it a masked sentinel would land in creds.sh's OWN Password cell and the
# operator would never see their password on a real terminal. creds.sh then masks (or reveals) it
# with the identical rule. Do NOT reach for `[ -t 1 ]` to detect that case: it cannot distinguish
# "creds.sh is capturing me" from "a walk log is capturing me", which is the whole leak.
_raw=0
_wait_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) _wait_arg="${2:-}"; shift 2 ;;
    --wait=*) _wait_arg="${1#--wait=}"; shift ;;
    --raw) _raw=1; shift ;;
    -h|--help) printf 'usage: argocd-password.sh [--wait SECONDS] [--raw]\n'; exit 0 ;;
    *) printf 'argocd-password.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

# _emit <plaintext> — the ONLY way this script writes a password to stdout.
# MEASURED (B153 round, run 6, all six row logs): 16 credential occurrences reached the walk logs.
# creds-show's guard alone closes 14; a value-keyed redactor at walk-doc.sh's sink closes 12 and
# adds ZERO over the guard -- the two that survive BOTH are the bare `make argocd-password` prints
# at docs/scenario-1.md Step 5, because that value is read from the k8s Secret and never lands in
# .env or .walk-env, so nothing downstream can key on it. This function is what takes it to 16/16.
_emit() {
  # ⚠️ DELIBERATELY `= "1"` AND NOT THE REPO'S `is_true` — do NOT "fix" this for consistency.
  # `is_true` accepts 1|true|yes|y|on (case-insensitively). MEASURED 2026-08-18 across 9 values, the
  # two predicates diverge on 5 — true / TRUE / yes / y / on — and EVERY divergence is in the
  # fail-CLOSED direction: the shipped form MASKS where is_true would REVEAL. Widening a predicate
  # that uncovers a password, for tidiness, is the wrong trade in the only direction that matters.
  # An adversary flagged the inconsistency (correctly) and prescribed is_true; that prescription is
  # declined on this measurement. The cost is an operator who types SHOW_SECRETS=true getting no
  # output -- and the mask message names the accepted value verbatim, so it is self-correcting.
  if [ "$_raw" = 1 ] || [ -t 1 ] || [ "$_show_secrets_snapshot" = "1" ]; then
    printf '%s\n' "$1"
  else
    printf '<hidden: not a terminal — re-run with SHOW_SECRETS=1>\n'
  fi
}

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# WHOLE SECONDS. `15m` is the plausible typo because the document speaks in minutes, and an
# unguarded value makes `[ "$_wait" -gt 0 ]` print `integer expression expected` and SKIP the wait —
# silently restoring the behaviour the wait exists to fix.
_wait="${_wait_arg:-${ARGOCD_PASSWORD_WAIT_SECONDS:-900}}"
case "$_wait" in
  ''|*[!0-9]*) die "--wait / ARGOCD_PASSWORD_WAIT_SECONDS must be WHOLE SECONDS, got '${_wait}' (900, not 15m)" ;;
esac

ARGOCD_NAMESPACE="$(argocd_namespace)"   # lib/os.sh: installer and reader agree

# THE CLUSTER IS THE TRUTH, NOT `.env`.
#
# This used to print ARGOCD_ADMIN_PASSWORD from .env first, "because the KinD install applied it".
# It often did not: `make e2e-kind` runs with SKIP_DOTENV=1, so 07-install-argocd.sh never saw the
# .env value and never applied it — ArgoCD kept its AUTO-GENERATED password. But THIS script does
# not skip .env, so it printed the .env value anyway: a confidently-wrong password that does not
# log in. Telling someone a wrong password is worse than telling them nothing.
#
# The signal is exact: 07-install-argocd.sh DELETES `argocd-initial-admin-secret` when (and only
# when) it applies our password. So:
#   secret PRESENT -> the auto-generated password is in force; ours was NOT applied -> print theirs.
#   secret ABSENT  -> ours was applied (or ArgoCD is lab-provided) -> fall back to ARGOCD_ADMIN_PASSWORD.
# Ask the cluster first, and only believe .env when the cluster is unreachable or has no such secret.

# WHICH CLUSTER — and why this is not just `$KUBECONFIG`.
#
# ArgoCD on VKS is a SUPERVISOR Service, but scenario-1 Step 6 repoints KUBECONFIG at the GUEST
# cluster and it stays there through Step 13. MEASURED 2026-08-12 with the guest cluster's own
# kubeconfig: `kubectl -n cicd get secret argocd-initial-admin-secret` ->
# `Error from server (NotFound): namespaces "cicd" not found`. The namespace does not even exist
# there, so from Step 6 on this script could never find the password on a real lab.
#
# ⚠️ BUT NOT `supervisor_kubeconfig` ALONE, WHICH WOULD INVERT THE SAME BUG. It is first-that-EXISTS
# and ranks ${REPO_ROOT}/secrets/supervisor.kubeconfig ABOVE $KUBECONFIG — and nothing ever deletes
# that file (`secrets/` is gitignored; 98-uninstall-all.sh only prints a note). So on any box that
# has ever run `make vks-login` — including this one — a later KinD `make argocd-password` would
# read the LAB's password while the operator is looking at KinD. Try BOTH, in that order, take the
# first that ANSWERS, and say which one did: evidence, not ranking.
_candidates() {
  local sup; sup="$(supervisor_kubeconfig 2>/dev/null || true)"
  [ -n "$sup" ] && printf '%s\n' "$sup"
  [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG:-}" != "$sup" ] && printf '%s\n' "$KUBECONFIG"
  return 0
}

# Prints `<kubeconfig><TAB><base64>` on success — ONE string, not a value plus a global.
# ⚠️ A GLOBAL CANNOT CROSS A SUBSHELL. The first version set ANSWERED_KC here and read it in the
# caller, which invokes this as `$(_read_secret)` — a subshell — so the assignment was discarded and
# `set -u` killed the script with `ANSWERED_KC: unbound variable`. Neither field can contain a tab
# (a filesystem path we constructed, and base64), so one line carries both unambiguously.
# ⚠️ THE ERRFILE IS PASSED IN BY THE CALLER, NOT KEPT IN A GLOBAL — same subshell rule as the note
# above. This runs as `$(_read_secret)`, so anything it assigns is discarded; a FILE crosses the
# boundary, a variable does not. Until 2026-09-08 this did `2>/dev/null` and the cause was destroyed
# at the point of the read, which is why the caller could only see "empty" and waited 900s on an
# EXPIRED token (measured on the live lab: 15 minutes for a secret it would never see).
# Each candidate APPENDS, because there are two of them and they fail DIFFERENTLY — see _should_wait.
_read_secret() {
  local kc enc errf="${1:-/dev/null}"
  : > "$errf" 2>/dev/null || true
  while IFS= read -r kc; do
    [ -n "$kc" ] && [ -f "$kc" ] || continue
    # BOUNDED, and stdin CLOSED — see the timing note below.
    if enc="$(KUBECONFIG="$kc" timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl --request-timeout=5s \
                -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
                -o jsonpath='{.data.password}' </dev/null 2>>"$errf")" && [ -n "$enc" ]; then
      printf '%s\t%s' "$kc" "$enc"; return 0
    fi
  done < <(_candidates)
  return 1
}

# The read's stderr, kept for the WAIT decision below. A file, not a variable, because _read_secret
# runs inside `$( )` — see its header. Removed on exit; an operator never sees or needs it.
_ap_err="$(mktemp)"
trap 'rm -f "$_ap_err"' EXIT

# ── _should_wait <errfile> — is waiting the RIGHT thing, or will it never arrive? ────────────────
# ⚠️ THE TEST IS A POSITIVE NotFound ON THE SECRET, NOT A CLASSIFICATION. classify_kube_failure has
# NO NotFound arm — a genuine "secrets ... not found" classifies UNKNOWN, which is also its residual
# bucket, so gating the wait on a class would fail OPEN (wait on anything unrecognised) and would
# even wait 15 minutes on NO_KUBE_TARGET, i.e. on localhost:8080. 08-install-argocd-service.sh:95-111
# solved this identical failure with kube_is_notfound; this follows it.
#
# ⚠️ AND THE TOKEN MATTERS, because there are TWO candidates and they fail DIFFERENTLY. MEASURED on
# the live lab with an expired Supervisor token:
#     secrets/supervisor.kubeconfig -> "You must be logged in to the server (Unauthorized)"
#     $KUBECONFIG (the guest)       -> 'Error from server (NotFound): namespaces "cicd" not found'
# So "any NotFound -> wait" votes to WAIT on the guest's NAMESPACE-NotFound and the 15-minute hang
# survives the fix. Only a NotFound naming THE SECRET means "it is reconciling, come back".
# kube_is_notfound requires both facts on the SAME line, so a namespace-NotFound cannot satisfy it.
_should_wait() {
  kube_is_notfound "${1:-/dev/null}" argocd-initial-admin-secret
}

# Split what _read_secret printed. Sets ANSWERED_KC + ENC in the CALLER's shell.
_split_answer() { ANSWERED_KC="${1%%$'\t'*}"; ENC="${1#*$'\t'}"; }


# CURRENT or STALE — because NOTHING deletes argocd-initial-admin-secret, so a stale value is
# served with full confidence, forever.
#
# MEASURED 2026-09-07 on cicd-gc3: the secret was still present 20h after install, with ZERO
# annotations, labels and ownerReferences — i.e. created by `argocd-server` at runtime, not by
# kapp (contrast argocd-secret, which carries kapp.k14s.io/*). So the operator neither deletes nor
# recreates it, and upstream's Getting Started only ADVISES a human to delete it. The previous
# wording ("it no longer works if you have run update-password") was an unconditional hedge: the
# reader could never tell a live value from a dead one.
#
# THE DISCRIMINATOR IS FREE. argocd-secret carries `admin.passwordMtime`, rewritten on every
# password change; the initial secret carries its own creationTimestamp. MEASURED equal to the
# second on an unchanged instance (both 2026-09-06T07:45:25Z). mtime NEWER ⇒ changed.
#
# ⚠️ Bounded and tolerant: a missing argocd-secret, an RBAC refusal or a slow API must degrade to
# UNKNOWN and the old honest hedge — never to a confident CURRENT. Absence is a claim about the
# QUERY first (this file has been bitten by that: see the 89%-of-runtime retry note above).
_password_state() {
  local kc="$1" mt ct
  mt="$(KUBECONFIG="$kc" timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl --request-timeout=5s \
          -n "$ARGOCD_NAMESPACE" get secret argocd-secret \
          -o jsonpath='{.data.admin\.passwordMtime}' </dev/null 2>/dev/null || true)"
  [ -n "$mt" ] || { printf 'UNKNOWN'; return 0; }
  mt="$(printf '%s' "$mt" | base64 -d 2>/dev/null || true)"
  ct="$(KUBECONFIG="$kc" timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl --request-timeout=5s \
          -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
          -o jsonpath='{.metadata.creationTimestamp}' </dev/null 2>/dev/null || true)"
  [ -n "$mt" ] && [ -n "$ct" ] || { printf 'UNKNOWN'; return 0; }
  # String compare is correct here: both are RFC3339 UTC (Z), so lexical order IS chronological.
  if [ "$mt" \> "$ct" ]; then printf 'STALE\t%s' "$mt"; else printf 'CURRENT'; fi
}

# The one line the operator reads about whether this value works. It replaces an unconditional
# hedge, so the wording per state is the deliverable, not decoration.
_say_state() {
  local st="$1" when="${2:-}"
  case "$st" in
    CURRENT)
      log_info "ArgoCD admin password: CURRENT — unchanged since this instance was created, so this value works." ;;
    STALE)
      log_warn "ArgoCD admin password: STALE — it was CHANGED at ${when}, after this value was issued."
      log_warn "  This value NO LONGER WORKS, and the current one is NOT RECOVERABLE: ArgoCD keeps only a"
      log_warn "  bcrypt hash in argocd-secret's admin.password. Nothing deletes the stale secret, so this"
      log_warn "  report will keep showing this value. Confirm with: make argocd-auth-check" ;;
    *)
      log_warn "this is the INITIAL admin password. Nothing ever deletes argocd-initial-admin-secret, so"
      log_warn "  this report keeps printing it even after someone changes the password — it does NOT"
      log_warn "  self-correct. Could not tell CURRENT from STALE here (argocd-secret unreadable)."
      log_warn "  Check with: make argocd-auth-check" ;;
  esac
}

# 1. The auto-generated initial-admin secret — if it EXISTS, it is the password in force.
if command -v kubectl >/dev/null 2>&1; then
  # BOUNDED, and stdin CLOSED. This is the single most expensive call in `make creds-show`:
  # MEASURED 2026-08-12 against a blackholed endpoint it cost 150,061 ms of the report's 168,189 ms
  # total — 89% — because a bare `kubectl get` RETRIES the dial. `--request-timeout` alone does not
  # bound it either (measured: `--request-timeout=3s get` still took 15,034 ms, 5x the flag, while
  # `version` was bounded at 3,033 ms). And without `</dev/null` a kubeconfig whose user has no
  # credentials makes kubectl print `Please enter Username:` and WAIT — measured, it held a
  # 6s-delayed stdin for the full 6,004 ms, which on a terminal is an indefinite hang.
  # A report that hangs is worse than one that says <not set>: the operator Ctrl-Cs and never sees
  # the Context block explaining why the value is stale.
  if ans="$(_read_secret "$_ap_err")" && [ -n "$ans" ]; then
    _split_answer "$ans"; enc="$ENC"
    log_info "read argocd-initial-admin-secret from ns/${ARGOCD_NAMESPACE} via ${ANSWERED_KC}"
    if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
      log_warn "ARGOCD_ADMIN_PASSWORD is set, but the cluster still has argocd-initial-admin-secret"
      log_warn "  -> your value was NEVER APPLIED (an install with SKIP_DOTENV=1 does not read .env)."
      log_warn "  -> printing the password that ACTUALLY works."
      # ⚠️ THE REMEDY IS RIG-SCOPED; THE DIAGNOSIS ABOVE IS NOT. Both commands below PROVISION LOCAL
      # TEST INFRASTRUCTURE — Makefile:922 describes `install-argocd` verbatim as "Install ArgoCD into
      # KinD", and it applies manifests to whatever $KUBECONFIG names. This arm is reachable on a REAL
      # lab (argocd-server creates argocd-initial-admin-secret at runtime and nothing deletes it), so
      # unguarded it pointed a tenant at a KinD installer aimed at their own cluster.
      # Same shape and same fix as lib/harbor.sh:153, which gates its KinD-only remedy on this stamp.
      if [ "${VKS_STATE_KIND:-0}" = 1 ]; then
        log_warn "  -> to pin your own: make install-argocd   (or: make e2e-kind E2E_SKIP_DOTENV=0)"
      else
        log_warn "  -> ArgoCD here is lab-provided: your ARGOCD_ADMIN_PASSWORD was never applied and"
        log_warn "     nothing here can apply it. Unset it in .env. To CHANGE the password, use the"
        log_warn "     ArgoCD CLI against the instance: argocd account update-password"
      fi
    fi
    # ⚠️ THIS IS THE *INITIAL* PASSWORD. ArgoCD does NOT delete the secret when the password is
    # changed, and scenario-1 Step 5 tells the reader to run `argocd account update-password`
    # immediately after reading it — so from that moment this value is stale while still being
    # served. Say so; a wrong password presented as fact costs more than no password.
    _st="$(_password_state "$ANSWERED_KC")"
    _say_state "${_st%%$'\t'*}" "${_st#*$'\t'}"
    _emit "$(printf '%s' "$enc" | base64 -d)"
    exit 0
  fi

  # NOT YET CREATED IS NOT THE SAME AS NOT AVAILABLE, and the difference was worth 12 seconds.
  # MEASURED, walk row 1 at scenario-1 Step 5: this script ran at 19:42:25Z and told the operator to
  # "get the 'admin' password from your VKS lab"; the ArgoCD operator created the secret at
  # 19:42:37Z. Same class as harbor-reachable / argocd-address / vks-k8s-version before each was
  # taught to wait — a point-in-time read of something that is merely still reconciling.
  # ⚠️ WAIT ONLY IF WAITING CAN HELP. Until 2026-09-08 this asked only whether the value was
  # EMPTY, so an empty result read as "still reconciling" whatever caused it — measured on the live
  # lab, an EXPIRED Supervisor token bought a 900s wait for a secret that would never appear, while
  # `make creds` PRESCRIBED this command in exactly that state and called it "(it waits)". Same
  # forbidden-reads-as-absent class as B484.
  if [ "$_wait" -gt 0 ] && [ -z "${ARGOCD_ADMIN_PASSWORD:-}" ] && ! _should_wait "$_ap_err"; then
    # classify_kube_failure WORDS this; it never DECIDES it (no NotFound arm — see _should_wait).
    _ap_cls="$(classify_kube_failure "$_ap_err" 2>/dev/null || true)"
    log_warn "not waiting: the read did not fail with a NotFound naming argocd-initial-admin-secret,"
    log_warn "so the secret is not merely reconciling (classified: ${_ap_cls:-UNKNOWN})."
    # ⚠️ THE SSO COMMAND APPEARS ON EXACTLY ONE ARM BELOW: EXPIRED, where the token's own `exp`
    # makes the cause a FACT. Everywhere else there is deliberately NO command — the obvious remedy
    # performs a vSphere SSO bind and vCenter locks out PERMANENTLY after 3 failures, so it must
    # never be prescribed for a state this cannot decide. Keep this arm-for-arm identical to
    # creds.sh's `_rejected_why`; a round found the two copies DISAGREEING on the undecidable arm.
    if [ "$_ap_cls" = UNAUTHORIZED ]; then
      # The token's own exp claim separates "expired" from "rotated/revoked" — kubectl reports both
      # as Unauthorized. Offline, so it costs none of the THREE vCenter SSO attempts before lockout.
      _ap_exp="$(kube_token_expiry "$(supervisor_kubeconfig 2>/dev/null || true)" 2>/dev/null || printf 'UNKNOWN')"
      case "$_ap_exp" in
        # ONE sentence, from lib/os.sh — NOT a hand-written copy. A round measured the two copies
        # DISAGREEING on the undecidable arm, and "locks out PERMANENTLY" missing from this file's
        # arms entirely: the clause that is the whole REASON the command is withheld.
        EXPIRED*) log_warn "the Supervisor token EXPIRED at ${_ap_exp#EXPIRED } — $(supervisor_renew_how)" ;;
        VALID*)   log_warn "the cluster REJECTED this kubeconfig although its token has NOT expired (valid until ${_ap_exp#VALID }) — that is a ROTATED or REVOKED credential, not an expiry. $(supervisor_renew_how --ask-only)" ;;
        *)        log_warn "the cluster REJECTED this kubeconfig and its token carries no readable expiry (a client-cert kubeconfig has none, and an ambiguous one is refused rather than guessed), so this may be a ROTATED credential rather than an expired one. $(supervisor_renew_how --no-command)" ;;
      esac
    fi
  fi
  if [ "$_wait" -gt 0 ] && [ -z "${ARGOCD_ADMIN_PASSWORD:-}" ] && _should_wait "$_ap_err"; then
    log_info "argocd-initial-admin-secret is not in ns/${ARGOCD_NAMESPACE} yet — the ArgoCD instance is still reconciling."
    log_info "waiting up to ${_wait}s ..."
    _w=0
    while [ "$_w" -lt "$_wait" ]; do
      sleep 15; _w=$((_w + 15))
      if ans="$(_read_secret "$_ap_err")" && [ -n "$ans" ]; then
        _split_answer "$ans"; enc="$ENC"
        log_info "read argocd-initial-admin-secret from ns/${ARGOCD_NAMESPACE} via ${ANSWERED_KC} (after ${_w}s)"
        _st="$(_password_state "$ANSWERED_KC")"
        _say_state "${_st%%$'\t'*}" "${_st#*$'\t'}"
        _emit "$(printf '%s' "$enc" | base64 -d)"
        exit 0
      fi
      [ $((_w % 60)) = 0 ] && log_info "  still absent (${_w}/${_wait}s) ..."
    done
    _waited=1
  fi
fi

# 2. No initial-admin secret -> our password was applied (07 deletes it when it applies ours),
#    or ArgoCD is lab-provided and the operator set the value themselves.
if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
  _emit "$ARGOCD_ADMIN_PASSWORD"
  exit 0
fi

# 3. Not knowable locally. TWO STATES, TWO EXIT CODES — creds.sh renders the reason in the Password
#    cell, and it captures this script with `2>/dev/null`, so a message alone reaches nobody at the
#    step that needs it most (scenario-1 Step 13, "Access the UIs").
if [ "${_waited:-0}" = 1 ]; then
  log_error "argocd-initial-admin-secret never appeared in ns/${ARGOCD_NAMESPACE} (waited ${_wait}s)."
  log_error "  Tried: $(_candidates | tr '\n' ' ')"
  log_error "  If the ArgoCD instance IS running, its namespace is probably not ${ARGOCD_NAMESPACE}:"
  log_error "      kubectl get argocd -A        # on VKS it is often argocd-instance-N"
  exit 4
fi
log_error "No ArgoCD 'admin' password is available locally for this context."
log_error "  Looked for argocd-initial-admin-secret in ns/${ARGOCD_NAMESPACE} via: $(_candidates | tr '\n' ' ')"
log_error "  • real VKS: the initial secret is created by the ArgoCD instance — 'make argocd-password'"
log_error "    waits for it. If it is genuinely gone, someone has rotated the password."
# ⚠️ Same rig-scoping as the arm above: this line prescribes a LOCAL-INFRA installer, so it prints only
# when the stamp proves we are on the rig. Unguarded it let an operator ARM the conflict arm by hand.
if [ "${VKS_STATE_KIND:-0}" = 1 ]; then
log_error "  • KinD: set ARGOCD_ADMIN_PASSWORD in .env and re-run 'make install-argocd' for a known"
log_error "    login, or ensure the cluster is up so the generated 'argocd-initial-admin-secret' is readable."
fi
exit 3
