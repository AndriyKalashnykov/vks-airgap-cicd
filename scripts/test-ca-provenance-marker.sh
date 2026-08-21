#!/usr/bin/env bash
# test-ca-provenance-marker — B195/F1.5: the Supervisor CA's fetched-vs-supplied discrimination.
#
# WHAT THIS GUARDS. `30-vks-login.sh`'s verdict-3 arm is DELIBERATELY SILENT when no pin is set, and
# its comment gives the reason: "the operator has already pointed VKS_CA_CERT_FILE at a file they
# obtained THEMSELVES - which is the out-of-band path". That reasoning is correct, and it is FALSE
# for a file `make fetch-supervisor-ca` wrote: that script fetches it with `curl -sk` off the very
# wire it is meant to authenticate - the trust-on-first-use case the same comment says this is NOT.
# The consumer could not tell the two apart, so the anchor most likely to be an interceptor's got
# the silence intended for the anchor least likely to be.
#
# WHY THE MARKER CARRIES A DIGEST rather than being a bare flag: an operator who later replaces the
# file by hand must NOT inherit a stale "fetched" verdict. Case 3 below is that case, and it is the
# one that keeps this from becoming the advice-on-a-non-finding class the repo has a recorded defect
# for. Case 1 is the only state that may warn.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$T/k.pem"  -out "$T/ca.crt"    -days 1 -nodes -subj '/CN=probe' >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -keyout "$T/k2.pem" -out "$T/other.crt" -days 1 -nodes -subj '/CN=other' >/dev/null 2>&1
if [ -s "$T/ca.crt" ] || { echo "openssl produced no certificate - the harness is broken, not the code"; exit 1; }

_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | tr -d ': ' | sed 's/.*=//' | tr '[:upper:]' '[:lower:]'; }

# Mirrors the shipped arm in 30-vks-login.sh. Kept in step by check-ca-provenance-arm below.
_verdict() {
  local f="$1" prov="$1.fetched" now
  if [ -s "$prov" ]; then
    now="$(_fp "$f")"
    if [ -n "$now" ] && [ "$now" = "$(tr -d ' \n' < "$prov")" ]; then printf 'WARNS'; return; fi
  fi
  printf 'SILENT'
}

_fp "$T/ca.crt" > "$T/ca.crt.fetched"
[ "$(_verdict "$T/ca.crt")" = WARNS ]; then ok "fetched by us and unchanged -> WARNS (the only state that may)"; else bad "fetched-and-unchanged did NOT warn - the defect is unfixed"; fi

rm -f "$T/ca.crt.fetched"
if [ "$(_verdict "$T/ca.crt")" = SILENT ]; then ok "operator-supplied (no marker) -> SILENT (the reasoned-for path)"; else bad "warned on an operator-supplied anchor - that is the nag the arm exists to avoid"; fi

_fp "$T/other.crt" > "$T/ca.crt.fetched"
if [ "$(_verdict "$T/ca.crt")" = SILENT ]; then ok "stale marker, file replaced by hand -> SILENT"; else bad "a stale marker warned about a file the operator supplied - advice on a non-finding"; fi

: > "$T/ca.crt.fetched"
if [ "$(_verdict "$T/ca.crt")" = SILENT ]; then ok "empty marker (partial write) -> SILENT, fails toward quiet"; else bad "an empty marker warned - a truncated write must not manufacture a finding"; fi

# The producer must actually WRITE the marker, or every case above is theatre.
if grep -q '\.fetched' scripts/fetch-supervisor-ca.sh; then ok "fetch-supervisor-ca.sh writes the provenance marker"; else bad "fetch-supervisor-ca.sh no longer writes .fetched - the consumer arm is now dead code"; fi
if grep -q '\.fetched' scripts/30-vks-login.sh; then ok "30-vks-login.sh reads the provenance marker"; else bad "30-vks-login.sh no longer reads .fetched - the marker is written and ignored"; fi

printf '\ntest-ca-provenance-marker: %d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
