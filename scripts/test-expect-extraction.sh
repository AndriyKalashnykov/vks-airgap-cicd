#!/usr/bin/env bash
# test-expect-extraction.sh — the ASYMMETRY between the two Expect readers is DELIBERATE. Pin it.
#
# WHY THIS EXISTS
# ---------------
# `**Expect:**` claims are read by TWO things, and B205's idea round established that they MUST NOT
# read the same unit:
#
#   scripts/walk-doc.sh          RUNTIME, head-only. Decides EXPECT MET/UNMET on a live lab.
#   scripts/check-expect-literals.sh  OFFLINE, head + continuation lines. Decides a gate on a laptop.
#
# WIDENING THE RUNTIME PARSER IS CERTIFICATION-BLOCKING, and it was designed and then REFUTED:
# docs/scenario-2.md's discovery block flips from _tot=0 (not checkable) to _tot=3, with literals that
# CANNOT appear on the `else` branch EVERY scenario-2 matrix row takes -> EXPECT UNMET -> exit 1,
# roughly 25 minutes into a live lab. docs/scenario-2.md carries a dated comment saying those literals
# are DELIBERATELY on continuation lines, naming the PR that got it wrong once and predicting that
# exact failure. The design decision lives in the DOCUMENT, not the script -- which is why a
# script-side review misses it, and why it needs a test rather than a comment.
#
# An offline MISSING costs a red gate on a laptop. A runtime UNMET costs a certification row.
#
# This test fails in BOTH directions: if someone widens the runtime parser, and if someone narrows
# the offline gate back.
# shellcheck disable=SC2016
# ^ FILE-LEVEL, and justified rather than blunt: this file's ENTIRE SUBJECT is markdown code spans,
# so every backtick in it is a LITERAL being matched, never a command substitution. A per-line
# disable would need repeating at ~8 sites and would still be the same claim eight times. If you add
# code here that genuinely wants expansion, note it at that line — the blanket applies to the
# backtick-literal grammar, not to sloppiness.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }

echo "== test-expect-extraction =="

# ── 1. THE RUNTIME PARSER MUST STAY HEAD-ONLY ───────────────────────────────────────────────────
# Keyed on the CAPTURE line itself, not on prose about it: a comment mentioning `startswith` would
# satisfy a looser grep and this assertion would pass over a widened parser.
# ⚠️ ANCHORED AT BOTH ENDS ($ included), and that is load-bearing. The first version anchored only
# the PREFIX, so a widening that APPENDS to the line (`...append(line.rstrip()); _cont = True`) still
# matched and the assertion passed over the exact change it exists to forbid. MEASURED: rc=0 on the
# mutated parser. A gate that cannot fire is worse than none, so pin the WHOLE capture statement.
if grep -qE "^[[:space:]]*elif line\.startswith\('\*\*Expect'\) and out: out\[-1\]\[\"e\"\]\.append\(line\.rstrip\(\)\)[[:space:]]*$" scripts/walk-doc.sh; then
  ok "runtime parser (walk-doc.sh) still captures the HEAD LINE ONLY"
else
  bad "the runtime Expect capture changed shape" \
      "if it was WIDENED to continuation lines this is CERTIFICATION-BLOCKING -- read the comment at the top of this file and docs/scenario-2.md before proceeding"
fi

# ── 2. THE OFFLINE GATE MUST READ CONTINUATIONS ─────────────────────────────────────────────────
_heads_only() { grep -hE '^[[:space:]]*\*\*Expect' "$@" 2>/dev/null | grep -oE '`[^`]+`' | wc -l; }
_widened()    { awk '/^[[:space:]]*\*\*Expect/ { print; inx=1; next }
                     inx && (/^[[:space:]]*$/ || /^[[:space:]]*```/) { inx=0 }
                     inx { print }' "$@" 2>/dev/null | grep -oE '`[^`]+`' | wc -l; }
_docs=(docs/scenario-1.md docs/scenario-2.md)
_h="$(_heads_only "${_docs[@]}")"; _w="$(_widened "${_docs[@]}")"
if [ "$_w" -gt "$_h" ]; then
  ok "offline extraction reads continuations (${_h} head-only -> ${_w} widened)"
else
  bad "the offline extraction no longer reads continuation lines (${_h} vs ${_w})" \
      "B205 widened it deliberately; narrowing it re-hides every literal on a wrapped claim"
fi

# ── 3. THE GATE ITSELF MUST USE THE WIDENED FORM ────────────────────────────────────────────────
# Assertion 2 proves the TECHNIQUE works; this proves the SHIPPED gate uses it. Without this, someone
# could revert check-expect-literals.sh and assertion 2 would still pass on its own local awk.
if grep -q 'inx && (/\^\[\[:space:\]\]\*\$/ || /\^\[\[:space:\]\]\*```/)' scripts/check-expect-literals.sh \
   || grep -qF 'inx { print }' scripts/check-expect-literals.sh; then
  ok "check-expect-literals.sh ships the continuation-reading extraction"
else
  bad "check-expect-literals.sh no longer ships the widened extraction" \
      "the technique passing in this file proves nothing if the GATE reverted to head-only"
fi

# ── 4. A PLANTED CONTINUATION LITERAL MUST BE EXTRACTED ─────────────────────────────────────────
# The end-to-end direction: not a count, an actual literal on line 2 of a claim.
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
printf '**Expect:** a head claim with no literal here\nand a continuation carrying `planted-continuation-literal` in it.\n\n' > "$_t/d.md"
if _widened "$_t/d.md" | grep -q '^2$' || _widened "$_t/d.md" | grep -qE '^[1-9]'; then
  if awk '/^[[:space:]]*\*\*Expect/ { print; inx=1; next }
          inx && (/^[[:space:]]*$/ || /^[[:space:]]*```/) { inx=0 }
          inx { print }' "$_t/d.md" | grep -q 'planted-continuation-literal'; then
    ok "a literal on a CONTINUATION line is extracted end-to-end"
  else
    bad "a planted continuation literal was NOT extracted" "the terminator rule dropped it"
  fi
else
  bad "the widened extractor returned nothing for the planted fixture" "check the terminator rule"
fi

# ── 5. THE TERMINATOR MUST STOP AT A BLANK LINE ─────────────────────────────────────────────────
# Over-attaching is the mirror defect: it drags unrelated prose literals into the contract and
# manufactures FALSE MISSING.
printf '**Expect:** head\ncontinuation with `attached-literal`\n\nunrelated prose with `must-not-attach` in it\n' > "$_t/e.md"
_out="$(awk '/^[[:space:]]*\*\*Expect/ { print; inx=1; next }
             inx && (/^[[:space:]]*$/ || /^[[:space:]]*```/) { inx=0 }
             inx { print }' "$_t/e.md")"
if printf '%s' "$_out" | grep -q 'attached-literal' && ! printf '%s' "$_out" | grep -q 'must-not-attach'; then
  ok "the terminator stops at a blank line (no over-attach into unrelated prose)"
else
  bad "the terminator does not stop at a blank line" \
      "over-attaching drags unrelated literals into the checked contract and manufactures FALSE MISSING"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
