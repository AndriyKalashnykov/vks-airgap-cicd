#!/usr/bin/env bash
# RED-proof for scripts/check-app-icons.sh — one case per DISCRIMINATOR, not per condition.
#
# WHY THIS FILE EXISTS. The gate shipped with only a by-hand RED-proof, and that loop MISSED the
# same bypass FOUR times: condition 3 passed a moved route off the shared markup, then off a test
# COMMENT, then off legal whitespace around `=`; and condition 4 passed off the TEMPLATE once the
# link tag's attributes were reordered. Separately, condition 5 was decided by `aria-label`, so two
# PIXEL-IDENTICAL icons passed. Per gates.md a hand-run proof expires at the next commit touching
# the gate or its toolchain — three of five conditions had nothing pinning their discriminators.
#
# ⚠️ EVERY CASE MUTATES A COPY. The tree under test is a `git ls-files`-driven COPY in $T, never the
# real repo: the gate resolves its corpus through `git -C "$REPO_ROOT" ls-files`, so each case gets
# its own throwaway git repo. Nothing here can touch the working tree.
#
# ⚠️ A RED IS NOT ENOUGH — each case asserts WHICH guard fired. Measured while building the gate: a
# mutation that moved a route made it go RED via condition 4, not condition 3. A red in the wrong
# place is not a proof; it means you mutated something else and the property is still untested.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

SRC="${REPO_ROOT}"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# THE APPS ARE DERIVED FROM THE REGISTRY, never named. `make check-app-hardcodes` forbids a shared
# script from naming an app, and it is right to: when app #7 arrives, a hand-typed name here rots
# silently. What a case actually needs is a LANGUAGE (go's route syntax, python's, nodejs' test
# file) — and language IS a registry column, so `app_of_lang` keeps this registry-driven while the
# per-language mutation stays a language `case`, exactly as lib/apps.sh does it.
app_of_lang() {
  local want="$1" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if [ "$(app_lang "$a")" = "$want" ]; then printf '%s' "$a"; return 0; fi
  done <<LANGS
$(app_names)
LANGS
  echo "HARNESS: the registry has no ${want} app — this case cannot run" >&2; return 1
}


pass=0; failn=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A throwaway checkout of the real tree. `git ls-files` in the COPY is what the gate will read.
fresh() {
  local d="${T}/w$1"
  rm -rf "$d"; mkdir -p "$d"
  # .env.example is REQUIRED: the gate's load_env dies FATAL without it, and every case then
  # 'fails' for a reason that has nothing to do with the gate. Measured while writing this file.
  ( cd "$SRC" && git archive HEAD apps scripts/lib scripts/check-app-icons.sh .env.example 2>/dev/null ) \
    | tar -x -C "$d" || { echo "HARNESS: could not build the sandbox — this is the TEST, not the gate"; exit 1; }
  # The WORKING-TREE gate + libs, so we test what is on DISK rather than what is committed.
  # apps/ deliberately comes from `git archive` ONLY. MEASURED while writing this: `cp -r apps`
  # also drags in obj/ target/ __pycache__/ — and the `git add -A` below then TRACKS them, so
  # `git ls-files` hands the gate six compiled copies of the icon and it reports "ships 6 icons".
  # Every case then fails for a reason that has nothing to do with the case.
  cp "${SRC}/scripts/check-app-icons.sh" "${d}/scripts/"
  cp "${SRC}/scripts/lib/"*.sh "${d}/scripts/lib/" 2>/dev/null || true
  [ -s "${d}/scripts/check-app-icons.sh" ] || { echo "HARNESS: sandbox is empty"; exit 1; }
  ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 && \
    git -c user.email=t@t -c user.name=t commit -qm s >/dev/null 2>&1 ) || {
      echo "HARNESS: could not init the sandbox repo"; exit 1; }
  printf '%s' "$d"
}

# run <label> <dir> <want-rc> <want-substring-in-output>
run() {
  local label="$1" d="$2" want="$3" needle="$4" out rc=0
  out="$( cd "$d" && REPO_ROOT="$d" SKIP_DOTENV=1 bash scripts/check-app-icons.sh 2>&1 )" || rc=$?
  if [ "$rc" -ne "$want" ]; then
    printf '  FAIL %-46s rc=%s want=%s\n' "$label" "$rc" "$want"; failn=$((failn+1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF "$needle" <<< "$out"; then
    printf '  FAIL %-46s rc ok but the WRONG guard fired\n' "$label"
    printf '       wanted: %s\n' "$needle"
    printf '       got   : %s\n' "$(grep -m1 'level=ERROR' <<< "$out" | cut -c1-110)"
    failn=$((failn+1)); return
  fi
  printf '  ok   %s\n' "$label"; pass=$((pass+1))
}

echo "== check-app-icons.sh — RED-proof =="

d="$(fresh base)"; run "GREEN on an unmutated tree" "$d" 0 ""

# 1 ENUMERATION
d="$(fresh enum)"
sed -i 's#<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"#<XX #' "${d}/$(app_src "$(app_of_lang python)")/app.py"
run "1 enumeration: an app ships no icon" "$d" 1 "ships NO icon"

# 2 STRUCTURE — a '#' colour (the data-URI-fragment / rust-raw-string trap)
d="$(fresh hash)"
perl -pi -e 's/fill="rgb\(0,173,216\)"/fill="\#00ADD8"/' "${d}/$(app_src "$(app_of_lang go)")/main.go"
run "2 structure: a '#' colour" "$d" 1 "contains a '#'"

# 3 THE ROUTE JOIN — route moved, markup and test untouched
d="$(fresh join)"
perl -pi -e 's{r\.Get\("/favicon\.svg"}{r.Get("/icon.svg"}' "${d}/$(app_src "$(app_of_lang go)")/main.go"
run "3 join: the route moved to another path" "$d" 1 "no ROUTE is registered"

# 3b THE WHITESPACE BYPASS — the third incarnation of the same hole
d="$(fresh ws)"
perl -pi -e 's{r\.Get\("/favicon\.svg"}{r.Get("/icon.svg"}' "${d}/$(app_src "$(app_of_lang go)")/main.go"
perl -pi -e 's{href="/favicon\.svg"}{href = "/favicon.svg"}' "${d}/$(app_src "$(app_of_lang go)")/main.go"
run "3b join: moved route + 'href = ' whitespace" "$d" 1 "no ROUTE is registered"

# 3c THE MARKUP-ORDER ASSERTION that makes condition 4's one-char guard sound
d="$(fresh order)"
perl -pi -e 's{<link rel="icon" type="image/svg\+xml" href="/favicon\.svg"/>}{<link type="image/svg+xml" href="/favicon.svg" rel="icon"/>}' \
  "${d}/$(app_src "$(app_of_lang go)")/main.go"
run "3c markup: the <link> attributes reordered" "$d" 1 "is not written as"

# 4 THE TEST — extractor removed, comments left in place (bypass #2 and #3 were both comments)
d="$(fresh test)"
perl -pi -e 's{<link rel="icon"\[\^>\]\*href}{<link rel="NOPE"[^>]*href}' "${d}/$(app_src "$(app_of_lang nodejs)")/server.test.js"
run "4 test: the href extractor removed" "$d" 1 "no TEST parses"

# 5 DISTINCTNESS — the HIGH. Two PIXEL-IDENTICAL icons that differ only in aria-label.
d="$(fresh dist)"
perl -pi -e 's/fill="rgb\(55,118,171\)"/fill="rgb(0,173,216)"/; s{>Py</text>}{>Go</text>}' \
  "${d}/$(app_src "$(app_of_lang python)")/app.py"
run "5 distinct: same pixels, different aria-label" "$d" 1 "ship the SAME icon"

# 5b the CONTROL for 5: genuinely different icons must stay GREEN (no false RED)
d="$(fresh distok)"
perl -pi -e 's/fill="rgb\(55,118,171\)"/fill="rgb(1,2,3)"/' "${d}/$(app_src "$(app_of_lang python)")/app.py"
run "5b control: a merely recoloured icon is fine" "$d" 0 ""

# 6 the git-driven corpus: an untracked leftover must NOT be a false RED
d="$(fresh untracked)"
_go="${d}/$(app_src "$(app_of_lang go)")/main.go"; cp "$_go" "${_go}.orig"
run "6 corpus: an untracked main.go.orig is ignored" "$d" 0 ""

# 7 VACUITY: starve the corpus — the gate must not pass by not looking
d="$(fresh starve)"
while IFS= read -r f; do [ -n "$f" ] && : > "${d}/${f}"; done <<EOF
$( cd "$d" && git ls-files -- apps | grep -vE 'registry\.tsv$' )
EOF
run "7 vacuity: every app file EMPTIED" "$d" 1 "ships NO icon"

echo
if [ "$failn" -ne 0 ]; then
  echo "check-app-icons RED-proof: ${failn} FAILED, ${pass} passed"; exit 1
fi
echo "check-app-icons RED-proof: ALL ${pass} passed"
