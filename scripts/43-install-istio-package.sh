#!/usr/bin/env bash
# Install Istio as a VKS Standard Package (ISTIO_INSTALL_METHOD=package) instead of with helm.
#
# NUMBERING: 43, not 48. It is a dispatch TARGET of 44 like 45/46/47, but 45-49 are taken (45 traefik,
# 46 istio-helm, 47 attach, 48 istio-preflight, 49 psa-check) -- 48 was a straight collision. 43 keeps
# it adjacent to its family rather than at 51, where the "numbered by execution order" convention
# would read as running after 50. No gate constrains this: they all glob scripts/*.sh, deliberately.
#
# WHY THIS EXISTS. Harbor and ArgoCD install as Supervisor Services; Istio is the only one of the
# three we installed with helm, and a VKS-native path was already here and unused
# (`make install-vks-package`). That path is LIGHTER than either: scripts/vks-package.sh invokes
# kubectl and jq and nothing else -- no vcf CLI, no helm, no imgpkg -- applying a Carvel
# PackageInstall CR that the guest cluster's own kapp-controller reconciles. See BACKLOG.md B476.
#
# WHAT THE PACKAGE DOES NOT DO, and why this script is not just one `make` call. The package installs
# the MESH. It does not install the Gateway API CRDs, it does not create PSA-labelled namespaces
# before its pods schedule, it does not apply our Gateway/VirtualServices, and it does not publish
# INGRESS_LB_IP. Every one of those is shared with 46-install-istio.sh and 47-attach-istio.sh via
# scripts/lib/istio.sh, so this path reuses them rather than re-implementing them.
#
# TWO PACKAGE DEFAULTS THAT MUST BE OVERRIDDEN, both measured 2026-08-25 by rendering the public
# bundle offline (`crane export <bundle> - | tar -x` then ytt -- no cluster needed):
#   - `istio.pilot.resources.requests` is pinned by the package's OWN schema at
#     {cpu: 500m, memory: 2048Mi}. On best-effort-small workers istiod goes Pending: allocatable is
#     2833Mi and this demo already holds ~874Mi. (The record used to say the package left this NULL
#     and inherited an upstream default -- that was wrong; see docs/vks-services/istio.md.)
#   - `istio.pilot.replicas` defaults to **2**, where helm defaults to 1. Two istiods at 2048Mi is
#     twice the problem, and this knob our helm path never had to touch.
# Both are set in k8s/istio/vks-package-values.yaml, which renders istiod at 768Mi / replicas 1 and
# the ingress gateway ON as a LoadBalancer -- verified against the package's own valuesSchema.
#
# ⚠️ VERSION: the package ships Istio 1.28.5+vmware.1-vks.1 against our helm path's 1.30.3 -- a
# two-minor DOWNGRADE, accepted deliberately (B476) for the VMware-certified build.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
# shellcheck source=scripts/lib/istio.sh
. "${SCRIPT_DIR}/lib/istio.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

# kubectl and jq: this script's own header names both, and istio_wait_lb_ip derives the gateway
# Service selector with jq. Without jq that selector is empty, which now fails CLOSED rather than
# publishing an address nothing verified -- so name the missing tool HERE, not 100 lines later.
require_cmd kubectl jq

# EXPORTED, not bare: istio_apply_routes renders manifests with envsubst, which reads the
# ENVIRONMENT. An unexported var renders EMPTY -> `namespace:` blank -> the Gateway lands in
# `default` while the VirtualServices point at istio-ingress/<name> -> 404. (Same note as 46.)
export ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
export ISTIO_GATEWAY_NAMESPACE="${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}"
# THE ROUTES NEED THESE TWO AND THE PACKAGE PATH SET NEITHER -- the defect that made this script
# die at istio_apply_routes AFTER creating 8 namespaces and installing the package (measured:
# "FATAL cannot render manifests — ISTIO_GATEWAY_LABEL(unset)"). 46 pins them; 47 DISCOVERS them
# from a foreign mesh. This path installs the mesh itself, so pinning is right -- and the values are
# read from the package's OWN rendered output, not guessed: its Service is `istio-ingressgateway`
# in `istio-ingress` carrying `istio: ingressgateway`, identical to what 46 pins.
ISTIO_GATEWAY_SERVICE="${ISTIO_GATEWAY_SERVICE:-istio-ingressgateway}"
ISTIO_GATEWAY_LABEL="${ISTIO_GATEWAY_LABEL:-ingressgateway}"
export ISTIO_GATEWAY_SERVICE ISTIO_GATEWAY_LABEL

PKG="${ISTIO_PACKAGE_NAME:-istio.kubernetes.vmware.com}"
VALUES_TPL="${REPO_ROOT}/k8s/istio/vks-package-values.yaml"
[ -s "$VALUES_TPL" ] || die "no ${VALUES_TPL} -- the package's own defaults do NOT fit this sizing (2048Mi x2 istiods); refusing to install without them"

log_info "Istio via VKS Standard Package '${PKG}' (ISTIO_INSTALL_METHOD=package)"

# --- 0. WHERE WILL THE IMAGES COME FROM? DETECT IT; NEVER ASSUME RELOCATION. ---
# This path has NO `global.hub`. kbld resolves the bundle's ImagesLock RELATIVE TO THE BUNDLE, so
# the images come from wherever the Package CR's imgpkgBundle lives -- which this repo does not
# choose and `make mirror` cannot stage (they are digest-addressed inside a vendor bundle repo).
#
# MEASURED 2026-08-25, and this is why the check exists rather than a comment:
#   antrea.tanzu.vmware.com (a cluster-BOOTSTRAP package) -> localhost:5000/tkg/packages/core/...
#   istio.kubernetes.vmware.com (a STANDARD package)      -> projects.packages.broadcom.com/...
# Those are two DIFFERENT mechanisms that merely rhyme. `localhost:5000` is not a property packages
# inherit -- it is written into the bootstrap CRs because the Supervisor relocated THAT repo at
# cluster creation. Reading 18 bootstrap pods on localhost:5000 and concluding "package images never
# leave the cluster" was exactly the wrong generalisation, and it is the one this check prevents.
#
# THE FALSE-GREEN THIS EXISTS FOR: on a DUAL-HOMED lab the install SUCCEEDS from Broadcom, goes
# green, and proves nothing about the air gap -- the same class as a builder base image that
# silently falls back to the public registry. The operator learns on the box that can still fix it.
# Resolve the Package namespace ONCE, by asking the cluster (lib/os.sh). Both the tripwire below
# and the bundle-host probe further down must agree about where they are looking.
# Resolve the Package NAMESPACE once, and PASS IT to the installer (below) so the probe and the
# install provably look at the same place. A PackageInstall resolves its packageRef in ITS OWN
# namespace -- lab-verified 2026-08-10, `Reconcile failed: Package ... not found`, retried 4
# minutes -- so a cluster-wide `-A` probe can match a Package in a namespace no PackageInstall is
# ever created in. That would be this very defect, one level up.
_pkg_ns_rc=0
PKG_NS_RESOLVED="$(vks_package_namespace "$PKG" 2>/dev/null)" || _pkg_ns_rc=$?
case "$_pkg_ns_rc" in
  0) : ;;
  2) log_warn "several namespaces hold Carvel Packages; vks_package_namespace could not choose." ;;
  *) log_warn "could not ask the cluster where Carvel Packages live." ;;
esac
if [ -z "$PKG_NS_RESOLVED" ]; then
  PKG_NS_RESOLVED=vmware-system-tkg
  log_warn "  assuming '${PKG_NS_RESOLVED}' (lab-measured, but UNVERIFIED here)."
  log_warn "  Override with VKS_PACKAGE_NAMESPACE=<ns>."
fi

# VKS 3.7+ ADDON-FRAMEWORK COLLISION -- NAMED HERE, GATED IN vks-package.sh. There is deliberately
# NO probe at this point. A tripwire lived here until 2026-08-28 and could never fire: it ran
# `kubectl get crd` against the AMBIENT kubeconfig, which vks-package.sh:77-88 forces to be a
# GUEST, while the addon CRDs are SUPERVISOR-side (MEASURED on the 3.7 lab: Supervisor 9, guest 0).
# It also failed OPEN -- a kubectl exiting non-zero yields the same count 0 as a healthy guest with
# no addon CRDs -- so it was silent for exactly the namespaced tenant who is the default audience.
#
# Do NOT "fix" it by re-pointing at supervisor_kubeconfig(). That resolver emits ${KUBECONFIG} as
# its LAST candidate (lib/os.sh:872-874), so on a tenant box it returns the GUEST again -- the same
# dead code wearing a fix -- and where it DOES resolve a Supervisor it warns on 100% of VKS 3.7+
# labs, because those CRDs are the FRAMEWORK being installed, not an addon-managed istio.
# (Adversary round 2026-08-28 RAN both; see BACKLOG.md B484.)
#
# WHERE THE HAZARD IS ACTUALLY REFUSED: vks-package.sh's B489 divergence gate, which reads the
# PackageInstall OBJECT before the apply and refuses a foreign owned-by label, a different refName
# under the same derived name, and -- fail-CLOSED -- a read it cannot perform. By object, at the
# moment it matters, whatever created the competitor. NOTHING is verified here.

# WHICH Package do we inspect? The one that will actually be INSTALLED -- and that is not what a
# refName-only filter gives you. MEASURED on the lab 2026-08-26: istio ships EIGHT Package objects,
# one per version (1.27.1 .. 1.30.2), and the count GROWS (it was six before the 3.7 upgrade). The
# installer picks `PKG_VERSION` if set, else the SEMVER-latest (vks-package.sh `_versions`, which
# sorts by vkey). A probe that took whatever the API returned last could therefore inspect a bundle
# that is never installed (false BLOCK) or clear one while a DIFFERENT version installs from
# somewhere else (FALSE GREEN -- the exact false-green the comment above says this exists to stop).
#
# ⚠️ jq, NOT jsonpath. kubectl's jsonpath has no `&&`; the two-predicate filter that looks obvious
# here does not parse, and because the query is wrapped in `2>/dev/null` the parse error would be
# swallowed, leaving an empty result and skipping the check silently on EVERY cluster, forever.
# jq is already mandatory (require_cmd above) and is how vks-package.sh selects versions.
BUNDLE_HOST=""
if [ "${DRY_RUN:-0}" != 1 ]; then
  _pkg_err="$(mktemp)"
  _pkg_json="$(kubectl get package -n "$PKG_NS_RESOLVED" -o json 2>"$_pkg_err")" || _pkg_json=""
  if [ -z "$_pkg_json" ]; then
    # Could not REACH the API. That is not "the bundle is remote" and not "it is local" -- it is
    # unknown, and an air-gapped lab must not be blocked by a probe that could not reach it.
    log_warn "could not read Packages in '${PKG_NS_RESOLVED}' ($(classify_kube_failure "$_pkg_err")) --"
    log_warn "  the bundle host is UNKNOWN. Proceeding, but this run proves NOTHING about the air gap."
    rm -f "$_pkg_err"
  else
    rm -f "$_pkg_err"
    # The version the INSTALL will use. vkey (lib/os.sh) is the shared semver key -- jq's bare
    # `sort` is LEXICOGRAPHIC, so 1.9.0 would beat 1.100.0.
    PKG_VER_RESOLVED="${ISTIO_PACKAGE_VERSION:-$(printf '%s' "$_pkg_json" \
      | jq -r --arg r "$PKG" "$(vkey_jq)"' [.items[]?|select(.spec.refName==$r)|.spec.version]
              |map(select((type=="string") and length>0))|sort_by(vkey)|last // empty' 2>/dev/null || true)}"
    _n="$(printf '%s' "$_pkg_json" | jq -r --arg r "$PKG" --arg v "${PKG_VER_RESOLVED:-}" \
            '[.items[]?|select(.spec.refName==$r and .spec.version==$v)]|length' 2>/dev/null || echo 0)"
    if [ "${_n:-0}" != 1 ]; then
      # REACHED and ambiguous is not the same as could-not-reach. This is the SOLE provenance guard
      # on the package path -- 96-verify-gateway-image.sh exits 0 for this mode by design -- so an
      # ambiguous answer must not pass silently.
      die "cannot identify the ${PKG} Package to inspect: ${_n:-0} match(es) for version
  '${PKG_VER_RESOLVED:-<unresolved>}' in namespace '${PKG_NS_RESOLVED}'.
  This check is the only thing verifying where the package's images come from, so it will not
  proceed on an ambiguous answer. Inspect with:
      kubectl get packages -n ${PKG_NS_RESOLVED} -o custom-columns=NAME:.metadata.name,REF:.spec.refName,VER:.spec.version
  Pin explicitly with ISTIO_PACKAGE_VERSION=<version>, or set VKS_PACKAGE_NAMESPACE=<ns>."
    fi
    # `fetch` is a LIST and Carvel supports several types; reading fetch[0].imgpkgBundle only would
    # return empty for a bundle at index 1 or a non-imgpkgBundle fetch -- another silent skip.
    _pkg_cr="$(printf '%s' "$_pkg_json" | jq -r --arg r "$PKG" --arg v "${PKG_VER_RESOLVED:-}" \
      '[.items[]?|select(.spec.refName==$r and .spec.version==$v)
        |.spec.template.spec.fetch[]?|(.imgpkgBundle.image // .image.url // empty)]|first // empty' 2>/dev/null || true)"
    # registry_hostport (lib/os.sh), NOT `%%/*`: the latter returns the whole reference for a
    # hostless Docker-Hub ref, and the comparison below must be host-for-host.
    BUNDLE_HOST="$(registry_hostport "$_pkg_cr")"
    log_info "inspecting ${PKG} ${PKG_VER_RESOLVED} in ${PKG_NS_RESOLVED} (the version that will install)"
  fi
fi
if [ -n "$BUNDLE_HOST" ]; then
  # EXACT host:port, never a prefix. MEASURED 2026-08-26, the prefix form was wrong BOTH ways:
  # `harbor.lab` ACCEPTED `harbor.lab.evil.example` (false GREEN — a lookalike read as our mirror),
  # and a scheme or trailing slash in HARBOR_URL false-BLOCKED the real one. Both sides now go
  # through the same parser, so the two spellings of one host cannot disagree.
  #
  # depot*.kube-system.svc: the VCF Software Depot, and it IS an air-gapped path. ARTEFACT-VERIFIED
  # 2026-08-26 (not lab-verified — we have no relocated depot): the two shipped VKS service YAMLs
  # differ by exactly this field —
  #   vsphere-kubernetes-service-legacy-3.7.1+v1.36.yaml -> projects.packages.broadcom.com/...
  #   vsphere-kubernetes-service-3.7.1+v1.36.yaml        -> depot.kube-system.svc/vcf/...
  # — both sha256 matching the pinned checksums. Broadcom's air-gapped 9.1 guide §7b rewrites it to
  # depot-image-proxy.kube-system.svc.cluster.local. Refusing those REFUSES the vendor's own
  # sanctioned air-gapped configuration and sends the operator to request a relocation they already
  # performed. See B485 for the open question of whether the CR carries the relocated host at all.
  _harbor_hp="$(registry_hostport "${HARBOR_URL:-}")"
  case "$BUNDLE_HOST" in
    localhost:*|127.0.0.1:*|"[::1]":*)
      log_info "package images resolve from ${BUNDLE_HOST} — local, air-gap safe" ;;
    depot.kube-system.svc:*|depot-image-proxy.kube-system.svc.cluster.local:*|depot*.kube-system.svc*:*)
      log_info "package images resolve from ${BUNDLE_HOST} — the Supervisor's Software Depot, air-gap safe" ;;
    *)
      if [ -n "${HARBOR_URL:-}" ] && [ "$BUNDLE_HOST" = "$_harbor_hp" ]; then
        log_info "package images resolve from ${BUNDLE_HOST} — our mirror, air-gap safe"
      elif [ "${ISTIO_PACKAGE_ALLOW_REMOTE:-0}" = 1 ]; then
        log_warn "package images resolve from ${BUNDLE_HOST}, which is NOT ${HARBOR_URL:-your mirror}."
        log_warn "  ISTIO_PACKAGE_ALLOW_REMOTE=1 — proceeding. This install is NOT air-gapped, and a"
        log_warn "  green result here says nothing about whether it would work without internet."
      else
        die "the ${PKG} bundle resolves from '${BUNDLE_HOST}', not a local or mirrored registry.
  kbld resolves this package's images RELATIVE TO ITS BUNDLE, so they would be pulled from there --
  and \`make mirror\` cannot stage them: they are digest-addressed inside a vendor bundle repo, and
  images/images.txt carries the HELM versions (istio 1.30.3), not this package's.
  Relocating the standard-packages repository is a PLATFORM-TEAM action (imgpkg copy), outside this
  repo. Ask them, or install Istio with helm instead:
      make install-ingress ISTIO_INSTALL_METHOD=helm
  On a lab WITH internet you can proceed deliberately with ISTIO_PACKAGE_ALLOW_REMOTE=1 -- knowing
  the run then proves nothing about the air gap."
      fi ;;
  esac
fi

# --- 1. Gateway API CRDs ------------------------------------------------------
# The package does not ship them and Istio never has. On a VKS guest cluster they are usually
# already present as their own Standard Package (gateway-api.tanzu.vmware.com); this is idempotent
# either way and is the same helper the helm path uses.

# B480: REFUSE before ANY mutation. Below this line the script applies cluster-scoped Gateway
# API CRDs and then creates + PSA-RELABELS $ISTIO_NAMESPACE -- so a guard placed near the
# package install would first relabel a FOREIGN istio-system, which 48-istio-preflight.sh
# already names as a harm. This is the direction that matters: kapp does NOT refuse to adopt.
istio_refuse_foreign_owner "$ISTIO_NAMESPACE" package

istio_ensure_gwapi_crds

# --- 2. Namespaces, PSA-LABELLED BEFORE ANYTHING SCHEDULES --------------------
# ⚠️ ORDERING IS THE WHOLE POINT, exactly as in 46: kapp-controller creates the namespace itself if
# it is absent, and it creates it UNLABELLED -- so on a cluster enforcing PSA the pods are rejected
# before the label lands. Create and label FIRST; the package then adopts them.
# ⚠️ NEITHER goes through ensure_namespace: that helper also stamps istio-injection=disabled, which
# is correct for APP namespaces and FATAL here -- the gateway ships `image: auto` and only the
# injection webhook rewrites it, so excluding the namespace leaves the pod on `ErrImagePull: auto`.
run bash -c "kubectl create namespace \"$ISTIO_NAMESPACE\" --dry-run=client -o yaml | kubectl apply -f -"
psa_label_namespace "$ISTIO_NAMESPACE" "${PSA_LEVEL_ISTIO_SYSTEM:-baseline}"
run bash -c "kubectl create namespace \"$ISTIO_GATEWAY_NAMESPACE\" --dry-run=client -o yaml | kubectl apply -f -"
psa_label_namespace "$ISTIO_GATEWAY_NAMESPACE" "${PSA_LEVEL_INGRESS:-baseline}"

# --- 3. The package ------------------------------------------------------------
# Rendered from the committed template so the namespaces follow the env rather than being a second
# hardcoded copy -- the values file is the ONE place the tunables live, and this keeps it that way.
VALUES_RENDERED="$(mktemp)"; trap 'rm -f "$VALUES_RENDERED"' EXIT
# Both vars are EXPORTED above, so envsubst reads them from the environment -- no `env VAR=...`
# prefix, which check-env-clobber correctly reads as a per-run override of a documented value.
# shellcheck disable=SC2016  # the single quotes are envsubst's ALLOWLIST argument -- it must
# receive the literal ${NAME} text, and expanding it here would substitute before envsubst runs,
# leaving it with an empty allowlist and therefore substituting NOTHING.
envsubst '${ISTIO_NAMESPACE} ${ISTIO_GATEWAY_NAMESPACE}' < "$VALUES_TPL" > "$VALUES_RENDERED"
# PASS the resolved version and namespace. Without this the installer re-runs its own version
# selection 50 lines later and can pick a DIFFERENT Package than the one just cleared -- a
# PackageRepository reconcile between the two queries is enough, and that is exactly the event
# that grew istio from six Packages to eight. vks-package.sh validates an explicit pin against
# the offered list and dies with the real list, so a version that vanished mid-run fails CLOSED.
run env PACKAGE="$PKG" PKG_VERSION="${PKG_VER_RESOLVED:-${ISTIO_PACKAGE_VERSION:-}}" VKS_PACKAGE_NAMESPACE="$PKG_NS_RESOLVED" PKG_VALUES="$VALUES_RENDERED" \
  "${SCRIPT_DIR}/vks-package.sh" install "$PKG"

# --- 4. RE-ASSERT the PSA labels ----------------------------------------------
# kapp-controller may have re-applied the namespaces from the bundle; 46 re-asserts for the same
# reason after helm. Cheap, and the alternative is a silently-unlabelled namespace.
psa_label_namespace "$ISTIO_NAMESPACE" "${PSA_LEVEL_ISTIO_SYSTEM:-baseline}"
psa_label_namespace "$ISTIO_GATEWAY_NAMESPACE" "${PSA_LEVEL_INGRESS:-baseline}"

# --- 5. Gateway + VirtualServices (shared with the helm and attach paths) -----
istio_apply_routes

# --- 6. LoadBalancer address ---------------------------------------------------
LB_IP="$(istio_wait_lb_ip)" || die "istio ingress-gateway has no LoadBalancer address"
log_info "istio ingress-gateway LoadBalancer address: ${LB_IP}"

# --- 7. Publish ----------------------------------------------------------------
# Published HERE, not in 44's dispatcher, so the controller and the IP land together: a run that
# died earlier must not leave "istio" beside the PREVIOUS controller's IP (46 and 47 do the same).
state_set INGRESS_LB_IP "$LB_IP"
state_set INGRESS_CONTROLLER "istio"
state_set ISTIO_INSTALL_METHOD "package"
log_info "published INGRESS_LB_IP=${LB_IP} to $(state_file)"
log_info "Istio installed AS A VKS PACKAGE. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  $(ingress_infra_hosts)$(app_hosts_flat)"
log_info ""
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
