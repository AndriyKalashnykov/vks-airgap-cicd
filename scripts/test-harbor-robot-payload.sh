#!/usr/bin/env bash
# test-harbor-robot-payload.sh — the Harbor robot payloads must be VALID JSON of the RIGHT SHAPE,
# and the shape depends on who you are. Offline: builds the payloads exactly as 22-harbor-robot.sh
# does and inspects them; never talks to Harbor.
#
# WHY THIS EXISTS
# ---------------
# 22-harbor-robot.sh always created a level:"system" robot -- the only shape that can span TWO
# projects in ONE credential -- which Harbor gates on SYSTEM-ADMIN. Meanwhile the README promised a
# Harbor PROJECT-ADMIN tenant could self-service it. A tenant simply got a 403 and no robot.
#
# The fix asks Harbor who we are and picks the shape it will accept. Building THAT payload is where
# this test earns its keep: the first attempt pasted JSON fragments with `paste -sd,`, which joins
# LINES -- and the fragments had no trailing newline, so they concatenated with NO COMMA and jq
# rejected the payload. That would have broken the SYSTEM-ADMIN path, i.e. every current user, and it
# is invisible until you actually call Harbor.
#
# Harbor API facts these payloads rely on (Harbor 2.15.x -- the version the pinned chart ships):
#   * POST /api/v2.0/robots with a `level` field is the ONLY robot endpoint. The per-project path
#     POST /api/v2.0/projects/{p}/robots existed in 2.12 and was REMOVED in the 2.13 line.
#   * a level:"project" robot may hold exactly ONE project permission.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# --- the SYSADMIN payload, built exactly as the script builds it ---------------------------------
build_system_payload() { # <project...>
  local projects; projects="$(printf '%s\n' "$@" | sort -u)"
  local perms
  perms="$(printf '%s\n' "$projects" | jq -R -s -c '
      split("\n") | map(select(length > 0))
      | map({kind:"project", namespace:.,
             access:[{resource:"repository", action:"push"},
                     {resource:"repository", action:"pull"}]})')"
  jq -nc --arg name "vks-cicd" --argjson perms "$perms" \
    '{name:$name, duration:-1, level:"system", description:"x", permissions:$perms}'
}

build_project_payload() { # <project>
  jq -nc --arg name "vks-cicd" --arg ns "$1" \
    '{name:$name, duration:-1, level:"project", description:"x",
      permissions:[{kind:"project", namespace:$ns,
                    access:[{resource:"repository",action:"push"},
                            {resource:"repository",action:"pull"}]}]}'
}

# 1. SYSTEM robot, two projects — MUST be valid JSON with TWO permissions.
#    (This is the case the comma bug broke: it produced invalid JSON and would have 400'd.)
p="$(build_system_payload cicd apps 2>/dev/null)"
if [ -z "$p" ] || ! printf '%s' "$p" | jq -e . >/dev/null 2>&1; then
  bad "system payload (2 projects) is not valid JSON — the sysadmin path (every current user) is broken"
else
  n="$(printf '%s' "$p" | jq '.permissions | length')"
  lvl="$(printf '%s' "$p" | jq -r '.level')"
  ns="$(printf '%s' "$p" | jq -r '[.permissions[].namespace] | sort | join(",")')"
  if [ "$lvl" = system ] && [ "$n" = 2 ] && [ "$ns" = "apps,cicd" ]; then
    ok "system payload: valid JSON, level=system, push+pull on BOTH projects"
  else
    bad "system payload wrong: level=$lvl permissions=$n projects=$ns"
  fi
fi

# 2. Duplicate projects (the TENANT collapse: HARBOR_INFRA_PROJECT == HARBOR_APP_PROJECT) must
#    de-duplicate — Harbor rejects a robot naming the same project twice.
p="$(build_system_payload myproj myproj)"
n="$(printf '%s' "$p" | jq '.permissions | length')"
if [ "$n" = 1 ]; then
  ok "system payload de-duplicates when both projects are the same (the tenant collapse)"
else
  bad "system payload did NOT de-duplicate ($n permissions) — Harbor rejects a repeated project"
fi

# 3. PROJECT robot — valid JSON, level=project, EXACTLY ONE permission (Harbor allows no more).
p="$(build_project_payload myproj)"
if ! printf '%s' "$p" | jq -e . >/dev/null 2>&1; then
  bad "project payload is not valid JSON"
else
  lvl="$(printf '%s' "$p" | jq -r '.level')"
  n="$(printf '%s' "$p" | jq '.permissions | length')"
  acc="$(printf '%s' "$p" | jq -r '[.permissions[0].access[].action] | sort | join(",")')"
  if [ "$lvl" = project ] && [ "$n" = 1 ] && [ "$acc" = "pull,push" ]; then
    ok "project payload: valid JSON, level=project, exactly ONE project, push+pull"
  else
    bad "project payload wrong: level=$lvl permissions=$n access=$acc"
  fi
fi

# 4. The script must NOT call the per-project robot endpoint — it does not exist on Harbor 2.13+.
if grep -qE 'projects/[^"]*/robots' "${SCRIPT_DIR}/22-harbor-robot.sh" "${SCRIPT_DIR}/lib/harbor.sh"; then
  bad "a per-project robot endpoint (POST /projects/{p}/robots) is referenced — REMOVED in Harbor 2.13; it would 404"
else
  ok "no per-project robot endpoint referenced (removed in Harbor 2.13; only POST /robots + level exists)"
fi

# 5. The permission branch must key on the HTTP CODE, not on Harbor's error prose.
if grep -q 'harbor_last_code' "${SCRIPT_DIR}/22-harbor-robot.sh"; then
  ok "the failure branch keys on the HTTP status (harbor_last_code), not on error prose"
else
  bad "the failure branch does not read harbor_last_code — a 403 is indistinguishable from any other error"
fi

# 6. The status must be recorded in a FILE, not a shell global. Callers capture the body with
#    `resp="$(harbor_api_body ...)"` — a COMMAND SUBSTITUTION, i.e. a subshell — so a global assigned
#    inside harbor_api_body never reaches them. That is not theoretical: it made harbor_is_sysadmin
#    tell a real Harbor ADMINISTRATOR they were not one, and the script then refused to create the
#    system robot it had always created. Verified against a live Harbor.
if grep -q 'HARBOR_CODE_FILE' "${SCRIPT_DIR}/lib/harbor.sh" &&
   grep -q 'harbor_last_code() *{ *cat' "${SCRIPT_DIR}/lib/harbor.sh"; then
  ok "the HTTP status survives the subshell (recorded to a file, not a global)"
else
  bad "the HTTP status is not file-backed — a global set inside a command substitution is LOST to the caller"
fi

[ "$fail" = 0 ] && { echo "test-harbor-robot-payload: OK"; exit 0; }
echo "test-harbor-robot-payload: FAILED" >&2; exit 1
