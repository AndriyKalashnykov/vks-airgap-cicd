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
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

require_cmd kubectl
: "${KUBECONFIG:?KUBECONFIG must be set (path to the GUEST/workload-cluster kubeconfig)}"; export KUBECONFIG

NS="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"
VKS_ARGOCD_CRD="argocds.argocd-service.vsphere.vmware.com"
blocking=0
warned=0
dest=""

# ka = the cluster ArgoCD RUNS IN. kg = the GUEST/workload cluster. On KinD they are the same file.
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" "$@"; }
kg() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
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
kg version -o json >/dev/null 2>&1 || block "the GUEST cluster does not answer (\$KUBECONFIG)"
ka version -o json >/dev/null 2>&1 || block "the ARGOCD cluster does not answer (\$ARGOCD_KUBECONFIG)"

OFF=0
if argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$KUBECONFIG" 2>/dev/null; then OFF=1; fi
if [ "$OFF" = 1 ]; then log_info "ArgoCD is OFF-CLUSTER (the real-lab shape)."
else                   log_info "ArgoCD is IN the workload cluster."; fi

# ---- 2. versions (asked on the ARGOCD cluster — that is where ArgoCD lives) ----------------------
echo "── ArgoCD version ──"
if have argocd; then
  log_info "argocd CLI (client): $(argocd version --client --short 2>/dev/null || echo unknown)"
else
  log_warn "argocd CLI not on PATH — it is REQUIRED on the tenant path (argocd-server is the only writer a tenant may have)."
fi
if ka get crd "$VKS_ARGOCD_CRD" >/dev/null 2>&1; then
  log_info "VKS ArgoCD operator present. Supported server versions:"
  ka explain argocd.spec.version 2>/dev/null | sed 's/^/    /'
  ka get argocd -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VERSION:.spec.version' 2>/dev/null | sed 's/^/    /'
else
  log_info "no VKS ArgoCD operator CRD on the ArgoCD cluster — upstream ArgoCD (the KinD stand-in), or you are a tenant who may not read CRDs."
fi
img="$(ka -n "$NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$img" ]; then
  log_info "RUNNING argocd-server image: $img"
  log_info "  (the CLI's version is NOT the server's — the lab pins a 2.x server while the KinD stand-in runs 3.x)"
else
  log_warn "cannot read the argocd-server Deployment in ns/$NS — ArgoCD is elsewhere, or you may not read it (tenant)."
fi
log_info "this repo's KinD pin: ARGOCD_VERSION=${ARGOCD_VERSION:-?}"

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
  else
    block "namespace '$NS' not found on the ArgoCD cluster ($ARGOCD_API). Wrong ARGOCD_NAMESPACE? On VKS the instance namespace is typically 'argocd-instance-N', not 'argocd'."
  fi
fi
can_kubectl=0
if [ "$(ka auth can-i create applications.argoproj.io -n "$NS" 2>/dev/null || echo no)" = yes ]; then
  can_kubectl=1
  log_info "kubectl  : YES — you may create Applications in ns/$NS (the Scenario 1 / KinD path)."
else
  log_info "kubectl  : no  — you may NOT create Applications in ns/$NS with kubectl."
fi
can_api=unknown
if have argocd && [ -n "${ARGOCD_SERVER:-}" ] && [ -n "${ARGOCD_AUTH_TOKEN:-}" ]; then
  if argocd account can-i create applications "${ARGOCD_PROJECT:-default}/*" >/dev/null 2>&1; then
    can_api=yes; log_info "argocd API: YES — argocd-server permits you to create Applications in project '${ARGOCD_PROJECT:-default}'."
  else
    can_api=no;  log_info "argocd API: no  — argocd-server refuses (check your AppProject role)."
  fi
else
  log_info "argocd API: not probed — set ARGOCD_SERVER + ARGOCD_AUTH_TOKEN (and install the argocd CLI) to test the tenant path."
fi
if [ "$can_kubectl" = 0 ] && [ "$can_api" != yes ]; then
  warn "NO write mechanism is confirmed. As a tenant, request an ArgoCD AppProject role permitting 'applications, create' — or ask for the Applications to be created for you."
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
    [ -n "${GITEA_ARGOCD_URL:-}" ] || { log_info "  ${app}: repo check deferred (GITEA_ARGOCD_URL not discovered yet)"; continue; }
    repo="${GITEA_ARGOCD_URL}/${GITEA_ORG:-demo}/${app}-deploy.git"
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
# GITEA_ARGOCD_URL is DISCOVERED by 40-install-gitea.sh, which runs inside `make platform` — and
# `make preflight` is the FIRST prerequisite of `make install-all`. So on a real lab it is legitimately
# UNSET here. Blocking on the fallback (the cluster-local GITEA_INTERNAL_URL) made `make install-all`
# — the single command both runbooks tell the operator to run — die BEFORE THE MIRROR, demanding they
# fix a value that CANNOT EXIST YET. Invisible on KinD (there ArgoCD is in-cluster, so OFF=0 and this
# whole section is skipped).
#
#   unset                       -> WARN  (70-configure-argocd.sh asserts it at the point of USE)
#   SET to a cluster-local value-> BLOCK (that IS something the operator can fix now)
if [ "$OFF" = 1 ] && [ -n "${GITEA_ARGOCD_URL:-}" ] && argocd_url_is_cluster_local "$GITEA_ARGOCD_URL"; then
  block "GITEA_ARGOCD_URL is SET to a CLUSTER-LOCAL address ($GITEA_ARGOCD_URL). An off-cluster repo-server cannot resolve it, and the ingress hostname will not work either (it exists only in your /etc/hosts). Use Gitea's own LoadBalancer address."
elif [ "$OFF" = 1 ]; then
  log_info "GITEA_ARGOCD_URL not discovered yet — 'make install-gitea' (inside 'make platform') publishes it."
  log_info "  'make gitops' re-asserts it at the point of use, so it is not a blocker now."
else
  log_info "ArgoCD would clone from: ${GITEA_ARGOCD_URL:-${GITEA_INTERNAL_URL:-<unset>}}"
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
