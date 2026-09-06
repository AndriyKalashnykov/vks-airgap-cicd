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
check "BLOB_UNKNOWN (the 2026-07-13 shape)" CORRUPT \
  'Error: GET https://harbor/v2/cicd/x/blobs/sha256:abc: BLOB_UNKNOWN: blob unknown to registry'
check "Content-Length mismatch" CORRUPT \
  'Error: Content-Length 100 does not match expected size 200'
# --- ABSENT: the artifact is NOT THERE. Its remedy is "re-push this one image", NEVER "re-carry
# the 12 GB bundle" -- which is what it used to get, because ABSENT had no class and fell to CORRUPT.
# MANIFEST_UNKNOWN LIVES HERE, NOT IN CORRUPT (B703 finding (b)). It is the OCI-STANDARD signature
# for an absent tag -- measured 3/3 on Docker Hub, gcr.io and ghcr.io. This fixture's own label said
# "image deleted from Harbor" while asserting CORRUPT: the test documented an ABSENT scenario and
# pinned the wrong verdict. The 2026-07-13 corruption shape was "153 manifest links, ZERO blobs" --
# manifests PRESENT, blobs gone -- i.e. BLOB_UNKNOWN, which stays CORRUPT above.
check "MANIFEST_UNKNOWN (OCI-standard absent tag)" ABSENT \
  'Error: GET https://harbor/v2/cicd/x/manifests/v1: MANIFEST_UNKNOWN: manifest unknown'
# The strings below are MEASURED against the live Harbor 2026-09-06, committed as fixtures so that a
# Harbor upgrade which reworded them fails HERE rather than in front of an operator.
check "Harbor absent TAG (measured)" ABSENT \
  'Error: GET https://harbor.env1.lab.test/v2/: NOT_FOUND: artifact cicd/tektoncd/pipeline/controller:v1.14.0 not found'
check "Harbor absent REPO (measured)" ABSENT \
  'Error: GET https://harbor.env1.lab.test/v2/: NOT_FOUND: repository library/foo not found'

# --- AUTH: the credential was REJECTED. Nothing is known to be missing or corrupt.
# ORDER IS THE WHOLE POINT HERE. Harbor's absent/invisible-PROJECT error carries BOTH UNAUTHORIZED
# and "not found", so a PROSE match lets ORDER decide the verdict -- and AUTH's remedy ("request a
# fresh credential") vs ABSENT's ("re-mirror this image") is exactly the expensive inversion for the
# RULE ZERO-B tenant who CANNOT self-renew. Matching the CODE TOKEN and ordering AUTH first is what
# makes this deterministic rather than accidental.
check "Harbor absent/invisible PROJECT -- BOTH tokens present, AUTH must win (measured)" AUTH \
  'Error: GET https://harbor.env1.lab.test/v2/: UNAUTHORIZED: project nosuchproject not found: project nosuchproject not found'
check "Docker Hub unauthenticated" AUTH \
  'Error: GET https://index.docker.io/v2/library/x/manifests/v1: UNAUTHORIZED: authentication required'
check "quay.io unauthorized" AUTH \
  'Error: GET https://quay.io/v2/x/manifests/v1: UNAUTHORIZED: access to the requested resource is not authorized'
check "gcr.io denied" AUTH \
  'Error: GET https://gcr.io/v2/x/manifests/v1: DENIED: Unauthenticated request'
# SYNTHETIC, and labelled so nobody mistakes it for a measured string. No registry has been
# observed emitting BOTH code tokens, but if one ever does, the AUTH-before-ABSENT ordering is
# what decides it -- and an ordering that no fixture can RED-prove is decoration. Swapping the
# two arms in _verify_class must turn THIS case red.
check "SYNTHETIC: both code tokens present -- AUTH must win over ABSENT" AUTH \
  'Error: GET https://reg/v2/: UNAUTHORIZED: denied; NOT_FOUND: also absent'

# ── UNCLASSIFIED is FAIL-SAFE, and that is a decision, not an oversight ──────────────────────────
# `unexpected EOF` is BOTH the network-cut signature AND the 2026-07-13 corruption signature. A
# classifier that guessed TRANSPORT there would silently downgrade a real corruption to "try
# again", which is the one failure this gate exists to prevent. It must land on the corrupt side.
check "ambiguous unexpected-EOF stays UNCLASSIFIED" UNCLASSIFIED \
  'Error: failed to read image harbor/cicd/x:v1: unexpected EOF'
check "an error nobody has seen before stays UNCLASSIFIED" UNCLASSIFIED \
  'Error: something entirely new that no pattern here anticipates'

# AND THE FAIL-SAFE IS ASSERTED, NOT ASSUMED. The classifier returning UNCLASSIFIED is only safe
# if the CALLER counts it as corrupt.
#
# THIS GUARD WAS REWRITTEN WHEN ABSENT/AUTH WERE ADDED (B703), AND THE REWRITE IS THE POINT.
# It used to grep for: if [ "$cls" = TRANSPORT ]; then
# B703 predicted the exact failure mode of extending that shape -- adding an `elif` for a new class
# makes the guard's COMMENT false while its GREP still MATCHES, so the one check protecting the
# fail-safe goes on passing while no longer describing the code. The caller is therefore a `case`
# whose LAST arm is the catch-all, and this guard asserts that SHAPE: any class without an explicit
# arm falls to `fails`. A `case` cannot be extended in a way that silently bypasses the tally.
# ⚠️ THERE IS MORE THAN ONE `case "$cls" in` IN THAT FILE. The probe guard added for the
# CORRUPT-is-definitive fix is also one, and it deliberately has a `*)` arm that does NOT touch the
# tally — so an extractor that grabs the FIRST block measures the wrong thing and this guard went
# RED on a correct change. (It failing was the guard working; a guard that had silently passed would
# have been the defect.) Select the block by its CONTENT — the one that tallies — not by position,
# so neither adding another `case` nor reordering them can point this at the wrong one.
_case_block="$(awk '
  /case "\$cls" in/ { inblk=1; buf=""; }
  inblk               { buf = buf $0 "\n" }
  inblk && /^    esac/ { if (buf ~ /INTEGRITY FAIL/) { printf "%s", buf; exit } inblk=0 }
' scripts/23-mirror-verify.sh)"
_last_arm="$(printf '%s\n' "$_case_block" | grep -E '^[[:space:]]+[A-Za-z*]+\)' | tail -1 || true)"
if printf '%s' "$_last_arm" | grep -qE '^[[:space:]]+\*\)'; then
  ok "the caller's case on \$cls ends with the catch-all arm"
else
  bad "23-mirror-verify.sh's case on \$cls must END with the '*)' catch-all so an unhandled class
        reaches the fails tally" "last arm seen: '${_last_arm}'"
fi
if printf '%s\n' "$_case_block" | awk '/^[[:space:]]+\*\)/{f=1} f && /fails=\$\(\(fails\+1\)\)/{found=1} END{exit !found}'; then
  ok "the catch-all arm increments the corrupt tally (UNCLASSIFIED is treated as CORRUPT)"
else
  bad "the '*)' arm of 23-mirror-verify.sh's case must increment 'fails'" \
      "without it UNCLASSIFIED -- which includes 'unexpected EOF', a REAL corruption signature --
        becomes silently non-fatal"
fi
# And the success line must be UNREACHABLE when any tally is non-zero. B703's REFUTED design gave a
# new class a non-fatal branch, so with fails=0 NO die fired and the gate printed "N images intact"
# while exiting 0 -- a false green on the gate that stands before an air-gap install.
if grep -q 'refusing to report the mirror intact' scripts/23-mirror-verify.sh; then
  ok "a total-tally guard stands between the verdicts and the success line"
else
  bad "23-mirror-verify.sh must refuse the success line when any failure tally is non-zero" \
      "otherwise a future class added without its own die passes silently"
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
