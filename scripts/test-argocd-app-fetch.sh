#!/usr/bin/env bash
# test-argocd-app-fetch.sh — offline, hermetic. Drives argocd_app_fetch_verdict with a STUB `argocd`.
#
# WHY THIS EXISTS. The MECH=api (TENANT) branch of 70-configure-argocd.sh has NEVER EXECUTED in any
# recorded walk run — measured: 0 hits for "kubectl cannot read them on this path" across the 158
# logs in /tmp/walk, because scenario-2 dies ~500 lines earlier at the mechanism gate. So this suite
# is the only thing that will ever have exercised it before a real lab does, and the logic was moved
# out of the script body specifically so that it could be.
#
# THE PROPERTY UNDER TEST is not "does it wait". It is: **can it tell apart the FIVE outcomes that
# have five different remedies?** — the repo genuinely failed to fetch / something OTHER than the
# repo failed the comparison / the controller never judged it / the CLI could not be reached /
# the reply could not be parsed. The old code collapsed all of them into one sentence naming Gitea.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

export ARGOCD_REPO_TIMEOUT_SECONDS=2   # keep the suite fast; the count is not what is under test

# run <mode> [witness] -> "state|msg"
# ⚠️ PRODUCTION OPTIONS. lib/argocd.sh has no `set` line of its own and inherits
# 70-configure-argocd.sh:21 (`set -euo pipefail`). The sibling suite scored three clean greens over
# broken implementations by running the subject under weaker options; do not repeat it here.
# run <mode> [witness] -> "state|msg"
# ⚠️ THE STUB IS A SCRIPT ON $PATH, NOT A SHELL FUNCTION. argocd_app_fetch_verdict wraps the call in
# `timeout`, and timeout(1) EXECS A BINARY — a bash function named `argocd` is invisible to it. The
# sibling suite can stub `ka` as a function only because nothing wraps that call. This is the same
# device scripts/test-argocd-preflight-ns.sh uses for kubectl. It also means the test exercises the
# REAL timeout wrapper rather than a stand-in for it.
#
# ⚠️ PRODUCTION OPTIONS. lib/argocd.sh has no `set` line of its own and inherits
# 70-configure-argocd.sh:21 (`set -euo pipefail`). The sibling suite scored three clean greens over
# broken implementations by running the subject under weaker options; do not repeat it here.
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT
cat > "$STUBDIR/argocd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${WITNESS:-/dev/null}"
case "${STUB_MODE:-}" in
  cli)   echo 'FATA[0000] rpc error: code = Unavailable desc = connection error' >&2; exit 1 ;;
  hang)  sleep 30 ;;
  repo)  printf '%s' '{"status":{"sync":{"status":"Unknown"},"conditions":[{"type":"ComparisonError","message":"Failed to load target state: rpc error: failed to get git client for repo http://gitea.invalid:3000/demo/x-deploy.git"}]}}' ;;
  live)  printf '%s' '{"status":{"sync":{"status":"Unknown"},"conditions":[{"type":"ComparisonError","message":"Failed to load live state: cluster https://guest:6443 not found"}]}}' ;;
  nocmp) printf '%s' '{"status":{"sync":{"status":"Unknown"}}}' ;;
  ok)    printf '%s' '{"status":{"sync":{"status":"Synced"},"conditions":[]}}' ;;
  junk)  printf '%s' 'this is not json at all' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/argocd"

run() {
  # ⚠️ CAPTURE, THEN DECIDE — never `) … || printf`. A trailing `||` makes the subshell the LEFT
  # OPERAND of an AND-OR list, and bash suppresses errexit INSIDE it; the subshell's own
  # `set -euo pipefail` does NOT restore it. MEASURED: a mutant killing argocd_app_fetch_verdict on
  # EVERY path scored 12/0 — the suite was totally blind to the deaths it exists to catch.
  #
  # The `||` form has a second defect the capture also fixes: on a death AFTER the printf it emitted
  # BOTH the partial line and SUBJECT-DIED, and `case "$out" in ok|*)` matched the first, scoring a
  # PASS. Capturing means only one verdict is ever emitted.
  #
  # THE REDIRECT IS INSIDE THE SUBSTITUTION, ON THE SUBSHELL, and that placement is load-bearing:
  # `out="$( … )" 2>/dev/null` does NOT redirect the substitution — for a command consisting only of
  # assignments, expansions run BEFORE redirections — so the stub's stderr escapes into the report.
  # MEASURED: 8 leaks with the redirect outside, 0 with it inside.
  #
  # `rc=$?` on its OWN LINE, never `|| rc=$?` — that reintroduces the very suppression above
  # (measured: rc=0 and the post-death marker printed). scripts/test-argocd-version.sh:43 is the
  # other correct instance of this pattern in the repo; copy from there.
  local out rc
  out="$( ( set -euo pipefail
            export STUB_MODE="$1" WITNESS="${2:-/dev/null}" PATH="$STUBDIR:$PATH"
            argocd_app_fetch_verdict testapp
            printf '%s|%s\n' "$_afv_state" "$_afv_msg"
            rm -f "$_afv_err" ) 2>/dev/null )"
  rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; else printf 'SUBJECT-DIED|\n'; fi
}

echo
echo "════════ argocd_app_fetch_verdict — five outcomes, five remedies ════════"
echo

out="$(run ok)"
case "$out" in ok\|*)  ok "a clean post-refresh reply is ok (state=${out%%|*})" ;;
  *) bad "clean reply -> ok" "got: $out" ;; esac

out="$(run repo)"
case "$out" in repo\|*) ok "'Failed to load target state:' is the REPO — the one arm that may say so" ;;
  *) bad "target-state -> repo" "got: $out" ;; esac

echo
echo "== THE DECISIVE CASE: same condition TYPE, a DIFFERENT producer =="
out="$(run live)"
case "$out" in notrepo\|*) ok "'Failed to load live state:' is NOT the repo (it is the destination cluster)" ;;
  *) bad "live-state must NOT be 'repo'" "got: $out — matching the bare ComparisonError type would blame Gitea for a guest-credential fault" ;; esac
case "$out" in *"not found"*) ok "and it carries argo-cd's OWN words forward" ;;
  *) bad "carries the message" "got: $out" ;; esac

echo
echo "== the remaining three =="
out="$(run nocmp)"
case "$out" in unknown\|*) ok "Unknown with NO condition = the controller never judged it" ;;
  *) bad "no-condition Unknown" "got: $out" ;; esac

out="$(run cli)"
case "$out" in cli\|*) ok "a CLI failure is its own state, not a repo verdict" ;;
  *) bad "cli failure" "got: $out" ;; esac

out="$(run junk)"
case "$out" in parse\|*) ok "an unparseable reply is 'parse' — NEVER a silent 'the repo is fine'" ;;
  *) bad "unparseable -> parse" "got: $out" ;; esac

echo
echo "== the timeout wrapper (argocd app get has NO --timeout flag) =="
out="$(run hang)"
case "$out" in cli\|*) ok "a hanging CLI is cut off and reported as cli, not left to block forever" ;;
  *) bad "hang -> cli" "got: $out" ;; esac
case "$out" in *"did not return within"*) ok "and it names the timeout explicitly" ;;
  *) bad "names the timeout" "got: $out" ;; esac

echo
echo "== the MECHANISM: a soft refresh must actually be requested =="
# Without --refresh the call cannot force a Level-3 comparison, so the repo-error short-circuit
# stays armed and the whole gate is a no-op. Assert the flag reaches the CLI.
W="$(mktemp)"; run ok "$W" >/dev/null; wit="$(cat "$W")"; rm -f "$W"
case "$wit" in *--refresh*) ok "--refresh IS passed (without it the short-circuit stays armed)" ;;
  *) bad "--refresh is passed" "witness=[$wit]" ;; esac
case "$wit" in *--hard-refresh*) bad "must NOT use --hard-refresh" "it adds a per-app NoCache render whose failure is only log.Warnf'ed — more cost, no more proof" ;;
  *) ok "and NOT --hard-refresh (soft already selects Level 3)" ;; esac
case "$wit" in *"-o json"*) ok "it asks for json (there is no jsonpath output on this subcommand)" ;;
  *) bad "asks for json" "witness=[$wit]" ;; esac

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
