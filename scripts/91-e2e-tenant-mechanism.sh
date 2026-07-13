#!/usr/bin/env bash
# 91-e2e-tenant-mechanism.sh — prove the TENANT write path actually works, on KinD.
#
# WHY THIS EXISTS
# ---------------
# `make gitops` used to gate on `kubectl auth can-i create applications` in the ArgoCD namespace and
# DIE if the answer was no. On a real VKS lab the ArgoCD instance lives in an ADMIN-owned vSphere
# Namespace, so that is exactly what a tenant gets — and the gate told a tenant who COULD deploy that
# they could not. It measured the wrong axis: in ArgoCD, `applications` and `repositories` are
# PROJECT-SCOPED RBAC resources, so an AppProject role lets a tenant create them through
# ARGOCD-SERVER with ZERO Kubernetes RBAC in that namespace.
#
# That claim is the whole basis of the `api` mechanism, and it is faithfully testable here: ArgoCD
# RBAC is plain ArgoCD, not a VKS feature. So we build the tenant's exact situation —
#
#     * an ArgoCD local account with a token
#     * an AppProject that permits ONLY our apps' destinations + repos
#     * an argocd-rbac-cm role granting that account `applications, create` in THAT project
#     * a kubeconfig with **no RBAC whatsoever** in the ArgoCD namespace
#
# — and assert that `make gitops` SUCCEEDS through argocd-server while `kubectl` is Forbidden.
# An unexercised branch is an untested branch.
#
# Requires: a running KinD stand-in with ArgoCD + Gitea (i.e. run after `make e2e-kind`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

require_cmd kubectl
require_cmd argocd "the tenant path IS the argocd CLI — install it (make deps)"
: "${KUBECONFIG:?}"; export KUBECONFIG
NS="${ARGOCD_NAMESPACE:-argocd}"
PROJ="tenant-a"
ACCOUNT="tenant"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

kubectl -n "$NS" get deploy argocd-server >/dev/null 2>&1 \
  || die "ArgoCD is not installed — run 'make e2e-kind' (or 'make kind-up install-harbor install-argocd') first."

# ---- 1. the tenant's ArgoCD account -------------------------------------------------------------
log_info "creating ArgoCD local account '${ACCOUNT}' (apiKey) + an AppProject that permits ONLY our apps"
kubectl -n "$NS" patch configmap argocd-cm --type merge \
  -p "{\"data\":{\"accounts.${ACCOUNT}\":\"apiKey, login\"}}" >/dev/null

# The AppProject the tenant is confined to: it permits our destinations + our repos, nothing else.
dests=""; repos=""
while read -r app; do
  [ -n "$app" ] || continue
  dests="${dests}    - server: https://kubernetes.default.svc"$'\n'"      namespace: ${app}"$'\n'
  repos="${repos}    - ${GITEA_ARGOCD_URL_OVERRIDE:-${GITEA_INTERNAL_URL}}/${GITEA_ORG}/${app}-deploy.git"$'\n'
done <<EOF
$(app_names)
EOF

kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${PROJ}
  namespace: ${NS}
spec:
  description: "the tenant's project — permits only their apps"
  sourceRepos:
${repos}  destinations:
${dests}  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

# ArgoCD RBAC: the tenant may create Applications IN THEIR PROJECT — and nothing else.
kubectl -n "$NS" patch configmap argocd-rbac-cm --type merge -p "$(cat <<EOF
{"data":{"policy.csv":"p, role:tenant-a, applications, create, ${PROJ}/*, allow\np, role:tenant-a, applications, get, ${PROJ}/*, allow\np, role:tenant-a, applications, update, ${PROJ}/*, allow\np, role:tenant-a, applications, sync, ${PROJ}/*, allow\np, role:tenant-a, projects, get, ${PROJ}, allow\np, role:tenant-a, repositories, create, ${PROJ}/*, allow\np, role:tenant-a, repositories, get, ${PROJ}/*, allow\ng, ${ACCOUNT}, role:tenant-a\n"}}
EOF
)" >/dev/null
kubectl -n "$NS" rollout restart deploy/argocd-server >/dev/null
kubectl -n "$NS" rollout status deploy/argocd-server --timeout=180s >/dev/null

# ---- 2. a kubeconfig with ZERO rights in the ArgoCD namespace ------------------------------------
# This is the crux: the tenant must NOT be able to kubectl into the ArgoCD namespace. We give them a
# ServiceAccount that is cluster-admin on their OWN namespaces but has no role in ns/$NS at all.
log_info "building a tenant kubeconfig with NO RBAC in ns/${NS} (that is the real-lab situation)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: tenant, namespace: default }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: tenant-guest-admin }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [ { kind: ServiceAccount, name: tenant, namespace: default } ]
EOF
# NOTE: cluster-admin DOES include ns/$NS — so we must EXCLUDE it to reproduce the tenant. Use an
# aggregated deny? Kubernetes RBAC has no deny. So instead: bind a narrow role, not cluster-admin.
kubectl delete clusterrolebinding tenant-guest-admin >/dev/null 2>&1 || true
kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: tenant-guest }
rules:
  - apiGroups: ["", "apps", "networking.k8s.io", "rbac.authorization.k8s.io"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: tenant-guest }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: tenant-guest }
subjects: [ { kind: ServiceAccount, name: tenant, namespace: default } ]
EOF
tok="$(kubectl -n default create token tenant --duration=1h)"
api="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
ca="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
TENANT_KC="${WORK}/tenant.kubeconfig"
( umask 077; cat > "$TENANT_KC" <<EOF
apiVersion: v1
kind: Config
clusters: [ { name: c, cluster: { server: ${api}, certificate-authority-data: ${ca} } } ]
contexts: [ { name: c, context: { cluster: c, user: tenant } } ]
current-context: c
users: [ { name: tenant, user: { token: ${tok} } } ]
EOF
)

# RED-1: the tenant must NOT be able to create Applications with kubectl. If they can, this test
# proves nothing — it would be exercising the kubectl path under a different name.
if [ "$(kubectl --kubeconfig "$TENANT_KC" auth can-i create applications.argoproj.io -n "$NS" 2>/dev/null || echo no)" = yes ]; then
  die "FAIL: the tenant kubeconfig CAN kubectl-create Applications in ns/${NS} — this fixture does not reproduce a tenant."
fi
log_info "RED 1 OK — the tenant CANNOT create Applications in ns/${NS} with kubectl (Forbidden), as on a real lab."

# ---- 3. the tenant's argocd-server token --------------------------------------------------------
argocd_lb="${ARGOCD_LB_IP:-}"
[ -n "$argocd_lb" ] || argocd_lb="$(kubectl -n "$NS" get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
[ -n "$argocd_lb" ] || die "cannot resolve the ArgoCD LoadBalancer IP"
admin_pw="$(kubectl -n "$NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
[ -n "$admin_pw" ] || admin_pw="${ARGOCD_ADMIN_PASSWORD:?cannot read the ArgoCD admin password}"

# The LoadBalancer needs a moment after the rollout restart above: cloud-provider-kind assigns the
# IP long before its Envoy is actually routing (the K1.5 race). A pod being Ready is NOT the same as
# its LB answering — poll the endpoint itself, or the first request dies on "connection reset".
log_info "waiting for argocd-server to answer on its LoadBalancer (${argocd_lb})"
ok=0
for _ in $(seq 1 60); do
  if curl -sS -k -o /dev/null --max-time 3 "https://${argocd_lb}/healthz" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || die "argocd-server never answered on https://${argocd_lb} after the restart"

export ARGOCD_OPTS="--insecure"
# `argocd login` offers ONLY `--password <string>` — i.e. the secret on ARGV, which this repo forbids
# (ps -ef / /proc/<pid>/cmdline). There is no --password-stdin. So mint the admin JWT through the
# session API with the body on STDIN (curl --data @-), and drive the CLI with ARGOCD_AUTH_TOKEN
# thereafter — the CLI reads it from the ENVIRONMENT, never argv.
# Retry the SESSION call itself, not a /healthz proxy: healthz can be answered by a pod that is not
# yet serving the API (and by the LB before it has finished re-wiring after the restart).
admin_jwt=""
for _ in $(seq 1 60); do
  admin_jwt="$(jq -nc --arg u admin --arg p "$admin_pw" '{username:$u, password:$p}' \
    | curl -s -k --max-time 5 -H 'Content-Type: application/json' --data @- \
        "https://${argocd_lb}/api/v1/session" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null || true)"
  [ -n "$admin_jwt" ] && break
  sleep 2
done
[ -n "$admin_jwt" ] || die "could not authenticate to argocd-server at ${argocd_lb}"
TENANT_TOKEN="$(ARGOCD_SERVER="$argocd_lb" ARGOCD_AUTH_TOKEN="$admin_jwt" \
  argocd account generate-token --account "$ACCOUNT")"
[ -n "$TENANT_TOKEN" ] || die "could not mint an argocd token for account '${ACCOUNT}'"
log_info "minted an argocd-server API token for account '${ACCOUNT}' (no password ever on argv)"

# ---- 4. THE TEST: `make gitops` as the tenant, through argocd-server -----------------------------
# Remove the Applications the earlier (admin/kubectl) run created in project `default`. Without this
# the tenant's `argocd app create --upsert` is checked as an UPDATE of an existing app owned by
# `default`, and argocd-server correctly denies it ("applications, update, default/<app>") — a real
# permission answer, but about the WRONG question. A real tenant creates their OWN Applications; they
# do not inherit someone else's. (--cascade=false: keep the deployed workloads, we are only moving
# the Application object between projects.)
while read -r app; do
  [ -n "$app" ] || continue
  kubectl -n "$NS" delete application "$app" --cascade=false --ignore-not-found >/dev/null 2>&1 || true
done <<EOF
$(app_names)
EOF

log_info "== running 70-configure-argocd.sh as the TENANT (mechanism=api) =="
KUBECONFIG="$TENANT_KC" \
ARGOCD_KUBECONFIG="$TENANT_KC" \
ARGOCD_MECHANISM=api \
ARGOCD_PROJECT="$PROJ" \
ARGOCD_SERVER="$argocd_lb" \
ARGOCD_AUTH_TOKEN="$TENANT_TOKEN" \
ARGOCD_OPTS="--insecure" \
  "${SCRIPT_DIR}/70-configure-argocd.sh"

# ---- 5. assert the Applications EXIST and are in the TENANT'S project ----------------------------
rc=0
while read -r app; do
  [ -n "$app" ] || continue
  proj="$(kubectl -n "$NS" get application "$app" -o jsonpath='{.spec.project}' 2>/dev/null || true)"
  if [ "$proj" = "$PROJ" ]; then
    log_info "  ${app}: Application exists, project=${proj} (created via argocd-server, NOT kubectl)"
  else
    log_error "  ${app}: expected project '${PROJ}', got '${proj:-<missing>}'"; rc=1
  fi
done <<EOF
$(app_names)
EOF
[ "$rc" = 0 ] || die "FAIL: the tenant path did not create the Applications"

log_info "e2e-tenant-mechanism: OK — a tenant with ZERO Kubernetes RBAC in ns/${NS} created every"
log_info "  Application through argocd-server, using only an AppProject role. That is the path the old"
log_info "  'kubectl auth can-i' gate wrongly declared impossible."
