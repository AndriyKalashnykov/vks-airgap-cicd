#!/usr/bin/env bash
# 71-argocd-register-guest.sh — register the GUEST/workload cluster as a destination with an
# ArgoCD instance that runs in a DIFFERENT cluster (the real-lab case: ArgoCD is a Supervisor
# Service on the Supervisor; javawebapp must deploy into the guest cluster).
#
# It does NOT install a second ArgoCD in the guest — it only:
#   1. GUEST cluster: creates an `argocd-manager` ServiceAccount + a cluster-admin binding
#      + a NON-EXPIRING (legacy) token Secret. The durable token sidesteps the x509
#      client-cert #13175 trap (an x509-auth guest kubeconfig would otherwise make ArgoCD
#      store an EXPIRING cert → cluster goes Unknown). See the argocd-cross-cluster memory.
#   2. ArgoCD cluster: creates the ArgoCD `Cluster` Secret (label secret-type=cluster) in
#      ARGOCD_NAMESPACE, carrying the guest API URL + CA + the durable bearer token.
#   3. Publishes ARGOCD_DEST_SERVER (the guest API URL) so `make gitops` targets the guest.
#
# Registering a cluster is an ArgoCD-ADMIN operation (research-confirmed: `clusters` is a global
# ArgoCD RBAC resource, and minting the cluster-admin argocd-manager RBAC needs cluster-admin on
# the guest). A pure VKS tenant cannot self-service this — they request it from the platform team.
#
# Secrets never touch argv: the token/CA are embedded in manifests applied over STDIN.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⚠️ SNAPSHOT BEFORE load_env — this toggle registers a destination with TLS verification OFF, and
# the choice PERSISTS in the ArgoCD Cluster Secret, so it is the one weakening toggle that is never
# legitimate as standing config. `load_env` sources `.env.example` then `.env` with `set -a` AFTER
# the caller's environment is established, so a `.env` line WINS over a per-run override — and for
# this variable that is a RATCHET: once `.env` says 1 there is no per-run way back, because
# `ARGOCD_REGISTER_INSECURE=0 make gitops` loses to the same `set -a`. MEASURED (idea round,
# 2026-08-19), all three arms against the real `load_env`:
#     .env=1, caller=0        -> 1  insecure, and unreachable by any override   *** the ratchet ***
#     .env=1, caller silent   -> 1  insecure, silently
#     no .env, caller=1       -> 1  the e2e prefix, which must keep working
# Honouring ONLY the pre-`load_env` environment closes all three: the first two become 0, the third
# is unchanged. `scripts/e2e-cross-cluster.sh:72` sets it as a direct command prefix on this script
# (no make, no wrapper, no `env -i`), so it lands here BEFORE this line and still wins — that arm is
# pinned by `test-argocd-register-insecure.sh` precisely so a "fix" that hardcodes 0 cannot pass.
# Same pattern as `creds.sh`'s and `argocd-password.sh`'s `SHOW_SECRETS` and `24-lab-preflight.sh`'s
# `CA_STATUS_STRICT`. Unlike those, this one IS documented in `.env.example` — so the commented line
# there states the invocation form and that a value in `.env` is ignored by design.
_argocd_register_insecure_snapshot="${ARGOCD_REGISTER_INSECURE:-0}"

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# The file channel is DELIBERATELY inert for this variable — but say so, or an operator who set it in
# `.env` sees the run quietly do the opposite and has nothing to grep for. Do not phrase this as an
# error: the ignore is the intended behaviour, and the remedy is a different invocation, not a fix.
if [ "${ARGOCD_REGISTER_INSECURE:-0}" = "1" ] && [ "$_argocd_register_insecure_snapshot" != "1" ]; then
  log_warn "ARGOCD_REGISTER_INSECURE=1 came from .env/.env.example and is IGNORED BY DESIGN —"
  log_warn "  it disables TLS verification PERMANENTLY in the ArgoCD Cluster Secret, so it is honoured"
  log_warn "  only as a per-run prefix: ARGOCD_REGISTER_INSECURE=1 ${0##*/}"
fi
ARGOCD_REGISTER_INSECURE="$_argocd_register_insecure_snapshot"

require_cmd kubectl "install kubectl (make deps)"

# --- inputs ------------------------------------------------------------------
# KUBECONFIG        : the workload cluster where the apps deploy. THE ONLY name for it.
# ARGOCD_KUBECONFIG : the cluster the ArgoCD instance runs in (the Supervisor / the e2e ArgoCD box).
#
# GUEST_KUBECONFIG (an operator-settable override that defaulted to $KUBECONFIG) was REMOVED
# 2026-08-24. MEASURED: it NEVER diverged anywhere in the tree -- even e2e-cross-cluster.sh set
# BOTH to the same value, and the thing that actually differs there is ARGOCD_KUBECONFIG. It was
# one concept with two names, and it was WORSE than a harmless alias: only THIS script honoured it,
# while its siblings (67-72) use ambient $KUBECONFIG. So an operator who set it differently got a
# SPLIT-BRAIN GUEST -- this script registering cluster X with ArgoCD while everything else deployed
# to cluster Y, silently, because both are valid kubeconfigs. One name removes that by construction.
_guest_kc="${KUBECONFIG:?KUBECONFIG (guest cluster) must be set}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"
: "${ARGOCD_NAMESPACE:?ARGOCD_NAMESPACE must be set (namespace the ArgoCD instance watches)}"

# ---- IS REGISTRATION EVEN NEEDED? DERIVE IT; DO NOT REMEMBER IT ----------------------------------
# `make gitops` used to force-run this whenever ARGOCD_KUBECONFIG was merely SET — which meant it
# minted a cluster-admin ClusterRoleBinding on the guest even when both kubeconfigs pointed at the
# SAME cluster (nothing to register), and it made the tenant path impossible: the README told tenants
# not to set ARGOCD_KUBECONFIG (registration is admin-only), but 70 NEEDS it to write the Application.
#
# ARGOCD_REGISTER=auto|never|force
#   auto  (default) — register only if ArgoCD is OFF-CLUSTER and the guest is not registered yet.
#   never           — a TENANT: registration is someone else's job. Skip, quietly.
#   force           — register even if it looks unnecessary.
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"
ARGOCD_REGISTER="${ARGOCD_REGISTER:-auto}"

if [ "$ARGOCD_REGISTER" = never ]; then
  log_info "ARGOCD_REGISTER=never — skipping guest-cluster registration (a tenant REQUESTS it from the platform team)."
  exit 0
fi
if [ "$ARGOCD_REGISTER" != force ]; then
  # NO `2>/dev/null` HERE. argocd_is_off_cluster DIES (lib/argocd.sh: "could not read the guest
  # cluster's API server from …") when a kubeconfig is unreadable, and `die` writes to STDERR and
  # exits — so the redirect destroyed the only explanation and this target failed with a bare
  # `make: *** [argocd-register-guest] Error 1` and nothing else. MEASURED 2026-08-12, walk block
  # [27], both rows. kubectl's own noise is already redirected inside argocd_api_server, so there is
  # nothing left here for the redirect to suppress except the diagnostic.
  if ! argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$_guest_kc"; then
    log_info "ArgoCD runs in the SAME cluster as the workload — nothing to register."
    exit 0
  fi
  guest_api="$(argocd_api_server "$_guest_kc")"
  already="$(kubectl --kubeconfig "$ARGOCD_KUBECONFIG" -n "$ARGOCD_NAMESPACE" \
      get secret -l argocd.argoproj.io/secret-type=cluster \
      -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>/dev/null \
    | argocd_pick_dest_server "$guest_api" "${ARGOCD_DEST_CLUSTER_NAME:-}" || true)"
  if [ -n "$already" ]; then
    # NAME WHAT MATCHED, AND WHEN. This used to print only $already — which is the server URL the
    # operator just supplied — so the message could not distinguish "our registration, minted four
    # minutes ago" from "a registration from three labs ago". A guest REBUILT at the same API
    # address keeps that address, so the by-server match still fires while the stored bearer token
    # and CA are dead; the Application then never syncs and `make verify` reports "ArgoCD did not
    # roll a new image", which names nothing near the cause.
    #
    # A SEPARATE `kubectl get`, NOT a third column on ARGOCD_CLUSTER_LIST_TEMPLATE. Measured: adding
    # one makes `IFS=$'\t' read -r n s` put the remainder INCLUDING THE TAB into $s, so the server
    # comparison in argocd_pick_dest_server can never match, the count==1 fallback is blocked too,
    # and 70-configure-argocd.sh then dies "AMBIGUOUS deploy destination — refusing to guess" on
    # EVERY run. test-argocd-topology.sh cannot catch that: its fixtures are hand-written
    # two-column strings. Do not touch the shared template.
    # Mirrors the PROVEN syntax of ARGOCD_CLUSTER_LIST_TEMPLATE (lib/argocd.sh:77) rather than
    # inventing one: `.data.server | base64decode`, not `index .data "server"`.
    _reg_detail="$(kubectl --kubeconfig "$ARGOCD_KUBECONFIG" -n "$ARGOCD_NAMESPACE" \
        get secret -l argocd.argoproj.io/secret-type=cluster \
        -o go-template='{{range .items}}{{.data.server | base64decode}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{.metadata.creationTimestamp}}{{"\n"}}{{end}}' \
        2>/dev/null | awk -F'\t' -v s="$already" '$1 == s {print; exit}' || true)"
    log_info "the guest cluster is ALREADY registered with this ArgoCD ($already) — nothing to do."
    if [ -n "$_reg_detail" ]; then
      log_info "  matched Secret: $(printf '%s' "$_reg_detail" | cut -f2)  (created $(printf '%s' "$_reg_detail" | cut -f3))"
      log_info "  If the guest was REBUILT since that timestamp, the stored token and CA are STALE and"
    else
      # The pick can land on a server we could not then re-read (RBAC narrowed mid-run, or the
      # count==1 fallback matched a Secret whose data.server differs from what was picked). Say
      # that, rather than printing "since that timestamp" with no timestamp above it.
      log_info "  (could not re-read the matching Secret to date it)"
      log_info "  If the guest was REBUILT since it was registered, the stored token and CA are STALE and"
    fi
    log_info "  the Application will never sync. Re-register with:"
    log_info "      make argocd-register-guest ARGOCD_REGISTER=force"
    exit 0
  fi
  # Registration mints a cluster-admin ClusterRoleBinding on the guest AND writes a Secret into the
  # ArgoCD namespace. A tenant can do neither. Say so plainly instead of failing with a stack of
  # Forbidden errors.
  # ⚠️ THE "ADMIN-ONLY" REMEDY IS CORRECT ONLY FOR A REAL DENIAL. On a transport failure the old
  # `!= yes` printed it anyway, sending the operator to request a grant they already held — and
  # then `exit 0`, so the guest silently stayed unregistered and the Application failed later with
  # a destination error pointing nowhere near the cause.
  _rs="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
          auth can-i create secrets -n "$ARGOCD_NAMESPACE")"
  if [ "${_rs%%|*}" = unknown ]; then
    die "cannot tell whether you may register the guest cluster: the probe never reached the ArgoCD
  cluster (${_rs#*|}). This is NOT a permissions problem, so asking your platform team for a grant
  will not fix it. Refusing to skip registration on a capability nobody measured."
  fi
  if [ "${_rs%%|*}" != yes ]; then
    log_warn "you may not create Secrets in ns/${ARGOCD_NAMESPACE} on the ArgoCD cluster — registration is ADMIN-only."
    log_warn "  REQUEST from your platform team: register guest cluster '$(kubectl --kubeconfig "$_guest_kc" config current-context 2>/dev/null || echo guest)' ($guest_api) as an ArgoCD destination."
    log_warn "  Then set ARGOCD_DEST_CLUSTER_NAME (the name they registered it under) and re-run 'make gitops'."
    log_warn "  Skipping registration (set ARGOCD_REGISTER=never to silence this)."
    exit 0
  fi
fi
ARGOCD_MANAGER_SA="${ARGOCD_MANAGER_SA:-argocd-manager}"
ARGOCD_MANAGER_NS="${ARGOCD_MANAGER_NS:-kube-system}"
[ -f "$_guest_kc" ]  || die "KUBECONFIG (guest cluster) not found: $_guest_kc"
[ -f "$ARGOCD_KUBECONFIG" ] || die "ARGOCD_KUBECONFIG not found: $ARGOCD_KUBECONFIG"

kg() { kubectl --kubeconfig "$_guest_kc" "$@"; }   # guest cluster
# --request-timeout matches the sibling wrapper in 23-argocd-preflight.sh: without it this probe
# hangs forever against a blackholed endpoint, and a classifier cannot help a probe that never returns.
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s "$@"; }  # ArgoCD cluster

# A stable name for the registered destination (the guest cluster's context name).
DEST_NAME="${ARGOCD_DEST_CLUSTER_NAME:-$(kg config current-context 2>/dev/null || echo guest)}"

log_info "registering guest '$DEST_NAME' with the ArgoCD instance in ns/$ARGOCD_NAMESPACE (ArgoCD cluster: $(ka config current-context 2>/dev/null || echo '?'))"
ka get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || die "ArgoCD namespace '$ARGOCD_NAMESPACE' not found on the ArgoCD cluster — is ArgoCD installed there?"

# --- 1. GUEST: argocd-manager SA + cluster-admin binding + durable token ------
log_info "guest: creating '$ARGOCD_MANAGER_SA' ServiceAccount + cluster-admin binding + durable token"
kg apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ARGOCD_MANAGER_SA}
  namespace: ${ARGOCD_MANAGER_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${ARGOCD_MANAGER_SA}-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${ARGOCD_MANAGER_SA}
    namespace: ${ARGOCD_MANAGER_NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${ARGOCD_MANAGER_SA}-token
  namespace: ${ARGOCD_MANAGER_NS}
  annotations:
    kubernetes.io/service-account.name: ${ARGOCD_MANAGER_SA}
type: kubernetes.io/service-account-token
EOF

# Wait for the token controller to populate the Secret (non-expiring legacy token).
for _ in $(seq 1 30); do
  TOKEN="$(kg -n "$ARGOCD_MANAGER_NS" get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
[ -n "${TOKEN:-}" ] || die "guest: the argocd-manager token Secret did not populate — check the SA token controller"

CA_DATA="$(kg -n "$ARGOCD_MANAGER_NS" get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"

# --- 2. resolve the guest API URL ArgoCD will dial ---------------------------
# GUEST_API_SERVER overrides (must be ROUTABLE from the ArgoCD cluster — on a real lab the guest
# control-plane VIP; in the two-KinD e2e the guest's --internal API on the shared kind network).
if [ -n "${GUEST_API_SERVER:-}" ]; then
  SERVER="$GUEST_API_SERVER"
else
  SERVER="$(kg config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
fi
[ -n "$SERVER" ] || die "could not resolve the guest API server URL — set GUEST_API_SERVER"
log_info "guest API server ArgoCD will dial: $SERVER"

# --- 3. ArgoCD cluster: create the destination Cluster Secret ----------------
# tlsClientConfig.caData present ⇒ verify TLS; absent ⇒ insecure (self-signed without a CA handy).
if [ "${ARGOCD_REGISTER_INSECURE:-0}" = "1" ]; then
  # Opt-in: skip TLS verify of the guest API (the two-KinD stand-in reaches the guest by raw IP,
  # which may not be in the API cert SAN — the guest-API TLS/CA specifics are a real-lab-only concern).
  #
  # ⚠️ THIS WARNS, and the sibling `else` arm below is why. Visibility used to be exactly BACKWARDS:
  # the ACCIDENTAL no-CA fallback warned, while this DELIBERATE opt-in was silent — even though this
  # one is the worse of the two, because the choice does not end with the run. It is written into the
  # ArgoCD Cluster Secret, so EVERY later sync to this destination dials the guest API with TLS
  # verification off. `.env.example` says "Never on a real lab", and `make env-init` is a verbatim
  # copy of that file, so an operator who armed it for the two-KinD e2e and left it there would
  # register a REAL lab insecurely with no output at all.
  log_warn "ARGOCD_REGISTER_INSECURE=1 — registering '${DEST_NAME}' with TLS verification OFF."
  log_warn "  This PERSISTS in the Cluster Secret: every future sync to this destination skips verify."
  log_warn "  Intended for the two-KinD stand-in only. On a real lab, unset it and supply the CA."
  TLS_CFG="\"tlsClientConfig\":{\"insecure\":true}"
elif [ -n "$CA_DATA" ]; then
  TLS_CFG="\"tlsClientConfig\":{\"caData\":\"${CA_DATA}\"}"
else
  log_warn "no CA in the SA token secret — registering with insecure TLS"
  TLS_CFG="\"tlsClientConfig\":{\"insecure\":true}"
fi
CONFIG_JSON="{\"bearerToken\":\"${TOKEN}\",${TLS_CFG}}"
SECRET_NAME="cluster-$(printf '%s' "$DEST_NAME" | tr -c 'a-z0-9-' '-' | cut -c1-40)"

# ⚠️ REFUSE TO OVERWRITE A REGISTRATION THAT IS NOT OURS. SECRET_NAME is DERIVED and LOSSY — it
# lowercases nothing, maps every non-[a-z0-9-] byte to '-', and TRUNCATES TO 40 CHARS, so it is not
# injective. Measured:
#     tenant-a-very-long-guest-cluster-name-number-one -> cluster-tenant-a-very-long-guest-cluster-name-nu
#     tenant-a-very-long-guest-cluster-name-number-two -> cluster-tenant-a-very-long-guest-cluster-name-nu
# Identical. `ka apply` on a collision would REPOINT ANOTHER TENANT'S registration at our cluster
# with our token, in a namespace measured to hold foreign registrations (one labelled
# nested-lab.local/managed-by) — and would stamp it with OUR owned-by label, so `make uninstall-all`
# would later DELETE it as if it were ours. Two destructive acts from one truncation.
if _existing_owner="$(ka -n "$ARGOCD_NAMESPACE" get secret "$SECRET_NAME" \
      -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>/dev/null)"; then
  if [ "$_existing_owner" != "vks-airgap-cicd" ]; then
    die "Cluster Secret '$SECRET_NAME' already exists in ns/$ARGOCD_NAMESPACE and is NOT ours
  (owned-by='${_existing_owner:-<no ownership label>}').

  Refusing to overwrite it. The Secret name is derived from the destination name and TRUNCATED to
  40 characters, so two different clusters can map to the same name. Overwriting would repoint
  someone else's ArgoCD destination at your cluster.

  Register under a distinct name instead:
      make argocd-register-guest ARGOCD_DEST_CLUSTER_NAME=<a-short-distinct-name>
  Or, if that Secret really is a leftover of yours, delete it first after confirming what it points at:
      kubectl --kubeconfig \$ARGOCD_KUBECONFIG -n $ARGOCD_NAMESPACE get secret $SECRET_NAME -o jsonpath='{.data.server}' | base64 -d"
  fi
fi

log_info "argocd: creating Cluster Secret '$SECRET_NAME' (secret-type=cluster) in ns/$ARGOCD_NAMESPACE"
# Manifest (with the token) goes over STDIN — never argv.
ka apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
    # ⚠️ THE OWNERSHIP STAMP 'make uninstall-all' SELECTS ON. Without it the teardown's Secret pass
    # matches nothing and LEAVES a cluster-registration Secret pointing at a cluster it just
    # deleted — in a SHARED namespace, where a stale registration is someone else's problem.
    # It is also the only thing distinguishing this Secret from another tool's: measured on a real
    # lab, the same namespace held a registration Secret labelled nested-lab.local/managed-by.
    vks-airgap-cicd.local/owned-by: vks-airgap-cicd
stringData:
  name: "${DEST_NAME}"
  server: "${SERVER}"
  config: '${CONFIG_JSON}'
EOF

# --- 4. publish ARGOCD_DEST_SERVER so `make gitops` targets the guest --------
# DELIBERATELY NOT PUBLISHED. 70-configure-argocd.sh RE-DERIVES the destination from the live ArgoCD
# Cluster Secrets and validates it against that list, so writing ARGOCD_DEST_SERVER here would be pure
# redundancy — plus a stale pointer that survives into the NEXT cluster, which is the publish-then-
# read-back trap this repo has already removed twice (INGRESS_LB_IP_OVERRIDE, GITEA_ARGOCD_URL).
# An operator who must force it has ARGOCD_DEST_SERVER as an explicit env override.
# ⚠️ THIS LINE USED TO CLAIM THE VALUE WAS "written to $(state_file)" — CONTRADICTING THE COMMENT
# DIRECTLY ABOVE IT, and it is false: there is no state_set in this file, and test-state-overlay
# gates that there never is. MEASURED 2026-08-08: after a successful registration, .env.state
# contained no ARGOCD_DEST_SERVER at all. An operator who greps for it concludes the registration
# failed and runs it again. Say what actually happened, and where the destination really comes from.
log_info "registered as '$DEST_NAME' ($SERVER)."
log_info "  Nothing was written to $(state_file) — 'make gitops' RE-DERIVES the destination from the"
log_info "  live ArgoCD Cluster Secrets, so it will pick this up with no further configuration."
log_info "verify: kubectl --kubeconfig \$ARGOCD_KUBECONFIG -n $ARGOCD_NAMESPACE get secret -l argocd.argoproj.io/secret-type=cluster"
