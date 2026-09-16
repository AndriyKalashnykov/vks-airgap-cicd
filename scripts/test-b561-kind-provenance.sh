#!/usr/bin/env bash
# test-b561-kind-provenance.sh — B561: fetch-ca.sh must warn when the endpoint/CA-file it was handed
# (as make ARGV from $(HARBOR_URL)/$(HARBOR_CA_FILE)) came from a KinD overlay, and must NOT persist a
# KinD CA to .env. This pins the PROVENANCE PRINTER (the part that runs before the pin check). The
# printer's decision drives the two flags (_from_kind_overlay / _overlay_ambiguous) that select the
# 3-way success remedy, so the warn-text assertions here transitively cover the flag-setting; the
# success-remedy branch itself needs a live/pinned TLS endpoint and is exercised by the KinD e2e.
#
# RED-proven the fix catches a regression: label-scoped key match (not every key) + the stamped-vs-
# legacy split are what these cases exercise; reverting either reddens A/B or the FP case.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FCA="${SCRIPT_DIR}/fetch-ca.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck() { if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
       else f=$((f+1)); printf '  FAIL  %s (got=[%s] want=[%s])\n' "$1" "$2" "$3"; fi; }

# Run fetch-ca.sh in a scratch REPO_ROOT with the planted overlay; it prints provenance BEFORE the
# openssl connect (which then fails against 127.0.0.1:443 — irrelevant, we grep the warn). Classify
# the output: STAMPED (definite KinD), LEGACY (hedged .env.kind), or SILENT.
verdict() { # <scratch-dir>
  local out
  out="$( cd "$1" && REPO_ROOT="$1" bash "$FCA" 127.0.0.1 /kind/ca.crt harbor 2>&1 )"
  if   grep -qF 'KinD-stamped overlay'  <<<"$out"; then printf 'STAMPED'
  elif grep -qF 'legacy .env.kind overlay' <<<"$out"; then printf 'LEGACY'
  else printf 'SILENT'; fi
}
mk() { rm -rf "${T:?}/$1"; mkdir -p "${T:?}/$1"; printf '%s' "$2" > "${T:?}/$1/$3"; }

# A: a KinD-STAMPED .env.state whose HARBOR_URL/HARBOR_CA_FILE match -> definite KinD assertion.
mk A "$(printf 'VKS_STATE_KIND=1\nHARBOR_URL=127.0.0.1\nHARBOR_CA_FILE=/kind/ca.crt\n')" .env.state
ck "stamped .env.state (VKS_STATE_KIND=1) -> definite KinD warning" "$(verdict "$T/A")" "STAMPED"

# B: legacy .env.kind (KinD-NAMED, may hold real-lab state) -> HEDGED, never asserts KinD.
mk B "$(printf 'HARBOR_URL=127.0.0.1\n')" .env.kind
ck "legacy .env.kind -> hedged 'verify' warning (not an assertion)" "$(verdict "$T/B")" "LEGACY"

# C: no overlay -> silent.
rm -rf "$T/C"; mkdir -p "$T/C"
ck "no overlay -> silent" "$(verdict "$T/C")" "SILENT"

# D: an UNSTAMPED (real-lab) .env.state -> silent (not KinD).
mk D "$(printf 'VKS_STATE_KIND=0\nHARBOR_URL=127.0.0.1\nHARBOR_CA_FILE=/lab/ca.crt\n')" .env.state
ck "unstamped real-lab .env.state -> silent" "$(verdict "$T/D")" "SILENT"

# E (the secret-echo / coincidental-match guard): a NON-endpoint key whose value equals the endpoint
# must NOT match — the printer scopes to the label's endpoint/CA keys, so it never echoes a secret.
mk E "$(printf 'VKS_STATE_KIND=1\nGITEA_ADMIN_PASSWORD=127.0.0.1\n')" .env.state
ck "stamped sink, non-endpoint key == endpoint -> silent (no secret echo, no misattribution)" "$(verdict "$T/E")" "SILENT"

printf '\n  %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
