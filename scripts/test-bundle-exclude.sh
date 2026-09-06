#!/usr/bin/env bash
# ci-tier: fast — real tar on throwaway trees. No network, no registry, no cluster.
#
# test-bundle-exclude.sh — B706 (stale artefact) and B708 (symlinked BUNDLE_DIR).
#
# B708 IS THE SERIOUS ONE. `tar -C parent -cf out bundle` archives the LINK, not its target.
# MEASURED: a 24 MB payload behind a symlink produced a 10,240-byte archive holding ONE dangling
# entry, rc=0 — and every pre-existing guard passed, including the selfbuilt check, because it
# follows the link. On the lab that is an 8 GB bundle carried across an air gap as 10 KB with the
# sha256 written and "bundle ready" logged.
#
# B706's premise turned out to be STALE: the fossil tarball got into bundle/ via a
# BUNDLE_OUT_DIR clobber that is now guarded three ways (commented var, 11-bundle.sh's inside-check,
# check-env-clobber). The exclude is kept as cheap portable insurance, not as the fix for a live bug.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- case 1: THE B708 HAZARD — tar on a symlink yields a 1-member archive, rc=0 ------
mkdir -p "$TMP/real/bundle/selfbuilt" "$TMP/parent"
head -c 2000000 /dev/urandom > "$TMP/real/bundle/payload.bin"
: > "$TMP/real/bundle/selfbuilt/kaniko.tar"
ln -s "$TMP/real/bundle" "$TMP/parent/bundle"
tar -C "$TMP/parent" -cf "$TMP/sym.tar" bundle 2>/dev/null; rc=$?
n=$(tar -tf "$TMP/sym.tar" 2>/dev/null | wc -l)
if [ "$rc" -eq 0 ] && [ "$n" -eq 1 ]; then
  ok "case1: tar on a SYMLINKED dir returns 0 with 1 member (the hazard B708 guards)"
else bad "case1: rc=$rc members=$n — expected rc=0 and exactly 1"; fi

# ---- case 2: the member-count check CATCHES that archive ----------------------------
if [ "$n" -lt 10 ]; then ok "case2: a >=10-member floor rejects the symlink archive"
else bad "case2: member count $n would slip a >=10 floor"; fi

# ---- case 3: the ANCHORED exclude drops top-level, keeps selfbuilt AND a nested decoy -
mkdir -p "$TMP/w/bundle/selfbuilt" "$TMP/w/bundle/images/sub"
: > "$TMP/w/bundle/vks-airgap-cicd-bundle-20260712-184355.tar.zst"
: > "$TMP/w/bundle/vks-airgap-cicd-bundle-20260712-184355.tar.zst.sha256"
: > "$TMP/w/bundle/selfbuilt/kaniko.tar"
: > "$TMP/w/bundle/images/sub/vks-airgap-cicd-bundle-DECOY.tar"
tar -C "$TMP/w" --exclude="bundle/vks-airgap-cicd-bundle-*" -cf "$TMP/w.tar" bundle 2>/dev/null
mem="$(tar -tf "$TMP/w.tar" 2>/dev/null)"
drop=$(printf '%s\n' "$mem" | grep -c '^bundle/vks-airgap-cicd-bundle-' || true)
keep_sb=$(printf '%s\n' "$mem" | grep -c 'selfbuilt/kaniko.tar' || true)
keep_dec=$(printf '%s\n' "$mem" | grep -c 'images/sub/vks-airgap-cicd-bundle-DECOY.tar' || true)
if [ "$drop" -eq 0 ] && [ "$keep_sb" -eq 1 ] && [ "$keep_dec" -eq 1 ]; then
  ok "case3: anchored exclude drops top-level (+.sha256), keeps selfbuilt AND the nested decoy"
else bad "case3: top-level=$drop (want 0) selfbuilt=$keep_sb nested=$keep_dec (want 1,1)"; fi

# ---- case 4: a BLANKET '*.tar' eats selfbuilt — the trap, pinned so nobody "simplifies" -
tar -C "$TMP/w" --exclude='*.tar' -cf "$TMP/blanket.tar" bundle 2>/dev/null
if [ "$(tar -tf "$TMP/blanket.tar" 2>/dev/null | grep -c 'selfbuilt/kaniko.tar' || true)" -eq 0 ]; then
  ok "case4: a blanket '*.tar' DOES eat selfbuilt/kaniko.tar (why the exclude is anchored)"
else bad "case4: blanket exclude unexpectedly kept selfbuilt — the anchoring rationale is wrong"; fi

# ---- case 5: WIRING — the guards are present and the SIGPIPE-safe form is used -------
w=0
# shellcheck disable=SC2016  # the single quotes are the POINT: this greps another
# file's SOURCE for a literal `$name`. Double quotes would expand it here (unset), so the
# pattern would silently become one that matches nothing — a vacuous, always-green check.
grep -qE '^\[ -L "\$BUNDLE_DIR" \] && die' scripts/11-bundle.sh || { bad "case5a: no symlink die in 11-bundle.sh"; w=1; }
grep -qE '_bundle_abs="\$\(realpath' scripts/11-bundle.sh          || { bad "case5b: the inside-check still uses logical cd+pwd"; w=1; }
# shellcheck disable=SC2016  # the single quotes are the POINT: this greps another
# file's SOURCE for a literal `$name`. Double quotes would expand it here (unset), so the
# pattern would silently become one that matches nothing — a vacuous, always-green check.
grep -qE -- '--exclude="\$\(basename "\$BUNDLE_DIR"\)/vks-airgap-cicd-bundle-\*"' scripts/11-bundle.sh \
                                                                    || { bad "case5c: the anchored exclude is missing"; w=1; }
# The post-tar check must NOT use `grep -q` on the far end of a pipe: tar -tf writes once per
# member, so an early -q exit SIGPIPEs it and pipefail reports the pipeline CLEAN.
# shellcheck disable=SC2016  # the single quotes are the POINT: this greps another
# file's SOURCE for a literal `$name`. Double quotes would expand it here (unset), so the
# pattern would silently become one that matches nothing — a vacuous, always-green check.
grep -qE 'tar -tf "\$tarball" \| grep -q ' scripts/11-bundle.sh     && { bad "case5d: post-tar check uses grep -q — it will SIGPIPE and false-clean"; w=1; }
[ "$w" -eq 0 ] && ok "case5: symlink die + realpath + anchored exclude present; no grep -q on the pipe"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
