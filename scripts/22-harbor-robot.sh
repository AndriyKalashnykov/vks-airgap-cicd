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
: "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"

ROBOT_NAME="${HARBOR_ROBOT_NAME:-vks-cicd}"
OUT_FILE="${HARBOR_ROBOT_OUT:-secrets/harbor-robot.env}"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
harbor_setup "$HARBOR_TMP"

# The projects the robot needs push+pull on. DISTINCT: a tenant is often granted ONE project and
# points both vars at it, and Harbor rejects a project-level robot that names the same project twice.
PROJECTS="$(printf '%s\n%s\n' "$HARBOR_INFRA_PROJECT" "$HARBOR_APP_PROJECT" | sort -u)"
N_PROJECTS="$(printf '%s\n' "$PROJECTS" | grep -c .)"

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
    409) die "robot '$ROBOT_NAME' already exists — delete it in Harbor (Administration → Robot Accounts) to regenerate, or reuse the secret you saved earlier." ;;
  esac
  case "$msg" in
    *conflict*|*exists*|*already*) die "robot '$ROBOT_NAME' already exists — delete it in Harbor (Administration → Robot Accounts) to regenerate, or reuse the secret you saved earlier." ;;
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
mkdir -p "$(dirname "$OUT_FILE")"
rm -f "$OUT_FILE"
esc_rname=${rname//\'/\'\\\'\'}
esc_secret=${secret//\'/\'\\\'\'}
( umask 077; {
    printf "# Harbor robot account for CI (generated by scripts/22-harbor-robot.sh). Copy into .env.\n"
    printf "HARBOR_USERNAME='%s'\n" "$esc_rname"
    printf "HARBOR_PASSWORD='%s'\n" "$esc_secret"
  } > "$OUT_FILE" )

log_info "robot account '$rname' created."
log_info "credentials written to $OUT_FILE (mode 0600, gitignored) — copy HARBOR_USERNAME/HARBOR_PASSWORD from it into .env."
log_warn "the secret is shown only once by Harbor; keep $OUT_FILE safe (or delete it after copying into .env)."
