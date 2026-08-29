#!/usr/bin/env bash
# vks-package.sh <list|install|uninstall> [package-refName] — VKS Standard Packages on a GUEST cluster.
#
# These are NOT Supervisor Services. A Standard Package (istio, cert-manager, contour, prometheus,
# external-dns, harbor, ...) is a Carvel package installed INTO a guest cluster, so KUBECONFIG must
# point at the GUEST, not the Supervisor. `make install-harbor-service` and friends are the other
# family; do not mix them up.
#
# ⚠️ THE NAMESPACE TRAP, measured 2026-08-10. Carvel `Package` objects are NAMESPACED, and the
# standard repo publishes them into `vmware-system-tkg`. A PackageInstall created in ANY OTHER
# namespace fails with:
#     Reconcile failed: Package istio.kubernetes.vmware.com not found
# which reads as a missing package and is really a wrong namespace -- it retried that for 4
# minutes before the namespace was corrected. Every platform-managed install on a VKS cluster
# (<cluster>-antrea, -gateway-api, -metrics-server) lives there for the same reason. So do ours.
#
# ⚠️ AND THAT IS A DELIBERATE TRADE-OFF, NOT "the correct namespace". `vmware-system-tkg` is the
# SYSTEM's -- it holds the system-managed PackageRepository and is documented as reserved for the
# addon controller. Broadcom's own kubectl docs put CUSTOMER-managed installs in `tkg-system` with
# a repository YOU create and version. We ride the system repo on purpose:
#   - in an AIR GAP the platform team has already relocated it, so it costs us nothing; owning one
#     would mean relocating the bundle ourselves -- the Software-Depot flow this repo rejects;
#   - the system repo tracks the VKS Service release automatically; ours would have to be bumped
#     by hand on every VKS Service upgrade.
# Measured on VKr v1.34.9 (VKS 3.6.0), 2026-08-25: the guest has ZERO addon CRDs, `tkg-system` is
# EMPTY (kapp-controller runs there but owns no pkgr/pkgi), and the 8 platform installs are all
# named <cluster>-<component> -- so our `istio` collides with nothing. The conflict the docs warn
# about becomes real on VKS 3.7+, where the addon framework reconciles this namespace. It is
# refused by the B489 divergence gate below -- by OBJECT, fail-closed -- and NOT by any CRD probe:
# 43-install-istio-package.sh carried one until 2026-08-28, when it was deleted as unfireable (the
# addon CRDs are SUPERVISOR-side; that script is structurally guest-only). See
# docs/vks-services/istio.md and BACKLOG.md B484.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# DISCOVERED, not hardcoded -- see vks_package_namespace() in lib/os.sh for why the name is not
# stable across sources. An explicit VKS_PACKAGE_NAMESPACE still wins. If the cluster cannot be
# asked (no kubeconfig yet, an offline `list`), fall back to the historically-measured name and
# SAY the value is unverified -- never let a silent default masquerade as a discovered answer.
if PKG_NS="$(vks_package_namespace 2>/dev/null)" && [ -n "$PKG_NS" ]; then :
else
  PKG_NS=vmware-system-tkg
  log_warn "could not ask the cluster where Carvel Packages live; assuming '${PKG_NS}'"
  log_warn "  (lab-measured on VKS 3.6.3, but UNVERIFIED here). Override with VKS_PACKAGE_NAMESPACE=<ns>."
fi
ACTION="${1:-list}"
PACKAGE="${2:-${PACKAGE:-}}"
require_cmd kubectl jq
[ -s "${KUBECONFIG:-/nonexistent}" ] || die "no kubeconfig at '${KUBECONFIG:-<unset>}'. These are GUEST-cluster packages - point KUBECONFIG at the guest cluster (make vks-cluster-status writes one)."

# WHICH CLUSTER? There is no CLUSTER= argument -- the target is whatever $KUBECONFIG points at, so
# KUBECONFIG is a SELECTOR and a silent wrong value acts on the wrong cluster. The documented flow
# makes that reachable rather than theoretical: scenario-1.md:303 and scenario-2.md:148 both tell
# the operator to `export KUBECONFIG=./secrets/supervisor.kubeconfig` for the Supervisor steps, and
# nothing un-exports it before a later `make install-vks-package` in the same shell. So SAY which
# cluster, every time, on both paths. This is a PRINT, not a gate -- it cannot false-block.
log_info "cluster: $(kube_target_id)   [KUBECONFIG=${KUBECONFIG}]"

# REFUSE A SUPERVISOR. These are GUEST-cluster packages, and the pre-existing guards CANNOT catch
# this -- MEASURED 2026-08-24 against a live Supervisor and a live guest:
#   * a Supervisor serves the SAME refNames at the SAME versions (ako, cert-manager, cilium,
#     cluster-autoscaler, contour -- five byte-identical rows; it has MORE packages, not fewer),
#     so `_list`'s "no Carvel Packages visible" die never fires;
#   * `install` never reaches `_list` anyway -- it calls `_versions`, which RETURNS versions on a
#     Supervisor, so `_die_unknown` does not fire either;
#   * `install` has NO CONFIRM gate (only `uninstall` does).
# So the wrong-cluster install proceeds UNCONFIRMED and binds cluster-admin on the Supervisor
# control plane. This is the ONE place an EAGER check is justified: everywhere else in this repo
# the discriminator is called LAZILY inside a failure branch, because the operation FAILS on the
# wrong cluster and only the message needs correcting. Here the operation SUCCEEDS.
#
# rc=2 (API server unreachable) FAILS OPEN by design: it means we learned nothing about the
# cluster, and an air-gapped or slow lab must not be blocked by a probe that could not reach it.
# The cost of that is honest and worth stating: the gate is silent exactly when the operator is
# most confused about which cluster they are on. It can only refuse a HEALTHY Supervisor.
# Measured latency: 0.09s warm guest, 0.11s Supervisor, 3.1s host-unreachable, 20s blackholed.
if [ "$ACTION" = install ] || [ "$ACTION" = uninstall ]; then
  _sup_rc=0; kubeconfig_is_supervisor "$KUBECONFIG" || _sup_rc=$?
  case "$_sup_rc" in
    0) die "REFUSING: that kubeconfig points at a SUPERVISOR, not a guest cluster.
  $(kube_target_id)
  These are GUEST-cluster Carvel packages. A Supervisor serves the same package names at the same
  versions, so nothing downstream would have stopped this -- and \`install\` would have bound
  cluster-admin on the Supervisor control plane without asking.
  Point KUBECONFIG at the guest cluster (make vks-cluster-status writes one), then re-run." ;;
    2) log_warn "could not reach the API server to check whether this is a Supervisor — proceeding (not a pass)" ;;
  esac
fi

# _VKEY comes from scripts/lib/os.sh -- one key for every version selection in this repo.


# `// ""` on .spec.version: a Package with the field absent must not abort the whole listing with a
# jq error that `_list` then reports as "no Carvel Packages visible. Is KUBECONFIG pointing at a
# GUEST cluster?" -- naming the wrong cause for a one-row schema surprise.
# stderr goes to $_PKG_ERR (a FILE), not /dev/null. `2>/dev/null` hides the MESSAGE and not the
# STATUS, so the caller saw only "empty" and had to guess between three very different causes: no
# Carvel API at all, a cluster-scoped list this identity may not hold, and a genuinely absent package.
_versions() { kubectl get packages -A -o json 2>"${_PKG_ERR:-/dev/null}" \
  | jq -r --arg r "$1" "$(vkey_jq)"' [.items[]?|select(.spec.refName==$r)|(.spec.version // "")]|map(select((type=="string") and length>0))|sort_by(vkey)|.[]' 2>/dev/null; }

_list() {
  # A package whose only item has no .spec.version is LISTED with "<no version>", not dropped:
  # filtering it out made `list` hide a package that `_die_unknown` then advertises as available.
  # `type=="string"` before `length`: on a non-string version `length` is a jq ERROR (measured:
  # `boolean (true) has no length`, rc=5), which _list swallows and reports as "no Carvel Packages
  # visible. Is KUBECONFIG pointing at a GUEST cluster?" -- naming the wrong cause entirely.
  local out
  # LATEST comes from the SAME vkey the installer uses -- do not re-implement it here.
  out="$(kubectl get packages -A -o json 2>/dev/null \
        | jq -r "$(vkey_jq)"' [.items[]?|{r:.spec.refName,v:(.spec.version // "")}]|group_by(.r)|map({r:.[0].r,n:length,latest:((map(.v)|map(select((type=="string") and length>0))|sort_by(vkey)|last) // "<no version>")})|.[]|"  \(.r)\t\(.n)\t\(.latest)"' 2>/dev/null || true)"
  [ -n "$out" ] || die "no Carvel Packages visible. Is KUBECONFIG pointing at a GUEST cluster with the standard-packages repo? Check: kubectl get packagerepositories -A"
  printf '  %-46s %-9s %s\n' PACKAGE VERSIONS LATEST
  printf '%s\n' "$out" | while IFS=$'\t' read -r r n l; do printf '  %-46s %-9s %s\n' "${r# }" "$n" "$l"; done
  log_info "pass one as PACKAGE=<name>"
}

_die_unknown() {
  log_error "$1"
  log_error "  packages available on this cluster:"
  # `|| true`: this pipeline is a STATEMENT under `set -euo pipefail`, so a failing kubectl kills the
  # function HERE and the final die() below never prints -- the error reporter would itself die
  # silently, in exactly the case it exists to report.
  { kubectl get packages -A -o json 2>/dev/null | jq -r '[.items[]?.spec.refName]|unique|.[]' 2>/dev/null | sed 's/^/    /' >&2; } || true
  die "re-run with PACKAGE=<one of the above>   (see also: make list-vks-packages)"
}

case "$ACTION" in
  list) _list ;;

  install)
    [ -n "$PACKAGE" ] || _die_unknown "PACKAGE is not set."
    # `|| true` IS LOAD-BEARING. `_versions` is a `kubectl | jq` pipeline, so under
    # `set -euo pipefail` a failing kubectl makes the ASSIGNMENT non-zero and `set -e` kills the
    # script HERE -- one line above the guard that exists for precisely this case. MEASURED
    # 2026-08-26 with a stubbed kubectl; the CONTROL is the discriminator:
    #     no Carvel API                  -> rc=1, 262 bytes, output ends at "cluster: ..."  SILENT
    #     Forbidden (a namespaced tenant) -> rc=1, 262 bytes, identical                     SILENT
    #     API present, 0 items (CONTROL)  -> rc=1, 545 bytes, full diagnostic          guard reached
    # In the field that is `make install-ingress ISTIO_INSTALL_METHOD=package` creating two
    # namespaces and then dying with no message at all.
    _PKG_ERR="$(mktemp)"; export _PKG_ERR
    vers="$(_versions "$PACKAGE" || true)"
    if [ -z "$vers" ]; then
      # DISCRIMINATE, rather than reporting one cause for three. Deliberately a LOCAL check and NOT a
      # new class in classify_kube_failure: check-classifier-consumers.sh DERIVES the class list from
      # that function and requires a named arm in every case-form consumer, so a new class reddens 9
      # files, each needing a DIFFERENT remedy -- and this script is not one of those nine. "this API
      # group is not served" is also neither transport nor auth, which is that taxonomy.
      _e="$(cat "$_PKG_ERR" 2>/dev/null || true)"; rm -f "$_PKG_ERR"
      case "$_e" in
        *"doesn't have a resource type"*|*"no matches for kind"*|*"could not find the requested resource"*)
          # HEDGED ON PURPOSE. This says kubectl's DISCOVERY does not list the TYPE right now -- which
          # is usually "no kapp-controller here", but an aggregated APIService that is momentarily
          # Unavailable, or a kapp-controller still starting, produces the same answer. It is also a
          # claim about the TYPE, never about whether a given OBJECT exists; that stays
          # kube_is_notfound's job, which requires the server's own "Error from server (NotFound)".
          die "this cluster is not serving the Carvel packaging API (packaging.carvel.dev), so no VKS
    Package can be installed here. Usually that means no kapp-controller -- KinD and generic clusters
    have none, a VKS GUEST cluster does -- but it can also be an APIService that is still starting.
      -> use ISTIO_INSTALL_METHOD=helm, or point KUBECONFIG at a VKS guest cluster.
      -> if you believe this IS a VKS guest, check WHICH cluster: $(kube_target_id)
         and confirm with: kubectl api-resources --api-group=data.packaging.carvel.dev" ;;
        *orbidden*)
          die "this cluster serves packaging.carvel.dev, but this identity may not LIST packages
    cluster-wide ('kubectl get packages -A'), which a namespaced tenant cannot hold.
      -> ask your platform team to run 'make list-vks-packages', or use ISTIO_INSTALL_METHOD=helm.
    kubectl said: ${_e}" ;;
        "") _die_unknown "no Package '${PACKAGE}' on this cluster." ;;
        *)  die "could not list Carvel Packages on $(kube_target_id).
    kubectl said: ${_e}" ;;
      esac
    fi
    rm -f "$_PKG_ERR" 2>/dev/null || true
    VER="${PKG_VERSION:-$(printf '%s\n' "$vers" | tail -1)}"
    printf '%s\n' "$vers" | grep -qxF "$VER" || die "version '${VER}' is not offered for ${PACKAGE}. Offered:
$(printf '%s\n' "$vers" | sed 's/^/    /')"
    name="$(printf '%s' "$PACKAGE" | cut -d. -f1)"
    log_info "installing ${PACKAGE} ${VER} into ${PKG_NS} (PackageInstall '${name}') on $(kube_target_id)"

    # ── B489: gate on DIVERGENCE, never on EXISTENCE ────────────────────────────────────────────
    # This apply creates a CLUSTER-SCOPED ClusterRoleBinding to cluster-admin. It used to run with
    # no pre-apply read at all, so a PackageInstall of the same derived name created by anyone else
    # -- a second operator, a hand-install, later the VKS 3.7 addon framework -- was silently
    # ADOPTED and overwritten, and `uninstall` would then delete THEIR objects as if they were ours.
    #
    # ⚠️ The obvious fix (mirror uninstall's CONFIRM gate) was REFUTED by the design round, and the
    # reason is worth keeping: install `die`s AFTER the apply (the reconcile-timeout below), so the
    # most likely reason an operator re-runs leaves all three objects behind. An existence gate
    # would fire on their OWN retry and train them to type CONFIRM=yes reflexively -- which is
    # exactly what makes a gate useless on the day it matters. So an IDENTICAL spec adopts silently:
    # that is not a hole, that IS idempotency.
    #
    # ⚠️ managedFields CANNOT be the ownership signal. MEASURED: kubectl defaults to
    # --server-side=false, so the manager is `kubectl-client-side-apply` for ANY apply -- ours, a
    # second operator's, a hand-run. The repo's own owned-by label is the signal; the precedent is
    # 71-argocd-register-guest.sh:268-283.
    #
    # ⚠️ FAIL CLOSED. `if _x="$(kubectl get ... 2>/dev/null)"` -- the precedent's idiom -- cannot
    # tell ABSENT from Forbidden from unreachable, and here it would fail open into GRANTING
    # cluster-admin. kube_is_notfound requires the server's OWN "Error from server (NotFound)" and
    # the object token on ONE line: provably absent -> proceed; anything else -> refuse and say why.
    _pkgi_err="$(mktemp)"
    _pkgi_json="$(kubectl -n "$PKG_NS" get pkgi "$name" -o json 2>"$_pkgi_err" || true)"
    if [ -z "$_pkgi_json" ]; then
      if kube_is_notfound "$_pkgi_err" "$name"; then
        rm -f "$_pkgi_err"   # provably absent -- a fresh install, proceed.
      else
        _pe="$(cat "$_pkgi_err" 2>/dev/null || true)"; rm -f "$_pkgi_err"
        die "could not read PackageInstall '${name}' in ${PKG_NS}, so it is UNKNOWN whether one
  already exists. Refusing: this step grants cluster-admin via a CLUSTER-SCOPED ClusterRoleBinding,
  and proceeding on an unreadable answer would overwrite whatever is there.
  The cluster said:
$(printf '%s' "${_pe:-<no output>}" | sed 's/^/      /')
  A namespaced tenant typically cannot read ${PKG_NS}; ask the platform team, or set
  VKS_PACKAGE_NAMESPACE to a namespace you can read."
      fi
    else
      printf '%s' "$_pkgi_json" | jq -e . >/dev/null 2>&1 || {
        rm -f "$_pkgi_err"
        die "PackageInstall '${name}' in ${PKG_NS} read back as text jq cannot parse, so it is
  UNKNOWN what is there. Refusing — this step grants cluster-admin.
  First 200 bytes: $(printf '%s' "$_pkgi_json" | head -c 200)"; }
      _cur_ref="$(printf '%s' "$_pkgi_json"  | jq -r '.spec.packageRef.refName // ""')"
      _cur_ver="$(printf '%s' "$_pkgi_json"  | jq -r '.spec.packageRef.versionSelection.constraints // ""')"
      _cur_sa="$(printf '%s' "$_pkgi_json"   | jq -r '.spec.serviceAccountName // ""')"
      _cur_own="$(printf '%s' "$_pkgi_json"  | jq -r '.metadata.labels["vks-airgap-cicd.local/owned-by"] // ""')"
      rm -f "$_pkgi_err"

      # 1. A FOREIGN owner is decisive on its own -- do not go on to compare specs.
      if [ -n "$_cur_own" ] && [ "$_cur_own" != vks-airgap-cicd ]; then
        die "PackageInstall '${name}' in ${PKG_NS} is owned by '${_cur_own}', not us. Refusing to
  overwrite it (this apply also rebinds the cluster-scoped ClusterRoleBinding
  '${name}-pkg-sa-cluster-admin' to cluster-admin).
  Inspect it: kubectl -n ${PKG_NS} get pkgi ${name} -o yaml"
      fi

      # 2. A different refName under the SAME derived name. The name is `cut -d. -f1` of the
      #    refName, so ANY two packages sharing a first DNS label collide -- on a CLUSTER-SCOPED
      #    object. Never adopt across that.
      if [ "$_cur_ref" != "$PACKAGE" ]; then
        die "PackageInstall '${name}' in ${PKG_NS} already installs '${_cur_ref}', not '${PACKAGE}'.
  Both derive the SAME name ('${name}') because the name is the first DNS label of the refName, so
  installing here would REPOINT that install and rebind a cluster-admin ClusterRoleBinding.
  Remove it deliberately first, or install into a different VKS_PACKAGE_NAMESPACE."
      fi

      # 3. Same package, DIFFERENT version -- the real hazard. An operator re-running at an older
      #    PKG_VERSION over a live mesh is a downgrade; 43-install-istio-package.sh already treats a
      #    two-minor gap as one requiring consent. Gate it; do not refuse it outright.
      if [ "$_cur_ver" != "$VER" ]; then
        [ "${CONFIRM:-}" = yes ] || die "PackageInstall '${name}' in ${PKG_NS} is at '${_cur_ver}' and
  this would move it to '${VER}'. That is an upgrade or a DOWNGRADE of a running workload, not a
  retry, so it is not done silently. Re-run with:
      make install-vks-package PACKAGE='${PACKAGE}' PKG_VERSION='${VER}' CONFIRM=yes"
        log_warn "changing ${PACKAGE} from ${_cur_ver} to ${VER} (CONFIRM=yes given)"
      fi

      # 4. Identical, but UNLABELLED. It is most likely our own install from before the label
      #    existed -- but it is not PROVABLY ours, and the apply below stamps it, after which
      #    `uninstall` would delete it. Adopt (so the retry keeps working) and SAY SO, rather than
      #    blocking a legitimate re-run or stamping in silence.
      if [ -z "$_cur_own" ]; then
        log_warn "adopting an existing, UNLABELLED PackageInstall '${name}' in ${PKG_NS}"
        log_warn "  (same refName and version, sa='${_cur_sa}'). It will be stamped owned-by=vks-airgap-cicd,"
        log_warn "  after which 'make uninstall-vks-package' would remove it. If it is NOT yours, stop now."
      fi
    fi

    # A dedicated SA + cluster-admin binding: a Standard Package installs cluster-scoped objects
    # (CRDs, webhooks, a CNI DaemonSet), so the installer needs them. Named after the package so
    # the uninstall can remove exactly what it created and nothing else.
    kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${name}-pkg-sa
  namespace: ${PKG_NS}
  labels: { vks-airgap-cicd.local/owned-by: vks-airgap-cicd }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${name}-pkg-sa-cluster-admin
  labels: { vks-airgap-cicd.local/owned-by: vks-airgap-cicd }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - { kind: ServiceAccount, name: ${name}-pkg-sa, namespace: ${PKG_NS} }
---
apiVersion: packaging.carvel.dev/v1alpha1
kind: PackageInstall
metadata:
  name: ${name}
  namespace: ${PKG_NS}
  labels: { vks-airgap-cicd.local/owned-by: vks-airgap-cicd }
spec:
  serviceAccountName: ${name}-pkg-sa
  packageRef:
    refName: ${PACKAGE}
    versionSelection: { constraints: "${VER}" }
$([ -n "${PKG_VALUES:-}" ] && [ -s "${PKG_VALUES:-}" ] && printf '  values:\n    - secretRef: { name: %s-pkg-values }\n' "$name")
YAML
    if [ -n "${PKG_VALUES:-}" ] && [ -s "${PKG_VALUES:-}" ]; then
      # ⚠️ THE LABEL MUST BE ADDED HERE. `create secret generic` does not take the heredoc's labels,
      # so this Secret used to be the ONE object we create UNLABELLED — after which the uninstall
      # half below correctly refused to delete it and printed a leftover warning about an object we
      # had made ourselves. `43-install-istio-package.sh` always passes PKG_VALUES, so that fired on
      # every real uninstall and would have desensitised the operator to the genuine warnings.
      kubectl -n "$PKG_NS" create secret generic "${name}-pkg-values" \
        --from-file=values.yml="$PKG_VALUES" --dry-run=client -o yaml \
        | kubectl label --local -f - -o yaml \
            vks-airgap-cicd.local/owned-by=vks-airgap-cicd \
        | kubectl apply -f - >/dev/null
      log_info "data-values from ${PKG_VALUES}"
    fi

    # WAIT, and report the platform's own description -- 'Reconcile failed' is where the namespace
    # trap above shows up, and it is worth naming rather than timing out silently.
    _end=$((SECONDS + ${VKS_PACKAGE_WAIT_SECONDS:-600})); last=""
    while :; do
      d="$(kubectl -n "$PKG_NS" get pkgi "$name" -o jsonpath='{.status.friendlyDescription}' 2>/dev/null || true)"
      [ -n "$d" ] && [ "$d" != "$last" ] && { log_info "  ${d}"; last="$d"; }
      case "$d" in
        *"Reconcile succeeded"*) log_info "${PACKAGE} ${VER} installed"; exit 0 ;;
        *Package*"not found"*) die "${d}
  That is the NAMESPACE trap: Carvel Packages are namespaced and live in ${PKG_NS}. If you changed
  VKS_PACKAGE_NAMESPACE, change it back." ;;
      esac
      [ "$SECONDS" -lt "$_end" ] || die "${PACKAGE} did not reconcile within ${VKS_PACKAGE_WAIT_SECONDS:-600}s (last: ${d:-no status}).
  Inspect: kubectl -n ${PKG_NS} get pkgi ${name} -o yaml"
      sleep 10
    done ;;

  uninstall)
    [ -n "$PACKAGE" ] || _die_unknown "PACKAGE is not set."
    name="$(printf '%s' "$PACKAGE" | cut -d. -f1)"
    # ⚠️ NOT `get … >/dev/null 2>&1 || "nothing to do"`. That is the condemned idiom the install
    # guard above exists to avoid, and here it reports rc=0 "cleanup succeeded" on a Forbidden or an
    # unreachable API server. Read the owner and the existence in ONE call, then discriminate.
    _u_err="$(mktemp)"
    _u_own="$(kubectl -n "$PKG_NS" get pkgi "$name" \
                -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>"$_u_err" || true)"
    _u_rc=$?
    if [ -n "$_u_own" ]; then
      _u_state=present
    elif kube_is_notfound "$_u_err" "$name"; then
      _u_state=absent
    elif [ "$_u_rc" -eq 0 ] && [ ! -s "$_u_err" ]; then
      _u_state=present            # exists, but carries no ownership label
    else
      _u_state=unknown
    fi
    case "$_u_state" in
      absent) rm -f "$_u_err"; log_info "${PACKAGE} is not installed in ${PKG_NS} - nothing to do"; exit 0 ;;
      unknown)
        _ue="$(cat "$_u_err" 2>/dev/null || true)"; rm -f "$_u_err"
        die "could not read PackageInstall '${name}' in ${PKG_NS}, so it is UNKNOWN whether it is
  installed or who owns it. Refusing rather than reporting a cleanup that did not happen.
  The cluster said:
$(printf '%s' "${_ue:-<no output>}" | sed 's/^/      /')" ;;
    esac
    rm -f "$_u_err"
    # ⚠️ THE PackageInstall IS THE EXPENSIVE OBJECT — it owns everything the package deployed. The
    # first version of this change protected the SA, the ClusterRoleBinding and the values Secret
    # and still deleted the pkgi BY NAME, four lines under a comment quoting "NEVER by name alone".
    # An implementation-round adversary seeded a foreign-owned pkgi: install REFUSED it, and
    # uninstall destroyed it one command later.
    if [ -n "$_u_own" ] && [ "$_u_own" != vks-airgap-cicd ]; then
      die "PackageInstall '${name}' in ${PKG_NS} is owned by '${_u_own}', not us. Refusing to delete
  it — it owns everything that package deployed. The name is the first DNS label of the refName, so
  another package can derive it.
  Inspect it: kubectl -n ${PKG_NS} get pkgi ${name} -o yaml"
    fi
    [ "${CONFIRM:-}" = yes ] || die "refusing without CONFIRM=yes.
  This removes ${PACKAGE} and everything it deployed from:
      $(kube_target_id)
  Confirm that is the cluster you mean, then re-run:
      make uninstall-vks-package PACKAGE='${PACKAGE}' CONFIRM=yes"
    log_warn "uninstalling ${PACKAGE} from $(kube_target_id)"
    kubectl -n "$PKG_NS" delete pkgi "$name" 2>&1 | sed 's/^/    /'

    # ── B489 (the other half) ───────────────────────────────────────────────────────────────────
    # The comment here used to read "Only what WE created: the SA and binding are named after the
    # package." NAMED AFTER IS NOT OWNED BY. The name is `cut -d. -f1` of the refName, so any two
    # packages sharing a first DNS label derive the SAME name -- and the ClusterRoleBinding is
    # CLUSTER-SCOPED. Deleting by name alone directly violates this repo's own doctrine
    # (98-uninstall-all.sh:17-18: "deletes ONLY objects carrying our ownership label, NEVER by name
    # alone"), and it composes with the adoption the install guard above now prevents: install used
    # to adopt a foreign pkgi, so the operator believed it was theirs, and this deleted THEIR
    # cluster-admin binding. Two destructive acts from one lossy derivation.
    #
    # Refuse-and-SAY is the honest middle. Silently deleting an unlabelled object risks destroying
    # someone else's; silently LEAVING one risks abandoning a live cluster-admin binding, which is a
    # security residual, not a tidy-up. So we name it and hand over the exact command.
    _del_if_ours() { # <kind> <name> [-n <ns>]
      local kind="$1" obj="$2"; shift 2
      local own errf; errf="$(mktemp)"
      local rc=0
      own="$(kubectl "$@" get "$kind" "$obj" \
             -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>"$errf")" || rc=$?
      if [ -z "$own" ] && kube_is_notfound "$errf" "$obj"; then rm -f "$errf"; return 0; fi
      # ⚠️ A FAILED READ IS NOT AN EMPTY LABEL. Reporting owned-by='<none>' for an object whose
      # owner we could not read asserts a value never obtained, and then hands the operator a
      # `kubectl delete` they were just told they may not run.
      if [ "$rc" -ne 0 ] || [ -s "$errf" ]; then
        log_warn "could NOT READ the owner of ${kind}/${obj}; leaving it in place. The cluster said:"
        sed 's/^/        /' "$errf" >&2 2>/dev/null || true
        rm -f "$errf"; _LEFTOVERS=1; return 0
      fi
      rm -f "$errf"
      # empty label -> ours, from BEFORE the label existed. Delete it and say so: the alternative is
      # abandoning a live cluster-admin ClusterRoleBinding, which is a security residual, not tidy.
      if [ -z "$own" ]; then
        log_warn "${kind}/${obj} carries NO ownership label — treating it as ours (pre-label install) and deleting it."
        kubectl "$@" delete "$kind" "$obj" --ignore-not-found >/dev/null 2>&1 || true
        return 0
      fi
      if [ "$own" = vks-airgap-cicd ]; then
        kubectl "$@" delete "$kind" "$obj" --ignore-not-found >/dev/null 2>&1 || true
        return 0
      fi
      log_warn "NOT deleting ${kind}/${obj}: it carries owned-by='${own}', not ours."
      log_warn "  Named after the package is not owned by it -- the name is the first DNS label of"
      log_warn "  the refName, so another package can derive it. If it really is a leftover of"
      log_warn "  yours, remove it deliberately:"
      log_warn "      kubectl $* delete ${kind} ${obj}"
      _LEFTOVERS=1
    }
    _LEFTOVERS=0
    # The ClusterRoleBinding first: it is the cluster-scoped, cluster-admin one.
    _del_if_ours clusterrolebinding "${name}-pkg-sa-cluster-admin"
    _del_if_ours sa                 "${name}-pkg-sa"     -n "$PKG_NS"
    _del_if_ours secret             "${name}-pkg-values" -n "$PKG_NS"
    # if-then-else, not `A && B || C`: with the && form, a failing `die` would fall through to the
    # success message -- reporting "removed" for something still present (SC2015).
    if kubectl -n "$PKG_NS" get pkgi "$name" >/dev/null 2>&1; then
      die "the PackageInstall is STILL present after the delete. Not reporting success."
    fi
    if [ "${_LEFTOVERS:-0}" -ne 0 ]; then
      log_warn "${PACKAGE} removed, but objects NOT ours were left in place (named above)."
    else
      log_info "${PACKAGE} removed"
    fi ;;

  *) die "usage: vks-package.sh <list|install|uninstall> [package]" ;;
esac
