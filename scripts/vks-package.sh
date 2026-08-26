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
# about becomes real on VKS 3.7+, where the addon framework reconciles this namespace; 43-install-
# istio-package.sh warns when addon CRDs are present. See docs/vks-services/istio.md.
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

    # A dedicated SA + cluster-admin binding: a Standard Package installs cluster-scoped objects
    # (CRDs, webhooks, a CNI DaemonSet), so the installer needs them. Named after the package so
    # the uninstall can remove exactly what it created and nothing else.
    kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${name}-pkg-sa, namespace: ${PKG_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: ${name}-pkg-sa-cluster-admin }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - { kind: ServiceAccount, name: ${name}-pkg-sa, namespace: ${PKG_NS} }
---
apiVersion: packaging.carvel.dev/v1alpha1
kind: PackageInstall
metadata: { name: ${name}, namespace: ${PKG_NS} }
spec:
  serviceAccountName: ${name}-pkg-sa
  packageRef:
    refName: ${PACKAGE}
    versionSelection: { constraints: "${VER}" }
$([ -n "${PKG_VALUES:-}" ] && [ -s "${PKG_VALUES:-}" ] && printf '  values:\n    - secretRef: { name: %s-pkg-values }\n' "$name")
YAML
    if [ -n "${PKG_VALUES:-}" ] && [ -s "${PKG_VALUES:-}" ]; then
      kubectl -n "$PKG_NS" create secret generic "${name}-pkg-values" \
        --from-file=values.yml="$PKG_VALUES" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
    kubectl -n "$PKG_NS" get pkgi "$name" >/dev/null 2>&1 || { log_info "${PACKAGE} is not installed in ${PKG_NS} - nothing to do"; exit 0; }
    [ "${CONFIRM:-}" = yes ] || die "refusing without CONFIRM=yes.
  This removes ${PACKAGE} and everything it deployed from:
      $(kube_target_id)
  Confirm that is the cluster you mean, then re-run:
      make uninstall-vks-package PACKAGE='${PACKAGE}' CONFIRM=yes"
    log_warn "uninstalling ${PACKAGE} from $(kube_target_id)"
    kubectl -n "$PKG_NS" delete pkgi "$name" 2>&1 | sed 's/^/    /'
    # Only what WE created: the SA and binding are named after the package.
    kubectl delete clusterrolebinding "${name}-pkg-sa-cluster-admin" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$PKG_NS" delete sa "${name}-pkg-sa" --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n "$PKG_NS" delete secret "${name}-pkg-values" --ignore-not-found >/dev/null 2>&1 || true
    # if-then-else, not `A && B || C`: with the && form, a failing `die` would fall through to the
    # success message -- reporting "removed" for something still present (SC2015).
    if kubectl -n "$PKG_NS" get pkgi "$name" >/dev/null 2>&1; then
      die "the PackageInstall is STILL present after the delete. Not reporting success."
    fi
    log_info "${PACKAGE} removed" ;;

  *) die "usage: vks-package.sh <list|install|uninstall> [package]" ;;
esac
