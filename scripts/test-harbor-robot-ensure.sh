#!/usr/bin/env bash
# Offline RED/GREEN for 22-harbor-robot.sh's ENSURE mode (harbor_robot_ensure=1), the variant
# `make install-all` runs. Stubs the libs in a throwaway dir and executes the REAL script; touches
# no Harbor.
#
# WHY THIS FILE EXISTS. An implementation-round adversary observed that `make static-check` was
# green (121 tests) while NONE of those tests executes 22-harbor-robot.sh — so ensure mode shipped
# with zero coverage, and its CRITICAL defect (case F1 below) was invisible to every gate.
#
# THE DISCRIMINATING CASE IS F1, NOT THE HAPPY PATH. `make e2e-kind` runs `install-all` with
# SKIP_DOTENV=1, where .env is IGNORED: minting there calls env_publish_all, which state_unsets both
# credential keys from .env.state — the only sink that run reads — and returns 0 while logging
# success. The break lands two targets later, and only on a COLD Harbor; a warm one takes the
# 409->skip path and never publishes. So a local green proves nothing about it.
# ci-tier: fast — offline; stubs every lib in a mktemp dir, no network, no Harbor, no cluster.
# shellcheck disable=SC2016
#   The single quotes are the POINT. A Harbor robot login name is literally `robot$vks-cicd`, and
#   `$vks` must NOT expand — expanding it is exactly the bug harbor_username_is_robot's `case` guards.
#   The verdict strings (`unchecked:no CA yet (Step 8 fetches it) ...`) are likewise literals copied
#   verbatim from lib/harbor.sh, so the case arms are tested against the real text.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lib" "$T/secrets"
cp "$SCRIPT_DIR/22-harbor-robot.sh" "$T/"

cat > "$T/lib/os.sh" <<'STUB'
log_info(){ printf 'INFO %s\n' "$*"; }
log_warn(){ printf 'WARN %s\n' "$*"; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
die(){ printf 'DIE %s\n' "$*" >&2; exit 1; }
# ⚠️ THE PROJECT VARS ARE SUPPLIED HERE, NOT ON THE COMMAND LINE. Passing
# `HARBOR_INFRA_PROJECT=cicd` to the sim made check-env-clobber flag a PER-RUN OVERRIDE of a var
# that is UNCOMMENTED in .env.example — correctly, by its own rule, because that shape loses to
# `set -a` in the real product. This sim's load_env is a no-op stub so no clobber can occur, but a
# gate should not have to know that. Supplying them from load_env is also more faithful: that is
# where the real script gets them.
load_env(){ HARBOR_INFRA_PROJECT="${SIM_INFRA_PROJECT:-cicd}"; HARBOR_APP_PROJECT="${SIM_APP_PROJECT:-apps}"; }
require_cmd(){ :; }
esc_curlk(){ printf '%s' "${1:-}"; }
ensure_secret_dir(){ mkdir -p "${1:-.}"; }
set_env_var(){ printf 'set_env_var %s\n' "$1"; }
state_unset(){ printf 'STATE_UNSET %s\n' "$1" >> "${PROBE_LOG:-/dev/null}"; }
env_publish_all(){ printf 'ENV_PUBLISH_ALL\n' >> "${PROBE_LOG:-/dev/null}"; }
env_publish(){ printf 'ENV_PUBLISH %s\n' "$1" >> "${PROBE_LOG:-/dev/null}"; }
assert_env_effective(){ :; }
STUB

# ⚠️ tls.sh IS SOURCED TOO (22-harbor-robot.sh:18). My first draft omitted it and EVERY case that
# expected exit 0 failed while every case expecting exit 1 "passed" — the script was dying at line 18
# with "lib/tls.sh: No such file or directory", so the 1s were right for the wrong reason. That
# asymmetry (all the 0-expecting cases fail, all the 1-expecting cases pass) is the signature of a
# harness that never reaches the code under test. The instrument, not the product.
cat > "$T/lib/tls.sh" <<'STUB'
ca_bundle_with_system(){ :; }
STUB

cat > "$T/lib/harbor.sh" <<'STUB'
harbor_setup(){ :; }
ensure_project(){ :; }
harbor_last_code(){ printf '%s' "${STUB_CODE:-201}"; }
harbor_is_sysadmin(){ return "${STUB_SYSADMIN_RC:-0}"; }
harbor_auth_verdict(){ printf '%s' "${STUB_VERDICT:-accepted}"; }
harbor_username_is_robot(){ case "${HARBOR_USERNAME:-}" in 'robot$'*) return 0;; *) return 1;; esac; }
harbor_api_body(){
  if [ "${STUB_CODE:-201}" = 201 ]; then printf '{"name":"robot$vks-cicd","secret":"s3cr3t"}';
  else printf '{"errors":[{"message":"conflict"}]}'; fi
}
STUB

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

run() { # run <env assignments...> -- captures rc and output
  rc=0
  out="$(cd "$T" && env HARBOR_URL=https://h.example HARBOR_PASSWORD=pw \
        "$@" bash "$T/22-harbor-robot.sh" 2>&1)" || rc=$?
}

# ── F1 (the discriminating case): ensure + SKIP_DOTENV=1 must NOT publish ──────────────────────────
: > "$T/probe.log"
run harbor_robot_ensure=1 SKIP_DOTENV=1 HARBOR_USERNAME=admin STUB_CODE=201 PROBE_LOG="$T/probe.log"
ck "F1 ensure+SKIP_DOTENV -> exit 0" "$rc" "0"
ck "F1 ensure+SKIP_DOTENV -> nothing published (this is the CRITICAL)" \
   "$(grep -c 'ENV_PUBLISH\|STATE_UNSET' "$T/probe.log" || true)" "0"
case "$out" in *"SKIP_DOTENV=1"*) ck "F1 says WHY it skipped" yes yes ;;
                *) ck "F1 says WHY it skipped" no yes ;; esac

# STRICT mode under SKIP_DOTENV is unaffected: the operator asked for a robot.
: > "$T/probe.log"
run SKIP_DOTENV=1 HARBOR_USERNAME=admin STUB_CODE=201 PROBE_LOG="$T/probe.log"
ck "strict+SKIP_DOTENV still mints (the guard is ensure-only)" \
   "$(grep -c ENV_PUBLISH_ALL "$T/probe.log" || true)" "1"

# ── case (a): HARBOR_USERNAME is already the robot ─────────────────────────────────────────────────
run harbor_robot_ensure=1 'HARBOR_USERNAME=robot$vks-cicd' STUB_VERDICT=accepted
ck "ensure + already-robot + accepted -> exit 0" "$rc" "0"
run harbor_robot_ensure=1 'HARBOR_USERNAME=robot$vks-cicd' STUB_VERDICT=rejected
ck "ensure + already-robot + rejected -> exit 1" "$rc" "1"
# F2: "could not ASK" is not "the probe failed" — the documented publicly-trusted-cert tenant.
run harbor_robot_ensure=1 'HARBOR_USERNAME=robot$vks-cicd' \
    'STUB_VERDICT=unchecked:no CA yet (Step 8 fetches it) and HARBOR_INSECURE is not 1'
ck "F2 ensure + unchecked:no-CA -> exit 0 (documented tenant state)" "$rc" "0"
run harbor_robot_ensure=1 'HARBOR_USERNAME=robot$vks-cicd' 'STUB_VERDICT=unchecked:the probe did not complete'
ck "F2 ensure + unchecked:probe-failed -> exit 1 (evidence, not absence)" "$rc" "1"
# strict must still refuse, or ensure mode leaked into the operator-facing target
run 'HARBOR_USERNAME=robot$vks-cicd' STUB_VERDICT=accepted
ck "strict + already-robot -> exit 1 (ensure did not leak)" "$rc" "1"

# ── 409 / already exists ───────────────────────────────────────────────────────────────────────────
run harbor_robot_ensure=1 HARBOR_USERNAME=admin STUB_CODE=409 STUB_VERDICT=accepted
ck "ensure + 409 + accepted -> exit 0 (matrix rows 2/4/5/6)" "$rc" "0"
case "$out" in *"(admin) AUTHENTICATES"*) ck "F4 409 skip NAMES the identity" yes yes ;;
                *) ck "F4 409 skip NAMES the identity" no yes ;; esac
run harbor_robot_ensure=1 HARBOR_USERNAME=admin STUB_CODE=409 STUB_VERDICT=rejected
ck "ensure + 409 + rejected -> exit 1" "$rc" "1"
run HARBOR_USERNAME=admin STUB_CODE=409
ck "strict + 409 -> exit 1" "$rc" "1"

# ── two projects without sysadmin ──────────────────────────────────────────────────────────────────
run harbor_robot_ensure=1 HARBOR_USERNAME=tenant STUB_SYSADMIN_RC=1
ck "ensure + two projects, no sysadmin -> exit 0 (RULE ZERO-B)" "$rc" "0"
run HARBOR_USERNAME=tenant STUB_SYSADMIN_RC=1
ck "strict + two projects, no sysadmin -> exit 1" "$rc" "1"

printf '\ntest-harbor-robot-ensure: %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
