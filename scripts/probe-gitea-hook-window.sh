#!/usr/bin/env bash
# ci-tier: manual
# B538 F6 — measure the Gitea push->webhook-resolution WINDOW. Touches NO app repo.
#
# Mechanism (Gitea v1.27.2 source, settled by an earlier round): PushUpdates() hands off to an async
# pushQueue; the "which hooks does this repo have" query runs INSIDE that handler, at an unbounded
# time after the push returns. So the window is (push returns) -> (handler reaches PrepareWebhooks).
#
# ZERO PIPELINERUNS BY CONSTRUCTION: the hook points at 127.0.0.1:9 (RFC 863 discard), never the
# EventListener. The repo is a throwaway in its own name-space and is deleted on EVERY exit path.
# The push is made through the CONTENTS API rather than `git push`, so no clone, no git credential.
#
# SELF-CHECK: if nothing fires even at S=0 the source-read is wrong somewhere, and this says so
# rather than reporting a window of zero. Without that arm, a broken probe and a zero window are the
# same output.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh
# shellcheck source=scripts/lib/apps.sh
. scripts/lib/apps.sh
load_env

NS="${GITEA_NAMESPACE:-gitea}"
ORG="${GITEA_ORG:?}"
SLEEPS="${PROBE_SLEEPS:-0 1 2 4 8}"
DEAD="${PROBE_DEAD_URL:-http://127.0.0.1:9/}"
TOKF="${REPO_ROOT}/secrets/gitea-ci-token"
[ -s "$TOKF" ] || die "no ${TOKF}: run 'make seed-gitea' first (this probe reuses it, it mints nothing)"

TMP="$(mktemp -d)"; PF_PID=""; MADE=""
cleanup() {
  local r
  for r in $MADE; do
    curl -sS -o /dev/null -X DELETE -K "$TMP/auth" "${BASE}/api/v1/repos/${ORG}/${r}" 2>/dev/null || true
  done
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

PORT="$(pick_port)"; BASE="http://127.0.0.1:${PORT}"
kubectl -n "$NS" port-forward svc/gitea-http "${PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 40); do curl -fsS "${BASE}/api/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "${BASE}/api/healthz" >/dev/null 2>&1 || die "gitea not reachable on the port-forward"

# credential to a -K config, never argv (the repo's own pattern, 50-seed-gitea-repos.sh:186)
( umask 077; printf 'header = "Authorization: token %s"\n' "$(cat "$TOKF")" > "$TMP/auth" )
[ "$(curl -sS -o /dev/null -w '%{http_code}' -K "$TMP/auth" "${BASE}/api/v1/user")" = 200 ] \
  || die "the stored gitea token is REJECTED (HTTP != 200) — it is stale; re-run 'make seed-gitea'"

log_info "probe: ns=${NS} org=${ORG} sleeps='${SLEEPS}' dead-url=${DEAD}"
printf '\n  %-6s %-10s %s\n' "S" "fired?" "meaning"
WINDOW="(not reached)"
for S in $SLEEPS; do
  R="zz-hookprobe-$$-${S}"
  printf '{"name":"%s","auto_init":true,"private":true}' "$R" > "$TMP/repo.json"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            -K "$TMP/auth" -d @"$TMP/repo.json" "${BASE}/api/v1/orgs/${ORG}/repos")"
  case "$code" in 201) MADE="$MADE $R" ;; *) log_warn "  S=$S: repo create returned $code — skipping"; continue ;; esac

  SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # THE PUSH: a contents-API commit goes through the same notify path as `git push`.
  printf '{"content":"%s","message":"probe"}' "$(printf 'probe' | base64 -w0)" > "$TMP/f.json"
  curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -K "$TMP/auth" \
       -d @"$TMP/f.json" "${BASE}/api/v1/repos/${ORG}/${R}/contents/probe.txt" || true

  sleep "$S"
  printf '{"type":"gitea","active":true,"events":["push"],"config":{"url":"%s","content_type":"json"}}' "$DEAD" > "$TMP/h.json"
  curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -K "$TMP/auth" \
       -d @"$TMP/h.json" "${BASE}/api/v1/repos/${ORG}/${R}/hooks" || true

  sleep 6
  n="$(kubectl -n "$NS" logs deploy/gitea --since-time="$SINCE" 2>/dev/null \
        | grep -c 'Unable to deliver webhook task' || true)"
  if [ "${n:-0}" -gt 0 ]; then
    printf '  %-6s %-10s %s\n' "$S" "YES ($n)" "the hook existed when the handler resolved -> INSIDE the window"
  else
    printf '  %-6s %-10s %s\n' "$S" "no" "the handler had already resolved -> OUTSIDE the window"
    [ "$WINDOW" = "(not reached)" ] && WINDOW="$S"
  fi
done

echo
if [ "$WINDOW" = 0 ]; then
  log_error "SELF-CHECK FAILED: nothing fired even at S=0. The source-read is wrong somewhere, or a"
  log_error "  contents-API commit does not take the same notify path as a git push. This probe"
  log_error "  reports NO window rather than a window of zero."
else
  if [ "$WINDOW" = "(not reached)" ]; then
    log_warn "NO WINDOW FOUND: the hook fired at EVERY S tried. Sweep further (PROBE_SLEEPS='0 1 2 4 8 16')."
  else
    log_info "WINDOW = ${WINDOW}s (the smallest S at which the hook did NOT fire)"
  fi
fi

echo
log_info "read-only: hooks on each DEPLOY repo (the seed's DELETE only targets the APP repo,"
log_info "  so a stray deploy-repo hook would never be reaped and nothing looks for it)"
for a in $(app_names); do
  d="$(app_deploy_repo "$a" 2>/dev/null || printf '%s-deploy' "$a")"
  h="$(curl -sS -K "$TMP/auth" "${BASE}/api/v1/repos/${ORG}/${d}/hooks" 2>/dev/null || true)"
  printf '  %-28s hooks=%s\n' "$d" "$(printf '%s' "$h" | grep -o '"id"' | wc -l)"
done
