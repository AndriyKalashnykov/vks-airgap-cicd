#!/usr/bin/env bash
# vcenter.sh — vCenter REST session + Supervisor Service primitives.
#
# WHY THIS EXISTS: scenario-1 Steps 2 and 3 used to be browser work ("Add New Service ->
# upload the .yml -> Manage Service -> paste data-values"), including hand-editing SEVEN
# plaintext secrets. That is not automatable by the reader and it is not testable by us.
# These primitives do the same thing over the documented vCenter REST API.
#
# SECRETS: the vCenter password reaches curl through a `-K` config file written under
# `umask 077` and escaped with esc_curlk (lib/os.sh) -- NEVER argv, never `-u`. The session
# token likewise reaches curl via `-H @file`. See common/security.md.
#
# ROUTES: the supervisor-scoped ("V2") routes are used for install/uninstall. The
# cluster-scoped equivalents (/clusters/{moid}/supervisor-services) are DEPRECATED as of
# vSphere API 9.0.0.0 -- the generation this repo targets -- so they are deliberately not used.
#
# IDEMPOTENCY: `?action=checkContent` derives a service's id from the YAML WITHOUT
# registering it. That is the only way to ask "is this already registered?" before mutating.

vc_require() {
  require_cmd curl jq base64
  : "${VCENTER_HOST:?VCENTER_HOST is not set (your vCenter FQDN, e.g. vcsa.env1.lab.test)}"
  : "${VCENTER_USERNAME:?VCENTER_USERNAME is not set (e.g. administrator@vsphere.local)}"
  : "${VCENTER_PASSWORD:?VCENTER_PASSWORD is not set - put it in .env or export it}"
}

# vc_login — POST /api/session, store the token in a 0600 file, echo nothing.
# The token is kept in a FILE (not a variable that could leak into a child's argv/environ).
vc_login() {
  vc_require
  VC_TOKEN_FILE="${VC_TOKEN_FILE:-$(mktemp)}"
  VC_CURL_CFG="${VC_CURL_CFG:-$(mktemp)}"
  VC_HDR_FILE="${VC_HDR_FILE:-$(mktemp)}"
  # VC_CODE_FILE, not a variable: vc_api is almost always called as `x="$(vc_api ...)"`, which is a
  # SUBSHELL -- a global assigned inside it is LOST, so the caller would read a stale or unset
  # status and branch on it. A file survives the subshell. (common/coding-style.md)
  VC_CODE_FILE="${VC_CODE_FILE:-$(mktemp)}"
  chmod 600 "$VC_TOKEN_FILE" "$VC_CURL_CFG" "$VC_HDR_FILE" "$VC_CODE_FILE"

  # rm -f FIRST: `umask 077` only applies at CREATION, so a pre-existing 0644 file would KEEP
  # its mode and the credential would land world-readable while this code read as safe.
  rm -f "$VC_CURL_CFG"
  ( umask 077; printf 'user = "%s:%s"\n' \
      "$(esc_curlk "$VCENTER_USERNAME")" "$(esc_curlk "$VCENTER_PASSWORD")" > "$VC_CURL_CFG" )

  local body code
  body="$(mktemp)"; chmod 600 "$body"
  code="$(curl -sS -k -o "$body" -w '%{http_code}' -X POST \
           --connect-timeout "${VC_CONNECT_TIMEOUT:-10}" --max-time "${VC_API_TIMEOUT:-60}" \
           -K "$VC_CURL_CFG" "https://${VCENTER_HOST}/api/session" 2>/dev/null || true)"
  case "$code" in
    201|200) : ;;
    401) rm -f "$body"; die "vCenter rejected VCENTER_USERNAME/VCENTER_PASSWORD (HTTP 401). NOTE: vCenter SSO locks the account after 5 failures in 3 minutes - do not retry blindly." ;;
    000) rm -f "$body"; die "vCenter ${VCENTER_HOST} is unreachable (no HTTP response). Check the FQDN resolves and is routable from here." ;;
    *)   rm -f "$body"; die "vCenter /api/session returned HTTP ${code:-<none>}" ;;
  esac
  # The body is a bare JSON string: "abc123..."
  ( umask 077; jq -r '. // empty' < "$body" > "$VC_TOKEN_FILE" )
  rm -f "$body"
  [ -s "$VC_TOKEN_FILE" ] || die "vCenter returned HTTP $code but no session token"

  rm -f "$VC_HDR_FILE"
  ( umask 077; printf 'vmware-api-session-id: %s\n' "$(cat "$VC_TOKEN_FILE")" > "$VC_HDR_FILE" )
  log_info "vCenter session established (${VCENTER_HOST})"
}

# vc_last_code — the HTTP status of the most recent vc_api call, readable by a caller that
# captured vc_api's stdout in a subshell.
vc_last_code() { cat "${VC_CODE_FILE:-/dev/null}" 2>/dev/null; }

vc_logout() {
  [ -n "${VC_HDR_FILE:-}" ] && [ -s "${VC_HDR_FILE:-/nonexistent}" ] || return 0
  curl -sS -k -o /dev/null -X DELETE --max-time 20 -H "@${VC_HDR_FILE}" \
    "https://${VCENTER_HOST}/api/session" 2>/dev/null || true
  rm -f "${VC_TOKEN_FILE:-}" "${VC_CURL_CFG:-}" "${VC_HDR_FILE:-}" "${VC_CODE_FILE:-}" 2>/dev/null || true
  return 0
}

# vc_api <METHOD> <PATH> [extra curl args...] -> body on stdout; status via vc_last_code.
# ⚠️ Read the status with vc_last_code(), NEVER $VC_LAST_CODE: every real call is
# `x="$(vc_api ...)"` -- a SUBSHELL -- so the variable holds the PREVIOUS call's status and a
# die message built from it reports a plausible, wrong code (measured: "install failed (HTTP
# 200)" for a 400, which sends you looking at the wrong thing entirely).
# Returns non-zero on a non-2xx so callers can branch, WITHOUT dying (some callers expect 404).
vc_api() {
  local method="$1" path="$2"; shift 2
  local body code
  body="$(mktemp)"; chmod 600 "$body"
  code="$(curl -sS -k -o "$body" -w '%{http_code}' -X "$method" \
           --connect-timeout "${VC_CONNECT_TIMEOUT:-10}" --max-time "${VC_API_TIMEOUT:-120}" \
           -H "@${VC_HDR_FILE}" -H 'Content-Type: application/json' \
           "$@" "https://${VCENTER_HOST}${path}" 2>/dev/null || true)"
  # DELIBERATELY not also a variable: one that is correct only when the caller avoids a subshell
  # is a trap, and it already produced a die message reporting HTTP 200 for a 400.
  printf '%s' "$code" > "${VC_CODE_FILE:-/dev/null}"
  cat "$body"; rm -f "$body"
  case "$code" in 2*) return 0 ;; *) return 1 ;; esac
}

# vc_supervisor_id — the Supervisor's UUID. NOT the same id space as a cluster moid
# (domain-cN); crossing them 404s with a message that names neither.
# MEASURED on a 9.1.0.0300 vCenter: /namespace-management/supervisors is NOT FOUND; the
# list lives at .../supervisors/summaries. The response is returned in TWO shapes ({items:[...]}
# and a bare array), and jq's `//` does NOT suppress a left-side ERROR -- `.items[0].x // .[0].x`
# exits rc=5 on the array shape, which under `set -e` kills the caller with no message. try/catch
# is the only form that survives both.
vc_supervisor_id() {
  local out
  out="$(vc_api GET /api/vcenter/namespace-management/supervisors/summaries || true)"
  printf '%s' "$out" \
    | jq -r 'try (.items[0].supervisor) catch empty // (try (.[0].supervisor) catch empty) // empty' \
      2>/dev/null || echo ''
}

# vc_ss_check_content <yaml-file> -> "<content_type>|<derived-id>|<version>|<status>" (NON-MUTATING)
vc_ss_check_content() {
  local yaml="$1" b64 req out
  b64="$(mktemp)"; req="$(mktemp)"; chmod 600 "$b64" "$req"
  base64 -w0 < "$yaml" > "$b64" 2>/dev/null || base64 < "$yaml" | tr -d '\n' > "$b64"
  jq -n --rawfile c "$b64" '{spec:{content:$c}}' > "$req"
  out="$(vc_api POST '/api/vcenter/namespace-management/supervisor-services?action=checkContent' \
           --data-binary "@${req}" || true)"
  rm -f "$b64" "$req"
  printf '%s' "$out" | jq -r '[(.content_type // ""),
                               (.carvel_apps_check_result.supervisor_service // ""),
                               (.carvel_apps_check_result.version // ""),
                               (.status // "")] | join("|")' 2>/dev/null
}

# vc_ss_list -> one "<state>\t<id>\t<display name>" per REGISTERED service.
# The id is DERIVED BY VCENTER from the service-definition YAML's content, which is why it is
# dotted (harbor.tanzu.vmware.com) and not the dash-only catalogue key (harbor). You cannot
# invent it; you read it from here, or from checkContent before registering.
vc_ss_list() {
  vc_api GET /api/vcenter/namespace-management/supervisor-services 2>/dev/null \
    | jq -r '.[]? | [(.state // "?"), (.supervisor_service // "?"), (.display_name // "")] | @tsv' 2>/dev/null
}

# vc_ss_is_registered <id> -> 0 if vCenter already knows this service
vc_ss_is_registered() {
  vc_api GET "/api/vcenter/namespace-management/supervisor-services/${1}" >/dev/null 2>&1
}

# vc_ss_register <yaml-file>
vc_ss_register() {
  local yaml="$1" b64 req out
  b64="$(mktemp)"; req="$(mktemp)"; chmod 600 "$b64" "$req"
  base64 -w0 < "$yaml" > "$b64" 2>/dev/null || base64 < "$yaml" | tr -d '\n' > "$b64"
  # carvel_spec is the THIRD create_spec variant (vSphere API 8.0.0.1+). vCenter's own
  # create_spec docs still say "exactly one of custom-spec or vsphere-spec", which is why it is
  # easy to miss -- and `{spec:{content:...}}` (what checkContent takes) is rejected here with
  # 404 "The Supervisor Service create specification cannot be empty." MEASURED.
  jq -n --rawfile c "$b64" '{carvel_spec:{version_spec:{content:$c}}}' > "$req"
  out="$(vc_api POST '/api/vcenter/namespace-management/supervisor-services' \
           --data-binary "@${req}")" || { rm -f "$b64" "$req"; die "register failed (HTTP $(vc_last_code)): $(printf '%s' "$out" | head -c 400)"; }
  rm -f "$b64" "$req"
  return 0
}

# vc_cluster_moid [name] -> the vSphere cluster moid (domain-cN). NOT the supervisor UUID:
# two id spaces, and crossing them 404s with a message that names neither.
vc_cluster_moid() {
  local want="${1:-}" out
  out="$(vc_api GET /api/vcenter/cluster || true)"
  if [ -n "$want" ]; then
    printf '%s' "$out" | jq -r --arg n "$want" '.[]|select(.name==$n)|.cluster' 2>/dev/null | head -1
  else
    printf '%s' "$out" | jq -r 'if length==1 then .[0].cluster else empty end' 2>/dev/null
  fi
}

# vc_ss_install <cluster-moid> <service-id> <version> [data-values-file]
# The CLUSTER-scoped route. Its operations are deprecated as of vSphere API 9.0.0.0, but it is
# the one that has actually been RUN against this generation; the supervisor-scoped V2 route
# has no POST-to-create for a new install. The data-values file carries PLAINTEXT SECRETS --
# it is base64'd into the body and every temp file is removed on all paths.
vc_ss_install() {
  local moid="$1" id="$2" ver="$3" values="${4:-}" req out b64
  req="$(mktemp)"; chmod 600 "$req"
  if [ -n "$values" ] && [ -s "$values" ]; then
    b64="$(mktemp)"; chmod 600 "$b64"
    base64 -w0 < "$values" > "$b64" 2>/dev/null || base64 < "$values" | tr -d '\n' > "$b64"
    jq -n --arg s "$id" --arg v "$ver" --rawfile c "$b64" \
      '{supervisor_service:$s, version:$v, yaml_service_config:$c}' > "$req"
    rm -f "$b64"
  else
    jq -n --arg s "$id" --arg v "$ver" '{supervisor_service:$s, version:$v}' > "$req"
  fi
  # RETRY on the platform's own "try again later". MEASURED: immediately after a fresh
  # register, vCenter answers 404 "The service account is not ready. Please try again later."
  # -- a TRANSIENT that reads like a missing service and would send an operator hunting for a
  # file that is present and correct. Everything else fails fast.
  local tries="${VC_SS_INSTALL_RETRIES:-30}" i=1
  while :; do
    if out="$(vc_api POST "/api/vcenter/namespace-management/clusters/${moid}/supervisor-services" \
                --data-binary "@${req}")"; then
      rm -f "$req"; return 0
    fi
    case "$out" in
      *"not ready"*|*"try again later"*)
        [ "$i" -lt "$tries" ] || { rm -f "$req"; die "the service account was still not ready after ${tries} attempts"; }
        [ "$i" = 1 ] && log_info "vCenter: service account not ready yet - retrying (up to ${tries}x)"
        i=$((i + 1)); sleep "${VC_SS_INSTALL_INTERVAL:-10}" ;;
      *)
        rm -f "$req"; die "install failed (HTTP $(vc_last_code)): $(printf '%s' "$out" | head -c 400)" ;;
    esac
  done
}

# vc_ss_state <supervisor-uuid> <service-id> -> config_status string (or empty)
vc_ss_state() {
  vc_api GET "/api/vcenter/namespace-management/supervisors/${1}/supervisor-services/${2}" 2>/dev/null \
    | jq -r '(.config_status // .status // empty)' 2>/dev/null
}
