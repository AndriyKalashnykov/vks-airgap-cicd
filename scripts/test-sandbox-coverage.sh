#!/usr/bin/env bash
# ci-tier: fast — offline; reads scripts/*.sh and plants fixtures under mktemp. No network, no cluster.
# ============================================================================
# GATE: every unit test that NAMES a script able to reach a lab is fenced, or says why not.
#
# WHY (B751). The Supervisor-kubeconfig resolver in lib/os.sh defaults to a sibling lab's REAL
# kubeconfig under $HOME, two of its consumers create and destroy clusters, and each test used to
# assemble its own subset of the pins that close that. Four tests pinned the lab directory; the
# rest relied on whatever the script happened to do first. scripts/lib/test-sandbox.sh is the
# whole pin set, and this gate is what keeps a NEW test from being written without it.
#
# THE RULE. A scripts/test-*.sh whose code (comment lines removed) names
#     - a numbered step script              scripts/NN-*.sh
#     - the credential report               (the one whose name this file composes at run time)
#     - any other non-test script that CALLS the resolver   (derived by grep, below -- not typed)
# or STARTS A BACKGROUND JOB (a line ending in a single `&`, or `& pid=$!`)
# must either
#     source scripts/lib/test-sandbox.sh  BEFORE the first line that names such a script, or
#     carry one comment line   `# test-sandbox: exempt — <why this test cannot reach a lab>`
#
# ⚠️ "NAMES", NOT "EXECUTES", ON PURPOSE. Whether a test runs a script cannot be read off its text:
# `S="$REPO/scripts/04-x.sh"; bash "$S"` and `grep -c foo "$S"` look the same to a grep. A rule
# keyed on an execution verb is green for every indirection it did not think of, so this one is
# keyed on the NAME, which over-asks: a test that only greps a script must say so in a marker.
#
# WHY A BACKGROUND JOB IS IN THE RULE. MEASURED: when such a test is killed (TERM, HUP), bash runs
# its EXIT trap, the trap deletes the stub dir, and the child it started is still alive -- its next
# fresh `kubectl` lookup resolves to whatever is left on PATH. The helper's exit handler kills the
# test's descendants BEFORE removing anything; scripts/test-test-sandbox.sh pins both arms.
#
# WHAT A GREEN HERE DOES NOT PROVE: that the fence HOLDS for a given test -- a test may re-point a
# pin after sourcing the helper. The guard directory (scripts/test-guard/) is what refuses a real
# tool at run time; this gate only proves the fence was put up.
# ============================================================================
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }

# Code lines only: a line whose first non-blank character is `#` is a comment.
code_of() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }

# ---- the risky set, DERIVED -----------------------------------------------------------------
# Composed, never typed: this file is itself a scripts/test-*.sh, so a literal script name on a
# code line here would make the gate one of its own subjects.
_resolver="supervisor_kube""config"
_report="creds"".sh"
_amp="&"   # the planted fixtures below must not put a background-job line into THIS file's code
: > "$T/risky"
n_numbered=0; n_consumers=0
for f in "$SCRIPTS"/[0-9][0-9]-*.sh; do
  [ -f "$f" ] || continue
  basename "$f" >> "$T/risky"; n_numbered=$((n_numbered + 1))
done
for f in "$SCRIPTS"/*.sh; do
  b="$(basename "$f")"
  case "$b" in test-*|[0-9][0-9]-*) continue ;; esac
  if code_of "$f" | grep -qE "(^|[^A-Za-z0-9_])${_resolver}(_or_die|_candidates|_hint)?([^A-Za-z0-9_]|\$)"; then
    printf '%s\n' "$b" >> "$T/risky"; n_consumers=$((n_consumers + 1))
  fi
done
grep -qxF "$_report" "$T/risky" || printf '%s\n' "$_report" >> "$T/risky"
# every numbered script that calls the resolver, for the denominator printed below
n_num_consumers=0
for f in "$SCRIPTS"/[0-9][0-9]-*.sh; do
  [ -f "$f" ] || continue
  code_of "$f" | grep -qE "(^|[^A-Za-z0-9_])${_resolver}(_or_die|_candidates|_hint)?([^A-Za-z0-9_]|\$)" \
    && n_num_consumers=$((n_num_consumers + 1))
done
# One ERE: a risky basename not preceded by a name character (so `x04-a.sh` is not `04-a.sh`).
risky_re="(^|[^A-Za-z0-9_.-])($(sed 's/[.]/[.]/g' "$T/risky" | paste -sd'|' -))"

# A line that starts a background job: it ends in ONE `&` (not `&&`, not `>&`, not `|&`), or
# captures the pid straight after one.
bg_re='(^|[^&|>])&[[:space:]]*($|#)|[^&|>]&[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$!'

# ---- the scanner ----------------------------------------------------------------------------
# scan <dir>  ->  lines:  SCANNED n | NAMING n | FENCED n | EXEMPT n | EXEMPTION <file>: <why>
#                         BAD <file>: <reason>
scan() {
  local dir="$1" f b scanned=0 naming=0 fenced=0 exempt=0 backgrounding=0 lifted=0 first_use helper_line mentions why lift
  for f in "$dir"/test-*.sh; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1)); b="$(basename "$f")"
    # first CODE line (by file line number) that names a risky script, or backgrounds a job
    first_use="$(grep -nE "$risky_re|$bg_re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)"
    [ -n "$first_use" ] || continue
    naming=$((naming + 1))
    if grep -E "$bg_re" "$f" | grep -qvE '^[[:space:]]*#'; then backgrounding=$((backgrounding + 1)); fi
    # the helper, SOURCED AS THE TEST'S FIRST COMMAND: unindented, with nothing before it but
    # comments, blank lines, `set …` and a TEST_SANDBOX_* assignment (the documented lift). That
    # is what makes "it is sourced" mean "it RUNS, before anything else does": a helper line
    # inside `if false`, a function nobody calls or a heredoc, or after `exit 0`, is by
    # construction not the first command. A trailing comment is cut before the match, so a line
    # that only MENTIONS the helper there is not one. (`mentions` is the old, looser reading,
    # kept to word the refusal.)
    helper_line="$(awk '
      /^[[:space:]]*(#|$)/ { next }
      /^set[[:space:]][^;|&<>()`$]*$/ { next }   # a bare `set ...` only: `set -u; exit 0` is a command line
      /^TEST_SANDBOX_[A-Z_]+=[^[:space:];|&<>()]*[[:space:]]*(#.*)?$/ { next }
      { l = $0; sub(/[[:space:]]#.*$/, "", l)
        if (l ~ /^(\.|source)[[:space:]].*lib\/test-sandbox[.]sh/) print NR
        exit }' "$f")"
    mentions="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*lib/test-sandbox[.]sh' "$f" | head -1 | cut -d: -f1)"
    why="$(grep -E '^#[[:space:]]*test-sandbox:[[:space:]]*exempt' "$f" | head -1 \
           | sed -E 's/^#[[:space:]]*test-sandbox:[[:space:]]*exempt[[:space:]]*(—|--|-|:)?[[:space:]]*//')"
    if [ -n "$helper_line" ]; then
      if [ "$helper_line" -lt "$first_use" ]; then
        fenced=$((fenced + 1))
        # A fenced test may LIFT a pin for a root it owns. Printed, never refused: the lift is
        # the test's stated need, and a list nobody prints is how it would grow unseen.
        lift=""
        grep -qE '^TEST_SANDBOX_REPO_ROOT=keep' "$f" && lift="${lift} REPO_ROOT=kept"
        grep -qE '^export SKIP_DOTENV=0' "$f"       && lift="${lift} SKIP_DOTENV=0"
        if [ -n "$lift" ]; then lifted=$((lifted + 1)); printf 'LIFT %s:%s\n' "$b" "$lift"; fi
      else printf 'BAD %s: sources the helper at line %s, AFTER it first names a lab-capable script or backgrounds a job (line %s)\n' "$b" "$helper_line" "$first_use"; fi
    elif [ -n "$mentions" ]; then
      printf 'BAD %s: sources the helper at line %s, but NOT as its first command (unindented, with only comments, "set" and a TEST_SANDBOX_* assignment before it) -- so nothing shows it runs before the rest\n' "$b" "$mentions"
    elif grep -qE '^#[[:space:]]*test-sandbox:[[:space:]]*exempt' "$f"; then
      if [ "${#why}" -ge 12 ]; then exempt=$((exempt + 1)); printf 'EXEMPTION %s: %s\n' "$b" "$why"
      else printf 'BAD %s: carries the exemption marker with NO reason (found: "%s")\n' "$b" "$why"; fi
    else
      printf 'BAD %s: names a lab-capable script or starts a background job (line %s) and neither sources lib/test-sandbox.sh nor carries an exemption marker\n' "$b" "$first_use"
    fi
  done
  printf 'SCANNED %s\nNAMING %s\nFENCED %s\nEXEMPT %s\nBACKGROUNDING %s\nLIFTED %s\n' "$scanned" "$naming" "$fenced" "$exempt" "$backgrounding" "$lifted"
}
field() { printf '%s\n' "$1" | awk -v k="$2" '$1 == k { print $2; exit }'; }

# ---- 1. the instrument is alive: planted controls, BOTH directions ----------------------------
P="$T/planted"; mkdir -p "$P"
one_numbered="$(head -1 "$T/risky")"
plant() { printf '%s\n' "$2" > "$P/test-$1.sh"; }
# shellcheck disable=SC2016  # the planted files are SOURCE TEXT: $R and $0 must stay literal
{
  plant bare        '#!/usr/bin/env bash'$'\n''bash "$R/scripts/'"$one_numbered"'"'
  plant viavar      '#!/usr/bin/env bash'$'\n''S="$R/scripts/'"$_report"'"'$'\n''bash "$S"'
  plant fenced      '#!/usr/bin/env bash'$'\n''. "$(dirname "$0")/lib/test-sandbox.sh"'$'\n''bash "$R/scripts/'"$one_numbered"'"'
  plant late        '#!/usr/bin/env bash'$'\n''bash "$R/scripts/'"$one_numbered"'"'$'\n''. "$(dirname "$0")/lib/test-sandbox.sh"'
  plant commented   '#!/usr/bin/env bash'$'\n''# . "$(dirname "$0")/lib/test-sandbox.sh"'$'\n''bash "$R/scripts/'"$one_numbered"'"'
  plant exempt      '#!/usr/bin/env bash'$'\n''# test-sandbox: exempt — only greps the script text, runs nothing'$'\n''grep -c x "$R/scripts/'"$one_numbered"'"'
  plant noreason    '#!/usr/bin/env bash'$'\n''# test-sandbox: exempt'$'\n''grep -c x "$R/scripts/'"$one_numbered"'"'
  plant onlycomment '#!/usr/bin/env bash'$'\n''# see scripts/'"$one_numbered"' for why'$'\n''echo hi'
  plant unrelated   '#!/usr/bin/env bash'$'\n''bash "$R/scripts/x'"$one_numbered"'"; echo hi'
  plant bgbare      '#!/usr/bin/env bash'$'\n''python3 -m http.server 0 '"$_amp"$'\n''pid=$!'
  plant bgpid       '#!/usr/bin/env bash'$'\n''( sleep 9 ) '"$_amp"' pid=$!; echo "$pid"'
  plant bgfenced    '#!/usr/bin/env bash'$'\n''. "$(dirname "$0")/lib/test-sandbox.sh"'$'\n''sleep 9 '"$_amp"
  plant notbg       '#!/usr/bin/env bash'$'\n''true && echo a'$'\n''echo b >&2'$'\n''echo c 2>&1 | cat'$'\n''cmd |& cat'
  plant lifted      '#!/usr/bin/env bash'$'\n''TEST_SANDBOX_REPO_ROOT=keep'$'\n''. "$(dirname "$0")/lib/test-sandbox.sh"'$'\n''export SKIP_DOTENV=0'$'\n''bash "$R/scripts/'"$one_numbered"'"'
  # THE HELPER LINE IS PRESENT AND DOES NOT RUN FIRST (or at all): each was green before.
  _helper='. "$(dirname "$0")/lib/test-sandbox.sh"'
  _use='bash "$R/scripts/'"$one_numbered"'"'
  plant inif        '#!/usr/bin/env bash'$'\n''if false; then'$'\n''  '"$_helper"$'\n''fi'$'\n'"$_use"
  plant infunc      '#!/usr/bin/env bash'$'\n''never_called() {'$'\n'"$_helper"$'\n''}'$'\n'"$_use"
  plant heredoc     '#!/usr/bin/env bash'$'\n''cat > /dev/null <<EOF'$'\n'"$_helper"$'\n''EOF'$'\n'"$_use"
  plant afterexit   '#!/usr/bin/env bash'$'\n''[ -n "${RUN:-}" ] || exit 0'$'\n'"$_helper"$'\n'"$_use"
  plant trailing    '#!/usr/bin/env bash'$'\n''. "$R/other.sh"   # not lib/test-sandbox.sh, on purpose'$'\n'"$_use"
  plant setheredoc  '#!/usr/bin/env bash'$'\n''set -u; cat > /dev/null <<EOF'$'\n'"$_helper"$'\n''EOF'$'\n'"$_use"
  plant setexit     '#!/usr/bin/env bash'$'\n''set -u; exit 0'$'\n'"$_helper"$'\n'"$_use"
  plant firstok     '#!/usr/bin/env bash'$'\n''# a comment'$'\n''set -uo pipefail'$'\n'$'\n'"$_helper"'   # the fence'$'\n'"$_use"
}
pout="$(scan "$P")"
pbad="$(printf '%s\n' "$pout" | grep -c '^BAD ' || true)"
for want in inif infunc heredoc afterexit trailing setheredoc setexit; do
  if printf '%s\n' "$pout" | grep -q "^BAD test-${want}[.]sh:"; then ok "planted '${want}' is FLAGGED (the helper line is there and is not the first command)"
  else bad "planted '${want}' was NOT flagged -- a helper line that does not run first reads as a fence" "$(printf '%s' "$pout" | tr '\n' '|')"; fi
done
if printf '%s\n' "$pout" | grep -q "^BAD test-firstok[.]sh:"; then bad "planted 'firstok' was flagged -- a false positive (comments, set and a trailing comment are allowed)"
else ok "planted 'firstok' is clean (comment, set, blank line, then the helper with a trailing comment)"; fi
for want in bare viavar late commented noreason bgbare bgpid; do
  if printf '%s\n' "$pout" | grep -q "^BAD test-${want}[.]sh:"; then ok "planted '${want}' is FLAGGED"
  else bad "planted '${want}' was NOT flagged -- the gate is blind to that shape" "$(printf '%s' "$pout" | tr '\n' '|')"; fi
done
for want in fenced exempt onlycomment unrelated bgfenced notbg lifted; do
  if printf '%s\n' "$pout" | grep -q "^BAD test-${want}[.]sh:"; then bad "planted '${want}' was flagged -- a false positive"
  else ok "planted '${want}' is clean"; fi
done
if [ "$pbad" -eq 14 ] && [ "$(field "$pout" SCANNED)" -eq 22 ] && [ "$(field "$pout" NAMING)" -eq 19 ] \
   && [ "$(field "$pout" FENCED)" -eq 4 ] && [ "$(field "$pout" EXEMPT)" -eq 1 ] \
   && [ "$(field "$pout" BACKGROUNDING)" -eq 3 ] && [ "$(field "$pout" LIFTED)" -eq 1 ] \
   && printf '%s\n' "$pout" | grep -q '^LIFT test-lifted[.]sh: REPO_ROOT=kept SKIP_DOTENV=0$'; then
  ok "planted tree reconciles: 22 scanned, 19 in scope (3 backgrounding), 4 fenced (1 with pins lifted), 1 exempt, 14 flagged"
else
  bad "planted tree does not reconcile" "$(printf '%s' "$pout" | tr '\n' '|')"
fi

# ---- 2. the derivation found something to protect -----------------------------------------------
# Floors, each a measured count on 2026-10-09 with headroom below it: 68 numbered scripts, 14
# resolver callers (9 numbered + 5 not). A derivation that silently returns nothing would make the
# real scan below a vacuous green.
if [ "$n_numbered" -ge 40 ]; then ok "derived ${n_numbered} numbered step scripts (floor 40)"
else bad "only ${n_numbered} numbered step scripts found (floor 40)" "the glob stopped matching"; fi
if [ "$((n_consumers + n_num_consumers))" -ge 10 ]; then
  ok "derived $((n_consumers + n_num_consumers)) non-test scripts that call the resolver (${n_num_consumers} numbered, ${n_consumers} not; floor 10)"
else
  bad "only $((n_consumers + n_num_consumers)) resolver callers found (floor 10)" "the resolver was renamed, or the grep is wrong"
fi

# ---- 3. the real tree ---------------------------------------------------------------------------
rout="$(scan "$SCRIPTS")"
r_scanned="$(field "$rout" SCANNED)"; r_naming="$(field "$rout" NAMING)"
r_fenced="$(field "$rout" FENCED)";   r_exempt="$(field "$rout" EXEMPT)"
r_bad="$(printf '%s\n' "$rout" | grep -c '^BAD ' || true)"
printf '\n  checked %s scripts/test-*.sh: %s name a lab-capable script or background a job (%s background) -> %s fenced, %s exempt, %s NEITHER\n' \
  "$r_scanned" "$r_naming" "$(field "$rout" BACKGROUNDING)" "$r_fenced" "$r_exempt" "$r_bad"
printf '%s\n' "$rout" | grep '^EXEMPTION ' | sed 's/^EXEMPTION /    exempt: /' || true
printf '  %s fenced test(s) LIFT a pin for a root they own:\n' "$(field "$rout" LIFTED)"
printf '%s\n' "$rout" | grep '^LIFT ' | sed 's/^LIFT /    /' || true
if [ "$r_scanned" -ge 150 ] && [ "$r_naming" -ge 60 ]; then
  ok "the scan covered ${r_scanned} tests, ${r_naming} of them naming a lab-capable script (floors 150 / 60)"
else
  bad "the scan covered ${r_scanned} tests / ${r_naming} naming (floors 150 / 60)" "a shrunken corpus is how this gate goes vacuous"
fi
if [ "$((r_fenced + r_exempt + r_bad))" -eq "$r_naming" ]; then ok "every naming test is accounted for (${r_fenced} + ${r_exempt} + ${r_bad} = ${r_naming})"
else bad "the counts do not add up: ${r_fenced} + ${r_exempt} + ${r_bad} != ${r_naming}"; fi
if [ "$r_bad" -eq 0 ]; then
  ok "no test names a lab-capable script without the fence or a stated exemption"
else
  bad "${r_bad} test(s) are neither fenced nor exempt" \
      "add, as the first command:  . \"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)/lib/test-sandbox.sh\"   -- or the marker, with the reason"
  printf '%s\n' "$rout" | grep '^BAD ' | sed 's/^BAD /        /'
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
