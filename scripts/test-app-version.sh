#!/usr/bin/env bash
# Offline unit tests for the DECLARED-VERSION machinery in scripts/lib/apps.sh.
#
# WHY THIS EXISTS: the deployed image tag IS the app's declared version, so every one of these is a
# silent-wrong-value defect rather than a crash.
#   - app_version_cmd must be POSIX/busybox-only: it runs in `alpine/git` (busybox ash) in-cluster,
#     and a GNU-only construct works here and returns EMPTY there — which tags the image with no
#     version at all.
#   - app_set_version_in must move EVERY file that carries the version. MEASURED on the lab: bumping
#     Cargo.toml alone left Cargo.lock stale and `cargo test --offline --locked` REFUSED to run
#     ("cannot update the lock file ... because --locked was passed"), failing the pipeline at the
#     test step with clone/read-version already green.
#   - app_bump_patch must refuse a non-numeric version rather than mangle it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

echo "== app_version_cmd runs under busybox ash (the CLUSTER shell), not just bash =="
if command -v busybox >/dev/null 2>&1; then
  for a in $(app_names); do
    d="${REPO_ROOT}/$(app_src "$a")"
    want="$(app_version "$a")"
    got="$( cd "$d" && busybox sh -c "$(app_version_cmd "$a")" 2>/dev/null || true )"
    check "busybox: $a" "$got" "$want"
    # And through the exact in-cluster chain: base64 -> decode -> sh.
    b64="$(app_version_cmd "$a" | base64 | tr -d '\n')"
    got2="$( cd "$d" && busybox sh -c "$(printf '%s' "$b64" | busybox base64 -d)" 2>/dev/null || true )"
    check "busybox base64 chain: $a" "$got2" "$want"
  done
else
  printf '  SKIP  busybox not installed — the cluster-shell arm did not run\n'
fi

echo "== every app declares a NON-EMPTY version (an empty one makes the build task's write-back die) =="
for a in $(app_names); do
  v="$(app_version "$a")"
  if [ -n "$v" ]; then ok "declares a version: $a ($v)"; else bad "declares a version: $a (EMPTY)"; fi
done

echo "== app_set_version_in moves EVERY file that carries the version, lockfiles included =="
for a in $(app_names); do
  d="${t}/${a}"; rm -rf "$d"; cp -a "${REPO_ROOT}/$(app_src "$a")" "$d"
  if ( app_set_version_in "$a" "$d" 9.8.7 ) >/dev/null 2>&1; then
    check "manifest: $a" "$(app_version_in "$a" "$d")" "9.8.7"
  else
    bad "manifest: $a (writer failed)"
  fi
  # The lockfiles that embed the app's OWN version. Absent is fine; STALE is the defect.
  if [ -f "${d}/Cargo.lock" ]; then
    got="$(grep -A1 "^name = \"${a}\"\$" "${d}/Cargo.lock" | grep -m1 '^version = ' | sed 's/.*"\(.*\)"/\1/')"
    check "Cargo.lock: $a" "$got" "9.8.7"
  fi
  if [ -f "${d}/package-lock.json" ]; then
    check "package-lock.json: $a"          "$(jq -r '.version' "${d}/package-lock.json")" "9.8.7"
    check "package-lock.json packages: $a" "$(jq -r '.packages[""].version // "9.8.7"' "${d}/package-lock.json")" "9.8.7"
  fi
done

echo "== app_set_version_in READS BACK: a writer whose pattern stops matching must DIE, not no-op =="
# Derive the java app from the registry — a shared file must never name one (check-app-hardcodes).
# NOT `x="$(... while ... done)"`: an `A && B` loop body returns non-zero when nothing matches, and
# under `set -e` that kills the assignment. Plain loop, plain variable.
JAVA_APP=""
for _a in $(app_names); do
  if [ "$(app_lang "$_a")" = java ]; then JAVA_APP="$_a"; break; fi
done
if [ -z "$JAVA_APP" ]; then
  printf '  SKIP  no java app in the registry — the read-back RED did not run\n'
else
  d="${t}/redproof"; rm -rf "$d"; cp -a "${REPO_ROOT}/$(app_src "$JAVA_APP")" "$d"
  was="$(app_version_in "$JAVA_APP" "$d")"
  # A <packaging> element between <artifactId> and <version> is legal and common, and it defeats the
  # adjacency the perl writer requires — so the write becomes a silent no-op that exits 0.
  N="$JAVA_APP" perl -0pi -e 's{(<artifactId>\Q$ENV{N}\E</artifactId>)(\s*<version>)}{$1<packaging>jar</packaging>$2}s' "${d}/pom.xml"
  if ( app_set_version_in "$JAVA_APP" "$d" 7.7.7 ) >/dev/null 2>&1; then
    bad "RED: a no-op write must fail (it exited 0)"
  else
    check "RED: a no-op write fails AND leaves the file alone" "$(app_version_in "$JAVA_APP" "$d")" "$was"
  fi
fi

echo "== app_bump_patch =="
check "0.1.0"  "$(app_bump_patch 0.1.0)"  "0.1.1"
check "0.1.9"  "$(app_bump_patch 0.1.9)"  "0.1.10"
check "1.0"    "$(app_bump_patch 1.0)"    "1.0.1"
check "empty"  "$(app_bump_patch '')"     "0.0.1"
# 4-component: all digits and dots, so a `*[!0-9.]*`-only guard PASSED it and `cut -f3` silently
# dropped the `.4` — writing 1.2.4 over the operator's 1.2.3.4, with the read-back agreeing.
# `<Version>1.2.3.4</Version>` is idiomatic .NET.
for bad_v in 0.1.0-rc8 0.2.0-SNAPSHOT 1.0.0+build 1.2.3.4 1..2 .1.2 1.2.; do
  if ( app_bump_patch "$bad_v" ) >/dev/null 2>&1; then
    bad "refuses '$bad_v' (it returned a value — 0.1.0-rc8 used to be a fatal \$((08+1)), and -SNAPSHOT was silently destroyed)"
  else
    ok "refuses '$bad_v'"
  fi
done

printf '\ntest-app-version: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
