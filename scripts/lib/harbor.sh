#!/usr/bin/env bash
# scripts/lib/harbor.sh — shared Harbor plumbing sourced by the mirror push (21) and the
# robot-account helper (22): sudo-free TLS trust for a self-signed Harbor CA, an auth'd REST
# helper (creds via a curl -K config file, never argv), project creation, and robot creation.
# Depends on lib/os.sh (log_info/log_warn/die) + lib/tls.sh (ca_bundle_with_system). The caller
# sets HARBOR_URL/HARBOR_USERNAME/HARBOR_PASSWORD (via load_env) and passes a writable tmpdir.

# harbor_setup <tmpdir> — establish TLS trust + auth for Harbor REST/crane calls. Sets globals:
#   HARBOR_TLS_VERIFY (true|false), SCHEME (https|http), CURL_CACERT (array),
#   HARBOR_CURL_CFG (path); exports SSL_CERT_FILE when a CA bundle is built (crane honors it).
harbor_setup() {
  local tmp="$1"
  : "${HARBOR_URL:?}"; : "${HARBOR_USERNAME:?}"
  : "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"
  HARBOR_TLS_VERIFY="true"
  if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
    HARBOR_TLS_VERIFY="false"; log_warn "HARBOR_INSECURE=1 — skipping TLS verification (demo only)"
  elif [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ]; then
    # crane (go-containerregistry) honors SSL_CERT_FILE — point it at system CAs + the Harbor CA
    # so pushes verify the self-signed cert WITHOUT modifying the root-owned trust store (no sudo).
    local bundle="${tmp}/ca-bundle.crt"
    ca_bundle_with_system "$HARBOR_CA_FILE" "$bundle"
    export SSL_CERT_FILE="$bundle"
    log_info "trusting Harbor CA via SSL_CERT_FILE=$bundle (no system-store change, no sudo)"
  fi
  CURL_CACERT=(); [ -f "${HARBOR_CA_FILE:-/nonexistent}" ] && CURL_CACERT=(--cacert "$HARBOR_CA_FILE")
  [ "$HARBOR_TLS_VERIFY" = "false" ] && CURL_CACERT=(--insecure)
  # HTTP for an insecure (kind) Harbor, HTTPS otherwise.
  SCHEME="https"; [ "$HARBOR_TLS_VERIFY" = "false" ] && SCHEME="http"
  # Curl auth in a real umask-077 config FILE (kept out of argv).
  HARBOR_CURL_CFG="${tmp}/curl.cfg"
  ( umask 077; printf 'user = "%s:%s"\n' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > "$HARBOR_CURL_CFG" )
  # Where harbor_api_body records the HTTP status. A FILE, not a global: callers read the body via
  # a command substitution (a subshell), and a global set in there never reaches them.
  HARBOR_TMP_DIR="$tmp"
  HARBOR_CODE_FILE="${tmp}/last_code"
  : > "$HARBOR_CODE_FILE"
}

# harbor_api METHOD PATH [json-body] — echoes the HTTP status code. Creds via -K file, not argv.
harbor_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o /dev/null -w '%{http_code}' "${CURL_CACERT[@]}" -K "$HARBOR_CURL_CFG")
  # Use --head for HEAD (curl -X HEAD still waits for a body -> curl error 18).
  if [ "$method" = "HEAD" ]; then args+=(--head); else args+=(-X "$method"); fi
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "${SCHEME}://${HARBOR_URL}/api/v2.0/${path}"
}

# harbor_api_body METHOD PATH [json-body] — like harbor_api but echoes the RESPONSE BODY (needed
# to read a generated robot secret). Creds via -K file, not argv. The body may contain a secret —
# callers must NOT log it; capture into a variable and write to a 0600 file.
#
# It ALSO records the HTTP status, readable via `harbor_last_code`. Without that, a caller can only
# guess at what went wrong by substring-matching Harbor's error prose — which is how "you are not a
# system admin" (403) became indistinguishable from every other failure. A permission branch must
# key on the CODE.
#
# The status is written to a FILE, not a shell global, and that is load-bearing: every caller reads
# the body with `resp="$(harbor_api_body ...)"`, i.e. inside a COMMAND SUBSTITUTION — a subshell. A
# global assigned in there is invisible to the caller. (It bit exactly that way: harbor_is_sysadmin
# saw an unset code and told an actual Harbor administrator they were not one.) A file survives.
harbor_api_body() {
  local method="$1" path="$2" body="${3:-}" code
  local bodyfile="${HARBOR_TMP_DIR}/resp.$$"
  local args=(-sS -o "$bodyfile" -w '%{http_code}' "${CURL_CACERT[@]}" -K "$HARBOR_CURL_CFG" -X "$method")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  code="$(curl "${args[@]}" "${SCHEME}://${HARBOR_URL}/api/v2.0/${path}" || true)"
  printf '%s' "$code" > "${HARBOR_CODE_FILE}"
  cat "$bodyfile" 2>/dev/null || true
  rm -f "$bodyfile"
}

# harbor_last_code — the HTTP status of the last harbor_api_body call (survives the subshell).
harbor_last_code() { cat "${HARBOR_CODE_FILE}" 2>/dev/null || printf '?'; }

# harbor_is_sysadmin — exit 0 when the CURRENT Harbor user is a system administrator.
# This is the question that decides which robot we may create, and it is ASKED, not assumed: the
# README used to promise a Harbor PROJECT-ADMIN could self-service the CI robot, while the code
# only ever created a SYSTEM-level one (which Harbor gates on system-admin). A tenant got a 403.
harbor_is_sysadmin() {
  local body
  body="$(harbor_api_body GET "users/current")"
  [ "$(harbor_last_code)" = "200" ] || return 1
  [ "$(printf '%s' "$body" | jq -r '.sysadmin_flag // false')" = "true" ]
}

# ensure_project NAME — create the Harbor project if absent. Public per HARBOR_PUBLIC_PROJECTS
# (default true: anonymous pull → no app imagePullSecret; set false for a private-project lab).
ensure_project() {
  local name="$1" code
  code="$(harbor_api HEAD "projects?project_name=${name}")"
  if [ "$code" = "200" ]; then
    log_info "Harbor project '$name' exists"
    return 0
  fi
  log_info "creating Harbor project '$name'"
  code="$(harbor_api POST "projects" "{\"project_name\":\"${name}\",\"public\":${HARBOR_PUBLIC_PROJECTS:-true}}")"
  case "$code" in
    201|409) log_info "project '$name' ready (http $code)" ;;
    401|403)
      # A TENANT is not a Harbor admin and cannot create projects — and a robot account cannot
      # either. This used to `die`, which meant a tenant's `make harbor-robot` (and a `make mirror`
      # run with robot creds against a fresh Harbor) failed here, BEFORE reaching the thing they
      # actually came for. Not being allowed to create a project you were already GRANTED is not
      # an error; only its absence is.
      log_warn "not permitted to create Harbor project '$name' (http $code) — you are not a Harbor admin."
      log_warn "  If the project already exists and you were granted it, this is harmless."
      log_warn "  If it does NOT exist, ask your platform team to create it, or point"
      log_warn "  HARBOR_INFRA_PROJECT / HARBOR_APP_PROJECT at the project(s) you were given."
      return 1
      ;;
    *) die "failed to create Harbor project '$name' (http $code)" ;;
  esac
}
