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
harbor_api_body() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS "${CURL_CACERT[@]}" -K "$HARBOR_CURL_CFG" -X "$method")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "${SCHEME}://${HARBOR_URL}/api/v2.0/${path}"
}

# ensure_project NAME — create the Harbor project if absent. Public per HARBOR_PUBLIC_PROJECTS
# (default true: anonymous pull → no app imagePullSecret; set false for a private-project lab).
ensure_project() {
  local name="$1" code
  code="$(harbor_api HEAD "projects?project_name=${name}")"
  if [ "$code" = "200" ]; then
    log_info "Harbor project '$name' exists"
  else
    log_info "creating Harbor project '$name'"
    code="$(harbor_api POST "projects" "{\"project_name\":\"${name}\",\"public\":${HARBOR_PUBLIC_PROJECTS:-true}}")"
    case "$code" in
      201|409) log_info "project '$name' ready (http $code)" ;;
      *) die "failed to create Harbor project '$name' (http $code)" ;;
    esac
  fi
}
