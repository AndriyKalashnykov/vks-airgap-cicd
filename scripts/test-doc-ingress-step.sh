#!/usr/bin/env bash
# test-doc-ingress-step.sh — pin check-doc-ingress-step against the ways a DOCUMENT can look
# executable to a naive reader and not be executable by the walk.
#
# WHY EACH FIXTURE EXISTS. The gate answers one question — "will `walk-doc.sh` actually RUN this
# document's ingress step?" — and it answers it with a SECOND parser. Every divergence between the
# two is a FALSE GREEN: the gate certifies a document the walk extracts nothing from. An
# implementation-round adversary measured three, and all three are what an author does naturally:
#
#   ```text / ```console   the info string is ignored -> gate green, walk extracts ZERO
#   ````-wrapped block     an odd number of ``` lines inside INVERTS the toggle for the rest of file
#   <details>              scenario-2 already collapses alternatives; the walk SKIPS them
#
# The first version of the gate failed all three. They are fixtures here so a future "simplify it
# back to awk" is red before it is committed.
#
# HONESTY: this pins the GATE's verdict. It does not run `walk-doc.sh` over each fixture — that
# needs a repo context and nine WALK_* variables — so it proves the gate implements the walk's rules
# as WRITTEN HERE, not that the two parsers can never drift again. If walk-doc's extractor changes,
# this suite stays green and the gate is wrong; the header of the gate names that coupling.
# EVERY fixture below is MARKDOWN, so backticks are its subject matter -- the ``` fences are the
# thing under test. Inside the single quotes they are literal, which is exactly right; the linter
# reads them as a would-be expansion. Suppressed file-wide with the reason stated here rather than
# per line, because there is a fixture on nearly every one. (A comment whose first word after the
# hash is the linter's own name is parsed as a DIRECTIVE, not prose -- hence this wording.)
# shellcheck disable=SC2016
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/docs" "$T/scripts"
cp "$SCRIPT_DIR/check-doc-ingress-step.sh" "$T/scripts/"

# Run the gate against a THROWAWAY docs/ so the real documents cannot influence the verdict, and so
# a fixture can never be mistaken for a repo document.
# ⚠️ RC IS SET IN *THIS* SHELL, and the output goes to a FILE. `out="$(run ...)"` would run `run`
# in a command substitution -- a SUBSHELL -- so the RC it assigns is discarded and every rc
# assertion reads a stale value. Same trap as a helper that "also sets a global".
OUT="$T/out.txt"
run() {  # run <fixture-body>  ->  writes $OUT, sets RC
  rm -f "$T"/docs/scenario-*.md
  printf '%s' "$1" > "$T/docs/scenario-fixture.md"
  ( cd "$T" && REPO_ROOT="$T" bash scripts/check-doc-ingress-step.sh ) > "$OUT" 2>&1; RC=$?
}

_fence()  { printf '```bash\n%s\n```\n' "$1"; }

# ---- 1. the SHAPE THAT SHIPPED: a table cell and prose, no fence anywhere ------------------------
run "$(printf '# f\n\n| It says | You run |\n|---|---|\n| here | `make install-ingress INGRESS_CONTROLLER=istio-existing` |\n\nprose about `make install-ingress`.\n')"
run "$(printf '# f\n\n| It says | You run |\n|---|---|\n| here | `make install-ingress INGRESS_CONTROLLER=istio-existing` |\n\nprose about `make install-ingress`.\n')"
if [ "$RC" -ne 0 ]; then ok "a table cell + prose is REFUSED (the state that shipped)"
else bad "a table-only ingress step PASSED — this is the exact defect, and a naive grep passes it too"; fi

# ---- 2. the FIX: fenced install + fenced verify --------------------------------------------------
run "$(printf '# f\n\n%s\n%s\n' "$(_fence 'make install-ingress INGRESS_CONTROLLER=istio-existing')" "$(_fence 'make verify-ingress')")"
if [ "$RC" -eq 0 ]; then ok "a fenced install + fenced verify PASSES"
else bad "the correct shape was REFUSED (rc=$RC) — the gate would block the fix it exists to require"; fi

# ---- 3. fenced install, NO verify ---------------------------------------------------------------
run "$(printf '# f\n\n%s\n' "$(_fence 'make install-ingress')")"
if [ "$RC" -ne 0 ]; then ok "a fenced install with NO verify is REFUSED"
else bad "an unverified ingress step PASSED"; fi

# ---- 4. DIVERGENCE A: the info string. ```text is not executable ---------------------------------
run "$(printf '# f\n\n```text\nmake install-ingress\nmake verify-ingress\n```\n')"
if [ "$RC" -ne 0 ]; then ok "a \`\`\`text block does NOT count — the walk executes bash|sh|shell only"
else bad "a \`\`\`text ingress step PASSED — the gate ignores the info string, so it certifies a document the walk extracts NOTHING from"; fi

# ---- 5. DIVERGENCE B: the 4-backtick wrapper. An odd number of ``` inside must not desync --------
# A ````-fence is how a document SHOWS a ```bash block without running it. Its inner lines are NOT
# executable, and — the part a toggle gets wrong — the wrapper must not invert the state afterwards.
run "$(printf '# f\n\n````markdown\n```bash\nmake install-ingress\n````\n\nmake verify-ingress\n')"
if [ "$RC" -ne 0 ]; then ok "a 4-backtick wrapper neither counts nor DESYNCS the lines after it"
else bad "the 4-backtick wrapper passed — a toggle inverted, so prose after it was read as fenced"; fi

# ---- 6. DIVERGENCE C: <details>. The walk SKIPS a collapsed alternative --------------------------
run "$(printf '# f\n\n<details>\n<summary>only if a mesh is here</summary>\n\n%s\n%s\n\n</details>\n' "$(_fence 'make install-ingress INGRESS_CONTROLLER=istio-existing')" "$(_fence 'make verify-ingress')")"
if [ "$RC" -ne 0 ]; then ok "an ingress step collapsed into <details> is REFUSED (the walk skips those)"
else bad "a <details>-collapsed ingress step PASSED — the walk would skip it, so the row still cannot install one"; fi

# ---- 7. the swallow arm must not swallow a REAL step written with make's own flags ---------------
run "$(printf '# f

%s
' "$(_fence 'make -C .. install-ingress')")"
if [ "$RC" -ne 0 ] && ! grep -q 'no ingress step MATCHED' "$OUT"; then
  ok "\`make -C .. install-ingress\` is SEEN (it is an ingress step, and it has no verify)"
else bad "a flag between make and the target made the gate report 'no ingress step' on a document that installs one: $(cat "$OUT")"; fi

# ---- 8. a document with NO ingress step at all is not this gate's business -----------------------
run "$(printf '# f\n\nnothing to see.\n')"
if [ "$RC" -eq 0 ] && grep -q 'no ingress step MATCHED' "$OUT"; then
  ok "a document with no ingress step passes, and SAYS it could not see one"
else bad "a document with no ingress step was mishandled (rc=$RC): $(cat "$OUT")"; fi

# ---- 9. the denominator must be real, and starvation must FAIL, not pass silently ----------------
rm -f "$T"/docs/scenario-*.md
( cd "$T" && REPO_ROOT="$T" bash scripts/check-doc-ingress-step.sh >/dev/null 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then ok "an EMPTY docs/ FAILS — a gate that scanned nothing must not report OK"
else bad "the gate reported success having scanned ZERO documents"; fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
