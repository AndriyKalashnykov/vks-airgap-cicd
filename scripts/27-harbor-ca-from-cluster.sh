#!/usr/bin/env bash
# scripts/27-harbor-ca-from-cluster.sh — get the lab Harbor's CA when it is NOT on the wire.
#
# WHY THIS EXISTS: `make fetch-harbor-ca` extracts the issuer from the TLS handshake, and for a
# Harbor installed as a SUPERVISOR SERVICE that is impossible — MEASURED, it presents exactly ONE
# certificate (its leaf, issuer CN=Harbor CA), so the CA is simply not on the connection.
# fetch-harbor-ca detects that and REFUSES, which is correct: deriving a "CA" from a leaf would
# install a trust anchor that verifies nothing. This is scenario-1 §8 route B, automated.
#
# 🔴 READ THE GRANT THIS COSTS. `get secret harbor-ca-key-pair` ALSO RETURNS THE CA's PRIVATE
# SIGNING KEY (type kubernetes.io/tls, keys ca.crt/tls.crt/tls.key). Kubernetes RBAC has no
# field-level read, so whoever can run this can MINT a certificate for anything every
# HARBOR_CA_FILE consumer trusts. That is an admin-level grant. §8 route A — downloading ca.crt
# from the Harbor UI — needs only a Harbor login and NO Kubernetes access. Prefer it if you can.
#
# ⚠️ FOUR THINGS BELOW ARE LOAD-BEARING; the naive one-liner gets all four wrong and TRUNCATES A
# WORKING CA TO 0 BYTES AT rc=0:
#   1. the LABEL selector, not `get ns | grep harbor` — 0 matches yields an EMPTY namespace and
#      kubectl silently runs against `default`; 2+ matches feeds a multi-line value. Neither is
#      detected. The label is authoritative and we assert it returns exactly one.
#   2. --kubeconfig the SUPERVISOR. Harbor runs there; .env's KUBECONFIG is the GUEST, which has no
#      harbor namespace at all — ambient kubectl gives NotFound at rc=0.
#   3. NEVER redirect straight onto HARBOR_CA_FILE. A jsonpath miss on an EXISTING secret yields
#      rc=0 and empty output, and `base64 -d` on empty yields rc=0 and a 0-byte file, so a renamed
#      key or the wrong cluster REPLACES a good anchor and reports success.
#   4. chmod 0644 BEFORE the mv. mktemp creates 0600 and mv PRESERVES the mode, so without it this
#      deterministically produces a trust anchor that non-root consumers cannot read — and the
#      failure names TRUST, not permissions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# ca_anchor_reject_reason. Pure function definitions -- sourcing executes nothing.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

load_env
require_cmd kubectl
require_cmd openssl

# ⚠️ Taken as an ARGUMENT, exactly as fetch-ca.sh does, NOT read as ${HARBOR_CA_FILE:-default}.
# HARBOR_CA_FILE is UNCOMMENTED in .env.example, so load_env exports it and a dynamic fallback
# here could never fire — check-env-clobber flags precisely that. The Makefile passes the value.
OUT="${1:?usage: 27-harbor-ca-from-cluster.sh <out-file>   (the Makefile passes $(HARBOR_CA_FILE))}"
# ⚠️ VKS_SUPERVISOR_KUBECONFIG FIRST — that is the name the WRITER (30-vks-login.sh)
# honours. These readers used only SUPERVISOR_KUBECONFIG; the defaults coincide, so the
# split was invisible on the box that measured it and would have split the moment an
# operator set either one.
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
[ -f "$SUP" ] || { supervisor_kubeconfig_hint >&2; die "no Supervisor kubeconfig — see the search order above"; }

# The ESCAPE HATCH first — see .env.example. A tenant who cannot LIST NAMESPACES gets a correct
# message from the FORBIDDEN arm below and would otherwise still be stuck.
if [ -n "${HARBOR_SERVICE_NAMESPACE:-}" ]; then
  ns="$HARBOR_SERVICE_NAMESPACE"
else
# CLASSIFY THE PROBE WE ACTUALLY RAN (B110). `2>/dev/null || true` made "I could not ask"
# indistinguishable from "the answer is no", and the zero-match branch below then told the operator
# Harbor was absent. MEASURED: a valid kubeconfig returns 1 namespace here and an expired one
# returns 0, against the same running Harbor.
#
# NO `trap` for this temp file, deliberately: line ~61 below registers its OWN `trap … EXIT` for the
# cert file, and a second EXIT trap REPLACES the first rather than adding to it — so a trap here
# would be silently discarded and leak a file every run. Short-lived, so it is removed explicitly.
_ns_err="$(mktemp)"
_ns_rc=0
ns="$(kubectl --kubeconfig "$SUP" --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-15s}" \
        get ns -l appplatform.vmware.com/serviceId=harbor -o name 2>"$_ns_err")" || _ns_rc=$?
if [ "$_ns_rc" -ne 0 ]; then
  _cls="$(classify_kube_failure "$_ns_err")"
  _err_txt="$(sed 's/^/    /' "$_ns_err")"; rm -f "$_ns_err"
  _hint="Re-issue it:  make vks-login   (scenario-1 Step 3)"
  case "$_cls" in
    STALE_CA)     die "'${SUP}' does not work against this cluster, and the server ANSWERED — so this
  is NOT Harbor being absent. A REBUILT cluster mints a new CA while the address stays the same.
  ${_hint}" ;;
    UNAUTHORIZED) die "the Supervisor REJECTED these credentials, so we never asked where Harbor is.
  ${_hint}" ;;
    FORBIDDEN)    die "authenticated, but this identity may not LIST NAMESPACES, so we cannot find
  Harbor's namespace. That is an RBAC GRANT, not a missing service:
  do NOT re-fetch your kubeconfig, and do NOT install Harbor.
  Ask your platform admin for the namespace and set HARBOR_SERVICE_NAMESPACE in .env." ;;
    UNREACHABLE)  die "could not reach the Supervisor at all. This is NOT evidence your kubeconfig is
  stale — check the address and the network." ;;
    PLAINTEXT)    die "the Supervisor endpoint answered PLAINTEXT where TLS was expected. Check the
  server URL in '${SUP}'." ;;
    NO_KUBE_TARGET) die "'${SUP}' names no cluster to talk to. ${_hint}" ;;
    KUBECONFIG_UNUSABLE) die "'${SUP}' is unusable — something it NAMES is missing, unreadable or
  malformed. ${_hint}" ;;
    *)            log_error "could not ask the Supervisor where Harbor is:"
                  printf '%s\n' "$_err_txt" >&2
                  die "refusing to report Harbor absent on the strength of a probe that did not complete." ;;
  esac
fi
rm -f "$_ns_err"
# ONLY NOW is an empty result a fact about the world.
n="$(printf '%s\n' "$ns" | grep -c . || true)"
[ "$n" = 1 ] || die "expected EXACTLY ONE namespace labelled serviceId=harbor, got ${n}:
$(printf '%s\n' "$ns" | sed 's/^/    /')
  Refusing to guess — an empty value would silently target 'default'."
ns="${ns#namespace/}"
fi
log_info "harbor namespace: ${ns}  (by label, not by grep)"

t="$(mktemp)"; trap 'rm -f "$t"' EXIT
kubectl --kubeconfig "$SUP" -n "$ns" get secret harbor-ca-key-pair \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$t" || true
[ -s "$t" ] || die "extracted ZERO bytes from ${ns}/harbor-ca-key-pair (key .data.ca\\.crt).
  '$OUT' was NOT touched. A jsonpath miss returns rc=0 and empty output, which is why this
  script stages to a temp file — writing straight to the anchor would have destroyed it."
openssl x509 -in "$t" -noout -subject >/dev/null 2>&1 \
  || die "what we extracted is not a certificate. '$OUT' was NOT touched."

# IT MUST BE A TRUST ANCHOR, NOT MERELY A CERTIFICATE (B83c). Parsing was the only check, so a
# LEAF was accepted and installed as the anchor with exit 0. The decision is a PURE function in
# lib/tls.sh so it can be RED-tested offline against real openssl-minted certs -- this script had
# ZERO test coverage of any kind.
_why="$(ca_anchor_reject_reason "$t")"
if [ -n "$_why" ]; then
  die "what we extracted is not a usable trust anchor: ${_why}
  '$OUT' was NOT touched."
fi
# B83(a). SHAPE IS NOT PROVENANCE. ca_anchor_reject_reason above proves self-issued + CA:TRUE, and
# it is SOURCE-BLIND: MEASURED, it ACCEPTS an unrelated `CN=Acme Corporate Root CA` and a STALE
# `CN=Harbor CA` from a destroyed lab. scenario-1 §8's PRIMARY route already guards this ("same
# name, wrong file ... image pulls fail with `certificate signed by unknown authority` long after
# this step") and so does fetch-supervisor-ca.sh; this FALLBACK was the one that did not.
#
# ⚠️ SPLIT host FROM port. ca_verifies_endpoint takes them as SEPARATE args, and HARBOR_URL is a
# BARE host OR host:port (02-env.sh rejects a scheme). Passing it whole repeats B119 exactly: a
# bare host then reaches openssl as a hostname with no port and connects to nothing.
#
# ⚠️ harbor_url_is_placeholder is NOT usable here -- it is defined in 02-env.sh, not a lib, and
# this script sources only lib/os.sh + lib/tls.sh. Calling it would be `command not found` under
# `set -euo pipefail`. is_placeholder (lib/os.sh) plus the documented sentinel is the in-scope pair.
_hu="${HARBOR_URL:-}"
if is_placeholder "$_hu" || [ "$_hu" = harbor.vks.local ]; then
  # DO NOT skip silently. A check that prints nothing is the gate that passes by not looking.
  log_warn "INSTALLED WITHOUT VOUCHING — HARBOR_URL is not set, so this anchor was accepted on its"
  log_warn "  SHAPE alone (self-issued + CA:TRUE). That does NOT prove it is THIS Harbor's CA: a"
  log_warn "  corporate root, or a CA left over from a destroyed lab, has the same shape. Set"
  log_warn "  HARBOR_URL and re-run to have it verified against the live endpoint."
else
  _vhost="${_hu%%:*}"
  case "$_hu" in *:*) _vport="${_hu##*:}" ;; *) _vport=443 ;; esac
  _vrc=0
  ca_verifies_endpoint "$_vhost" "$_vport" "$t" || _vrc=$?
  case "$_vrc" in
    0) log_info "  vouches for: ${_vhost}:${_vport}" ;;
    1) die "this CA does NOT verify ${_vhost}:${_vport}'s certificate — it is the wrong CA, or a
  STALE one from a rebuilt lab. '$OUT' was NOT touched." ;;
    2) die "${_vhost}:${_vport} did not answer, so the anchor could not be verified. That is a
  CONNECTION problem, NOT a verdict about the CA. '$OUT' was NOT touched." ;;
    3) die "the chain verifies but the certificate does not NAME ${_vhost} — is HARBOR_URL the
  address Harbor actually serves? This is a SAN mismatch, not staleness. '$OUT' was NOT touched." ;;
    4) die "${_vhost}:${_vport} presented no certificate. '$OUT' was NOT touched." ;;
    5) die "the extracted file is not usable as an anchor (ca_verifies_endpoint rc=5).
  '$OUT' was NOT touched." ;;
    *) die "could not verify against ${_vhost}:${_vport} (ca_verifies_endpoint rc=${_vrc}).
  '$OUT' was NOT touched." ;;
  esac
fi

subj="$(openssl x509 -in "$t" -noout -subject | sed 's/^subject=//')"
fp="$(openssl x509 -in "$t" -noout -fingerprint -sha256 | cut -d= -f2)"
chmod 0644 "$t"
mv "$t" "$OUT"; trap - EXIT
log_info "wrote ${OUT}"
log_info "  subject:     ${subj}"
log_info "  SHA-256:     ${fp}"
log_warn "  NOT AUTHENTICATED by itself — you took this over a connection this CA is meant to"
log_warn "  protect. Confirm that SHA-256 with whoever operates Harbor, over another channel."
log_info "next: make env-validate   (it proves the anchor actually verifies the live endpoint)"
