#!/usr/bin/env bash
# 50-seed-gitea-repos.sh — create the Gitea admin + CI token, the org, the two
# repos (javawebapp-app, javawebapp-deploy), push their content, and register the push
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
kubeconfig_ready
: "${GITEA_NAMESPACE:?}"; : "${GITEA_ADMIN_USER:?}"
: "${GITEA_ADMIN_PASSWORD:?set GITEA_ADMIN_PASSWORD in .env}"
: "${GITEA_ORG:?}"
: "${CI_NAMESPACE:?}"; : "${APP_BRANCH:?}"; : "${ARGOCD_TRACK_BRANCH:?}"  # APP_NAME is PER-APP (registry), never a global
: "${HARBOR_URL:?}"; : "${HARBOR_APP_PROJECT:?}"; : "${APP_REPLICAS:?}"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
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

# A TOKEN FILE EXISTING DOES NOT MEAN THE TOKEN WORKS.
#
# This used to be `if [ -s "$TOKEN_FILE" ]` — presence, not validity. But the token belongs to a
# SPECIFIC Gitea: a fresh cluster installs a fresh Gitea with a freshly GENERATED admin password and
# an empty database, so any token left over from a previous cluster is dead. Seeding then failed with
# `create org failed (http 401)` — an error that names authorization and points nowhere near the
# stale file that caused it.
#
# It is only reachable because `make kind-down` (correctly) removes these credentials ONLY when it
# actually deleted a cluster — so a no-op teardown leaves the token behind for the next run.
#
# So: the file is a CANDIDATE. Whether it works is decided by the live Gitea, below (mint_token), the
# same way we detect anything else — by the artifact, never by a file's existence.
CANDIDATE_TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
  CANDIDATE_TOKEN="$(cat "$TOKEN_FILE")"
fi

# mint_token — create the admin (idempotent) and generate a fresh CI token.
mint_token() {
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
  ( umask 077; printf '%s' "$TOKEN" > "$TOKEN_FILE" )
  log_info "stored CI token -> $TOKEN_FILE"
}

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

# ---- 2b. Is the candidate token VALID FOR THIS GITEA? (ask Gitea, do not trust the file) ----------
# Token stays out of argv: -K config file, mode 0600.
token_works() {
  cfg="${tmp}/probe.cfg"
  ( umask 077; printf 'header = "Authorization: token %s"\n' "$1" > "$cfg" )
  [ "$(curl -sS -o /dev/null -w '%{http_code}' -K "$cfg" "${base}/api/v1/user" 2>/dev/null)" = "200" ]
}

TOKEN=""
if [ -n "$CANDIDATE_TOKEN" ] && token_works "$CANDIDATE_TOKEN"; then
  TOKEN="$CANDIDATE_TOKEN"
  log_info "reusing the existing CI token (verified against THIS Gitea)"
else
  if [ -n "$CANDIDATE_TOKEN" ]; then
    log_warn "the CI token in $TOKEN_FILE does NOT authenticate against this Gitea — it belongs to a"
    log_warn "  previous cluster (a fresh Gitea generates a new admin password + an empty DB)."
    log_warn "  Minting a new one. (Reusing it produced 'create org failed (http 401)'.)"
  fi
  mint_token
fi

# curl auth via -K config file (token stays out of argv).
authcfg="${tmp}/curl.cfg"
( umask 077; printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$authcfg" )
api() { curl -sS -o /dev/null -w '%{http_code}' -K "$authcfg" -H 'Content-Type: application/json' "$@"; }
# api_body — like api() but returns the response BODY (for idempotency GET checks).
api_body() { curl -sS -K "$authcfg" -H 'Content-Type: application/json' "$@"; }

# ---- 3. Org + repos (idempotent: treat 201 and 409/422 as success) ----
ok() { case "$1" in 2??|409|422) return 0;; *) return 1;; esac; }

printf '{"username":"%s"}' "$GITEA_ORG" > "${tmp}/org.json"
code="$(api -X POST -d @"${tmp}/org.json" "${base}/api/v1/orgs")"
ok "$code" || die "create org failed (http $code)"; log_info "org '$GITEA_ORG' ready (http $code)"

# Two repos PER APP: <app>-app (source) and <app>-deploy (what ArgoCD watches). Derived from
# apps/registry.tsv — `while read` (not `for x in $(...)`), because the login shell may be zsh,
# which does not word-split an unquoted expansion and would run the body ONCE on the whole blob.
# shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
create_app_repos() {
  local repo code
  for repo in "$APP_GIT_REPO" "$APP_DEPLOY_REPO"; do
    printf '{"name":"%s","private":false,"auto_init":false,"default_branch":"%s"}' \
      "$repo" "$ARGOCD_TRACK_BRANCH" > "${tmp}/repo.json"
    code="$(api -X POST -d @"${tmp}/repo.json" "${base}/api/v1/orgs/${GITEA_ORG}/repos")"
    ok "$code" || die "create repo '$repo' failed (http $code)"; log_info "repo '$repo' ready (http $code)"
  done
}
for_each_app create_app_repos

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

# ---- 4b/5. PER APP (apps/registry.tsv): seed <app>-app + <app>-deploy, and register ONE webhook
# on the app repo pointing at the SHARED EventListener. Adding an app is a registry ROW — no edit
# here. Every app gets the identical walk; nothing about this loop is language-specific.
# shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
seed_app() {
  local app="$1"

  # Source repo: the app's source dir IS the content of <app>-app.
  push_repo "${REPO_ROOT}/${APP_SRC}" "$APP_GIT_REPO" "$APP_BRANCH"

  # Deploy repo: the app's kustomize dir, rendered to operator values (kustomization at root).
  local deploy_src="${tmp}/deploy-src-${app}"
  rm -rf "$deploy_src"; mkdir -p "$deploy_src"; cp -a "${REPO_ROOT}/${APP_DEPLOY_DIR}/." "$deploy_src/"
  NEWNAME="${APP_IMAGE}" NS="${APP_NAMESPACE}" \
    yq -i '.images[0].newName = strenv(NEWNAME) | .namespace = strenv(NS)' \
    "${deploy_src}/kustomization.yaml"
  yq -i ".replicas[0].count = ${APP_REPLICAS}" "${deploy_src}/kustomization.yaml"
  push_repo "$deploy_src" "$APP_DEPLOY_REPO" "$ARGOCD_TRACK_BRANCH"

  # Webhook on <app>-app -> the shared EventListener. Gitea does NOT dedupe hooks: a blind re-POST
  # on a re-run creates a DUPLICATE, firing 2 PipelineRuns per push. Skip if ours is already there.
  local hook_url="http://el-apps.${CI_NAMESPACE}.svc:8080"
  local hooks_api="${base}/api/v1/repos/${GITEA_ORG}/${APP_GIT_REPO}/hooks"
  # Capture the body, then grep the VARIABLE draining all input (no `-q`): `api_body | grep -qF`
  # lets grep close the pipe on its first match and SIGPIPE api_body (exit 141), which under
  # `set -o pipefail` reads as "no hook present" -> we would create the duplicate this check exists
  # to prevent.
  local hooks_body; hooks_body="$(api_body -X GET "$hooks_api" || true)"
  if printf '%s' "$hooks_body" | grep -F "$hook_url" >/dev/null; then
    log_info "webhook on ${APP_GIT_REPO} -> ${hook_url} already present — skipping (idempotent)"
  else
    cat > "${tmp}/hook-${app}.json" <<EOF
{"type":"gitea","active":true,"events":["push"],
 "config":{"url":"${hook_url}","content_type":"json","secret":"${WEBHOOK_TOKEN}"}}
EOF
    local code; code="$(api -X POST -d @"${tmp}/hook-${app}.json" "$hooks_api")"
    ok "$code" || die "webhook registration failed for ${APP_GIT_REPO} (http $code)"
    log_info "webhook on ${APP_GIT_REPO} -> ${hook_url} (http $code)"
  fi
}
for_each_app seed_app

log_info "Gitea seeded: org '${GITEA_ORG}' — for each app: <app>-app + <app>-deploy ($(app_names | tr '\n' ' '))"
