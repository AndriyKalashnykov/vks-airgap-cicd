#!/usr/bin/env bash
# test-argocd-kubeconfig-stale.sh — OFFLINE unit test for argocd_kubeconfig_stale_reason (B98).
#
# THE DEFECT IT PINS. 30-vks-login.sh published ARGOCD_KUBECONFIG only `if [ -z ... ]` — emptiness,
# not existence. So once ANY value reached .env/.env.state the step never published again, and a
# path naming a rebuilt lab's deleted kubeconfig survived forever. `is_placeholder` cannot catch it
# (MEASURED: it reports a nonexistent path as NOT-placeholder), so nothing else in the repo does.
# The consequence is not a loud failure: `make gitops` falls back to the GUEST kubeconfig, where
# argocd-server does not exist.
#
# WHY THIS TEST IS MANDATORY RATHER THAN NICE. The publish block lives inside
# `case "$METHOD" in vcf)`, and 05-kind-up.sh sets VKS_AUTH_METHOD=kubeconfig — so NO KinD e2e, no
# CI job and no static-check can ever execute it. This file is the only proof that path can have.
#
# THE THREE CASES THAT MATTER ARE A/B/C, AND THEY EXIST BECAUSE THE FIRST VERSION FAILED TWO OF
# THEM. It re-typed `{.clusters[0].cluster.server}` WITHOUT `--minify` — the first cluster in the
# FILE, not the one the current context resolves to. A real VKS kubeconfig always holds several,
# because `vcf context create` writes Supervisor contexts INTO the existing file and repoints
# current-context. Measured on this repo's own secrets/cicd-gc4.kubeconfig: un-minified reports the
# GUEST while kubectl dials the SUPERVISOR. Case A then wrongly clobbered a healthy file, and
# case C — the dangerous direction — wrongly declared healthy a kubeconfig whose current context is
# the GUEST, which is precisely the B98 failure the function exists to catch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"
require_cmd kubectl

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SUP='https://192.168.101.128:443'      # the shapes measured on a real lab artifact
GUEST='https://192.168.101.137:6443'
pass=0; fail=0

# kc <file> <current-context-server> [other-server-listed-FIRST]
# When the second server is given it is written as clusters[0], so the file's FIRST cluster is NOT
# the one current-context resolves to — the shape that broke the first implementation.
kc() {
  local f="$1" ctx_server="$2" first="${3:-}"
  { echo "apiVersion: v1"; echo "kind: Config"; echo "clusters:"
    [ -n "$first" ] && { echo "  - name: aaa-other"; echo "    cluster: { server: $first }"; }
    echo "  - name: zzz-current"; echo "    cluster: { server: $ctx_server }"
    echo "contexts:"
    [ -n "$first" ] && { echo "  - name: other"; echo "    context: { cluster: aaa-other, user: u }"; }
    echo "  - name: current"; echo "    context: { cluster: zzz-current, user: u }"
    echo "current-context: current"; echo "users:"; echo "  - name: u"; echo "    user: {}"
  } > "$f"
}

check() {  # check <name> <recorded> <supervisor> <want: EMPTY|substring>
  local name="$1" rec="$2" sup="$3" want="$4" got ok=1
  got="$(argocd_kubeconfig_stale_reason "$rec" "$sup")"
  if [ "$want" = EMPTY ]; then [ -z "$got" ] || ok=0
  else case "$got" in *"$want"*) ;; *) ok=0 ;; esac; fi
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf '  ok   %-46s -> [%s]\n' "$name" "$got"
  else fail=$((fail+1)); printf '  FAIL %-46s -> [%s] (want %s)\n' "$name" "$got" "$want"; fi
}

kc "$TMP/sup.kubeconfig"   "$SUP"
kc "$TMP/caseA.kubeconfig" "$SUP"   "$GUEST"   # ctx=Supervisor, clusters[0]=GUEST
kc "$TMP/caseC.kubeconfig" "$GUEST" "$SUP"     # ctx=GUEST,      clusters[0]=Supervisor
: > "$TMP/empty.kubeconfig"
printf 'not: a kubeconfig\n' > "$TMP/junk.kubeconfig"

echo "== the --minify cases (A/B/C) — each was got WRONG by the first implementation =="
check "A: ctx=Supervisor, clusters[0]=GUEST -> KEEP" "$TMP/caseA.kubeconfig" "$TMP/sup.kubeconfig" EMPTY
check "B: single cluster, same server -> KEEP"       "$TMP/sup.kubeconfig"   "$TMP/sup.kubeconfig" EMPTY
check "C: ctx=GUEST, clusters[0]=Supervisor -> STALE" "$TMP/caseC.kubeconfig" "$TMP/sup.kubeconfig" "$GUEST"

echo "== the B98 case itself =="
check "unset"                        ""                                  "$TMP/sup.kubeconfig" "unset"
check "STALE: path does not exist"   "/nonexistent/stale-lab.kubeconfig" "$TMP/sup.kubeconfig" "stale"
check "STALE: exists but EMPTY"      "$TMP/empty.kubeconfig"             "$TMP/sup.kubeconfig" "stale"

echo "== never clobber on UNCERTAINTY =="
check "unparseable -> keep"          "$TMP/junk.kubeconfig"              "$TMP/sup.kubeconfig" EMPTY
check "supervisor unreadable -> keep" "$TMP/sup.kubeconfig"              "/nonexistent/sup"    EMPTY

echo "== cwd-independence (a RELATIVE path is what the docs tell operators to set) =="
mkdir -p "$TMP/repo/secrets"; kc "$TMP/repo/secrets/argocd.kubeconfig" "$SUP"
( cd /tmp && REPO_ROOT="$TMP/repo" \
    argocd_kubeconfig_stale_reason './secrets/argocd.kubeconfig' "$TMP/sup.kubeconfig" ) > "$TMP/out" 2>&1
if [ -s "$TMP/out" ]; then
  fail=$((fail+1)); printf '  FAIL %-46s -> [%s] (want EMPTY)\n' "relative path, cwd elsewhere -> KEEP" "$(cat "$TMP/out")"
else
  pass=$((pass+1)); printf '  ok   %-46s -> []\n' "relative path, cwd elsewhere -> KEEP"
fi

echo "== the regression guard for WHY emptiness was the wrong test =="
if is_placeholder '/nonexistent/stale-lab.kubeconfig'; then
  fail=$((fail+1)); printf '  FAIL %-46s\n' "is_placeholder must NOT report a stale path"
else
  pass=$((pass+1)); printf '  ok   %-46s -> anything keying on it re-opens B98\n' "is_placeholder cannot see a stale path"
fi

printf '\ntest-argocd-kubeconfig-stale: %d passed, %d failed (%d cases)\n' "$pass" "$fail" "$((pass+fail))"
# FAIL-CHECK FIRST, then the ran-anything check — the reverse exits 0 on a run that printed FAIL.
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -gt 0 ] || { echo "no cases ran — this gate judged nothing"; exit 1; }
