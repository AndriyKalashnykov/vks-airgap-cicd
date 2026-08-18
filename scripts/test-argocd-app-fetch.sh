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
  # nostatus: NO .status.sync at all — a freshly-created Application the controller has not judged.
  # This is the state this suite could not previously express, and it is the one the read
  # MANUFACTURES: `jq -r '.status.sync.status // ""'` turns a missing path into "". Under the old
  # `[ "$_sst" = Unknown ]` test that fell through to the healthy arm and the function AFFIRMED `ok`,
  # so the caller logged "<app>: synced (argocd-server)" for an app nothing had compared — on the
  # TENANT path, the one branch never exercised by any recorded walk run.
  nostatus) printf '%s' '{"status":{}}' ;;
  # repo2nd: TWO conditions with the repo message SECOND. Before the leading separator this
  # classified `notrepo` here while the kubectl path called it `repo` — the same Application, two
  # mechanisms, opposite verdicts, selectable with one variable (B177).
  repo2nd) printf '%s' '{"status":{"sync":{"status":"Unknown"},"conditions":[{"type":"ComparisonError","message":"gpg signature check failed"},{"type":"ComparisonError","message":"Failed to load target state: rpc error: repo unreachable"}]}}' ;;
  ok)    printf '%s' '{"status":{"sync":{"status":"Synced"},"conditions":[]}}' ;;
  junk)  printf '%s' 'this is not json at all' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/argocd"

# run <mode> [witness] -> "state|msg"
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

out="$(run repo2nd)"
case "$out" in repo\|*) ok "a repo message that is NOT FIRST is still the repo (matches the sibling)" ;;
  *) bad "position-independent prefix test" "got: $out — without a LEADING separator this says notrepo while the kubectl path says repo, on the same Application" ;; esac

out="$(run nostatus)"
case "$out" in unknown\|*) ok "NO .status.sync at all is 'unknown' — the controller never judged it" ;;
  *) bad "an unjudged app must NOT be affirmed as ok" "got: $out — the read manufactures \"\" for a missing path, and affirming ok here makes the caller log '<app>: synced (argocd-server)' for an Application nothing compared" ;; esac
# The MESSAGE must not assert a value the read did not produce. It used to hardcode
# "sync.status=Unknown", which is a claim about a status that is actually EMPTY, printed verbatim by
# the caller. Same class as the guard against claiming "no conditions" when the read FAILED.
case "$out" in *"sync.status=<none>"*) ok "and it reports the status it actually read, not a hardcoded 'Unknown'" ;;
  *) bad "must interpolate the status" "got: $out" ;; esac

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
# ⚠️ GATED ON A NON-EMPTY WITNESS. A bare negative passes VACUOUSLY on an empty witness — measured:
# under a mutant that kills the function on every path this case still scored a PASS, because
# "nothing was recorded" satisfies "--hard-refresh was not used". Pair it with the positive above.
case "$wit" in
  '') bad "the witness is EMPTY" "the negative below would pass vacuously — nothing was recorded, so there is nothing to be absent" ;;
  *--hard-refresh*) bad "must NOT use --hard-refresh" "it adds a per-app NoCache render whose failure is only log.Warnf'ed — more cost, no more proof" ;;
  *) ok "and NOT --hard-refresh (soft already selects Level 3)" ;;
esac
case "$wit" in *"-o json"*) ok "it asks for json (there is no jsonpath output on this subcommand)" ;;
  *) bad "asks for json" "witness=[$wit]" ;; esac

echo
echo "════════ the MECH=api readback must not be gated on an RBAC probe ════════"
# THE DEFECT THIS PINS, measured on certification row 5 (2026-08-18): the api-path readback was
# SELECTED by `kubectl auth can-i get applications.argoproj.io`. That is a PURE RBAC question, and
# when the resource type is not served at all kubectl WARNS to stderr and answers `yes` — measured
# against an apiserver with no argoproj.io group, using this repo's pinned kubectl 1.36.3. k_can_i
# then `rm -f`s that stderr unread (os.sh:1389), so the probe reported a confident `yes`, control
# fell through to the KUBECTL readback, and it died on a guest cluster with "the server doesn't have
# a resource type application" — killing the row. The write went through argocd-server; so must the
# read.
#
# ⚠️ COMMENTS ARE STRIPPED FIRST, AND THAT IS LOAD-BEARING. The fix's own comment QUOTES the
# forbidden command — it has to, to explain the measurement — so a naive grep self-matches:
# MEASURED 2 raw hits, both prose, 0 in code. A gate that reads a file it guards must look at the
# CODE, or it goes red on the day someone documents the trap properly.
_cfg="${SCRIPT_DIR}/70-configure-argocd.sh"
_code="$(awk '{ s=$0; sub(/^[[:space:]]+/,"",s); if (substr(s,1,1) != "#") print }' "$_cfg")"

if printf '%s' "$_code" | grep -q 'auth can-i get applications'; then
  bad "the api readback is not gated on 'auth can-i get applications'" \
      "an RBAC probe answers 'yes' for a resource type the cluster does not serve — it cannot select a transport"
else
  ok "the api readback is not gated on an 'auth can-i get applications' probe"
fi

# ...and the branch routing to argocd-server must be UNCONDITIONAL on MECH=api. Absence of the old
# probe is not enough on its own — a DIFFERENT conditional could be reintroduced and be wrong the
# same way.
# shellcheck disable=SC2016  # the \$ is LITERAL on purpose: we are matching the TEXT `"$MECH"`
# as it appears in the file, not expanding a variable. Proven by the RED-proof below.
if printf '%s' "$_code" | grep -qE '^if \[ "\$MECH" = api \]; then'; then
  ok "...and MECH=api routes to argocd-server unconditionally"
else
  bad "MECH=api routes to argocd-server unconditionally" \
      "the api readback is conditional again; whatever selects it can be wrong the way auth can-i was"
fi

# ...while MECH=kubectl still reaches the kubectl readback. A fix that greened rows 5/6 by deleting
# the scenario-1 path would be a loss — rows 1-4 are the ones currently passing.
# shellcheck disable=SC2016  # literal `"$app"` again — matching source text, not expanding.
if printf '%s' "$_code" | grep -q 'argocd_await_revision "\$app"'; then
  ok "...and the kubectl readback still exists for MECH=kubectl (rows 1-4 unaffected)"
else
  bad "the kubectl readback still exists" "argocd_await_revision is gone — scenario-1 lost its fetch gate"
fi

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
