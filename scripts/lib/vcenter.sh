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

# vcenter_ca_default — point VCENTER_CA_FILE at an anchor we can find, if the operator did not.
#
# PURE: no network, and it never overrides a value the operator set. Mirrors vks_ca_default()
# in lib/tls.sh, deliberately, so there is ONE shape for "default the anchor" in this repo.
#
# MEASURED 2026-08-18 on a live lab: secrets/supervisor-ca.crt is NOT a vCenter anchor
# (--cacert supervisor-ca.crt -> rc=60), while a cert taken from vCenter's own
# /certs/download.zip bundle verifies it (rc=0). They are different CAs; `make fetch-vcenter-ca`
# is what produces the file this function looks for.
#
# ⚠️ IT DELIBERATELY DOES NOT PROBE secrets/vmca-root.pem, EVEN THOUGH ONE EXISTS ON THIS BOX.
# MEASURED the same day: that copy returns **rc=60** against the live vCenter — it is STALE, from
# an earlier cut — and `-s` cannot tell stale from good. Defaulting to it would silently select a
# dead anchor and then hand the operator the rc-60 die naming a file THEY NEVER CHOSE. Adding a
# ca_verifies_endpoint check here would fix that and would put NETWORK in a function documented
# PURE, so it stays out. When no anchor is found, _vc_tls REFUSES, which is the correct outcome.
vcenter_ca_default() {
  [ -n "${VCENTER_CA_FILE:-}" ] && return 0
  # ONE path, deliberately. An earlier draft also probed ${LAB_STATE}/vmca-root.pem because the
  # sibling lab repo produces one there — and `check-env-coverage` correctly went RED: that made
  # LAB_STATE a variable THIS repo reads without owning or documenting, importing another repo's
  # concept into our env contract for a path an operator can set explicitly in one line anyway.
  # The die in _vc_tls_args names the sibling's `make trust-vcsa` in prose instead, which informs
  # without coupling.
  local c="${REPO_ROOT}/secrets/vcenter-ca.pem"
  if [ -s "$c" ]; then
    VCENTER_CA_FILE="$c"; export VCENTER_CA_FILE
    log_info "TLS: using the vCenter anchor at ${c}"
  fi
  return 0
}

# _vc_tls — the ONE place that decides how a vCenter TLS connection is trusted.
#
# Ported from _harbor_ca_args (lib/harbor.sh), which exists for exactly this hazard and says so:
# three functions were each re-deriving it, and the moment they drift one of them sends a
# password over a connection another one refused to. vCenter had it WORSE -- a hardcoded `-k` on
# all three curls, with no knob, no anchor and no pin, while Harbor, ArgoCD and the Supervisor
# each had a trust ladder. This was the only credential-bearing TLS client in the repo with none.
#
# Prints curl args newline-separated; returns 1 when there is neither an anchor nor an explicit
# opt-out, so the CALLER decides what refusing looks like at its own call site.
#
# INSECURE IS OPT-IN, never a fallback. That polarity matches HARBOR_INSECURE/ARGOCD_INSECURE and
# it is the owner decision recorded in B64 ("vCenter is pre-existing customer infrastructure, so
# this repo must fail closed"), re-confirmed 2026-08-18.
_vc_tls() {
  if   [ -n "${VCENTER_CA_FILE:-}" ] && [ -s "${VCENTER_CA_FILE}" ]; then printf '%s\n%s' --cacert "${VCENTER_CA_FILE}"
  elif [ "${VCENTER_INSECURE:-0}" = 1 ];                             then printf '%s' -k
  else return 1; fi
}

# _vc_tls_args <arrayname> [soft] — resolve the anchor and fill the array.
#
# Callers use it as: local -a tls; _vc_tls_args tls        (fatal — the default)
#               or: local -a tls; _vc_tls_args tls soft    (returns 1 instead of dying)
#
# ⚠️ THE `soft` ARM IS NOT SYMMETRY-FOR-ITS-OWN-SAKE — it is a REGRESSION THIS CHANGE CAUSED, and
# the gate caught it. `vc_login --soft` exists so wcp-service.sh's restart-wait can re-probe a
# vCenter that is deliberately down; its whole contract is "RETURN non-zero, do not exit". The
# first version of this function died unconditionally, so a box with no anchor lost the entire
# 600s wait to a refusal on the FIRST probe — turning a recoverable restart into a hard failure.
# test-wcp-service.sh caught it (`vc_login --soft should RETURN non-zero on 000, not exit`).
# Refusing is still correct; dying inside a poll loop is not.
_vc_tls_args() {
  local -n __vc_out="$1"   # nameref: bash 4.3+. MEASURED on the real targets: photon:5.0 ships 5.3.0,
                       # ubuntu:24.04 ships 5.2.21, host 5.2.21 — all far above the floor, and it
                       # works under `set -u` (verified, not assumed).
  local _soft_mode="${2:-}"
  __vc_out=()
  vcenter_ca_default
  # ⚠️ ALL THREE LOCALS ARE `__vc_`-PREFIXED, and that is not cosmetic. A nameref collides
  # SILENTLY with a caller's own variable of the same name: MEASURED, a caller passing an array
  # named `_out` gets "circular name reference" warnings AND an empty array, but one whose locals
  # are named `_t` or `_a` gets an empty array, rc 0, and NO warning at all. An empty array means
  # curl runs with neither --cacert nor -k, so the CA case silently degrades to system-store
  # verification and the insecure case silently drops -k. No caller collides today; the prefix is
  # what keeps it that way.
  local __vc_t __vc_a
  if __vc_t="$(_vc_tls)"; then
    while IFS= read -r __vc_a; do __vc_out+=("$__vc_a"); done <<< "$__vc_t"
    return 0
  fi
  if [ "$_soft_mode" = soft ]; then
    log_warn "no vCenter trust anchor (VCENTER_CA_FILE unset, ./secrets/vcenter-ca.pem absent) —"
    log_warn "  NOT sending credentials to an unverified peer. Set VCENTER_CA_FILE, or accept the"
    log_warn "  risk for this run with VCENTER_INSECURE=1."
    return 1
  fi
  # ⚠️ NAME THE PATH THEY SET, or the message prescribes what they just did. MEASURED: with
  # VCENTER_CA_FILE=/typo/vcenter-ca.pem the first version said "export VCENTER_CA_FILE=…" and
  # never printed the path. `-s` is false for ABSENT and for ZERO-BYTE alike and those have
  # different remedies. The sibling handling this SAME SSO credential already has the arm —
  # 30-vks-login.sh:277: "VKS_CA_CERT_FILE='<path>' is set but missing or empty. Refusing to
  # fall back…".
  if [ -n "${VCENTER_CA_FILE:-}" ]; then
    die "VCENTER_CA_FILE='${VCENTER_CA_FILE}' is set, but that file is missing or empty — so there
  is no anchor to verify vCenter with, and this repo will not send the SSO administrator password
  over a connection whose identity it has not checked.
  Check the path, or produce the anchor with:  make fetch-vcenter-ca
  Or accept the risk for THIS run, deliberately and per-run:  VCENTER_INSECURE=1 make <target>"
  fi
  die "refusing to send the vCenter SSO administrator password over a connection whose identity
  we have not verified. vCenter is pre-existing infrastructure and this repo fails closed there.
  Give it an anchor (any ONE of these):
    - make fetch-vcenter-ca            (downloads vCenter's own roots and picks the one that
                                        VERIFIES it, by handshake, writing ./secrets/vcenter-ca.pem)
    - export VCENTER_CA_FILE=/path/to/the/vCenter/CA.pem
    - put it at ./secrets/vcenter-ca.pem
  vCenter serves its own roots unauthenticated at https://${VCENTER_HOST}/certs/download.zip —
  unzip certs/lin/*.0 and keep the one that VERIFIES vCenter (prove it with a handshake, not a
  subject compare: every lab cut mints a new VMCA with a byte-identical subject).
  NOTE: ./secrets/supervisor-ca.crt is NOT a vCenter anchor — measured on a live lab, it returns
  rc=60 against vCenter while the VMCA root returns rc=0.
  Or accept the risk for THIS run, deliberately and per-run:  VCENTER_INSECURE=1 make <target>"
}

vc_require() {
  require_cmd curl jq base64
  : "${VCENTER_HOST:?VCENTER_HOST is not set (your vCenter FQDN, e.g. vcsa.env1.lab.test)}"
  : "${VCENTER_USERNAME:?VCENTER_USERNAME is not set (e.g. administrator@vsphere.local)}"
  : "${VCENTER_PASSWORD:?VCENTER_PASSWORD is not set - put it in .env or export it}"
}

# vc_login — POST /api/session, store the token in a 0600 file, echo nothing.
# The token is kept in a FILE (not a variable that could leak into a child's argv/environ).
# shellcheck disable=SC2120  # ...and, transitively, SC2119 at the 8 bare call sites.
# `--soft` is OPTIONAL BY DESIGN: eight callers are one-shot entry points that WANT the fatal
# behaviour and correctly pass nothing; only the polling probe in wcp-service.sh passes the flag.
# ShellCheck sees a function that reads "$1" and no caller passing one, so it suggests
# `vc_login "$@"` — which would be WRONG here: it would forward the SCRIPT's argv into this
# function, so `./04-install-harbor-service.sh --anything` would reach the flag parser and die
# with "vc_login: unknown argument". Disabling SC2120 on the definition is the documented way to
# silence the pair; do not "fix" the call sites.
vc_login() {
  # --soft: on a TRANSPORT failure (000) or a server-side error (5xx), WARN and `return 1` instead
  # of dying. For a POLLING caller that is the difference between a diagnosis and a silent death.
  #
  # ⚠️ 401 STAYS FATAL IN BOTH MODES, and that is the load-bearing part. vCenter SSO locks the
  # account after a small number of failures in a short window (this file's own note below says 5
  # in 3 minutes; the operator's standing brief says 3 — operate on the SMALLER number). Dying at
  # the FIRST 401 is what keeps a polling loop's lockout cost at exactly ONE attempt. A "bounded
  # retry on 401" is therefore FORBIDDEN: it would turn a one-attempt burn into 2..N and is the one
  # change that could actually lock the account out. Retrying 000/5xx costs nothing — those never
  # reach the SSO failure counter, because no credential was ever evaluated.
  local _soft=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft) _soft=1; shift ;;
      *) die "vc_login: unknown argument $1" ;;
    esac
  done
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

  local body code _crc
  # Pass the caller's soft-ness through: in a poll loop a missing anchor must be a re-probe, not
  # an exit. See _vc_tls_args' own note — this is the line the wcp-service test pins.
  local -a tls
  if [ "$_soft" = 1 ]; then _vc_tls_args tls soft || return 1; else _vc_tls_args tls; fi
  body="$(mktemp)"; chmod 600 "$body"
  # ⚠️ `|| true` IS GONE, DELIBERATELY, and the 60/77 arms below are why.
  # Removing `-k` without capturing curl's rc would have introduced a NEW critical: rc 60 (the
  # anchor does not verify this server) and rc 77 (the anchor file is unreadable) BOTH surface as
  # http_code=000, which is the "unreachable" arm below — so every TRUST failure would have told
  # the operator to go debug DNS. `&& _crc=0 || _crc=$?`, not `; _crc=$?`, because a plain
  # assignment-then-read aborts under `set -e` (common/coding-style.md).
  code="$(curl -sS "${tls[@]}" -o "$body" -w '%{http_code}' -X POST \
           --connect-timeout "${VC_CONNECT_TIMEOUT:-10}" --max-time "${VC_API_TIMEOUT:-60}" \
           -K "$VC_CURL_CFG" "https://${VCENTER_HOST}/api/session" 2>/dev/null)" && _crc=0 || _crc=$?
  case "$_crc" in
    0) : ;;
    60) rm -f "$body"; die "vCenter's certificate did NOT verify against ${VCENTER_CA_FILE:-<no anchor>} (curl rc 60).
  This is a TRUST failure, not a network one — the host answered. Most likely the lab was re-cut
  and minted a new VMCA: every cut produces a new CA with a BYTE-IDENTICAL subject, so a stale
  anchor looks correct and only a handshake tells you otherwise.
  Re-fetch the anchor, or accept the risk for this run with VCENTER_INSECURE=1." ;;
    # MEASURED: rc 77 fires on ALL of absent, empty, mode-000 AND "exists, readable, but is HTML
    # rather than a PEM" — the last being the realistic operator error (saving the wrong file out
    # of download.zip). The old text said "check it exists and is readable by you", which sends
    # that operator to look at permissions that are fine.
    77) rm -f "$body"; die "could not USE the vCenter anchor '${VCENTER_CA_FILE:-<unset>}' (curl rc 77).
  It is missing, unreadable, or not a PEM certificate. This will say which:
    openssl x509 -in '${VCENTER_CA_FILE:-<path>}' -noout" ;;
    # ⚠️ 35/51 IS SOFT, 60/77 IS NOT, AND THE SPLIT IS THE WHOLE POINT OF THIS ARM.
    # A handshake blip is fixed by WAITING; an anchor problem never is. MEASURED against a listener
    # that accepts TCP but does not speak TLS — a proxy that has bound its port but has not finished
    # coming up, i.e. exactly a service mid-restart: `code=000 rc=35`. And measured against the
    # PREVIOUS code: `curl -sS -k … || true` turned rc 35 into code=000, which the `000` arm below
    # soft-returns. So making it fatal was a REGRESSION I introduced — `make wcp-restart`'s 600s
    # wait used to survive a TLS blip and would have died on the first one, needing no missing
    # anchor, only the restart the target itself induces. This repo already classifies rc 35 as
    # transport-transient twice: fetch-supervisor-ca.sh calls it "half-open … a VIP mid-move" and
    # RETRIES it, and os.sh:1665 records the same signature.
    35|51) rm -f "$body"
         if [ "$_soft" = 1 ]; then
           log_warn "the TLS handshake with ${VCENTER_HOST} failed (curl rc ${_crc}) — expected while it restarts; will re-probe."
           return 1
         fi
         die "the TLS handshake with ${VCENTER_HOST} failed (curl rc ${_crc}). The host answered but the connection could not be secured." ;;
  esac
  # ⚠️ THE SOFT SET IS 000 AND 5xx ONLY, AND THAT LINE IS DELIBERATE.
  #   000  no HTTP response at all — nothing reached SSO, so no credential was evaluated.
  #   5xx  the server failed to process it — likewise no credential verdict.
  # Everything else stays FATAL even in soft mode, including 403: a permission refusal is a
  # CREDENTIAL problem that no amount of waiting fixes, and retrying it is how you approach the
  # lockout threshold sideways. `if`, not `[ ... ] && { ...; }` — the AND-list form returns 1 on
  # the false branch, which under `set -e` would kill the caller from inside a case arm.
  case "$code" in
    201|200) : ;;
    401) rm -f "$body"; die "vCenter rejected VCENTER_USERNAME/VCENTER_PASSWORD (HTTP 401). NOTE: vCenter SSO locks the account after 5 failures in 3 minutes - do not retry blindly." ;;
    000) rm -f "$body"
         if [ "$_soft" = 1 ]; then
           log_warn "vCenter ${VCENTER_HOST} did not answer (no HTTP response) — expected while it restarts; will re-probe."
           return 1
         fi
         die "vCenter ${VCENTER_HOST} is unreachable (no HTTP response). Check the FQDN resolves and is routable from here." ;;
    5??) rm -f "$body"
         if [ "$_soft" = 1 ]; then
           log_warn "vCenter /api/session returned HTTP ${code} — server-side, expected while it restarts; will re-probe."
           return 1
         fi
         die "vCenter /api/session returned HTTP ${code:-<none>}" ;;
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
  # ⚠️ THIS ONE USES _vc_tls DIRECTLY AND NEVER _vc_tls_args, because _vc_tls_args DIES and this
  # runs as an EXIT trap. A `die` here would replace the caller's real exit status and its real
  # error message with a TLS complaint raised during cleanup. If we cannot verify the peer we
  # simply do not send the token to it — the session expires on its own — and we still remove the
  # local credential files, which is the part that actually matters on this box.
  local -a tls=(); local _t _a
  if _t="$(_vc_tls)"; then
    while IFS= read -r _a; do tls+=("$_a"); done <<< "$_t"
    curl -sS "${tls[@]}" -o /dev/null -X DELETE --max-time 20 -H "@${VC_HDR_FILE}" \
      "https://${VCENTER_HOST}/api/session" 2>/dev/null || true
  else
    # Not silent: the session stays alive server-side until vCenter's idle timeout, and an
    # operator who never sees this line has no way to know that happened.
    log_warn "no vCenter trust anchor at logout — NOT sending the session token to an unverified"
    log_warn "  peer. The session will expire on its own; local credential files are still removed."
  fi
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
  # Same trust decision as vc_login, from the same ONE place. `|| true` is kept HERE (unlike
  # vc_login) because this function's contract is to return non-zero on any non-2xx WITHOUT dying
  # — some callers legitimately expect a 404 — so a transport failure has to reach them as an
  # empty code, not as an exit. The 60/77 discrimination lives in vc_login, which every caller
  # runs first, so a bad anchor is diagnosed there rather than surfacing here as a bare 000.
  local -a tls; _vc_tls_args tls
  code="$(curl -sS "${tls[@]}" -o "$body" -w '%{http_code}' -X "$method" \
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
  # BUDGET = tries x interval = 60 x 10s = 10 min. Both transients below are ASYNC platform work
  # whose duration we do not control, so the budget is sized from measurement, not taste:
  # MEASURED 2026-08-10 on an idle, freshly rebuilt 9.1 lab -- argocd's signature verified in ~10s
  # (one poll), harbor's in ~107s (17:11:47 refused -> 17:13:34 accepted). 10 min is ~5.6x the worst
  # observed, on a box under no other load; a busy vCenter is the case nobody has measured, which is
  # why this is generous rather than tight. The 10s CADENCE is not the cost -- it is one cheap POST
  # per poll, and a short interval only means faster recovery. Raising the ceiling is free until it
  # fires; a too-tight ceiling turns a wait into a FATAL that reads like a broken service file.
  local tries="${VC_SS_INSTALL_RETRIES:-60}" i=1 code
  while :; do
    if out="$(vc_api POST "/api/vcenter/namespace-management/clusters/${moid}/supervisor-services" \
                --data-binary "@${req}")"; then
      rm -f "$req"; return 0
    fi
    code="$(vc_last_code)"
    case "$out" in
      *"not ready"*|*"try again later"*)
        [ "$i" -lt "$tries" ] || { rm -f "$req"; die "the service account was still not ready after ${tries} attempts"; }
        [ "$i" = 1 ] && log_info "vCenter: service account not ready yet - retrying (up to ${tries}x)"
        i=$((i + 1)); sleep "${VC_SS_INSTALL_INTERVAL:-10}" ;;
      *"in terminating status"*)
        # A THIRD transient, found by re-walking scenario-1 from scratch 2026-08-10. Uninstalling a
        # Supervisor Service leaves its namespace (svc-<name>-<hash>) TERMINATING for a while, and a
        # reinstall during that window is refused:
        #   HTTP 500 "The namespace (svc-harbor-1dgwt) is in terminating status. Please wait for the
        #             namespace to be fully deleted before attempting to install the service again."
        # The platform is telling us to retry, in those words. Without this arm the operator gets a
        # FATAL that reads like a broken service file, on the ordinary uninstall-then-reinstall path.
        [ "$i" -lt "$tries" ] || { rm -f "$req"; die "the previous install's namespace was still terminating after ${tries} attempts"; }
        [ "$i" = 1 ] && log_info "vCenter: the previous ${id} namespace is still terminating - retrying (up to ${tries}x)"
        i=$((i + 1)); sleep "${VC_SS_INSTALL_INTERVAL:-10}" ;;
      *"signature verification result not found"*)
        # A SECOND transient, same shape as the one above and a DIFFERENT status (500, not 404).
        # MEASURED 2026-08-10 on a freshly rebuilt lab: registering a service and installing it in
        # the same second returns
        #   HTTP 500 "Failed to run compatibility check ... signature verification result not found
        #             for Supervisor Service <id>/<ver> on Supervisor <uuid>"
        # The Supervisor verifies a newly-registered service's signature ASYNCHRONOUSLY; until that
        # lands, the compatibility check has nothing to read. Re-running by hand ~2 min later
        # succeeded with no other change.
        #
        # It is NOT covered by the end-state check below: the install never happened, so
        # vc_ss_state is empty and that arm correctly declines to claim success -- it just dies,
        # naming a 500 that reads like a broken service file rather than a wait.
        [ "$i" -lt "$tries" ] || { rm -f "$req"; die "the Supervisor had still not verified ${id}'s signature after ${tries} attempts"; }
        [ "$i" = 1 ] && log_info "vCenter: ${id}'s signature is not verified yet (async, follows registration) - retrying (up to ${tries}x)"
        i=$((i + 1)); sleep "${VC_SS_INSTALL_INTERVAL:-10}" ;;
      *"already exists"*)
        # IDEMPOTENT. Re-running an install is a normal thing to do -- after a transport error,
        # after a partial run, or just twice. Dying here made the target non-re-runnable.
        rm -f "$req"; log_info "${id} is already installed on this cluster - nothing to do"; return 0 ;;
      *)
        # ⚠️ VERIFY THE END STATE, do not trust the status code. MEASURED on a clean lab: the
        # install returned HTTP 500 and HAD CREATED THE SERVICE ANYWAY -- the next run said
        # "already exists". Failing here reports a failure over a request that worked, and sends
        # the operator to debug an install that is in fact proceeding.
        if [ -n "$(vc_ss_state "$moid" "$id")" ]; then
          rm -f "$req"
          log_warn "install returned HTTP ${code}, but ${id} IS present on the cluster - treating as installed."
          log_warn "  vCenter said: $(printf '%s' "$out" | head -c 200)"
          return 0
        fi
        # ⚠️ POLARITY: a 5xx here is RETRYABLE BY DEFAULT, not fatal by default.
        # The three named arms above are an ENUMERATED LIST of platform strings, and enumerated
        # lists rot: re-walking scenario-1 from scratch on 2026-08-10 produced THREE distinct
        # transient 500s in one afternoon ("signature verification result not found", "namespace
        # ... in terminating status", and the webhook race handled at the CR apply). Each was
        # patched one string at a time; the FOURTH would still have FATAL-ed.
        # Installing a Supervisor Service is ASYNC platform work, so "the server had a problem"
        # is far more often "it is not finished yet" than "your request is wrong". A malformed
        # request is a 4xx and still fails fast below.
        # COST, stated: a genuinely permanent 5xx now costs the full budget (10 min) before it
        # dies -- and it dies quoting vCenter verbatim, so the diagnosis is not lost, only delayed.
        case "$code" in
          5??)
            [ "$i" -lt "$tries" ] || { rm -f "$req"; die "install failed with HTTP ${code} on every one of ${tries} attempts: $(printf '%s' "$out" | head -c 400)"; }
            [ "$i" = 1 ] && log_info "vCenter returned HTTP ${code} (async platform work is often still in flight) - retrying (up to ${tries}x)"
            i=$((i + 1)); sleep "${VC_SS_INSTALL_INTERVAL:-10}"; continue ;;
        esac
        rm -f "$req"; die "install failed (HTTP ${code}): $(printf '%s' "$out" | head -c 400)" ;;
    esac
  done
}

# vc_ss_state <supervisor-uuid> <service-id> -> config_status string (or empty)
# vc_ss_state <supervisor-uuid-OR-cluster-moid> <service-id> -> config_status, or empty.
# Tries the supervisor-scoped route then the cluster-scoped one, because callers legitimately hold
# one id or the other and the two are DIFFERENT id spaces (a UUID vs domain-cN).
vc_ss_state() {
  local st
  st="$(vc_api GET "/api/vcenter/namespace-management/supervisors/${1}/supervisor-services/${2}" 2>/dev/null \
        | jq -r '(.config_status // .status // empty)' 2>/dev/null || true)"
  [ -n "$st" ] && { printf '%s' "$st"; return 0; }
  vc_api GET "/api/vcenter/namespace-management/clusters/${1}/supervisor-services/${2}" 2>/dev/null \
    | jq -r '(.config_status // .status // empty)' 2>/dev/null || true
}
