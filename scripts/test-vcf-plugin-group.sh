#!/usr/bin/env bash
# ci-tier: fast — OFFLINE. A stand-in `vcf` that records what it was given; nothing is dialled.
#
# test-vcf-plugin-group.sh — every `vcf` this repo runs is told which "essentials" plugin group to
# install (VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION), from ONE place: .env.example.
#
# THE DEFECT. MEASURED on a lab: a vcf v9.1.1 CLI left to itself asks for essentials group v9.0.2,
# whose `telemetry` plugin is not published. Every `vcf` command (each `make vks-login`, each
# `make creds-renew`) printed "[!] unable to install plugin 'telemetry' …" and tried again next
# time. The CLI reads the group from this variable; nothing set it.
#
# WHAT IS PINNED:
#   1. load_env exports the variable with .env.example's value when nothing else sets it
#   2. a value in the operator's .env wins (it is a lab pin: it follows the CLI they hold), and a
#      PIN_OVERRIDE wins for one run
#   3. a program started after load_env (the stand-in vcf) SEES it: default, .env, override
#   4. every script that runs the `vcf` program does so after load_env — derived by grep, so a
#      new script that runs vcf bare fails here
#   5. the value is written in .env.example and NOWHERE in scripts/ or the Makefile
#
# DOES NOT PROVE: that the real vcf CLI honours the variable (READ: the name is in the v9.1.1
# binary; MEASURED on a lab by the owner, not here), what a v9.0.x CLI does with v9.1.1, or
# anything about a `vcf` typed by hand in the operator's own shell.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$REPO_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
# Each case states its own inputs: a caller's SKIP_DOTENV would hide the sandbox .env, and a
# value of the variable itself in the caller's environment is exactly what is under test.
unset SKIP_DOTENV PIN_OVERRIDE VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION _VKS_BOUNDS_REPORTED

LIB_OS="${REPO}/scripts/lib/os.sh"
KEY=VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

# THE DEFAULT IS READ FROM .env.example, NOT TYPED HERE: this file must not become a second home
# for the value. It only has to LOOK like a group version.
DEFAULT="$(command grep -E "^${KEY}=" "${REPO}/.env.example" | head -1 | cut -d= -f2-)"
if [[ "$DEFAULT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok ".env.example ships ${KEY} uncommented, as a group version (${DEFAULT})"
else bad ".env.example does not ship ${KEY} as an active vN.N.N value" "found '${DEFAULT}'"; fi
if [ "$(command grep -B1 -E "^${KEY}=" "${REPO}/.env.example" | head -1)" = '# pin: lab' ]; then ok "it is marked a LAB pin (it follows the CLI the operator holds, so their .env wins)"
else bad "${KEY} is not under a '# pin: lab' marker" "$(command grep -B1 -E "^${KEY}=" "${REPO}/.env.example" | head -1)"; fi

# A stand-in vcf: records its arguments and the variable as IT sees it.
mkdir -p "$T/bin" "$T/root"
# The stub's own "$*" is written literally (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "vcf %%s | group=[%%s]\\n" "$*" "${%s-UNSET}" >> "%s"\nexit 0\n' "$KEY" "$T/vcf.log" > "$T/bin/vcf"
chmod +x "$T/bin/vcf"
cp "${REPO}/.env.example" "$T/root/.env.example"
# run_after_load_env [VAR=value …] : a script that calls load_env and then runs vcf, the way every
# script in this repo does. Prints what the stand-in saw.
run_after_load_env() {
  : > "$T/vcf.log"
  # The child expands its own "$1" (SC2016 is deliberate).
  # shellcheck disable=SC2016
  env -u KUBECONFIG -u "$KEY" "$@" PATH="$T/bin:$PATH" REPO_ROOT="$T/root" VKS_STATE_FILE="$T/root/.env.state" \
    bash -c '. "$1"; load_env; vcf context list' _ "$LIB_OS" >/dev/null 2>"$T/err"
  sed -n 's/.*group=\[\(.*\)\]$/\1/p' "$T/vcf.log" | head -1
}
rm -f "$T/root/.env"
got="$(run_after_load_env)"
if [ "$got" = "$DEFAULT" ]; then ok "with nothing set anywhere, vcf is started with ${KEY}=${DEFAULT} (.env.example's value, exported by load_env)"
else bad "vcf did not get the default" "saw '${got}', wanted '${DEFAULT}'"; fi
printf '%s=v0.0.1\n' "$KEY" > "$T/root/.env"
got="$(run_after_load_env)"
if [ "$got" = v0.0.1 ]; then ok "a value in the operator's .env wins (v0.0.1)"
else bad "the operator's .env value did not reach vcf" "saw '${got}'"; fi
got="$(run_after_load_env PIN_OVERRIDE="${KEY}=v0.0.2")"
if [ "$got" = v0.0.2 ]; then ok "PIN_OVERRIDE wins for one run, over .env (v0.0.2)"
else bad "PIN_OVERRIDE did not reach vcf" "saw '${got}'; stderr: $(head -1 "$T/err" | cut -c1-120)"; fi
rm -f "$T/root/.env"
# TYPED IN FRONT OF A COMMAND, the value loses to the files like every lab pin. That is SAID, in
# one line naming both values and the way to do it for one run; a script started from there
# re-reads the files and says nothing again.
got="$(run_after_load_env "${KEY}=v0.0.9")"
if [ "$got" = "$DEFAULT" ] && [ "$(command grep -c "${KEY}=v0.0.9 from the environment is NOT used" "$T/err")" = 1 ] \
   && command grep -q "${DEFAULT} from .env.example" "$T/err" && command grep -q "PIN_OVERRIDE='${KEY}=v0.0.9'" "$T/err"; then
  ok "a value typed in front of the command loses to .env.example, and ONE line says which value is used and how to override for one run"
else bad "a typed value that lost was replaced without a word (or did not lose)" "vcf saw '${got}'; lines: $(command grep -c 'is NOT used' "$T/err")"; fi
# shellcheck disable=SC2016
env -u KUBECONFIG "${KEY}=v0.0.9" PATH="$T/bin:$PATH" REPO_ROOT="$T/root" VKS_STATE_FILE="$T/root/.env.state" \
  bash -c '. "$1"; load_env; bash -c ". \"\$1\"; load_env; load_env" _ "$1"' _ "$LIB_OS" >/dev/null 2>"$T/err"
if [ "$(command grep -c 'is NOT used' "$T/err")" = 1 ]; then ok "  ...once for the process tree: a script started from there, and a second load_env, add no second line"
else bad "the lost-override line was repeated (or never printed) across a process tree" "$(command grep -c 'is NOT used' "$T/err") line(s)"; fi
got="$(run_after_load_env "${KEY}=${DEFAULT}")"
if [ "$got" = "$DEFAULT" ] && ! command grep -q 'is NOT used' "$T/err"; then ok "  ...and nothing is said when the typed value IS the one in use"
else bad "the lost-override line was printed for a value that did not lose" "$(command grep 'is NOT used' "$T/err" | head -1 | cut -c1-140)"; fi
got="$(run_after_load_env "${KEY}=v0.0.9" PIN_OVERRIDE="${KEY}=v0.0.2")"
if [ "$got" = v0.0.2 ] && ! command grep -q 'is NOT used' "$T/err" && command grep -q 'PIN_OVERRIDE in effect' "$T/err"; then ok "  ...and with a PIN_OVERRIDE for it, the override's own line is the only one"
else bad "a PIN_OVERRIDE and a typed value: the wrong line was printed" "vcf saw '${got}'; $(command grep -c 'is NOT used' "$T/err") lost-override line(s)"; fi
# Without load_env the variable is NOT there: this is the control that makes case 4 matter.
: > "$T/vcf.log"; env -u "$KEY" PATH="$T/bin:$PATH" vcf context list
if command grep -q 'group=\[UNSET\]' "$T/vcf.log"; then ok "control: a vcf run WITHOUT load_env does not get the variable (so every caller must load_env first)"
else bad "control: the stand-in saw the variable without load_env" "$(cat "$T/vcf.log")"; fi

# EVERY SCRIPT THAT RUNS THE vcf PROGRAM DOES SO AFTER load_env. "Runs vcf" = the word `vcf`, or a
# variable holding its path, in command position before one of its subcommands. Comment lines
# and lines that only PRINT a vcf command for the reader are left out.
# What this cannot see: a script that runs vcf through a wrapper defined elsewhere, and a vcf
# call reached by `make <target>` from a script (that target's own script is in the list itself).
# The pattern spells a shell variable literally (SC2016 is deliberate).
# shellcheck disable=SC2016
RUNS='(^|[;&|(]|[[:space:]])(run |_vcf_run )?("\$(vcf_bin|\{vcf_bin\})"|vcf)[[:space:]]+(context|plugin|version)\b'
callers=""; n_callers=0; bare=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hits="$(command grep -nE -- "$RUNS" "$f" | command grep -vE '^[0-9]+:[[:space:]]*#' \
            | command grep -vE '^[0-9]+:[[:space:]]*(log_[a-z]+|echo|printf|die)[[:space:]]' \
            | command grep -vE "KUBECONFIG='[^']*' vcf context list" || true)"
  [ -n "$hits" ] || continue
  n_callers=$((n_callers + 1)); callers="${callers} ${f##*/}"
  first_vcf="$(head -1 <<< "$hits" | cut -d: -f1)"
  first_env="$(command grep -nE '^[[:space:]]*(\(?[[:space:]]*)?load_env([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)"
  if [ -z "$first_env" ] || [ "$first_env" -gt "$first_vcf" ]; then bare="${bare} ${f##*/}:${first_vcf}"; fi
done < <(find "${REPO}/scripts" -maxdepth 1 -name '*.sh' ! -name 'test-*.sh' | sort)
if [ -z "$bare" ] && [ "$n_callers" -ge 4 ]; then
  ok "all ${n_callers} scripts that run the vcf program call load_env before their first vcf command (${callers# })"
else
  bad "a script runs vcf before (or without) load_env, so that vcf does not get the plugin group" "scripts found: ${n_callers} (${callers# }); bare: ${bare:- none}"
fi
# Library functions that run vcf (lib/os.sh) are called only from scripts; state which they are,
# so a new one is seen: each must be reachable only after its caller's load_env.
lib_vcf="$(command grep -cE -- "$RUNS" "$LIB_OS" || true)"
if [ "${lib_vcf:-0}" -ge 1 ] && [ "${lib_vcf:-0}" -le 3 ]; then ok "lib/os.sh runs vcf at ${lib_vcf} place(s), inside helpers its callers reach after load_env (a change in that count is a prompt to re-check)"
else bad "the number of vcf calls in lib/os.sh changed" "found ${lib_vcf}; re-check that each is reached only after load_env, then update this bound"; fi

# THE VALUE HAS ONE HOME. No script and no Makefile line assigns the variable or carries the
# default: a second copy would be the one that is forgotten at the next CLI bump.
second="$(command grep -rnE -- "${KEY}[[:space:]]*[:?]?=" "${REPO}/scripts" "${REPO}/Makefile" 2>/dev/null \
            | command grep -vE '/scripts/test-[^/]*\.sh:' | command grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
if [ -z "$second" ]; then ok "${KEY} is assigned nowhere under scripts/ or in the Makefile: .env.example is its one home"
else bad "${KEY} is assigned outside .env.example" "$(printf '%s' "$second" | sed "s#${REPO}/##" | head -3 | cut -c1-160)"; fi

printf '\ntest-vcf-plugin-group: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-vcf-plugin-group: OK\n'
