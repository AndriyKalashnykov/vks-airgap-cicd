#!/usr/bin/env bash
# test-gitea-hook-ids.sh — OFFLINE unit test for gitea_hook_ids (lib/os.sh).
#
# WHY THIS SHAPE, and not a container test of Gitea.
# --------------------------------------------------
# The tempting test was: run the pinned gitea image, create a hook, prove DELETE+POST rotates the
# secret. An adversary round refuted it (2026-08-12): `50-seed-gitea-repos.sh` needs a kubeconfig,
# `kubectl exec deploy/gitea` and `kubectl port-forward`, so a standalone container executes NONE of
# seed_app — every assertion would be made by the test's own curl. DELETE the entire reconcile block
# and that test still passes 4/4. It would have measured GITEA, not US.
#
# This repo already has a pattern for "our code path rests on a third-party behaviour", used three
# times — verify-gateway-image, mirror-verify, check-pod-inject-label — and all three assert the
# CONSEQUENCE over OUR OWN artifacts. This test is that pattern: the upstream fact (Gitea cannot
# PATCH a webhook secret; it never returns one) is recorded as a graded comment where the code uses
# it, and what gets TESTED is our selector, offline, on every PR.
#
# THE DEFECT IT PINS (live in main when this was written, from the fix one commit earlier):
#   ids="$(... | jq ... 2>/dev/null || true)"  +  if [ -n "$ids" ]; then delete; fi  +  POST always
# An error body makes jq exit 5 with empty stdout, which read as "no hooks" -> no DELETE -> POST
# anyway -> the STALE-SECRET hook survives AND a duplicate appears. Both bugs the fix addressed,
# reachable in exactly the cell where that class already cost a walk row.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
require_cmd jq

U='http://el-apps.ci.svc:8080'
pass=0; fail=0
check() {  # check <name> <want-rc> <want-ids-space-separated> <body>
  local name="$1" wrc="$2" wids="$3" body="$4" got grc
  got="$(gitea_hook_ids "$body" "$U")"; grc=$?
  got="$(printf '%s' "$got" | tr '\n' ' ' | sed 's/ *$//')"
  if [ "$grc" = "$wrc" ] && [ "$got" = "$wids" ]; then
    pass=$((pass + 1)); printf '  ok   %-42s rc=%s ids=[%s]\n' "$name" "$grc" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-42s rc=%s (want %s) ids=[%s] (want [%s])\n' "$name" "$grc" "$wrc" "$got" "$wids"
  fi
}

# --- the healthy shapes -------------------------------------------------------------------------
check "one hook, ours"            0 "3"   '[{"id":3,"config":{"url":"http://el-apps.ci.svc:8080"}}]'
check "two of ours (a duplicate)" 0 "1 7" '[{"id":1,"config":{"url":"http://el-apps.ci.svc:8080"}},{"id":7,"config":{"url":"http://el-apps.ci.svc:8080"}}]'
check "someone else's hook only"  0 ""    '[{"id":2,"config":{"url":"http://other.example/hook"}}]'
check "empty array"               0 ""    '[]'
# EXACT match, not substring: a longer URL that CONTAINS ours must not be deleted.
check "url is a prefix of another" 0 ""   '[{"id":9,"config":{"url":"http://el-apps.ci.svc:8080/extra"}}]'
check "hook with no config"       0 ""    '[{"id":4}]'

# --- THE ONES THAT MATTER: an error body must NOT read as "no hooks" -----------------------------
# Measured against a real Gitea/jq: each of these made jq exit 5 with empty stdout, and the old
# inline form turned that into "no hooks exist" -> skip the delete -> POST a duplicate.
check "401/403 error object"      2 ""    '{"message":"token does not have permission","url":"..."}'
check "502 HTML from a proxy"     2 ""    '<html><head><title>502 Bad Gateway</title></head></html>'
check "empty body (curl failed)"  2 ""    ''
check "truncated JSON"            2 ""    '[{"id":3,"config":{"url":"http://el'

printf '\ntest-gitea-hook-ids: %d passed, %d failed (%d cases)\n' "$pass" "$fail" "$((pass + fail))"
# FAIL-CHECK FIRST, then any skip — the reverse exits 0 on a run that printed FAIL
# (scripts/test-builder-save-crane.sh records that self-inflicted false-green).
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -gt 0 ] || { echo "no cases ran — this gate judged nothing"; exit 1; }
