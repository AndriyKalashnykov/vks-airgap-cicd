#!/usr/bin/env bash
# 22-harbor-robot.sh — create a least-privilege Harbor ROBOT ACCOUNT for CI (push+pull scoped to
# the two mirror projects), so the pipeline authenticates as a robot instead of `admin`.
#
# Runs on the dual-homed jump box against the lab (or the local KinD) Harbor, using the CURRENT
# HARBOR_USERNAME/HARBOR_PASSWORD (admin) to mint the robot. Harbor shows a robot's secret ONCE at
# creation, so this writes the robot name + secret to a gitignored 0600 file for you to copy into
# .env — the secret is NEVER printed to stdout or passed on argv.
#
# Usage: HARBOR_ROBOT_NAME=<name> scripts/22-harbor-robot.sh   (name defaults to vks-cicd)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"

require_cmd curl
require_cmd jq

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_APP_PROJECT:?}"
: "${HARBOR_USERNAME:?set HARBOR_USERNAME in .env to the Harbor ADMIN (or project-admin) that will MINT the robot — 'admin' for scenario 1}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"

ROBOT_NAME="${HARBOR_ROBOT_NAME:-vks-cicd}"
OUT_FILE="${HARBOR_ROBOT_OUT:-secrets/harbor-robot.env}"

# Step 9 tells the operator to copy this robot into .env as HARBOR_USERNAME. If they then re-run
# this target, we authenticate AS THE ROBOT -- and a robot cannot create robots. harbor_is_sysadmin
# gets 412, returns 1, and the script dies with "you are NOT a Harbor system administrator", which
# is false: they are, their .env just no longer says so. Name the real cause.
case "${HARBOR_USERNAME:-}" in
  'robot$'*) die "HARBOR_USERNAME is '${HARBOR_USERNAME}', a ROBOT — and a robot cannot mint robots.
       This is the credential Step 9 told you to save, so this is the expected state after a first run.
       Set HARBOR_USERNAME/HARBOR_PASSWORD back to the Harbor ADMIN for this one command." ;;
esac

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
harbor_setup "$HARBOR_TMP"

# The projects the robot needs push+pull on. DISTINCT: a tenant is often granted ONE project and
# points both vars at it, and Harbor rejects a project-level robot that names the same project twice.
PROJECTS="$(printf '%s\n%s\n' "$HARBOR_INFRA_PROJECT" "$HARBOR_APP_PROJECT" | sort -u)"
# `grep -c` prints 0 and EXITS 1 on a zero count, which under pipefail+set -e would kill this
# script silently. UNREACHABLE today — the `${HARBOR_INFRA_PROJECT:?}` / `${HARBOR_APP_PROJECT:?}`
# guards above fire on EMPTY as well as unset, so PROJECTS always has >=1 line. Kept as
# defence-in-depth against someone weakening those guards; graded LOW, not a live fix.
N_PROJECTS="$(printf '%s\n' "$PROJECTS" | grep -c . || true)"

# Create them if we can. A tenant CANNOT (403) — that is not fatal here: they were granted an
# existing project, and `ensure_project` now says so instead of dying before we ever reach the robot.
while read -r p; do [ -n "$p" ] && ensure_project "$p" || true; done <<EOF
$PROJECTS
EOF

# WHICH ROBOT MAY WE ACTUALLY CREATE?
#
# This script always created a level:"system" robot — the only shape that can span TWO projects in
# ONE credential. Harbor gates that on SYSTEM-ADMIN. Meanwhile the README promised a Harbor
# PROJECT-ADMIN tenant could self-service it ("system-admin is not required"). That was simply false:
# a tenant got a 403 and no robot.
#
# So ASK Harbor who we are, and pick the shape it will accept:
#   sysadmin                     -> level:"system", push+pull on every project (unchanged).
#   not sysadmin, ONE project    -> level:"project", exactly one permission. Harbor rejects more than
#                                   one project on a project-level robot. Login name is
#                                   robot$<project>+<name> (note: NOT robot$<name>).
#   not sysadmin, TWO projects   -> IMPOSSIBLE. Not a plumbing gap: kaniko carries ONE host-keyed
#                                   docker auth and must PULL from the infra project and PUSH to the
#                                   app project with it, so two robots cannot both be that one auth.
#                                   Print the exact ask and stop.
if harbor_is_sysadmin; then
  log_info "Harbor says you ARE a system administrator — creating a system-level robot"
  # Build the permissions array with jq from the project list. (Do NOT paste JSON fragments together
  # by hand: `paste -sd,` joins LINES, and a printf without a trailing newline produced ONE line, so
  # the objects concatenated with no comma and jq rejected the payload as invalid JSON. Caught by
  # rendering the payload before ever calling Harbor.)
  perms="$(printf '%s\n' "$PROJECTS" | jq -R -s -c '
      split("\n") | map(select(length > 0))
      | map({kind:"project", namespace:.,
             access:[{resource:"repository", action:"push"},
                     {resource:"repository", action:"pull"}]})')"
  payload="$(jq -nc --arg name "$ROBOT_NAME" --argjson perms "$perms" \
    '{name:$name, duration:-1, level:"system", description:"vks-airgap-cicd CI push/pull", permissions:$perms}')"
  log_info "creating Harbor robot '$ROBOT_NAME' (push+pull on: $(printf '%s' "$PROJECTS" | tr '\n' ' '))"
elif [ "$N_PROJECTS" = "1" ]; then
  only="$(printf '%s\n' "$PROJECTS" | head -1)"
  log_info "Harbor says you are NOT a system administrator — creating a PROJECT-level robot in '$only'"
  log_info "  (that is all a project-admin may do; its login name will be robot\$${only}+${ROBOT_NAME})"
  payload="$(jq -nc --arg name "$ROBOT_NAME" --arg ns "$only" \
    '{name:$name, duration:-1, level:"project",
      description:"vks-airgap-cicd CI push/pull",
      permissions:[{kind:"project", namespace:$ns,
                    access:[{resource:"repository",action:"push"},
                            {resource:"repository",action:"pull"}]}]}')"
else
  log_error "You are NOT a Harbor system administrator, and this flow needs push+pull on TWO projects:"
  while read -r p; do [ -n "$p" ] && log_error "    - $p"; done <<EOF
$PROJECTS
EOF
  log_error ""
  log_error "  A PROJECT-level robot (all a project-admin may create) is scoped to exactly ONE project,"
  log_error "  and two robots cannot help: the kaniko build pod carries ONE registry credential and must"
  log_error "  PULL its builder/runtime images from '${HARBOR_INFRA_PROJECT}' and PUSH the app image to"
  log_error "  '${HARBOR_APP_PROJECT}' with that same credential."
  log_error ""
  log_error "  Two ways forward:"
  log_error "    1. Use ONE project for both. Set BOTH in .env (an uncommented .env.example value would"
  log_error "       clobber a make-level override):"
  log_error "           HARBOR_INFRA_PROJECT=<your project>"
  log_error "           HARBOR_APP_PROJECT=<your project>"
  log_error "       The repo names do not collide (infra: <app>-builder, golang, eclipse-temurin, ...;"
  log_error "       app: bare <app>), so one project holds both safely."
  log_error "    2. ASK your platform team for a SYSTEM-level robot with push+pull on both projects,"
  log_error "       and put its name + secret in .env as HARBOR_USERNAME / HARBOR_PASSWORD."
  die "cannot create a robot that spans two projects without Harbor system-admin."
fi

# The remedy DEPENDS ON WHETHER THE SECRET FILE IS HERE, and the old message assumed it was.
# MEASURED on a fresh jump box: the robot existed (a PREVIOUS box minted it), $OUT_FILE did not,
# and the error said "reuse the secret you saved earlier" -- immediately followed by
# `cat: ./secrets/harbor-robot.env: No such file or directory`. An error that names an unavailable
# remedy sends the operator to look for a file that was never there.
robot_exists_message() {
  if [ -f "$OUT_FILE" ]; then
    printf "robot '%s' already exists, and %s is here — reuse it. Harbor shows a robot secret ONCE, so re-creating would hand you a credential that does not work." "$ROBOT_NAME" "$OUT_FILE"
  else
    printf "robot '%s' already exists but %s is NOT on this box — it was created elsewhere. Harbor shows a robot secret ONCE and cannot re-issue it, so there is nothing to read back. Either get the secret from whoever created it, or refresh it in the Harbor UI (Administration → Robot Accounts → Refresh Secret) and paste the new value into %s." "$ROBOT_NAME" "$OUT_FILE" "$OUT_FILE"
  fi
}

resp="$(harbor_api_body POST robots "$payload")"

secret="$(printf '%s' "$resp" | jq -r '.secret // empty')"
rname="$(printf '%s' "$resp" | jq -r '.name // empty')"
if [ -z "$secret" ] || [ -z "$rname" ]; then
  # Never echo the raw response (could carry sensitive data); surface only the error message.
  msg="$(printf '%s' "$resp" | jq -r '(.errors[0].message // .message // "unknown error")' 2>/dev/null || echo 'unparseable response')"
  # Branch on the STATUS, not on Harbor's error prose (which is why a 403 used to look like any
  # other failure). harbor_last_code reads the status harbor_api_body recorded (via a FILE — a global
  # would be lost, because the body is captured in a command substitution, i.e. a subshell).
  case "$(harbor_last_code)" in
    401|403)
      die "Harbor refused to create robot '$ROBOT_NAME' (http $(harbor_last_code)): you do not have permission. If you are a project-admin, you may only create a robot in a project you administer — see the guidance above."
      ;;
    409) die "$(robot_exists_message)" ;;
  esac
  case "$msg" in
    *conflict*|*exists*|*already*) die "$(robot_exists_message)" ;;
    *) die "failed to create robot '$ROBOT_NAME' (http $(harbor_last_code)): $msg" ;;
  esac
fi

# Write the credentials to a gitignored 0600 file. Single-quote both values: the robot name is
# `robot$<name>`, so a double-quoted .env line would mis-expand `$<name>`.
#
# esc_sq (lib/os.sh) as well as the quotes: a `'` INSIDE the value terminates the quote, so
# single-quoting ALONE is not inert — the remainder is parsed as code by load_env's `set -a`
# source. Graded LOW because Harbor cannot currently emit one (secrets are [a-zA-Z0-9]; robot names
# are validated `^[a-z0-9]+(?:[._-][a-z0-9]+)*$` — goharbor v2.15.0), so this is defence against an
# upstream charset change, not a live hole. Assigned, not $( )-captured: a command substitution
# strips trailing newlines, which would silently corrupt a rotated secret that ends in one.
#
# rm -f FIRST: `umask 077` only applies when the file is CREATED. A pre-existing world-readable
# harbor-robot.env (a stray touch, an editor, a restore) would KEEP mode 0644 and the secret would
# land world-readable while this code still read as safe.
ensure_secret_dir "$(dirname "$OUT_FILE")"
rm -f "$OUT_FILE"
esc_rname=${rname//\'/\'\\\'\'}
esc_secret=${secret//\'/\'\\\'\'}
( umask 077; {
    printf "# Harbor robot account for CI (generated by scripts/22-harbor-robot.sh).\n# Already published to ./.env — nothing to copy.\n"
    printf "HARBOR_USERNAME='%s'\n" "$esc_rname"
    printf "HARBOR_PASSWORD='%s'\n" "$esc_secret"
  } > "$OUT_FILE" )

log_info "robot account '$rname' created."
log_info "credentials written to $OUT_FILE (mode 0600, gitignored)."

# AND PUBLISHED, rather than asking the operator to copy two values a script just generated.
# scenario-1 Step 9 used to say "Then set in ./.env, copying the two values it just printed" -- a
# hand-copy of a secret THIS SCRIPT PRODUCED. The same shape cost a walk row 605 seconds when the
# Harbor admin password was left to a paste that nobody performs (see 28-harbor-admin-password.sh).
#
# set_env_var preserves .env's mode (it truncates in place; it does NOT mv a fresh tempfile over it),
# so a .env the operator chmod 600'd stays 0600.
#
# ⚠️ A ROBOT CANNOT MINT ROBOTS, and this overwrites the admin credential that just minted this one.
# Re-running `make harbor-robot` now stops with that exact message (the guard at the top of this
# file). The way back is `make harbor-admin-password`, which re-reads the admin credential from the
# Supervisor secret -- so say that HERE, where the operator is standing, not in a doc they have left.
# env_publish, NOT set_env_var: it writes .env, CLEARS the key from the state overlay, and only then
# asserts. Writing the replacement into the LOWEST-precedence sink while the overlay still holds the
# old value is not a publish -- it is a no-op with a log line, which is exactly what happened below.
#
# BOTH KEYS, ALWAYS. Clearing only the username leaves .env=robot$x/robotsecret against an overlay
# still holding admin's password -- effective USER=robot$x PASS=adminpw, i.e. a 401 that reads like a
# wrong password. A partial fix here is worse than none.
# ALL-OR-NOTHING (B138's round, F2). Two bare `env_publish` under `set -euo pipefail` meant key #1
# could ABORT with key #2 unwritten — producing EXACTLY the mismatched pair the comment above calls
# worse than none. MEASURED: overlay holding admin's pair + `.env.kind` pinning HARBOR_USERNAME ->
# effective USER=robot$x PASS=adminpw. The comment stated the invariant; the code could not keep it.
env_publish_all "the robot credential pair" \
  HARBOR_USERNAME "$rname" \
  HARBOR_PASSWORD "$secret"
# ASSERT THE WRITE TOOK EFFECT. `.env` is the LOWEST-precedence sink, and on the DEFAULT admin path
# `04-install-harbor-service.sh` has already state_set admin's credential into the overlay (both keys
# ship COMMENTED in .env.example, so its `[ -n "${HARBOR_PASSWORD:-}" ] ||` guard is false at Step 4).
# The line below then says the pipeline runs as the ROBOT while it runs as Harbor ADMIN -- and it
# does NOT 401, because admin works, so nothing surfaces it. It also defeats this file's own
# `robot$*` re-run guard, so a second robot gets minted unnoticed.
# (the assert that used to live here is now the last step of env_publish above — MEASURED
# 2026-08-17, matrix row 1: it fired with rc=1 having already created the robot, because the write
# could not take effect while 04-install-harbor-service.sh:144-145 still owned both keys.)
log_info "published HARBOR_USERNAME/HARBOR_PASSWORD to ./.env — the pipeline now runs as the ROBOT, not as admin."
log_info "  to mint another robot later, restore the admin credential first: make harbor-admin-password"
log_warn "the secret is shown only once by Harbor; $OUT_FILE is your only other copy."
