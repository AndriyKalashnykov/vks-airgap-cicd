#!/usr/bin/env bash
# RED-proof for check-walk-env-manifest.sh and walk-env-keys.sh (B475).
#
# Every case asserts a SPECIFIC verdict, never merely "it ran". A gate over two lists has three ways
# to be worthless and all three exit 0: it compares an empty doc set (direction (a) passes
# vacuously), it compares an empty manifest (direction (b) passes vacuously), or it silently drops a
# malformed row out of both comparisons. Each has its own case below.
#
# Assertions are if/then/else, never `A && B || C` -- that form runs C when A is true and B is false,
# so a failing ok() would ALSO report a failure, and shellcheck SC2015 reddens the whole gate for it.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# A throwaway copy per case: the mutations are destructive and a leaked one makes every later case
# measure the wrong bytes.
mk() {
  local d; d="$(mktemp -d)"; mkdir -p "$d/scripts" "$d/docs"
  cp "$ROOT/scripts/walk-env-keys.sh" "$ROOT/scripts/check-walk-env-manifest.sh" "$d/scripts/"
  cp "$ROOT/.env.example" "$d/.env.example"
  cp "$ROOT/docs/scenario-1.md" "$ROOT/docs/scenario-2.md" "$ROOT/docs/walk-env-manifest.tsv" "$d/docs/"
  # `while read` from a pipe, never `for inc in $(...)`: an unquoted expansion does NOT
  # word-split under zsh, so the for-loop would run ONCE on the whole blob.
  sed -nE 's|^[[:space:]]*<!--[[:space:]]*walk-include:[[:space:]]*([^[:space:]]+)[[:space:]]*-->.*$|\1|p' \
    "$ROOT/docs/scenario-1.md" "$ROOT/docs/scenario-2.md" | sort -u | while IFS= read -r inc; do
    [ -n "$inc" ] || continue
    cp "$ROOT/docs/$inc" "$d/docs/" 2>/dev/null || true
  done
  printf '%s' "$d"
}
run() { ( cd "$1" && ./scripts/check-walk-env-manifest.sh 2>&1 ); }

# 1. GREEN on the real tree, and it must say how much it compared -- a gate that cannot report its
#    denominator cannot be trusted to have looked.
d="$(mk)"; out="$(run "$d")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "real tree: rc=0"; else bad "real tree" "rc=$rc: $(printf '%s' "$out" | tail -2)"; fi
if printf '%s' "$out" | grep -qE 'OK — [0-9]+ documented .* [0-9]+ manifest row'; then
  ok "reports both denominators"
else bad "denominators" "no OK line with both counts"; fi
rm -rf "$d"

# 2. RED (a): a document names a key with no manifest row. This is the drift that motivated B475 --
#    somebody adds a key to a document and nobody decides what the harness does about it.
d="$(mk)"
grep -v $'^scenario-1\tVKS_NAMESPACE\t' "$d/docs/walk-env-manifest.tsv" > "$d/docs/m.tmp"
mv "$d/docs/m.tmp" "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'VKS_NAMESPACE'; then
  ok "RED: a documented key with no manifest row is refused, by name"
else bad "RED undecided" "rc=$rc out=$(printf '%s' "$out" | head -2)"; fi
rm -rf "$d"

# 3. RED (b): a manifest row for a key no document names, whose reason does not declare it. That is
#    a dead row left by a rename, and a dead row is how the list rots unnoticed.
d="$(mk)"
printf 'scenario-1\tAPP_BRANCH\tEXEMPT\tsome reason that does not declare the orphan\n' >> "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ORPHAN.*APP_BRANCH'; then
  ok "RED: an undeclared orphan row is refused, by name"
else bad "RED orphan" "rc=$rc out=$(printf '%s' "$out" | head -2)"; fi
rm -rf "$d"

# 3a. THE ESCAPE IS STRUCTURAL, NOT PROSE (B494). Column 5 `undocumented` is what lets an
#     unnamed key through. Before this, the gate substring-matched column 4 against
#     "never names it" | "no document names" | B471 -- and that third alternative is a BACKLOG ROW
#     ID matched against free text. MEASURED 2026-08-26: 8 rows mentioned B471 and FIVE escaped on
#     that literal ALONE, so a copy-edit removing `B471:` -- changing no decision -- turned five
#     rows ORPHAN and reddened static-check. Both halves are pinned here: the flag PASSES, and the
#     prose that used to pass no longer does.
d="$(mk)"
printf 'scenario-1\tAPP_BRANCH\tEXEMPT\tno document names it\tundocumented\n' >> "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ok (declared).*APP_BRANCH'; then
  ok "column 5 'undocumented' declares an unnamed key (rc=0)"
else bad "flagged orphan" "rc=$rc out=$(printf '%s' "$out" | head -3)"; fi
rm -rf "$d"

d="$(mk)"
printf 'scenario-1\tAPP_BRANCH\tEXEMPT\tB471: no document names it, it never names it\n' >> "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'ORPHAN.*APP_BRANCH'; then
  ok "RED: the OLD prose phrases alone no longer declare it -- prose is prose again"
else bad "prose must not declare" "rc=$rc out=$(printf '%s' "$out" | head -3)"; fi
rm -rf "$d"

# 3b. ...and the SAME row as FORBID is legitimate. A FORBID is a standing prohibition: forbidding a
#     key the document does not name is the STRONGEST form of the row, not a defect. Without this,
#     scenario-1 HARBOR_PASSWORD -- the row the whole per-scenario design exists for -- is a false RED.
d="$(mk)"
printf 'scenario-1\tAPP_BRANCH\tFORBID\tthe walk must obtain it itself\n' >> "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ok (FORBID).*APP_BRANCH'; then
  ok "a FORBID row for an unnamed key is legitimate (rc=0)"
else bad "FORBID orphan" "rc=$rc out=$(printf '%s' "$out" | head -3)"; fi
rm -rf "$d"

# 4. THE ROW THE DESIGN EXISTS FOR. HARBOR_PASSWORD must be FORBID for scenario-1 and EMIT for
#    scenario-2. A flat union of doc keys cannot express that -- which is why the first design was
#    refuted: moving the emission out of its scenario-2 guard left that gate GREEN while
#    28-harbor-admin-password.sh's read-the-installed-password branch stopped being walked.
d="$(mk)"
s1="$(awk -F'\t' '$1=="scenario-1" && $2=="HARBOR_PASSWORD" {print $3}' "$d/docs/walk-env-manifest.tsv")"
s2="$(awk -F'\t' '$1=="scenario-2" && $2=="HARBOR_PASSWORD" {print $3}' "$d/docs/walk-env-manifest.tsv")"
if [ "$s1" = FORBID ] && [ "$s2" = EMIT ]; then
  ok "HARBOR_PASSWORD: scenario-1 FORBID, scenario-2 EMIT"
else bad "HARBOR_PASSWORD dispositions" "s1=$s1 s2=$s2 (want FORBID / EMIT)"; fi
rm -rf "$d"

# 5. RED: a malformed row. Without this check it drops out of BOTH comparisons, so both directions
#    pass while the row decides nothing -- the file-vs-item vacuity bug, one level up.
for m in 'scenario-1	SOME_KEY	EXEMPT' 'scenario-1	SOME_KEY	NOPE	a reason' 'scenario-9	SOME_KEY	EMIT	a reason'; do
  d="$(mk)"; printf '%s\n' "$m" >> "$d/docs/walk-env-manifest.tsv"
  out="$(run "$d")"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "RED: malformed row refused ($(printf '%s' "$m" | cut -f3))"
  else bad "RED malformed" "rc=0 on: $m"; fi
  rm -rf "$d"
done

# 6. RED: an EMPTY manifest must REFUSE, not pass. Comparing an empty set against anything finds no
#    undecided pairs and no orphans -- a perfect, meaningless green.
d="$(mk)"; grep '^#' "$d/docs/walk-env-manifest.tsv" > "$d/docs/m.tmp"; mv "$d/docs/m.tmp" "$d/docs/walk-env-manifest.tsv"
out="$(run "$d")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'ZERO usable rows'; then
  ok "RED: an all-comment manifest refuses (vacuity guard)"
else bad "RED empty manifest" "rc=$rc out=$(printf '%s' "$out" | head -2)"; fi
rm -rf "$d"

# 7. RED: an unreadable DOC set must REFUSE. The exporter refuses on a broken parse rather than
#    emitting a short set, and this gate must not shrug that off -- a short doc set makes direction
#    (a) pass vacuously.
d="$(mk)"; : > "$d/.env.example"
out="$(run "$d")"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'walk-env-keys.sh produced nothing'; then
  ok "RED: an unreadable document set refuses (vacuity guard)"
else bad "RED empty docs" "rc=$rc out=$(printf '%s' "$out" | head -2)"; fi
rm -rf "$d"

# 8. Every reason must be a MECHANISM, not a bare restatement. A reason of "it is not needed" is a
#    row nobody can review; the point of the table is that each decision is auditable.
short=0
while IFS=$'\t' read -r _ k _ why; do
  case "${k:-}" in ''|'#'*) continue ;; esac
  if [ "${#why}" -lt 20 ]; then printf '     thin reason: %s (%s)\n' "$k" "$why"; short=$((short+1)); fi
done < <(grep -vE '^\s*(#|$)' "$ROOT/docs/walk-env-manifest.tsv")
if [ "$short" -eq 0 ]; then ok "every reason is at least a sentence"
else bad "thin reasons" "$short row(s) under 20 chars"; fi

printf '\n  walk-env-manifest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
