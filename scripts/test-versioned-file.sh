#!/usr/bin/env bash
# newest_versioned_file() must pick the NEWEST operator-supplied file by VERSION, not lexically.
#
# WHY: `find … | sort | tail -1` was used at THREE sites to choose entitled, operator-downloaded
# service definitions. MEASURED over the exact filenames docs/scenario-1.md tells the operator to
# download: it picks argocd `1.2.0` over `1.10.0`, and harbor `v2.9.1` over `v2.14.3` -- i.e. the
# installer silently installs the OLDER service the moment a second download sits beside the first.
# Dormant while exactly one version is present, which is why nothing caught it.
#
# The harbor pair matters twice: its definition and its data-values template are chosen by two
# INDEPENDENT searches, so a directory holding two downloads can pair a 2.14 definition with a 2.9
# values file -- a mismatch that surfaces much later as an obscure reconcile error.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0; D=""
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
cleanup(){ [ -n "$D" ] && rm -rf "$D"; }
trap cleanup EXIT

# shellcheck source=/dev/null
. "$ROOT/scripts/lib/os.sh" >/dev/null 2>&1

fixture() { cleanup; D="$(mktemp -d)"; local f; for f in "$@"; do : > "$D/$f"; done; }
pick()    { basename "$(newest_versioned_file "$D" "$1" || echo NONE)"; }
lexical() { basename "$(find "$D" -maxdepth 1 -name "$1" 2>/dev/null | sort | tail -1)"; }

want() { # want <label> <glob> <expected>
  local got; got="$(pick "$2")"
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1" "want '$3', got '$got'"; fi
}

fixture supervisor-service-argocd-legacy-1.2.0.yml supervisor-service-argocd-legacy-1.10.0.yml
want "argocd: 1.10.0 beats 1.2.0" 'supervisor-service-argocd-legacy-*.yml' supervisor-service-argocd-legacy-1.10.0.yml
if [ "$(lexical 'supervisor-service-argocd-legacy-*.yml')" = supervisor-service-argocd-legacy-1.2.0.yml ]; then
  ok "control: the OLD find|sort|tail really does pick 1.2.0 here"
else
  bad "control: lexical picks wrong" "it agreed — this fixture no longer discriminates"
fi

fixture supervisor-service-harbor-legacy-v2.9.1.yml supervisor-service-harbor-legacy-v2.14.3.yml
want "harbor: v2.14.3 beats v2.9.1 (a 'v' prefix does not break it)" 'supervisor-service-harbor-legacy-*.yml' supervisor-service-harbor-legacy-v2.14.3.yml

fixture supervisor-service-argocd-legacy-1.10.0.yml
want "a single file is returned unchanged" 'supervisor-service-argocd-legacy-*.yml' supervisor-service-argocd-legacy-1.10.0.yml

fixture unrelated.txt
got="$(newest_versioned_file "$D" 'supervisor-service-argocd-legacy-*.yml')"; rc=$?
if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
  ok "no match -> non-zero AND empty (the caller's own die carries the actionable message)"
else
  bad "no match" "rc=$rc out='$got' — a non-empty return here makes the caller's [ -n ] guard pass on nothing"
fi

# A filename with no digits at all must not crash or win over a real version.
fixture supervisor-service-argocd-legacy-latest.yml supervisor-service-argocd-legacy-1.10.0.yml
want "a version-less filename does not outrank a real version" 'supervisor-service-argocd-legacy-*.yml' supervisor-service-argocd-legacy-1.10.0.yml

# versioned_file_version powers the harbor def/values pair check.
fixture x
if [ "$(versioned_file_version /a/b/supervisor-service-harbor-legacy-v2.14.3.yml)" = 2.14.3 ]; then
  ok "versioned_file_version extracts the version from a path"
else
  bad "version extraction" "got '$(versioned_file_version /a/b/supervisor-service-harbor-legacy-v2.14.3.yml)'"
fi
if [ -z "$(versioned_file_version /a/b/no-digits-here.yml)" ]; then
  ok "...and is empty when there is no version (so the pair check fires rather than comparing junk)"
else
  bad "no-version extraction" "got '$(versioned_file_version /a/b/no-digits-here.yml)'"
fi

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
