#!/usr/bin/env bash
# shellcheck disable=SC2016
# ^ DELIBERATE, file-scoped, same reason as test-http-fail-hint.sh: `ck` takes its condition as
# a STRING and `eval`s it, so single quotes are required — expansion must happen at eval time,
# inside the assertion. Double-quoting would run the assert_k8s_manifest calls (which `die`)
# when the ARGUMENT is built rather than when ck evaluates it.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source os.sh"; exit 1; }
pass=0; fail=0
ck(){ if eval "$2"; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "--- GREEN: real downloaded manifests must PASS ---"
n=0
for f in "${MANIFEST_GREEN_DIR:-bundle/manifests}"/*.yaml; do
  [ -f "$f" ] || continue
  n=$((n+1))
  ck "real manifest $(basename "$f")" "( assert_k8s_manifest '$f' 'https://x' ) >/dev/null 2>&1"
done
echo "  (GREEN arm covered $n real file(s))"
# ⚠️ MED-1 from the implementation round: bundle/manifests is a GITIGNORED build artifact, so on a
# fresh clone or a CI runner this arm covers ZERO files and `[ -f "$f" ] || continue` makes that a
# SILENT no-op. This test is in TEST_FAST, i.e. it runs on every PR, where the arm is always 0. Say
# so loudly instead of printing a denominator nothing gates on.
if [ -d "${MANIFEST_GREEN_DIR:-bundle/manifests}" ]; then
  ck "the GREEN arm was NON-VACUOUS (the dir exists, so it must hold manifests)" "[ $n -gt 0 ]"
else
  printf '  SKIP  no %s — the GREEN arm did NOT run. That is ZERO coverage, not a pass.\n' \
    "${MANIFEST_GREEN_DIR:-bundle/manifests}"
fi

echo "--- the DIE MESSAGE is the deliverable, so assert it (MED-2) ---"
# Every case above redirects to /dev/null and asserts only the exit status. MEASURED by the round:
# replacing the whole captive-portal diagnostic with `die "nope"` still scored 7 passed, 0 failed.
printf '<html>Sign in to continue</html>\n' > "$T/portal.yaml"
ck "the die NAMES the captive-portal cause" \
   'grep -qi "captive portal" <<< "$( ( assert_k8s_manifest "$T/portal.yaml" https://x ) 2>&1 )"'
ck "...and SHOWS what actually arrived"     \
   'grep -qi "Sign in to continue" <<< "$( ( assert_k8s_manifest "$T/portal.yaml" https://x ) 2>&1 )"'
ck "...and names the URL it fetched"        \
   'grep -q "example.invalid" <<< "$( ( assert_k8s_manifest "$T/portal.yaml" https://example.invalid/m.yaml ) 2>&1 )"' 

echo "--- RED: each portal body shape must DIE ---"
printf '<html>CORPORATE BLOCK PAGE</html>\n'        > "$T/a"; ck "HTML block page DIES"      "! ( assert_k8s_manifest '$T/a' 'https://x' ) >/dev/null 2>&1"
printf '<!DOCTYPE html>\n<title>Sign in</title>\n'  > "$T/b"; ck "DOCTYPE sign-in DIES"      "! ( assert_k8s_manifest '$T/b' 'https://x' ) >/dev/null 2>&1"
printf 'Access Denied by Policy\n'                  > "$T/c"; ck "Access-Denied text DIES"   "! ( assert_k8s_manifest '$T/c' 'https://x' ) >/dev/null 2>&1"
printf '{"error":"blocked"}\n'                      > "$T/d"; ck "JSON error DIES"           "! ( assert_k8s_manifest '$T/d' 'https://x' ) >/dev/null 2>&1"
: > "$T/e";                                                   ck "EMPTY file DIES"           "! ( assert_k8s_manifest '$T/e' 'https://x' ) >/dev/null 2>&1"

echo "--- the DISCRIMINATOR: indented apiVersion is a nested field, not a document ---"
printf 'spec:\n  apiVersion: v1\n'                  > "$T/f"; ck "indented apiVersion DIES"  "! ( assert_k8s_manifest '$T/f' 'https://x' ) >/dev/null 2>&1"
printf 'apiVersion: v1\nkind: ConfigMap\n'          > "$T/g"; ck "column-0 apiVersion PASSES" "( assert_k8s_manifest '$T/g' 'https://x' ) >/dev/null 2>&1"

echo "  RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
