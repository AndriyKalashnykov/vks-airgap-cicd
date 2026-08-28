#!/usr/bin/env bash
# test-selfbuilt-lock.sh — REGRESSION GUARD: selfbuilt.lock must SURVIVE a warm re-run.
#
# WHAT IT GUARDS
# ---------------------------------------------------------------------------
# `14-selfbuilt-build.sh` writes a provenance record per image into selfbuilt.lock. Three lines
# conspired to erase it on every warm run, and the warm run is the COMMON path:
#
#     :  > "${LOCK}.tmp"                     # truncate the temp
#         continue                            # the SKIP path jumps past the append
#     sort -u "${LOCK}.tmp" > "$LOCK"         # overwrite the lock with the empty temp
#
# MEASURED on a real box before the fix: kaniko.tar 113 MB at 19:22, selfbuilt.lock **0 BYTES** at
# 20:02 — i.e. emptied by a later warm run. The lock has one writer and (today) zero readers, so
# this had cost nothing operationally; that is exactly why it survived, and it is the reason NOT to
# build anything on top of it. A verdict column on a file that is empty whenever anything is
# skipped would have been decoration on decoration.
#
# THE FIX under test: the per-image stamp carries the tag on line 1 (what the skip comparison reads,
# via `head -1`, so an OLD one-line stamp still compares equal) and the lock record on line 2, which
# the skip path re-emits.
#
# HONESTY: this drives the REAL script with a fabricated bundle so the skip path is taken; it does
# NOT build an image. It proves the record survives skips and is byte-stable across them. It does
# not prove the record's CONTENT is right on a cold build — that is `make selfbuilt-image`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# ⚠️ ISOLATION IS BY **CWD**, NOT BY BUNDLE_DIR. `BUNDLE_DIR` CANNOT be overridden: `.env.example`
# sets it uncommented, and `load_env` sources that with `set -a` AFTER the environment is
# established, so an override is silently replaced. MEASURED: `BUNDLE_DIR=/tmp/x` -> `./bundle`,
# and `SKIP_DOTENV=1` does not help (it skips `.env`, not `.env.example`). Since OUT_DIR is
# `${BUNDLE_DIR}/selfbuilt` = `./bundle/selfbuilt`, running from a temp CWD gives full isolation --
# verified below by asserting the repo's own bundle is not touched.
# One helper, one directive. REPO_ROOT is read by selfbuilt_file() inside the sourced library; the
# linter cannot see that through the variable path (hence the export, which silences SC2034) and
# cannot follow the source through "$SCRIPT_DIR" (hence the source= directive below).
# NOTE: a comment whose first word after # is the linter's own name is parsed as a DIRECTIVE, not
# prose -- that is why this paragraph is worded around it (SC1072/SC1073 otherwise).
# shellcheck source=scripts/lib/selfbuilt.sh
reg() { ( export REPO_ROOT="$REPO"; . "$SCRIPT_DIR/lib/selfbuilt.sh" >/dev/null 2>&1 || exit 9; "$@" ); }
NAME="$(reg selfbuilt_names | head -1)"
TAG="$(reg selfbuilt_tag "$NAME")"
[ -n "${NAME:-}" ] && [ -n "${TAG:-}" ] || { echo "  FAIL  could not read the registry"; exit 1; }

OUT="$TMP/bundle/selfbuilt"; mkdir -p "$OUT"
# Field 4 is `<repo>:<tag>` and the script now REFUSES to re-emit a record naming a different push
# target, so the fixture must carry the REAL repo path (registry field 6, env-independent) -- an
# arbitrary `some/repo` here would be refused, and the case would fail for a fixture reason.
REPO_PATH="$(reg selfbuilt_repo_path "$NAME")"
[ -n "${REPO_PATH:-}" ] || { echo "  FAIL  could not read the repo path from the registry"; exit 1; }
REC="$(printf '%s\tv1.2.3\tsha256:deadbeef\t%s:%s\t2026-01-01T00:00:00Z' "$NAME" "$REPO_PATH" "$TAG")"
printf 'fake-image-bytes\n' > "$OUT/${NAME}.tar"
printf '%s\n%s\n' "$TAG" "$REC" > "$OUT/.${NAME}.built"

REAL_LOCK="$REPO/bundle/selfbuilt/selfbuilt.lock"
real_before="$(stat -c %Y "$REAL_LOCK" 2>/dev/null || echo none)"
# CONTAINER_ENGINE=none: the script `die`s in container_engine() when no engine is on PATH, and this
# test is in the FAST per-PR tier. Without it, an engine-less runner reports 5 FAILs reading "the
# erasure is back" / "not backward compatible" — wrong causes for a missing binary, the class this
# repo calls worse than a crash. The skip path never touches the engine, so pinning it is faithful.
run_warm() { ( cd "$TMP" && CONTAINER_ENGINE=none timeout 120 bash "$SCRIPT_DIR/14-selfbuilt-build.sh" ) >"$TMP/run.log" 2>&1; }

run_warm; rc1=$?
a="$(cat "$OUT/selfbuilt.lock" 2>/dev/null)"
run_warm; rc2=$?
b="$(cat "$OUT/selfbuilt.lock" 2>/dev/null)"

if [ -n "$a" ]; then ok "warm run 1 leaves selfbuilt.lock NON-EMPTY"
else bad "warm run 1 left selfbuilt.lock EMPTY (rc=$rc1) — the erasure is back"; sed -n '1,8p' "$TMP/run.log" | sed 's/^/        | /'; fi
if [ -n "$b" ]; then ok "warm run 2 leaves selfbuilt.lock NON-EMPTY"
else bad "warm run 2 left selfbuilt.lock EMPTY (rc=$rc2) — the erasure is back"; fi
# `[ -n "$a" ]` first: comparing "" = "" PASSED in BOTH broken states (fix reverted, and no engine),
# so without it this case contributes nothing exactly when things are wrong.
if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "the record is BYTE-IDENTICAL across warm runs (no churn)"
else bad "the record changed between warm runs — a re-emit must not re-timestamp"; fi
if printf '%s' "$a" | grep -qF "$REC"; then ok "the re-emitted record is the stamped one, verbatim"
else bad "the lock does not carry the stamped record (got: '$a')"; fi

printf '%s\n' "$TAG" > "$OUT/.${NAME}.built"
run_warm; rc3=$?
if [ "$rc3" -eq 0 ]; then ok "an OLD one-line stamp is still accepted (head -1, not cat)"
else bad "an old one-line stamp broke the run (rc=$rc3) — not backward compatible"; fi
# ⚠️ THE LOCK ITSELF, not just the message. This case used to assert only the warning, so it stayed
# GREEN while the lock was being emptied — invisible to the very defect it names. An old one-line
# stamp is the state EVERY existing box is in, and the record is recoverable from the previous
# $LOCK, so the correct outcome is a PRESERVED lock, not a warning.
c="$(cat "$OUT/selfbuilt.lock" 2>/dev/null)"
if [ -n "$c" ]; then ok "an OLD one-line stamp still leaves the lock NON-EMPTY (record recovered from the previous lock)"
else bad "an old one-line stamp EMPTIED the lock — the migration path re-emits nothing, so the erasure survives the fix"; fi
if printf '%s' "$c" | grep -qF "$REC"; then ok "and the recovered record is the previous one, verbatim"
else bad "the recovered record is not the previous one (got: '$c')"; fi

# ⚠️ THE UNRECOVERABLE BRANCH. Old one-line stamp AND no record for this image in the previous
# lock: nothing can be re-emitted, so the lock is legitimately written EMPTY and the ONLY signal is
# the warning. That branch was previously untested -- the two lock-content cases above REPLACED the
# warning case rather than joining it -- so if the warn were dropped or the condition inverted,
# nothing would catch it. Assert BOTH halves: rc=0 (a missing record is not fatal) and the warn.
: > "$OUT/selfbuilt.lock"
printf '%s\n' "$TAG" > "$OUT/.${NAME}.built"
run_warm; rc4=$?
d="$(cat "$OUT/selfbuilt.lock" 2>/dev/null)"
if [ "$rc4" -eq 0 ]; then ok "an unrecoverable stamp is NOT fatal (rc=0)"
else bad "an unrecoverable stamp aborted the run (rc=$rc4) — a missing provenance record must not stop a build"; fi
if grep -q 'no record for it survives' "$TMP/run.log"; then ok "and it WARNS that the lock is being written empty for that image"
else bad "the unrecoverable path emitted NO warning — the lock silently goes empty"; sed -n '1,8p' "$TMP/run.log" | sed 's/^/        | /'; fi
if [ -z "$d" ]; then ok "and the lock is empty, as the warning says (single-image registry)"
else bad "the warning says the lock is empty but it is not: '$d'"; fi

# ⚠️ A STALE record must NOT be re-emitted: field 4 naming a different push target means the row
# describes an image we did not build here, and a silent re-emit is self-perpetuating (it becomes
# the next run's recovery source and never re-validates).
printf '%s\tv9.9.9\tsha256:stale\tSOMEONE/ELSE:%s\t2020-01-01T00:00:00Z\n' "$NAME" "$TAG" > "$OUT/selfbuilt.lock"
printf '%s\n' "$TAG" > "$OUT/.${NAME}.built"
run_warm; rc5=$?
e="$(cat "$OUT/selfbuilt.lock" 2>/dev/null)"
if [ "$rc5" -eq 0 ] && ! printf '%s' "$e" | grep -qF 'SOMEONE/ELSE'; then ok "a record naming a DIFFERENT push target is refused, not re-emitted"
else bad "a stale record for '$(printf '%s' "$e" | cut -f4)' was re-emitted (rc=$rc5) — provenance now asserts an image we did not build"; fi
if grep -q 'different push target' "$TMP/run.log"; then ok "and the refusal says WHICH target it names"
else bad "the stale record was dropped SILENTLY — the operator cannot tell an empty lock from a refused one"; fi

real_after="$(stat -c %Y "$REAL_LOCK" 2>/dev/null || echo none)"
if [ "$real_before" = "$real_after" ]; then ok "the repo's own bundle was NOT touched (CWD isolation holds)"
else bad "this test mutated $REAL_LOCK — isolation failed, do not run it again until fixed"; fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
