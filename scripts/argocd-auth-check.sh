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
# against a broken PATH rather than a likely absence. kubectl is here because section 3 CANNOT
# read the Secret without it, and its absence otherwise produced the same 'NOT AVAILABLE' message
# as a genuinely-absent Secret -- which then prescribes ARGOCD_ADMIN_PASSWORD, i.e. tells the
# operator to make the check 'pass' on a password it never verified against anything.
require_cmd jq curl kubectl   # variadic since lib/os.sh was fixed — it used to check only the FIRST

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
# WHERE the password came from is part of the verdict, not trivia: a 401 only means "the credential
# was rejected" if a credential was actually READ, and an unreadable Secret can otherwise leave a
# non-empty garbage value that makes this check exonerate the address and the anchor it never tested.
_pw_src="$(argocd_password_last)"; _pw_src="${_pw_src#source=}"; _pw_src="${_pw_src%% *}"
_pw_why="$(argocd_password_last)"; _pw_why="${_pw_why##*reason=}"; case "$_pw_why" in *' '*|source=*|'') _pw_why="" ;; esac
if [ -z "$pw" ]; then
  case "$_pw_why" in
    nons)
      bad "admin password" "the NAMESPACE '${NS}' does not exist on this cluster (so the Secret was never looked for)"
      say "  what to check" "ARGOCD_NAMESPACE. On a real VKS lab ArgoCD is a Supervisor Service and does NOT live in '${NS}' — this is the most common cause. Do NOT set ARGOCD_ADMIN_PASSWORD to get past it." ;;
    unreadable)
      bad "admin password" "COULD NOT BE READ — kubectl failed against ns '${NS}' (not: the Secret is missing)"
      say "  what to check" "the kubeconfig, its context, and whether it may read Secrets in '${NS}'. Do NOT set ARGOCD_ADMIN_PASSWORD to get past this — that makes the check pass on a password nothing verified." ;;
    absent)
      bad "admin password" "the Secret argocd-initial-admin-secret is ABSENT in ns '${NS}' (the read SUCCEEDED)"
      say "  note" "upstream DELETES that Secret once the password is rotated — set ARGOCD_ADMIN_PASSWORD if yours was" ;;
    *)
      bad "admin password" "NOT AVAILABLE (ns '${NS}'), and ARGOCD_ADMIN_PASSWORD is unset" ;;
  esac
else
  say "admin password" "read (${#pw} chars) from ${_pw_src:-unknown} — never printed, never on argv"
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
  # A non-numeric or negative value makes `seq` yield ZERO iterations, silently disabling the poll
  # this check calls the leading cause of certification row 1's failure. Measured: `abc` -> 0, `-1`
  # -> 0, `3 4` -> 0; the message then reads "after abc attempts".
  _att="${ARGOCD_READY_ATTEMPTS:-30}"
  case "$_att" in ''|*[!0-9]*|0) _att=30 ;; esac
  for _ in $(seq 1 "$_att"); do
    # F9: without a status test ANY reply counts as "answering" — a 404, or an Envoy's
    # "503 no healthy upstream", breaks the loop and reports readiness during the exact race
    # this poll exists to wait out. F8: honour the scheme hook the session path already honours,
    # or this reports "did NOT answer" against a live stub while the session below returns 401.
    # B486/F7: single-sourced. It polls with -k DELIBERATELY -- this was the only CA-aware
    # poller, and with a stale CA (the default after any lab re-cut) it reported a healthy,
    # listening ArgoCD as "did NOT answer" after ~150s. ARGOCD_TLS_MODE is still disclosed
    # independently below, and the SESSION call keeps ARGOCD_CURL_TLS.
    argocd_endpoint_probe "$srv" 3
    _hc="${ARGOCD_ENDPOINT_HTTP:-}"
    if [ -n "$_hc" ] && [ "$_hc" != 000 ]; then
      _ready=1; break
    fi
    sleep "${ARGOCD_READY_INTERVAL_SECONDS:-2}"
  done
  if [ "$_ready" = 1 ]; then
    # ANY status means the endpoint is answering — the poll's job is to wait out a refused or
    # reset connection (the K1.5 race), not to assert that /healthz is routed. Requiring 200 made a
    # perfectly serving ArgoCD under --rootpath print "did NOT answer" one line above "a session
    # token was ISSUED", telling the reader to discount a PASS printed beneath it.
    say "endpoint" "answering on ${ARGOCD_SESSION_SCHEME:-https}://${srv}/healthz (HTTP ${_hc})"
  else
    # NOT a die: this check is read-only and its job is to REPORT. Saying the endpoint never
    # answered is itself the diagnosis, and it must not be confused with a credential verdict.
    say "endpoint" "did NOT answer /healthz after ${_att} attempts — anything below is about an endpoint that is not serving"
      # ⚠️ DIAGNOSE THE STALE ADDRESS, but DO NOT RE-RESOLVE AND CONTINUE. Re-resolving here would
      # make this check go GREEN while .env still held the dead address -- so `argocd login`,
      # `make gitops`, `make fetch-argocd-ca` and `creds-show` would all stay broken behind a passing
      # check. That is the fake-green class. It also cannot work for a TENANT, who is HANDED
      # ARGOCD_SERVER and has no Supervisor access, so the check would mean two different things in
      # the two scenarios. Report the discrepancy; change nothing.
      # MEASURED 2026-08-26: this poll burned 170s against a VIP that had moved .131 -> .138 and was
      # never coming back. The poll was added (B163/F2) for the K1.5 race -- an address that is
      # CORRECT but not yet routing -- and is structurally blind to an address that CHANGED.
      if [ -n "${KC:-}" ] && [ -r "${KC:-}" ]; then
        _live="$(kubectl --kubeconfig "$KC" -n "$NS" get svc argocd-server \
                   -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [ -n "$_live" ] && [ "$_live" != "$srv" ]; then
          say "  THE ADDRESS MOVED" "ARGOCD_SERVER=${srv}, but svc/argocd-server is now at ${_live}"
          say "  what to do" "your .env is stale - re-run 'make argocd-address'; it re-resolves and may now correct a value it wrote itself"
        elif [ -z "$_live" ]; then
          say "  cross-check" "svc/argocd-server reports no LoadBalancer address at all - the instance may still be reconciling"
        else
          say "  cross-check" "svc/argocd-server agrees the address is ${srv}, so this is NOT a stale-address problem"
        fi
      fi
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
    if _why="$(argocd_session_explain "$_rc" "$_code" "$_pw_src")"; then
      say "  what happened" "$_why"
    else
      # Only HERE is the cause genuinely undetermined, so only here is a hypothesis list honest —
      # and even here it is honest ONLY when verifying. Under -k the certificate's names were never
      # consulted, so printing ADDRESS/ANCHOR candidates and then a NOTE saying they are impossible
      # is a self-contradiction on adjacent lines. Suppress the list instead of annotating it.
      say "  undetermined"  "rc=${_rc:-?} HTTP ${_code:-?} does not name a cause on its own"
      if [ "$ARGOCD_TLS_MODE" = verified ]; then
        say "  candidates"    "1) the ADDRESS: is '${srv}' a name the certificate carries? 2) the ANCHOR: is ARGOCD_CA_FILE the CA that signed it?"
        say "  discriminate"  "make argocd-preflight   (it reports which of the two is at fault)"
      fi
    fi
    if [ "$ARGOCD_TLS_MODE" != verified ]; then
      # Say it out loud: with -k in effect, an address/anchor fault is IMPOSSIBLE here, so nobody
      # should be sent to look at either. This is the sentence whose absence cost a session.
      say "  NOTE" "this run was NOT verifying (-k), so the certificate's names were never consulted — an ADDRESS or ANCHOR fault cannot be the cause of THIS failure (which is why no candidate list is offered above)"
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
