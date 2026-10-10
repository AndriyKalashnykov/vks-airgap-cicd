#!/usr/bin/env bash
# check-count-fallback — a COUNTING command whose `||` fallback EMITS A VALUE prints TWO values.
#
# `grep -c` PRINTS its count AND EXITS 1 when the count is zero (and exits 2 when the file is
# missing). So the reflex `n=$(... | grep -c PAT || echo 0)` fires the fallback ON THE NO-MATCH
# PATH TOO, and the captured value becomes "0\n0". MEASURED:
#
#     match   -> [1]
#     nomatch -> [0
#                0]        and `[ "$v" -eq 0 ]` dies: "integer expression expected"
#
# THE FAILURE IS A SILENT WRONG ANSWER, and it lands in two shapes:
#   * a COMPARISON breaks loudly-but-confusingly, or passes BY ACCIDENT when a later `read`
#     truncates at the newline (measured at test-env-publish.sh, which is correct only by luck);
#   * a DIAGNOSTIC prints "0" then "?" -- and diagnostics are exactly where you are already
#     confused, so a two-line count reads as instrument noise rather than the bug it is.
#
# ⚠️ `|| true` IS CORRECT AND IS NOT FLAGGED. It swallows the exit status and emits NOTHING extra,
# which is why the tree already uses it 78 times. The defect is a fallback that *produces a value*.
#
# THE FIX is one of:
#   a) `|| true`                       — when the count is the only thing you need
#   b) `| wc -l`                       — always exits 0, always prints a number (best for `grep -c .`)
#   c) capture the rc on its own line  — when you genuinely must tell "no match" from "no file"
#
# Provenance: found 2026-09-09 in my OWN probe while asking whether a subagent had authenticated to
# vCenter. The helper returned "0\n0", every comparison failed, and for several minutes an absence
# of evidence read as evidence of absence. The repo turned out to carry the same shape.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
cd "$REPO_ROOT"
SELF="$(basename "${BASH_SOURCE[0]}")"

# COMPOSED AT RUNTIME so this file is not its own finding. A literal here would make the gate flag
# itself, and the reflex fix -- excluding this file by name -- would blind it to every future real
# finding in it. (gates.md: "compose the token, never exclude the file".)
PAT="($(printf 'grep -c')o?|$(printf 'wc -l'))[^|]*\|\|[[:space:]]*($(printf 'echo')|$(printf 'printf'))"

# ── ALLOWLIST: path|fragment|reason, one entry per line. Tiny and REASONED: an entry must say why
# the two-value emission CANNOT happen there, never that fixing it is inconvenient.
# KEYED BY A FRAGMENT OF THE LINE, NOT ITS NUMBER. It was `path|108|…`, and a line number moves
# with every edit above it: the entry then matched nothing (reported as a dead exemption) while
# the line it was written for became a finding. The fragment is fixed text the flagged line must
# CONTAIN (no `|` in it); it has to be specific enough to pick ONE flagged line in that file.
# Reconciled in BOTH directions below: an entry that matches no flagged line is a dead exemption,
# and one that matches more than one is exempting a line nobody reasoned about.
ALLOW='scripts/test-env-validate-auth-truncation.sh|users/current\" 2>/dev/null|the text is a SEARCH PATTERN, not a fallback: this test asserts 02-env.sh no longer CONTAINS that shape'

# _allowed <file> <line> -- rc 0 when an entry for this file names a fragment the line contains.
# Counts the match per entry (ALLOW_HITS, one "path|fragment" per matched line) for the reconcile.
ALLOW_HITS=""
_allowed() {
  local e p rest frag
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    p="${e%%|*}"; rest="${e#*|}"; frag="${rest%%|*}"
    if [ "$p" != "$1" ] || [ -z "$frag" ]; then continue; fi
    case "$2" in *"$frag"*) ALLOW_HITS="${ALLOW_HITS}${p}|${frag}"$'\n'; return 0 ;; esac
  done <<EOF_ALLOW
$ALLOW
EOF_ALLOW
  return 1
}

_files=$(git ls-files 'scripts/*.sh' 'Makefile' 2>/dev/null || true)
[ -n "$_files" ] || { echo "check-count-fallback: no files to scan — REFUSING (a scan of nothing is not a pass)"; exit 1; }

scanned=0; hits=0; allowed=0; TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$(basename "$f")" = "$SELF" ] && continue   # see the composed-token note above
  scanned=$((scanned + 1))
  # STRIP COMMENTS: this is a must-NOT-exist check, so a commented-out occurrence executes nothing
  # and is harmless. (The opposite polarity applies to a must-EXIST check -- gates.md.)
  # Test the FIRST NON-SPACE character, never `${line%%#*}`, which false-negatives on ${#ARR[@]}.
  n=0; _path="$f"      # the path as TEXT for the allowlist (a second name: the loop below reads "$f")
  while IFS= read -r line; do
    s=${line#"${line%%[![:space:]]*}"}
    case "$s" in '#'*) continue ;; esac
    printf '%s\n' "$line" | grep -qE "$PAT" || continue
    if _allowed "$_path" "$line"; then allowed=$((allowed + 1)); continue; fi
    n=$((n + 1))
  done < "$f"
  # An allowlisted LINE is not a finding. Match on path+fragment, never path alone -- exempting a
  # whole file blinds the gate to every future real finding in it.
  if [ "$n" -gt 0 ]; then
    printf '%s|%s\n' "$f" "$n" >> "$TMP"
    hits=$((hits + n))
  fi
done <<EOF
$_files
EOF

echo "check-count-fallback: scanned ${scanned} file(s), ${allowed} allowlisted line(s)"
# A dead exemption is a claim about a site that no longer exists -- reconcile the OTHER direction.
# Per ENTRY, not by totals: two lines matching one entry would otherwise cancel a dead one.
_declared=0; _reconcile=0
while IFS= read -r _e; do
  [ -n "$_e" ] || continue
  _declared=$((_declared + 1))
  _ek="${_e%%|*}|"; _er="${_e#*|}"; _ek="${_ek}${_er%%|*}"
  _eh=$(printf '%s' "$ALLOW_HITS" | grep -cxF -- "$_ek" || true)
  if [ "$_eh" -eq 0 ]; then
    echo "check-count-fallback: allowlist entry '${_ek}' matched NO flagged line — a DEAD exemption (the line changed or is gone). Remove it, or give it the line's current text." >&2
    _reconcile=1
  elif [ "$_eh" -gt 1 ]; then
    echo "check-count-fallback: allowlist entry '${_ek}' matched ${_eh} flagged lines — the fragment is too loose: it exempts a line nobody reasoned about." >&2
    _reconcile=1
  fi
done <<EOF_ALLOW
$ALLOW
EOF_ALLOW
echo "check-count-fallback: ${_declared} allowlist entr(ies) declared, ${allowed} line(s) matched"
[ "$_reconcile" -eq 0 ] || exit 1
if [ "$hits" -eq 0 ]; then echo "check-count-fallback: OK — no counting command emits a value from its || fallback"; exit 0; fi

echo "check-count-fallback: FOUND ${hits} occurrence(s) — a counting command with a value-emitting || fallback:" >&2
while IFS='|' read -r f n; do
  [ -n "${f:-}" ] || continue
  echo "  ${f}: ${n}" >&2
  grep -nE "$PAT" "$f" | sed 's/^/      /' >&2
done < "$TMP"
cat >&2 <<'WHY'

  WHY: `grep -c` prints its count AND exits 1 on zero, so the fallback fires on the NO-MATCH path
  too and the captured value is "0\n0". Fix with `|| true`, or `| wc -l` (always exits 0), or by
  capturing the rc on its own line when you must tell "no match" from "no file".
WHY
exit 1
