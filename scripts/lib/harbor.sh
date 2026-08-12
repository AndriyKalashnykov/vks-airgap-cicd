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
  : "${HARBOR_URL:?}"; : "${HARBOR_USERNAME:?set HARBOR_USERNAME in .env (admin for scenario 1, your robot for scenario 2)}"
  # HARBOR_URL is a BARE HOST — every call below builds "${SCHEME}://${HARBOR_URL}/…". A scheme here
  # produces https://https://host/… and curl fails with `(6) Could not resolve host: https`, which
  # names neither the variable nor the file. MEASURED 2026-08-04: fetch-ca.sh accepts a scheme (it
  # parses host/port), so §6 of scenario-1 passes and the failure lands two steps later in §7 —
  # far from the mistake. Normalise, and SAY SO: silently accepting both spellings would leave the
  # operator's .env wrong for every other consumer.
  case "$HARBOR_URL" in
    http://*|https://*)
      log_warn "HARBOR_URL='${HARBOR_URL}' carries a scheme; HARBOR_URL is a BARE HOST. Stripping it —"
      log_warn "  fix .env, because other consumers read it verbatim."
      HARBOR_URL="${HARBOR_URL#http://}"; HARBOR_URL="${HARBOR_URL#https://}" ;;
  esac
  HARBOR_URL="${HARBOR_URL%/}"          # a trailing slash yields //api/v2.0/… on some proxies
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
  # Curl auth in a real umask-077 config FILE (kept out of argv). esc_curlk (lib/os.sh) is not
  # cosmetic: a bare `"` in the password TRUNCATES it at that character and a `\` is EATEN, so an
  # ordinary strong password 401s and the diagnostic below blames the wrong thing. A newline would
  # inject a curl DIRECTIVE outright.
  HARBOR_CURL_CFG="${tmp}/curl.cfg"
  ( umask 077; printf 'user = "%s:%s"\n' "$(esc_curlk "$HARBOR_USERNAME")" "$(esc_curlk "$HARBOR_PASSWORD")" > "$HARBOR_CURL_CFG" )
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
    401)
      # 401 IS NOT A PERMISSIONS PROBLEM — IT IS A WRONG PASSWORD, and saying otherwise sends the
      # operator to fix a thing that is not broken. Measured against a live Harbor (2026-07-14):
      #   wrong password -> 401 (unauthenticated)   ·   authenticated-but-not-admin -> 403 (forbidden)
      # This branch used to be `401|403`, so a stale credential printed "you are not a Harbor admin"
      # and the run continued into a cascade of failures whose real cause was three steps back.
      #
      # THE COMMON CAUSE, and it is not obvious: Harbor's admin password lives in its DATABASE, seeded
      # at FIRST install. A re-install (helm upgrade) rotates the SECRET but NOT the database, so if the
      # cluster survived, Harbor still wants the ORIGINAL password. The classic way to get here is to run
      # `make install-harbor` with your .env and then `make e2e-kind`, which sets SKIP_DOTENV=1 and
      # GENERATES fresh credentials — new password in the state sink, old password in Harbor's DB.
      log_error "Harbor rejected the credentials for '${HARBOR_USERNAME:-<unset>}' (HTTP 401 = UNAUTHENTICATED)."
      log_error "  This is NOT a permissions problem — Harbor returns 403 for that. The PASSWORD IS WRONG."
      log_error "  Most likely: Harbor's DATABASE survives from an earlier install and still holds the"
      log_error "  ORIGINAL admin password, while a later install generated a new one (e.g. 'make"
      log_error "  install-harbor' with your .env, then 'make e2e-kind', which regenerates credentials)."
      log_error "  Fix: 'make kind-down' and re-run (a fresh Harbor is seeded with the current password),"
      log_error "  or set HARBOR_PASSWORD to the password Harbor was FIRST installed with."
      return 1
      ;;
    403)
      # A TENANT is not a Harbor admin and cannot create projects — and a robot account cannot
      # either. This used to `die`, which meant a tenant's `make harbor-robot` (and a `make mirror`
      # run with robot creds against a fresh Harbor) failed here, BEFORE reaching the thing they
      # actually came for. Not being allowed to create a project you were already GRANTED is not
      # an error; only its absence is.
      log_warn "not permitted to create Harbor project '$name' (http $code) — you are authenticated, but not a Harbor admin."
      log_warn "  If the project already exists and you were granted it, this is harmless."
      log_warn "  If it does NOT exist, ask your platform team to create it, or point"
      log_warn "  HARBOR_INFRA_PROJECT / HARBOR_APP_PROJECT at the project(s) you were given."
      return 1
      ;;
    *) die "failed to create Harbor project '$name' (http $code)" ;;
  esac
}

# harbor_auth_report — READ-ONLY: do HARBOR_USERNAME/HARBOR_PASSWORD actually AUTHENTICATE?
# Same house style and contract as harbor_reachable_report: ok/PROBLEM/note to stderr, returns the
# problem count (0 or 1). Call it AFTER harbor_reachable_report -- a credential cannot be judged
# against something that is not serving.
#
# WHY IT EXISTS -- a measured 605-second failure
# ----------------------------------------------
# MEASURED 2026-08-12, the "Harbor already exists" row of the scenario-1 walk: `make env-validate`
# reported `Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)` at 15:00:13 and exited 1 --
# correctly, five minutes before anything else noticed. The walk (and any reader who pastes Step 11's
# block into one terminal, since the lines are newline-separated and not `&&`-chained) then ran
# `make install-all` anyway: it mirrored 24 images, built the offline Maven builder, and died 605s
# later pushing it, on the SAME credential, with an error naming a blob upload.
#
# lab-preflight is the thing install-all runs FIRST precisely so a doomed run stops in its first
# seconds. It checked that Harbor SERVES and never that we can LOG IN -- so the one precondition that
# was actually wrong was the one it did not look at. This closes that, for every reader and every
# credential, without depending on anyone reading prose.
#
# 403 IS A PASS, and this is not a nicety: a PROJECT-SCOPED ROBOT (what scenario-1 Step 9 tells the
# reader to create, and what the pipeline should run as) is fully authenticated and still gets 403
# from /users/current, which is a SYSTEM-scoped endpoint. Treating "any non-200" as failure would
# turn the least-privilege path into a hard stop -- a false RED introduced by a gate meant to help.
# Only 401 means the credential is wrong; Harbor returns 403 for a permissions problem.
# _harbor_auth_code <curl-tls-args...> — ONE http code, or 000. The probe, with no opinion.
# `|| echo 000` is NOT used: curl's -w already prints 000 on a connection failure, so appending
# another produced the literal `http 000000` in the operator-facing message (measured).
_harbor_auth_code() {
  local cfg rc=0 code
  cfg="$(mktemp)"; chmod 600 "$cfg"
  printf 'user = "%s:%s"\n' "$(esc_curlk "${HARBOR_USERNAME:-admin}")" "$(esc_curlk "${HARBOR_PASSWORD}")" > "$cfg"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${HARBOR_PROBE_TIMEOUT_SECONDS:-10}" \
            "$@" -K "$cfg" "https://${HARBOR_URL}/api/v2.0/users/current" 2>/dev/null)" || rc=$?
  rm -f "$cfg"
  [ "$rc" = 0 ] || code=000
  case "${code:-}" in ''|*[!0-9]*) code=000 ;; esac
  printf '%s' "$code"
}

# _harbor_ca_args — the TLS anchor, resolved ONCE. Prints the curl args, or nothing and returns 1
# when we have no way to verify. Three functions were each re-deriving this; the moment they drift,
# one of them sends a password over a connection another one refused to.
_harbor_ca_args() {
  if   [ -n "${HARBOR_CA_FILE:-}" ] && [ -s "${HARBOR_CA_FILE}" ]; then printf '%s\n%s' --cacert "${HARBOR_CA_FILE}"
  elif [ "${HARBOR_INSECURE:-0}" = 1 ];                            then printf '%s' -k
  else return 1; fi
}

# harbor_auth_ok — 0 ONLY when Harbor demonstrably ACCEPTED the credential (200, or 403 from a
# project-scoped robot). Everything else, INCLUDING an inconclusive probe, is non-zero.
#
# ⚠️ DO NOT SUBSTITUTE harbor_auth_report FOR THIS. A REPORTER returns "problems found"; 0 means
# "nothing to report", which it also returns when it could not tell (no CA yet, a stale CA, a
# timeout) -- so `if harbor_auth_report; then "the credential works"` is a FAKE GREEN. MEASURED
# 2026-08-12: with a wrong CA and a deliberately wrong password, harbor_auth_report returned 0 and a
# caller using it as a verifier concluded the wrong password worked. "Verified" and "could not tell"
# are different answers and need different functions.
harbor_auth_ok() { [ "$(harbor_auth_verdict)" = accepted ]; }

# harbor_auth_verdict — THREE outcomes, because two is not enough and the third one lies.
#   accepted | rejected | unchecked:<why>
#
# harbor_auth_ok collapses "Harbor said no" and "I could not ask" into the same non-zero, and a
# caller that reports the first message for the second condition tells the operator something FALSE.
# MEASURED 2026-08-12, row 4 of the scenario-1 walk: at Step 4 there is no Harbor CA yet (Step 8
# fetches it), so the probe SKIPPED -- and 28-harbor-admin-password.sh printed "the password ... does
# NOT authenticate ... a Harbor whose password was later changed keeps the OLD one and this secret is
# stale", about a password that had never been sent anywhere. An error that names the wrong cause is
# worse than a crash: it sends the operator to fix a thing that is not broken.
harbor_auth_verdict() {
  [ -n "${HARBOR_URL:-}" ]              || { printf 'unchecked:no HARBOR_URL'; return; }
  if is_placeholder "${HARBOR_PASSWORD:-}"; then printf 'unchecked:no password'; return; fi
  local -a cafg=(); local _ca
  if _ca="$(_harbor_ca_args)"; then
    while IFS= read -r _a; do cafg+=("$_a"); done <<< "$_ca"
  else
    printf 'unchecked:no CA yet (Step 8 fetches it) and HARBOR_INSECURE is not 1'; return
  fi
  case "$(_harbor_auth_code "${cafg[@]}")" in
    200|403) printf 'accepted' ;;
    401)     printf 'rejected' ;;
    *)       printf 'unchecked:the probe did not complete' ;;
  esac
}

harbor_auth_report() {
  local ok_p='  ok       ' bad_p='  PROBLEM  ' note_p='           '
  [ -n "${HARBOR_URL:-}" ] || return 0                      # reachable_report already said so
  if is_placeholder "${HARBOR_PASSWORD:-}"; then
    printf '%sHARBOR_PASSWORD is unset — cannot check whether Harbor accepts you.\n' "$note_p" >&2
    printf '%s  (make env-check owns that; this only reports what it can measure.)\n' "$note_p" >&2
    return 0
  fi

  # Verify TLS against our own CA when we have one. A password may not travel over a connection we
  # cannot verify unless the operator has already accepted that (HARBOR_INSECURE=1), so an absent CA
  # is a NOTE, not a silent `-k`: this probe sends a credential, unlike the reachability one.
  local -a cafg=(); local _ca
  if _ca="$(_harbor_ca_args)"; then
    while IFS= read -r _a; do cafg+=("$_a"); done <<< "$_ca"
  else
    printf '%sno HARBOR_CA_FILE yet — skipping the auth probe rather than send a password\n' "$note_p" >&2
    printf '%s  over an unverified connection. Step 8 (make fetch-harbor-ca) provides it.\n' "$note_p" >&2
    return 0
  fi

  # esc_curlk (lib/os.sh) is REQUIRED, not defensive: a bare `"` in the password truncates it, a `\`
  # is eaten and a newline injects a curl directive -- each of which reports a FALSE 401, the exact
  # wrong answer from a gate whose whole job is to say whether the credential works.
  local acode; acode="$(_harbor_auth_code "${cafg[@]}")"

  case "$acode" in
    200) printf '%sHarbor accepts %s (http 200)\n' "$ok_p" "${HARBOR_USERNAME:-admin}" >&2; return 0 ;;
    403) printf '%sHarbor accepts %s (http 403 from /users/current — a project-scoped robot, authenticated)\n' \
           "$ok_p" "${HARBOR_USERNAME:-admin}" >&2; return 0 ;;
    401)
      printf '%sHarbor REJECTED %s (http 401). install-all cannot succeed on this credential,\n' "$bad_p" "${HARBOR_USERNAME:-admin}" >&2
      printf '%s  and takes 8-10 minutes to say so — it stops here instead.\n' "$note_p" >&2
      printf '%s401 is authentication, not permissions (Harbor returns 403 for those). The usual cause\n' "$note_p" >&2
      printf '%s  is a GENERATED password against a Harbor that already existed: it keeps the password\n' "$note_p" >&2
      printf '%s  from its FIRST install, and a later data-values submission does not change it.\n' "$note_p" >&2
      printf '%sSet HARBOR_USERNAME/HARBOR_PASSWORD in .env to the credential that Harbor was\n' "$note_p" >&2
      printf '%s  installed with, or to a robot from '\''make harbor-robot'\''.\n' "$note_p" >&2
      return 1 ;;
    *)   printf '%sHarbor auth probe inconclusive (http %s) — not judging it here\n' "$note_p" "$acode" >&2; return 0 ;;
  esac
}

# harbor_reachable_report — READ-ONLY: does HARBOR_URL actually SERVE? Prints ok/PROBLEM/note lines
# to stderr in the preflight house style and RETURNS the problem count (0 or 1).
#
# WHY IT IS ITS OWN FUNCTION, not three lines inside 24-lab-preflight.sh
# ---------------------------------------------------------------------
# scenario-1 needs this answer at STEP 4, right after `install-harbor-service`, when a reinstalled
# Harbor has taken a NEW LoadBalancer IP and the operator's A record still names the old one. But
# lab-preflight's other three checks (CRD-create, a DEFAULT StorageClass, a LoadBalancer provider)
# are GUEST-CLUSTER preconditions, and at Step 4 the current context is the SUPERVISOR -- the guest
# cluster is not created until Step 6. Pointing Step 4 at `make lab-preflight` therefore reports
# PROBLEMs on a CORRECT walk, and a gate that is red when nothing is wrong is a gate people learn to
# ignore. So the check is ADDITIVE and separately scoped (`make harbor-reachable`) rather than
# lab-preflight being taught to skip: lab-preflight keeps full coverage for `install-all`, and Step 4
# gets a target that answers exactly the question it is asking.
#
# Needs NO cluster and NO kubectl -- it is DNS + one HTTPS request, so it works from the jump box at
# Step 4 and from a guest-cluster context at install-all time, unchanged.
#
# MEASURED 2026-08-11 on both OS rows of the create-from-nothing walk: Harbor was healthy (9 pods
# Running, harbor-nginx on 192.168.101.141) while DNS still said 192.168.101.135 from the previous
# install. It cost FIVE failures -- Step 8's CA fetch hung 129s and wrote an EMPTY file before
# `openssl` said "Could not find certificate" (naming the file, not the reason), `make harbor-robot`
# burned 262s, then env-populate and both ingress steps.
#
# Probed by REACHABILITY, not by comparing to the LoadBalancer object: Harbor's LB lives on the
# SUPERVISOR while lab-preflight runs against the GUEST cluster, so the object is not ours to read --
# and "does it answer?" is the end result anyway, which also catches a down Harbor or a firewall.
# harbor_reachable_ok — 0 ONLY when Harbor demonstrably ANSWERED. The verifier counterpart of
# harbor_reachable_report, and it exists for the same reason harbor_auth_ok does: the REPORTER
# returns 0 for "nothing to report", which includes "the name does not resolve yet" (a note, not a
# problem -- correct for a preflight, useless as a predicate). A wait loop keyed on the reporter
# would exit immediately on an unresolvable name and declare Harbor reachable.
harbor_reachable_ok() {
  [ -n "${HARBOR_URL:-}" ] || return 1
  getent hosts "${HARBOR_URL%%:*}" >/dev/null 2>&1 || return 1
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${HARBOR_PROBE_TIMEOUT_SECONDS:-10}" \
            "https://${HARBOR_URL}/api/v2.0/systeminfo" 2>/dev/null || true)"
  case "${code:-000}" in 000|'') return 1 ;; *) return 0 ;; esac
}

harbor_reachable_report() {
  local ok_p='  ok       ' bad_p='  PROBLEM  ' note_p='           '
  [ -n "${HARBOR_URL:-}" ] || { printf '%sHARBOR_URL is not set — nothing to check\n' "$note_p" >&2; return 0; }

  local hip
  hip="$(getent hosts "${HARBOR_URL%%:*}" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [ -z "$hip" ]; then
    printf '%sHARBOR_URL=%s does not resolve yet — expected before you create the A record\n' "$note_p" "$HARBOR_URL" >&2
    printf '%s  that '\''make show-dns-records'\'' prints. It must resolve before '\''make mirror'\''.\n' "$note_p" >&2
    return 0
  fi

  # --fail is deliberately ABSENT: a 4xx from a live Harbor still proves it is SERVING. Judge only on
  # whether the connection produced any HTTP response at all. 000 means nothing answered.
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${HARBOR_PROBE_TIMEOUT_SECONDS:-10}" \
            "https://${HARBOR_URL}/api/v2.0/systeminfo" 2>/dev/null || true)"
  if [ "${code:-000}" = 000 ]; then
    printf '%sHARBOR_URL=%s resolves to %s but NOTHING is serving there.\n' "$bad_p" "$HARBOR_URL" "$hip" >&2
    printf '%sA REINSTALLED Harbor gets a NEW LoadBalancer IP. Compare that address with what\n' "$note_p" >&2
    printf '%s  '\''make show-dns-records'\'' prints now, and update the A record if they differ.\n' "$note_p" >&2
    printf '%s(Otherwise this surfaces as a 129s hang in Step 8 and a 262s one in '\''make harbor-robot'\'',\n' "$note_p" >&2
    printf '%s  neither of which mentions DNS.)\n' "$note_p" >&2
    return 1
  fi
  printf '%sHarbor answers at %s (%s, http %s)\n' "$ok_p" "$HARBOR_URL" "$hip" "$code" >&2
  return 0
}
