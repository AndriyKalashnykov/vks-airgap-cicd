#!/usr/bin/env bash
# ci-tier: fast — offline; a stub curl on PATH. No network, no cluster.
#
# test-harbor-probe.sh — RED-proofs for lib/harbor-probe.sh (B527).
#
# WHY THE THREE-VERDICT SHAPE IS THE THING UNDER TEST. A **private** project answers an anonymous
# query with `[]` — byte-identical to a MISSING one. Collapsing that to two verdicts would tell a
# tenant to run `make mirror` against a Harbor that is fine, which is the same class of wrong-cause
# error the probe exists to remove. So `[]` is decisive ONLY when a credential was supplied.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# A stub `curl` that echoes a canned body and exits with a canned rc. It also RECORDS its argv so a
# case can assert the credential never reached it.
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_ARGV:-/dev/null}"
printf '%s' "${STUB_BODY:-}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH"

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh" >/dev/null 2>&1
# shellcheck source=scripts/lib/harbor-probe.sh
. "${SCRIPT_DIR}/lib/harbor-probe.sh"

_probe() { # _probe <body> <rc> <user> <pass> -> the verdict
  STUB_BODY="$1" STUB_RC="$2" HARBOR_URL=h.example \
  HARBOR_USERNAME="${3:-}" HARBOR_PASSWORD="${4:-}" harbor_project_state cicd
}

# ── the decisive cases: a credential is present, so `[]` MEANS absent ────────────────────────────
[ "$(_probe '[]' 0 u p)" = absent ] \
  && ok "credentialed + [] -> absent (decisive)" || bad "credentialed [] must be absent"
[ "$(_probe '[{"name":"cicd","repo_count":37}]' 0 u p)" = present ] \
  && ok "a project with repositories -> present" || bad "a populated project must be present"

# `repo_count: 0` is the SECOND half of the measured incident — the project exists and holds
# nothing. A per-image probe would call that "one image missing"; it is "nothing was ever mirrored".
[ "$(_probe '[{"name":"cicd","repo_count":0}]' 0 u p)" = empty ] \
  && ok "an EXISTING but EMPTY project -> empty (the incident's second half)" || bad "repo_count 0 must be empty"

# ── the honest cases: no credential, so `[]` is AMBIGUOUS with a private project ─────────────────
[ "$(_probe '[]' 0 '' '')" = inconclusive ] \
  && ok "ANONYMOUS + [] -> inconclusive, NOT absent (a private project looks identical)" \
  || bad "an anonymous [] must never be reported as absent — it would send a tenant to make mirror
        against a Harbor that is fine"

# ── an unreachable Harbor is not an empty one ───────────────────────────────────────────────────
[ "$(_probe '' 7 u p)" = inconclusive ] \
  && ok "curl failure -> inconclusive (reachability is lab-preflight's job, not this probe's)" \
  || bad "a curl failure must not be reported as absent"

# ── garbage body -> inconclusive, never a pass and never a false accusation ──────────────────────
[ "$(_probe '<html>502 Bad Gateway' 0 u p)" = inconclusive ] \
  && ok "an unparseable body -> inconclusive" || bad "garbage must be inconclusive"

# ── THE CREDENTIAL MUST NEVER REACH ARGV ────────────────────────────────────────────────────────
# The repo's standing rule: anything in argv is world-readable via ps/proc for the call's lifetime.
_argv="$STUB/argv"; : > "$_argv"
STUB_ARGV="$_argv" _probe '[]' 0 'robot$ci' 'sup3rs3cret' >/dev/null
if grep -q 'sup3rs3cret' "$_argv"; then
  bad "the Harbor password REACHED curl's argv" "it must travel in a umask-077 -K config file"
else
  ok "the credential never reaches argv (it goes in a -K config file)"
fi
grep -q -- '-K' "$_argv" && ok "curl was invoked with -K (the config-file path)" || bad "expected -K in argv"

# ── the escape hatch, and the loud-SKIP discipline ───────────────────────────────────────────────
out="$(HARBOR_IMAGE_PREFLIGHT=0 HARBOR_URL=h.example harbor_assert_mirrored cicd x 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'disabled'; then
  ok "HARBOR_IMAGE_PREFLIGHT=0 -> skips, and SAYS it skipped"
else bad "the escape hatch must skip and announce itself; rc=$rc"; fi

out="$(HARBOR_URL='' harbor_assert_mirrored cicd x 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not a pass'; then
  ok "no HARBOR_URL -> SKIPPED, and says 'not a pass'"
else bad "an unset HARBOR_URL must skip loudly, never silently pass; rc=$rc"; fi

# ── and the assertion DIES on the measured incident state, naming `make mirror` ──────────────────
out="$(STUB_BODY='[]' STUB_RC=0 HARBOR_URL=h.example HARBOR_USERNAME=u HARBOR_PASSWORD=p \
       harbor_assert_mirrored cicd istio 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'make mirror'; then
  ok "the incident state -> DIES naming 'make mirror' (not a credential problem)"
else bad "an absent project must die and name make mirror; rc=$rc"; fi

# ...but an ANONYMOUS caller in the same state must NOT be blocked.
out="$(STUB_BODY='[]' STUB_RC=0 HARBOR_URL=h.example HARBOR_USERNAME='' HARBOR_PASSWORD='' \
       harbor_assert_mirrored cicd istio 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not a pass'; then
  ok "an ANONYMOUS tenant is never BLOCKED by an ambiguous [] (RULE ZERO-B)"
else bad "an anonymous caller must not be blocked on an ambiguous result; rc=$rc"; fi

printf '\ntest-harbor-probe: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
