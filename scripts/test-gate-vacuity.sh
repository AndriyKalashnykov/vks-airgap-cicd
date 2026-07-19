#!/usr/bin/env bash
# test-gate-vacuity.sh — a gate that judged NOTHING must not report OK.
#
# WHY THIS EXISTS (B39/B49):
#   A gate can be green because it is satisfied, or green because it never looked. Those are
#   indistinguishable from the outside, and this repo has now shipped BOTH failures:
#     * check-doc-novels and check-doc-robot-quoting each reported `OK — scanned N` with rc=0 over a
#       corpus of EMPTY files. Their zero-guards counted FILES OPENED, which stayed healthy, while the
#       ITEM count that carries the verdict was zero. (Fixed; both are cases below.)
#   The obvious fix — a meta-gate that statically asserts "every check-*.sh prints a denominator and
#   dies on zero" — was BUILT AND MEASURED AT 67% ACCURACY (wrong about 7 of 21 gates, in both
#   directions) and is REFUTED. It cannot see the distinction that matters, because "is the guard on
#   the ITEM count or the FILE count" is semantic. So this harness does not read the gates. It STARVES
#   them and looks at what they do.
#
# THE METHOD: empty a gate's declared corpus in a throwaway `git archive` copy, run the gate there,
# and require rc != 0. It cannot be satisfied by `echo "checked 1"`, and it needs no model of how the
# gate is written.
#
# THE RESIDUAL, STATED NOT HIDDEN: the per-gate corpus declaration below is an ENUMERATED LIST, and
# enumerated lists rot. A WRONG declaration makes a starvation vacuous — the same failure class this
# harness exists to catch, one level up. Three mitigations, all partial: the self-check below proves
# the harness can still tell blind from healthy; the coverage denominator is PRINTED and the
# UNDECLARED gates are NAMED, so a newly-added gate surfaces as a named gap rather than a silently
# moved number; and the declared count is DERIVED from the calls, not hand-typed beside them.
#
# THE THREE VERDICTS, and why `rc != 0` alone is not one of them. A gate can die under starvation for
# a reason that has nothing to do with its denominator — a missing interpreter (rc 127), an anchor
# file gone, a `set -e` trip on an empty read. Accepting any non-zero would then report `ok` over a
# gate that never judged a thing, which is this harness's own failure mode. A gate that JUDGED and
# REFUSED always says why; a gate that merely DIED is usually silent. So:
#     rc == 0                          -> VACUOUS      (or an INCOMPLETE declaration — see below)
#     rc in {126,127} or NO output     -> INCONCLUSIVE (not a proof of anything; fix or drop the case)
#     rc != 0 with output              -> ok
# This is deliberately NOT "assert the message mentions emptiness": the gates' emptiness messages
# share no common token, so that would be a per-gate list of expected strings — the rot class again.
#
# WHY A FALSE GREEN HERE READS AS "VACUOUS" AND MAY BE A LIE IN THE OTHER DIRECTION. If a declaration
# MISSES part of a gate's corpus, the gate legitimately still has something to judge, exits 0, and
# this harness accuses it of being vacuous. That FALSE RED is the more dangerous error, because the
# cheapest way to silence it is to weaken the accused gate. The failure message therefore names both
# hypotheses and puts the declaration first. (Lived through on check-doc-robot-quoting, whose corpus
# also includes .env.example; and again on check-vks-terminology — see NOT STARVABLE below.)
#
# BLAST RADIUS — a pathspec must never empty the gate's own dependencies. Every gate here sources
# scripts/lib/os.sh, so a wildcard over scripts/ empties that lib (and often the gate itself); bash
# then runs an empty file and exits 0, which this harness would report as VACUOUS when in truth the
# gate never ran. So: no pathspec may use a WILDCARD over scripts/ or name anything under
# scripts/lib/. Naming a SINGLE non-lib script as a gate's ground truth is fine and sometimes the
# only option (see check-namespace-labelled below). Where a gate's primary corpus IS scripts/, starve
# its ground truth instead — apps/registry.tsv, .env.example, images/images.txt.
#
# NOT STARVABLE, and why they are absent rather than forgotten:
#   check-vks-terminology     — its corpus is EVERY tracked text file, which necessarily includes its
#                               own lib. Starving less than all of it leaves a real corpus and yields
#                               a false RED; starving all of it hits the blast radius above. Its
#                               zero-guard is asserted in the gate itself instead.
#   check-gwapi-istio-alignment — its corpus is an upstream go.mod fetched over the network; it
#                               loud-SKIPs green when offline by design. Starving the repo does
#                               nothing to it.
#   check-doc-command-count   — CONDITIONAL BY DESIGN: it cross-checks any "N command(s)" prose
#                               claim against the commands beside it, and a docs set that makes NO
#                               such claim is a legitimate state with nothing to contradict. Its
#                               real coverage today is ONE intentional line (README.md); a second
#                               apparent hit is prose warning you not to run something as one
#                               command, which passes by coincidence. Guarding its claim count would
#                               convert a contradiction-detector into a permanent prose MANDATE —
#                               rewording that one README cell would redden CI, and the only way to
#                               satisfy the gate would be to re-introduce an "N commands" phrase.
#                               Same shape as check-java-alignment's "no java app — nothing to
#                               check": the emptiness is honest, so a die would be a FALSE BLOCK.
#
# shellcheck shell=bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0; ran=0
ok()  { printf 'ok    %s\n' "$1"; ran=$((ran + 1)); }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# A pristine throwaway checkout, re-inited as a git repo because several gates drive off `git ls-files`.
# `git archive HEAD` for the corpus, then the WORKING TREE's scripts/ overlaid on top. The overlay is
# load-bearing and was missing in the first draft: without it this harness tests the COMMITTED gates,
# so a fix you have not committed yet is invisible and the harness reports your just-fixed gate as
# still vacuous. (It did exactly that, quoting the pre-fix message — the same "measuring the wrong
# artifact" class this file exists to catch.)
# EVERY STEP IS CHECKED, and the result is asserted. An unguarded fresh() that half-populates the
# sandbox does not fail here — it fails LATER, as a gate going RED on its supposedly-pristine
# baseline, which reads as "that gate is broken" and sends you to the wrong file entirely. It cost a
# CI-only failure that reproduced nowhere locally (2026-07-19). The setup of a test harness is part
# of the instrument: if it can fail, it must say so itself.
_setup_die() { echo "test-gate-vacuity: SANDBOX SETUP FAILED — $1" >&2; echo "  This is the HARNESS, not the gate under test. Do not go looking at the gate." >&2; exit 1; }
fresh() {
  rm -rf "${SB:?}/repo"; mkdir -p "$SB/repo" || _setup_die "cannot create the sandbox dir"
  git archive HEAD | tar -x -C "$SB/repo" || _setup_die "git archive HEAD | tar failed"
  cp -a "${REPO_ROOT}/scripts/." "$SB/repo/scripts/" || _setup_die "could not overlay the working tree's scripts/"
  ( cd "$SB/repo" && git init -q . && git add -A >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -qm starve >/dev/null 2>&1 ) \
    || _setup_die "could not re-init the sandbox as a git repo (several gates drive off git ls-files)"
  # Assert the sandbox actually HOLDS the tree. Cheap, and the only thing that distinguishes a
  # half-copied sandbox from a genuinely failing gate.
  [ -s "$SB/repo/scripts/lib/os.sh" ]      || _setup_die "scripts/lib/os.sh is missing or empty in the sandbox"
  [ -s "$SB/repo/scripts/49-psa-check.sh" ] || _setup_die "scripts/49-psa-check.sh is missing or empty in the sandbox"
  _n="$(cd "$SB/repo" && git ls-files | grep -c . || true)"
  [ "${_n:-0}" -gt 50 ] || _setup_die "the sandbox tracks only ${_n:-0} file(s) — the archive/overlay did not populate it"
}

# starve <pathspec...> — empty every tracked file matching, leaving it TRACKED. Emptying rather than
# deleting is deliberate: deletion is the easy case (most gates notice a missing file), while an empty
# file keeps every file-count healthy and is exactly the state that fooled two gates.
starve() { ( cd "$SB/repo" && git ls-files "$@" | while read -r f; do : > "$f"; done ); }

# Every gate a case is DECLARED for, recorded at the top of assert_starved so the coverage figure
# counts ATTEMPTS. A failing case must still count as declared, or the number drops precisely when a
# gate breaks — the moment you most want it to be honest. `ran` stays separate; it counts passes.
DECLARED_GATES=()

# assert_starved <gate> <label> <pathspec...>
assert_starved() {
  local gate="$1" label="$2"; shift 2
  DECLARED_GATES+=("$gate")          # BEFORE any early return
  local base_rc st_rc sz
  fresh
  # Exit status read DIRECTLY off each run onto its own line, never via a later `$?` — the house
  # rule, and the reason is that `$?` silently becomes the status of whatever ran most recently.
  ( cd "$SB/repo" && bash "scripts/${gate}" ) >"$SB/base.log" 2>&1
  base_rc=$?
  if [ "$base_rc" -ne 0 ]; then
    bad "${label} — the gate is RED on its UNSTARVED baseline, so this case proves nothing about vacuity. Suspect the SANDBOX before the gate: fresh() asserts its own setup above, but a gate reading state outside \$REPO_ROOT (an exported var, an absolute path) would also land here."
    sed 's/^/        /' "$SB/base.log" >&2
    return
  fi
  starve "$@"
  ( cd "$SB/repo" && bash "scripts/${gate}" ) >"$SB/starved.log" 2>&1
  st_rc=$?
  sz=$(wc -c < "$SB/starved.log" | tr -d ' ')
  if [ "$st_rc" -eq 0 ]; then
    # Declaration first: a false RED here is likelier — and costlier — than a real vacuity.
    bad "${label} — GREEN on the declared-empty corpus. EITHER this declaration is INCOMPLETE (check
        for a second corpus component BEFORE touching the gate) OR the gate is genuinely VACUOUS. It reported:"
    tail -2 "$SB/starved.log" | sed 's/^/        /' >&2
    return
  fi
  if [ "$st_rc" -eq 126 ] || [ "$st_rc" -eq 127 ] || [ "$sz" -eq 0 ]; then
    bad "${label} — INCONCLUSIVE: died SILENTLY (rc=${st_rc}, ${sz} bytes of output). A gate that
        judged and refused says why; this one just died, so the case proves nothing about the
        denominator. Fix the gate's error path, or drop the case rather than bank a false pass."
    return
  fi
  ok "${label}"
}

# --- THE HARNESS'S OWN KNOWN ANSWER --------------------------------------------------------------
# Non-circular by construction: two fixtures whose verdict is known WITHOUT reference to any real
# gate. If the harness cannot tell these apart it is broken, and every result below is worthless.
# (Contrast B37, where the fixture had to encode my own model of the defect — that is what made it
# circular and unbuildable.)
selfcheck() {
  fresh
  cat > "$SB/repo/scripts/_vac-blind.sh" <<'BLIND'
#!/usr/bin/env bash
# BLIND ON PURPOSE: guards the FILE count, which stays healthy when the files are empty.
set -uo pipefail
n=$(git ls-files '*.md' | wc -l)
[ "$n" -gt 0 ] || { echo "scanned 0"; exit 1; }
echo "OK — scanned $n doc(s)"
BLIND
  cat > "$SB/repo/scripts/_vac-good.sh" <<'GOOD'
#!/usr/bin/env bash
# HEALTHY ON PURPOSE: guards the ITEM count (bytes actually read).
set -uo pipefail
items=0
while read -r f; do items=$(( items + $(wc -c < "$f") )); done < <(git ls-files '*.md')
[ "$items" -gt 0 ] || { echo "examined 0 items"; exit 1; }
echo "OK — examined $items byte(s)"
GOOD
  chmod +x "$SB/repo/scripts/_vac-blind.sh" "$SB/repo/scripts/_vac-good.sh"
  starve '*.md'
  ( cd "$SB/repo" && bash scripts/_vac-blind.sh ) >/dev/null 2>&1
  local blind_rc=$?
  ( cd "$SB/repo" && bash scripts/_vac-good.sh ) >/dev/null 2>&1
  local good_rc=$?
  if [ "$blind_rc" -eq 0 ] && [ "$good_rc" -ne 0 ]; then
    ok "SELF-CHECK: the harness distinguishes a BLIND gate (green on empty) from a HEALTHY one (red)"
  else
    bad "SELF-CHECK BROKEN — blind_rc=${blind_rc} (want 0), good_rc=${good_rc} (want non-zero). Every result below is meaningless until this passes."
  fi
}

selfcheck

# --- DECLARED CORPORA ------------------------------------------------------------------------------
# Only gates whose corpus is confidently known are listed. The coverage denominator is printed at the
# end so the REST are visible as an admitted gap rather than an implied pass.
assert_starved check-doc-novels.sh        "check-doc-novels dies on an empty doc corpus"        '*.md'
assert_starved check-doc-robot-quoting.sh "check-doc-robot-quoting dies on an empty corpus"     '*.md' '.env.example'
assert_starved check-vks-provenance.sh    "check-vks-provenance dies with no fact rows"         'docs/vks-services/*.md'
# NOTE the pathspec here is `.env.example` ONLY, not `scripts/*.sh`. Starving the scripts would empty
# check-psa-defaults.sh ITSELF — bash then runs an empty file and exits 0, which this harness would
# report as "VACUOUS" when in truth the gate never ran. A starvation whose blast radius includes the
# gate under test measures nothing; when a gate's corpus overlaps its own source, starve the OTHER side.
assert_starved check-psa-defaults.sh      "check-psa-defaults dies with nothing documented"     '.env.example'

# These four were MEASURED healthy before being declared (2026-07-19): each already guards its ITEM
# count and goes RED with a named diagnostic under starvation. They are pure regression protection —
# they pin behaviour that is correct today so it cannot silently rot into the class above.
assert_starved check-pod-inject-label.sh  "check-pod-inject-label dies with no workloads parsed"  'k8s/*.yaml' 'k8s/**/*.yaml' 'deploy/**/*.yaml'
assert_starved check-readme-scenarios.sh  "check-readme-scenarios dies on empty scenario docs"    'docs/*.md'
assert_starved check-doc-target-coverage.sh "check-doc-target-coverage dies with no Makefile targets" 'Makefile'
assert_starved check-env-coverage.sh      "check-env-coverage dies with nothing documented"       '.env.example'
# Ground truth is a SINGLE named script, not a wildcard over scripts/ — permitted by the blast-radius
# rule in the header (it cannot reach scripts/lib/ or this gate's own source).
assert_starved check-namespace-labelled.sh "check-namespace-labelled dies with no NS_SPEC inventory" 'scripts/49-psa-check.sh'

# These seven were MEASURED VACUOUS (2026-07-19) — each reported OK over an empty corpus. The
# declarations land in their OWN commit, BEFORE the fixes, so the harness records seven real
# `VACUOUS` lines in CI. A case that is `ok` from birth is indistinguishable from one that was
# never blind; this ordering is what makes the demonstrated RED an observation instead of a claim.
assert_starved check-doc-make-targets.sh  "check-doc-make-targets dies with no commands examined"  'README.md' 'docs/*.md'
assert_starved check-prose-secrets.sh     "check-prose-secrets dies with no lines examined"        '*.md'
assert_starved check-how-provenance.sh    "check-how-provenance dies with no '# how:' lines"       '.env.example'
assert_starved check-app-hardcodes.sh     "check-app-hardcodes dies with no (file,app) pairs"      'apps/registry.tsv'
assert_starved check-app-toolchains.sh    "check-app-toolchains dies with no toolchains checked"   'apps/registry.tsv'
assert_starved check-pull-secret-alignment.sh "check-pull-secret-alignment dies with no apps"      'apps/registry.tsv'
assert_starved check-env-clobber.sh       "check-env-clobber dies with nothing uncommented"        '.env.example'

# check-java-alignment: DECLARABLE only since its two zero-states were separated (a registry with
# apps but no java app is honest emptiness -> exit 0; a registry yielding ZERO apps is blindness ->
# die). Before that split it died SILENTLY on an empty registry (rc=1, zero output) and this case
# would have scored INCONCLUSIVE rather than ok.
assert_starved check-java-alignment.sh    "check-java-alignment dies with no apps in the registry"  'apps/registry.tsv'
# check-image-alignment: `k8s/` NOT 'k8s/**/*.yaml' — the arm greps k8s/ RECURSIVELY WITH NO
# EXTENSION FILTER, so an extension glob is complete only until someone adds a .yml/.json carrying a
# Harbor ref, at which point the declaration silently goes short and the harness emits a FALSE RED
# against a healthy gate. A bare directory pathspec is extension-proof by construction (measured:
# identical 19 files today).
#
# ⚠️ THIS DECLARATION COVERS ONE OF FIVE ARMS. Arm 1 (k8s/ + gitea refs) is what `k8s/` starves.
# Arm 2 (.env.example tag vars) got its own guard in the same change but is not starved here. Arms
# 4 and 5 route through check_pinned(), whose `[ -n "$3" ] || return 0` returns SUCCESS when the
# expected value is absent — vacuous by construction, source-read, not yet addressed. Do not read
# this line as "check-image-alignment is covered".
#
# The pathspec MUST also name 40-install-gitea.sh. Arm 1's feed is `{ grep k8s/ ; grep gitea-script ; }`
# and the `|| true` fix landed in the SAME change: before it, `set -e` killed the group when the k8s
# grep found nothing, so the gitea grep never ran and `k8s/` alone starved the arm to zero. Fixing
# that correctly means the gitea ref now SURVIVES a k8s-only starvation, the guard does not fire,
# and the harness emits a FALSE RED against a healthy gate. Observed exactly that, once, here.
# A single NAMED non-lib script is permitted by the blast-radius rule (cf. 49-psa-check.sh above).
assert_starved check-image-alignment.sh   "check-image-alignment dies with no k8s image refs"      'k8s/' 'scripts/40-install-gitea.sh'
# check-ns-chokepoint: starving k8s/ removes the one declared ArgoCD syncOption hit, so its
# both-directions reconciliation fires ("allowed for 1 but has NONE"). Its scripts/ corpus is NOT
# starvable — it sources lib/os.sh, the blast-radius rule — so this covers the k8s side only, which
# is the honest scope rather than an implied whole-gate proof.
assert_starved check-ns-chokepoint.sh     "check-ns-chokepoint dies when a declared hit vanishes"  'k8s/'

# Coverage, DERIVED — never a literal hand-typed beside the calls, which is a two-numbers-that-must-
# agree problem with nothing asserting it. Both figures come from the SAME listing, so the count and
# the named list cannot disagree; a harness whose own two numbers drift is what this exists to catch.
ALL_GATES=$(find "${REPO_ROOT}/scripts" -maxdepth 1 -name 'check-*.sh' | sed 's#.*/##' | sort)
TOTAL=$(printf '%s\n' "$ALL_GATES" | grep -c .)
DECLARED=${#DECLARED_GATES[@]}
UNDECLARED=""
while read -r g; do
  [ -n "$g" ] || continue
  case " ${DECLARED_GATES[*]} " in *" ${g} "*) ;; *) UNDECLARED="${UNDECLARED}${UNDECLARED:+ }${g}" ;; esac
done <<EOF
$ALL_GATES
EOF

# Fail-check FIRST: `ran` counts only PASSING cases, so if everything failed, ran==0 AND fail==1 —
# checking a "nothing ran" skip first would exit 0 on a run that printed nothing but FAIL.
if [ "$fail" -ne 0 ]; then echo "test-gate-vacuity: FAILED" >&2; exit 1; fi
[ "$ran" -gt 0 ] || { echo "test-gate-vacuity: no case ran — the harness is broken, not the gates" >&2; exit 1; }
echo "test-gate-vacuity: OK (${ran} case(s); starvation declared for ${DECLARED} of ${TOTAL} check-*.sh SCRIPTS)"
echo "  This is NOT a fraction of all gates: static-check/docs-lint/sec also run five inline Makefile"
echo "  recipes (check-env, check-toolchain-alignment, check-secrets-untracked, gitleaks, trivy-config)"
echo "  plus lint.sh, validate.sh, trivy-fs.sh and diagrams-check — none of which are counted here."
if [ -n "$UNDECLARED" ]; then
  echo "  UNDECLARED — UNAUDITED for vacuity, NOT proven healthy:"
  printf '%s\n' "$UNDECLARED" | tr ' ' '\n' | sed 's/^/    /'
fi
