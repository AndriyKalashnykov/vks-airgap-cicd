#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# ^ assertions are eval'd by try(), so $VARS must NOT expand at definition time; and `out`
#   is consumed inside those single-quoted strings, which shellcheck cannot see through.
# test-env-lifecycle.sh — exercise the `.env` lifecycle a NEW OPERATOR walks first.
#
# WHY: docs/scenario-1.md tells the reader to run env-init -> env-populate -> env-check ->
# env-validate before anything else. Measured 2026-08-09 (scripts/doc-harness-coverage.sh):
# three of those four were run by NOTHING -- no test, no e2e, no workflow. The first
# instructions in the runbook were the least verified in the repo.
#
# All four are offline-able: 02-env.sh's DISCOVER block is gated on a reachable cluster and
# prints "(no reachable cluster — skipping)" when there is none, so this needs no lab.
#
# NOT COVERED: the DISCOVER path itself (needs a cluster) and env-validate's connectivity
# leg. This tests the OFFLINE half; the other half is named in doc-harness-coverage's output.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO=$PWD
fail=0; n=0
ok()   { n=$((n+1)); printf '  ok %d - %s\n' "$n" "$1"; }
bad()  { n=$((n+1)); fail=1; printf '  not ok %d - %s\n' "$n" "$1"; }
try()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/envlc.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp "$REPO/.env.example" "$WORK/.env.example"

echo "== env lifecycle (offline) =="

# --- env-init: creates .env from the example -----------------------------------------
( cd "$WORK" && ENV_FILE=.env REPO_ROOT="$WORK" bash "$REPO/scripts/02-env.sh" init >/dev/null 2>&1 )
try "env-init creates .env from .env.example" '[ -s "$WORK/.env" ]'

# --- env-init again: must BACK UP rather than clobber --------------------------------
printf '\nMARKER_KEEP=1\n' >> "$WORK/.env"
( cd "$WORK" && ENV_FILE=.env REPO_ROOT="$WORK" bash "$REPO/scripts/02-env.sh" init >/dev/null 2>&1 )
try "env-init BACKS UP an existing .env (does not silently clobber)" \
    'ls "$WORK"/.env.bak* >/dev/null 2>&1 && grep -q MARKER_KEEP "$WORK"/.env.bak*'

# --- env-populate: offline, must SKIP discover and not die ---------------------------
out=$( cd "$WORK" && ENV_FILE=.env REPO_ROOT="$WORK" KUBECONFIG=/nonexistent \
       bash "$REPO/scripts/02-env.sh" populate 2>&1 ); rc=$?
try "env-populate exits 0 with no cluster (it is best-effort by design)" '[ "$rc" -eq 0 ]'
# 02-env.sh distinguishes "no kubeconfig FILE" from "file present, cluster unreachable" and
# names the fix for each. Accept either, and require that it NAMES A COMMAND -- a skip that
# does not tell the operator how to proceed is the defect this asserts against.
try "env-populate SAYS it skipped discovery rather than failing silently" \
    'printf "%s" "$out" | grep -qiE "skipping discovery|no reachable cluster"'
try "the skip message NAMES a command that would fix it" \
    'printf "%s" "$out" | grep -qE "make (vks-login|kind-up)"'

# --- env-populate MINTS the secrets it can, and does NOT clobber a set one ------------
try "env-populate generates GITEA_ADMIN_PASSWORD when unset" \
    'grep -qE "^GITEA_ADMIN_PASSWORD=.+" "$WORK/.env"'
before=$(grep -E '^GITEA_ADMIN_PASSWORD=' "$WORK/.env")
( cd "$WORK" && ENV_FILE=.env REPO_ROOT="$WORK" KUBECONFIG=/nonexistent \
  bash "$REPO/scripts/02-env.sh" populate >/dev/null 2>&1 )
try "env-populate NEVER clobbers a value already set (re-run is idempotent)" \
    '[ "$(grep -E "^GITEA_ADMIN_PASSWORD=" "$WORK/.env")" = "$before" ]'

# --- env-check: the HARBOR_URL placeholder must CHANGE the exit code ---------------
# WHY A PAIR, NOT A SINGLE ASSERTION: env-check accumulates EVERY missing required value,
# so a fixture that is short of anything else exits 1 whether HARBOR_URL is a placeholder
# or not -- defect present -> 1, defect absent -> 1, ZERO discrimination. The first
# assertion below is the POSITIVE CONTROL: it proves the fixture satisfies everything
# else, which is the only thing that makes the second assertion mean anything.
# Note the placeholder is the LITERAL harbor.vks.local (02-env.sh harbor_url_is_placeholder),
# and that .env.example ships HARBOR_URL *commented*, so it must be APPENDED, not sed'd.
# A kubeconfig fixture must have CONTENT: env-check tests `-s`, not `-f`, because a 0-byte
# kubeconfig passed the gate and kubectl then fell back to localhost:8080 (measured; a real
# 0-byte secrets/testcluster.kubeconfig was in the tree). An empty fixture here asserts the bug.
printf 'apiVersion: v1\\nkind: Config\\nclusters: []\\n' > "$WORK/fake.kubeconfig"
cat >> "$WORK/.env" <<EOF
HARBOR_USERNAME=admin
HARBOR_PASSWORD=x
GITEA_ADMIN_PASSWORD=x
SUPERVISOR_HOST=sup.example.com
VKS_CONTEXT_NAME=ctx
VKS_USERNAME=u
VKS_NAMESPACE=ns
VKS_CLUSTER_NAME=c
VKS_PASSWORD=p
KUBECONFIG=$WORK/fake.kubeconfig
EOF
cp "$WORK/.env" "$WORK/.env.base"

_check_with() {  # $1 = HARBOR_URL value; echoes env-check's rc
  cp "$WORK/.env.base" "$WORK/.env"
  printf 'HARBOR_URL=%s\n' "$1" >> "$WORK/.env"
  ( cd "$WORK" && ENV_FILE=.env REPO_ROOT="$WORK" bash "$REPO/scripts/02-env.sh" check >/dev/null 2>&1 )
  echo $?
}
rc_real=$(_check_with harbor.real.example.com)
rc_ph=$(_check_with harbor.vks.local)

try "POSITIVE CONTROL: env-check PASSES when every required value is real" '[ "$rc_real" -eq 0 ]'
try "env-check FAILS on the harbor.vks.local placeholder" '[ "$rc_ph" -ne 0 ]'
try "the rc actually CHANGES with HARBOR_URL (the assertion discriminates)" \
    '[ "$rc_real" -ne "$rc_ph" ]'

printf '\n%s: %d checks, %d failed\n' "$(basename "$0")" "$n" "$fail"
[ "$fail" -eq 0 ] || exit 1
