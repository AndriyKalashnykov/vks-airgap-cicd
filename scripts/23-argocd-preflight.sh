#!/usr/bin/env bash
# 23-argocd-preflight.sh — answer, BEFORE you spend 20 minutes mirroring images, the questions that
# actually decide whether `make gitops` can work on THIS lab:
#
#   1. Do both clusters answer?              (the ArgoCD cluster AND the guest/workload cluster)
#   2. Is ArgoCD OFF-CLUSTER?                (on a real VKS lab it is — a Supervisor Service)
#   3. WHICH WRITE MECHANISM is open to me?  (kubectl into the ArgoCD namespace, or argocd-server)
#   4. Is my guest a REGISTERED destination, unambiguously?
#   5. Does my AppProject actually PERMIT the destination + the repo, per app?
#   6. Can ArgoCD's repo-server even REACH my Gitea?
#   7. Versions: the operator's supported set, the RUNNING server, the CLI, this repo's pin.
#
# IT USED TO LIE. It only ever talked to $KUBECONFIG (the GUEST). On a CORRECT Scenario-1 lab — where
# ArgoCD is a Supervisor Service and KUBECONFIG is the guest — it therefore reported FOUR false
# things: "operator CRD not found", "no argocd-server deploy", "0 clusters registered", and
# "TOPOLOGY MISMATCH ... the repo's make gitops assumes the in-cluster destination". That last one
# has been false since 70-configure-argocd.sh started DERIVING the topology and REFUSING the
# in-cluster destination when off-cluster. A preflight that tells a correctly-configured operator
# their setup is broken is worse than no preflight.
#
# It also asked for ONE namespace literally named "javawebapp gowebapp " (the app names joined with
# spaces), so the namespace check could never pass — not even with a single app (trailing space).
#
# Read-only. Exits NON-ZERO on a BLOCKING finding, so it can gate `make install-all`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
argocd_tls_opts   # ARGOCD_CA_FILE -> --server-crt, once, for every argocd call below
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

require_cmd kubectl
: "${KUBECONFIG:?KUBECONFIG must be set (path to the GUEST/workload-cluster kubeconfig)}"; export KUBECONFIG

NS="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"   # VKS_ARGOCD_CRD now lives in lib/argocd.sh
blocking=0
warned=0
dest=""

# ka = the cluster ArgoCD RUNS IN. kg = the GUEST/workload cluster. On KinD they are the same file.
# --request-timeout=15s: on a black-hole endpoint `kubectl version` HANGS (>2 min) instead of
# failing fast — the gate `block`s on failure anyway, so a bounded timeout just makes the block quick.
# 15s is generous enough not to false-block a live-but-slow Supervisor (the version PEEK uses 3s).
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s "$@"; }
kg() { kubectl --kubeconfig "$KUBECONFIG" --request-timeout=15s "$@"; }
block() { log_error "BLOCKING: $*"; blocking=1; }
warn()  { log_warn "$*"; warned=$((warned + 1)); }

# ---- 1. both clusters ---------------------------------------------------------------------------
echo "── clusters ──"
[ -f "$ARGOCD_KUBECONFIG" ] || block "ARGOCD_KUBECONFIG not found: $ARGOCD_KUBECONFIG"
ARGOCD_API="$(argocd_api_server "$ARGOCD_KUBECONFIG")"
GUEST_API="$(argocd_api_server "$KUBECONFIG")"
log_info "guest  (workload): ${GUEST_API:-?}"
log_info "argocd (control) : ${ARGOCD_API:-?}"

if [ "$ARGOCD_KUBECONFIG" = "$KUBECONFIG" ]; then
  log_info "ARGOCD_KUBECONFIG is unset -> assuming ArgoCD runs IN the workload cluster (KinD / ArgoCD-in-guest)."
  log_info "  On a real VKS lab ArgoCD is a Supervisor SERVICE — a DIFFERENT cluster. If that is your lab,"
  log_info "  set ARGOCD_KUBECONFIG ('make fetch-argocd-kubeconfig') or gitops will look in the wrong place."
fi
# ⚠️ CLASSIFY, do not guess. These two used to discard stderr and say "does not answer" for every
# failure — which is the WRONG CAUSE for the most common one on a real lab: a REBUILT Supervisor
# mints a new CA while the address stays the same, so the kubeconfig looks configured and the
# endpoint answers fine. "Does not answer" sends the operator to check the network.
#
# ⚠️ NO `local` HERE. This file is `set -uo pipefail` with NO `-e`, and these lines are TOP-LEVEL:
# `local` outside a function is an error, the assignment silently does not happen, and the next
# use trips `set -u` for rc=127 — a crash whose message names the variable, not the cluster.
_pf_err="$(mktemp)"
_pf_classify() {   # _pf_classify <label> <var-name-for-the-message>
  case "$(classify_kube_failure "$_pf_err")" in
    STALE_CA)     block "the $1 cluster's kubeconfig CA does not match what it points at ($2).
    The server ANSWERED — not a network fault. A REBUILT cluster mints a new CA while the address
    stays the same. Re-fetch it: $3" ;;
    UNAUTHORIZED) block "the $1 cluster REJECTED this kubeconfig's credentials ($2) — expired, or
    from a cluster that no longer exists. Re-authenticate: $3" ;;
    FORBIDDEN)    block "authenticated to the $1 cluster, but this identity may not read it ($2).
    That is an RBAC grant, not a broken kubeconfig — do NOT re-fetch it." ;;
    UNREACHABLE)  block "the $1 cluster never answered ($2). This is NOT evidence the kubeconfig is
    stale — check the address and that this box can route to it." ;;
    *)            block "the $1 cluster did not answer ($2), and the error is not one we classify:
$(sed 's/^/      /' "$_pf_err" | head -4)" ;;
  esac
}
# The VARIABLE NAME is the message — the operator needs to know WHICH kubeconfig to fix, so these
# stay single-quoted deliberately (expanding them would print the path and never the name).
# shellcheck disable=SC2016
kg version -o json >/dev/null 2>"$_pf_err" || _pf_classify GUEST  '$KUBECONFIG'        "make vks-login"
# shellcheck disable=SC2016
ka version -o json >/dev/null 2>"$_pf_err" || _pf_classify ARGOCD '$ARGOCD_KUBECONFIG' "make fetch-argocd-kubeconfig"
rm -f "$_pf_err"

OFF=0
if argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$KUBECONFIG" 2>/dev/null; then OFF=1; fi
if [ "$OFF" = 1 ]; then log_info "ArgoCD is OFF-CLUSTER (the real-lab shape)."
else                   log_info "ArgoCD is IN the workload cluster."; fi

# ---- 2. versions (asked on the ARGOCD cluster — that is where ArgoCD lives) ----------------------
echo "── ArgoCD version ──"
# Shared with the read-only `make argocd-version`. 15s: this is the GATE, so it wants headroom (the
# standalone peek uses the 3s default). Self-contained in lib/argocd.sh — no verdict state touched.
argocd_print_versions "$ARGOCD_KUBECONFIG" "$NS" 15s

# ---- 3. WHICH WRITE MECHANISM IS OPEN TO ME? ----------------------------------------------------
# The single most valuable thing a tenant can learn before spending 20 minutes on a mirror.
# `kubectl auth can-i` measures KUBERNETES RBAC in an ADMIN-owned namespace — the axis a tenant is
# EXPECTED to fail. In ArgoCD, `applications` and `repositories` are PROJECT-scoped RBAC resources,
# so a tenant's real grant is usually an AppProject role enforced by argocd-server, not by the API
# server. Report BOTH, and do not conclude "you cannot deploy" from the kubectl answer alone.
echo "── write mechanism ──"
ns_err="$(ka get ns "$NS" 2>&1 >/dev/null)"; ns_rc=$?
if [ "$ns_rc" != 0 ]; then
  if printf '%s' "$ns_err" | grep -qi forbidden; then
    warn "you may not even READ namespace '$NS' on the ArgoCD cluster (Forbidden) — a PERMISSION problem, not a missing install."
  elif [ "${ARGOCD_MECHANISM:-auto}" = kubectl ]; then
    # kubectl is the ONE write path that must read+write this namespace (70-configure-argocd.sh dies here
    # too for MECH=kubectl). For it, catching a NotFound BEFORE the 20-minute mirror is this preflight's
    # whole point — so this stays a hard block.
    block "namespace '$NS' not found on the ArgoCD cluster ($ARGOCD_API), and ARGOCD_MECHANISM=kubectl requires it. Wrong ARGOCD_NAMESPACE? On VKS the instance namespace is typically 'argocd-instance-N', not 'argocd'."
  elif [ "$ARGOCD_KUBECONFIG" = "$KUBECONFIG" ]; then
    # Defaulted to the GUEST. ArgoCD is a Supervisor Service on ANOTHER cluster, so NotFound is EXPECTED
    # and kubectl is NOT the tenant's write path (api/request is) — 70 continues here too. Do NOT block,
    # or `make install-all` dies before the mirror for exactly the tenant this scenario targets (C12).
    warn "namespace '$NS' not found on the ArgoCD cluster ($ARGOCD_API) — NORMAL for a tenant: ArgoCD is a Supervisor Service on a different cluster and ARGOCD_KUBECONFIG defaults to the GUEST. kubectl is not your write path; the api/request mechanism is. Continuing."
  else
    # ARGOCD_KUBECONFIG was set explicitly but the ns still isn't there — likely a wrong ARGOCD_NAMESPACE.
    # Still not fatal unless MECH=kubectl (handled above): api/request bypass kubectl. Warn, don't block.
    warn "namespace '$NS' not found on the ArgoCD cluster ($ARGOCD_API). Wrong ARGOCD_NAMESPACE? On VKS it's typically 'argocd-instance-N'. Not fatal for ARGOCD_MECHANISM=${ARGOCD_MECHANISM:-auto} (kubectl is not the write path); continuing."
  fi
fi
can_kubectl=0
# ⚠️ THE FLAGS ARE PASSED EXPLICITLY, not via ka(). k_can_i runs `kubectl "$@"`, so routing a
# ka() call through it would DROP --kubeconfig and silently probe the WRONG CLUSTER — a far worse
# failure than the one being fixed. Keep them here, where they are visible.
_r="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
        auth can-i create applications.argoproj.io -n "$NS")"
case "${_r%%|*}" in
  yes) can_kubectl=1
       log_info "kubectl  : YES — you may create Applications in ns/$NS (the Scenario 1 / KinD path)." ;;
  no)  log_info "kubectl  : no  — you may NOT create Applications in ns/$NS with kubectl." ;;
  # This is a REPORT, so it may legitimately say "could not determine" — but it must not print
  # "no", which is an answer about YOUR PERMISSIONS that nobody obtained.
  *)   log_info "kubectl  : COULD NOT DETERMINE (${_r#*|}) — the probe did not reach the cluster, so
             this is NOT a permissions answer. Fix the connection, then re-run." ;;
esac
can_api=unknown
if have argocd && [ -n "${ARGOCD_SERVER:-}" ] && [ -n "${ARGOCD_AUTH_TOKEN:-}" ]; then
  # ⚠️ `if argocd … ; then can_api=yes` FILED A DENIAL AS PERMITTED. Verified in upstream argo-cd
  # at the INSTALLED version v3.4.5: a refusal returns `&CanIResponse{Value:"no"}, nil` — a NIL
  # error — and the CLI does `CheckError(err); fmt.Println(response.Value)`, so it PRINTS "no" and
  # EXITS 0. The `>/dev/null` then discarded the only thing carrying the answer. Compare the
  # OUTPUT; rc alone says the RPC completed, never that you may.
  _ra="$(argocd_can_i create applications "${ARGOCD_PROJECT:-default}/*")"
  case "${_ra%%|*}" in
    yes) can_api=yes; log_info "argocd API: YES — argocd-server permits you to create Applications in project '${ARGOCD_PROJECT:-default}'." ;;
    no)  can_api=no;  log_info "argocd API: no  — argocd-server refuses (check your AppProject role)." ;;
    # ⚠️ NOT "refuses". argocd-server never saw the request, so an AppProject role is the wrong
    # remedy — that message sent operators to request a grant they already held.
    *)   can_api=unknown
         log_info "argocd API: COULD NOT DETERMINE (${_ra#*|}) — argocd-server never received the
             request, so this is NOT a permissions answer and an AppProject role will not fix it.
             If the reason is a trust anchor: make fetch-argocd-ca, then set ARGOCD_CA_FILE." ;;
  esac
else
  log_info "argocd API: not probed — set ARGOCD_SERVER + ARGOCD_AUTH_TOKEN (and install the argocd CLI) to test the tenant path."
fi
if [ "$can_kubectl" = 0 ] && [ "$can_api" != yes ]; then
  warn "NO write mechanism is confirmed. As a tenant, request an ArgoCD AppProject role permitting 'applications, create' — or ask for the Applications to be created for you."
fi

# A CREDENTIALED api tenant on a DEFAULTED (guest) kubeconfig who forgot the DESTINATION passes every
# check above (can_api=yes → no "no write mechanism" warn) yet `make gitops` will `die` at
# 70-configure-argocd.sh:150 — OFF=0 (in-cluster) + an unreadable ArgoCD ns + no destination means the
# default in-cluster destination is the SUPERVISOR, which it refuses. This warn is the EXACT mirror of
# that guard (OFF=0 && ns-unreadable && no dest). The OFF=1 case is section 4 below (and 70's off-cluster
# path) — must NOT be included here, or the Scenario-1 ADMIN (OFF=1, dest auto-derived by
# 71-argocd-register-guest) gets a false "gitops will REFUSE" warning.
if [ "$OFF" = 0 ] && [ "$ns_rc" != 0 ] && [ -z "${ARGOCD_DEST_SERVER:-}${ARGOCD_DEST_CLUSTER_NAME:-}" ]; then
  warn "no deploy destination set: 'make gitops' will REFUSE (the default in-cluster destination is the Supervisor). Set ARGOCD_DEST_SERVER to your GUEST cluster's API URL — and have your guest REGISTERED as an ArgoCD destination (admin-only; see below)."
fi

# ---- 4. is the guest a REGISTERED destination, unambiguously? ------------------------------------
if [ "$OFF" = 1 ]; then
  echo "── deploy destination ──"
  REGISTERED="$(ka -n "$NS" get secret -l argocd.argoproj.io/secret-type=cluster \
    -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>/dev/null || true)"
  if [ -z "$REGISTERED" ]; then
    warn "no guest cluster is registered with this ArgoCD (or you may not list its Secrets). Registration is ADMIN-only: 'make argocd-register-guest', or REQUEST it."
  else
    log_info "clusters registered with this ArgoCD:"
    printf '%s\n' "$REGISTERED" | while IFS="$(printf '\t')" read -r n s; do
      [ -n "${s:-}" ] && log_info "    - ${n}: ${s}"
    done
    dest="$(printf '%s\n' "$REGISTERED" | argocd_pick_dest_server "$GUEST_API" "${ARGOCD_DEST_CLUSTER_NAME:-}" || true)"
    if [ -n "$dest" ]; then
      log_info "your guest resolves UNAMBIGUOUSLY to: $dest"
    else
      block "AMBIGUOUS destination — several clusters are registered and none matches yours by name or API URL. Set ARGOCD_DEST_CLUSTER_NAME (or ARGOCD_DEST_SERVER). Guessing could deploy your app into ANOTHER TENANT'S cluster (the Application carries prune+selfHeal)."
    fi
  fi
fi

# ---- 5. does the AppProject actually PERMIT it, per app? -----------------------------------------
# This is the #1 way a tenant's `make gitops` dies at the very END — the Application is created and
# then rejected with "application destination ... is not permitted in project". Nothing checked it;
# the README just told the operator to arrange it by hand.
PROJ="${ARGOCD_PROJECT:-default}"
echo "── AppProject '$PROJ' ──"
if ! ka -n "$NS" get appproject "$PROJ" >/dev/null 2>&1; then
  if [ "$PROJ" = default ]; then
    log_info "cannot read AppProject 'default' (fine — it belongs to the ArgoCD admin)."
  else
    warn "AppProject '$PROJ' is not readable in ns/$NS — ask your platform team to confirm it exists and permits your apps."
  fi
elif ! have jq; then
  log_warn "jq not installed — skipping the AppProject permission check."
else
  dest_server="${ARGOCD_DEST_SERVER:-${dest:-$ARGOCD_INCLUSTER_SERVER}}"
  pj="$(ka -n "$NS" get appproject "$PROJ" -o json 2>/dev/null || echo '{}')"
  while read -r app; do
    [ -n "$app" ] || continue
    # Same rule: before `make platform` the clone URL is not known. Checking the cluster-local
    # fallback would BLOCK on a repo the admin was never asked to permit.
    [ -n "${GITEA_ARGOCD_URL_OVERRIDE:-}" ] || { log_info "  ${app}: repo check deferred (the clone URL is resolved at 'make gitops')"; continue; }
    repo="${GITEA_ARGOCD_URL_OVERRIDE}/${GITEA_ORG:-demo}/${app}-deploy.git"
    ok_dest="$(printf '%s' "$pj" | jq -r --arg s "$dest_server" --arg n "$app" \
      '[.spec.destinations[]? | select((.server==$s or .server=="*") and (.namespace==$n or .namespace=="*"))] | length' 2>/dev/null || echo 0)"
    ok_repo="$(printf '%s' "$pj" | jq -r --arg r "$repo" \
      '[.spec.sourceRepos[]? | select(. == $r or . == "*")] | length' 2>/dev/null || echo 0)"
    if [ "${ok_dest:-0}" -gt 0 ] && [ "${ok_repo:-0}" -gt 0 ]; then
      log_info "  ${app}: destination + repo are permitted"
    else
      [ "${ok_dest:-0}" -gt 0 ] || block "AppProject '$PROJ' does NOT permit destination {server: $dest_server, namespace: $app} — ask the ArgoCD admin to add it to spec.destinations"
      [ "${ok_repo:-0}" -gt 0 ] || block "AppProject '$PROJ' does NOT permit repo $repo — ask the ArgoCD admin to add it to spec.sourceRepos"
    fi
  done <<EOF
$(app_names)
EOF
fi

# ---- 6. can ArgoCD's repo-server even REACH Gitea? -----------------------------------------------
echo "── Gitea reachability (from the ArgoCD cluster) ──"
# A PREFLIGHT MAY ONLY BLOCK ON WHAT THE OPERATOR CAN FIX RIGHT NOW.
#
# The clone URL is RESOLVED from the live Gitea Service by 70-configure-argocd.sh (`make gitops`) — and
# `make preflight` is the FIRST prerequisite of `make install-all`. So on a real lab it is legitimately
# UNSET here. Blocking on the fallback (the cluster-local GITEA_INTERNAL_URL) made `make install-all`
# — the single command both runbooks tell the operator to run — die BEFORE THE MIRROR, demanding they
# fix a value that CANNOT EXIST YET. Invisible on KinD (there ArgoCD is in-cluster, so OFF=0 and this
# whole section is skipped).
#
#   unset                       -> WARN  (70-configure-argocd.sh asserts it at the point of USE)
#   SET to a cluster-local value-> BLOCK (that IS something the operator can fix now)
if [ "$OFF" = 1 ] && [ -n "${GITEA_ARGOCD_URL_OVERRIDE:-}" ] && argocd_url_is_cluster_local "$GITEA_ARGOCD_URL_OVERRIDE"; then
  block "GITEA_ARGOCD_URL_OVERRIDE is a CLUSTER-LOCAL address ($GITEA_ARGOCD_URL_OVERRIDE). An off-cluster repo-server cannot resolve it, and the ingress hostname will not work either (it exists only in your /etc/hosts). Use Gitea's own LoadBalancer address, or leave it unset and let 'make gitops' resolve it from the live Service."
elif [ "$OFF" = 1 ]; then
  log_info "ArgoCD's clone URL is RESOLVED from Gitea's live Service by 'make gitops' — nothing to set."
  log_info "  Override it only if that address is not reachable from the ArgoCD cluster: GITEA_ARGOCD_URL_OVERRIDE."
else
  log_info "ArgoCD would clone from: ${GITEA_ARGOCD_URL_OVERRIDE:-${GITEA_INTERNAL_URL:-<resolved at gitops>}}"
fi

# ---- 7. app namespaces on the GUEST (one per app) ------------------------------------------------
echo "── app namespaces (guest) ──"
while read -r app; do
  [ -n "$app" ] || continue
  if kg get ns "$app" >/dev/null 2>&1; then
    log_info "  ${app}: exists"
  else
    log_info "  ${app}: absent (make gitops creates it, PSA-labelled)"
  fi
done <<EOF
$(app_names)
EOF

# ---- verdict ------------------------------------------------------------------------------------
echo "── verdict ──"
if [ "$blocking" != 0 ]; then
  log_error "PREFLIGHT FAILED — fix the BLOCKING item(s) above BEFORE 'make install-all'. They will not fix themselves after a 20-minute mirror."
  exit 1
fi
[ "$warned" -gt 0 ] && log_warn "preflight passed with ${warned} warning(s) — read them if you are a tenant."
log_info "PREFLIGHT OK — clusters answer, the destination is unambiguous, and the project permits your apps."
exit 0
