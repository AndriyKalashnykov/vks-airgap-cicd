#!/usr/bin/env bash
# test-registry-fail-open.sh — the registry-driven loops must FAIL CLOSED on a broken registry.
#
# WHY: three shapes in this repo swallow a `die` from app_names/app_toolchain, so the loop body runs
# ZERO times and the caller reports SUCCESS:
#   1. `for x in $(fn)`            — a dying $( ) in ARGUMENT position does NOT trip `set -e`
#   2. `done <<EOF\n$(fn)\nEOF`    — the heredoc substitution is swallowed the same way
#   3. a counter with no FLOOR     — `checked=0` reads as "nothing to check", not "I went blind"
#
# MEASURED before the fixes: `check-app-toolchains` printed FATAL, then OK, then exited 0 on exactly
# the input it exists to catch; `validate.sh` reported `validate: OK` at rc=0 having validated zero
# deploy dirs and zero Tekton test tasks. PR #944 fixed shapes 1 and 2 in five loops and floored
# for_each_app, but shipped NO test — so reverting any of it went green. This is that test.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
: > "$T/zero.tsv"
printf '# only a comment\n' > "$T/comment.tsv"
printf '# name\tlang\tsrc\tdeploy\n' > "$T/unhandled.tsv"
grep -vE '^\s*#' "$REPO/apps/registry.tsv" >> "$T/unhandled.tsv"
printf 'zzwebapp\tzzlang\tapps/zz/zzwebapp\tdeploy/zzwebapp\n' >> "$T/unhandled.tsv"

# rc is captured on its OWN line every time. Putting a $( ) between the command and $? reads the
# SUBSTITUTION's status — measured: that exact mistake made this suite report rc=0 for a gate that
# was correctly exiting 1.
run_rc() { ( cd "$REPO" && APPS_REGISTRY="$1" bash "$2" ) >/dev/null 2>&1; printf '%s' "$?"; }

for reg in zero comment; do
  rc="$(run_rc "$T/$reg.tsv" scripts/validate.sh)"
  if [ "$rc" != 0 ]; then ok "validate.sh fails CLOSED on a $reg registry (rc=$rc)"
  else bad "validate.sh returned 0 on a $reg registry" "both arms checked nothing and it said 'validate: OK'"; fi
done
rc="$(run_rc /nonexistent scripts/validate.sh)"
if [ "$rc" != 0 ]; then ok "validate.sh fails CLOSED on a MISSING registry (rc=$rc)"
else bad "validate.sh returned 0 on a missing registry"; fi

rc="$(run_rc "$T/unhandled.tsv" scripts/check-app-toolchains.sh)"
if [ "$rc" != 0 ]; then ok "check-app-toolchains fails CLOSED on an unhandled lang (rc=$rc)"
else bad "check-app-toolchains returned 0 on an unhandled lang" "it printed FATAL, then OK, then exited 0"; fi

# for_each_app's floor, exercised directly — all eight callers inherit it.
for reg in zero comment; do
  out="$( cd "$REPO" && APPS_REGISTRY="$T/$reg.tsv" bash -c '
    . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/apps.sh
    noop(){ :; }; for_each_app noop; echo SURVIVED' 2>&1 )"
  case "$out" in
    *SURVIVED*) bad "for_each_app iterated 0 apps and RETURNED on a $reg registry" "every caller would then print its success line" ;;
    *"iterated 0 app"*) ok "for_each_app floors a $reg registry, and SAYS SO" ;;
    *) bad "for_each_app died on a $reg registry without naming the count" "a silent non-zero is not a usable signal: [$out]" ;;
  esac
done

# POSITIVE CONTROL — the healthy registry must still pass, or the assertions above prove nothing.
rc="$(run_rc "$REPO/apps/registry.tsv" scripts/validate.sh)"
if [ "$rc" = 0 ]; then ok "positive control: the REAL registry still passes validate.sh (rc=0)"
else bad "the real registry now FAILS validate.sh (rc=$rc)" "the floors are too strict"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
