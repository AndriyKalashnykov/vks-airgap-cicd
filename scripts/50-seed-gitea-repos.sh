#!/usr/bin/env bash
# 50-seed-gitea-repos.sh — create the Gitea admin + CI token, the org, the two
# repos (webui-app, webui-deploy), push their content, and register the push
# webhook to the Tekton EventListener.
#
# Secret hygiene: the admin password is passed via stdin (heredoc) to kubectl
# exec, never the jump-box argv; the API token is supplied to curl via a -K config
# file and to git via a credential-store file (umask 077), never argv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl; require_cmd git; require_cmd curl; require_cmd yq
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${GITEA_ADMIN_USER:?}"
: "${GITEA_ADMIN_PASSWORD:?set GITEA_ADMIN_PASSWORD in .env}"
: "${GITEA_ORG:?}"; : "${GITEA_APP_REPO:?}"; : "${GITEA_DEPLOY_REPO:?}"
: "${CI_NAMESPACE:?}"; : "${APP_NAME:?}"; : "${APP_BRANCH:?}"; : "${ARGOCD_TRACK_BRANCH:?}"
: "${HARBOR_URL:?}"; : "${HARBOR_APP_PROJECT:?}"; : "${ARGOCD_DEST_NAMESPACE:?}"; : "${APP_REPLICAS:?}"
: "${GITEA_CI_USER:?}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@vks-airgap-cicd.local}"
# Ephemeral by default (pick_port) so parallel runs don't collide on a fixed local
# port; an operator can still pin it via GITEA_LOCAL_PORT.
LOCAL_PORT="${GITEA_LOCAL_PORT:-$(pick_port)}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

tmp="$(mktemp -d)"
PF_PID=""
cleanup() { if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi; rm -rf "$tmp"; }
trap cleanup EXIT
umask 077

# ---- 1. Admin user + CI access token ----
TOKEN_FILE="${REPO_ROOT}/secrets/gitea-ci-token"
if [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
  log_info "reusing existing CI token ($TOKEN_FILE)"
else
  log_info "creating Gitea admin user '$GITEA_ADMIN_USER' (password via stdin)"
  # Password travels in the heredoc (stdin), not the jump-box argv.
  kubectl -n "$GITEA_NAMESPACE" exec -i deploy/gitea -- sh <<EOF || log_warn "admin may already exist — continuing"
gitea admin user create --admin --username "$GITEA_ADMIN_USER" \
  --email "$GITEA_ADMIN_EMAIL" --password "$GITEA_ADMIN_PASSWORD" --must-change-password=false
EOF
  log_info "generating CI access token"
  TOKEN="$(kubectl -n "$GITEA_NAMESPACE" exec deploy/gitea -- \
    gitea admin user generate-access-token --username "$GITEA_ADMIN_USER" \
      --scopes all --token-name "seed-$(date +%s)" --raw | tr -d '\r' | tail -1)"
  [ -n "$TOKEN" ] || die "failed to generate Gitea access token"
  mkdir -p "$(dirname "$TOKEN_FILE")"
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
  log_info "stored CI token -> $TOKEN_FILE"
fi

WEBHOOK_TOKEN="$(ensure_secret_token "${REPO_ROOT}/secrets/webhook-token")"

# ---- 2. Port-forward the Gitea HTTP service ----
log_info "port-forwarding gitea-http -> localhost:${LOCAL_PORT}"
kubectl -n "$GITEA_NAMESPACE" port-forward svc/gitea-http "${LOCAL_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
base="http://localhost:${LOCAL_PORT}"
# Poll bounded by READY_TIMEOUT_SECONDS (from .env.example), matching 99-verify.sh
# — not a hardcoded iteration count.
end=$((SECONDS + READY_TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$end" ]; do
  curl -fsS "${base}/api/healthz" >/dev/null 2>&1 && break
  sleep "$POLL_INTERVAL_SECONDS"
done
curl -fsS "${base}/api/healthz" >/dev/null 2>&1 || die "Gitea not reachable via port-forward within ${READY_TIMEOUT_SECONDS}s"

# curl auth via -K config file (token stays out of argv).
authcfg="${tmp}/curl.cfg"
printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$authcfg"
api() { curl -sS -o /dev/null -w '%{http_code}' -K "$authcfg" -H 'Content-Type: application/json' "$@"; }

# ---- 3. Org + repos (idempotent: treat 201 and 409/422 as success) ----
ok() { case "$1" in 2??|409|422) return 0;; *) return 1;; esac; }

printf '{"username":"%s"}' "$GITEA_ORG" > "${tmp}/org.json"
code="$(api -X POST -d @"${tmp}/org.json" "${base}/api/v1/orgs")"
ok "$code" || die "create org failed (http $code)"; log_info "org '$GITEA_ORG' ready (http $code)"

for repo in "$GITEA_APP_REPO" "$GITEA_DEPLOY_REPO"; do
  printf '{"name":"%s","private":false,"auto_init":false,"default_branch":"%s"}' \
    "$repo" "$ARGOCD_TRACK_BRANCH" > "${tmp}/repo.json"
  code="$(api -X POST -d @"${tmp}/repo.json" "${base}/api/v1/orgs/${GITEA_ORG}/repos")"
  ok "$code" || die "create repo '$repo' failed (http $code)"; log_info "repo '$repo' ready (http $code)"
done

# ---- 4. Push content ----
gitcreds="${tmp}/gitcreds"
printf 'http://%s:%s@localhost:%s\n' "$GITEA_ADMIN_USER" "$TOKEN" "$LOCAL_PORT" > "$gitcreds"

push_repo() {
  # push_repo <src-dir> <repo> <branch>
  local src="$1" repo="$2" branch="$3"
  local d="${tmp}/${repo}"
  rm -rf "$d"; mkdir -p "$d"; cp -a "$src/." "$d/"
  rm -rf "$d/target" "$d/.git"
  git -C "$d" init -q -b "$branch"
  git -C "$d" config user.email "$GITEA_ADMIN_EMAIL"
  git -C "$d" config user.name "$GITEA_CI_USER"
  # store helper supplies creds via the credential protocol (stdin), not argv.
  git -C "$d" config credential.helper "store --file=${gitcreds}"
  git -C "$d" add -A
  git -C "$d" commit -q -m "seed: initial ${repo}"
  git -C "$d" remote add origin "${base}/${GITEA_ORG}/${repo}.git"
  # Force-push: the seed is the AUTHORITATIVE initial content, and push_repo
  # builds a fresh history (git init) each run. Against an already-seeded repo
  # (a prior run, or a deploy repo that received pipeline tag write-backs) a
  # plain push is a non-fast-forward rejection ("fetch first"). Force makes the
  # seed idempotent and ensures the CURRENT source (e.g. an updated app) lands.
  git -C "$d" push -q -f -u origin "$branch"
  log_info "pushed ${repo} (branch ${branch})"
}

# App repo: the Spring Boot app at repo root.
push_repo "${REPO_ROOT}/apps/java/webui" "$GITEA_APP_REPO" "$APP_BRANCH"

# Deploy repo: deploy/base rendered to operator values (kustomization at root).
deploy_src="${tmp}/deploy-src"
rm -rf "$deploy_src"; mkdir -p "$deploy_src"; cp -a "${REPO_ROOT}/deploy/base/." "$deploy_src/"
NEWNAME="${HARBOR_URL}/${HARBOR_APP_PROJECT}/${APP_NAME}" NS="$ARGOCD_DEST_NAMESPACE" \
  yq -i '.images[0].newName = strenv(NEWNAME) | .namespace = strenv(NS)' \
  "${deploy_src}/kustomization.yaml"
yq -i ".replicas[0].count = ${APP_REPLICAS}" "${deploy_src}/kustomization.yaml"
push_repo "$deploy_src" "$GITEA_DEPLOY_REPO" "$ARGOCD_TRACK_BRANCH"

# ---- 5. Register the push webhook on webui-app -> EventListener ----
hook_url="http://el-webui.${CI_NAMESPACE}.svc:8080"
cat > "${tmp}/hook.json" <<EOF
{"type":"gitea","active":true,"events":["push"],
 "config":{"url":"${hook_url}","content_type":"json","secret":"${WEBHOOK_TOKEN}"}}
EOF
code="$(api -X POST -d @"${tmp}/hook.json" "${base}/api/v1/repos/${GITEA_ORG}/${GITEA_APP_REPO}/hooks")"
ok "$code" || die "webhook registration failed (http $code)"
log_info "webhook on ${GITEA_APP_REPO} -> ${hook_url} (http $code)"

log_info "Gitea seeded: org '${GITEA_ORG}', repos '${GITEA_APP_REPO}' + '${GITEA_DEPLOY_REPO}'"
