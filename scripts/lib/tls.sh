#!/usr/bin/env bash
# scripts/lib/tls.sh — self-signed CA + leaf-cert helpers for the KinD "secure" mode,
# which mimics VCF/VKS 9.1's self-signed-TLS Harbor + ArgoCD (see
# docs/decisions/kind-tls-fidelity.md). Source it; do not execute.
#
# The lab's Harbor/ArgoCD certs are self-signed (cert-manager-minted per instance); we
# reproduce the SAME end state with openssl (deterministic, no cert-manager dependency).
#
# shellcheck shell=bash

[ -n "${__VKS_TLS_SH_LOADED:-}" ] && return 0
__VKS_TLS_SH_LOADED=1

# gen_selfsigned_ca_cert <san-dns-host> <out-dir> [ca-cn]
#   Writes, into <out-dir>: ca.crt, ca.key (a self-signed CA) and tls.crt, tls.key
#   (a leaf cert signed by that CA, CN + subjectAltName = <san-dns-host>).
#   Idempotent: regenerates only when ca.crt or tls.crt is missing, so re-running an
#   install keeps a stable CA (clients that already trust it stay valid).
#   The SAN is the FQDN only (clients always reach the endpoint by name, never by the
#   dynamic LoadBalancer IP), so the cert can be minted before the LB IP is known.
gen_selfsigned_ca_cert() {
  local host="$1" dir="$2" ca_cn="${3:-vks-lab-ca}"
  [ -n "$host" ] && [ -n "$dir" ] || { echo "gen_selfsigned_ca_cert: need <host> <dir>" >&2; return 2; }
  command -v openssl >/dev/null 2>&1 || { echo "gen_selfsigned_ca_cert: openssl not found" >&2; return 2; }
  mkdir -p "$dir"
  if [ -s "$dir/ca.crt" ] && [ -s "$dir/tls.crt" ] && [ -s "$dir/tls.key" ]; then
    return 0   # already minted — keep the stable CA
  fi
  local umask_old; umask_old="$(umask)"; umask 077
  # 1) self-signed CA (analogue of cert-manager's per-instance self-signed CA)
  openssl genrsa -out "$dir/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$dir/ca.key" -sha256 -days 3650 \
    -subj "/CN=${ca_cn}" -out "$dir/ca.crt" 2>/dev/null
  # 2) leaf cert for the endpoint, CN + SAN = the FQDN
  openssl genrsa -out "$dir/tls.key" 4096 2>/dev/null
  openssl req -new -key "$dir/tls.key" -subj "/CN=${host}" \
    -addext "subjectAltName=DNS:${host}" -out "$dir/tls.csr" 2>/dev/null
  openssl x509 -req -in "$dir/tls.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -CAcreateserial -out "$dir/tls.crt" -days 825 -sha256 \
    -extfile <(printf 'subjectAltName=DNS:%s\n' "$host") 2>/dev/null
  rm -f "$dir/tls.csr" "$dir/ca.srl"
  umask "$umask_old"
}

# add_host_entry <ip> <fqdn> [hosts-file]
#   Idempotently map <fqdn> -> <ip> in a hosts file (default /etc/hosts, via $SUDO).
#   Used so `crane`/tools on the jump box resolve the FQDN to the LoadBalancer IP.
add_host_entry() {
  local ip="$1" fqdn="$2" file="${3:-/etc/hosts}"
  [ -n "$ip" ] && [ -n "$fqdn" ] || return 2
  if grep -qE "[[:space:]]${fqdn}(\$|[[:space:]])" "$file" 2>/dev/null; then
    # replace any stale mapping for this fqdn
    ${SUDO:-} sed -i -E "/[[:space:]]${fqdn//./\\.}(\$|[[:space:]])/d" "$file" 2>/dev/null || true
  fi
  printf '%s %s\n' "$ip" "$fqdn" | ${SUDO:-} tee -a "$file" >/dev/null
}
