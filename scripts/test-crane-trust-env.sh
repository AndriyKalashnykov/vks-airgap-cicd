#!/usr/bin/env bash
# test-crane-trust-env.sh — B735: crane_trust_env (lib/tls.sh) must make crane trust Harbor's CA on
# BOTH OSes, and on macOS refuse a crane that cannot.
#
# Offline: stub `uname`, `go`, `crane` (and no `mise`) on a private PATH. What each case pins:
#   linux  -> SSL_CERT_FILE only; GODEBUG untouched (the release crane already honours the file)
#   darwin -> GODEBUG gains x509sslcertoverrideplatform=1 exactly ONCE, keeping any existing value
#   darwin + a go1.26 crane -> REFUSED (it would fail later with an x509 error blaming the lab)
#   darwin + an unreadable Go version -> REFUSED (fail closed)
#   a missing/empty bundle or a wrong arity -> rc 2
# The real TLS behaviour (Apple's verifier vs Go's) cannot be stubbed; it was measured on the Mac.
# shellcheck disable=SC2016  # single quotes are the point: bash -c bodies and stub scripts
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
fail=0; n=0
ok()  { n=$((n + 1)); printf '  ok    %s\n' "$1"; }
bad() { n=$((n + 1)); fail=1; printf '  FAIL  %s\n' "$1"; }

mkdir -p "$T/bin"
printf 'bundle\n' > "$T/bundle.crt"
: > "$T/empty.crt"
printf '#!/bin/sh\necho "$STUB_OS"\n' > "$T/bin/uname"
printf '#!/bin/sh\n[ "$STUB_GO" = none ] && exit 1\necho "$2: go$STUB_GO"\n' > "$T/bin/go"
printf '#!/bin/sh\necho v0.21.9\n' > "$T/bin/crane"
chmod +x "$T/bin/uname" "$T/bin/go" "$T/bin/crane"

# probe <os> <go-version|none> <GODEBUG-before> <bundle> -> prints "rc=<n> ssl=<v> godebug=<v>"
probe() {
  # A PATH of ONLY the stubs plus the dirs the stubs need: a real `mise` on the box must not answer.
  PATH="$T/bin:/usr/bin:/bin" STUB_OS="$1" STUB_GO="$2" GODEBUG="$3" SSL_CERT_FILE="" \
    bash -c '. "$1/scripts/lib/tls.sh"; crane_trust_env "$2" 2>/dev/null; rc=$?
             printf "rc=%s ssl=%s godebug=%s\n" "$rc" "${SSL_CERT_FILE:-}" "${GODEBUG:-}"' _ "$REPO_ROOT" "$4"
}
# expect <label> <want-substring> <got>
expect() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — want '$2' in: $3" ;; esac; }

out="$(probe Linux 1.26.5 "" "$T/bundle.crt")"
expect "linux: rc 0"                        "rc=0 "                              "$out"
expect "linux: SSL_CERT_FILE exported"      "ssl=$T/bundle.crt "                 "$out"
expect "linux: GODEBUG untouched"           "godebug="$'\n'                      "$out"$'\n'

out="$(probe Darwin 1.27.1 "" "$T/bundle.crt")"
expect "darwin go1.27: rc 0"                "rc=0 "                              "$out"
expect "darwin go1.27: GODEBUG set"         "godebug=x509sslcertoverrideplatform=1" "$out"

out="$(probe Darwin 1.27.1 "http2client=0" "$T/bundle.crt")"
expect "darwin: existing GODEBUG kept"      "godebug=http2client=0,x509sslcertoverrideplatform=1" "$out"

out="$(probe Darwin 1.27.1 "x509sslcertoverrideplatform=1" "$T/bundle.crt")"
case "$out" in *x509sslcertoverrideplatform=1,x509*) bad "darwin: GODEBUG appended twice: $out" ;;
               *) ok "darwin: GODEBUG not duplicated" ;; esac

out="$(probe Darwin 1.26.5 "" "$T/bundle.crt")"
expect "darwin go1.26 crane: REFUSED"       "rc=1 "                              "$out"

out="$(probe Darwin none "" "$T/bundle.crt")"
expect "darwin unreadable Go version: REFUSED" "rc=1 "                           "$out"

out="$(probe Linux 1.27.1 "" "$T/empty.crt")"
expect "empty bundle: rc 2"                 "rc=2 "                              "$out"
out="$(probe Linux 1.27.1 "" "$T/missing.crt")"
expect "missing bundle: rc 2"               "rc=2 "                              "$out"

echo "== darwin: a mise SHIM on PATH is resolved through 'mise which' (go version cannot read a shim)"
mkdir -p "$T/shim/bin" "$T/shim/real"
printf '#!/bin/sh\nexit 0\n' > "$T/shim/real/mise"; chmod +x "$T/shim/real/mise"
ln -s "$T/shim/real/mise" "$T/shim/bin/crane"            # what a mise shim is: a link to mise
printf '#!/bin/sh\necho v0.21.9\n' > "$T/shim/real/crane-built"; chmod +x "$T/shim/real/crane-built"
# `mise which crane` -> the real build; the go stub answers per binary path
printf '#!/bin/sh\n[ "$1" = which ] && echo %s\n' "$T/shim/real/crane-built" > "$T/shim/bin/mise"; chmod +x "$T/shim/bin/mise"
printf '#!/bin/sh\ncase "$2" in *crane-built) echo "$2: go1.27.1" ;; *) exit 1 ;; esac\n' > "$T/shim/bin/go"; chmod +x "$T/shim/bin/go"
cp "$T/bin/uname" "$T/shim/bin/uname"
out="$(PATH="$T/shim/bin:/usr/bin:/bin" STUB_OS=Darwin GODEBUG="" bash -c \
  '. "$1/scripts/lib/tls.sh"; crane_trust_env "$2" 2>/dev/null; echo "rc=$? "' _ "$REPO_ROOT" "$T/bundle.crt")"
expect "darwin shim: resolved via mise which, go1.27 build accepted" "rc=0 " "$out"

rc=0; PATH="$T/bin:/usr/bin:/bin" bash -c '. "$1/scripts/lib/tls.sh"; crane_trust_env' _ "$REPO_ROOT" 2>/dev/null || rc=$?
if [ "$rc" -eq 2 ]; then ok "no argument: rc 2"; else bad "no argument: want rc 2, got $rc"; fi

echo "== call sites go through crane_trust_env"
if grep -q 'crane_trust_env "\$bundle"' "$REPO_ROOT/scripts/lib/harbor.sh"; then ok "lib/harbor.sh"
else bad "lib/harbor.sh does not call crane_trust_env"; fi
# [u] keeps check-lib-sourcing from reading this PATTERN as a call to the run() helper
if grep -q 'crane_trust_env "\${CRANE_TMP}/ca-bundle.crt" && r[u]n crane validate' "$REPO_ROOT/scripts/16-engine-trust-check.sh"; then
  ok "16-engine-trust-check.sh"
else bad "16-engine-trust-check.sh does not call crane_trust_env"; fi
# A crane call site that sets SSL_CERT_FILE by hand would bypass the macOS GODEBUG.
if grep -rnE 'SSL_CERT_FILE=[^ ]+ +(r[u]n +)?crane' "$REPO_ROOT/scripts" --include='*.sh' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep . >/dev/null; then
  bad "a crane call sets SSL_CERT_FILE inline (bypasses crane_trust_env): $(grep -rnE 'SSL_CERT_FILE=[^ ]+ +(r[u]n +)?crane' "$REPO_ROOT/scripts" --include='*.sh' | head -1)"
else ok "no crane call sets SSL_CERT_FILE inline"; fi

echo "test-crane-trust-env: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-crane-trust-env: OK"; exit 0; }
echo "test-crane-trust-env: FAILED"; exit 1
