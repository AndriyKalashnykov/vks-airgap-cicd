#!/usr/bin/env bash
# check-doc-expect-leak.sh — an `**Expect:**` line must not quote a name the READER HAS NEVER MET.
#
# THE DEFECT, committed 2026-08-16 and caught by the owner, not by any gate:
#   scenario-1 §8 gained  **Expect:** `HARBOR_CA_FILE: verifies` ...
#   `HARBOR_CA_FILE` appears in scenario-1 exactly ONCE — on that line. The operator following that
#   runbook is shown an environment variable they are never told about, never set, and cannot act on.
#   It leaked because the TOOL labelled its output with the variable name; the fix was in the tool
#   (29-ca-status.sh now prints "Harbor CA (<path>) verifies <host>"), and this gate stops the class.
#
# THE PREDICATE, and why this one:
#   An Expect line is the document's CONTRACT — "here is what you will see". A name that occurs
#   ONLY there was, by construction, pasted from our internals: nothing in the document introduces
#   it, defines it, or asks the reader to set it. That is mechanical, needs no judgment, and does
#   not care whether the introduction was a table row, an assignment, or a sentence.
#
#   MEASURED FALSE-RED RATE before shipping (the thing that decides whether a gate survives):
#   over the 40 Expect lines in the two runbooks, the ONLY names quoted are ARGOCD_SERVER,
#   VKS_K8S_VERSION, VKS_CONTEXT, VKS_AUTH_METHOD, HARBOR_USERNAME, HARBOR_PASSWORD -- every one of
#   them introduced elsewhere in its own document. 0 false RED. A narrower earlier draft that
#   demanded a TABLE ROW or an assignment scored 2 false RED on HARBOR_USERNAME/HARBOR_PASSWORD,
#   which §8.5 introduces in prose; that draft was rejected for it.
#
# WHAT IT DOES NOT CATCH, said out loud so nobody reads the green as more than it is:
#   - internal jargon that is not UPPER_SNAKE ("the state overlay", "rc=2", a script filename);
#   - a name introduced ONCE in prose and then used as if familiar -- introduced is introduced;
#   - anything outside an Expect line. Re-reading the whole document as the end user is DISCIPLINE,
#     not a gate, and this does not replace it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DOCS="${1:-docs/scenario-1.md docs/scenario-2.md}"
leaks=0; checked=0; lines=0

for D in $DOCS; do
  [ -f "$D" ] || { echo "check-doc-expect-leak: no such document: $D"; exit 1; }
  while IFS=: read -r n rest; do
    [ -n "${n:-}" ] || continue
    lines=$((lines + 1))
    # every backticked literal on the Expect line -> every UPPER_SNAKE token inside it
    for t in $(printf '%s\n' "$rest" | grep -oE '`[^`]+`' | tr -d '`' \
               | grep -oE '\b[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\b' | sort -u); do
      checked=$((checked + 1))
      # Does it appear ANYWHERE in this document other than on an Expect line?
      elsewhere=$(grep -n "$t" "$D" | grep -vcE ':[[:space:]]*\*\*Expect' || true)
      if [ "$elsewhere" -eq 0 ]; then
        leaks=$((leaks + 1))
        echo "${D}:${n}: LEAK — \`${t}\` is quoted in an **Expect:** line and appears NOWHERE else in this document."
        echo "    The reader is never told what it is or asked to set it. Either introduce it, or —"
        echo "    usually right — stop printing an internal name at them and give the output a human label."
      fi
    done
  done < <(grep -nE '^[[:space:]]*\*\*Expect' "$D")
done

# THE DENOMINATOR. A gate that cannot say what it looked at cannot be trusted to have looked, and
# this one is silent by construction on a healthy corpus.
printf 'check-doc-expect-leak: examined %d Expect line(s) across %s, %d quoted name(s), %d leak(s)\n' \
  "$lines" "$(printf '%s' "$DOCS" | wc -w) document(s)" "$checked" "$leaks"

[ "$lines" -gt 0 ] || { echo "REFUSING: found 0 Expect lines — the extractor is broken, not the docs"; exit 1; }
[ "$leaks" -eq 0 ] || exit 1
echo "check-doc-expect-leak: OK"
