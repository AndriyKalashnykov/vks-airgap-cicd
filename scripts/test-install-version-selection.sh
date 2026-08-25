#!/usr/bin/env bash
# The install scripts must SELECT operator-supplied files by VERSION, not lexicographically.
#
# WHY THIS FILE EXISTS: newest_versioned_file() had a test; its USE did not. An adversary reverted
# each product change individually and measured that **7 of 11 reverted GREEN** — including all
# three call sites, the harbor pair check, the enum ordering, the _versions type guard and the
# gwapi caveat initialiser. A helper that is tested while its callers are not is the same vacuity
# as no test at all: the defect ships at the call site.
#
# These are STRUCTURAL assertions, and that is a deliberate, stated limit: driving 04/08 end to end
# needs a vCenter session and a Supervisor. They catch exactly the reverts that were measured green
# — a call site going back to `find | sort | tail`, a guard being deleted — and they cannot catch a
# behavioural change that keeps the shape. Comments are stripped before matching, so the ban cannot
# be satisfied (or tripped) by prose describing it.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0
# The files this test makes assertions about. Named explicitly so the denominator is real: an
# earlier version incremented a counter inside code(), which runs in a COMMAND SUBSTITUTION, so the
# increment died in the subshell and the summary printed "scanned 0" beside 11 passes.
# An ARRAY, not a space-separated string: shellcheck's SC2086 fix for the string form is
# `"$FILES"`, which would make `wc -l` report 1 instead of 4 -- a denominator that is quiet and
# wrong. The array is correct AND quiet.
FILES=(04-install-harbor-service.sh 08-install-argocd-service.sh vks-package.sh check-gwapi-istio-alignment.sh)
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

code() { sed 's/^[[:space:]]*#.*//' "$ROOT/scripts/$1"; }

has() {   # has <label> <file> <ere> <why-it-matters>
  if grep -qE "$3" <<< "$(code "$2")"; then ok "$1"; else bad "$1" "$4"; fi
}
hasnt() { # hasnt <label> <file> <ere> <why-it-matters>
  if grep -qE "$3" <<< "$(code "$2")"; then bad "$1" "$4"; else ok "$1"; fi
}

# --- the three call sites (all three reverted GREEN) ---------------------------------------------
has "04: the harbor DEFINITION is picked by version" 04-install-harbor-service.sh \
    'DEF="\$\(newest_versioned_file' \
    "it is back to a lexicographic pick: measured, that installs v2.9.1 over v2.14.3"
has "04: the harbor DATA-VALUES template is picked by version" 04-install-harbor-service.sh \
    'TPL="\$\(newest_versioned_file' \
    "same, for the values template — and it is chosen by an INDEPENDENT search, so a lexicographic pick here can mismatch the definition"
has "08: the argocd DEFINITION is picked by version" 08-install-argocd-service.sh \
    'DEF="\$\(newest_versioned_file' \
    "it is back to a lexicographic pick: measured, that installs 1.2.0 over 1.10.0"
hasnt "04+08: no lexicographic file pick remains" 04-install-harbor-service.sh \
    'find .*\| *sort *\| *tail' "a find|sort|tail pick is back in the harbor installer"
hasnt "08: no lexicographic file pick remains" 08-install-argocd-service.sh \
    'find .*\| *sort *\| *tail' "a find|sort|tail pick is back in the argocd installer"

# --- the harbor def/values PAIR check (reverted GREEN) --------------------------------------------
has "04: the def/values pair is version-checked" 04-install-harbor-service.sh \
    'version MISMATCH between the two operator-supplied Harbor files' \
    "the two files are chosen by INDEPENDENT searches, so a directory with two downloads can pair a 2.14 definition with a 2.9 values file — a mismatch nothing else can see"

# --- the CRD enum ordering (reverted GREEN) -------------------------------------------------------
has "08: the CRD enum is ordered by version" 08-install-argocd-service.sh \
    'enum\[\]\?\] \| map\(select\(type=="string"\)\) \| sort_by\(vkey\)' \
    "bare '| last' takes whatever the CRD lists LAST: measured over three document orders it picks 3.0.9 / 3.0.2 / 3.0.19 — two of three install an OLDER ArgoCD, and this branch runs BEFORE the Carvel path, so it wins"

# --- the _versions type guard (reverted GREEN) ----------------------------------------------------
has "vks-package: the INSTALL path tolerates a non-string version" vks-package.sh \
    'select\(\(type=="string"\) and length>0\)' \
    "a non-string .spec.version makes jq exit 5; pipefail propagates it and set -e kills the script with ZERO diagnostic. _list was hardened four lines away; its twin on the INSTALL path was not"

# --- the gwapi caveat initialiser (reverted GREEN) ------------------------------------------------
has "gwapi: the caveat flag is INITIALISED, not inherited" check-gwapi-istio-alignment.sh \
    '^gwapi_pkg_unchecked=0$' \
    "load_env's set -a exports every uncommented .env line, so an uninitialised bare name can be forced on from the environment and print HELM PATH ONLY under a fully-checked pin"

# --- jq is required where the helper is used ------------------------------------------------------
for f in 04-install-harbor-service.sh 08-install-argocd-service.sh; do
  if grep -qE 'require_cmd .*\bjq\b' <<< "$(code "$f")"; then
    ok "${f%%-*}: jq is required before the version pick"
  else
    bad "${f%%-*}: jq required" "newest_versioned_file needs jq; without the guard a missing jq surfaces as 'no such file in \$SRC_DIR' — the wrong cause, sending the operator to re-download a file that is present"
  fi
done

# Every named file must EXIST and be non-empty, or the assertions above are vacuous against a
# missing file (grep on nothing simply does not match, which for the `hasnt` cases reads as a PASS).
for _f in "${FILES[@]}"; do
  if [ -s "$ROOT/scripts/$_f" ]; then :; else
    bad "corpus present: $_f" "the file is missing or empty — every assertion over it is VACUOUS, and the 'no lexicographic pick remains' cases would PASS on nothing"
  fi
done
printf '\n  asserted over %d file(s); %d passed, %d FAILED\n' "${#FILES[@]}" "$pass" "$fail"
[ "$fail" -eq 0 ]
