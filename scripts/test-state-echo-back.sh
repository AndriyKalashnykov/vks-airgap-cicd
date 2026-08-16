#!/usr/bin/env bash
# test-state-echo-back.sh — a writer must publish ONLY what it produced (B111 / its F1).
#
# WHAT WENT WRONG. `04-install-harbor-service.sh` computes
#     H_ADMIN="${HARBOR_PASSWORD:-$(gen_password)}"      # reuse an existing .env value if set
# and then USED TO publish it back unconditionally:
#     state_set HARBOR_PASSWORD "$H_ADMIN"
#     state_set HARBOR_USERNAME admin
# load_env sources the overlay LAST, so that frozen copy outranked .env AND the command line
# forever. Two measured harms, and the second is the worse one:
#
#   * `make harbor-admin-password` verified a fresh password against Harbor (http 200), wrote it to
#     .env, and was discarded; `make env-validate` returned 401 seconds later. Both were telling the
#     truth about different values. (The copy was provably never generated: gen_password is 16 chars
#     and the value on a real box was 32.)
#   * The overlay's `admin` shadowed the least-privilege ROBOT that 22-harbor-robot.sh writes to
#     .env — while 22 printed "the pipeline now runs as the ROBOT, not as admin". False on every
#     real-lab box, and unlike the password case it does NOT 401: the pipeline runs as Harbor ADMIN,
#     successfully, claiming otherwise. A diagnostic on failure cannot catch a failure that looks
#     like success, which is why this is a writer fix and not a warning.
#
# 05-kind-up.sh:129-130 already had the right shape (only-if-unset) and said so in its own comment.
# shellcheck disable=SC2016  # `robot$vks` is Harbor's LITERAL robot-account syntax — the `$name`
                            # is part of the account name, not a shell expansion. Single quotes
                            # are exactly right, and this repo has a rule about an unquoted
                            # `robot$<name>` making the state overlay unsourceable.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

SRC="${SCRIPT_DIR}/04-install-harbor-service.sh"

# 1. STRUCTURAL: the two publishes must be guarded, and the guard must be the only-if-unset shape.
for k in HARBOR_USERNAME HARBOR_PASSWORD; do
  if grep -qE "^\[ -n \"\\\$\{${k}:-\}\" \] \|\| state_set ${k} " "$SRC"; then
    ok "04 publishes ${k} only-if-unset"
  else
    bad "04 publishes ${k} only-if-unset" "found: $(grep -n "state_set ${k}" "$SRC" | head -1)"
  fi
done
if grep -qE '^state_set HARBOR_(USERNAME|PASSWORD) ' "$SRC"; then
  bad "04 has no UNGUARDED state_set of either credential" "$(grep -nE '^state_set HARBOR_' "$SRC" | head -2)"
else
  ok "04 has no UNGUARDED state_set of either credential"
fi

# 2. BEHAVIOURAL: the guard's own logic, both directions plus the fresh-install path.
pub() {  # pub <guarded 0|1> <HARBOR_PASSWORD> <HARBOR_USERNAME> -> what the overlay would gain
  ( export HARBOR_PASSWORD="$2" HARBOR_USERNAME="$3"
    H_ADMIN="${HARBOR_PASSWORD:-generated16chars}"; out=""
    if [ "$1" = 1 ]; then
      [ -n "${HARBOR_USERNAME:-}" ] || out="${out}U "
      [ -n "${HARBOR_PASSWORD:-}" ] || out="${out}P=${H_ADMIN} "
    else
      out="U P=${H_ADMIN} "
    fi
    printf '%s' "${out:-none}" )
}
if [ "$(pub 0 robotsecret 'robot$vks')" = 'U P=robotsecret ' ]
then ok  "unguarded DOES echo the operator's value back (the defect reproduces)"
else bad "unguarded DOES echo the operator's value back" "got '$(pub 0 robotsecret 'robot$vks')'"; fi
if [ "$(pub 1 robotsecret 'robot$vks')" = none ]
then ok  "guarded publishes NOTHING when .env already has both"
else bad "guarded publishes NOTHING when .env already has both" "got '$(pub 1 robotsecret 'robot$vks')'"; fi
if [ "$(pub 1 '' '')" = 'U P=generated16chars ' ]
then ok  "guarded STILL publishes on a fresh install (happy path intact)"
else bad "guarded STILL publishes on a fresh install" "got '$(pub 1 '' '')'"; fi

# 3. The command-line half, against the REAL loader.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts"; cp -r "${SCRIPT_DIR}/lib" "$T/scripts/"; cp "${SCRIPT_DIR}/../.env.example" "$T/"
printf 'HARBOR_PASSWORD=fromdotenv\n' > "$T/.env"
printf 'HARBOR_PASSWORD=fromstate\n'  > "$T/.env.state"
got="$( cd "$T" && env HARBOR_PASSWORD=FROM_CLI REPO_ROOT="$T" bash -c \
        '. scripts/lib/os.sh; load_env >/dev/null 2>&1; printf "%s" "${HARBOR_PASSWORD:-<unset>}"' )"
if [ "$got" = FROM_CLI ]
then ok  "a per-run HARBOR_PASSWORD=... survives the overlay (snapshot protection)"
else bad "a per-run HARBOR_PASSWORD=... survives the overlay" "got '$got' — the overlay still wins"; fi

echo
echo "state echo-back: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
