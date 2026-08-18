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
argocd_tls_opts   # ARGOCD_CA_FILE -> --server-crt, once, for every argocd call below

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
# jq is needed by argocd_app_fetch_verdict on the MECH=api path: `argocd app get` offers only
# -o json (no jsonpath), so the verdict is parsed with jq. It is pinned in .mise.toml and staged into
# the sneakernet bundle (03-check-tools.sh classifies it `jq|carried`), so this guards a broken PATH
# rather than a likely absence — but an UNREQUIRED jq turns "jq is missing" into an affirmative
# exculpation of the repo, which is worse than the hedge it replaced.
require_cmd jq
kubeconfig_ready
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
# --request-timeout matches the sibling wrapper in 23-argocd-preflight.sh. Without it every OTHER
# ka() call in this file (the reconciler check, the cluster-Secret listing) hangs forever against a
# blackholed endpoint — the explicit flags at the k_can_i sites closed only half of that.
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s "$@"; }

ARGOCD_API="$(argocd_api_server "$ARGOCD_KUBECONFIG")"
GUEST_API="$(argocd_api_server "$KUBECONFIG")"
if argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$KUBECONFIG"; then
  ARGOCD_OFF_CLUSTER=1
  log_info "ArgoCD is OFF-CLUSTER: ArgoCD=$ARGOCD_API  guest=$GUEST_API"
else
  ARGOCD_OFF_CLUSTER=0
  log_info "ArgoCD runs in the SAME cluster as the workload ($ARGOCD_API)"
fi

# ---- which Gitea URL can ARGOCD'S repo-server actually clone? --------------------------------------
# GITEA_INTERNAL_URL (gitea-http.gitea.svc:3000) resolves ONLY inside the guest cluster. It is right
# for Tekton (which runs there) and WRONG for an off-cluster ArgoCD, whose repo-server would fail
# every sync with `dial tcp: lookup gitea-http.gitea.svc`. The address that works is Gitea's own
# LoadBalancer.
#
# We RESOLVE it from the live Service — we do NOT read back GITEA_ARGOCD_URL.
# 40-install-gitea.sh used to PUBLISH GITEA_ARGOCD_URL into .env.kind, and this script read it back
# as an input. That is the publish-then-read-back trap the ingress code already refuses (see
# INGRESS_LB_IP_OVERRIDE): once a value is auto-published, it is ALWAYS set on the next run, so a
# STALE value is indistinguishable from a deliberate override — and it is consumed silently. A
# rebuilt Gitea with a new LB address would be cloned from the OLD one, and the failure surfaces as
# "Application never fetched a revision", pointing nowhere near the cause.
#
# A genuine operator override lives in its own variable, which nothing auto-publishes.
unset GITEA_ARGOCD_URL
GITEA_ARGOCD_URL="$(gitea_clone_url)"   # lib/argocd.sh — the SINGLE definition (see there)
log_info "ArgoCD clone URL resolved: ${GITEA_ARGOCD_URL}"
argocd_assert_clonable_url "$ARGOCD_OFF_CLUSTER" "$GITEA_ARGOCD_URL" \
  "${GITEA_NAMESPACE:-gitea}" "${GITEA_HOST:-gitea.vks.local}"
log_info "ArgoCD will clone from: $GITEA_ARGOCD_URL"

# ---- can we even write here? MEASURE it, do not assume ------------------------------------------
# On a real lab the ArgoCD instance lives in an ADMIN-owned vSphere Namespace. A tenant's grant may
# be ArgoCD RBAC (enforced by argocd-server, via an AppProject role) rather than Kubernetes RBAC —
# in which case `kubectl apply` into that namespace is Forbidden and this whole mechanism is the
# wrong tool. That question is UNVERIFIED against a real lab; rather than assume the write lands,
# ask the API server, and if the answer is no, print exactly what to request.
# THIS IS A MEASUREMENT, NOT A GATE. It used to `die` here — on Forbidden OR NotFound — which is the
# opposite of what the comment above says, and it made the TENANT PATH IMPOSSIBLE ON A REAL LAB:
#
#   * The die is at THIS line. ARGOCD_MECHANISM is not read until ~20 lines below and not dispatched
#     until ~45 below. So `ARGOCD_MECHANISM=api` — the tenant's ONLY path — could never rescue it.
#   * On a lab the guest cluster has NO `argocd` namespace at all (ArgoCD is a Supervisor Service in
#     ANOTHER cluster), so ARGOCD_KUBECONFIG defaulting to the guest yields NotFound -> die.
#   * A tenant who DOES point it at the Supervisor but holds no k8s RBAC there gets Forbidden -> die.
#
# Either way `make gitops` died before it could choose the api mechanism. KinD cannot show this: it is
# ONE cluster, so the namespace is always present and readable. 23-argocd-preflight.sh already treats
# the same Forbidden as a WARN — the two scripts disagreed, and this one was wrong.
#
# So: a namespace we cannot read means "kubectl is not available to us here" — feed that to the
# ladder. Only MECH=kubectl may die on it (it does, further below).
argocd_ns_readable=yes
ns_err="$(ka get ns "$ARGOCD_NAMESPACE" 2>&1 >/dev/null)" || {
  argocd_ns_readable=no
  if printf '%s' "$ns_err" | grep -qi 'forbidden'; then
    log_warn "cannot READ namespace '$ARGOCD_NAMESPACE' on the ArgoCD cluster ($ARGOCD_API): FORBIDDEN."
    log_warn "  That is normal for a TENANT — the ArgoCD instance lives in an admin-owned namespace."
    log_warn "  kubectl is not your write path; argocd-server is. Continuing to the mechanism ladder."
  else
    log_warn "namespace '$ARGOCD_NAMESPACE' not found on the ArgoCD cluster ($ARGOCD_API)."
    log_warn "  Expected when ArgoCD is a Supervisor Service and ARGOCD_KUBECONFIG points at the GUEST."
    log_warn "  kubectl is not usable here. Continuing to the mechanism ladder (api / request)."
  fi
}

# WHICH MECHANISM CAN ACTUALLY WRITE THE APPLICATION?
#
# This used to gate on `kubectl auth can-i create applications` AND `create secrets` in the ArgoCD
# namespace, and DIE if either said no. That measures KUBERNETES RBAC in an ADMIN-owned vSphere
# Namespace — the one axis a VKS tenant is EXPECTED to fail. It is the wrong axis: in ArgoCD,
# `applications` and `repositories` are PROJECT-SCOPED RBAC resources, so an AppProject role lets a
# tenant create them through ARGOCD-SERVER with no Kubernetes RBAC at all. The old gate told a tenant
# who could deploy that they could not.
#
# ---- THE SUPERVISOR GUARD. Re-armed after the tenant fix DELETED it. -------------------------------
#
# Removing the `die` on the namespace probe unblocked the tenant — and simultaneously removed the ONLY
# thing standing between a misconfigured run and a DEPLOY ONTO THE SUPERVISOR:
#
#   a tenant has no Supervisor kubeconfig -> ARGOCD_KUBECONFIG defaults to the GUEST
#     -> argocd_is_off_cluster compares the guest kubeconfig WITH ITSELF -> ARGOCD_OFF_CLUSTER=0
#     -> the destination defaults to https://kubernetes.default.svc
#     -> MECH=api writes that Application to the SUPERVISOR's argocd-server, where "in-cluster" IS
#        THE SUPERVISOR — with prune: true and selfHeal: true.
#
# That is CRITICAL #158 ("more dangerous than the bug") walking back in through the door the fix
# opened. KinD cannot see it: one cluster, so the namespace is always readable and in-cluster is
# genuinely correct.
#
# The signature is exact: the ArgoCD namespace is UNREADABLE from the kubeconfig we would deploy
# "in-cluster" into. That combination is never legitimate. An operator who really means it says so
# explicitly with ARGOCD_DEST_SERVER / ARGOCD_DEST_CLUSTER_NAME — which keeps the tenant path open.
if [ "$argocd_ns_readable" = no ] && [ "$ARGOCD_OFF_CLUSTER" = 0 ] \
   && [ -z "${ARGOCD_DEST_SERVER:-}${ARGOCD_DEST_CLUSTER_NAME:-}" ]; then
  log_error "REFUSING to deploy: the ArgoCD namespace '$ARGOCD_NAMESPACE' is UNREADABLE from the very"
  log_error "  kubeconfig we would deploy IN-CLUSTER into ($ARGOCD_API)."
  log_error "  That means ArgoCD is NOT in this cluster — it is a Supervisor Service in ANOTHER one —"
  log_error "  and an in-cluster destination would deploy your app ONTO THE SUPERVISOR, with prune"
  log_error "  and self-heal enabled."
  log_error "  Fix ONE of these:"
  log_error "    * make fetch-argocd-kubeconfig      (get the Supervisor kubeconfig; the ADMIN path)"
  log_error "    * ARGOCD_DEST_SERVER=<your guest API URL>          (the TENANT path)"
  log_error "    * ARGOCD_DEST_CLUSTER_NAME=<your guest, as registered in ArgoCD>"
  die "refusing to guess a deploy destination when ArgoCD is demonstrably not in this cluster."
fi

# So MEASURE, then pick (ARGOCD_MECHANISM=auto|kubectl|api|request):
#   kubectl — we may write to the ArgoCD namespace directly (Scenario 1, KinD). Unchanged.
#   api     — argocd-server accepts us (the TENANT path: an AppProject role, no k8s RBAC).
#   request — neither. Render what we WOULD have applied and print the exact ask. The give-up path,
#             and it is LAST, not first.
ARGOCD_MECHANISM="${ARGOCD_MECHANISM:-auto}"

# The deploy repos are seeded PUBLIC (50-seed-gitea-repos.sh), so ArgoCD needs no credential to clone
# them and the repo Secret is OPTIONAL. Demanding `create secrets` — the grant a tenant is least
# likely to hold — for a repo that needs no credential is how the old gate failed them twice over.
GITEA_DEPLOY_PRIVATE="${GITEA_DEPLOY_PRIVATE:-false}"

# ⚠️ THREE STATES, and the flags are passed EXPLICITLY. `|| echo no` collapsed "you are refused"
# onto "the probe never reached the cluster", so a TLS or CA fault silently downgraded the write
# mechanism. `can` keeps its boolean contract for callers; `can_why` carries the reason.
# --request-timeout is added here: the sibling wrapper in 23-argocd-preflight.sh has it and this
# one did not, so against a blackholed endpoint this probe HUNG rather than failing — and a
# classifier cannot help a probe that never returns.
can_why=""
can() {
  local _r
  _r="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
          auth can-i "$1" "$2" -n "$ARGOCD_NAMESPACE")"
  can_why="${_r#*|}"
  [ "${_r%%|*}" = yes ]
}
can_kubectl=no
# A namespace we cannot even READ is a namespace we cannot apply into. Short-circuit the probes.
if [ "$argocd_ns_readable" = no ]; then
  log_info "kubectl write path: NOT AVAILABLE (the ArgoCD namespace is unreadable from this kubeconfig)"
fi
# ⚠️ THE CRD IS NOT THE CONTROLLER. `auth can-i create applications.argoproj.io` is a pure RBAC
# question — it is TRUE the moment the CRD is registered, and says nothing about whether anything
# is running to reconcile what we write. On a Supervisor those are SEPARATE INSTALLS, minutes
# apart: MEASURED 2026-08-05, the argocd Supervisor SERVICE created applications/applicationsets/
# appprojects.argoproj.io at 00:59:38, and the ArgoCD INSTANCE only became ready at 01:02:46.
# scenario-1 §3 has the reader do those as separate steps, so the window is not exotic — it is
# what the runbook instructs. Inside it, this probe used to answer "kubectl", we would write an
# Application into a cluster with no reconciler, and the run would exit 0 having deployed NOTHING.
# So require a LIVE reconciler, not merely the schema for one.
#
# `${rr:-0}` is load-bearing: Kubernetes OMITS .status.readyReplicas when it is zero, so a
# StatefulSet that exists with no ready pods yields an EMPTY string while kubectl still exits 0
# (the `|| true` never fires). `[ "" -ge 1 ]` then dies with `integer expression expected`.
# MEASURED all three states — ready => true; absent => false; field-omitted => false, no stderr.
argocd_reconciler_ready() {
  local rr
  rr=$(ka -n "$ARGOCD_NAMESPACE" get sts argocd-application-controller \
         -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ "${rr:-0}" -ge 1 ]
}
# ⚠️ PROBE ONCE. The first version of this warn called `can` a SECOND time, so the message and the
# decision read two DIFFERENT measurements and could contradict each other — measured, probe1=yes
# with probe2=unknown gave can_kubectl=no with NO warning, i.e. the exact silent downgrade this
# block exists to prevent, still reachable. It also doubled the latency (up to 30 s against a
# blackholed endpoint). One probe, one variable, then branch.
_app_state=skip
if [ "$argocd_ns_readable" = yes ]; then
  # PROBE EVERY VERB THE PATH NEEDS, NOT JUST THE FIRST. This asked only for `create`, but the
  # kubectl path also PATCHES: argocd_await_revision annotates argocd.argoproj.io/refresh=hard, and
  # that annotate is now a gate rather than fire-and-forget, so a Role with [get,list,create]
  # selected MECH=kubectl and then died ~500 lines later at the refresh.
  # ⚠️ It is ADD, not REPLACE: probing `patch` ALONE would regress the mirror case — a
  # [get,list,patch] Role would select kubectl and then fail to CREATE the Application at all.
  _ra_k="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
            auth can-i create applications.argoproj.io -n "$ARGOCD_NAMESPACE")"
  # BOTH verbs, because the path needs both and either one alone is a different late failure:
  # without `create` it cannot make the Application; without `patch` it dies at the refresh
  # annotate ~500 lines later. Probe `patch` only when `create` was actually granted, so the
  # reported state stays the FIRST thing that is missing rather than the last one probed.
  if [ "${_ra_k%%|*}" = yes ]; then
    _ra_p="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
              auth can-i patch applications.argoproj.io -n "$ARGOCD_NAMESPACE")"
    if [ "${_ra_p%%|*}" != yes ]; then
      log_warn "kubectl may CREATE Applications in '${ARGOCD_NAMESPACE}' but not PATCH them"
      log_warn "  (auth can-i patch -> ${_ra_p%%|*}). The flow annotates argocd.argoproj.io/refresh=hard"
      log_warn "  to prove the repo is reachable, so a create-only grant fails at that step, not here."
      _ra_k="$_ra_p"
    fi
  fi
  _app_state="${_ra_k%%|*}"
  [ "$_app_state" = unknown ] && log_warn "the kubectl write probe FAILED TO ANSWER (${_ra_k#*|}) —
  this is NOT a denial. It never reached the cluster, so no RBAC grant will change it. Not
  selecting the kubectl path on a capability nobody measured."
fi
if [ "$_app_state" = yes ]; then
  if ! argocd_reconciler_ready; then
    log_warn "the argoproj.io CRDs exist, but NO ArgoCD reconciler is running in '${ARGOCD_NAMESPACE}'."
    log_warn "  StatefulSet argocd-application-controller is absent or has 0 ready replicas, so an"
    log_warn "  Application written here would never sync. The ArgoCD Supervisor SERVICE installs the"
    log_warn "  CRDs; the ArgoCD INSTANCE is a separate step that provides the controller."
    log_warn "  Create the instance first (scenario-1 §3), then re-run — not selecting the kubectl path."
  elif [ "$GITEA_DEPLOY_PRIVATE" != "true" ]; then
    can_kubectl=yes
  elif can create secrets; then
    can_kubectl=yes
  elif [ -n "$can_why" ]; then
    # ⚠️ Same asymmetry as the Applications probe above: a FALSE here is either "you are refused"
    # or "nobody asked". Silently leaving can_kubectl=no on the second is how a transport fault
    # became a permissions verdict. can_why is empty on a real yes/no and carries the class
    # otherwise — it is the ONLY reader, which is why `can()` still populates it.
    log_warn "the kubectl Secret probe FAILED TO ANSWER (${can_why}) — this is NOT a denial, so no
  RBAC grant will change it. Not selecting the kubectl path on a capability nobody measured."
  fi
fi

can_api=no
argocd_api_ready=no
if have argocd && [ -n "${ARGOCD_SERVER:-}" ] && [ -n "${ARGOCD_AUTH_TOKEN:-}" ]; then
  argocd_api_ready=yes
  # ARGOCD_AUTH_TOKEN reaches the CLI through the ENVIRONMENT (the argocd CLI reads it by name) —
  # never `argocd login --password`, which would put the secret in argv.
  # ⚠️ A DENIAL EXITS 0. Upstream argo-cd v3.4.5 (the installed version) returns
  # `&CanIResponse{Value:"no"}, nil` for a refusal, and the CLI prints that value and exits 0 — so
  # branching on rc recorded a REFUSED tenant as PERMITTED, and `>/dev/null` binned the answer.
  _rl="$(argocd_can_i create applications "${ARGOCD_PROJECT}/*")"
  case "${_rl%%|*}" in
    yes) can_api=yes ;;
    no)  can_api=no ;;
    *)   can_api=unknown
         # Loud, and it does NOT select the mechanism. Falling through to `request` is correct
         # under `auto` — the operator asked us to choose — but doing it SILENTLY was the defect.
         log_warn "the argocd API probe FAILED TO ANSWER (${_rl#*|}) — this is NOT a denial.
  argocd-server never received the request, so no AppProject role will change it. Not selecting the
  api mechanism on a capability nobody measured." ;;
  esac
fi

case "$ARGOCD_MECHANISM" in
  kubectl) MECH=kubectl ;;
  api)     MECH=api ;;
  request) MECH=request ;;
  auto)
    if   [ "$can_kubectl" = yes ]; then MECH=kubectl
    elif [ "$can_api"     = yes ]; then MECH=api
    # ⚠️ `request` IS ONLY SAFE WHEN CHOSEN BECAUSE A CAPABILITY WAS MEASURED ABSENT. Its exit is
    # `exit 0` (below), and the Makefile runs this script bare — so on `unknown` the chain was:
    # TLS fault -> both probes unknown -> MECH=request -> "ask your platform team" -> rc 0.
    # `make gitops` SUCCEEDS having applied NOTHING, and any e2e gating on that rc goes green over
    # a non-deployment. Of the three branches it is the one whose failure mode is SILENT SUCCESS,
    # so it is the worst possible default for "we could not tell".
    elif [ "$_app_state" = unknown ] || [ "$can_api" = unknown ]; then
      die "cannot choose a write mechanism: a capability probe did not ANSWER
  (kubectl=${_app_state}${can_why:+/${can_why}}, api=${can_api}).
  Refusing to fall back to 'request' — that path exits 0 having applied nothing, so a caller would
  read this run as a success. This is NOT a permissions result: fix the connection or the trust
  anchor and re-run, or set ARGOCD_MECHANISM explicitly to state what you intend."
    else                                MECH=request
    fi ;;
  *) die "ARGOCD_MECHANISM must be auto|kubectl|api|request (got '$ARGOCD_MECHANISM')" ;;
esac
# Log the server we ACTUALLY talk to, not the one we were passed. ARGOCD_SERVER is a SELECTOR: an
# uncommented value in .env.example used to be exported by load_env's `set -a` OVER a per-run
# override, so a run could target a hostname that resolves only on the author's box (/etc/hosts) —
# and the e2e still went green. A log line naming the effective server is what makes that visible.
[ -z "${ARGOCD_SERVER:-}" ] || log_info "argocd-server (effective): ${ARGOCD_SERVER}"
log_info "write mechanism: ${MECH}  (kubectl=${can_kubectl}, argocd-api=${can_api}$([ "$argocd_api_ready" = no ] && printf ' [api not probed: set ARGOCD_SERVER + ARGOCD_AUTH_TOKEN]'))"

if [ "$MECH" = kubectl ] && [ "$can_kubectl" != yes ] ; then
  die "ARGOCD_MECHANISM=kubectl, but this kubeconfig may not create Applications in '$ARGOCD_NAMESPACE' on $ARGOCD_API."
fi
if [ "$MECH" = api ] && [ "$argocd_api_ready" != yes ]; then
  die "ARGOCD_MECHANISM=api needs the argocd CLI plus ARGOCD_SERVER and ARGOCD_AUTH_TOKEN (see .env.example)."
fi

# ⚠️ AN EXPLICIT `api` BYPASSES THE unknown-GUARD ABOVE — and the tenant path is ALWAYS explicit.
# The die at the `auto` arm is unreachable here: `docs/scenario-2.md:264` and the walk harness
# (`nested-vsphere-lab/scripts/walk-matrix.sh:393`) both set ARGOCD_MECHANISM=api, so `api) MECH=api`
# takes it straight past the check that exists for exactly this state.
#
# MEASURED, matrix row 5, 2026-08-17 07:17:42Z: the probe was RIGHT and was then contradicted one
# line later —
#     WARN  the argocd API probe FAILED TO ANSWER (STALE_CA) ... Not selecting the api mechanism
#     INFO  write mechanism: api  (kubectl=no, argocd-api=unknown)
# and the run went on to create a namespace, apply PSA labels and mint an image-pull secret before
# dying with a GUESSED AppProject/RBAC cause. We already HOLD the classified reason at this point;
# this refuses before any of that side-effecting work and says what we actually measured.
if [ "$MECH" = api ] && [ "$can_api" = unknown ]; then
  _why="${_rl:-unknown|unknown}"; _why="${_why#*|}"
  # ⚠️ THE REMEDY MUST NOT NAME ONE CAUSE. Go verifies the HOSTNAME BEFORE the chain (measured,
  # go1.26.5: a leaf with DNS SANs only, dialled by IP, emits `doesn't contain any IP SANs`
  # IDENTICALLY whether the CA is trusted or not) — so a name failure MASKS the anchor, and telling
  # the operator "re-fetch the CA" or "the anchor is fine" is a coin flip that costs a second round
  # trip. Name both knobs; they are independent here in a way they never are for a kubeconfig.
  # ⚠️ DO NOT hand the operator two knobs and let them guess — MEASURE which one is wrong.
  # `ca_verifies_endpoint` (lib/tls.sh) exists for EXACTLY this fault: its own header records that
  # `rc 3 — chain OK, NAME wrong` was added "so callers stop reporting it as staleness", measured
  # against a leaf with DNS SANs and NO IP SAN served on 127.0.0.1 — the shape argocd-server has.
  # Harbor (27-harbor-ca-from-cluster.sh:148, 02-env.sh:410) and the Supervisor (30-vks-login.sh:181)
  # both route through it; ArgoCD was the ONLY one of the three that did not, and that asymmetry is
  # what made this message a coin flip. Do NOT re-implement it with a fresh `openssl` call: its
  # header documents five measured traps a new one re-introduces (s_client exits 0 on verification
  # FAILURE; it HANGS on a black-holed endpoint so rc 124 is not a bad anchor; a PLAINTEXT endpoint
  # was once reported as "the CA verifies it"; five distinct broken anchors all read "unreachable";
  # and -verify_ip vs -verify_hostname must be chosen per address shape or it verifies NOTHING).
  # ⚠️ lib/tls.sh is NOT auto-sourced by os.sh — 02-env.sh:25 and 30-vks-login.sh:21 both record that
  # omission as an rc-127 bug. Source it explicitly, and tolerate its absence rather than dying with
  # a worse error than the one we came here to report.
  _addr_verdict=""
  # shellcheck source=scripts/lib/tls.sh
  [ -f "${REPO_ROOT}/scripts/lib/tls.sh" ] && . "${REPO_ROOT}/scripts/lib/tls.sh" 2>/dev/null || true
  # ⚠️ F8 FIRST: a credential fault is NOT a transport fault. `_why` can be UNAUTHORIZED
  # (classify_argocd_failure, lib/os.sh) — an expired token means TLS was FINE, and sending the
  # operator to `make fetch-argocd-ca` there is a wrong remedy for a right diagnosis. `_why` is
  # already in hand; consult it before measuring anything.
  case "$_why" in
    UNAUTHORIZED)
      _addr_verdict="  The TRANSPORT is fine — argocd-server ANSWERED and REJECTED THE CREDENTIAL.
  Neither knob below is the fault: mint a fresh ARGOCD_AUTH_TOKEN (argocd login <server> --sso, then
  argocd account generate-token --account <you>) and put it in .env. Do NOT re-fetch the CA." ;;
  esac
  if [ -z "${_addr_verdict:-}" ] && command -v ca_verifies_endpoint >/dev/null 2>&1 \
     && [ -n "${ARGOCD_SERVER:-}" ]; then
    # ⚠️ F7: parse host:port the way fetch-ca.sh:49-50 already does. A naive `%:*`/`##*:` split
    # MEASURED broken on five real shapes: a scheme (`https://h` -> host=https, port=//h — and
    # creds.sh:76 shows a scheme IS an anticipated shape here, while env_validate does NOT reject
    # one for ARGOCD_SERVER as it does for HARBOR_URL), a trailing slash, `[::1]:443`, bare `::1`
    # and `fd00::1` (-> host=fd00:, port=1). Each degraded to rc 2 "did not answer", i.e. STRICTLY
    # WORSE than the generic text it replaced, because it blames reachability for a malformed value.
    _cv_hp="$(printf '%s' "$ARGOCD_SERVER" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##')"
    case "$_cv_hp" in
      \[*\]:*) _cv_h="${_cv_hp%]:*}]"; _cv_p="${_cv_hp##*]:}" ;;   # [v6]:port
      \[*\])   _cv_h="$_cv_hp";        _cv_p=443 ;;                # [v6]
      *:*:*)   _cv_h="$_cv_hp";        _cv_p=443 ;;                # bare IPv6, no port
      *:*)     _cv_h="${_cv_hp%:*}";   _cv_p="${_cv_hp##*:}" ;;
      *)       _cv_h="$_cv_hp";        _cv_p=443 ;;
    esac
    case "$_cv_p" in ''|*[!0-9]*) _cv_p=443 ;; esac
    # ⚠️ F4: rc 2 conflates "does not RESOLVE" with "refused", and those have OPPOSITE remedies —
    # MEASURED separable (errno 6 vs errno 111). A tenant who correctly set ARGOCD_SERVER to a
    # certificate NAME and has not mapped it lands here, and rc 2's text tells them to "retry",
    # which can never succeed. Ask the resolver first; it costs nothing and names the real fix.
    if ! getent hosts "$_cv_h" >/dev/null 2>&1 && ! printf '%s' "$_cv_h" | grep -qE '^[0-9.]+$|:'; then
      _addr_verdict="  MEASURED: '${_cv_h}' DOES NOT RESOLVE on this box — so nothing was dialled and
  neither knob has been tested. If you set ARGOCD_SERVER to a certificate NAME (which is correct —
  an IP cannot verify against a cert with no IP SAN), you must also make that name resolve:
      echo \"<argocd-lb-ip> ${_cv_h}\" | sudo tee -a /etc/hosts
  Then re-run. This is NOT a reachability problem and retrying alone will not fix it."
    else
      _cv=0; ca_verifies_endpoint "$_cv_h" "$_cv_p" "${ARGOCD_CA_FILE:-}" || _cv=$?
      case "$_cv" in
        0) _addr_verdict="  MEASURED: '${ARGOCD_SERVER}' VERIFIES against ARGOCD_CA_FILE (chain AND name).
  So neither knob below is the fault. Look at ARGOCD_AUTH_TOKEN, or at something between us and the
  server that terminates TLS or cannot do HTTP/2 (see ARGOCD_OPTS --grpc-web in .env.example)." ;;
        3) _addr_verdict="  MEASURED: the ANCHOR IS CORRECT and the ADDRESS IS WRONG — the chain verified and the
  NAME did not. Change ONLY the ADDRESS: do NOT re-fetch the CA, it is already the right one." ;;
        1) _addr_verdict="  MEASURED: connected, and ARGOCD_CA_FILE did NOT verify the chain — so the ANCHOR is
  wrong (or belongs to a rebuilt lab). Re-fetch it: make fetch-argocd-ca. The address may be fine." ;;
        2) _addr_verdict="  MEASURED: '${ARGOCD_SERVER}' resolved but did not answer (refused, or it accepted and
  closed with zero bytes — what an LB VIP looks like while its backend is still starting). This is
  NOT evidence either knob is wrong; check reachability, then retry." ;;
        4) _addr_verdict="  MEASURED: '${ARGOCD_SERVER}' served PLAINTEXT, not TLS — so no anchor can ever verify
  it. You are almost certainly pointing at the wrong port or the wrong service." ;;
        5) _addr_verdict="  NOT MEASURED: ARGOCD_CA_FILE is unset or unusable, so the two knobs cannot be told
  apart yet. If your ArgoCD presents a PUBLICLY-TRUSTED certificate there is nothing to set and the
  fault is elsewhere; otherwise set it (make fetch-argocd-ca) and re-run." ;;
      esac
      # ⚠️ F6: DERIVE this from the SANs, never hardcode it, and NEVER print it on rc 0. MEASURED
      # against a leaf carrying `DNS:argocd-server, IP Address:127.0.0.1`: the old hardcoded text
      # asserted "It carries NO IP SAN" directly beneath a printed IP SAN, claimed 'localhost' was
      # present when it was not, and fired on a rc-0 address that had just verified — telling the
      # operator to change something that works. lib/tls.sh's own gen_selfsigned_ca_cert mints
      # IP SANs, so this repo reaches that contradiction.
      if [ "$_cv" -ne 0 ]; then
        _sans="$(printf '' | timeout "${CA_VERIFY_TIMEOUT:-15}" openssl s_client \
                   -connect "${_cv_h}:${_cv_p}" -servername "$_cv_h" 2>/dev/null \
                 | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -s ' ' || true)"
        if [ -n "${_sans:-}" ]; then
          _addr_verdict="${_addr_verdict}
  THE NAMES THIS SERVER'S CERTIFICATE ACTUALLY CARRIES:${_sans}"
          printf '%s' "$_sans" | grep -q 'IP Address' || _addr_verdict="${_addr_verdict}
  There is NO IP SAN there, so an IP can never verify however correct the CA is — use one of the
  names above and make it resolve to this address."
        fi
      fi
    fi
  fi
  # ⚠️ Build the fallback as its own assignment, NOT as a `${_addr_verdict:-<default>}` inside the die
  # string: a multi-line default containing apostrophes does not parse there, and the resulting error
  # lands ~200 lines away (`syntax error near unexpected token '('`), pointing at innocent code.
  if [ -z "${_addr_verdict:-}" ]; then
    _addr_verdict="  Two INDEPENDENT knobs reach '${ARGOCD_SERVER:-<unset>}', and a name fault hides an anchor fault:
    * the ADDRESS  — ARGOCD_SERVER must be a name or IP the server's certificate actually carries
    * the ANCHOR   — ARGOCD_CA_FILE (make fetch-argocd-ca) must be the CA that signed it
  Fix the address first (it is verified first), then re-run: the anchor error can only appear once
  the name matches."
  fi
  die "ARGOCD_MECHANISM=api, but the argocd API probe DID NOT ANSWER (${_why}).
  This is a TRANSPORT fault, not a permissions one: argocd-server never received the probe, so no
  AppProject role changes it and 'make argocd-preflight' cannot surface it — and every write below
  would fail the same way, after creating namespaces and secrets.
${_addr_verdict}"
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
  reg_err="$(ka -n "$ARGOCD_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster \
    -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>&1 >/dev/null)" || true
  REGISTERED="$(ka -n "$ARGOCD_NAMESPACE" get secret -l argocd.argoproj.io/secret-type=cluster \
    -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>/dev/null || true)"

  # FORBIDDEN is not "nothing is registered". The cluster Secrets live in the ArgoCD admin's
  # namespace, and a tenant may not list them — saying "no guest cluster is registered" would be
  # FALSE, and it would point them at an admin-only target (`make argocd-register-guest`). In that
  # case we accept the destination the operator was TOLD (by name, or by API URL) without the
  # cross-check we are not allowed to perform.
  if [ -z "$REGISTERED" ] && printf '%s' "$reg_err" | grep -qi 'forbidden'; then
    if [ -n "${ARGOCD_DEST_CLUSTER_NAME:-}" ] || [ -n "${ARGOCD_DEST_SERVER:-}" ]; then
      log_warn "you may not LIST the clusters registered with this ArgoCD (Forbidden) — that is normal for a tenant."
      log_warn "  Trusting the destination you supplied; ArgoCD will reject it if it is not registered."
      REGISTERED=""
    else
      log_error "You may not list the clusters registered with this ArgoCD (Forbidden), and you have not"
      log_error "  told us which one is yours. We will NOT guess: the Application carries prune+selfHeal."
      die "set ARGOCD_DEST_CLUSTER_NAME (the name your platform team registered your guest cluster under), or ARGOCD_DEST_SERVER."
    fi
  elif [ -z "$REGISTERED" ]; then
    log_error "ArgoCD is off-cluster, but NO guest cluster is registered as an ArgoCD destination."
    log_error "  Deploying with the in-cluster destination would install the app INTO THE ARGOCD"
    log_error "  CLUSTER (on a real lab: the Supervisor) — with prune+selfHeal. Refusing."
    die "run 'make argocd-register-guest' first (ADMIN-only; a tenant REQUESTS it from the platform team)."
  fi

  if [ -z "$REGISTERED" ]; then
    : # tenant, cannot list: trust the supplied ARGOCD_DEST_CLUSTER_NAME / ARGOCD_DEST_SERVER (warned above)
  elif [ -n "${ARGOCD_DEST_SERVER:-}" ] && [ "${ARGOCD_DEST_SERVER}" != "$ARGOCD_INCLUSTER_SERVER" ]; then
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

  if [ -z "${ARGOCD_DEST_SERVER:-}" ] && [ -n "${ARGOCD_DEST_CLUSTER_NAME:-}" ]; then
    : # we will address the destination BY NAME (below) — ArgoCD accepts that, and it may be all a
      # tenant has, since the cluster Secrets are in the admin's namespace.
  elif [ -z "${ARGOCD_DEST_SERVER:-}" ]; then
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
  log_info "deploy destination: ${ARGOCD_DEST_SERVER:-(by name) ${ARGOCD_DEST_CLUSTER_NAME:-}}"
else
  # An EXPLICIT operator destination wins even here. It used to be ignored in this branch — so
  # ARGOCD_DEST_CLUSTER_NAME, documented as "the only handle a tenant usually has", was DEAD CODE on
  # precisely the path it was written for (the same class as #160: a knob that could never take
  # effect). Only fall back to in-cluster when the operator named nothing.
  if [ -n "${ARGOCD_DEST_SERVER:-}" ]; then
    log_info "deploy destination: $ARGOCD_DEST_SERVER (explicit)"
  elif [ -n "${ARGOCD_DEST_CLUSTER_NAME:-}" ]; then
    log_info "deploy destination: ${ARGOCD_DEST_CLUSTER_NAME} (explicit, by NAME)"
  else
    ARGOCD_DEST_SERVER="$ARGOCD_INCLUSTER_SERVER"
    log_info "deploy destination: $ARGOCD_DEST_SERVER (in-cluster)"
  fi
fi

# ArgoCD's Application.destination accepts EITHER `server:` (the API URL) or `name:` (the name the
# cluster was registered under). Prefer the URL when we have it; fall back to the NAME, which may be
# all a tenant has — the cluster Secrets live in the ArgoCD admin's namespace.
if [ -n "${ARGOCD_DEST_SERVER:-}" ]; then
  ARGOCD_DEST_KEY=server; ARGOCD_DEST_VALUE="$ARGOCD_DEST_SERVER"
else
  ARGOCD_DEST_KEY=name;   ARGOCD_DEST_VALUE="${ARGOCD_DEST_CLUSTER_NAME:?no deploy destination resolved}"
fi
export ARGOCD_NAMESPACE ARGOCD_TRACK_BRANCH ARGOCD_DEST_SERVER ARGOCD_PROJECT ARGOCD_DEST_KEY ARGOCD_DEST_VALUE

# ---- PER APP: its namespace (guest), its repo credentials + its Application (ArgoCD) --------------
TOKEN=""
[ -f "${REPO_ROOT}/secrets/gitea-ci-token" ] && TOKEN="$(cat "${REPO_ROOT}/secrets/gitea-ci-token")"
APPS_APPLIED=""
WORK_DIR="$(mktemp -d)"; trap 'rm -rf "$WORK_DIR"; rm -f "${_ac_err:-}" "${_afv_err:-}"' EXIT   # ⚠️ the two argocd stderr captures are registered HERE too. On every `die` path their own `rm -f` runs first (measured: 0 leaks), but an operator Ctrl-C during the api-path refresh left one behind (measured: 1). `_afv_err` (not the old `_aw_err`) is the one argocd_app_fetch_verdict creates — shellcheck SC2154 caught the stale name, which would have leaked it on Ctrl-C.
OUT_DIR="${REPO_ROOT}/out"           # only used by the `request` mechanism (gitignored)

# apply_application <app> <manifest> — write the Application through the mechanism we MEASURED.
# argocd_transport_die <class> <what-was-attempted> <cli-text>
#
# ONE ARM LIST for every argocd write site. The two sites shipped with DIFFERENT lists in the SAME
# commit — enumerated-list rot at birth. MEASURED 2026-08-17 by an implementation-round adversary
# driving the real script: `app create` omitted UNREACHABLE, so a plain `connection refused` fell to
# the default arm and told the operator *"Does your AppProject permit this destination and repo?"* —
# the exact defect B137 exists to fix, at the site B137 fixed, for a different transport shape.
#
# Returns 0 (and says nothing) when the class is NOT a transport/credential fault, so the caller
# emits its own domain-specific message on the next line.
argocd_transport_die() {
  case "$1" in
    STALE_CA|UNREACHABLE)
      die "could not REACH argocd-server to $2 ($1) — a TRANSPORT fault, not a permissions one.
  argocd-server never received the request, so no AppProject role changes it and 'make argocd-preflight'
  cannot surface it. This also says NOTHING about whether the operation would have succeeded.
  The certificate's NAME is verified BEFORE its chain (measured, go1.26.5), so a name fault HIDES an
  anchor fault — fix the address first, then the anchor:
    * ARGOCD_SERVER  ('${ARGOCD_SERVER:-<unset>}') must be a name/IP the server certificate carries
    * ARGOCD_CA_FILE (make fetch-argocd-ca) must be the CA that signed it
  the CLI said:
$3" ;;
    UNAUTHORIZED)
      die "argocd-server REJECTED the credential while trying to $2.
  ARGOCD_AUTH_TOKEN is absent, expired, or issued for another server — this is NOT an AppProject
  question, and no RBAC grant changes it. Mint a fresh one (argocd login --sso; argocd account
  generate-token) and re-run.
  the CLI said:
$3" ;;
  esac
  return 0
}


apply_application() {
  local app="$1" manifest="$2" _ac_err="" _ac_cls="" _ac_txt=""
  case "$MECH" in
    kubectl)
      run ka apply -f "$manifest" >/dev/null
      ;;
    api)
      # The TENANT path. argocd-server enforces ARGOCD RBAC (an AppProject role), not Kubernetes RBAC
      # — which is why this works where `kubectl apply` into the admin's namespace is Forbidden.
      # ARGOCD_AUTH_TOKEN reaches the CLI through the ENVIRONMENT, never argv.
        # ⚠️ CLASSIFY THE CLI'S OWN STDERR — do NOT substitute a cause. B137, measured row 5:
        # this died with "Does your AppProject permit this destination and repo?" while the CLI had
        # just printed `tls: failed to verify certificate: x509: ... doesn't contain any IP SANs`.
        # The text was never DISCARDED (>/dev/null is stdout only) — it was ignored and then
        # CONTRADICTED, which is worse: it sends the operator to argocd-preflight, a tool that
        # measures RBAC and structurally cannot surface a transport fault.
        _ac_err="$(mktemp)"
        if ! argocd app create -f "$manifest" --upsert >/dev/null 2>"$_ac_err"; then
          _ac_cls="$(classify_argocd_failure "$_ac_err")"
          _ac_txt="$(tr -d '\000' < "$_ac_err" | tail -5)"; rm -f "$_ac_err"
          argocd_transport_die "$_ac_cls" "create Application '${app}'" "$_ac_txt"
          die "argocd-server refused to create Application '${app}'. Does your AppProject '${ARGOCD_PROJECT}' permit this destination and repo? ('make argocd-preflight' checks exactly that.)
  the CLI said:
${_ac_txt}"
        fi
        rm -f "$_ac_err"
      ;;
    request)
      # The GIVE-UP path, and deliberately LAST. We cannot write, so render EXACTLY what we would
      # have applied and tell the operator precisely what to ask for. We do NOT render the repo
      # Secret: it carries a live Gitea token, and a token written to a file to be emailed to an
      # admin is a credential leak. `argocd repo add` is the right way to hand it over.
      mkdir -p "$OUT_DIR"
      cp "$manifest" "${OUT_DIR}/application-${app}.yaml"
      log_warn "  ${app}: rendered ${OUT_DIR#"${REPO_ROOT}/"}/application-${app}.yaml — ASK your platform team to apply it."
      ;;
  esac
}

# shellcheck disable=SC2329  # invoked indirectly (for_each_app)
configure_app_argocd() {
  local app="$1"
  local app_manifest="${WORK_DIR}/application-${app}.yaml"
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

  # The ArgoCD repo credential — ONLY when the deploy repo is actually private. The repos are seeded
  # PUBLIC (50-seed-gitea-repos.sh), so ArgoCD clones them anonymously and no Secret is needed.
  # Creating one anyway used to force the `create secrets` grant — the one a tenant is least likely
  # to hold — for a repo that needs no credential at all.
  if [ "$GITEA_DEPLOY_PRIVATE" = "true" ] && [ -n "$TOKEN" ]; then
    case "$MECH" in
      kubectl)
        log_info "  ${app}: registering ${APP_DEPLOY_REPO} with ArgoCD (private repo)"
        # The token reaches kubectl on STDIN (a heredoc), never argv — see common/security.md.
        # No `project:` field: a project-less repo Secret is ArgoCD's GLOBAL credential and matches
        # any project; setting it to the wrong one makes the credential vanish silently (ArgoCD then
        # falls back to an anonymous clone, with NO error).
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
        ;;
      api)
        # A tenant's repo credential MUST be project-scoped — that is the only kind ArgoCD RBAC lets
        # them create. Password on STDIN, never argv.
        log_info "  ${app}: argocd repo add ${DEPLOY_REPO_CLONE_URL} (project ${ARGOCD_PROJECT})"
        printf '%s' "$TOKEN" | argocd repo add "$DEPLOY_REPO_CLONE_URL" \
          --project "$ARGOCD_PROJECT" --username "$GITEA_CI_USER" --password-stdin >/dev/null \
          || die "argocd repo add failed for ${DEPLOY_REPO_CLONE_URL}"
        ;;
      request)
        log_warn "  ${app}: the deploy repo is PRIVATE — ask your platform team to run:"
        log_warn "      argocd repo add ${DEPLOY_REPO_CLONE_URL} --project ${ARGOCD_PROJECT} --username ${GITEA_CI_USER} --password-stdin"
        log_warn "    (hand the token over out-of-band — this script will NOT write it to a file.)"
        ;;
    esac
  fi

  log_info "Application '${APP_NAME}' (project ${ARGOCD_PROJECT}) -> ${DEPLOY_REPO_CLONE_URL} (ns ${APP_NAMESPACE} on ${ARGOCD_DEST_KEY}=${ARGOCD_DEST_VALUE}) via ${MECH}"
  # shellcheck disable=SC2016
  envsubst '${ARGOCD_NAMESPACE} ${ARGOCD_PROJECT} ${APP_NAME} ${APP_NAMESPACE} ${ARGOCD_TRACK_BRANCH} ${DEPLOY_REPO_CLONE_URL} ${ARGOCD_DEST_KEY} ${ARGOCD_DEST_VALUE}' \
    < "${REPO_ROOT}/k8s/argocd/application.yaml" > "$app_manifest"
  apply_application "$app" "$app_manifest"
  APPS_APPLIED="${APPS_APPLIED} ${APP_NAME}"
}
for_each_app configure_app_argocd

# ---- PROVE ArgoCD can actually CLONE the repo ----------------------------------------------------
# This is the gate that makes a wrong GITEA_ARGOCD_URL impossible to ship green.
#
# ⚠️ CORRECTED 2026-08-17 — THIS COMMENT USED TO ASSERT THE OPPOSITE, AND IT WAS MEASURABLY FALSE.
# It said `.status.sync.revision` "is only ever set AFTER repo-server successfully fetched the
# repository — so a non-empty revision is proof of a real clone, not the absence of a complaint",
# and on that basis it argued AGAINST using ComparisonError. Read against argo-cd v3.5.1 (our pin):
#   state.go:653-655   syncStatus.Revision = spec.source.targetRevision — the BRANCH NAME — is set
#                      BEFORE any fetch, and state.go:1042-1046 only overwrites it when manifests
#                      were actually produced. So a FAILED fetch leaves it NON-EMPTY.
# A non-empty revision is therefore NOT proof of a clone, and three successive versions of this
# gate reported "the repo is reachable" against a host that does not exist because of it.
#
# The objection to ComparisonError ("passes trivially on an Application not yet reconciled") is real
# but is answered by CONJUNCTION rather than by dropping the signal: argocd_await_revision requires
# BOTH that the app reconciled (reconciledAt ADVANCED past a pre-refresh reading) AND that the fetch
# succeeded (no ComparisonError, sync.status != Unknown). An unreconciled Application fails the
# first half, so the trivial-pass case cannot arise.
#
# And reconciledAt alone is not sufficient either, for a reason specific to what this gate does:
# forcing a refresh selects a Level-3 comparison, and Level 3 is exactly where argo-cd DISABLES its
# repo-error short-circuit (state.go:700-712, gated `&& !noRevisionCache`), so the timestamp
# advances even when the repo could not be read. Neither signal works alone; both together do.
ARGOCD_REPO_TIMEOUT_SECONDS="${ARGOCD_REPO_TIMEOUT_SECONDS:-180}"
if [ "$MECH" = request ]; then
  log_warn "nothing was applied (mechanism=request) — rendered the Applications to ${OUT_DIR#"${REPO_ROOT}/"}/ instead."
  log_warn "Ask your platform team to apply them, then re-run 'make verify'."
  log_info "ArgoCD Applications RENDERED (not applied): $(app_names | tr '\n' ' ')"
  exit 0
fi
# ⚠️ MECH=api here is an EXPLICIT operator choice (or one `auto` already made), so an unanswerable
# probe must not be read as "kubectl cannot see them" — that is the api path's normal shape AND the
# shape of a broken connection. Distinguish them: only a real `no` means "use argocd-server".
# Probed INSIDE the guard: the kubectl path was paying a round trip whose result both branches
# below then discarded.
_rv=""
[ "$MECH" = api ] && _rv="$(k_can_i --kubeconfig "$ARGOCD_KUBECONFIG" --request-timeout=15s \
        auth can-i get applications.argoproj.io -n "$ARGOCD_NAMESPACE")"
if [ "$MECH" = api ] && [ "${_rv%%|*}" = unknown ]; then
  die "cannot verify the Applications: the probe did not reach the cluster (${_rv#*|}).
  Refusing to report a sync I did not observe. This is NOT a permissions problem — fix the
  connection or the trust anchor, then re-run."
fi
if [ "$MECH" = api ] && [ "${_rv%%|*}" = no ]; then
  # The tenant path writes through argocd-server and may not read the Application object with
  # kubectl at all. `argocd app wait` is the equivalent check.
  log_info "verifying via argocd-server that each Application syncs (kubectl cannot read them on this path)"
  for app in $APPS_APPLIED; do
        # ⚠️ THIS USED TO `2>&1` THE STDERR INTO /dev/null — strictly worse than the create site,
        # which at least let the text reach the log. A transport fault here was reported as
        # "repo-server cannot reach Gitea", a guess about a DIFFERENT component. Keep the text.
        # ⚠️ WAS `argocd app wait --sync`, which CANNOT prove a fetch happened. See
        # argocd_app_fetch_verdict in lib/argocd.sh for the mechanism and for what this does NOT fix.
        argocd_app_fetch_verdict "$app"
        _aw_txt="$(tr -d '\000' < "$_afv_err" | tail -5)"
        case "$_afv_state" in
          ok) rm -f "$_afv_err" ;;
          cli)
            _aw_cls="$(classify_argocd_failure "$_afv_err")"; rm -f "$_afv_err"
            argocd_transport_die "$_aw_cls" "refresh Application '$app'" "$_aw_txt"
            die "could not read Application '$app' through argocd-server${_afv_msg:+ — ${_afv_msg}}.
  This says NOTHING about whether the repo is reachable. the CLI said:
${_aw_txt}" ;;
          parse)
            rm -f "$_afv_err"
            die "could not parse argocd's reply for Application '$app' — ${_afv_msg}
  A parse fault is not evidence about the repo. Check that jq is present and that the CLI emitted JSON." ;;
          repo)
            rm -f "$_afv_err"
            die "ArgoCD could not FETCH the repo for Application '$app'.
  argo-cd's own words: ${_afv_msg}
  That message prefix is the ONE ComparisonError arm that IS the repo, so ${GITEA_ARGOCD_URL} is
  implicated here. Confirm from the repo-server itself:
    kubectl -n <argocd-ns> exec deploy/argocd-repo-server -c repo-server -- \\
      curl -s -o /dev/null -w '%{http_code}\\n' '${GITEA_ARGOCD_URL}/${GITEA_ORG}/${app}-deploy.git/info/refs?service=git-upload-pack'" ;;
          notrepo)
            rm -f "$_afv_err"
            die "Application '$app' failed its comparison for a reason that is NOT the repo.
  argo-cd's own words: ${_afv_msg}
  ComparisonError has SEVEN causes and only one is the repo fetch; 'Failed to load live state:' is the
  DESTINATION CLUSTER, which on this path is a registered guest reached by a bearer token. Do NOT start
  at Gitea — start at the message above." ;;
          *)
            rm -f "$_afv_err"
            die "Application '$app': ${_afv_msg}
  The controller produced no comparison, so nothing here implicates the repo." ;;
        esac
    log_info "  ${app}: synced (argocd-server)"
  done
  log_info "ArgoCD Applications created: $(app_names | tr '\n' ' ')"
  exit 0
fi
log_info "verifying ArgoCD can reach ${GITEA_ARGOCD_URL} (waiting for each Application to fetch a revision)"
# ⚠️ THIS BLOCK USED TO NAME A CAUSE IT HAD NEVER PROBED. Certification row 5 (2026-08-17) failed
# here and reported "Most likely GITEA_ARGOCD_URL is not reachable from the ArgoCD cluster" —
# MEASURED FALSE the same day: from inside the repo-server pod the real clone handshake
# (/info/refs?service=git-upload-pack) returned http=200, and the Application was Synced/Healthy
# with a deploy history. The message was a guess printed in the voice of a diagnosis.
#
# Both reads below were `2>/dev/null || true`, so a NotFound, a Forbidden, a wrong namespace, a
# wrong kubeconfig and "no resource type application" ALL collapsed into one empty string — and
# then the run promised "Its own words:" and printed NOTHING, because the conditions dump had been
# silenced too. The run's own evidence for which fault occurred was destroyed by its own redirects.
for app in $APPS_APPLIED; do
  argocd_await_revision "$app"
done

log_info "ArgoCD Applications created: $(app_names | tr '\n' ' ')"
