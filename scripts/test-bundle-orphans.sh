#!/usr/bin/env bash
# ci-tier: fast — fixture trees only. No network, no registry, no cluster.
#
# test-bundle-orphans.sh — B709. Pins the REPORTER's discrimination and its printer-not-gate contract.
#
# WHY A REPORTER. B709 prescribed a prune. An adversary round refuted that against three precedents
# set in this tree the same day (B704 "never remove a file it cannot prove is dead", B706 a `die`
# over disk waste refuted as a FALSE-BLOCK, B707 "NEVER SHIP A DELETER FIRST"), and refuted the
# premise too: 22-builder-push.sh:81-84 does a NAMED lookup, never a glob, so an orphan is never
# opened and never pushed. The harm is carry weight, not correctness.
#
# CASE 2 IS THE POINT. A reporter that flags everything is as useless as one that flags nothing;
# what must be proven is that it separates an orphan from a live artefact. And case 4 pins the
# printer contract: it must exit 0 even WITH orphans, or it becomes the gate B706 refuted.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
D="$TMP/bundle"; mkdir -p "$D/builders" "$D/charts" "$D/selfbuilt"

# LIVE: first registry app, the pinned istio chart version, the selfbuilt.tsv row.
live_app="$(grep -vE '^\s*#|^\s*$' apps/registry.tsv | head -1 | cut -f1)"
live_ver="$(grep -oE '^ISTIO_VERSION=.*' .env.example | cut -d= -f2)"
live_sb="$(grep -vE '^\s*#|^\s*$' images/selfbuilt.tsv | head -1 | cut -f1)"
: > "$D/builders/${live_app}-builder.tar"
: > "$D/charts/istiod-${live_ver}.tgz"
: > "$D/selfbuilt/${live_sb}.tar"
# ORPHANS: an app with no registry row, a superseded chart, a tool with no tsv row.
: > "$D/builders/GONEAPP-builder.tar"
: > "$D/charts/istiod-0.0.1-orphan.tgz"
: > "$D/selfbuilt/OLDTOOL.tar"

out="$(./scripts/bundle-orphans.sh "$D" 2>&1)"; rc=$?

# ---- case 1: every planted orphan is reported, one per directory --------------------
miss=""
for o in GONEAPP-builder.tar istiod-0.0.1-orphan.tgz OLDTOOL.tar; do
  printf '%s' "$out" | grep -q "$o" || miss="$miss $o"
done
[ -z "$miss" ] && ok "case1: all 3 planted orphans reported (builders + charts + selfbuilt)" \
                || bad "case1: NOT reported:$miss"

# ---- case 2: THE DISCRIMINATION — no live artefact is reported ----------------------
falsepos=""
for l in "${live_app}-builder.tar" "istiod-${live_ver}.tgz" "${live_sb}.tar"; do
  printf '%s' "$out" | grep -q "ORPHAN.*$l" && falsepos="$falsepos $l"
done
[ -z "$falsepos" ] && ok "case2: no LIVE artefact flagged (registry row / pinned version / tsv row)" \
                   || bad "case2: FALSE POSITIVE on:$falsepos"

# ---- case 3: it is a PRINTER — exit 0 even with orphans present ---------------------
[ "$rc" -eq 0 ] && ok "case3: exits 0 WITH orphans (a printer, not the gate B706 refuted)" \
                || bad "case3: rc=$rc — it gated; B706's die was refuted as a false-block"

# ---- case 4: a clean tree reports none, and prints a DENOMINATOR --------------------
C="$TMP/clean"; mkdir -p "$C/builders" "$C/charts" "$C/selfbuilt"
: > "$C/builders/${live_app}-builder.tar"
cout="$(./scripts/bundle-orphans.sh "$C" 2>&1)"; crc=$?
if [ "$crc" -eq 0 ] && printf '%s' "$cout" | grep -q "none — examined 1"; then
  ok "case4: a clean tree reports 'none' WITH its denominator"
else bad "case4: rc=$crc out=[$(printf '%s' "$cout" | tail -1 | cut -c1-70)]"; fi

# ---- case 5: WIRING — the builders keep-set must be REGISTRY membership -------------
# app_has_builder() is a FILE TEST; using it would let a missing Dockerfile.builder silently mark a
# live app's 1.2 GB tarball an orphan. Assert the code shape, not a name that also appears in prose.
if grep -qE 'keep_apps=" \$\(app_names \| tr' scripts/bundle-orphans.sh \
   && ! grep -qE '^\s*[^#]*app_has_builder' scripts/bundle-orphans.sh; then
  ok "case5: keep-set is app_names (registry membership), NOT the app_has_builder file test"
else bad "case5: the builders keep-set is not registry-derived"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
