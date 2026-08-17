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

echo
echo "env_publish tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
