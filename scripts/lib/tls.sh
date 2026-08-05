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
  if [ -z "$host" ] || [ -z "$dir" ]; then echo "gen_selfsigned_ca_cert: need <host> <dir>" >&2; return 2; fi
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

# ---------------------------------------------------------------------------
# ca_verifies_endpoint <host> <port> <ca-file>
#   0 = the CA verifies what the endpoint presents
#   1 = connected, but it does NOT verify  (a STALE or WRONG anchor)
#   2 = could not connect at all           (NOT an anchor problem)
#
# WHY THIS EXISTS. Checking that a CA file EXISTS and is non-empty is not checking that it is a
# trust anchor for THIS endpoint. MEASURED 2026-08-05: after a lab rebuild, secrets/supervisor-ca.crt
# still held the DESTROYED lab's VMCA (stored SHA-256 EF:19:5E:… vs live B0:E5:E6:…), and every
# consumer failed with `x509: certificate signed by unknown authority` — a message that names TLS,
# not staleness, so the operator goes hunting for a certificate or network fault. Nothing in the repo
# re-fetches it, so the walk simply could not proceed and did not say why.
#
# THREE THINGS ARE LOAD-BEARING, and the naive form gets all three wrong:
#   1. `openssl s_client` EXITS 0 ON VERIFICATION FAILURE. Only `-verify_return_error` makes the rc
#      meaningful — so a plain `s_client … && echo ok` reports a stale anchor as fine.
#   2. It HANGS on a black-holed endpoint — precisely the case a caller most wants distinguished.
#      `timeout` is mandatory, and rc 124 means UNREACHABLE, never "bad anchor". Conflating those
#      tells an operator whose lab is down that their certificate is wrong.
#   3. Even with the flag, parse `Verify return code:` rather than trusting rc alone, and require
#      `CONNECTED(` before calling it a verification failure — otherwise a refused connection and a
#      wrong CA produce the same verdict.
# ⚠️ 4. `-verify_return_error` CHECKS THE CHAIN AND NOT THE NAME. This is the trap that made this
#      function STRICTLY WEAKER than the transport it gates. MEASURED 2026-08-05 with an oracle — a CA,
#      a leaf carrying `DNS:vcsa.env1.lab.test` and NO IP SAN (the shape lib/govc.sh records for the real
#      VCSA), served on 127.0.0.1:
#        openssl s_client -CAfile ca.crt -verify_return_error   -> "Verify return code: 0 (ok)"   PASS
#        curl --cacert ca.crt https://127.0.0.1/                -> exit 60                        FAIL
#      So a green here meant "the chain is good", NOT "this connection will work" and NOT "this endpoint
#      is who it claims". Two live consequences: 30-vks-login.sh printed "TLS: verifying the Supervisor
#      against <file>" after a check that never verified the name, and its failure text blamed "a
#      DESTROYED and rebuilt Supervisor" — the WRONG diagnosis for a SAN mismatch, sending the operator
#      to re-fetch an anchor that was already correct.
#      There is a security edge too: VMCA signs EVERY ESXi host's certificate in the same vCenter, so a
#      leaf issued by the pinned CA for a DIFFERENT host passed this check.
#      Hence rc 3 — chain OK, NAME wrong — as its own verdict, so callers stop reporting it as staleness.
ca_verifies_endpoint() {
  local host="$1" port="${2:-443}" ca="$3" out rc=0 namearg
  # ⚠️ 5, NOT 1. Returning 1 here said "connected, and the anchor does NOT verify" — i.e. STALE — for
  # an operator who has configured NO CA AT ALL. Opposite remedies: a stale anchor is re-fetched, a
  # missing one is set. 02-env.sh already had to work around this with its own `_ca_verdict=9`
  # sentinel; a caller that did not know to would print the wrong cause.
  [ -s "$ca" ] || return 5
  # An IPv4 literal needs -verify_ip; a name needs -verify_hostname. Passing the wrong one silently
  # verifies nothing, which is the defect this is fixing.
  case "$host" in
    *[!0-9.]*) namearg="-verify_hostname" ;;
    *)         namearg="-verify_ip" ;;
  esac
  out=$(printf '' | timeout "${CA_VERIFY_TIMEOUT:-15}" openssl s_client \
          -connect "${host}:${port}" -servername "$host" \
          -CAfile "$ca" -verify_return_error "$namearg" "$host" 2>&1) || rc=$?
  [ "$rc" -eq 124 ] && return 2                              # timed out: the endpoint, not the anchor
  # ⚠️ THIS TEST MUST PRECEDE THE "ok" TEST, and that ordering is the whole fix.
  # MEASURED (OpenSSL 3.0.13, plain-HTTP port, valid CA file): s_client prints BOTH
  #   line  4: no peer certificate available
  #   line 17: Verify return code: 0 (ok)
  # — there is no certificate, so nothing FAILS verification — and this function returned **0**.
  # An endpoint serving PLAINTEXT was reported as "the CA verifies it". That is the worst possible
  # direction for a trust check, and it is silent.
  #
  # It also poisons anything built on top: a caller refining a TLS diagnosis through this function
  # concludes "transport is fine, so it must be permissions" — which is the exact wrong diagnosis
  # this whole class of fix exists to eliminate.
  #
  # ⚠️ Do NOT switch this to the `Verification:` line instead. On 3.0.13 that reads `Verification: OK`
  # for the SAME plaintext connection, so it is equally useless here, and it is a DIFFERENT string
  # from the `Verify return code:` one below — two spellings, one meaning, neither of them evidence.
  # ⚠️ THE CONJUNCTION IS LOAD-BEARING. `no peer certificate available` ALONE is NOT a plaintext
  # signal: with `-verify_return_error` a FAILED verification aborts the handshake, so no peer cert
  # is stored and that line appears for a wrong anchor and a name mismatch too. MEASURED — testing
  # it alone collapsed THREE verdicts into one (wrong CA 1->4, name mismatch 3->4), i.e. the "fix"
  # was strictly worse than the bug it fixed. Only the plaintext-only test would have missed that;
  # the regression arm is what caught it.
  #
  # Plaintext is precisely the case where verification "passed" VACUOUSLY — it succeeded because
  # there was nothing to verify. So: require the ok line AND the absence of a certificate.
  if printf '%s' "$out" | command grep -q 'Verify return code: 0 (ok)'; then
    printf '%s' "$out" | command grep -q 'no peer certificate available' && return 4
    return 0
  fi
  printf '%s' "$out" | command grep -q 'CONNECTED(' || return 2
  # CONNECTED but not ok. Separate "the anchor is wrong" from "the anchor is right, the NAME is not" —
  # they have opposite remedies (re-fetch the CA vs address the endpoint by its FQDN).
  printf '%s' "$out" | command grep -qiE 'Hostname mismatch|IP address mismatch' && return 3
  return 1
}

# ── OUT-OF-BAND PIN: the only thing that can AUTHENTICATE a self-signed anchor ──────────────────────
# ⚠️ ca_verifies_endpoint (above) and these two answer DIFFERENT QUESTIONS, and neither substitutes for
# the other:
#   ca_verifies_endpoint -> "is this anchor for the lab that is RUNNING?"  (catches a stale/rebuilt lab)
#   ca_pin_verdict       -> "is this anchor the one they TOLD me about?"   (catches an interceptor)
# A MITM's CA verifies a MITM's leaf perfectly, so ca_verifies_endpoint returns 0 and proceeds. Only a
# digest obtained over a DIFFERENT channel can tell the two apart.
#
# MEASURED 2026-08-05 with a live oracle: fetch-ca.sh used to take the CA off the wire, openssl-verify
# the leaf against it and print "VERIFIED". Served an evil self-signed cert, it wrote the evil CA and
# reported success. Self-consistency is not authenticity.
#
# ONE definition, because the normalisation is the drift-prone part: fetch-ca.sh and 30-vks-login.sh
# both route through here rather than each re-deriving "strip colons, lowercase, is it 64 hex".

# ── require_kind_target <what> — refuse to run a KinD-ONLY installer at a cluster that is not ours ──
# MEASURED 2026-08-05 (design round on B66, which was itself refuted — the real defect was one file over):
# `make install-harbor` has ONE prerequisite, `check-env`. Nothing in 06-install-harbor.sh checks that the
# target is KinD. Against a customer kubeconfig it would `ensure_namespace` + `helm upgrade --install
# harbor` into THEIR cluster, consume one of THEIR LoadBalancer VIPs, and then `state_set HARBOR_URL` to
# it — repointing the registry selector every downstream script reads. And it can EXIT 0:
#   * `kind get nodes --name <nonexistent>` returns **rc=0** (MEASURED)
#   * a failing process substitution does NOT trip `set -euo pipefail` (MEASURED: the loop body runs
#     zero times and the script CONTINUES, rc=0)
# so the one KinD-shaped step, `done < <(kind get nodes …)`, silently does nothing and execution reaches
# the state_set. The installer is verb-identical to `install-gitea`/`install-tekton`, which ARE on the
# customer chain, and the only thing distinguishing it is prose in `make help`.
#
# ⚠️ GUARD ON THE TARGET, NEVER ON THE LOCAL RUNTIME. `kind get clusters` queries the container runtime,
# not the kubeconfig — MEASURED: with KUBECONFIG pointed at a nonexistent path it still returns rc=0 and
# does not even read it. So on the ONE machine where this matters (an operator laptop with a local KinD
# cluster AND a customer kubeconfig loaded) that check PASSES while KUBECONFIG points at the customer.
# It also returns rc=0 on "No kind clusters found" — the same rc=0-on-nothing shape as the bug itself.
require_kind_target() {
  local what="${1:-this step}" want cur
  : "${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set (it names the KinD cluster this is scoped to)}"
  want="kind-${KIND_CLUSTER_NAME}"
  # Fails CLOSED: an unset KUBECONFIG, an empty file, or no current-context all yield '' and refuse.
  # MEASURED: `kubectl config current-context` errors with "current-context is not set" in that state.
  cur="$(kubectl config current-context 2>/dev/null)" || true
  [ "$cur" = "$want" ] && return 0
  die "${what} is KinD-ONLY and the current context is NOT this repo's KinD cluster — REFUSING.

    current context: ${cur:-<none set>}
    required:        ${want}

  This is not a formality. Run against another cluster it would install Harbor/ArgoCD INTO it,
  consume one of its LoadBalancer addresses, and repoint this repo's registry selector at it —
  and it would exit 0 while doing so.

  If you meant the local stand-in:  make kind-up            (then re-run this)
  If you are on a real lab:         you do NOT run this — the lab PROVIDES Harbor/ArgoCD as
                                    Supervisor Services. See docs/scenario-1.md."
}

# ca_fingerprint <ca-file> — prints the cert's SHA-256 as colon-hex. rc 1 if it cannot be read.
ca_fingerprint() {
  local f="$1" fp
  [ -s "$f" ] || return 1
  fp="$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*Fingerprint=//')" || true
  [ -n "$fp" ] || return 1
  printf '%s' "$fp"
}

# ca_pin_verdict <ca-file> <raw-pin> — compare a CA against an out-of-band digest.
#   0 = pin set and MATCHES        1 = pin set and MISMATCHES
#   3 = pin NOT set                4 = pin SET but not a SHA-256 digest
#   5 = the CA file could not be read
# ⚠️ 3 and 4 are DELIBERATELY DISTINCT, and 2 is deliberately unused (ca_verifies_endpoint uses it for
# UNREACHABLE, and callers share `case` statements). MEASURED 2026-08-05: an earlier fetch-ca.sh keyed
# its branch on the NORMALISED pin, so ':::' stripped to empty and was treated as "no pin" — the
# operator supplied one and it was silently ignored. Unattended that still refused, but on a terminal
# they would have been asked y/N and would have believed they were pinned. A control a typo in its own
# input can disable is not a control, so "set but unusable" must never collapse into "not set".
ca_pin_verdict() {
  local f="$1" raw="${2:-}" norm fp
  fp="$(ca_fingerprint "$f")" || return 5
  [ -n "$raw" ] || return 3
  norm="$(printf '%s' "$raw" | tr -d ': ' | tr '[:upper:]' '[:lower:]')"
  [[ "$norm" =~ ^[0-9a-f]{64}$ ]] || return 4
  [ "$norm" = "$(printf '%s' "$fp" | tr -d ':' | tr '[:upper:]' '[:lower:]')" ] && return 0
  return 1
}
