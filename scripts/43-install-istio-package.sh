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
BUNDLE_HOST=""
if [ "${DRY_RUN:-0}" != 1 ]; then
  _pkg_cr="$(kubectl get package -n "${VKS_PACKAGE_NAMESPACE:-vmware-system-tkg}"     -o jsonpath="{range .items[?(@.spec.refName=='${PKG}')]}{.spec.template.spec.fetch[0].imgpkgBundle.image}{'\n'}{end}"     2>/dev/null | tail -1 || true)"
  BUNDLE_HOST="${_pkg_cr%%/*}"
fi
if [ -n "$BUNDLE_HOST" ]; then
  case "$BUNDLE_HOST" in
    localhost:*|127.0.0.1:*|"${HARBOR_URL:-__none__}"*)
      log_info "package images resolve from ${BUNDLE_HOST} — local/mirrored, air-gap safe" ;;
    *)
      if [ "${ISTIO_PACKAGE_ALLOW_REMOTE:-0}" = 1 ]; then
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
run env PACKAGE="$PKG" PKG_VERSION="${ISTIO_PACKAGE_VERSION:-}" PKG_VALUES="$VALUES_RENDERED" \
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
log_info "    ${LB_IP}  ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_hosts_flat)"
log_info ""
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
