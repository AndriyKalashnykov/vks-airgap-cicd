#!/usr/bin/env bash
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
