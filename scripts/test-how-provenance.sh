#!/usr/bin/env bash
# test-how-provenance.sh — the RED-proof for check-how-provenance, committed so it cannot expire.
#
# WHY THIS FILE EXISTS: the gate it guards was rewritten because the old one fired on **0 of 21**
# vendor-CLI lines — it had never once looked at the class it was built for. A rewrite that big is
# exactly where a hand-run "I checked it once" proof rots, so every probe the implementation round
# specified is pinned here.
#
# ⚠️ EVERY POSITIVE CONTROL BELOW WAS OBSERVED FAILING AGAINST AN EARLIER DRAFT. They are not
# decoration:
#   A   the ORIGINAL incident (a fabricated `vcf … --export-file`) — the reason the gate exists
#   B   the same command one line lower, under a header. The OLD gate scored this rc=0: the hole.
#   F3  the same command under a GRADED header. The FIRST DRAFT of the rewrite scored it rc=0 —
#       grade inheritance LAUNDERED it, re-admitting the very shape the gate was built for.
#   F6  a fabrication whose line happens to mention `kubectl` in a trailing parenthetical. Matching
#       the RAW line instead of the payload's first token let that launder it.
#   F7  a FLAGLESS fabrication.
# and every NEGATIVE control is a false-RED that would get this gate loosened or deleted:
#   F4  `(Lab-verified)` — the repo's STRONGEST grade. An earlier draft REJECTED it while ACCEPTING
#       `(inferred)`, the weakest: a perfectly inverted incentive.
#   F5  `make -C dir target` — an earlier draft reported *names 'make -', which is NOT a target*.
#   512 a vendor command cited INSIDE BACKTICKS in a sentence. Demanding a per-line grade there
#       produced "`vcf context create …` (inferred), the" — which reads as if the word "the" is
#       inferred. That is a citation, not an instruction; backticked spans are stripped.
# ⚠️ A DIRECTIVE LINE TAKES ONLY THE DIRECTIVE. Trailing prose on the same line is parsed as a
# further directive key, so writing the reason after the disable= produced SC1072/SC1073 parse
# errors and REPLACED one lint finding with two. The reason goes on its own comment lines, below.
# ⚠️ AND THE FIRST WORDING OF THIS VERY NOTE TRIPPED GITLEAKS. Quoting the broken directive inline
# gave the line a <WORD> colon <high-entropy-token> shape, which generic-api-key flagged (entropy
# 3.81) — a comment ABOUT a lint directive, read as a credential. Same class as this repo's
# recorded PWD-colon and harborAdminPassword-colon false positives: prose that happens to look
# like an assignment. Reworded rather than allowlisted, because widening a secrets allowlist to
# admit prose is how a secrets gate stops catching secrets.
# shellcheck disable=SC2016
# EVERY probe string below is a LITERAL FIXTURE. `$C`, `$K`, `$X`
# must reach the gate unexpanded: the gate's job is to judge the TEXT of an acquisition command,
# and a shell-expanded `$C` would change the very thing under test. An implementation round
# adjudicated the same directive on a sibling test and cleared it -- `set -u` also makes the
# naive "fix" LOUD rather than silent, since double-quoting an undefined var aborts the run.
# File-level rather than 10 line-level directives, because the reason is identical at every site.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"
cp -r "$REPO/scripts/lib" "$T/scripts/"
cp "$REPO/scripts/check-how-provenance.sh" "$T/scripts/"
cp "$REPO/Makefile" "$T/"

# _probe <want:FAIL|pass> <name> <lines appended to a COPY of the real .env.example>
# Appending to the REAL file matters: a synthetic fixture would not carry this file's 3-space prose
# style, its wrapped `--flag` continuations, or its graded headers — the exact shapes that broke
# three earlier drafts.
_probe() {
  local want="$1" name="$2" add="${3:-}"
  cp "$REPO/.env.example" "$T/.env.example"
  [ -n "$add" ] && printf '%s\n' "$add" >> "$T/.env.example"
  ( cd "$T" && REPO_ROOT="$T" bash scripts/check-how-provenance.sh >/dev/null 2>&1 ); local rc=$?
  local got; got=$([ "$rc" -ne 0 ] && echo FAIL || echo pass)
  if [ "$got" = "$want" ]; then ok "$name ($got)"
  else bad "$name: got $got, want $want" "rc=$rc"; fi
}

echo "== positive controls: a fabrication MUST be caught =="
_probe FAIL "A  original incident, bare on the how line" \
  '# how (VKS 9): vcf cluster kubeconfig get $C --export-file $K'
_probe FAIL "B  same command on a CONTINUATION line" \
  '# how: fetch it:
#      vcf cluster kubeconfig get $C --export-file $K'
_probe FAIL "D  invented binary + flag" \
  '# how: totallymadeup fetch-kubeconfig --export-file $X'
_probe FAIL "F3 fabricated vcf under a GRADED header (laundering)" \
  '# how (verified): a real thing
#      vcf cluster kubeconfig get $C --export-file /tmp/fabricated'
_probe FAIL "F6 fabrication + incidental kubectl in a parenthetical" \
  '# how: totallymadeup fetch-kc --export-file $X   (faster than kubectl get)'
_probe FAIL "F7 FLAGLESS fabrication" \
  '# how: totallymadeup fetch-kubeconfig now'

echo "== negative controls: a false RED gets a gate deleted =="
_probe pass "C  fabricated but TAGGED (disclosure, not truth — by design)" \
  '# how (verified): vcf cluster kubeconfig get $C --export-file $K'
_probe pass "F4 (Lab-verified) — the STRONGEST grade must be accepted" \
  '# how (Lab-verified 2026-07-22): vcf cluster kubeconfig get $C'
_probe pass "F4b (LAB-VERIFIED) uppercase" \
  '# how (LAB-VERIFIED): vcf cluster kubeconfig get $C'
# The path is deliberately GENERIC: check-app-hardcodes forbids a shared file naming a
# specific app, and this probe tests `make -C` parsing, not any app.
_probe pass "F5 make -C dir target is not a target named '-'" \
  '# how: make -C some/subdir app-test'
_probe pass "prose mentioning \`set -a\` must not read as a command" \
  '# how: load_env sources this file with `set -a` so it is exported'
_probe pass "the REAL file, unmodified, must be clean" ''

# The DENOMINATOR is part of the contract: the old gate claimed "all 85 '# how:' commands" while
# every continuation line and every answer had never been command-checked — it called answers
# commands. Assert the gate still PRINTS a reconcilable breakdown rather than a bare total.
cp "$REPO/.env.example" "$T/.env.example"
out="$( cd "$T" && REPO_ROOT="$T" bash scripts/check-how-provenance.sh 2>&1 )"
if printf '%s' "$out" | grep -qE 'command-checked.*provenance-graded.*non-command'; then
  ok "denominator is broken out (command-checked / graded / non-command), not a bare total"
else
  bad "the OK line no longer breaks the denominator out" "a bare total is how 'answers' got called 'commands'"
fi

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
