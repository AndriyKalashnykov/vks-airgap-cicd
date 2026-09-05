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
# harbor_username_is_robot (lib/harbor.sh) — SINGLE-SOURCED with the guard in
# 28-harbor-admin-password.sh, which had drifted to a DIFFERENT SPELLING of this same
# predicate, so neither guard was findable by grepping the other.
# ENSURE MODE (harbor_robot_ensure=1, set only by `make harbor-robot-ensure`, which is what
# `install-all` runs). `make harbor-robot` itself stays STRICT: the operator asked for a robot and
# deserves a refusal, not a shrug.
#
# ⚠️ THE SKIP IS GATED ON A VERDICT, NEVER ON A STRING OR ON A FILE. An idea-round adversary
# refuted both of the predicates this was first written with:
#   * `harbor_username_is_robot` (lib/harbor.sh:244) is `case $x in 'robot$'*)` — a PURE STRING TEST
#     that makes ZERO API calls. CLAUDE.md records the measured state it cannot see: a 12-day-old
#     robot credential that read "works" from three separate probes and was DEAD (UNAUTHORIZED on
#     push). Skipping on it ships an unverified credential into `platform`, which BAKES it into
#     `harbor-dockerconfig` (60-configure-tekton.sh:80,89) and the per-app pull Secret
#     (70-configure-argocd.sh) — so the failure surfaces as ImagePullBackOff, far from here.
#   * `[ -f "$OUT_FILE" ]` is worse: MEASURED, nothing in this repo READS harbor-robot.env
#     (grep -rn finds only the writer, a comment, a test fixture and help text). The credential is
#     consumed from .env. And `secrets/` survives every lab re-cut while each cut mints a FRESH
#     Harbor, so a present file is compatible with a Harbor that has never seen that robot.
#
# harbor_auth_verdict (lib/harbor.sh:251) returns THREE outcomes, and "could not tell" is not "fine".
# ⚠️ Use harbor_auth_verdict / harbor_auth_ok, NEVER harbor_auth_report — lib/harbor.sh:213 records
# the measured fake-green where a wrong CA *and* a wrong password still returned 0.
# lowercase ON PURPOSE, matching argocd-password.sh: an UPPERCASE name reads as an OPERATOR KNOB to
# check-env-coverage, which then (correctly) demands it be documented in .env.example. The
# operator-facing knob is the TARGET (`make harbor-robot-ensure`); this variable is internal plumbing.
ensure_mode() { [ "${harbor_robot_ensure:-0}" = 1 ]; }

# ensure_skip_if_credential_works <why> — in ensure mode only. Exits 0 on `accepted`, dies otherwise.
# SCOPE, stated so the green is not over-read: `accepted` maps 200 AND 403 (lib/harbor.sh:260) because
# a project-scoped robot is authenticated and still 403s a system endpoint. It proves AUTHENTICATION,
# not authorization to PUSH — only a real push discriminates that, and `mirror` does it two steps later.
ensure_skip_if_credential_works() {
  local why="$1" v
  v="$(harbor_auth_verdict)"
  case "$v" in
    accepted)
      # F4: name the IDENTITY. "the robot exists" and "you ARE the robot" are different facts, and
      # on matrix rows 2/4/5/6 the credential that authenticates is admin — so the pipeline runs as
      # admin, not as the robot, and saying only "the credential authenticates" reads as the opposite.
      log_warn "harbor-robot: SKIPPING the mint — ${why}, and the credential in .env"
      log_warn "  (${HARBOR_USERNAME}) AUTHENTICATES. The pipeline will run as THAT identity."
      log_warn "  scope: this proves the credential is accepted (HTTP 200/403), NOT that it may PUSH."
      log_warn "  'make mirror' performs the first real push and is where a permissions fault surfaces."
      exit 0 ;;
    rejected)
      die "harbor-robot: ${why}, but Harbor REJECTED that credential (HTTP 401).
       A robot secret is shown ONCE and cannot be read back, so there is nothing to recover locally.
       Refresh it in the Harbor UI (Administration -> Robot Accounts -> Refresh Secret) and put the new
       value in .env as HARBOR_USERNAME/HARBOR_PASSWORD, or ask whoever minted it. If you are a TENANT,
       this is a REQUEST to your platform team — there is no self-service path (see docs/scenario-2.md)." ;;
    unchecked:no*)
      # F2 (implementation round): "we could not ASK" is NOT "the probe failed". _harbor_ca_args
      # (lib/harbor.sh:204) refuses whenever there is neither HARBOR_CA_FILE nor HARBOR_INSECURE=1 —
      # and docs/scenario-2.md:466 tells a tenant with a publicly-trusted Harbor cert to leave
      # HARBOR_CA_FILE EMPTY. MEASURED: in that state harbor_setup returns 0, curl uses the system
      # store, every real API call works, and only the verdict declares itself blind. Dying here would
      # hard-stop `install-all` for that tenant on EVERY run, quoting "Step 8 fetches it" — the step
      # their own doc told them to skip. That is the RULE ZERO-B hard-stop this script's two-projects
      # branch already refuses to make.
      # This also aligns with the repo's settled policy for the SAME verdict on an install path:
      # harbor_credential_settle (lib/harbor.sh:319-337) warns and returns 0, commenting "An error
      # naming the wrong cause is worse than none." Two sites, one verdict — now one policy.
      log_warn "harbor-robot: ${why}, and the credential could not be CHECKED (${v#unchecked:})."
      log_warn "  That is NOT a verdict — nothing was sent to Harbor. Continuing with what is in .env."
      log_warn "  If your Harbor's certificate is publicly trusted this is EXPECTED (scenario-2 Step 2)."
      exit 0 ;;
    *)
      # A probe that RAN and did not complete still stops: that is evidence, not absence of evidence.
      die "harbor-robot: ${why}, but the credential probe did not complete: ${v#unchecked:}.
       Continuing would bake an unverified credential into the pipeline's push Secret and the
       workload's pull Secret. Resolve the reason above and re-run." ;;
  esac
}

# ⚠️ F1 (implementation round, 2026-09-05) — CRITICAL: NEVER RUN THIS WHERE .env IS IGNORED.
# `make e2e-kind` runs `install-all` with SKIP_DOTENV=1 (Makefile:203 E2E_SKIP_DOTENV ?= 1, exported
# at :902 and inherited by the sub-make). On a Harbor with no robot yet, this script would MINT one
# and then call env_publish_all (:289), which writes .env — IGNORED under SKIP_DOTENV — *and*
# state_unset s both keys from .env.state, THE ONLY SINK THAT RUN READS. MEASURED with the real
# env_publish_all: it returns 0 and logs success (assert_env_effective re-reads with SKIP_DOTENV=0,
# finds the value in .env, warns and returns 0), then the very next target resolves
# USER=<UNSET> PASS=<UNSET> and 60-configure-tekton.sh:21 dies "set HARBOR_USERNAME in .env" on a box
# whose .env contains it. And it is STICKY: the NEXT e2e-kind dies in 05-kind-up.sh:177-185 ("the
# sink has lost it"), recoverable only by tearing the cluster down.
#
# It is invisible on a warm box: a Harbor that already holds the robot takes the 409 -> skip path and
# never publishes. The break is on the FIRST run after kind-down / E2E_FRESH=1 — i.e. CI-shaped runs
# and everyone else's box. Doing nothing here restores EXACTLY the pre-change behaviour (install-all
# had no robot step at all), so it cannot regress the e2e.
if ensure_mode && [ "${SKIP_DOTENV:-0}" = 1 ]; then
  log_warn "harbor-robot: SKIP_DOTENV=1 — .env is IGNORED by this run, so publishing a robot would"
  log_warn "  CLEAR the state overlay (the only credential sink here) and strand HARBOR_USERNAME/"
  log_warn "  HARBOR_PASSWORD for every later step. Leaving the existing credential in place."
  log_warn "  Run 'make harbor-robot' on a box with a .env to mint one."
  exit 0
fi

if harbor_username_is_robot; then
  if ensure_mode; then
    # F3 (implementation round): harbor_setup is needed here to NORMALIZE HARBOR_URL (lib/harbor.sh:20
    # strips a scheme and a trailing slash). Without it, HARBOR_URL=https://harbor... yields
    # https://https://harbor... -> curl error 6 -> code 000 -> unchecked -> die. The verdict itself
    # reads NONE of harbor_setup's globals (measured) — so do not delete this call as dead weight.
    HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
    harbor_setup "$HARBOR_TMP"
    ensure_skip_if_credential_works "HARBOR_USERNAME is already the robot '${HARBOR_USERNAME}'"
  fi
  die "HARBOR_USERNAME is '${HARBOR_USERNAME}', a ROBOT — and a robot cannot mint robots.
       This is the credential Step 9 told you to save, so this is the expected state after a first run.
       Set HARBOR_USERNAME/HARBOR_PASSWORD back to the Harbor ADMIN for this one command."
fi

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
  # ensure mode: this is not an error, it is "we cannot self-service least-privilege HERE".
  # MEASURED: .env.example:138,148 ship HARBOR_INFRA_PROJECT=cicd and HARBOR_APP_PROJECT=apps —
  # two DISTINCT projects — so a project-admin tenant reaches this branch ON DEFAULT SETTINGS.
  # Today that tenant CAN run install-all (they push with their own credential; 22-selfbuilt-push.sh
  # and 21-mirror-push.sh already tolerate a 403 from ensure_project). Dying here would hard-stop
  # the one command scenario-2 tells them to run, on a step they never asked for. RULE ZERO-B.
  if ensure_mode; then
    log_warn "harbor-robot: CONTINUING WITHOUT A ROBOT — the guidance above applies, but this is not"
    log_warn "  fatal to the install. The pipeline will authenticate as '${HARBOR_USERNAME}' instead of a"
    log_warn "  least-privilege robot. Run 'make harbor-robot' (strict) once you can act on option 1 or 2."
    exit 0
  fi
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
    409)
      # MEASURED (walk evidence, 2026-08-28 certified run): matrix rows 2/4/5/6 land here — the robot
      # was minted by row 1/3 on the SAME cut, and walk-matrix.sh DELIBERATELY excludes gitignored
      # secrets/ from the box (:733), carrying back only vks.kubeconfig and harbor-ca.crt. So the
      # secret file is absent BY CONSTRUCTION and the old code died. Those four rows are certified
      # green today only because walk-doc.sh:140 skips the DOCUMENTED `make harbor-robot` line — a
      # skip it cannot apply to a step buried inside `install-all`.
      if ensure_mode; then ensure_skip_if_credential_works "robot '${ROBOT_NAME}' already exists in Harbor"; fi
      die "$(robot_exists_message)" ;;
  esac
  case "$msg" in
    *conflict*|*exists*|*already*)
      if ensure_mode; then ensure_skip_if_credential_works "robot '${ROBOT_NAME}' already exists in Harbor"; fi
      die "$(robot_exists_message)" ;;
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
