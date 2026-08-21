#!/usr/bin/env bash
# vks-trust-probe — does THIS guest cluster trust our Harbor, and by what mechanism?
#
# WHY THIS EXISTS. The question "does the guest trust Harbor's CA?" was answered three times in one
# session by hand-rolled throwaway pods, each with a different bug (a spec PSA rejected, a heredoc
# escape, an image with no shell). This repo's own rule is that a comparator gets promoted to a
# supported target rather than left as scratch - so here it is, parameterised and cleaning up after
# itself.
#
# WHAT IT PROVES, and this is the honest boundary:
#   1. PROPAGATION - whether the Harbor CA we hold locally is present INSIDE the cluster, by
#      comparing SHA-256 fingerprints. A match proves the platform put OUR CA there; it does not
#      say which consumer uses it.
#   2. A REAL PULL - a fresh `imagePullPolicy: Always` pull, which forces a registry round-trip and
#      therefore a TLS handshake from the node. Success proves node->Harbor works RIGHT NOW.
#
# WHAT IT DOES **NOT** PROVE, stated because the green is otherwise over-readable:
#   - It does NOT distinguish node-level CA TRUST from containerd configured INSECURE for this
#     registry. Both produce an identical successful pull. Distinguishing them needs the node's
#     containerd config, which needs node access this probe deliberately does not take.
#   - A cached image does not weaken it: `Always` still re-resolves the manifest over TLS. But the
#     reported duration WILL be short in that case, so do not read speed as "no pull happened".
#
# It NEVER authenticates to vCenter. vSphere SSO locks the account permanently after 3 failed binds
# (docs/matrix-standing-rules.md F.2), and nothing here is worth that.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${KUBECONFIG:?set KUBECONFIG (or run: make vks-login) - this probe reads a cluster}"
HARBOR_CA_FILE="${HARBOR_CA_FILE:-./secrets/harbor-ca.crt}"
# The image is DERIVED from a running workload, not hardcoded: the point is to pull something this
# cluster genuinely has in Harbor. An enumerated tag would rot on the next pipeline run.
PROBE_NS="${PROBE_NS:-vks-trust-probe-$$}"
PROBE_IMAGE="${PROBE_IMAGE:-}"

_cleanup() { [ -n "${_ns_made:-}" ] && kubectl delete ns "$PROBE_NS" --wait=false >/dev/null 2>&1; }
trap _cleanup EXIT

_fp() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ': ' | tr '[:upper:]' '[:lower:]'; }

log_info "cluster: $(kubectl config current-context 2>/dev/null || echo '<no context>')"

# ---- 1. PROPAGATION -------------------------------------------------------------------------
echo
echo "  1. Is OUR Harbor CA present inside the cluster?"
_local_fp=""
if [ -s "$HARBOR_CA_FILE" ]; then _local_fp="$(_fp < "$HARBOR_CA_FILE")"; fi
if [ -z "$_local_fp" ]; then
  echo "     SKIP - no local CA at ${HARBOR_CA_FILE} to compare against (run: make fetch-harbor-ca)"
else
  echo "     ours (${HARBOR_CA_FILE}): ${_local_fp}"
  _found=0
  # kapp-controller is the consumer VKS is known to wire; it is the cheapest place to look. This is
  # a LIST of places to check, so it rots - print what was checked, never imply completeness.
  # One entry today. Kept as a LIST because it is one, and printed per-entry so the output states
  # what was checked rather than implying the check was exhaustive. `while read` splits in zsh too.
  printf '%s\n' "${TRUST_PROBE_LOCATIONS:-tkg-system/kapp-controller-config/caCerts}" \
  | while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    _ns="${loc%%/*}"; _rest="${loc#*/}"; _cm="${_rest%%/*}"; _key="${_rest##*/}"
    _cm_val="$(kubectl -n "$_ns" get cm "$_cm" -o jsonpath="{.data.${_key}}" 2>/dev/null || true)"
    [ -n "$_cm_val" ] || { printf '     %-42s <absent>\n' "$loc"; continue; }
    _rfp="$(printf '%s' "$_cm_val" | _fp)"
    if [ "$_rfp" = "$_local_fp" ]; then printf '     %-42s MATCH\n' "$loc"; _found=1
    else printf '     %-42s present, DIFFERENT cert (%s)\n' "$loc" "${_rfp:0:16}..."; fi
  done
  # NOTE: the loop above runs in a SUBSHELL (it is the right-hand side of a pipe), so `_found` set
  # inside it does NOT survive. Re-derive it here rather than reading a variable the pipe discarded -
  # this repo has a recorded defect where exactly that made a counter read 0.
  _found=0
  _cm_val="$(kubectl -n tkg-system get cm kapp-controller-config -o jsonpath='{.data.caCerts}' 2>/dev/null || true)"
  [ -n "$_cm_val" ] && [ "$(printf '%s' "$_cm_val" | _fp)" = "$_local_fp" ] && _found=1
  [ "$_found" = 1 ] \
    && echo "     => the platform propagated OUR CA into the cluster. We did not put it there." \
    || echo "     => not found in the location(s) checked above (that list is not exhaustive)."
fi

# ---- 2. A REAL PULL -------------------------------------------------------------------------
echo
echo "  2. Can a node pull from Harbor RIGHT NOW (fresh TLS handshake)?"
if [ -z "$PROBE_IMAGE" ]; then
  # Require a namespace that ALSO carries `harbor-pull`. The first version took the first Harbor
  # image anywhere, landed in `ci` (whose secret is named harbor-dockerconfig), and produced a
  # FailedToRetrieveImagePullSecret warning - the probe then measured an anonymous pull rather than
  # the credentialed path the workloads actually use. Measured on a real lab 2026-08-21.
  for _ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null); do
    kubectl -n "$_ns" get secret harbor-pull >/dev/null 2>&1 || continue
    _i="$(kubectl -n "$_ns" get pod -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
    case "$_i" in "${HARBOR_URL:-harbor}"*) PROBE_IMAGE="$_i"; _probe_src_ns="$_ns"; break ;; esac
  done
fi
if [ -z "$PROBE_IMAGE" ]; then
  echo "     SKIP - found no running workload using a ${HARBOR_URL:-harbor} image to probe with."
  exit 0
fi
echo "     image: ${PROBE_IMAGE}  (from namespace ${_probe_src_ns:-?})"

kubectl create ns "$PROBE_NS" >/dev/null 2>&1 && _ns_made=1
# VKS enforces PSA `restricted` by default, so the probe pod is restricted-COMPLIANT rather than
# relabelling the namespace. A probe that needs the policy weakened to run is measuring the wrong box.
kubectl -n "${_probe_src_ns}" get secret harbor-pull -o yaml 2>/dev/null \
  | sed "s/namespace: ${_probe_src_ns}/namespace: ${PROBE_NS}/" \
  | grep -vE 'resourceVersion|uid:|creationTimestamp' \
  | kubectl apply -n "$PROBE_NS" -f - >/dev/null 2>&1

cat <<YAML | kubectl apply -n "$PROBE_NS" -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: pullprobe}
spec:
  restartPolicy: Never
  imagePullSecrets: [{name: harbor-pull}]
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: ${PROBE_IMAGE}
    imagePullPolicy: Always
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML

for _i in $(seq 1 "${PROBE_WAIT_ITERATIONS:-12}"); do
  _p="$(kubectl -n "$PROBE_NS" get pod pullprobe -o jsonpath='{.status.phase}{"|"}{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  case "$_p" in Running*|Succeeded*|*ErrImagePull*|*ImagePullBackOff*) break ;; esac
  sleep "${PROBE_WAIT_INTERVAL:-5}"
done
# The EVENT is the evidence, not the phase: a pod can reach Running from a cached layer set, and the
# event is what names the registry round-trip.
_ev="$(kubectl -n "$PROBE_NS" get events --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'pulled|failed|x509' | tail -3 || true)"
printf '%s\n' "$_ev" | sed 's/^/     /'
case "$_ev" in
  *"Successfully pulled"*) echo "     => the node completed a TLS handshake with Harbor and pulled. Node<->Harbor WORKS." ;;
  *x509*|*"Failed"*)       echo "     => the pull FAILED. Read the event above: an x509 line is a TRUST problem." ;;
  *)                       echo "     => inconclusive - no pull event was recorded within the wait budget." ;;
esac
case "$_ev" in
  *FailedToRetrieveImagePullSecret*)
    echo "     ! the pull secret did NOT resolve, so any success above was an ANONYMOUS pull -"
    echo "       it does not exercise the credentialed path the workloads use." ;;
esac
echo
echo "  NOT PROVEN by a green here: whether node trust is CA-based or containerd is configured"
echo "  INSECURE for this registry. Both produce the same successful pull. See this script's header."
