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
  # ARITY GUARD FIRST. Called with ONE argument this used to write the bundle to the empty path and
  # print nothing, returning 0 -- so a caller writing `X="$(ca_bundle_with_system "$ca" || fallback)"`
  # got an EMPTY X with no error, the `||` never fired, and `SSL_CERT_FILE=` surfaced minutes later as
  # `x509: certificate signed by unknown authority` from crane, which reads as a LAB problem rather
  # than a call-site typo. MEASURED 2026-08-22: cost a full mirror run (5/5 images "FAILED") before
  # anyone looked at the argument list.
  [ $# -eq 2 ] || { echo "ca_bundle_with_system: needs 2 args (<ca-file> <out-bundle>), got $#" >&2; return 2; }
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
  # ⚠️ `-s` IS NOT "USABLE". MEASURED against a healthy TLS endpoint, FIVE distinct broken
  # anchors all satisfy `-s` and all returned **2** ("the endpoint is unreachable"): a
  # DIRECTORY, a mode-000 file, whitespace-only, a truncated PEM, and plain garbage text.
  # openssl fails to LOAD the CA and so never prints `CONNECTED(`, and the check below then
  # reads that absence as a network fault. An anchor problem reported as a reachability
  # problem is the exact class this function exists to delete — and 02-env.sh compounds it by
  # replying "this is NOT evidence the anchor is wrong."
  openssl x509 -in "$ca" -noout >/dev/null 2>&1 || return 5
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
    if printf '%s' "$out" | command grep -q 'no peer certificate available'; then
      # ⚠️ "NO CERTIFICATE" IS TWO DIFFERENT FAULTS, and they need OPPOSITE handling.
      # MEASURED — the outputs are cleanly distinct:
      #   accept-then-close : `unexpected eof while reading` / `handshake has read 0 bytes`
      #   plaintext/banner  : `wrong version number`         / `handshake has read 5 bytes`
      # A listener that ACCEPTS then CLOSES with zero bytes is what an LB VIP looks like while
      # its backend is still coming up — a Supervisor apiserver mid-start. That is RETRYABLE,
      # and verdict 2 already says exactly the right thing ("NOT evidence the anchor is wrong
      # — retry"). Reporting it as 4 hard-stopped the operator and told them to change a
      # SUPERVISOR_HOST that was correct. Deterministic, 6/6 — not a race.
      printf '%s' "$out" | command grep -qE 'unexpected eof while reading|handshake has read 0 bytes' \
        && return 2
      return 4
    fi
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
#
# ⚠️ B231: THE REFUSAL IS CORRECT AND ITS REMEDY USED TO LOOP. `make kind-up` writes its own kubeconfig
# at its OWN path (05-kind-up.sh: `secrets/kind.kubeconfig`) and `state_set KUBECONFIG` to it — but
# KUBECONFIG is the FIRST entry in load_env's selector snapshot (lib/os.sh), so a value the caller
# EXPORTED outranks everything any file records. And the nested lab actively TEACHES the operator to
# export it: `make kubectl-login` prints "use it with:  export KUBECONFIG=<path>" and its README repeats
# it three times. Follow that instruction, then run a KinD-only step in the same shell, and this guard
# refuses — correctly. Run the `make kind-up` it used to recommend as the only remedy, which CANNOT
# clear a variable in the CALLER's shell, and the next attempt refuses IDENTICALLY: the operator loops.
# The third arm below names the real fix. No tracker id in the PRINTED text — an operator cannot
# resolve a private index; that is what this comment is for.
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
                                    Supervisor Services. See docs/scenario-1.md.
  If it STILL refuses after that:   unset KUBECONFIG        — you have it EXPORTED in this shell.
                                    A login prints an 'export KUBECONFIG=...' line and people follow
                                    it; an exported value OUTRANKS the path 'make kind-up' records,
                                    so kind-up cannot clear it and re-running refuses identically."
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

# vks_ca_default — point VKS_CA_CERT_FILE at what `make fetch-supervisor-ca` wrote, if it is there.
#
# MEASURED 2026-08-10 walking docs/scenario-1.md on a clean container: Step 3 runs
# `make fetch-supervisor-ca` (writes secrets/supervisor-ca.crt) and then commands that need a CA,
# but .env.example's VKS_CA_CERT_FILE line is COMMENTED, so the var was unset and each consumer
# died — vks-login with `x509: certificate signed by unknown authority`, fetch-argocd-kubeconfig
# with `set VKS_CA_CERT_FILE=<path>`. Two scripts, same gap, fixed once here so a third consumer
# cannot be added without it.
#
# Only when the file EXISTS and is non-empty: a Supervisor with a publicly-trusted certificate must
# keep working with no CA at all, and passing --ca-certificate a missing path would break it.
vks_ca_default() {
  [ -n "${VKS_CA_CERT_FILE:-}" ] && return 0
  local _d="${REPO_ROOT:-.}/secrets/supervisor-ca.crt"
  [ -s "$_d" ] || return 0
  VKS_CA_CERT_FILE="$_d"; export VKS_CA_CERT_FILE
  log_info "TLS: using the CA that 'make fetch-supervisor-ca' wrote (${VKS_CA_CERT_FILE})"
}

# ca_anchor_reject_reason <cert-file> — prints WHY the file is not a usable trust ANCHOR, or
# nothing at all when it is one. Pure: reads a FILE with openssl, never a cluster.
#
# Why it exists (B83c): 27-harbor-ca-from-cluster.sh only checked that the blob PARSED as a
# certificate, so a LEAF was accepted and installed as the anchor with exit 0. That is harmless
# only while the secret being read happens to carry ca.crt == tls.crt. It stops being harmless the
# moment a one-token jsonpath slip, or a secret made by `kubectl create secret tls` (which emits
# tls.crt/tls.key and NO ca.crt -- exactly what 06-install-harbor.sh:201 does), puts a leaf in
# front of it. The failure would be silent here and surface much later as a pull that cannot
# verify anything.
#
# Two properties, both required. A cross-signed intermediate fails the first and is correctly
# rejected: this file is consumed as a STANDALONE anchor, not as part of a chain.
#
# It tests self-ISSUED (subject == issuer), NOT self-SIGNED. A certificate whose DN matches its
# own issuer DN but was signed by a FOREIGN key is accepted here -- measured, and `openssl verify
# -CAfile it it` rejects it. Adding that verify as a third conjunct is the one-line upgrade.
#
# ⚠️ DO NOT replace this with `openssl verify -CAfile <f> <f>`: MEASURED, it returns OK for a
# self-signed CA:FALSE certificate, because OpenSSL does not require CA:TRUE of a depth-0
# self-signed cert. It is a partial alternative for the self-issued half only, and swapping to it
# would DELETE the CA:TRUE dimension entirely.
#
# NAMED RESIDUALS, so they are not mistaken for coverage: keyUsage is not checked (a CA:TRUE cert
# lacking keyCertSign is accepted here and refused by OpenSSL as a signer -- measured), and expiry
# is not checked (`openssl x509 -checkend 0` is the one-line arm). ADOPTION: 1 of 5 anchor-
# installing sites uses this today. The next one is fetch-ca.sh:121's MULTI-CERT branch, which
# takes 'the last (the issuer)' with no self-issued and no CA:TRUE test at all.
#
# `case` rather than `openssl ... | grep -q`: under `set -o pipefail` grep -q exits at its first
# match and SIGPIPEs openssl, so the pipeline returns 141 and the caller's `||` fires on a CORRECT
# certificate. That false-die is a documented trap in this repo.
ca_anchor_reject_reason() {
  local f="${1:-}" subj issu bc n
  [ -s "$f" ] || { printf 'it is empty or missing'; return 0; }
  openssl x509 -in "$f" -noout -subject >/dev/null 2>&1 || { printf 'it is not a certificate'; return 0; }
  # A CAfile is a BUNDLE format and the caller installs the WHOLE file, but `openssl x509 -in`
  # reads only the FIRST PEM block -- so a second, entirely unvalidated certificate would become
  # a trusted root. MEASURED: `cat ca.crt evil.crt > bundle.crt` was ACCEPTED. Validate what is
  # actually installed, or refuse to guess which block is the anchor.
  n="$(grep -c 'BEGIN CERTIFICATE' "$f" 2>/dev/null || true)"
  if [ "${n:-0}" != 1 ]; then
    printf 'it holds %s certificates, not 1 -- every block in a CAfile becomes a trusted root, and only the first is validated here' "${n:-0}"
    return 0
  fi
  subj="$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')"
  issu="$(openssl x509 -in "$f" -noout -issuer  | sed 's/^issuer=//')"
  if [ "$subj" != "$issu" ]; then
    printf 'it is NOT self-issued, so it is a LEAF or an intermediate rather than an anchor:\n  subject: %s\n  issuer:  %s' "$subj" "$issu"
    return 0
  fi
  # READ THE EXTENSION, NEVER THE `-text` DUMP. The first version of this matched `*CA:TRUE*`
  # against the whole dump, which is a substring search over attacker- and operator-controlled
  # string fields. MEASURED: three certs minted with `basicConstraints=critical,CA:FALSE` were
  # ACCEPTED because the literal appeared in `CN = CA:TRUE`, in an `O =`, and in a
  # `subjectAltName URI:https://evil.example/CA:TRUE` -- the SAN vector being the one that matters,
  # since essentially every real certificate has a SAN and it needs no odd DN.
  #
  # `-ext basicConstraints` prints a CLOSED set (critical / CA:TRUE|FALSE / pathlen:N), so it
  # cannot carry an attacker string, and an absent extension prints "No extensions in certificate"
  # which correctly falls to the reject arm. Zero portability delta: this repo already depends on
  # `openssl x509 -noout -ext` at 02-env.sh:444 and 30-vks-login.sh:193, on the same targets.
  bc="$(openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null || true)"
  case "$bc" in
    *CA:TRUE*) : ;;
    *) printf 'its basicConstraints does not say CA:TRUE, so it cannot sign anything (subject: %s)' "$subj"; return 0 ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# ca_status_report lives HERE, beside ca_verifies_endpoint whose return codes it interprets.
# It used to live in the executable 29-ca-status.sh, which 24-lab-preflight.sh SOURCED — so the
# preflight re-ran `set -euo pipefail`, re-sourced os.sh and tls.sh, reassigned SCRIPT_DIR and
# called load_env a SECOND time, after it had already used those values. Same values today, so no
# live bug; but the second load_env snapshots file-derived values as if the operator had set them,
# and any die in that prologue would have killed the preflight with a message naming the CA script.
# Two entry points, one definition, no sourcing of an executable.
# ca_status_report — the whole check, as ONE function, so `make ca-status` and lab-preflight share
# it instead of each carrying a copy. (An inline copy in the preflight was the first draft; two
# copies of one predicate is the shape this repo keeps getting bitten by.)
# Prints to stderr; returns the number of STALE anchors.
ca_status_report() {
  local stale=0 label file host port remedy rc

  # ⚠️ WITHOUT openssl EVERY probe returns 5 and this reports "your CA is not usable" — the WRONG
  # cause, with a remedy that cannot help. MEASURED with PATH stripped. It matters because a bare
  # Photon jump box has no openssl until `make deps` runs, and scenario-2 reaches this step first.
  if ! command -v openssl >/dev/null 2>&1; then
    log_warn "openssl is not installed, so no certificate can be checked. Run: make deps"
    CA_STATUS_CHECKED=0
    return 0
  fi

  # The pairs are DERIVED from the env, not enumerated in a list that rots: each is a *_CA_FILE key
  # and the endpoint key that names what it anchors. Adding a third anchor means adding it here AND
  # to .env.example, which check-env-coverage already enforces.
  #
  # THE LABEL IS A HUMAN NAME, NOT THE VARIABLE NAME. This printed "HARBOR_CA_FILE: verifies ..." in
  # its first version, and scenario-1 mentions HARBOR_CA_FILE exactly ZERO times — so the operator
  # following that runbook would have been shown an internal name they had never met. The file PATH
  # is what they recognise, and the remedy command is what they act on; the variable is our business.
  #
  # NEWLINE-separated + `while read`, not space-separated + `for` — the labels contain spaces, and a
  # `for x in $var` would split them mid-label (and does not word-split at all under zsh).
  # ⚠️ `${HARBOR_URL%%/*}` WAS NOT A HOST PARSER, and two ordinary spellings produced a FALSE SKIP —
  # a live, healthy endpoint reported as "did not answer". MEASURED:
  #     HARBOR_URL=https://harbor.x  -> host became "https:"        -> rc=2, "did not answer"
  #     HARBOR_URL=harbor.x:8443     -> host kept the port, probe 443 -> rc=2, "did not answer"
  # lib/harbor.sh already answers "which host and port is this" (it strips the scheme with a warning,
  # strips a trailing slash, and splits the port). Two implementations of one predicate is exactly the
  # hazard this script's own header claims to avoid — so split it here the same way, in one helper.
  _ca_hostport() {                       # <url> -> "host|port"
    local u="$1" h p
    h="${u#http://}"; h="${h#https://}"  # a scheme is a documented .env mistake, not a crash
    h="${h%%/*}"; h="${h%/}"             # drop any path, then a trailing slash
    case "$h" in
      \[*\]:*) p="${h##*:}"; h="${h%:*}" ;;               # [v6]:port
      \[*\])   p=443 ;;                                    # [v6]
      *:*)     p="${h##*:}"; h="${h%:*}" ;;                # host:port
      *)       p=443 ;;
    esac
    case "$p" in ''|*[!0-9]*) p=443 ;; esac
    printf '%s|%s' "$h" "$p"
  }

  local pairs=""
  [ -n "${HARBOR_CA_FILE:-}" ]   && [ -n "${HARBOR_URL:-}" ]      && pairs="${pairs}Harbor CA|${HARBOR_CA_FILE}|$(_ca_hostport "$HARBOR_URL")|fetch-harbor-ca"$'\n'
  [ -n "${VKS_CA_CERT_FILE:-}" ] && [ -n "${SUPERVISOR_HOST:-}" ] && pairs="${pairs}Supervisor CA|${VKS_CA_CERT_FILE}|$(_ca_hostport "$SUPERVISOR_HOST")|fetch-supervisor-ca"$'\n'

  # THE DENOMINATOR. Set for the caller, because "checked nothing" and "checked three and all were
  # fine" must not print the same sentence. The first version said "all CA certificates match their
  # servers" with NOTHING configured — a green over zero work, which is the one failure this whole
  # script exists to prevent, committed by the script itself.
  CA_STATUS_CHECKED=0; CA_STATUS_MATCHED=0

  if [ -z "$pairs" ]; then
    log_info "no CA certificate is configured, so there is nothing to check."
    log_info "  A CA certificate needs a server to check it against: set HARBOR_CA_FILE + HARBOR_URL,"
    log_info "  or VKS_CA_CERT_FILE + SUPERVISOR_HOST, in ./.env"
    return 0
  fi

  # A herestring, NOT `printf | while` — a pipe makes the loop a subshell and `stale` would be lost,
  # so the report would count correctly and then return 0.
  while IFS='|' read -r label file host port remedy; do
    [ -n "$label" ] || continue

    if [ ! -s "$file" ]; then
      # NOT counted as stale: a missing anchor fails loudly at first use and is a different problem
      # from one that is present and WRONG. Saying so is the point.
      #
      # "run: make fetch-*" would be a CIRCLE on the commonest real-lab shape. MEASURED 2026-08-16
      # on the scenario-2 walk: fetch-harbor-ca refused with "presents ONE certificate that is NOT
      # self-signed ... Its CA is not on the wire" — correct, and unfixable from the tenant's side.
      # So name the command as an ATTEMPT, not as the answer.
      # WARN or PROBLEM depends on WHO IS ASKING, and the difference is not cosmetic.
      #   bare `make lab-preflight` — scenario-1 §7 legitimately runs BEFORE §8 saves the CA, so a
      #     missing file is expected and must not fail. WARN.
      #   `make preflight` (the first prerequisite of install-all) — here a missing CA is fatal and
      #     NOTHING ELSE CATCHES IT: _harbor_serving_code probes with `curl -sk` (skip-verify, so
      #     reachability passes without a CA), _harbor_ca_args returns non-zero when HARBOR_CA_FILE
      #     is unset so harbor_auth_report prints "skipping the auth probe" and returns 0, and
      #     `preflight` runs env-check, NOT env-validate — env-validate being the one gate that does
      #     catch it (measured on the row-5 walk: curl exit 60). So install-all printed a three-line
      #     all-clear and died 8-20 minutes later inside `mirror`. PROBLEM.
      if [ "${CA_STATUS_STRICT:-0}" = 1 ]; then
        log_error "${label} (${file}) is missing or empty — and the install cannot finish without it."
        log_error "  Try  make ${remedy}  — it works only when the issuing CA is sent by the server."
        log_error "  Many servers do not send it, and it will say so: ask for the CA file instead."
        stale=$((stale + 1))
      else
        log_warn "${label} (${file}) is missing or empty."
        log_warn "  Try  make ${remedy}  — it works only when the issuing CA is sent by the server."
        log_warn "  Many servers do not send it, and it will say so: ask for the CA file instead."
      fi
      continue
    fi

    rc=0; ca_verifies_endpoint "$host" "$port" "$file" >/dev/null 2>&1 || rc=$?
    CA_STATUS_CHECKED=$((CA_STATUS_CHECKED + 1))
    # EVERY STRING BELOW IS READ BY AN OPERATOR, so it says "CA certificate" and "matches", not
    # "trust anchor" and "STALE" — neither runbook uses those words, and printing them at someone
    # who has only ever been told to "save Harbor's CA certificate" is our jargon leaking out. The
    # internals may keep calling it an anchor; the output may not.
    # ALL SIX of ca_verifies_endpoint's documented verdicts get an arm. The first version handled
    # 0/1/2/5 and let 3 and 4 fall through to a catch-all that printed "could not check" and exited
    # 0 — and rc=3 (chain fine, NAME wrong) is the MODAL shape here, because scenario-2 tells the
    # tenant to put Harbor's LB *IP* in HARBOR_URL while its certificate usually carries only a DNS
    # name. So the commonest real failure was being reported as "could not check", with a green exit.
    case "$rc" in
      0) log_info "${label} (${file}) matches ${host}"
         CA_STATUS_MATCHED=$((CA_STATUS_MATCHED + 1)) ;;
      1) log_error "${label} (${file}) does NOT match ${host} — this is a leftover certificate."
         log_error "  A rebuilt lab issues a NEW certificate at the SAME address, so the old file"
         log_error "  still looks perfectly valid and is not."
         log_error "  Get it again — this overwrites in place and cannot lose anything:  make ${remedy}"
         stale=$((stale + 1)) ;;
      2) # ABSTAIN. Without this arm, every certificate reads as wrong whenever the lab is powered
         # off, and the first person to see that rightly deletes the check. rc=1 and rc=2 being
         # DISTINCT is what makes this safe to ship; test-ca-staleness-check.sh asserts they differ.
         # It is NOT a pass either — see the ALL-MATCH token below, which this arm cannot reach.
         log_warn "${label}: ${host}:${port} did not answer — skipping. This says nothing about the certificate."
         log_warn "  (the address is printed WITH its port so a skip is diagnosable: a mis-parsed"
         log_warn "   HARBOR_URL used to land here as a false 'did not answer' on a healthy server.)" ;;
      3) log_error "${label} (${file}) issued the certificate at ${host}, but that certificate is"
         log_error "  NOT VALID FOR THIS ADDRESS. Your certificate is fine; the address is wrong."
         log_error "  Use the DNS name the certificate was issued for, not an IP — set it in ./.env."
         stale=$((stale + 1)) ;;
      4) log_error "${label}: ${host} answered, but did not present a certificate at all."
         log_error "  Something other than ${label} is listening there, or it is serving plain HTTP."
         stale=$((stale + 1)) ;;
      5) log_error "${label} (${file}) is not a usable CA certificate — run: make ${remedy}"
         stale=$((stale + 1)) ;;
      *) log_error "${label}: unrecognised result ${rc} checking ${host} — treat as unchecked."
         stale=$((stale + 1)) ;;
    esac
  done <<< "$pairs"
  return "$stale"
}
