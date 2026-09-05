#!/usr/bin/env bash
# shellcheck disable=SC2016  # the mutation strings are single-quoted ON PURPOSE: $APP_DIR must
# expand in the CHILD, after fresh() has created that case's sandbox — not when this file is parsed.
# ci-tier: fast — offline; builds a throwaway tree per case, no network, no cluster, no containers.
#
# RED-proofs for scripts/check-sigterm.sh. Every case below is a bypass an adversary MEASURED
# against the gate's first version — it returned rc=0, green, on all six. A gate that is green over
# the bug it names is worse than no gate: it makes people stop looking.
#
# The control comes FIRST: if the unmutated tree does not go GREEN, every RED below is meaningless
# (a gate that fails on everything "catches" everything).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
load_env
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A throwaway copy of the repo (tracked files only) that the gate can run against.
fresh() {
  local d="${T}/t$$-$RANDOM"
  git -C "$REPO_ROOT" archive HEAD > "${T}/tree.tar" || { echo "git archive FAILED"; exit 1; }
  mkdir -p "$d" || { echo "mkdir FAILED"; exit 1; }
  tar -xf "${T}/tree.tar" -C "$d" || { echo "tar extract FAILED"; exit 1; }
  # Overlay the WORKING TREE's gate + lib, so we test what is on disk, not what is committed.
  cp "${REPO_ROOT}/scripts/check-sigterm.sh" "${d}/scripts/check-sigterm.sh"
  cp "${REPO_ROOT}/scripts/lib/apps.sh"      "${d}/scripts/lib/apps.sh"
  # .env is gitignored, so git archive omits it and load_env would die on unbound vars.
  [ -f "${REPO_ROOT}/.env" ] && cp "${REPO_ROOT}/.env" "${d}/.env"
  # ASSERT the sandbox: a partial extract exits 0 and every case below then "passes".
  [ -s "${d}/scripts/check-sigterm.sh" ] && [ -s "${d}/apps/registry.tsv" ] \
    || { echo "HARNESS BROKEN — the sandbox is incomplete; this is NOT a gate finding"; exit 1; }
  printf '%s' "$d"
}
# ⚠️ PIN REPO_ROOT FOR THE CHILD. This script exports REPO_ROOT (lib/apps.sh needs it), and
# lib/os.sh skips recomputing it when it is already set — so without this the gate running INSIDE
# the sandbox scanned the REAL repo and every mutation below "passed". Measured: 7 of 7 false
# GREENs, including a case already RED-proven by hand.
run_gate() { ( cd "$1" && REPO_ROOT="$1" ./scripts/check-sigterm.sh >/dev/null 2>&1 ); }

# Derive the apps from the registry — a shared file must never name one (check-app-hardcodes).
JAVA_APP=""; NODE_APP=""; PY_APP=""
for a in $(app_names); do
  case "$(app_lang "$a")" in
    java)   [ -z "$JAVA_APP" ] && JAVA_APP="$a" ;;
    nodejs) [ -z "$NODE_APP" ] && NODE_APP="$a" ;;
    python) [ -z "$PY_APP"   ] && PY_APP="$a"   ;;
  esac
done

echo "== CONTROL: the real tree must be GREEN (else every RED below means nothing) =="
d="$(fresh)"
if run_gate "$d"; then ok "control: unmutated tree is GREEN"; else bad "control: unmutated tree is RED — fix that first"; fi

red() {  # red <label> <app> <mutation-shell>
  local label="$1" app="$2" mut="$3" dd
  dd="$(fresh)"
  APP_DIR="${dd}/$(app_src "$app")"
  export APP_DIR
  if ( cd "$dd" && eval "$mut" ) >/dev/null 2>&1; then
    if run_gate "$dd"; then bad "RED: ${label} — gate stayed GREEN over the bug"; else ok "RED: ${label}"; fi
  else
    bad "RED: ${label} — the MUTATION itself failed to apply (harness, not gate)"
  fi
  unset APP_DIR
}

echo "== the six MEASURED bypasses of the gate's first version =="
red "shell-form ENTRYPOINT (docker wraps it in sh -c)" "$JAVA_APP" \
  'sed -i "s@^ENTRYPOINT .*@ENTRYPOINT java -jar /app/app.jar@" "$APP_DIR/Dockerfile"'
red "wrapper-script ENTRYPOINT, no exec"              "$JAVA_APP" \
  'sed -i "s@^ENTRYPOINT .*@ENTRYPOINT [\"/entrypoint.sh\"]@" "$APP_DIR/Dockerfile"'
red "sh -lc instead of sh -c"                          "$JAVA_APP" \
  'sed -i "s@^ENTRYPOINT .*@ENTRYPOINT [\"sh\", \"-lc\", \"java -jar /app/app.jar\"]@" "$APP_DIR/Dockerfile"'
red "exec lives in the HEALTHCHECK, not the ENTRYPOINT" "$JAVA_APP" \
  'sed -i "s@^ENTRYPOINT .*@ENTRYPOINT [\"sh\", \"-c\", \"java -jar /app/app.jar\"]@" "$APP_DIR/Dockerfile"
   printf "\nHEALTHCHECK CMD [\"sh\",\"-c\",\"exec wget -qO- http://127.0.0.1:8080/healthz\"]\n" >> "$APP_DIR/Dockerfile"'
red "handler COMMENTED OUT (pattern matched the comment)" "$NODE_APP" \
  'sed -i "s@^\( *\)for (const sig of@\1// for (const sig of@" "$APP_DIR/server.js"
   sed -i "s@^\( *\)process\.on(sig@\1// process.on(sig@"      "$APP_DIR/server.js"'
red "ENTRYPOINT never runs the file the handler is in"  "$PY_APP" \
  'sed -i "s@^ENTRYPOINT .*@ENTRYPOINT [\"gunicorn\", \"-b\", \"0.0.0.0:8080\", \"app:app\"]@" "$APP_DIR/Dockerfile"'

echo "== and it must still catch the ORIGINAL bug =="
red "no SIGTERM handler at all (the pre-fix state)"     "$PY_APP" \
  'sed -i "/signal\.signal(signal\.SIGTERM/d; /signal\.signal(signal\.SIGINT/d" "$APP_DIR/app.py"'

printf '\ntest-sigterm-gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
