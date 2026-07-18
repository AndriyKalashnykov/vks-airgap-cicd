#!/usr/bin/env bash
# test-doc-robot-quoting.sh — offline both-directions test for check-doc-robot-quoting (B28).
#
# Part A EXECUTES the pure classifier `doc_robot_line_is_bad` (lib/os.sh) on the real doc corpus
# (every current CORRECT form must PASS) plus a planted UNQUOTED assignment of every shape (each must
# FAIL) — a green that cannot fail is not a test. The classifier is a pure function precisely so this
# file can run it rather than grep for it, and so no bad-form example string lands in a scanned `.md`.
#
# Part B RED-proves the SCANNER wiring in a throwaway git repo: green on the real (unmutated) docs
# (zero false positives on the actual corpus), and RED with its own signature on a planted bad doc.
# A THROWAWAY `git init` repo (not a worktree) because the gate reads via `git ls-files`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Part A — the pure classifier, both directions.
# ---------------------------------------------------------------------------
echo "== doc_robot_line_is_bad: correct forms PASS, unquoted forms FAIL =="

# must PASS (return 1 = not-bad). Quoted heredoc keeps $vks / backticks literal.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if doc_robot_line_is_bad "$line"; then bad "false-POSITIVE on a SAFE line: ${line}"; else ok "PASS (safe): ${line}"; fi
done <<'PASS'
HARBOR_USERNAME='robot$vks-cicd'
HARBOR_USERNAME='robot$<name>'
HARBOR_USERNAME=admin
HARBOR_USERNAME=admin   # or robot$vks-cicd
HARBOR_USERNAME=robot$vks-cicd  # env-quote-ok: WRONG example on purpose
HARBOR_USERNAME="pre"'robot$vks'
HARBOR_PASSWORD=<robot-secret>
# unquoted robot$vks-cicd expands $vks away -> robot-cicd -> 401.
**Expect:** a `robot$vks-cicd` account scoped to the cicd project
PASS

# must FAIL (return 0 = bad). Note the leading-whitespace case is deliberately indented.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if doc_robot_line_is_bad "$line"; then ok "FAIL (flagged, correct): ${line}"; else bad "false-NEGATIVE — an UNQUOTED robot credential was NOT flagged: ${line}"; fi
done <<'FAILC'
HARBOR_USERNAME=robot$vks-cicd
HARBOR_USERNAME="robot$vks-cicd"
  HARBOR_USERNAME=robot$vks-cicd
export HARBOR_USERNAME=robot$vks-cicd
HARBOR_USERNAME='pre'robot$vks
SOME_OTHER=robot$vks
FAILC

# ---------------------------------------------------------------------------
# Part B — the scanner: green on the real corpus, RED on a planted bad doc.
# ---------------------------------------------------------------------------
echo "== check-doc-robot-quoting.sh: green on real docs, RED on a planted unquoted credential =="
TMP="$(mktemp -d)" || die "mktemp -d failed"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then die "mktemp -d produced no dir — refusing (a blank \$TMP would target /)"; fi
trap 'rm -rf "$TMP"' EXIT
cp -a "${REPO_ROOT}/scripts" "${REPO_ROOT}/docs" "${REPO_ROOT}/README.md" "${REPO_ROOT}/.env.example" "$TMP"/
git -C "$TMP" init -q
git -C "$TMP" add -A     # index only; git ls-files --cached needs this
# REPO_ROOT MUST be pinned to $TMP: os.sh EXPORTS REPO_ROOT, so the value this test set when it sourced
# os.sh would leak into the gate child and make it scan the REAL tree (positive control vacuous, RED
# false). Pinning forces the gate onto the throwaway copy.
run_gate() { ( cd "$TMP" && REPO_ROOT="$TMP" bash scripts/check-doc-robot-quoting.sh ) >"$TMP/gate.out" 2>&1; }

# POSITIVE CONTROL — the gate MUST be green on the copied real docs, or the harness (or a real false
# positive on the actual corpus) is broken and the RED below is meaningless.
if run_gate; then ok "positive control: gate GREEN on the real doc corpus (no false positives)"
else cat "$TMP/gate.out" >&2; bad "positive control FAILED: gate is RED on the unmutated real docs — a false positive, or the harness is broken"; fi

# RED — plant an UNQUOTED robot credential in a new doc; the gate must redden with ITS signature.
# shellcheck disable=SC2016  # the LITERAL $vks is the point — the planted doc must contain robot$vks-cicd unexpanded.
printf 'A one-line note.\n\nHARBOR_USERNAME=robot$vks-cicd\n' > "$TMP/docs/_b28_red.md"
git -C "$TMP" add -A
run_gate; grc=$?
if [ "$grc" -ne 0 ] \
   && grep -q 'unquoted Harbor robot credential' "$TMP/gate.out" \
   && grep -q '_b28_red.md' "$TMP/gate.out"; then
  ok "RED: gate reddens with its real signature on a planted unquoted robot credential"
else
  bad "gate did NOT redden correctly on a planted bad doc (rc=$grc): $(head -2 "$TMP/gate.out")"
fi

echo
if [ "$rc" -eq 0 ]; then
  log_info "test-doc-robot-quoting: OK — ${checks} checks (classifier both directions + scanner RED-proof)"
else
  log_error "test-doc-robot-quoting: FAILED (${checks} checks ran)"
fi
exit "$rc"
