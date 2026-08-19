#!/usr/bin/env bash
# 24-lab-preflight.sh — READ-ONLY: three cluster preconditions that each KILL the run later.
#
# WHY THIS EXISTS
# --------------
# `make preflight` covered check-tools + argocd-preflight + psa-check — and NOT these three, so
# docs/scenario-1.md made the admin hand-type them:
#
#   kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io   # Tekton needs this
#   kubectl get storageclass                                                   # Gitea's PVC needs a DEFAULT
#   kubectl get svc -A --field-selector spec.type=LoadBalancer                 # Gitea needs an LB VIP
#
# Anything typed more than once is a missing make target: the operator had to know what "good" looked
# like for each, and `install-all`'s own gate never checked them at all. Each failure surfaces LATE —
# after the ~20-minute mirror — and none of them names its real cause when it does:
#
#   * no CRD-create permission -> Tekton's install fails midway with an RBAC error about a CRD
#   * no DEFAULT StorageClass  -> Gitea's PVC sits Pending forever; the pod never schedules and the
#                                 error you see is a timeout, not "you have no default StorageClass"
#   * no LoadBalancer provider -> Gitea's Service never gets an EXTERNAL-IP, so ArgoCD (which is
#                                 OFF-CLUSTER on a real lab) can never clone from it
#
# It is READ-ONLY: it changes nothing, and it is safe to run against a cluster you do not own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠️ SNAPSHOT BEFORE load_env — ONE LINE IN A PERSONAL `.env` DISABLED THE ONLY CHECK FOR A
# MISSING HARBOR CA. `Makefile:623` does `preflight: export CA_STATUS_STRICT = 1` precisely
# because, as its own comment says, "nothing else catches it". But `load_env` sources
# `.env.example` and `.env` with `set -a` AFTER the caller's environment is established, so a
# `.env` line WINS over the Makefile's export. MEASURED, this exact script's ordering:
#     Makefile exports 1, operator .env says 0  ->  effective 0   *** the gate is disarmed ***
#     caller sets nothing                       ->  effective 0   (unchanged, the secure default)
# ...and it is a RATCHET: once `.env` says 0 there is no per-run way back, because
# `CA_STATUS_STRICT=1 make preflight` loses to the same `set -a`.
#
# There is NOTHING to protect here: `CA_STATUS_STRICT` appears NOWHERE in `.env.example` (grep
# count 0) and `check-env-coverage.sh` classifies it as internal, "not something an operator sets".
# So honour ONLY the pre-`load_env` environment, which is where the Makefile's export lives. Same
# pattern as `creds.sh`'s and `argocd-password.sh`'s `SHOW_SECRETS` snapshot.
_ca_status_strict_snapshot="${CA_STATUS_STRICT:-0}"

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
load_env
# Restore the snapshot OVER whatever load_env's `set -a` just put there. `ca_status_report` reads
# the global (`lib/tls.sh:473`), so the value has to be back in the environment by the time it is
# called — an argument would need a signature change across every caller of that function.
export CA_STATUS_STRICT="$_ca_status_strict_snapshot"

require_cmd kubectl

problems=0
ok()   { printf '  ok       %s\n' "$*" >&2; }
bad()  { printf '  PROBLEM  %s\n' "$*" >&2; problems=$((problems + 1)); }
note() { printf '           %s\n' "$*" >&2; }
# ⚠️ A FOURTH state, and the file already had the pattern — check #3 (LoadBalancer) says
# "This is NOT a pass" for something it cannot observe, while checks 1 and 2 did not.
# An unknown carries the SAME downstream cost as a `no` (this whole file exists so a missing
# permission does not kill the run 20 minutes into the mirror), so it must stay BLOCKING —
# but it must not assert a permissions verdict nobody obtained.
unk()  { printf '  UNKNOWN  %s\n' "$*" >&2; problems=$((problems + 1)); }

printf '\n===================== lab preflight =====================\n' >&2
log_info "cluster: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
# ⚠️ CAPTURE stderr and CLASSIFY it. This used to be `2>&1` + one guess ("run 'make vks-login'"),
# which is the wrong remedy for four of the five ways it fails — a stale CA is not fixed by logging
# in again, and an RBAC refusal is not fixed by anything this script can name.
#
# ⚠️ `version` is deliberate here (it is the cheapest possible probe) but it is ALSO the one kubectl
# verb whose stderr is TERSE — it skips discovery, so it emits neither "connection refused" nor
# "dial tcp". That is why classify_kube_failure carries the format-string suffix arm; this call site
# is the ONLY one in the repo that produces the terse form, so without this wiring that arm would be
# unreachable — a classifier branch no caller can hit is a branch that measures nothing.
_lp_err="$(mktemp)"
if ! kubectl version -o json >/dev/null 2>"$_lp_err"; then
  _lp_srv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  case "$(classify_kube_failure "$_lp_err")" in
    STALE_CA)     die "the kubeconfig's CA does not match ${_lp_srv:-the server it points at}.
  The server ANSWERED — this is NOT a network fault. A REBUILT cluster mints a new CA while the
  address stays the same, so a dead kubeconfig looks correctly configured.
  Re-export it from the cluster that is actually running:  make vks-login
  If that does NOT clear it, your SAVED Supervisor CA is stale too — and vks-login cannot tell you,
  because under VKS_AUTH_METHOD=kubeconfig (what scenario-1 section 6 sets) its arm checks only that
  the file is non-empty; every CA check lives in the vcf arm. Check the anchor itself — it needs no
  cluster, so it works when everything else here is dying:  make ca-status" ;;
    UNAUTHORIZED) die "${_lp_srv:-the cluster} REJECTED this kubeconfig's credentials — they expired,
  or they belong to a cluster that no longer exists. Re-authenticate:  make vks-login" ;;
    FORBIDDEN)    die "authenticated to ${_lp_srv:-the cluster}, but this identity may not read it.
  That is an RBAC GRANT, not a broken kubeconfig — do NOT re-fetch it. Ask your platform team for
  cluster-admin (this flow creates namespaces and installs CRDs)." ;;
    NO_KUBE_TARGET) die "kubectl had NO TARGET — it fell back to localhost:8080, which is never your
  lab. Either \$KUBECONFIG names a file that does not exist, or that file sets no current-context.
  Nothing was dialled, so this says NOTHING about whether the lab is up.  Fix it:  make vks-login" ;;
    PLAINTEXT)    die "${_lp_srv:-the server} is not speaking TLS on that port — EVERY CA remedy is
  wrong here, so do not re-fetch a trust anchor. Check the scheme and port in your kubeconfig." ;;
    UNREACHABLE)  die "cannot reach ${_lp_srv:-the cluster} — it never answered.
  This is NOT evidence your kubeconfig is stale. Is the lab up, and routable from this jump box?" ;;
    KUBECONFIG_UNUSABLE) die "a file named in your kube configuration is missing, unreadable or
  malformed, so NOTHING WAS DIALLED — this says NOTHING about whether the lab is up. It is not
  always \$KUBECONFIG itself: it may be a certificate-authority or client-cert it points at, an
  absent exec credential-plugin binary, or a present-but-invalid file. The error names which:
$(sed 's/^/    /' "$_lp_err" | head -4)
  Fix that file, or re-create the kubeconfig:  make vks-login" ;;
    *)            die "cannot reach the cluster with the current KUBECONFIG, and the error is not one
  this script classifies — printed verbatim rather than guessed at:
$(sed 's/^/    /' "$_lp_err" | head -6)" ;;
  esac
fi
rm -f "$_lp_err"

# 1. CRDs — Tekton installs its own. Without this permission its install dies midway.
# ⚠️ A reachability gate above already died if the cluster were unreachable, so `unknown` HERE
# means something changed between the two calls (a credential expiring mid-run is the realistic
# one). It must not print "may NOT create CRDs" — that is a claim about the operator's permissions
# derived from a question nobody answered, and it sends them to their platform team for a grant
# they may already hold.
_rc="$(k_can_i auth can-i create customresourcedefinitions.apiextensions.k8s.io)"
if [ "${_rc%%|*}" = unknown ]; then
  unk "could not determine whether you may create CustomResourceDefinitions (${_rc#*|})"
  note "This is NOT a permissions answer, so the cluster-admin remedy below does not apply. The"
  note "reachability gate above already passed, so the likely causes are a credential expiring"
  note "mid-run, or a cluster where SelfSubjectAccessReview itself is refused."
  note "Re-run 'make vks-login', then this preflight."
elif [ "${_rc%%|*}" = yes ]; then
  ok "may create CustomResourceDefinitions (Tekton installs its own)"
else
  bad "may NOT create CustomResourceDefinitions — Tekton cannot be installed."
  note "You need cluster-admin on this guest cluster. Ask your platform team, or use a cluster you own."
fi

# 2. A DEFAULT StorageClass — Gitea's PVC does not name one, so it gets the default. If there is no
#    default, the PVC stays Pending forever and the failure you see is a POD TIMEOUT, which names
#    nothing. Judge by the annotation the cluster ACTUALLY carries, not by the presence of any SC.
default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
n_sc="$(kubectl get storageclass --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ -n "$default_sc" ]; then
  ok "default StorageClass: ${default_sc}(Gitea's PVC binds to it)"
elif [ "$n_sc" -gt 0 ]; then
  bad "there are ${n_sc} StorageClass(es) but NONE is marked default — Gitea's PVC will sit Pending forever."
  note "Mark one: kubectl annotate sc <name> storageclass.kubernetes.io/is-default-class=true"
  note "(The failure you would otherwise see is a pod timeout, which does not mention StorageClasses.)"
else
  bad "no StorageClass at all — Gitea's PVC can never bind."
fi

# 4. HARBOR_URL must actually SERVE. The check itself lives in lib/harbor.sh because scenario-1
#    needs the same answer at STEP 4, where the other three checks below cannot run (they are
#    GUEST-cluster preconditions and the guest cluster does not exist until Step 6). One function,
#    two entry points — `make harbor-reachable` and this preflight — so they cannot drift.
harbor_reachable_report || problems=$((problems + 1))

# 4b. ...and it must ACCEPT US. Reachable is not authenticated: MEASURED 2026-08-12, a walk whose
#     HARBOR_PASSWORD had been GENERATED against a pre-existing Harbor passed 4 (Harbor answered
#     http 200) and then spent 605s in mirror+builder before failing the push on that credential.
#     env-validate had already reported the same 401 five minutes earlier and been walked past.
#     Cheapest failure available; see harbor_auth_report in lib/harbor.sh for why 403 is a PASS.
harbor_auth_report || problems=$((problems + 1))

# 3. A working LoadBalancer provider. On a real lab ArgoCD is OFF-CLUSTER (a Supervisor Service), so it
#    cannot resolve gitea-http.gitea.svc — Gitea needs its OWN LoadBalancer VIP for ArgoCD to clone from.
#    We cannot prove a provider exists without creating a Service, and this script is read-only. So we
#    report the evidence we CAN see and say plainly what it does and does not prove.
lbs="$(kubectl get svc -A --field-selector spec.type=LoadBalancer --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
pending="$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$2 == "" {print $1}' | tr '\n' ' ' || true)"
if [ "$lbs" -eq 0 ]; then
  note "no LoadBalancer Services exist yet, so a provider cannot be OBSERVED here."
  note "This is NOT a pass: if the cluster has no LB provider, Gitea's Service will never get an"
  note "EXTERNAL-IP and ArgoCD (off-cluster on a real lab) can never clone from it. If you are unsure,"
  note "ask your platform team whether this cluster has a LoadBalancer provider."
elif [ -n "$pending" ]; then
  bad "LoadBalancer Service(s) with NO external IP: ${pending}"
  note "A pending EXTERNAL-IP means no LB provider is assigning addresses. Gitea will hang the same way."
else
  ok "${lbs} LoadBalancer Service(s), all with an external IP — a provider is assigning addresses"
fi

# ── 4. STALE TRUST ANCHORS ────────────────────────────────────────────────────────────────────
# ONE implementation: ca_status_report in lib/tls.sh, beside the ca_verifies_endpoint whose return
# codes it interprets. The first draft was an inline copy of the probe loop here; the second put it
# in the executable 29-ca-status.sh and SOURCED that, which re-ran `set -euo pipefail`, re-sourced
# the libraries and called load_env a second time. tls.sh is already sourced above, so this is just
# a call — `make ca-status` is the other entry point to the same function.
# RESOLVE THE DEFAULT FIRST — see the same call in 29-ca-status.sh. Without it this preflight is
# BLIND to the Supervisor CA in the shipped configuration (VKS_CA_CERT_FILE is COMMENTED in
# .env.example), so it examines ZERO pairs and reports "nothing to check" instead of checking.
# MEASURED 2026-08-18: pairs examined 0 -> 1 with only this line added. No network; it early-returns
# when the operator set VKS_CA_CERT_FILE themselves.
vks_ca_default
_stale=0; ca_status_report || _stale=$?
problems=$((problems + _stale))

printf '\n' >&2
if [ "$problems" -eq 0 ]; then
  log_info "LAB PREFLIGHT OK — CRDs, storage and load-balancing look right for this flow."
  log_info "  (Read the LoadBalancer note above if it said a provider could not be observed.)"
else
  log_error "LAB PREFLIGHT: ${problems} problem(s) above. Each one kills the run LATER — after the"
  log_error "  ~20-minute mirror — with an error that does not name this as the cause. Fix them first."
fi
printf '=========================================================\n' >&2
exit "$problems"
