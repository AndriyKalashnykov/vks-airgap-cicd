#!/usr/bin/env bash
# test-env-file-mode.sh — every writer of the DURABLE credential store must land 0600.
#
# WHY: `.env` and `.env.state` hold HARBOR_PASSWORD, GITEA_ADMIN_PASSWORD, ARGOCD_ADMIN_PASSWORD and
# — hand-edited per docs/scenario-1.md — VCENTER_PASSWORD, the vSphere SSO administrator credential.
# Their mode used to come from the ambient umask and was never repaired.
#
# ⚠️ THE DECISIVE CELL IS umask 077 OVER A PRE-EXISTING 0644 FILE. It still yields 0644, because a
# umask only applies at CREATION. That is why the fix is an explicit `chmod`, and why a future "fix"
# that replaces the chmod with a umask goes RED here and ONLY here. This repo documents that exact
# trap twice already (22-harbor-robot.sh, lib/vcenter.sh) — both protecting a TRANSIENT copy, while
# the DURABLE store they read the credential out of went unswept.
#
# ⚠️ AND THE FILE IS BORN LOOSE BY A DIFFERENT FUNCTION. `env_init` does `cp .env.example .env`, so
# hardening the writer alone leaves a window from Step 2 (the hand-edited VCENTER_PASSWORD) to the
# first hardening writer at Step ~5 — permanently if the walk diverges. Case group 3 covers that.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

# ---- 1. the 18-cell writer matrix -----------------------------------------------------------------
# A `$`-bearing value on purpose: a chmod regression must not be "fixable" by breaking the writer,
# and this repo has a whole gate (check-doc-robot-quoting) about that exact shape.
# shellcheck disable=SC2016  # deliberate: $1 must stay LITERAL — it is the payload
SECRET='P@ssw0rd$1x'
cells=0; badcells=""
for um in 022 002 077; do
  for pre in none 600 644 664 666 400; do
    d="$(mktemp -d)"
    [ "$pre" = none ] || { : > "$d/.env"; chmod "$pre" "$d/.env"; }
    ( umask "$um"; cd "$REPO" || exit 1
      SKIP_DOTENV=1 T_SINK="$d/.env" T_SECRET="$SECRET" bash -c '
        . scripts/lib/os.sh >/dev/null 2>&1
        set_env_var OTHER_KEY keepme "$T_SINK"
        set_env_var HARBOR_PASSWORD "$T_SECRET" "$T_SINK"' >/dev/null 2>&1 )
    m="$(stat -c %a "$d/.env" 2>/dev/null || echo MISSING)"
    # a value round-trip, not just a mode: `set -a; .` is how load_env and the docs read this file
    rt="$( cd "$d" && set -a; . ./.env >/dev/null 2>&1; set +a; printf '%s' "${HARBOR_PASSWORD:-}" )"
    cells=$((cells+1))
    [ "$m" = 600 ] || badcells="$badcells umask=$um/pre=$pre:$m"
    [ "$rt" = "$SECRET" ] || badcells="$badcells umask=$um/pre=$pre:VALUE($rt)"
    rm -rf "$d"
  done
done
if [ -z "$badcells" ]; then ok "writer matrix: all $cells cells land 0600 AND the \$-bearing value round-trips"
else bad "writer matrix: $cells cells, failures:$badcells" "the umask-077-over-0644 cell is the one no umask can fix"; fi

# ---- 2. the state overlay -------------------------------------------------------------------------
d="$(mktemp -d)"; : > "$d/.env.state"; chmod 644 "$d/.env.state"
( cd "$REPO" || exit 1; SKIP_DOTENV=1 VKS_STATE_FILE="$d/.env.state" bash -c \
    '. scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1
     state_set A 1; state_set B 2' >/dev/null 2>&1 )
m="$(stat -c %a "$d/.env.state" 2>/dev/null || echo MISSING)"
if [ "$m" = 600 ]; then ok "state_set into a pre-existing 0644 overlay -> 600"
else bad "state_set left the overlay at $m" "state.sh wraps set_env_var in ( umask 077 ), which is create-only"; fi
# state_unset is the ONE place that creates a fresh inode (mv), i.e. the one chance to repair a mode.
( cd "$REPO" || exit 1; SKIP_DOTENV=1 VKS_STATE_FILE="$d/.env.state" bash -c \
    '. scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/state.sh >/dev/null 2>&1; state_unset A' >/dev/null 2>&1 )
m="$(stat -c %a "$d/.env.state" 2>/dev/null || echo MISSING)"
if [ "$m" = 600 ]; then ok "state_unset -> 600 (it no longer PROPAGATES the sink's mode onto a new inode)"
else bad "state_unset produced $m" "chmod --reference copies the CURRENT mode, carrying the defect forward"; fi
rm -rf "$d"

# ---- 3. THE DOCUMENTED FLOW — the case hardening the writer alone does NOT cover ------------------
# Force .env.example loose, so the assertion is about env_init and not about this box's umask.
d="$(mktemp -d)"
cp "$REPO/.env.example" "$d/.env.example"; chmod 664 "$d/.env.example"
# 02-env.sh is a DISPATCHER, not a library: `case "${1:-}" in init) env_init ;;`. Sourcing it runs the
# case with no argument and defines nothing callable — my first attempt did that and produced no .env
# at all, which the assertion correctly refused to read as a pass. Invoke it the way the Makefile does.
( umask 002; cd "$d" || exit 1
  SKIP_DOTENV=1 REPO_ROOT="$d" ENV_FILE="$d/.env" EXAMPLE_FILE="$d/.env.example" \
    bash "$REPO/scripts/02-env.sh" init >/dev/null 2>&1 )
m="$(stat -c %a "$d/.env" 2>/dev/null || echo MISSING)"
if [ "$m" = 600 ]; then ok "env_init: a fresh .env is 0600 even from a 0664 .env.example under umask 002"
elif [ "$m" = MISSING ]; then bad "env_init did not produce a .env" "the harness could not drive it; fix the harness before believing this"
else bad "env_init produced $m" "this is the window in which a HAND-EDITED VCENTER_PASSWORD sits world-readable"; fi
rm -rf "$d"

# ---- 4. MUST NOT CHANGE ---------------------------------------------------------------------------
# A 0600 CA is UNREADABLE by the jump-box container's uid — jumpbox-launch.sh says so verbatim. A fix
# that tightens these breaks the container, so they are asserted as deliberate 0644.
n=0
for f in scripts/27-harbor-ca-from-cluster.sh scripts/fetch-supervisor-ca.sh scripts/jumpbox-launch.sh scripts/30-vks-login.sh; do
  [ -f "$REPO/$f" ] || continue
  grep -qE '(install -m 0?644|chmod 0?644)' "$REPO/$f" && n=$((n+1))
done
if [ "$n" -ge 3 ]; then ok "public CA material is still deliberately 0644 in $n script(s) — a 0600 CA is unreadable by the container uid"
else bad "found only $n script(s) keeping CA material 0644" "if the sweep tightened a CA, the jump box breaks"; fi

# .env.example is the COMMITTED source of truth and must never be a set_env_var sink.
sinks=0
for f in scripts/check-psa-defaults.sh scripts/check-env-coverage.sh scripts/check-how-provenance.sh; do
  [ -f "$REPO/$f" ] || continue
  grep -qE 'set_env_var|env_set' "$REPO/$f" && sinks=$((sinks+1))
done
if [ "$sinks" -eq 0 ]; then ok ".env.example is read by 3 gates and written by NONE (so it never gets chmodded to 600)"
else bad "$sinks gate(s) that point ENV_FILE at .env.example also WRITE through set_env_var" "they would chmod the committed file"; fi

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
