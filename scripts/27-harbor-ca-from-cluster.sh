#!/usr/bin/env bash
# scripts/27-harbor-ca-from-cluster.sh — get the lab Harbor's CA when it is NOT on the wire.
#
# WHY THIS EXISTS: `make fetch-harbor-ca` extracts the issuer from the TLS handshake, and for a
# Harbor installed as a SUPERVISOR SERVICE that is impossible — MEASURED, it presents exactly ONE
# certificate (its leaf, issuer CN=Harbor CA), so the CA is simply not on the connection.
# fetch-harbor-ca detects that and REFUSES, which is correct: deriving a "CA" from a leaf would
# install a trust anchor that verifies nothing. This is scenario-1 §6 route B, automated.
#
# 🔴 READ THE GRANT THIS COSTS. `get secret harbor-ca-key-pair` ALSO RETURNS THE CA's PRIVATE
# SIGNING KEY (type kubernetes.io/tls, keys ca.crt/tls.crt/tls.key). Kubernetes RBAC has no
# field-level read, so whoever can run this can MINT a certificate for anything every
# HARBOR_CA_FILE consumer trusts. That is an admin-level grant. §6 route A — downloading ca.crt
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
SUP="${VKS_SUPERVISOR_KUBECONFIG:-${SUPERVISOR_KUBECONFIG:-${REPO_ROOT}/secrets/supervisor.kubeconfig}}"
[ -f "$SUP" ] || die "no Supervisor kubeconfig at '$SUP' — run 'make vks-login' first.
  Harbor is a SUPERVISOR Service; the guest cluster has no harbor namespace at all."

ns="$(kubectl --kubeconfig "$SUP" get ns -l appplatform.vmware.com/serviceId=harbor -o name 2>/dev/null || true)"
n="$(printf '%s\n' "$ns" | grep -c . || true)"
[ "$n" = 1 ] || die "expected EXACTLY ONE namespace labelled serviceId=harbor, got ${n}:
$(printf '%s\n' "$ns" | sed 's/^/    /')
  Refusing to guess — an empty value would silently target 'default'."
ns="${ns#namespace/}"
log_info "harbor namespace: ${ns}  (by label, not by grep)"

t="$(mktemp)"; trap 'rm -f "$t"' EXIT
kubectl --kubeconfig "$SUP" -n "$ns" get secret harbor-ca-key-pair \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$t" || true
[ -s "$t" ] || die "extracted ZERO bytes from ${ns}/harbor-ca-key-pair (key .data.ca\\.crt).
  '$OUT' was NOT touched. A jsonpath miss returns rc=0 and empty output, which is why this
  script stages to a temp file — writing straight to the anchor would have destroyed it."
openssl x509 -in "$t" -noout -subject >/dev/null 2>&1 \
  || die "what we extracted is not a certificate. '$OUT' was NOT touched."

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
