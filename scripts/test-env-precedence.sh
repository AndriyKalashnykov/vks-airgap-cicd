#!/usr/bin/env bash
# ============================================================================
# B84 — the Makefile's env/state includes must preserve TWO precedences at once:
#
#     the OPERATOR's environment  >  .env.kind  >  .env.state  >  .env  >  the Makefile's ?= defaults
#     `make VAR=value`            >  everything
#
# WHY THIS EXISTS. A plain `-include <file>` creates MAKEFILE assignments, and in GNU make a
# makefile assignment BEATS THE ENVIRONMENT. So `export VAR=x; make <target>` was SILENTLY IGNORED
# (measured: `export VKS_NAMESPACE=wld03; make vsphere-namespace` operated on `lab` and reported
# success). The fix rewrites every key to `?=`, which does not assign when the variable is already
# defined — and environment variables ARE defined.
#
# But `?=` INVERTS file-vs-file order: `load_env` SOURCES the files so the LAST wins, while under
# `?=` the FIRST wins. Rewriting the state overlay to `?=` while leaving it BELOW `.env` therefore
# made a stale `.env` beat the just-discovered state — a regression the fix itself introduced,
# caught only by this test. Both files are gitignored, so no other gate can see it.
#
# THE HARNESS LIFTS THE INCLUDE MACHINERY OUT OF THE REAL Makefile rather than retyping it. A
# retyped copy proves my typing, not the product: it would keep passing after someone reorders the
# real includes. The lift is asserted (line count + a STATE_SRC sentinel) so a failed extraction
# cannot masquerade as a pass.
# ============================================================================
# shellcheck disable=SC2016
#   Every single-quoted `$(...)` below is MAKEFILE syntax being written into a generated Makefile.
#   Not expanding it is the entire point: `"$(HARBOR_URL)"` must reach make intact, and double-
#   quoting it (shellcheck's suggestion) would have the SHELL expand it to empty first.
#   MUST sit above the first COMMAND: placed after `set -uo pipefail` it is silently inert.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MK="${REPO_ROOT}/Makefile"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
chk()  { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1: want [$2] got [$3]"; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T" || exit 1
mkdir -p secrets

# ---- lift the SHIPPED include blocks -------------------------------------------------------
# FOUR ranges: the shared `regen_overlay_mk` macro FIRST (a `$(call)` before its `define` expands
# to nothing, silently), then each block from its `$(call)` line through its own `-include`.
# Ending on a pattern that does NOT occur makes sed run to EOF — measured twice now: once on the
# original `.env.kind.make` anchor, and again when the per-block rules were replaced by the macro
# and the old `@umask 077;` end-anchor stopped existing (3589 lines lifted). The guard caught both,
# which is the whole reason it has an UPPER bound: a guard with one open end is not a guard.
{
  sed -n '/^define regen_overlay_mk$/,/^endef$/p'                                        "$MK"
  sed -n '/^_ENVMK_KIND := /,/^-include \$(if \$(wildcard \.env\.kind)/p'               "$MK"
  sed -n '/^STATE_SRC := /,/^-include \$(if \$(wildcard \$(STATE_SRC))/p'                "$MK"
  sed -n '/^_ENVMK_ENV := /,/^-include \$(if \$(wildcard \.env),/p'                      "$MK"
} > Makefile
lifted="$(grep -c . Makefile)"
if [ "$lifted" -ge 10 ] && [ "$lifted" -le 30 ] \
   && grep -q 'STATE_SRC' Makefile && grep -q 'wildcard \.env\.kind' Makefile \
   && grep -q '^endef$' Makefile \
   && [ "$(grep -c 'call regen_overlay_mk' Makefile)" -eq 3 ]; then
   # ^ `grep -c` on the CALL SITES, not on the macro body: the body occurs once by construction, so
   #   counting it could never detect a dropped block. Three call sites == three overlays.
  ok "lifted ${lifted} non-blank lines of the shipped include machinery (macro + 3 blocks)"
else
  bad "LIFT FAILED (${lifted} lines) — this harness is not testing the product; fix the sed anchors"
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
printf 'show: ; @printf "%%s|%%s|%%s\\n" "$(HARBOR_URL)" "$(KUBECONFIG)" "$(ONLY_IN_ENV)"\n' >> Makefile

f() { make -s show 2>/dev/null | cut -d'|' -f"$1"; }

# ---- 1. .env alone ---------------------------------------------------------------------------
printf 'HARBOR_URL=harbor.ENV\nONLY_IN_ENV=yes\n' > .env
chk 'only .env present: .env supplies the value' 'harbor.ENV' "$(f 1)"

# ---- 2. .env.state must BEAT .env (the regression this test exists for) -----------------------
printf 'HARBOR_URL=harbor.STATE\nKUBECONFIG=/from/state.kc\n' > .env.state
chk 'state overlay BEATS .env'                'harbor.STATE'   "$(f 1)"
chk '  ...and .env still supplies keys state does not' 'yes'   "$(f 3)"

# ---- 3. legacy .env.kind must BEAT .env.state (mirrors load_env sourcing it last) -------------
printf 'HARBOR_URL=harbor.KIND\n' > .env.kind
chk 'legacy .env.kind BEATS the state overlay' 'harbor.KIND'   "$(f 1)"
rm -f .env.kind secrets/.env.kind.make

# ---- 4. THE BUG: the operator's exported value must beat every file ---------------------------
out="$(HARBOR_URL=harbor.OPERATOR KUBECONFIG=/operator/chose make -s show 2>/dev/null)"
chk 'export HARBOR_URL beats every file'   'harbor.OPERATOR' "$(printf '%s' "$out" | cut -d'|' -f1)"
chk 'export KUBECONFIG beats every file'   '/operator/chose' "$(printf '%s' "$out" | cut -d'|' -f2)"

# ---- 5. a command-line assignment still outranks everything ----------------------------------
chk 'make VAR=... beats the environment too' 'harbor.CMDLINE' \
  "$(HARBOR_URL=harbor.OPERATOR make -s show HARBOR_URL=harbor.CMDLINE 2>/dev/null | cut -d'|' -f1)"

# ---- 6. ORPHAN GUARD: deleting a source must stop its generated file applying -----------------
# Without the `$(wildcard ...)` guard the generated secrets/.env.state.make survives the delete and
# keeps supplying values from a file the operator has REMOVED.
[ -s secrets/.env.state.make ] || bad "precondition: secrets/.env.state.make was never generated"
rm -f .env.state
chk 'deleting .env.state stops its orphan applying' 'harbor.ENV' "$(f 1)"
[ -f secrets/.env.state.make ] && ok "  (the orphan file still exists — it is EXCLUDED, not deleted)"

# ---- 7. VKS_STATE_FILE relocates the overlay --------------------------------------------------
printf 'HARBOR_URL=harbor.RELOCATED\n' > custom.state
chk 'VKS_STATE_FILE relocates the state overlay' 'harbor.RELOCATED' \
  "$(VKS_STATE_FILE=custom.state make -s show 2>/dev/null | cut -d'|' -f1)"

# ---- 7a. THE MTIME BLEED — the trigger section 7 above CANNOT catch ---------------------------
# Section 7 passes by ACCIDENT: it writes custom.state immediately BEFORE invoking make, so the
# source is always NEWER than the generated file and even the old rule form looked fresh. A fixed
# derived path with a VARIABLE source decides freshness by mtime, and the derived file is stamped
# `now` on every rebuild — so it is routinely newer than a perfectly current source. Three
# triggers, each serving the WRONG file's values, silently, with rc=0.
printf 'HARBOR_URL=harbor.BLEED_A\n' > bleed_a.state
printf 'HARBOR_URL=harbor.BLEED_B\n' > bleed_b.state
bl() { VKS_STATE_FILE="$1" make -s show 2>/dev/null | cut -d'|' -f1; }
chk 'bleed 1a: the first source reads correctly'        'harbor.BLEED_A' "$(bl bleed_a.state)"
chk 'bleed 1b: switching source does not serve the old' 'harbor.BLEED_B' "$(bl bleed_b.state)"
chk 'bleed 1c: switching back does not serve the other' 'harbor.BLEED_A' "$(bl bleed_a.state)"
printf 'HARBOR_URL=harbor.ROTATED\n' > bleed_a.state; touch -d '2020-01-01' bleed_a.state
chk 'bleed 2: rotated content, OLDER mtime, is re-read' 'harbor.ROTATED' "$(bl bleed_a.state)"
_bm="$(stat -c %y bleed_a.state)"
printf 'HARBOR_URL=harbor.SAMESEC\n' > bleed_a.state; touch -d "$_bm" bleed_a.state
chk 'bleed 3: rotated content, EQUAL mtime, is re-read' 'harbor.SAMESEC' "$(bl bleed_a.state)"

# POSITIVE CONTROL for 7a — the pre-fix RULE form must still bleed, or 7a discriminates nothing.
mkdir -p bleedctl/secrets && cd bleedctl || exit 1
cat > Makefile <<'MK'
STATE_SRC := $(if $(VKS_STATE_FILE),$(VKS_STATE_FILE),.env.state)
-include $(if $(wildcard $(STATE_SRC)),secrets/.env.state.make)
secrets/.env.state.make: $(STATE_SRC)
	@mkdir -p secrets && chmod 700 secrets
	@umask 077; sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=/\1 ?= /' '$<' > '$@'
show: ; @printf "%s\n" "$(HARBOR_URL)"
MK
printf 'HARBOR_URL=harbor.CTL_A\n' > a.state
printf 'HARBOR_URL=harbor.CTL_B\n' > b.state
VKS_STATE_FILE=a.state make -s show >/dev/null 2>&1
_ctl="$(VKS_STATE_FILE=b.state make -s show 2>/dev/null)"
if [ "$_ctl" = 'harbor.CTL_B' ]; then
  bad "positive control: the PRE-FIX rule form did NOT bleed — section 7a discriminates nothing"
else
  ok "positive control: pre-fix rule form still bleeds (b.state served [$_ctl]) — 7a discriminates"
fi
cd "$T" || exit 1

# ---- 8. the rewrite must not mangle a value containing '=' or spaces --------------------------
printf 'HARBOR_URL=host:443/path?a=b c\n' > .env.state
chk 'a value containing = and a space survives the rewrite' 'host:443/path?a=b c' "$(f 1)"

# ---- 9. the generated files must not be world-readable (they carry credentials) ---------------
mode="$(stat -c %a secrets/.env.make 2>/dev/null || echo '?')"
case "$mode" in 600|400) ok "generated .env.make is $mode (umask 077 held)";;
                *) bad "generated .env.make is mode $mode — it carries the same credentials as .env";; esac

# ---- 9b. the DIRECTORY must be 700 (B174) -----------------------------------------------------
# The file's 0600 above is NOT sufficient: `secrets/.env.make` is make `-include`d, so a
# GROUP-WRITABLE DIRECTORY is make-variable injection regardless of the file's own mode — a group
# member can unlink and recreate it. Measured on this box: umask IS 002, and a bare `mkdir -p`
# yields 775.
#
# ⚠️ WHY NOT `install -d -m 700`, which is the obvious one-call form: **toybox IGNORES `-m` on the
# `-d` path**, silently, rc=0. MEASURED on bare photon:5.0 (toybox 0.8.9 — the repo's primary
# air-gap jump-box OS): fresh 775 AND existing 775, at umask 002. It works on GNU coreutils 9.4 and
# uutils 0.8.0, so it passes on every dev box and is a NO-OP on the one machine that matters.
# `mkdir -p && chmod` is 700/700 on toybox AND GNU, fresh AND existing — measured on both.
#
# This case RED-proves TWO things at once: the mode, and that the recipe actually re-runs. It
# regresses the dir to 775 and touches .env so the timestamp-gated rule fires.
chmod 775 secrets 2>/dev/null || true
touch .env
make -s show >/dev/null 2>&1
dmode="$(stat -c %a secrets 2>/dev/null || echo '?')"
case "$dmode" in 700) ok "secrets/ is $dmode — group-write closed, and the recipe re-ran to repair it";;
                 *) bad "secrets/ is mode $dmode, not 700 — a group-writable dir holding a make -include'd file is variable injection (and if this is 775 on toybox, the fix regressed to \`install -d -m\`)";; esac

# ---- 10. POSITIVE CONTROL — reconstruct the PRE-FIX include shape and require it to FAIL --------
# Without this, every assertion above could be passing for a reason unrelated to the fix. Running the
# suite against the real pre-fix Makefile (a git worktree at the parent commit) exits non-zero — but
# only because the LIFT anchors do not exist there, which is the harness refusing to run, NOT the
# gate catching the defect. gates.md: a non-zero exit is not a RED; a RED is the gate saying the
# specific thing it was built to say. So the pre-fix shape is rebuilt here explicitly.
mkdir -p prefix/secrets && cd prefix || exit 1
{ printf 'secrets/.env.make: .env\n\t@mkdir -p secrets\n\t@umask 077; sed -E %s %s > %s\n' \
    "'s/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=/\\1 ?= /'" "'\$<'" "'\$@'"
  printf -- '-include secrets/.env.make\n'
  printf -- '-include $(if $(VKS_STATE_FILE),$(VKS_STATE_FILE),.env.state)\n'   # PLAIN: the B84 bug
  printf 'show: ; @printf "%%s|%%s\\n" "$(HARBOR_URL)" "$(KUBECONFIG)"\n'; } > Makefile
printf 'HARBOR_URL=harbor.ENV\n'                                     > .env
printf 'HARBOR_URL=harbor.STATE\nKUBECONFIG=/from/state.kc\n'        > .env.state
got="$(HARBOR_URL=harbor.OPERATOR make -s show 2>/dev/null | cut -d'|' -f1)"
if [ "$got" = 'harbor.OPERATOR' ]; then
  bad "positive control: the PRE-FIX shape did NOT reproduce B84 — these assertions discriminate nothing"
else
  ok "positive control: pre-fix shape still defeats \`export\` (got [$got]) — the assertions do discriminate"
fi
cd "$T" || exit 1

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
