#!/usr/bin/env bash
# argocd-auth-check.sh — does the ArgoCD ADMIN credential actually authenticate? READ-ONLY.
#
# WHY THIS EXISTS. B152 measured that NOTHING in the certification matrix ever authenticates to
# ArgoCD: `argocd login` is TTY-bound so walk-doc NEUTRALIZES it in all four scenario-1 rows, and
# scenario-2 has no admin-login line at all — 0 real-login lines across all six row logs. So the one
# credential the document hands the reader was the one credential nothing tested, and F9 (an ArgoCD
# transport failure) sat undetected behind four GREEN rows because of it.
#
# WHY IT IS A TARGET AND NOT A WALK REWRITE. scenario-1:384 DELIBERATELY documents an interactive
# step ("`argocd login` **prompts** for the password, so paste what `make argocd-password` printed").
# Rewriting that line into a non-interactive pipeline would test a command no reader ever types —
# the walk's own recorded failure mode. So the walk keeps skipping it, the doc keeps its honest
# interactive instruction, and the PROOF lives here, where a reader can run it.
#
# WHAT A PASS PROVES, EXACTLY — and this is deliberately narrow:
#   * the credential is valid, and argocd-server answers the session API at that address;
#   * with ARGOCD_CA_FILE set, that the CHAIN and the NAME both verify (the F9 path);
#   * with no CA, NOTHING about TLS trust — an insecure pass is compatible with the transport being
#     exactly as broken as F9 describes, so this script says so out loud rather than reporting a
#     green that means less than it looks.
# It does NOT prove the TENANT path. scenario-2 uses `argocd login --sso` + `account generate-token`;
# exercising `admin` says nothing about a capability a tenant may not have.
#
# Read-only: it reads a Secret and POSTs a session request. It creates nothing and mutates nothing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"
load_env

NS="${ARGOCD_NAMESPACE:-argocd}"
# ARGOCD_KUBECONFIG is the SUPERVISOR's on a real lab (ArgoCD is a Supervisor Service, so it is NOT
# the guest kubeconfig); on KinD the two are the same file and this collapses correctly.
KC="${ARGOCD_KUBECONFIG:-${KUBECONFIG:-}}"

fail=0
say()  { printf '  %-34s %s\n' "$1" "$2"; }
bad()  { say "$1" "$2"; fail=1; }

# Both are load-bearing and NEITHER was required before (B163/F3): a missing `jq` yields an empty
# body, which becomes an empty token, which produced the SAME "NO token" message — a third silent
# path into one diagnostic. Both are pinned (.mise.toml, 00-install-prereqs.sh), so this is a guard
# against a broken PATH rather than a likely absence.
require_cmd jq curl

echo
echo "════════ argocd auth check — does the ADMIN credential really authenticate? ════════"

# ---- 1. the ADDRESS ------------------------------------------------------------------------------
srv="${ARGOCD_SERVER:-}"
if [ -z "$srv" ]; then
  bad "ARGOCD_SERVER" "UNSET — nothing to authenticate against"
  echo
  log_error "argocd-auth-check: set ARGOCD_SERVER first (a NAME the certificate carries; see .env.example)."
  exit 1
fi
say "ARGOCD_SERVER" "$srv"
# An IP can NEVER verify against argocd-server's default certificate: LAB-MEASURED 2026-08-17, its
# SANs are DNS-only (localhost, argocd-server, argocd-server.<ns>[.svc[.cluster.local]]) with NO IP
# SAN. Report it as a fact about the ADDRESS rather than letting it surface later as a CA mystery.
case "$srv" in
  *[a-zA-Z]*) : ;;
  *) say "  ⚠️ address shape" "this looks like a bare IP — argocd-server's default cert has NO IP SAN, so a VERIFYING path cannot succeed with it" ;;
esac

# ---- 2. the ANCHOR ------------------------------------------------------------------------------
argocd_curl_tls_init
if [ "$ARGOCD_TLS_MODE" = verified ]; then
  say "TLS" "VERIFYING against ${ARGOCD_CA_FILE}"
else
  say "TLS" "NOT VERIFIED (-k) — no ARGOCD_CA_FILE"
  say "  what this costs" "a pass below proves the CREDENTIAL only, NOTHING about trust. Run 'make fetch-argocd-ca' and re-run to cover the path that fails on a real lab."
fi

# ---- 3. the CREDENTIAL --------------------------------------------------------------------------
if [ -z "$KC" ] || [ ! -s "$KC" ]; then
  bad "kubeconfig" "ARGOCD_KUBECONFIG/KUBECONFIG is unset or missing — cannot read the admin Secret"
else
  say "kubeconfig" "$KC"
fi
pw=""
[ -n "$KC" ] && [ -s "$KC" ] && pw="$(argocd_admin_password "$KC" "$NS")"
if [ -z "$pw" ]; then
  bad "admin password" "NOT AVAILABLE (no argocd-initial-admin-secret in ns '${NS}', and ARGOCD_ADMIN_PASSWORD is unset)"
  say "  note" "upstream DELETES that Secret once the password is rotated — set ARGOCD_ADMIN_PASSWORD if yours was"
else
  say "admin password" "read (${#pw} chars) — never printed, never on argv"
fi

# ---- 4. AUTHENTICATE ---------------------------------------------------------------------------
# ⚠️ THE READINESS POLL BELOW WAS DROPPED WHEN THIS CHECK WAS LIFTED (B163/F2, the leading cause of
# certification row 1's failure). The lift took 91-e2e-tenant-mechanism.sh:222-264 but NOT :206-214,
# whose own comment says why they belong together: "cloud-provider-kind assigns the IP long before
# its Envoy is actually routing (the K1.5 race). A pod being Ready is NOT the same as its LB
# answering — poll the endpoint itself, or the first request dies on connection reset."
# It matters HERE more than there, because scenario-1 runs `make argocd-address` — which returns the
# INSTANT .status.loadBalancer.ingress[0].ip appears, i.e. exactly when the race window OPENS — and
# then runs this check a few lines later. Row 1 failed in 0s (sub-second: walk-doc.sh:704 prints
# whole seconds), which is the shape of a refused connection, not of a TLS or credential fault.
# Class denominator at the time: 2 production callers of argocd_session_token, 1 polled first.
if [ -n "$pw" ] && [ "$fail" -eq 0 ]; then
  _ready=0
  for _ in $(seq 1 "${ARGOCD_READY_ATTEMPTS:-30}"); do
    if curl -s "${ARGOCD_CURL_TLS[@]}" -o /dev/null --max-time 3 "https://${srv}/healthz" 2>/dev/null; then
      _ready=1; break
    fi
    sleep "${ARGOCD_READY_INTERVAL_SECONDS:-2}"
  done
  if [ "$_ready" = 1 ]; then
    say "endpoint" "answering on https://${srv}/healthz"
  else
    # NOT a die: this check is read-only and its job is to REPORT. Saying the endpoint never
    # answered is itself the diagnosis, and it must not be confused with a credential verdict.
    say "endpoint" "did NOT answer /healthz after ${ARGOCD_READY_ATTEMPTS:-30} attempts — anything below is about an endpoint that is not serving"
  fi
  tok="$(argocd_session_token "$srv" "$pw")"
  if [ -n "$tok" ]; then
    say "POST /api/v1/session" "a session token was ISSUED"
    if [ "$ARGOCD_TLS_MODE" = verified ]; then
      say "VERDICT" "PASS — the credential authenticates AND the transport verifies (chain + name)"
    else
      say "VERDICT" "PASS (credential only) — the transport was NOT verified; see above"
    fi
  else
    # ⚠️ THIS USED TO PRINT A CLOSED TWO-ITEM LIST (the ADDRESS / the ANCHOR) over a signal that
    # could not distinguish five causes, because argocd_session_token discarded curl's rc AND the
    # HTTP status. On certification row 1 (2026-08-17, backlog B163) NEITHER listed item was live —
    # the run was `-k`, so the certificate's SANs were never consulted — and a reader followed the
    # list to the wrong file. A check may only offer "next steps" for a cause it has NOT named.
    _diag="$(argocd_session_last)"
    _rc="${_diag#rc=}"; _rc="${_rc%% *}"
    _code="${_diag##*http=}"
    bad "POST /api/v1/session" "NO token (curl rc=${_rc:-?}, HTTP ${_code:-?})"
    if _why="$(argocd_session_explain "$_rc" "$_code")"; then
      say "  what happened" "$_why"
    else
      # Only HERE is the cause genuinely undetermined, so only here is a hypothesis list honest.
      say "  undetermined"  "rc=${_rc:-?} HTTP ${_code:-?} does not name a cause on its own"
      say "  candidates"    "1) the ADDRESS: is '${srv}' a name the certificate carries? 2) the ANCHOR: is ARGOCD_CA_FILE the CA that signed it?"
      say "  discriminate"  "make argocd-preflight   (it reports which of the two is at fault)"
    fi
    if [ "$ARGOCD_TLS_MODE" != verified ]; then
      # Say it out loud: with -k in effect, an address/anchor fault is IMPOSSIBLE here, so nobody
      # should be sent to look at either. This is the sentence whose absence cost a session.
      say "  NOTE" "this run was NOT verifying (-k), so the certificate's names were never consulted — an ADDRESS or ANCHOR fault cannot be the cause of THIS failure"
    fi
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  log_info "argocd-auth-check: OK"
else
  log_error "argocd-auth-check: findings above"
fi
exit "$fail"
