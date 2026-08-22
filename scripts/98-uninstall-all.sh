#!/usr/bin/env bash
# scripts/98-uninstall-all.sh — remove what scenario-1 created on a REAL lab.
#
# ⚠️ READ THIS BEFORE CHANGING ANYTHING. This is the most dangerous script in the repo, and every
# guard below exists because an adversary round MEASURED the hazard on a live 9.1 lab:
#
#   * ARGOCD_NAMESPACE and VKS_NAMESPACE are BOTH `lab` on that lab — the ArgoCD Supervisor Service
#     instance runs IN the tenant namespace. That namespace also held the lab's own `lab-gc1`
#     cluster, a FOREIGN Application named `smoketest`, and a cluster Secret carrying a DIFFERENT
#     tool's ownership label (`nested-lab.local/managed-by`). So "the namespace is ours" is false,
#     and an emptiness guard on the variable passes while still being lethal.
#   * Our Applications are named from apps/registry.tsv — `javawebapp`, `gowebapp`. Generic demo
#     names, in a shared namespace, carrying `resources-finalizer` + `prune: true`. Deleting one BY
#     NAME cascade-deletes its deployed resources IN THE DESTINATION CLUSTER. That is how a teardown
#     destroys another tenant's running application.
#
# THEREFORE: this script deletes ONLY objects carrying our own ownership label, NEVER by name alone,
# NEVER with --all, and it REFUSES an unlabelled object rather than guessing. Anything it declines
# is PRINTED, so a half-done teardown is visible instead of silent.
#
# It is also deliberately NOT wired into any composite target. Nothing calls it but the operator.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

load_env
require_cmd kubectl

OWNER_LABEL="vks-airgap-cicd.local/owned-by=vks-airgap-cicd"
DELETED=0; SKIPPED=0; LEFT=()

note()    { printf '    %s\n' "$*" >&2; }
left()    { LEFT+=("$*"); SKIPPED=$((SKIPPED+1)); }
deleted() { DELETED=$((DELETED+1)); }

# --- guards ------------------------------------------------------------------------------------
# Every value we key on must be REAL. A placeholder or an empty string here does not merely fail —
# it widens a selector.
for v in VKS_CLUSTER_NAME VKS_NAMESPACE ARGOCD_NAMESPACE HARBOR_INFRA_PROJECT HARBOR_APP_PROJECT; do
  val="$(printenv "$v" 2>/dev/null || true)"
  case "$val" in
    ''|'<SET-IN-.env>'|*'<SET-'*) die "$v is empty or still a placeholder ('${val}'). Refusing to run:
  an empty value in a selector does not narrow it, it WIDENS it." ;;
  esac
done

# The operator must TYPE the cluster name. Not a y/n — a value that proves they know which lab this is.
[ "${CONFIRM:-}" = "$VKS_CLUSTER_NAME" ] || die "refusing to delete anything without confirmation.
  This removes what scenario-1 created on a REAL, SHARED lab. Re-run with the cluster name:
    make uninstall-all CONFIRM=${VKS_CLUSTER_NAME}"

# ⚠️ VKS_SUPERVISOR_KUBECONFIG FIRST — that is the name the WRITER (30-vks-login.sh)
# honours. These readers used only SUPERVISOR_KUBECONFIG; the defaults coincide, so the
# split was invisible on the box that measured it and would have split the moment an
# operator set either one.
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
[ -f "$SUP" ] || die "no Supervisor kubeconfig at '$SUP' — run 'make vks-login' first."
# </dev/null and --request-timeout are LOAD-BEARING, not hygiene. MEASURED: kubectl against an
# endpoint it cannot authenticate to emits `Please enter Username:` — an INTERACTIVE PROMPT. Every
# call here is `>/dev/null 2>&1`, so the prompt is INVISIBLE, and the step-4 wait loop polls for up
# to UNINSTALL_CLUSTER_WAIT_SECONDS (900) with a tty on stdin: the teardown would sit there,
# apparently working, blocked on a prompt nobody can see. An expired Supervisor token is the normal
# state of a lab kubeconfig the next morning, and this script is necessarily interactive (it
# requires a typed CONFIRM), so a tty is always present.
k() { kubectl --kubeconfig "$SUP" --request-timeout=15s "$@" </dev/null; }

# read_state <args...> — run a read and DISCRIMINATE its three outcomes, which a bare `if ! k …`
# collapses into one. kubectl exits 1 for NotFound, for unreachable, AND for forbidden, so
# `if ! k get X >/dev/null 2>&1; then "absent"` ASSERTS ABSENCE FROM ANY FAILURE. In a teardown
# that is the worst direction to be wrong in: it reports an object gone when the truth is that we
# could not look. Sets _RS_RC and _RS_ERR; returns 0 only when the object genuinely exists.
_RS_RC=0; _RS_ERR=""
read_state() {
  local _e; _e="$(mktemp)"
  _RS_RC=0; _RS_ERR=""
  # `|| _RS_RC=$?` on the SAME command. Reading $? after `fi` gives the IF COMPOUND's status, which
  # is 0 when the condition fails and no branch runs — so _RS_RC was ALWAYS 0 (measured) and any
  # future reader of it would conclude success from a failure.
  k "$@" >/dev/null 2>"$_e" || _RS_RC=$?
  # Keep ALL of stderr, not `head -1`. Measured: kubectl can emit a BLANK first line with the real
  # diagnosis on line 2 ("Error in configuration:" / "* unable to read client-cert …"), and a
  # first-line-only capture then looks like empty stderr — which used to render as "absent".
  _RS_ERR="$(tr '\n' ' ' < "$_e" | sed 's/  */ /g; s/^ //; s/ $//')"
  rm -f "$_e"
  [ "$_RS_RC" -eq 0 ]
}
# absent_or_unknown <label> — the honest print for a failed read.
# ⚠️ THERE IS NO "EMPTY STDERR MEANS ABSENT" CASE. `k` sends stdout to /dev/null, so a genuine
# NotFound ALWAYS lands on stderr; rc≠0 with nothing to show is a Ctrl-C, a kill (rc 137), or an
# error we failed to capture — none of which mean the object is gone. Treating empty as "absent"
# was measured to report a killed process and a real network fault as a completed deletion.
absent_or_unknown() {
  case "$_RS_ERR" in
    *NotFound*|*"not found"*) note "- ${1}: absent" ;;
    *) note "! ${1}: CANNOT READ (rc=${_RS_RC})${_RS_ERR:+ — ${_RS_ERR}}"
       left "${1} (could not be checked${_RS_ERR:+: ${_RS_ERR}})" ;;
  esac
}

# --- the plan, printed BEFORE the first destructive call ----------------------------------------
echo >&2
echo "  ── uninstall-all plan ──────────────────────────────────────────────" >&2
note "supervisor      : $SUP"
note "cluster         : ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}"
note "argocd namespace: ${ARGOCD_NAMESPACE}"
note "harbor projects : ${HARBOR_INFRA_PROJECT}, ${HARBOR_APP_PROJECT}  (robot: ${HARBOR_ROBOT_NAME:-<unset>})"
note "selector        : ${OWNER_LABEL}"
if [ "${ARGOCD_NAMESPACE}" = "${VKS_NAMESPACE}" ]; then
  note ""
  note "⚠️  ARGOCD_NAMESPACE == VKS_NAMESPACE ('${VKS_NAMESPACE}'). On a real lab that namespace is"
  note "    SHARED — it holds the ArgoCD instance itself and, measured, other tenants' objects."
  note "    That is exactly why nothing below is selected by name or swept with --all."
fi
echo "  ───────────────────────────────────────────────────────────────" >&2
echo >&2

# --- 1. ArgoCD Applications -- FIRST, and each must be OURS -------------------------------------
# Order matters and is not cosmetic: an Application's resources-finalizer can only complete while
# ArgoCD can still REACH the destination cluster. Delete the cluster first and the Application is
# stuck Terminating FOREVER in a namespace we do not own, needing a manual finalizer patch by
# whoever does own it.
log_info "1/5  ArgoCD Applications (ours only)"
# Capture first: a dying $( ) in argument position does not trip `set -e`, so a missing registry
# would make this loop run zero times and uninstall NOTHING, silently, with rc=0.
_apps="$(app_names)"
for app in $_apps; do
  if ! read_state -n "$ARGOCD_NAMESPACE" get application "$app"; then
    absent_or_unknown "$app"; continue
  fi
  owner="$(k -n "$ARGOCD_NAMESPACE" get application "$app" \
             -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>/dev/null || true)"
  if [ "$owner" != "vks-airgap-cicd" ]; then
    left "Application ${ARGOCD_NAMESPACE}/${app} — NOT labelled as ours (owned-by='${owner:-none}')"
    note "! ${app}: LEAVING IT — it is not labelled as ours. Deleting it could cascade-delete"
    note "  another tenant's workloads (it carries resources-finalizer + prune)."
    continue
  fi
  note "- ${app}: deleting (ours)"
  k -n "$ARGOCD_NAMESPACE" delete application "$app" --wait=false >/dev/null 2>&1 || true
  deleted
done

# Bounded wait. An unbounded one hangs forever exactly when the destination is already gone.
_end=$((SECONDS + ${UNINSTALL_APP_WAIT_SECONDS:-120}))
while [ "$SECONDS" -lt "$_end" ]; do
  # ⚠️ DO NOT "fix" a set -e abort here with a bare `|| true`. That converts a crash into a FALSE
  # CLEAN: with the API unreachable the count is 0, the loop breaks, and the teardown concludes the
  # Applications are gone. The mid-run case is the dangerous one — reads fine, deletes issued, API
  # dies during the wait — and then the summary says "ATTEMPTED 2 deletion(s)" and never mentions
  # them again. An `if` condition already suspends set -e, so no `|| true` is needed at all.
  if _out="$(k -n "$ARGOCD_NAMESPACE" get applications -l "$OWNER_LABEL" -o name 2>/dev/null)"; then
    still="$(printf '%s' "$_out" | grep -c . || true)"
    [ "$still" = 0 ] && break
  else
    note "! could not re-list Applications — NOT concluding they are gone."
    left "Applications in ${ARGOCD_NAMESPACE} (deletion issued, could NOT be verified)"
    break
  fi
  sleep "${POLL_INTERVAL_SECONDS:-5}"
done
still="$(k -n "$ARGOCD_NAMESPACE" get applications -l "$OWNER_LABEL" -o name 2>/dev/null || true)"
if [ -n "$still" ]; then
  note "! these Applications are still Terminating — ArgoCD cannot finish its finalizer, usually"
  note "  because the destination cluster is already unreachable. Clear it BY HAND (we will not"
  note "  strip a finalizer for you — that can orphan real resources):"
  printf '%s\n' "$still" | while read -r a; do
    note "    kubectl --kubeconfig $SUP -n $ARGOCD_NAMESPACE patch ${a} --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    left "$a still Terminating"
  done
fi

# --- 2. the guest-cluster registration + repo credential ----------------------------------------
log_info "2/5  ArgoCD cluster registration + repo credential (ours only)"
# This step used to print its heading and then, when nothing matched, NOTHING — so an empty result
# was indistinguishable from a failed read. _acted tracks whether any verdict was printed.
_acted=0
# ⚠️ SCOPED TO THIS CLUSTER, not just to our label. The label says "we made it"; it does NOT say
# "for THIS cluster". This box has run cicd-gc1 and cicd-gc2, and an unscoped sweep would make
# `make uninstall-all CONFIRM=cicd-gc2` delete the cicd-gc1 REGISTRATION — leaving that cluster's
# Applications pointing at a destination that no longer exists, while the counter reported a
# successful deletion. A teardown must remove what the operator CONFIRMED, and nothing else.
_secrets="$(k -n "$ARGOCD_NAMESPACE" get secret -l "$OWNER_LABEL" -o name 2>/dev/null || true)"
for s in $_secrets; do
  _nm="$(k -n "$ARGOCD_NAMESPACE" get "$s" -o jsonpath='{.data.name}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "$_nm" ] && [ "$_nm" != "$VKS_CLUSTER_NAME" ]; then
    note "! ${s}: ours, but it registers '${_nm}' — NOT '${VKS_CLUSTER_NAME}'. LEAVING IT."
    left "${s} (ours, but belongs to cluster '${_nm}')"; _acted=1; continue
  fi
  note "- ${s}: deleting (ours)"; k -n "$ARGOCD_NAMESPACE" delete "$s" >/dev/null 2>&1 || true; deleted; _acted=1
done
# The registration Secret written by 71-argocd-register-guest.sh predates the ownership stamp on
# some labs; identify it by the cluster NAME it registers and confirm it is not another tool's.
for s in $(k -n "$ARGOCD_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster -o name 2>/dev/null || true); do
  nm="$(k -n "$ARGOCD_NAMESPACE" get "$s" -o jsonpath='{.data.name}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  own="$(k -n "$ARGOCD_NAMESPACE" get "$s" -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>/dev/null || true)"
  if [ "$nm" = "$VKS_CLUSTER_NAME" ] && [ "$own" = "vks-airgap-cicd" ]; then
    note "- ${s}: deleting (registers ${nm}, labelled ours)"; k -n "$ARGOCD_NAMESPACE" delete "$s" >/dev/null 2>&1 || true; deleted
  elif [ "$nm" = "$VKS_CLUSTER_NAME" ]; then
    left "$s registers ${nm} but is NOT labelled ours (owned-by='${own:-none}')"
    note "! ${s}: registers ${nm} but is not labelled ours — LEAVING IT."; _acted=1
  fi
done
[ "$_acted" -eq 1 ] || note "- no registration Secret of ours for '${VKS_CLUSTER_NAME}' (nothing to delete)"
# ⚠️ THE HEADING SAYS "repo credential" AND THIS STEP CANNOT SELECT ONE. 70-configure-argocd.sh
# creates it with `argocd.argoproj.io/secret-type: repository` and NO ownership label, and the
# `argocd repo add` path does not stamp it either — so neither loop above can ever match it. Say so
# rather than letting the heading imply it was handled; a repository Secret holds a Gitea CI token
# with push rights to the deploy repos.
_repo="$(k -n "$ARGOCD_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=repository \
           -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -n "$_repo" ]; then
  note "! repo credential(s) present and NOT selectable by ownership (they carry no owned-by label):"
  printf '%s\n' "$_repo" | while read -r _r; do [ -n "$_r" ] && note "    ${_r}"; done
  note "  Inspect and remove the ones that are yours — they hold a git token:"
  note "    kubectl --kubeconfig '${SUP}' -n '${ARGOCD_NAMESPACE}' get secret <name> -o jsonpath='{.data.url}' | base64 -d"
  left "repo credential Secret(s) in ${ARGOCD_NAMESPACE} (unlabelled — cannot be selected safely)"
fi

# --- 3. Harbor projects + robot -----------------------------------------------------------------
log_info "3/5  Harbor (${HARBOR_INFRA_PROJECT}, ${HARBOR_APP_PROJECT})"
note "NOT automated, on purpose. Harbor REFUSES to delete a project that still holds repositories,"
note "and that refusal is the only thing standing between a stale HARBOR_*_PROJECT and someone"
note "else's images. Forcing it is the one shortcut that could destroy a shared registry."
note "Delete them in the Harbor UI (simplest), or with a scoped API call you have read."
# ⚠️ QUOTE EVERY <PLACEHOLDER>. Unquoted, `<admin>` is a SHELL REDIRECTION, not a word — and this
# is guidance an operator pastes verbatim. MEASURED:
#   bash -c 'curl -u <admin> -X DELETE https://h/...'  ->  bash: admin: No such file or directory
# and with a file named `admin` in the cwd the redirection SUCCEEDS, `-u` swallows `-X`, the server
# receives a GET instead of a DELETE, curl exits 0, and the operator believes the project was
# deleted. `${HARBOR_URL:-<harbor>}` carried the same defect on the same line.
note "  curl gives -u a USERNAME and PROMPTS for the password. Do NOT append ':password' —"
note "  that would put your Harbor admin credential in ps output and in your shell history."
note "  curl -u '<admin-username>' -X DELETE 'https://${HARBOR_URL:-<harbor-host>}/api/v2.0/projects/${HARBOR_INFRA_PROJECT}'"
note "  curl -u '<admin-username>' -X DELETE 'https://${HARBOR_URL:-<harbor-host>}/api/v2.0/projects/${HARBOR_APP_PROJECT}'"
[ -n "${HARBOR_ROBOT_NAME:-}" ] && note "  and the robot '${HARBOR_ROBOT_NAME}' under Administration -> Robot Accounts"
left "Harbor projects ${HARBOR_INFRA_PROJECT}/${HARBOR_APP_PROJECT} + robot ${HARBOR_ROBOT_NAME:-<unset>} (manual)"

# --- 4. the guest cluster -----------------------------------------------------------------------
# Deleting the Cluster removes everything INSIDE it, so the guest-cluster half (our namespaces,
# Tekton/Gateway-API CRDs, Istio) is deliberately SKIPPED: it is pure risk for zero benefit, and on
# a mesh we attached to rather than installed, deleting istio-system would remove the platform
# team's mesh.
log_info "4/5  the guest cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}"
if read_state -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME"; then
  own="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
           -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>/dev/null || true)"
  if [ "$own" != "vks-airgap-cicd" ]; then
    left "Cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} — NOT labelled as ours (owned-by='${own:-none}')"
    note "! NOT deleting it: this cluster is not labelled as created by us. On this lab that label is"
    note "  the only thing distinguishing our cluster from the lab's own."
  else
    note "- deleting (ours). Two controllers hold finalizers (cluster.cluster.x-k8s.io and"
    note "  tkg.tanzu.vmware.com/addon), so this is asynchronous."
    k -n "$VKS_NAMESPACE" delete cluster "$VKS_CLUSTER_NAME" --wait=false >/dev/null 2>&1 || true
    deleted
    _end=$((SECONDS + ${UNINSTALL_CLUSTER_WAIT_SECONDS:-900}))
    while [ "$SECONDS" -lt "$_end" ]; do
      k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >/dev/null 2>&1 || break
      sleep "${UNINSTALL_POLL_INTERVAL_SECONDS:-10}"
    done
    if k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >/dev/null 2>&1; then
      note "! still present after the timeout. NOT stripping finalizers — that orphans VMs and FCDs."
      note "  Inspect what is holding it:"
      note "    kubectl --kubeconfig $SUP -n $VKS_NAMESPACE get cluster $VKS_CLUSTER_NAME -o jsonpath='{.metadata.finalizers}'"
      left "Cluster ${VKS_CLUSTER_NAME} still terminating"
    else
      note "- gone."
    fi
  fi
else
  # NOT a bare "absent". read_state's rc=1 covers NotFound, unreachable AND forbidden alike, and
  # this is the CLUSTER — the single most consequential thing in the teardown to claim is gone.
  # MEASURED against an unreachable lab: this branch printed "- absent." for a cluster nobody could
  # see, while step 1 (already fixed) correctly said CANNOT READ two lines above. Same defect, one
  # step further down; wiring the helper into the `if` is not enough if the `else` re-implements it.
  absent_or_unknown "${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}"
fi

# --- 5. local state -----------------------------------------------------------------------------
log_info "5/5  this box"
note "NOT removing secrets/ automatically — it may hold a credential this repo did not create"
note "(the teardown rule: delete only what you can prove you created)."
note "  rm -f ${REPO_ROOT}/secrets/${VKS_CLUSTER_NAME}.kubeconfig"
note "and the ingress hosts line needs root, which we do not have:"
# DERIVED, not hardcoded. creds.sh:285 prints the /etc/hosts line built from ${GITEA_HOST},
  # ${TEKTON_DASHBOARD_HOST} and app_host() per app, while this said `/vks.local/d` LITERALLY — so
  # after any APP_DOMAIN change the two disagree: creds-show tells you to ADD the new names while
  # uninstall tells you to DELETE the old ones, and the stale entry survives teardown. On the next
  # cut the LB lands elsewhere and that entry points at a dead address, which is exactly the state
  # creds.sh:277-281 exists to prevent ("a hosts entry pointing at nothing sends you to debug your
  # browser"). The fallback keeps today's behaviour byte-identical.
  note "  sudo sed -i '/${APP_DOMAIN:-vks.local}/d' /etc/hosts"
left "secrets/ and the /etc/hosts line (manual; /etc/hosts needs sudo)"

# --- verdict ------------------------------------------------------------------------------------
echo >&2
# ⚠️ DELETED counts what we ATTEMPTED, not what went away: every delete above is `|| true`, so a
# rejection (RBAC, a webhook, a finalizer) still increments it. The number is a proxy; the RE-LIST
# below is the result. Same discipline as mirror-verify: never report a bulk mutation off its own
# counter.
log_info "uninstall-all: ATTEMPTED ${DELETED} deletion(s); left ${SKIPPED} thing(s) alone."
log_info "VERIFY IT — re-list rather than trusting the count above:"
log_info "  kubectl --kubeconfig $SUP -n $VKS_NAMESPACE get cluster $VKS_CLUSTER_NAME      # want: NotFound"
log_info "  kubectl --kubeconfig $SUP -n $ARGOCD_NAMESPACE get applications                # want: ours absent"
if [ "${#LEFT[@]}" -gt 0 ]; then
  log_warn "DELIBERATELY LEFT ALONE — this teardown is NOT complete, and that is the honest state:"
  printf '    - %s\n' "${LEFT[@]}" >&2
fi
if [ "$DELETED" = 0 ]; then
  log_warn "nothing was deleted. That is indistinguishable from 'my label selector matched nothing',"
  log_warn "so treat it as UNPROVEN rather than clean: re-check with 'make vks-cluster-status'."
fi
