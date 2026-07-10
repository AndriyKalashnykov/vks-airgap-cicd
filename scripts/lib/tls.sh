#!/usr/bin/env bash
# scripts/lib/tls.sh — self-signed CA + leaf-cert helper for the KinD "secure" mode,
# which mimics VCF/VKS 9.1's self-signed-TLS Harbor + ArgoCD (see
# docs/decisions/kind-tls-fidelity.md). Source it; do not execute.
#
# The lab's Harbor/ArgoCD certs are self-signed (cert-manager-minted per instance); we
# reproduce the SAME end state with openssl (deterministic, no cert-manager dependency).
# The endpoint is the LoadBalancer IP (sudo-free: no /etc/hosts / CoreDNS needed — the IP
# is routable from the host AND in-cluster on the kind network), so the leaf cert's SAN is
# that IP. Consumers trust the CA via SSL_CERT_FILE (host tools) / containerd certs.d
# (nodes) / an in-cluster ConfigMap (Kaniko) — never the system trust store (no sudo).
#
# shellcheck shell=bash

[ -n "${__VKS_TLS_SH_LOADED:-}" ] && return 0
__VKS_TLS_SH_LOADED=1

# gen_selfsigned_ca_cert <endpoint-host-or-ip> <out-dir> [ca-cn]
#   Writes, into <out-dir>: ca.crt, ca.key (a self-signed CA) and tls.crt, tls.key
#   (a leaf cert signed by that CA, CN + subjectAltName = the endpoint). The SAN is an
#   IP:<addr> entry when <endpoint> looks like an IPv4 address, else DNS:<host>.
#   The CA is STABLE across runs (kept if present, so already-distributed trust stays
#   valid); the LEAF is always regenerated so its SAN matches the CURRENT LB IP (which
#   cloud-provider-kind may reassign between cluster rebuilds).
gen_selfsigned_ca_cert() {
  local host="$1" dir="$2" ca_cn="${3:-vks-lab-ca}"
  [ -n "$host" ] && [ -n "$dir" ] || { echo "gen_selfsigned_ca_cert: need <host> <dir>" >&2; return 2; }
  command -v openssl >/dev/null 2>&1 || { echo "gen_selfsigned_ca_cert: openssl not found" >&2; return 2; }
  mkdir -p "$dir"
  local umask_old; umask_old="$(umask)"; umask 077

  # 1) self-signed CA (analogue of cert-manager's per-instance self-signed CA) — stable.
  if [ ! -s "$dir/ca.crt" ] || [ ! -s "$dir/ca.key" ]; then
    openssl genrsa -out "$dir/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$dir/ca.key" -sha256 -days 3650 \
      -subj "/CN=${ca_cn}" -out "$dir/ca.crt" 2>/dev/null
  fi

  # 2) leaf cert for the endpoint — SAN = IP:<addr> or DNS:<host>. Always regenerated.
  local san
  if printf '%s' "$host" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    san="IP:${host}"
  else
    san="DNS:${host}"
  fi
  openssl genrsa -out "$dir/tls.key" 4096 2>/dev/null
  openssl req -new -key "$dir/tls.key" -subj "/CN=${host}" \
    -addext "subjectAltName=${san}" -out "$dir/tls.csr" 2>/dev/null
  openssl x509 -req -in "$dir/tls.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -CAcreateserial -out "$dir/tls.crt" -days 825 -sha256 \
    -extfile <(printf 'subjectAltName=%s\n' "$san") 2>/dev/null
  rm -f "$dir/tls.csr" "$dir/ca.srl"
  # The CA cert (and the leaf cert) are PUBLIC trust material — make them world-readable so
  # EVERY consumer can read them regardless of uid: node containerd (docker cp), the SSL_CERT_FILE
  # bundle, podman --cert-dir, and a jump-box container whose service user may land on a DIFFERENT
  # uid than the host minter (e.g. Ubuntu 24.04/26.04 ship a default `ubuntu` at uid 1000, so a
  # useradd'd service user is uid 1001 and cannot read a host-uid-1000 0600 file → TLS trust fails
  # with a misleading "error adding trust anchors from file"). Only the *.key private keys stay 0600.
  [ -f "$dir/ca.crt" ]  && chmod 0644 "$dir/ca.crt"
  [ -f "$dir/tls.crt" ] && chmod 0644 "$dir/tls.crt"
  umask "$umask_old"
}

# ca_bundle_with_system <ca-file> <out-bundle>
#   Build a CA bundle = the system trust store + <ca-file>, so a host tool pointed at it
#   via SSL_CERT_FILE trusts BOTH upstream (public) registries and our self-signed Harbor
#   in one run — without touching the (root-owned) system store. No sudo.
ca_bundle_with_system() {
  local ca="$1" out="$2" sys
  [ -s "$ca" ] || { echo "ca_bundle_with_system: CA file '$ca' missing" >&2; return 2; }
  mkdir -p "$(dirname "$out")"
  for sys in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
             /etc/ssl/cert.pem; do
    [ -r "$sys" ] && { cat "$sys"; break; }
  done > "$out" 2>/dev/null || true
  printf '\n' >> "$out"
  cat "$ca" >> "$out"
}
