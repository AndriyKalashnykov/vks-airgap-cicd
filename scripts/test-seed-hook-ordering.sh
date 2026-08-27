#!/usr/bin/env bash
# test-seed-hook-ordering.sh — the webhook DELETE must precede the app push; the CREATE must follow it.
#
# WHY (measured 2026-08-27, e2e run 8). The whole webhook block used to run AFTER push_repo. On a
# WARM cluster the pre-existing hook is live and its HMAC comes from the persisted
# secrets/webhook-token, so the seed push was ACCEPTED and fired a PipelineRun per app that nothing
# waited for -- 4 of 6 apps, in a 6-second burst. Deterministic in REGISTRY ORDER, not intermittent:
# the seed->marker gap grows with position against ArgoCD's 180s default (36s PASS, 165s PASS,
# 214s FAIL), and invisible on a cold cluster where no stale hook exists.
#
# ⚠️ THE OBVIOUS PROOF IS A FAKE-GREEN, and that is why this file exists. "zero PipelineRuns across
# make seed-gitea" is ALSO the exact signature of the worst regression this change can cause -- the
# hook deleted and NEVER RECREATED. Gitea never returns the secret, so the hook LIST is the only
# witness. Any live assertion must carry BOTH arms: exactly one hook with the EventListener url
# after the seed, AND one PipelineRun from the next real push.
#
# This offline test guards the ORDERING only. It cannot see the live behaviour; the live proof must
# be a WARM run, because a cold cluster cannot reproduce the bug at all.
set -uo pipefail
S="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/50-seed-gitea-repos.sh"
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
       else printf '  FAIL  %s (want %s, got %s)\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }

exe() { grep -vnE '^[[:space:]]*#' "$S"; }
ln_of() { exe | grep -m1 -E "$1" | cut -d: -f1; }

del=$(ln_of '\-X DELETE .*hooks_api')
app=$(ln_of 'push_repo "\$\{REPO_ROOT\}/\$\{APP_SRC\}"')
pst=$(ln_of '\-X POST -d @"\$\{tmp\}/hook-')

printf '== seed hook ordering ==\n'
[ -n "$del" ] && [ -n "$app" ] && [ -n "$pst" ] || { echo "  FAIL  could not locate all three lines"; exit 1; }
ck "the hook DELETE precedes the app push"        "$([ "$del" -lt "$app" ] && echo yes || echo no)" "yes"
ck "the hook CREATE follows the app push"         "$([ "$pst" -gt "$app" ] && echo yes || echo no)" "yes"
ck "the refuse-rather-than-guess gate also precedes the push" \
   "$([ "$(ln_of 'REFUSING to POST')" -lt "$app" ] && echo yes || echo no)" "yes"
# The CREATE must still be a POST, not a PATCH: PATCH cannot set config.secret (measured upstream),
# so a "tidier" PATCH would leave the hook carrying a stale HMAC that silently rejects every push.
ck "the hook is (re)created with POST, never PATCH" \
   "$(exe | grep -c '\-X PATCH .*hooks_api')" "0"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
