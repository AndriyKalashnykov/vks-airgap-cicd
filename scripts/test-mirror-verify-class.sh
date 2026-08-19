#!/usr/bin/env bash
# ci-tier: fast — pure string classification, no network, no registry, no crane.
#
# test-mirror-verify-class.sh — `crane validate --remote` fails for TWO reasons with OPPOSITE
# remedies, and 23-mirror-verify.sh used to report both as "Harbor's copy is corrupt/incomplete
# (re-mirror)". On the air-gap box "re-mirror" means RE-CARRYING A 12 GB BUNDLE ACROSS THE GAP.
#
# The old line also did `cut -c1-200`, and the real message is 339 bytes, so the operator saw:
#     … dial tcp: lookup harbor.env1.lab.test on 12
# with `no such host` — the words that REFUTE the corruption verdict — removed entirely.
#
# The fixtures below are REAL crane stderr (captured against a Harbor-shaped ref) and crane's own
# corruption message templates, not invented strings. A classifier tested only on strings its
# author wrote is testing the author's imagination.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# Pull the classifier out of the script WITHOUT running the script (it needs a registry).
# ⚠️ Extracting by line range would rot on the first edit above it; extract by the function's own
# name and its closing brace at column 0, then assert the extraction actually produced a function.
_fn="$(awk '/^_verify_class\(\) \{/,/^\}/' scripts/23-mirror-verify.sh)"
case "$_fn" in
  *"_verify_class()"*"CORRUPT"*) : ;;
  *) printf 'FAIL  could not extract _verify_class from 23-mirror-verify.sh — the harness is broken, not the product\n' >&2
     exit 1 ;;
esac
eval "$_fn"

check() {  # <label> <expected> <stderr-fixture>
  got="$(_verify_class "$3")"
  if [ "$got" = "$2" ]; then ok "$1 -> $2"
  else bad "$1 -> got '${got}', want '${2}'. Fixture: $(printf '%s' "$3" | cut -c1-90)"; fi
}

# ── TRANSPORT: real captured stderr, and the trust failures that look nothing like corruption ────
check "DNS no-such-host (the 339-byte real one)" TRANSPORT \
  'Error: failed to read image harbor.env1.lab.test:443/cicd/gcr.io_tekton-releases_pipeline_cmd_controller:v1.4.2: Get "https://harbor.env1.lab.test:443/v2/": dial tcp: lookup harbor.env1.lab.test on 127.0.0.53:53: no such host'
check "connection refused (Harbor down)" TRANSPORT \
  'Error: failed to read image 127.0.0.1:1/cicd/x:v1: Get "https://127.0.0.1:1/v2/": dial tcp 127.0.0.1:1: connect: connection refused'
check "untrusted CA (the air-gap trust failure)" TRANSPORT \
  'Error: GET https://harbor.vks.local/v2/: x509: certificate signed by unknown authority'
check "plain-HTTP registry behind an https:// ref" TRANSPORT \
  'Error: Get "https://harbor:5000/v2/": http: server gave HTTP response to HTTPS client'
check "i/o timeout" TRANSPORT \
  'Error: Get "https://harbor.vks.local/v2/": dial tcp 10.0.0.5:443: i/o timeout'

# ── CORRUPT: crane's own templates + the registry codes the 2026-07-13 incident produced ─────────
check "mismatched digest (the integrity verdict)" CORRUPT \
  'Error: validating layer sha256:abc: mismatched digest: got sha256:def, want sha256:abc'
check "undersized layer" CORRUPT \
  'Error: undersized layer: wanted 12345 bytes, got 999'
check "MANIFEST_UNKNOWN (image deleted from Harbor)" CORRUPT \
  'Error: GET https://harbor/v2/cicd/x/manifests/v1: MANIFEST_UNKNOWN: manifest unknown'
check "BLOB_UNKNOWN (the 2026-07-13 shape)" CORRUPT \
  'Error: GET https://harbor/v2/cicd/x/blobs/sha256:abc: BLOB_UNKNOWN: blob unknown to registry'
check "Content-Length mismatch" CORRUPT \
  'Error: Content-Length 100 does not match expected size 200'

# ── UNCLASSIFIED is FAIL-SAFE, and that is a decision, not an oversight ──────────────────────────
# `unexpected EOF` is BOTH the network-cut signature AND the 2026-07-13 corruption signature. A
# classifier that guessed TRANSPORT there would silently downgrade a real corruption to "try
# again", which is the one failure this gate exists to prevent. It must land on the corrupt side.
check "ambiguous unexpected-EOF stays UNCLASSIFIED" UNCLASSIFIED \
  'Error: failed to read image harbor/cicd/x:v1: unexpected EOF'
check "an error nobody has seen before stays UNCLASSIFIED" UNCLASSIFIED \
  'Error: something entirely new that no pattern here anticipates'

# ⚠️ AND THE FAIL-SAFE IS ASSERTED, NOT ASSUMED. The classifier returning UNCLASSIFIED is only
# safe if the CALLER counts it as corrupt. Read that from the script rather than trusting it: the
# transport branch must test for TRANSPORT explicitly, so everything else falls to the fails
# tally. If someone later flips this to `[ "$cls" != CORRUPT ]`, UNCLASSIFIED silently becomes a
# warning and this file must go red.
if grep -q 'if \[ "\$cls" = TRANSPORT \]; then' scripts/23-mirror-verify.sh; then
  ok "the caller branches on = TRANSPORT, so UNCLASSIFIED falls through to the corrupt tally"
else
  bad "23-mirror-verify.sh must branch on '\$cls = TRANSPORT'. Any other shape risks routing
        UNCLASSIFIED (which includes 'unexpected EOF', a REAL corruption signature) to the
        non-fatal path — silently downgrading the failure this gate exists to catch."
fi

# The truncation width: the real message is 339 bytes, so anything at or below it removes the
# discriminating words. Assert the number moved off 200 and is generous.
# ⚠️ STRIP COMMENTS FIRST. The first version of this check read `200` out of the script's own
# comment — the one explaining that the OLD width was 200 — and failed a correct fix. That is the
# documented "a structural test that greps a symbol also matches the docstring" trap, committed
# here by a test written to prevent a different one. The comment is prose ABOUT the value; only
# the code carries the value, and this is a must-EXIST check on code, so dropping comments is the
# right polarity (a must-NOT-exist check would need the opposite).
_w="$(sed 's/#.*//' scripts/23-mirror-verify.sh | grep -oE 'cut -c1-[0-9]+' | grep -oE '[0-9]+$' | head -1)"
if [ -n "$_w" ] && [ "$_w" -ge 400 ]; then
  ok "crane stderr is truncated at ${_w} chars (the real message is 339 — 200 cut the evidence off)"
else
  bad "the stderr truncation is '${_w:-<none>}'; it must exceed the 339-byte real message, or the
        words that refute a corruption verdict are removed while the verdict is printed in full."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — a transport failure is no longer reported as corruption, and the ambiguous case\n'
printf '          still fails toward corrupt.\n'
