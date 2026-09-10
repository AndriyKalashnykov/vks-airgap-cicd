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

# ── ALLOWLIST: path|line|reason. Tiny and REASONED: an entry must say why the two-value emission
# CANNOT happen there, never that fixing it is inconvenient. Reconciled in BOTH directions below --
# an entry that stops matching is a dead exemption documenting a site that no longer exists.
ALLOW='scripts/test-env-validate-auth-truncation.sh|106|the text is a SEARCH PATTERN, not a fallback: this test asserts 02-env.sh no longer CONTAINS that shape'

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
  n=0; lineno=0
  while IFS= read -r line; do
    # COUNT FIRST. Incrementing after the comment-skip made `lineno` a count of NON-COMMENT lines,
    # so the allowlist key never matched the real file line -- measured: 1 declared, 0 matched.
    lineno=$((lineno + 1))
    s=${line#"${line%%[![:space:]]*}"}
    case "$s" in '#'*) continue ;; esac
    printf '%s\n' "$line" | grep -qE "$PAT" || continue
    _key="${f}|${lineno}|"
    case "$ALLOW" in *"$_key"*) allowed=$((allowed + 1)); continue ;; esac
    n=$((n + 1))
  done < "$f"
  # An allowlisted LINE is not a finding. Match on path+line, never path alone -- exempting a whole
  # file blinds the gate to every future real finding in it.
  if [ "$n" -gt 0 ]; then
    printf '%s|%s\n' "$f" "$n" >> "$TMP"
    hits=$((hits + n))
  fi
done <<EOF
$_files
EOF

echo "check-count-fallback: scanned ${scanned} file(s), ${allowed} allowlisted line(s)"
# A dead exemption is a claim about a site that no longer exists -- reconcile the OTHER direction.
_declared=$(printf '%s\n' "$ALLOW" | grep -c '|' || true)
if [ "${allowed}" -ne "${_declared}" ]; then
  echo "check-count-fallback: ${_declared} allowlist entr(ies) declared but ${allowed} matched — a DEAD exemption. Remove it." >&2
  exit 1
fi
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
