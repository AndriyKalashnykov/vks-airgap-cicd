#!/usr/bin/env bash
# 70-configure-argocd.sh — register each app's Gitea deploy repo with ArgoCD and create the ArgoCD
# Application that syncs <app>-deploy to the WORKLOAD cluster.
#
# TWO CLUSTERS, AND THEY ARE OFTEN NOT THE SAME ONE.
#   * The ARGOCD cluster  — where argocd-server + repo-server run, and where Applications and repo
#     Secrets must be created. On a real VKS lab ArgoCD is a Supervisor SERVICE: it runs ON THE
#     SUPERVISOR, not in your guest cluster. -> $ARGOCD_KUBECONFIG (defaults to $KUBECONFIG).
#   * The GUEST/workload cluster — where the app actually lands. -> $KUBECONFIG.
#
# This script used to apply EVERYTHING to $KUBECONFIG, i.e. the guest. On a real lab that cluster has
# no ArgoCD namespace at all, so `make gitops` died at its own namespace check with the misleading
# "is ArgoCD installed on this VKS cluster?" — the demo could never work off KinD. (71-argocd-
# register-guest.sh was already two-cluster aware; this script was not.)
#
# The repo Secret and the Application go to the ARGOCD cluster; the app NAMESPACE is prepared on the
# GUEST. Where they are the same cluster (KinD, ArgoCD-in-guest) both kubeconfigs are the same file
# and behaviour is byte-identical to before.
#
# Secrets never touch argv: the Gitea token is embedded in a manifest applied over STDIN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${ARGOCD_NAMESPACE:?}"
: "${ARGOCD_TRACK_BRANCH:?}"; : "${GITEA_INTERNAL_URL:?}"; : "${GITEA_ORG:?}"
: "${GITEA_CI_USER:?}"
# One ArgoCD Application PER APP, from the registry.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# ensure_namespace + PSA labelling (VKS enforces `restricted` by default; KinD enforces nothing).
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
# The two-cluster guards (off-cluster derivation + clonable-URL assertion) — pure, RED-tested offline.
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

# The AppProject the Applications belong to. `default` permits every destination and repo, which is
# right for KinD and for Scenario 1 (you installed ArgoCD; you are its admin). A TENANT is given
# their OWN AppProject, and an Application naming a project that does not permit their destination /
# their repo is REJECTED — so this must be settable. (It used to be hardcoded `default` in the
# manifest AND absent from the envsubst allowlist, i.e. not overridable even by editing the file.)
ARGOCD_PROJECT="${ARGOCD_PROJECT:-default}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"
[ -f "$ARGOCD_KUBECONFIG" ] || die "ARGOCD_KUBECONFIG not found: $ARGOCD_KUBECONFIG"

# The cluster ArgoCD RUNS IN. Guest-side work just uses the ambient kubectl ($KUBECONFIG).
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" "$@"; }

ARGOCD_API="$(argocd_api_server "$ARGOCD_KUBECONFIG")"
GUEST_API="$(argocd_api_server "$KUBECONFIG")"
if argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$KUBECONFIG"; then
  ARGOCD_OFF_CLUSTER=1
  log_info "ArgoCD is OFF-CLUSTER: ArgoCD=$ARGOCD_API  guest=$GUEST_API"
else
  ARGOCD_OFF_CLUSTER=0
  log_info "ArgoCD runs in the SAME cluster as the workload ($ARGOCD_API)"
fi

# ---- which Gitea URL can ARGOCD'S repo-server actually clone? (checked FIRST — no cluster needed) -
# GITEA_INTERNAL_URL (gitea-http.gitea.svc:3000) resolves ONLY inside the guest cluster. It is right
# for Tekton (which runs there) and WRONG for an off-cluster ArgoCD, whose repo-server would fail
# every sync with `dial tcp: lookup gitea-http.gitea.svc`. 40-install-gitea.sh publishes
# GITEA_ARGOCD_URL from Gitea's own LoadBalancer for exactly this.
GITEA_ARGOCD_URL="${GITEA_ARGOCD_URL:-${GITEA_INTERNAL_URL}}"
argocd_assert_clonable_url "$ARGOCD_OFF_CLUSTER" "$GITEA_ARGOCD_URL" \
  "${GITEA_NAMESPACE:-gitea}" "${GITEA_HOST:-gitea.vks.local}"
log_info "ArgoCD will clone from: $GITEA_ARGOCD_URL"

# ---- can we even write here? MEASURE it, do not assume ------------------------------------------
# On a real lab the ArgoCD instance lives in an ADMIN-owned vSphere Namespace. A tenant's grant may
# be ArgoCD RBAC (enforced by argocd-server, via an AppProject role) rather than Kubernetes RBAC —
# in which case `kubectl apply` into that namespace is Forbidden and this whole mechanism is the
# wrong tool. That question is UNVERIFIED against a real lab; rather than assume the write lands,
# ask the API server, and if the answer is no, print exactly what to request.
ns_err="$(ka get ns "$ARGOCD_NAMESPACE" 2>&1 >/dev/null)" || {
  if printf '%s' "$ns_err" | grep -qi 'forbidden'; then
    log_error "FORBIDDEN reading namespace '$ARGOCD_NAMESPACE' on the ArgoCD cluster ($ARGOCD_API)."
    log_error "  This is a PERMISSION problem, not a missing install — do not go looking for ArgoCD."
    die "ask your platform admin for read access to '$ARGOCD_NAMESPACE', or for the ArgoCD-side objects to be created for you (see below)."
  fi
  die "namespace '$ARGOCD_NAMESPACE' not found on the ArgoCD cluster ($ARGOCD_API). Is ARGOCD_KUBECONFIG/ARGOCD_NAMESPACE right? (ArgoCD is a Supervisor Service on a real lab — it is NOT in your guest cluster.)"
}

can() { [ "$(ka auth can-i "$1" "$2" -n "$ARGOCD_NAMESPACE" 2>/dev/null || echo no)" = yes ]; }
if ! can create applications.argoproj.io || ! can create secrets; then
  log_error "This kubeconfig may NOT create ArgoCD objects in '$ARGOCD_NAMESPACE' on $ARGOCD_API:"
  log_error "    create applications.argoproj.io : $(ka auth can-i create applications.argoproj.io -n "$ARGOCD_NAMESPACE" 2>&1 || true)"
  log_error "    create secrets                  : $(ka auth can-i create secrets -n "$ARGOCD_NAMESPACE" 2>&1 || true)"
  log_error ""
  log_error "  On VKS the ArgoCD instance runs in an ADMIN-owned vSphere Namespace, so a tenant"
  log_error "  typically cannot write there with kubectl. REQUEST from your platform team, per app:"
  app_names | while read -r a; do
    [ -n "$a" ] || continue
    log_error "    - an ArgoCD Application '${a}' tracking ${GITEA_ORG}/${a}-deploy -> namespace '${a}' on ${GUEST_API}"
  done
  log_error "    - (private repos only) the matching ArgoCD repository Secret"
  log_error "  Or ask to be granted create/update on applications.argoproj.io + secrets in '$ARGOCD_NAMESPACE'."
  die "refusing to continue — the writes below would fail with Forbidden."
fi

# ---- where does the app DEPLOY to? ---------------------------------------------------------------
# Default: in-cluster == the cluster ArgoCD runs in. That is correct ONLY when ArgoCD and the
# workload share a cluster. When they do not, the in-cluster default means THE SUPERVISOR, so we
# refuse it and re-derive the destination from the registered ArgoCD Cluster Secret (the cluster
# ArgoCD itself will dial) rather than trusting a value someone left in a file.
if [ "$ARGOCD_OFF_CLUSTER" = "1" ]; then
  # The clusters this ArgoCD actually knows about. On a real lab this ArgoCD is SHARED: the platform
  # team has registered MANY tenants' guest clusters here, so "just take the first one" is not a
  # shortcut — it is a way to deploy THIS tenant's app into ANOTHER tenant's cluster, with
  # prune:true + selfHeal:true. We match exactly, or we refuse.
  # The clusters registered with THIS ArgoCD, as `<name>\t<server>` lines. The template is a library
  # constant (lib/argocd.sh) because WHICH FIELD it reads is a contract — see the comment there.
  REGISTERED="$(ka -n "$ARGOCD_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster \
    -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>/dev/null || true)"

  if [ -z "$REGISTERED" ]; then
    log_error "ArgoCD is off-cluster, but NO guest cluster is registered as an ArgoCD destination."
    log_error "  Deploying with the in-cluster destination would install the app INTO THE ARGOCD"
    log_error "  CLUSTER (on a real lab: the Supervisor) — with prune+selfHeal. Refusing."
    die "run 'make argocd-register-guest' first (ADMIN-only; a tenant REQUESTS it from the platform team)."
  fi

  if [ -n "${ARGOCD_DEST_SERVER:-}" ] && [ "${ARGOCD_DEST_SERVER}" != "$ARGOCD_INCLUSTER_SERVER" ]; then
    # An explicit destination still has to be one ArgoCD can actually reach — i.e. registered.
    if ! printf '%s\n' "$REGISTERED" | cut -f2 | grep -qxF "$ARGOCD_DEST_SERVER"; then
      log_error "ARGOCD_DEST_SERVER=$ARGOCD_DEST_SERVER is NOT a cluster registered with this ArgoCD."
      log_error "  ArgoCD can only deploy to a cluster it holds credentials for. Registered:"
      printf '%s\n' "$REGISTERED" | while IFS="$(printf '\t')" read -r n s; do
        [ -n "${s:-}" ] && log_error "    - ${n}: ${s}"
      done
      die "set ARGOCD_DEST_SERVER to one of the above, or have the guest cluster registered."
    fi
  else
    ARGOCD_DEST_SERVER="$(printf '%s\n' "$REGISTERED" \
      | argocd_pick_dest_server "$GUEST_API" "${ARGOCD_DEST_CLUSTER_NAME:-}" || true)"
  fi

  if [ -z "${ARGOCD_DEST_SERVER:-}" ]; then
    log_error "AMBIGUOUS deploy destination — refusing to guess."
    log_error "  This ArgoCD has several clusters registered, and none of them matches the cluster"
    log_error "  we are deploying with (${GUEST_API}) by name or by API URL. Picking one at random"
    log_error "  could deploy this app into SOMEONE ELSE'S CLUSTER — with prune + selfHeal."
    log_error "  Registered destinations:"
    printf '%s\n' "$REGISTERED" | while IFS="$(printf '\t')" read -r n s; do
      [ -n "${s:-}" ] && log_error "    - ${n}: ${s}"
    done
    log_error "  Note the guest API URL ArgoCD dials may legitimately differ from the one in YOUR"
    log_error "  kubeconfig (a VIP vs a hostname). Pick the right one deliberately:"
    die "set ARGOCD_DEST_SERVER (or ARGOCD_DEST_CLUSTER_NAME) to the guest cluster you own."
  fi
  log_info "deploy destination (matched against the clusters registered with ArgoCD): $ARGOCD_DEST_SERVER"
else
  ARGOCD_DEST_SERVER="${ARGOCD_DEST_SERVER:-$ARGOCD_INCLUSTER_SERVER}"
  log_info "deploy destination: $ARGOCD_DEST_SERVER (in-cluster)"
fi

export ARGOCD_NAMESPACE ARGOCD_TRACK_BRANCH ARGOCD_DEST_SERVER ARGOCD_PROJECT

# ---- PER APP: its namespace (guest), its repo credentials + its Application (ArgoCD) --------------
TOKEN=""
[ -f "${REPO_ROOT}/secrets/gitea-ci-token" ] && TOKEN="$(cat "${REPO_ROOT}/secrets/gitea-ci-token")"
APPS_APPLIED=""

# shellcheck disable=SC2329  # invoked indirectly (for_each_app)
configure_app_argocd() {
  local app="$1"
  export DEPLOY_REPO_CLONE_URL="${GITEA_ARGOCD_URL}/${GITEA_ORG}/${APP_DEPLOY_REPO}.git"

  # GUEST: create the app's namespace WITH its PSA label. ArgoCD's CreateNamespace=true would create
  # it unlabelled, and VKS enforces Pod Security `restricted` by default on every non-system
  # namespace — so the label has to exist before the first pod. It used to be applied only by the
  # ingress step, which `make install-all` never runs.
  # (ensure_namespace uses the ambient kubectl, i.e. $KUBECONFIG = the GUEST — which is what we want.)
  ensure_namespace "$APP_NAMESPACE" "${PSA_LEVEL_APP:-restricted}"

  # GUEST: the image-PULL credential for Harbor, in the app's own namespace.
  #
  # There used to be NO imagePullSecret anywhere in this repo: the only Harbor credential lived in
  # the `ci` namespace, for kaniko to PUSH with. That is fine while HARBOR_PUBLIC_PROJECTS=true (the
  # KinD default) and silently fatal otherwise — which is the TENANT default: every app pod goes
  # ImagePullBackOff, and nothing in the flow says so. kubelet reads pull secrets from the POD's
  # namespace, so it has to be created per app, here, before ArgoCD's first pod.
  #
  # The password never touches argv (no `kubectl create secret --docker-password`): the manifest is
  # built in a umask-077 temp file and applied over STDIN. See common/security.md.
  if [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
    local auth dockercfg
    auth="$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0 2>/dev/null \
            || printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64)"
    dockercfg="$(printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" | base64 -w0 2>/dev/null \
            || printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" | base64)"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${HARBOR_PULL_SECRET}
  namespace: ${APP_NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${dockercfg}
EOF
    log_info "  ${app}: image-pull secret '${HARBOR_PULL_SECRET}' created in ns/${APP_NAMESPACE}"
  else
    log_warn "  ${app}: no HARBOR_USERNAME/HARBOR_PASSWORD — no image-pull secret."
    log_warn "    Fine only if the Harbor project is PUBLIC. With a private project every pod will ImagePullBackOff."
  fi

  if [ -n "$TOKEN" ]; then
    log_info "registering ${APP_DEPLOY_REPO} with ArgoCD"
    # The token reaches kubectl on STDIN (a heredoc), never on argv — see common/security.md.
    # NOTE: no `project:` field on purpose. A project-less repo Secret is ArgoCD's global-credential
    # fallback and matches any project; setting it to the WRONG project makes the credential vanish
    # silently (ArgoCD then falls back to an anonymous clone with no error).
    ka apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-${APP_DEPLOY_REPO}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${DEPLOY_REPO_CLONE_URL}
  username: ${GITEA_CI_USER}
  password: ${TOKEN}
EOF
  else
    log_warn "no CI token found — assuming a public deploy repo (no ArgoCD repo secret) for ${app}"
  fi

  log_info "creating ArgoCD Application '${APP_NAME}' (project ${ARGOCD_PROJECT}) -> ${DEPLOY_REPO_CLONE_URL} (ns ${APP_NAMESPACE} on ${ARGOCD_DEST_SERVER})"
  # shellcheck disable=SC2016
  envsubst '${ARGOCD_NAMESPACE} ${ARGOCD_PROJECT} ${APP_NAME} ${APP_NAMESPACE} ${ARGOCD_TRACK_BRANCH} ${DEPLOY_REPO_CLONE_URL} ${ARGOCD_DEST_SERVER}' \
    < "${REPO_ROOT}/k8s/argocd/application.yaml" | run ka apply -f -
  APPS_APPLIED="${APPS_APPLIED} ${APP_NAME}"
}
for_each_app configure_app_argocd

# ---- PROVE ArgoCD can actually CLONE the repo ----------------------------------------------------
# This is the gate that makes a wrong GITEA_ARGOCD_URL impossible to ship green, and it asserts a
# POSITIVE signal on purpose: "no ComparisonError present" passes trivially on an Application ArgoCD
# has not reconciled yet (its .status is simply empty). `.status.sync.revision` is only ever set
# AFTER repo-server successfully fetched the repository — so a non-empty revision is proof of a real
# clone, not the absence of a complaint.
ARGOCD_REPO_TIMEOUT_SECONDS="${ARGOCD_REPO_TIMEOUT_SECONDS:-180}"
log_info "verifying ArgoCD can reach ${GITEA_ARGOCD_URL} (waiting for each Application to fetch a revision)"
for app in $APPS_APPLIED; do
  ka -n "$ARGOCD_NAMESPACE" annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  rev=""
  for _ in $(seq 1 "$ARGOCD_REPO_TIMEOUT_SECONDS"); do
    rev="$(ka -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    [ -n "$rev" ] && break
    sleep 1
  done
  if [ -z "$rev" ]; then
    log_error "Application '$app' never fetched a revision from ${GITEA_ARGOCD_URL}/${GITEA_ORG}/${app}-deploy.git in ${ARGOCD_REPO_TIMEOUT_SECONDS}s."
    log_error "  ArgoCD's repo-server (in $ARGOCD_API) could not clone the repo. Its own words:"
    ka -n "$ARGOCD_NAMESPACE" get application "$app" \
      -o jsonpath='{range .status.conditions[*]}    [{.type}] {.message}{"\n"}{end}' 2>/dev/null || true
    log_error "  Most likely GITEA_ARGOCD_URL is not reachable from the ArgoCD cluster (currently: ${GITEA_ARGOCD_URL})."
    die "ArgoCD cannot clone the deploy repo — refusing to report success."
  fi
  log_info "  ${app}: ArgoCD fetched revision ${rev} — the repo is reachable from the ArgoCD cluster"
done

log_info "ArgoCD Applications created: $(app_names | tr '\n' ' ')"
