#!/usr/bin/env bash
# check-vks-login-requires — creds.sh's hand-typed requirement map must agree with 30-vks-login.sh.
#
# WHY HAND-TYPED AT ALL. B207's idea round REFUTED deriving the map from the dispatch: 6 of 11
# mentions of these variable names in 30-vks-login.sh are COMMENTS, one a NOT-WIRED design note
# (:309-311) that a deriver reads as the wiring — the "a structural test that greps a SYMBOL NAME
# also matches the DOCSTRING" class in gates.md. So the map is typed, and THIS gate stops it rotting.
#
# WHAT IT KEYS ON. The USAGE FORM `${VAR:?` — the shape that actually dies — never the bare name.
# Comments are stripped first, because the name appears in prose in both files.
#
# ⚠️ WHAT IT DOES **NOT** CHECK, stated so nobody reads its green as more than it is: it compares
# the UNION of required variables, NOT which auth-method ARM each belongs to. 30-vks-login.sh nests
# four `case` blocks, and arm-scoping a shell parser is exactly the tractability problem that got
# derivation refuted. A variable moved from the `vcf` arm to the `vsphere` arm passes this gate.
# The set membership is what rots in practice (a new `:?` lands and the map never hears about it).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LOGIN=scripts/30-vks-login.sh
CREDS=scripts/creds.sh

# Vars that DIE in the login script: `${VAR:?...}` with comments stripped.
want="$(sed 's/#.*//' "$LOGIN" | grep -oE '\$\{[A-Z_][A-Z0-9_]*:\?' | grep -oE '[A-Z_][A-Z0-9_]*' | sort -u)"
# Vars the map lists, taken ONLY from inside _vks_login_requires().
have="$(sed -n '/^_vks_login_requires() {/,/^}/p' "$CREDS" | sed 's/#.*//' \
        | grep -oE "'[A-Z_][A-Z0-9_\\\\n]*'" | grep -oE '[A-Z_][A-Z0-9_]*' | sort -u)"

n_want=$(printf '%s\n' "$want" | grep -c . || true)
n_have=$(printf '%s\n' "$have" | grep -c . || true)

# An empty extraction on EITHER side makes the comparison vacuous ("" == ""), so guard both and
# name the file that produced nothing — gates.md's extract-then-compare vacuity class.
[ "$n_want" -gt 0 ] || { echo "ERROR: parsed ZERO \${VAR:?} requirements from ${LOGIN} — the extractor is blind, not the script clean."; exit 1; }
[ "$n_have" -gt 0 ] || { echo "ERROR: parsed ZERO variables from _vks_login_requires() in ${CREDS}."; exit 1; }

missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))"
# ── the SECOND kind of fatal ────────────────────────────────────────────────────────────────────
# Not every blocker dies at a `${VAR:?}`. VCF_CLI_VSPHERE_PASSWORD only WARNS (30-vks-login.sh:351)
# and then `vcf context create` runs with `</dev/null` UNCONDITIONALLY, so it cannot prompt and
# fails there instead. Measured 2026-08-21: no short-circuit between the warn and the call.
# So it belongs in the map, and this gate must not call it stale — but an ALLOWLIST that merely
# names it would rot into a lie the moment that mechanism changed. Assert the MECHANISM instead.
soft='VCF_CLI_VSPHERE_PASSWORD'
if printf '%s\n' "$have" | grep -qx 'VCF_CLI_VSPHERE_PASSWORD'; then
  _joined="$(sed 's/#.*//' "$LOGIN" | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
  if ! grep -qE 'vcf context create[^\n]*</dev/null' <<< "$_joined"; then
    echo "ERROR: the map lists VCF_CLI_VSPHERE_PASSWORD as fatal, but ${LOGIN} no longer runs"
    echo "       'vcf context create' with </dev/null - so it CAN prompt now, and the map is wrong."
    exit 1
  fi
  if ! grep -q 'VCF_CLI_VSPHERE_PASSWORD' <<< "$(sed 's/#.*//' "$LOGIN")"; then
    echo "ERROR: the map lists VCF_CLI_VSPHERE_PASSWORD, but ${LOGIN} never reads it."
    exit 1
  fi
fi
stale="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | grep -vxF "$soft" || true)"

rc=0
if [ -n "$missing" ]; then
  echo "ERROR: ${LOGIN} dies on these, but _vks_login_requires() in ${CREDS} never lists them:"
  printf '%s\n' "$missing" | while IFS= read -r _n; do [ -n "$_n" ] && printf '         %s\n' "$_n"; done
  echo "       => make creds would name the WRONG first blocker, or none."
  rc=1
fi
if [ -n "$stale" ]; then
  echo "ERROR: _vks_login_requires() lists these, but ${LOGIN} has no \${VAR:?} for them:"
  printf '%s\n' "$stale" | while IFS= read -r _n; do [ -n "$_n" ] && printf '         %s\n' "$_n"; done
  echo "       => make creds would report a blocker that does not block."
  rc=1
fi
[ $rc -eq 0 ] && echo "check-vks-login-requires: OK — ${n_want} required var(s) in ${LOGIN}, all present in the map (arm assignment NOT checked)"
exit $rc
