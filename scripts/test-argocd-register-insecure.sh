#!/usr/bin/env bash
# ci-tier: fast
#
# `ARGOCD_REGISTER_INSECURE` is honoured ONLY from the pre-`load_env` environment.
#
# WHY THIS EXISTS. The toggle registers an ArgoCD destination with TLS verification OFF, and unlike
# every other weakening toggle in this repo the choice does NOT end with the run: it is written into
# the ArgoCD Cluster Secret, so every later sync to that destination dials the guest API without
# verification. A line in a personal `.env` is therefore a standing, invisible downgrade — and a
# RATCHET, because `load_env` sources `.env.example` then `.env` with `set -a` AFTER the caller's
# environment, so a per-run `ARGOCD_REGISTER_INSECURE=0` could never have undone it.
#
# MEASURED before the fix (idea round, 2026-08-19), all three arms against the real `load_env`:
#     .env=1, caller=0        -> 1   insecure, unreachable by any override   *** the ratchet ***
#     .env=1, caller silent   -> 1   insecure, silently
#     no .env, caller=1       -> 1   the e2e prefix, which must keep working
#
# ⚠️ THE THIRD ARM IS THE POINT OF THIS FILE. `scripts/e2e-cross-cluster.sh:72` sets the toggle as
# a direct command prefix on `71-argocd-register-guest.sh`, and that is a LEGITIMATE caller: the
# two-KinD stand-in reaches the guest by raw IP, which is not in the API cert's SAN. A "fix" that
# simply hardcodes 0, or that snapshots the wrong side of `load_env`, closes the ratchet AND breaks
# the e2e — and the first two arms alone would happily pass it. Any future change here must keep
# arm 3 green.
#
# This replays 71-argocd-register-guest.sh's EXACT ordering (snapshot -> source -> load_env ->
# restore) in a throwaway REPO_ROOT. The operator's real `.env` is never read and never written.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# $1 = the caller's value ('' = caller sets nothing)
# $2 = the line to write into the throwaway .env ('' = no .env at all)
probe() {
  local T; T="$(mktemp -d)"
  cp .env.example "$T/.env.example" 2>/dev/null || { rm -rf "$T"; printf 'NOENV'; return; }
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$T/.env"
  cp -r scripts "$T/scripts"
  ( cd "$T" || exit 1
    [ -n "${1:-}" ] && export ARGOCD_REGISTER_INSECURE="$1"
    _s="${ARGOCD_REGISTER_INSECURE:-0}"                 # the snapshot, BEFORE load_env
    # shellcheck source=/dev/null
    . scripts/lib/os.sh >/dev/null 2>&1
    load_env >/dev/null 2>&1
    ARGOCD_REGISTER_INSECURE="$_s"                      # the restore, AFTER
    printf '%s' "${ARGOCD_REGISTER_INSECURE:-<unset>}" )
  rm -rf "$T"
}

got="$(probe 0 'ARGOCD_REGISTER_INSECURE=1')"
if [ "$got" = 0 ]; then
  ok "caller=0 + .env says 1 -> 0 (the ratchet is broken: a per-run override wins)"
else
  bad "caller=0 with .env=1 must resolve 0, got '${got}'.
        This is the ratchet: load_env's set -a overwrote the caller and there was no way back."
fi

got="$(probe '' 'ARGOCD_REGISTER_INSECURE=1')"
if [ "$got" = 0 ]; then
  ok "caller silent + .env says 1 -> 0 (the file channel is inert BY DESIGN)"
else
  bad "a .env line must not arm a PERSISTENT TLS downgrade, got '${got}'.
        The value lands in the ArgoCD Cluster Secret and every later sync skips verification."
fi

# ⚠️ ARM 3 — DO NOT DELETE. This is the live caller: e2e-cross-cluster.sh:72.
got="$(probe 1 '')"
if [ "$got" = 1 ]; then
  ok "no .env + caller=1 -> 1 (e2e-cross-cluster.sh:72's prefix still wins)"
else
  bad "the e2e's command prefix must still arm it, got '${got}'.
        e2e-cross-cluster.sh:72 relies on this; a fix that hardcodes 0 breaks the two-KinD e2e."
fi

# The caller must also be able to arm it while a .env says 0 — the inverse of arm 1, and the case
# that proves the snapshot RESTORES rather than merely forcing 0.
got="$(probe 1 'ARGOCD_REGISTER_INSECURE=0')"
if [ "$got" = 1 ]; then
  ok "caller=1 + .env says 0 -> 1 (the snapshot restores, it does not force 0)"
else
  bad "a caller must be able to arm it over a .env=0, got '${got}'.
        If this fails the 'fix' is a hardcoded 0, not a snapshot."
fi

# The default with nothing set anywhere must be OFF.
got="$(probe '' '')"
if [ "$got" = 0 ]; then
  ok "nothing set anywhere -> 0 (secure default)"
else
  bad "the default must be 0, got '${got}'"
fi

# ⚠️ ARM 6 BINDS THE ABOVE TO THE REAL SCRIPT. Arms 1-5 replay the ORDERING inline, so on their own
# they would stay green if someone deleted the snapshot from 71-argocd-register-guest.sh entirely —
# a test of the pattern, not of the product. This arm asserts the four statements exist in the real
# file IN ORDER. It greps the CODE SHAPE (the assignment and the restore), never the prose, because
# every one of these names also appears in that file's comment block.
S="scripts/71-argocd-register-guest.sh"
# The single quotes are the POINT: these are grep patterns that must match the literal characters
# `${ARGOCD_REGISTER_INSECURE:-0}` and `$_argocd_register_insecure_snapshot` in the target file.
# Expanding them here would search for this test's own (empty) values and match nothing — a gate
# that passes by not looking. `|| true` because a grep that matches nothing exits 1, which under
# `set -e` would kill the script before the MISSING branch below can report it.
# shellcheck disable=SC2016
ln_snap="$(grep -n '^_argocd_register_insecure_snapshot="\${ARGOCD_REGISTER_INSECURE:-0}"' "$S" | head -1 | cut -d: -f1 || true)"
# shellcheck disable=SC2016
ln_src="$(grep -n '^\. "\${SCRIPT_DIR}/lib/os\.sh"' "$S" | head -1 | cut -d: -f1 || true)"
ln_load="$(grep -n '^load_env$' "$S" | head -1 | cut -d: -f1 || true)"
# shellcheck disable=SC2016
ln_rest="$(grep -n '^ARGOCD_REGISTER_INSECURE="\$_argocd_register_insecure_snapshot"' "$S" | head -1 | cut -d: -f1 || true)"
if [ -z "$ln_snap" ] || [ -z "$ln_src" ] || [ -z "$ln_load" ] || [ -z "$ln_rest" ]; then
  bad "the real script lost one of the four statements (snap=${ln_snap:-MISSING} src=${ln_src:-MISSING} load=${ln_load:-MISSING} restore=${ln_rest:-MISSING}).
        Arms 1-5 replay the ordering INLINE and cannot see this: they would stay green over a script
        that no longer snapshots at all."
elif [ "$ln_snap" -lt "$ln_src" ] && [ "$ln_src" -lt "$ln_load" ] && [ "$ln_load" -lt "$ln_rest" ]; then
  ok "$S snapshots at :${ln_snap} BEFORE sourcing (:${ln_src}), restores at :${ln_rest} after load_env (:${ln_load})"
else
  bad "the real script's four statements are OUT OF ORDER (snap=$ln_snap src=$ln_src load=$ln_load restore=$ln_rest).
        The snapshot must precede the source, and the restore must follow load_env, or the file
        channel wins and the ratchet is back."
fi

[ "$fail" -eq 0 ] && printf 'test-argocd-register-insecure: ALL PASS (6)\n'
exit "$fail"
