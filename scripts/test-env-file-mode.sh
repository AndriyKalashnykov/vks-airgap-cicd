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
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
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
    # ⚠️ shellcheck disable=SC1091 — `./.env` is created AT RUNTIME in $d (a mktemp dir) and does not
    # exist in the repo, so there is nothing to follow. This was GREEN LOCALLY and RED IN CI for the
    # classic reason: the author's box has a real .env at the repo root, so shellcheck followed THAT
    # and said nothing. A finding that depends on dev-machine state is not a finding about the code.
    # shellcheck disable=SC1091
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

# ---- 5. the GENERATED overlays — secrets/*.make ---------------------------------------------------
# These are a REWRITE of .env / .env.state, so they carry the same credentials verbatim — and they
# sat OUTSIDE this test's corpus while its own header documented the exact trap that hits them. The
# Makefile regenerates them at PARSE time with a `>` redirect, and `umask` is create-only, so a
# pre-existing loose mode survives the truncate unless the writer unlinks first. Measured before the
# fix: a pre-seeded 0644 stayed 0644 with a live credential inside.
#
# ⚠️ THIS SECTION RUNS IN A SANDBOX, AND IT DID NOT (B751). It used to `cd "$REPO"` and drive the
# REAL Makefile: five times per run it truncated, chmodded (644/664/666/400) and regenerated the
# real `$REPO/secrets/.env.state.make` from a fixture holding a fixture HARBOR_PASSWORD, then
# `rm -f`ed it -- on every fast-tier run, in the checkout a lab `make` may be running from. That
# other `make` `-include`s the same path, so it could read an overlay generated from this fixture.
# The include machinery is now LIFTED out of the shipped Makefile into the sandbox (the same lift
# test-env-precedence.sh makes, asserted the same way, so a failed extraction cannot pass), and the
# real file's identity is asserted UNCHANGED around the whole section.
d="$(mktemp -d)"; printf 'HARBOR_PASSWORD=%s\n' "$SECRET" > "$d/.env.state"
# The real overlay and its directory: inode, mtime (ns), mode, size, content. ABSENT is a state too
# -- the old code left the file ABSENT at the end, so on a box where it started absent only the
# DIRECTORY's mtime records that it was created and removed in between.
_real_sig() {
  local f="$REPO/secrets/.env.state.make" dd="$REPO/secrets"
  if [ -e "$dd" ]; then stat -c 'dir %i %y %a' "$dd"; else echo 'dir ABSENT'; fi
  if [ -e "$f" ]; then stat -c 'file %i %y %a %s' "$f"; cksum < "$f"; else echo 'file ABSENT'; fi
}
real_before="$(_real_sig)"
# shellcheck disable=SC2016  # $(...) below is MAKEFILE syntax matched in / written to a Makefile
{
  sed -n '/^define regen_overlay_mk$/,/^endef$/p'                                        "$REPO/Makefile"
  sed -n '/^_ENVMK_KIND := /,/^-include \$(if \$(wildcard \.env\.kind)/p'               "$REPO/Makefile"
  sed -n '/^STATE_SRC := /,/^-include \$(if \$(wildcard \$(STATE_SRC))/p'                "$REPO/Makefile"
  sed -n '/^_ENVMK_ENV := /,/^-include \$(if \$(wildcard \.env),/p'                      "$REPO/Makefile"
  printf 'help: ; @:\n'
} > "$d/Makefile"
lifted="$(grep -c . "$d/Makefile")"
if [ "$lifted" -ge 10 ] && [ "$lifted" -le 31 ] && grep -q '^endef$' "$d/Makefile" \
   && [ "$(grep -c 'call regen_overlay_mk' "$d/Makefile")" -eq 3 ] \
   && grep -q 'secrets/\.env\.state\.make' "$d/Makefile"; then
  ok "lifted ${lifted} non-blank lines of the shipped overlay machinery into the sandbox"
else
  bad "LIFT FAILED (${lifted} lines)" "section 5 is not testing the product; fix the sed anchors (they are test-env-precedence.sh's)"
fi
gen="$d/secrets/.env.state.make"
gen_bad=""
for pre in none 644 664 666 400; do
  mkdir -p "$d/secrets"
  if [ "$pre" = none ]; then
    rm -f "$gen"
  else
    : > "$gen"; chmod "$pre" "$gen"
  fi
  # MAKEFLAGS= for the reason test-env-precedence.sh records: an outer `make -C` leaks `-w`.
  ( cd "$d" || exit 1; VKS_STATE_FILE="$d/.env.state" MAKEFLAGS='' make -s --no-print-directory help >/dev/null 2>&1 )
  m="$(stat -c %a "$gen" 2>/dev/null || echo MISSING)"
  [ "$m" = 600 ] || gen_bad="$gen_bad pre=$pre:$m"
done
if [ -z "$gen_bad" ]; then
  ok "generated secrets/.env.state.make lands 0600 from every pre-existing mode (5 cells)"
else
  bad "generated overlay mode:$gen_bad" "umask is create-only — mv the temp file in, do not redirect over the destination"
fi
# The overlay must carry the fixture's key, or the five cells above measured an empty file's mode.
if grep -q '^HARBOR_PASSWORD ?= ' "$gen" 2>/dev/null; then
  ok "the sandbox overlay was GENERATED from the fixture state file (it carries the rewritten key)"
else
  bad "the sandbox overlay does not carry HARBOR_PASSWORD" "the lifted machinery did not run against the fixture, so the mode cells prove nothing"
fi
# The writer is atomic (write a PID-suffixed temp, then rename), so nothing may survive it. A
# leftover here means someone replaced the mv with a plain redirect, or the rename failed silently.
leftover="$(find "$d/secrets" -maxdepth 1 -name '*.tmp' 2>/dev/null | wc -l)"
if [ "$leftover" -eq 0 ]; then ok "the atomic writer leaves no *.tmp behind in secrets/"
else bad "$leftover leftover *.tmp in secrets/" "the temp file is PID-suffixed; a survivor means the rename did not happen"; fi
rm -rf "$d"
# THE FENCE, asserted. RED-proven by pointing `gen` back at "$REPO/secrets/.env.state.make" and
# the `cd` back at "$REPO": the inode and the directory mtime both move.
real_after="$(_real_sig)"
if [ "$real_before" = "$real_after" ]; then
  ok "the REAL secrets/.env.state.make and secrets/ are untouched (inode, mtime, mode, size, content)"
else
  bad "the REAL secrets/.env.state.make or secrets/ CHANGED while this test ran" \
      "before: $(printf '%s' "$real_before" | tr '\n' ' ') | after: $(printf '%s' "$real_after" | tr '\n' ' ') -- this test must never write there (or a 'make' ran in this checkout meanwhile: re-run)"
fi

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
