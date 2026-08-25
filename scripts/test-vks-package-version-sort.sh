#!/usr/bin/env bash
# The VKS-package version selection must sort by VERSION, not lexicographically (B476 F7).
#
# `vks-package.sh install` with no PKG_VERSION takes the NEWEST offered version -- so the default
# FLOATS, in a repo built on pinning. Both selection sites must agree: `_versions` (feeds `tail -1`,
# the actual default) and `_list`'s LATEST column (what `make list-vks-packages` calls newest).
#
# EVERY case below EXECUTES THE PRODUCT'S OWN KEY, sourced from vks-package.sh.
# The previous version of this file grep'd for a literal and executed a PASTED COPY of the
# expression. Both were vacuous: deleting `| sort -V` from the product left it 7/7 GREEN, because
# the grep matched the product's own COMMENT (the "greps a SYMBOL NAME, also matches the DOCSTRING"
# defect), and the pasted copy could not notice the product diverging from it. Do not reintroduce
# either: if a case does not run `$_VKEY` read out of the product file, it proves nothing.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# Lift _VKEY out of the product WITHOUT running it (the script needs a cluster). A single-quoted
# shell assignment, so sed can carve it precisely; the guard below fails loudly if it ever moves.
# shellcheck disable=SC2016  # the single quotes are DELIBERATE: this carves jq SOURCE out of the
# product, and expanding $raw / $core / $build here would corrupt the very thing under test.
_VKEY="$(sed -n "/^_VKEY='/,/;'$/p" "$ROOT/scripts/vks-package.sh" | sed "1s/^_VKEY='//; \$s/'$//")"
# shellcheck disable=SC2016  # a jq-source PATTERN, not an expansion.
case "$_VKEY" in
  *'def vkey:'*'$raw ];') ok "extracted _VKEY from the product ($(printf '%s' "$_VKEY" | wc -l) lines)" ;;
  *) bad "extract _VKEY from vks-package.sh" "got ${#_VKEY} bytes; the assignment moved or changed shape -- every case below would be VACUOUS, so this is fatal"; printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"; exit 1 ;;
esac

# latest <version>... -> what the product's key floats to. This is the actual default install.
latest() { printf '%s\n' "$@" | jq -R -s -r "$_VKEY"' [splits("\n")|select(length>0)]|sort_by(vkey)|last'; }
want() { # want <label> <expected> <version>...
  local label="$1" exp="$2"; shift 2
  local got; got="$(latest "$@")"
  # if/then/else, NOT `A && ok || bad`: SC2015 -- if ok ever returns non-zero the bad branch runs
  # too, which is the fake-green shape this repo's own rules forbid for any pass/fail decision.
  if [ "$got" = "$exp" ]; then ok "$label"; else bad "$label" "want '$exp', got '$got'"; fi
}

want "two-digit minor beats single (the lexicographic trap)" 1.100.0+vmware.1-vks.1 \
     1.27.8+vmware.1-vks.1 1.28.5+vmware.1-vks.1 1.9.0+vmware.1-vks.1 1.100.0+vmware.1-vks.1
want "two-digit vmware build beats single" 1.28.5+vmware.10-vks.1 \
     1.28.5+vmware.2-vks.1 1.28.5+vmware.10-vks.1
want "a vmware build beats the bare version (the toybox divergence)" 1.28.5+vmware.2-vks.1 \
     1.28.5 1.28.5+vmware.1-vks.1 1.28.5+vmware.2-vks.1
want "GA outranks its own prerelease -- the float must NEVER be an rc" 1.28.5 1.28.5 1.28.5-rc1
want "...and that does not depend on input ORDER (the key is total)" 1.28.5 1.28.5-rc1 1.28.5
want "a v-prefix does not zero the component" v1.30.0 v1.30.0 1.29.0
want "today's real istio list still floats to the newest" 1.30.3+vmware.1-vks.1 \
     1.26.5+vmware.1-vks.1 1.27.4+vmware.1-vks.1 1.28.3+vmware.1-vks.1 \
     1.29.2+vmware.1-vks.1 1.30.1+vmware.1-vks.1 1.30.3+vmware.1-vks.1

# CONTROLS. These prove the FIXTURES discriminate -- that a wrong key really would be caught.
# shellcheck disable=SC2016  # jq program text below, not shell expansion.
if [ "$(printf '%s\n' 1.9.0 1.100.0 | jq -R -s -r '[splits("\\n")|select(length>0)]|sort|last')" = 1.9.0 ]; then
  ok "control: a bare lexicographic sort DOES pick wrong here"
else
  bad "control: lexicographic picks wrong" "it agreed -- these fixtures no longer discriminate"
fi
if [ "$(printf '%s\n' 1.28.5 1.28.5-rc1 | jq -R -s -r "$_VKEY"' [splits("\\n")|select(length>0)]|sort_by(vkey)|last')" \
   != "$(printf '%s\n' 1.28.5 1.28.5-rc1 | sort -V | tail -1)" ]; then
  ok "control: our key DIFFERS from sort -V on GA-vs-rc (deliberate)"
else
  bad "control: GA-vs-rc differs from sort -V" "they agreed -- one of them changed"
fi

# The two sites must be the SAME code path. A second hand-written sort is the defect this file
# exists to prevent, and it is what shipped in #989.
n="$(grep -c 'sort_by(vkey)' "$ROOT/scripts/vks-package.sh")"
if [ "$n" = 2 ]; then
  ok "both selection sites use the shared vkey (2 uses)"
else
  bad "both sites use vkey" "found $n uses of sort_by(vkey); a site was removed or a third appeared"
fi
# Strip COMMENT lines before matching. The product's comments explain at length WHY `sort -V` is
# absent, so a bare grep for the literal matches the prose and reports the defect it is asserting
# against -- the same docstring-matching defect this file's header describes, inverted.
# HERESTRING, not a pipe: `producer | grep -q` lets grep exit at its first match, the producer takes
# SIGPIPE, and pipefail turns a FOUND pattern into ABSENT at random. check-grep-q-pipe caught this
# exact line in the very test written to prove a fix.
if grep -qE '\bsort[[:space:]]+-V\b' <<< "$(sed 's/^[[:space:]]*#.*//' "$ROOT/scripts/vks-package.sh")"; then
  bad "no sort -V in the product CODE" "sort -V is back; it is OS-dependent (toybox != GNU) and reintroduces the divergence"
else
  ok "no sort -V in the product CODE (OS-dependent, deliberately absent)"
fi

# A Package with no .spec.version must not abort the listing.
got="$(printf '{"items":[{"spec":{"refName":"a","version":"1.2.3"}},{"spec":{"refName":"b"}}]}' \
       | jq -r "$_VKEY"' [.items[]?|{r:.spec.refName,v:(.spec.version // "")}]|map(select(.v|length>0))|group_by(.r)|map({r:.[0].r,latest:(map(.v)|sort_by(vkey)|last)})|.[]|.r' 2>&1)"
if [ "$got" = a ]; then
  ok "a Package with no .spec.version is skipped, not fatal"
else
  bad "missing .spec.version tolerated" "got '$got' -- a schema surprise on ONE row kills the whole listing and gets reported as 'no Carvel Packages visible'"
fi

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
