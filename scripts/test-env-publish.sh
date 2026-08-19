#!/usr/bin/env bash
# RED-proof for env_publish / state_unset (B132).
#
# THE DEFECT, measured 2026-08-17 by matrix row 1 on a live lab, scenario-1 §9:
# 04-install-harbor-service.sh:144-145 publishes HARBOR_USERNAME/HARBOR_PASSWORD to the state
# overlay. Step 9 then wrote the ROBOT identity to .env with set_env_var. load_env sources the
# overlay LAST, so the robot identity could never take effect; the run died on assert_env_effective
# with rc=1 having already created the robot in Harbor.
#
# CASE 3 IS THE ONE THAT MATTERS. Clearing only the username yields .env=robot/robotsecret against an
# overlay still holding the ADMIN password -> effective USER=robot PASS=adminpw, a 401 that reads
# like a wrong password. A partial fix is worse than none, so it is pinned.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

# A Harbor robot name contains a LITERAL dollar (robot$<name>), so this is single-quoted on purpose
# and must never be expanded. Naming it once beats a shellcheck-disable on every comparison.
# shellcheck disable=SC2016  # the '$' is LITERAL by design — a Harbor robot login is robot$<name>
ROBOT='robot$vks-cicd'

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/scripts/lib"
cp "$ROOT"/scripts/lib/os.sh "$ROOT"/scripts/lib/state.sh "$TD/scripts/lib/"
cp "$ROOT/.env.example" "$TD/.env.example"

# The effective value, read the way every consumer reads it: through load_env.
eff() { ( cd "$TD" && REPO_ROOT="$TD" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  VKS_STATE_FILE="'"$TD"'/.env.state" load_env >/dev/null 2>&1
  printf "%s|%s" "${HARBOR_USERNAME:-}" "${HARBOR_PASSWORD:-}"' ) ; }

setup() {  # overlay holds admin (what step 4 publishes); .env is empty
  : > "$TD/.env"
  ( umask 077; printf 'ARGOCD_KUBECONFIG=/x\nHARBOR_USERNAME=admin\nHARBOR_PASSWORD=adminpw\n' > "$TD/.env.state" )
}

# 1. THE DEFECT REPRODUCES with the OLD mechanism (bare set_env_var). If this ever goes green, the
#    test is measuring nothing — the overlay must win.
setup
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  set_env_var HARBOR_USERNAME "robot\$vks-cicd" "'"$TD"'/.env"
  set_env_var HARBOR_PASSWORD "robotsecret"     "'"$TD"'/.env"' ) >/dev/null 2>&1
got="$(eff)"
if [ "$got" = 'admin|adminpw' ]; then ok "OLD set_env_var: overlay still wins -> [$got] (the defect, reproduced)"
else bad "expected the overlay to win with the old mechanism; got [$got]"; fi

# 2. env_publish on BOTH keys -> the robot identity actually takes effect.
setup
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish HARBOR_USERNAME "robot\$vks-cicd" "the robot identity"
  env_publish HARBOR_PASSWORD "robotsecret"     "the robot secret"' ) >/dev/null 2>&1
got="$(eff)"
if [ "$got" = "${ROBOT}|robotsecret" ]; then ok "env_publish BOTH keys -> [$got]"
else bad "env_publish both: expected robot/robotsecret, got [$got]"; fi

# 3. THE MISMATCHED PAIR. Publish only the username; the password must NOT silently stay admin's.
setup
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish HARBOR_USERNAME "robot\$vks-cicd" "half a fix"' ) >/dev/null 2>&1
got="$(eff)"
if [ "$got" = "${ROBOT}|adminpw" ]; then
  ok "PARTIAL fix produces the mismatched pair [$got] — pinned, so nobody ships half of this"
else bad "expected the mismatched pair from a partial fix; got [$got]"; fi

# 3b. 🔴 THE 2-KEY OVERLAY — the REAL-LAB shape, and the one the fixture above structurally cannot
#     reach. `04-install-harbor-service.sh:144-145` publishes EXACTLY the pair; there is no third key.
#     Publishing the pair one key at a time therefore reduces the overlay to ONE line, and then to
#     ZERO — and `grep -v` EXITS 1 when it emits nothing, so the second state_unset silently fails.
#     Cases 2 and 3 are green today only because setup() seeds a third key (ARGOCD_KUBECONFIG=/x,
#     added for case 5), which guarantees grep -v always has output. That is the "a gate's RED-proof
#     checks a SUBSET" trap: the fixture is the one shape that hides the defect.
setup2() { : > "$TD/.env"; ( umask 077; printf 'HARBOR_USERNAME=admin\nHARBOR_PASSWORD=adminpw\n' > "$TD/.env.state" ); }
setup2
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish HARBOR_USERNAME "robot\$vks-cicd" "the robot identity"
  env_publish HARBOR_PASSWORD "robotsecret"     "the robot secret"' ) >/dev/null 2>&1 || true
#   ^^^^^^^ `|| true` is REQUIRED, and it is itself a finding: a failing env_publish returns non-zero,
#   so under this file's `set -e` the abort would kill the SUITE before the assertion below could run
#   — the test would die instead of reporting. Same shape as `make env-populate` aborting mid-populate.
got="$(eff)"
if [ "$got" = "${ROBOT}|robotsecret" ]; then ok "2-KEY overlay: env_publish BOTH keys -> [$got]"
else bad "2-key overlay: expected robot/robotsecret, got [$got] — the SECOND state_unset failed, so the overlay still pins the admin password"; fi

# 3c. And the mechanism, directly: state_unset on a SINGLE-key overlay must still remove the key.
#     rc is deliberately NOT the assertion — a silent rc=1 that leaves the key is the defect, and an
#     rc-only check would pass the moment someone "fixed" it by returning 0 without removing anything.
( umask 077; printf 'HARBOR_USERNAME=admin\n' > "$TD/.env.state" )
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  state_unset HARBOR_USERNAME' ) >/dev/null 2>&1 || true
if ! grep -q '^HARBOR_USERNAME=' "$TD/.env.state" 2>/dev/null; then
  ok "state_unset on a SINGLE-key overlay removes the key (file may become empty)"
else bad "state_unset left the key in a single-key overlay — grep -v exited 1 on empty output"; fi

# 4. state_unset PRESERVES 0600 — the sink holds generated credentials.
setup
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  state_unset HARBOR_USERNAME' ) >/dev/null 2>&1
m="$(stat -c '%a' "$TD/.env.state")"
if [ "$m" = 600 ]; then ok "state_unset preserves mode 0600"; else bad "mode became $m, expected 600"; fi

# 5. It removes ONLY that key.
if grep -q '^ARGOCD_KUBECONFIG=/x$' "$TD/.env.state" && grep -q '^HARBOR_PASSWORD=' "$TD/.env.state" \
   && ! grep -q '^HARBOR_USERNAME=' "$TD/.env.state"; then
  ok "state_unset removed ONLY the named key"
else bad "state_unset disturbed other keys: $(tr '\n' ' ' < "$TD/.env.state")"; fi

# 6. Absent key / absent file -> no-op, rc 0 (never a hard failure on a fresh box).
if ( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
     . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
     state_unset NOT_PRESENT' ) >/dev/null 2>&1; then ok "absent key -> rc 0"; else bad "absent key should be a no-op"; fi
rm -f "$TD/.env.state"
if ( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
     . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
     state_unset HARBOR_USERNAME' ) >/dev/null 2>&1; then ok "absent FILE -> rc 0"; else bad "absent file should be a no-op"; fi
# 7. THE PAIR-ABORT ROUTE — `env_publish_all` must be ALL-OR-NOTHING.
#    A round MEASURED that 22-harbor-robot.sh and 28-harbor-admin-password.sh each ran TWO BARE
#    `env_publish` under `set -euo pipefail`. Key #1 fails -> set -e aborts -> key #2 is never written
#    and the overlay keeps admin's password: effective USER=robot$x PASS=adminpw, verbatim the "401
#    that reads like a wrong password" that 22's OWN comment calls worse than none. Cases 1-6 are
#    structurally BLIND to it: they pin the PARTIAL-CLEAR route to that pair, never the MID-PAIR-ABORT
#    route. Measured baseline before this case existed: 9 passed, 0 failed with the defect live.
#    The shadow is a legacy `.env.kind` (load_env sources it LAST), so the publish CANNOT win and the
#    failure is guaranteed — which is what makes the all-or-nothing property observable at all.
setup
printf 'HARBOR_USERNAME=/LEGACY-USER\n' > "$TD/.env.kind"
( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" bash -c '
  set -euo pipefail
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish_all "the robot credential pair" \
    HARBOR_USERNAME "robot\$vks-cicd" \
    HARBOR_PASSWORD "robotsecret"' ) >/dev/null 2>&1 || true
#    ^ `|| true` so the assertions below RUN. A failing publish returns non-zero BY DESIGN; without it
#    the suite aborts here and reports nothing — the very shape this case exists to test.
_u="$(grep -cE '^HARBOR_USERNAME=' "$TD/.env" 2>/dev/null || true)"
_p="$(grep -cE '^HARBOR_PASSWORD=' "$TD/.env" 2>/dev/null || true)"
if [ "${_u:-0}" -ge 1 ] && [ "${_p:-0}" -ge 1 ]; then
  ok "PAIR: both keys written to .env despite the failure — all-or-nothing"
else
  bad "PAIR: .env has USERNAME=${_u} PASSWORD=${_p} — a mid-pair ABORT left the pair half-written"
fi
_left="$(grep -cE '^(HARBOR_USERNAME|HARBOR_PASSWORD)=' "$TD/.env.state" 2>/dev/null || true)"
if [ "${_left:-0}" -eq 0 ]; then ok "PAIR: overlay holds NEITHER key — no half-pair left behind"
else bad "PAIR: overlay still holds ${_left} of the pair — a half-cleared credential pair"; fi
rm -f "$TD/.env.kind"


# 8. B139 — SKIP_DOTENV=1 must WARN AND SUCCEED when nothing shadows, and still FAIL when something does.
#    THE DEFECT WAS A MISLEADING ERROR, not merely an rc. `assert_env_effective` re-reads through
#    `load_env`, which under SKIP_DOTENV=1 deliberately IGNORES `.env` (os.sh:582) — so the value just
#    written there is invisible IN THIS PROCESS and the failure path fired, telling the operator
#    "a higher-precedence file already sets HARBOR_PASSWORD ... remove that line" while naming NO LINE.
#    They are sent to delete a line that does not exist. MEASURED before the fix: rc=1 under
#    SKIP_DOTENV=1, rc=0 with it unset, on the IDENTICAL call.
#    The callers are scenario-1 operator steps (22-harbor-robot, 27-use-guest-kubeconfig,
#    28-harbor-admin-password) and the KinD e2e sets E2E_SKIP_DOTENV=1 BY DESIGN, so this is reached
#    on every such run.
#    ⚠️ BOTH ARMS ARE REQUIRED. A "fix" that just warns whenever SKIP_DOTENV=1 throws away the real
#    discrimination — a genuine shadow outranks `.env` whether or not `.env` was read, and must still
#    FAIL with the file named. Arm 2 is what stops that, and it is why this is not a message tweak.
setup
_out="$( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" SKIP_DOTENV=1 bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish HARBOR_PASSWORD probevalue' 2>&1 )" && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ]; then
  ok "SKIP_DOTENV: an unverifiable-but-unshadowed write SUCCEEDS (rc=0)"
else
  bad "SKIP_DOTENV: rc=${_rc} with nothing shadowing — the operator is told to remove a line that
        does not exist. Re-read with .env enabled to discriminate before accusing."
fi
case "$_out" in
  *"cannot be verified here"*) ok "SKIP_DOTENV: and it SAYS why, rather than passing in silence" ;;
  *) bad "SKIP_DOTENV: succeeded without explaining that .env was ignored in-process — a silent
        pass here is indistinguishable from a verified one." ;;
esac

#    ARM 2: a REAL shadow must still FAIL, and still NAME the file. This is the discrimination the
#    row's first prescription ("special-case the message") would have destroyed.
printf 'HARBOR_PASSWORD=/LEGACY-PASS
' > "$TD/.env.kind"
_out2="$( cd "$TD" && REPO_ROOT="$TD" VKS_STATE_FILE="$TD/.env.state" SKIP_DOTENV=1 bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
  env_publish HARBOR_PASSWORD probevalue' 2>&1 )" && _rc2=0 || _rc2=$?
#    ^ `&& rc=0 || rc=$?`, NEVER `; rc=$?`. Arm 2 makes the publish FAIL on purpose, and under
#    `set -e` a failing command substitution in an ASSIGNMENT aborts the script — which is exactly
#    what happened on the first attempt: arm 2 never ran and the suite exited 1 having printed no
#    summary. Case 7 above records the same trap in its own `|| true`.
rm -f "$TD/.env.kind"
if [ "$_rc2" -ne 0 ]; then
  ok "SKIP_DOTENV: a GENUINE shadow still FAILS (the discrimination survives the fix)"
else
  bad "SKIP_DOTENV: a real .env.kind shadow returned rc=0 — the fix warns unconditionally and has
        thrown away the only signal that distinguishes a shadow from an unreadable .env."
fi
case "$_out2" in
  *".env.kind"*) ok "SKIP_DOTENV: and the failure NAMES the shadowing file" ;;
  *) bad "SKIP_DOTENV: the failure did not name .env.kind — naming the file IS the discriminator
        between a real shadow and an in-process read gap." ;;
esac


echo
echo "env_publish tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
