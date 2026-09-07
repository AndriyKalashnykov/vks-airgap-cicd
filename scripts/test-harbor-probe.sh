#!/usr/bin/env bash
# ci-tier: fast — offline; a stub curl on PATH. No network, no cluster.
#
# test-harbor_probe.sh — RED-proofs for lib/harbor_probe.sh (B527).
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
printf '%s\n%s' "${STUB_BODY:-}" "${STUB_CODE:-200}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH"

# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh" >/dev/null 2>&1
# shellcheck source=scripts/lib/harbor_probe.sh
. "${SCRIPT_DIR}/lib/harbor_probe.sh"

# _probe <body> <rc> <user> <pass> [http-code] -> the verdict
# HARBOR_INSECURE=1 gives a VERIFIABLE context (the operator chose it), which is what lets the
# credential be sent at all — see the "never send a credential we cannot verify" arm.
_probe() {
  STUB_BODY="$1" STUB_RC="$2" STUB_CODE="${5:-200}" HARBOR_URL=h.example HARBOR_INSECURE=1 \
  HARBOR_USERNAME="${3:-}" HARBOR_PASSWORD="${4:-}" harbor_project_state cicd
}

# ── the decisive cases: a credential is present, so `[]` MEANS absent ────────────────────────────
if [ "$(_probe '' 0 u p 404)" = absent ]; then ok "HTTP 404 -> absent (the exact-project endpoint answers directly)"
else bad "a 404 from /projects/<name> must be absent"; fi
if [ "$(_probe '{"name":"cicd","repo_count":37}' 0 u p)" = present ]; then
  ok "a project with repositories -> present"
else bad "a populated project must be present"; fi

# `repo_count: 0` is the SECOND half of the measured incident — the project exists and holds
# nothing. A per-image probe would call that "one image missing"; it is "nothing was ever mirrored".
if [ "$(_probe '{"name":"cicd","repo_count":0}' 0 u p)" = empty ]; then
  ok "an EXISTING but EMPTY project -> empty (the incident's second half)"
else bad "repo_count 0 must be empty"; fi

# ── the honest cases: no credential, so `[]` is AMBIGUOUS with a private project ─────────────────
if [ "$(_probe '' 0 '' '' 403)" = inconclusive ]; then
  ok "a 403 (private, not visible to me) -> inconclusive, never absent"
else
  bad "a 403 must never be reported as absent — it would send a tenant to make mirror against a
        Harbor that is fine"
fi

# ── an unreachable Harbor is not an empty one ───────────────────────────────────────────────────
if [ "$(_probe '' 7 u p)" = inconclusive ]; then
  ok "curl failure -> inconclusive (reachability is lab-preflight's job, not this probe's)"
else bad "a curl failure must not be reported as absent"; fi

# ── garbage body -> inconclusive, never a pass and never a false accusation ──────────────────────
if [ "$(_probe '<html>502 Bad Gateway' 0 u p 502)" = inconclusive ]; then
  ok "an unparseable body -> inconclusive"
else bad "garbage must be inconclusive"; fi

# ── THE CREDENTIAL MUST NEVER REACH ARGV ────────────────────────────────────────────────────────
# The repo's standing rule: anything in argv is world-readable via ps/proc for the call's lifetime.
_argv="$STUB/argv"; : > "$_argv"
# A literal `$` in the username on purpose: Harbor robots are named `robot$<project>`, and it must
# reach the -K file UNEXPANDED. Single quotes are required; that is what SC2016 would object to.
# shellcheck disable=SC2016
STUB_ARGV="$_argv" _probe '[]' 0 'robot$ci' 'sup3rs3cret' >/dev/null
if grep -q 'sup3rs3cret' "$_argv"; then
  bad "the Harbor password REACHED curl's argv" "it must travel in a umask-077 -K config file"
else
  ok "the credential never reaches argv (it goes in a -K config file)"
fi
if grep -q -- '-K' "$_argv"; then ok "curl was invoked with -K (the config-file path)"
else bad "expected -K in argv"; fi

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
out="$(STUB_BODY='' STUB_CODE=404 STUB_RC=0 HARBOR_URL=h.example HARBOR_INSECURE=1 \
       HARBOR_USERNAME=u HARBOR_PASSWORD=p harbor_assert_mirrored cicd istio 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'make mirror'; then
  ok "the incident state -> DIES naming 'make mirror' (not a credential problem)"
else bad "an absent project must die and name make mirror; rc=$rc"; fi

# ...but an ANONYMOUS caller in the same state must NOT be blocked.
out="$(STUB_BODY='' STUB_CODE=403 STUB_RC=0 HARBOR_URL=h.example HARBOR_USERNAME='' HARBOR_PASSWORD='' \
       harbor_assert_mirrored cicd istio 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not a pass'; then
  ok "an ANONYMOUS tenant is never BLOCKED by an ambiguous 403 (RULE ZERO-B)"
else bad "an anonymous caller must not be blocked on an ambiguous result; rc=$rc"; fi

# ── an EMPTY project name must SKIP, never die. The call sites used to pass
#    `"${HARBOR_INFRA_PROJECT:?}"`, and in 49-install-headlamp.sh that line sits 49 lines ABOVE the
#    first `mirror_target_ref` — the code that genuinely needs the var and dies naming what it was
#    resolving. A preflight added to improve a diagnostic must not PRE-EMPT a better one with a bare
#    "parameter null or not set".
out="$(HARBOR_URL=h.example harbor_assert_mirrored "" istio 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not a pass'; then
  ok "an EMPTY project name -> SKIPPED loudly, never a die that pre-empts a better error"
else bad "an empty project must skip, not die; rc=$rc"; fi

printf '\ntest-harbor-probe: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
