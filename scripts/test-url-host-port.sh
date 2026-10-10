#!/usr/bin/env bash
# ci-tier: fast — OFFLINE. Real `openssl s_server` listeners on 127.0.0.1 and ::1; no lab, no login.
#
# test-url-host-port.sh — one host/port splitter (lib/os.sh url_host_port), and a login typed
# into an address never reaches a report line.
#
# THE DEFECTS.
#   * Five hand-typed splitters and three `${x%%:*}` one-liners read the same address differently:
#     `[::1]:8443` was host `[` to some, `[::1]` to others, `::1` to a third. The ones that kept
#     the brackets then verified the NAME `[::1]`, and the ones that cut at the first colon dialled
#     nothing: a healthy IPv6 endpoint read as "did not answer".
#   * HARBOR_URL / ARGOCD_SERVER were printed verbatim, so `user:password@harbor…` put the
#     password in a terminal and in whatever the reader pasted from it.
#
# WHAT IS PINNED: the splitter's table (scheme, path, login, `[v6]:port`, `[v6]`, a bare v6, a
# bad port); the join that puts the brackets back; that load_env takes a login out of the two
# variables and says so WITHOUT printing it; that the reports and the fetch print no part of it;
# and, against a real listener on ::1, that the CA check, `make ca-status` and the fetch all reach
# `[::1]:<port>`.
#
# A BARE IPv6 LITERAL HAS NO PORT, and this file pins that on purpose: `::1:8443` is itself a
# valid address, so nothing can tell a port from the last group. `::1` is the address ::1 on 443.
#
# DOES NOT PROVE: that any tool this repo drives (crane, podman, argocd, kubectl) accepts an IPv6
# registry or server address, nor a zone id (`fe80::1%eth0`). Only the parsing and the TLS checks.
set -uo pipefail
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$REPO_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
command -v openssl >/dev/null 2>&1 || { echo "test-url-host-port: INCONCLUSIVE — openssl is not installed (nothing was asserted)"; exit 1; }

LIB_OS="${REPO}/scripts/lib/os.sh"
LIB_TLS="${REPO}/scripts/lib/tls.sh"
# shellcheck source=scripts/lib/os.sh
. "$LIB_OS"
# shellcheck source=scripts/lib/tls.sh
. "$LIB_TLS"

T="$(mktemp -d)"
PIDS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  local p
  while read -r p; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done <<< "$PIDS"
  rm -rf "$T"
}
trap cleanup EXIT
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
# The load_env cases give it a sandbox REPO_ROOT whose .env is the fixture: a caller's
# SKIP_DOTENV=1 would make it ignore that file.
unset SKIP_DOTENV _VKS_BOUNDS_REPORTED
# Run from `make test-scripts` this file inherits make's own environment: the pins the Makefile
# exports to every recipe (empty when unset), MAKEFLAGS, MAKELEVEL. Each case states its inputs.
unset HARBOR_CA_SHA256 ARGOCD_CA_SHA256 CA_VERIFY_TIMEOUT _FETCH_CA_ENDPOINT MAKEFLAGS MAKELEVEL MFLAGS
has() { command grep -qF -- "$2" <<< "$1"; }
SECRET='s3cr3t-must-not-appear'

# ══ 1. the splitter ══════════════════════════════════════════════════════════════════════════
# input | host | port | host_port_join
while IFS='|' read -r in h p j; do
  [ -n "$j" ] || continue
  url_host_port "$in"
  got="${URL_HOST}|${URL_PORT}|$(host_port_join "$URL_HOST" "$URL_PORT")"
  if [ "$got" = "${h}|${p}|${j}" ]; then ok "url_host_port: ${in} -> host ${h}, port ${p}, shown as ${j}"
  else bad "url_host_port: ${in}" "wanted '${h}|${p}|${j}', got '${got}'"; fi
done <<'ROWS'
harbor.example|harbor.example|443|harbor.example:443
harbor.example:8443|harbor.example|8443|harbor.example:8443
https://harbor.example|harbor.example|443|harbor.example:443
https://harbor.example:8443/v2/|harbor.example|8443|harbor.example:8443
harbor.example/|harbor.example|443|harbor.example:443
10.0.0.5:8443|10.0.0.5|8443|10.0.0.5:8443
[::1]:8443|::1|8443|[::1]:8443
[::1]|::1|443|[::1]:443
::1|::1|443|[::1]:443
https://[2001:db8::1]:8443/x|2001:db8::1|8443|[2001:db8::1]:8443
2001:db8::1|2001:db8::1|443|[2001:db8::1]:443
harbor.example:https|harbor.example|443|harbor.example:443
user:s3cr3t-must-not-appear@harbor.example:8443|harbor.example|8443|harbor.example:8443
https://user:s3cr3t-must-not-appear@[::1]:8443/x|::1|8443|[::1]:8443
h.example/r?u=https://evil.example|h.example|443|h.example:443
h.example:8443/r?next=http://evil.example:1/|h.example|8443|h.example:8443
harbor.example/proj/img@sha256:0123abcd|harbor.example|443|harbor.example:443
ROWS
# A SCHEME IS A SCHEME ONLY AT THE START. `*://*` anywhere used to be cut at: the address
# `h.example/r?u=https://evil.example` came out as the host `evil.example` (rows above).
# A bare IPv6 literal cannot carry a port: `::1:8443` is read as ONE address, on 443.
url_host_port '::1:8443'
if [ "$URL_HOST" = '::1:8443' ] && [ "$URL_PORT" = 443 ]; then ok "url_host_port: a bare '::1:8443' is ONE address on port 443 (a port needs the brackets: [::1]:8443)"
else bad "url_host_port: a bare IPv6 literal with a trailing group" "host '${URL_HOST}' port '${URL_PORT}'"; fi
# The three wrappers are the same splitter (they were three separate ones).
if [ "$(registry_hostport '[::1]:5000')" = '[::1]:5000' ] && [ "$(registry_hostport 'https://harbor.lab/')" = 'harbor.lab:443' ] \
   && [ "$(registry_hostport '::1')" = '[::1]:443' ]; then ok "registry_hostport: same answers through the one splitter ([::1]:5000, harbor.lab:443, a bare ::1 -> [::1]:443)"
else bad "registry_hostport: disagrees with the splitter" "$(registry_hostport '[::1]:5000') $(registry_hostport 'https://harbor.lab/') $(registry_hostport '::1')"; fi
# shellcheck source=scripts/lib/harbor.sh
. "${REPO}/scripts/lib/harbor.sh"
hh=""
for u in 'harbor.example:8443' 'https://harbor.example/' '[fd00::1]:443' 'fd00::1' "user:${SECRET}@harbor.example"; do hh="${hh}$(HARBOR_URL="$u" harbor_url_host) "; done
if [ "$hh" = 'harbor.example harbor.example fd00::1 fd00::1 harbor.example ' ]; then ok "harbor_url_host: port, scheme, brackets and a login are all removed"
else bad "harbor_url_host: disagrees with the splitter" "got '${hh}'"; fi
for row in '::1|ip' '2001:db8::1|ip' '10.0.0.5|ip' 'harbor.example|name' 'localhost|name'; do
  if [ "$(ca_addr_kind "${row%%|*}")" = "${row##*|}" ]; then ok "ca_addr_kind: ${row%%|*} is ${row##*|}"
  else bad "ca_addr_kind: ${row%%|*}" "wanted ${row##*|}, got $(ca_addr_kind "${row%%|*}")"; fi
done

# ══ 2. a login in an address ═════════════════════════════════════════════════════════════════
while IFS='|' read -r in want; do
  [ -n "$want" ] || continue
  got="$(url_without_userinfo "$in")"
  if [ "$got" = "$want" ]; then ok "url_without_userinfo: ${in//$SECRET/…} -> ${want}"
  else bad "url_without_userinfo: ${in//$SECRET/…}" "wanted '${want}', got '${got//$SECRET/<THE SECRET>}'"; fi
done <<'ROWS'
harbor.example:8443|harbor.example:8443
user:s3cr3t-must-not-appear@harbor.example:8443|harbor.example:8443
https://user:s3cr3t-must-not-appear@harbor.example/v2/|https://harbor.example/v2/
https://harbor.example/path/with@sign|https://harbor.example/path/with@sign
user@[::1]:8443|[::1]:8443
harbor.example/proj/img@sha256:0123abcd|harbor.example/proj/img@sha256:0123abcd
harbor.example:8443/proj/img@sha256:0123abcd|harbor.example:8443/proj/img@sha256:0123abcd
h.example/r?u=https://u:p@evil.example|h.example/r?u=https://u:p@evil.example
ROWS
# A LOGIN THAT CANNOT BE READ OUT IS REFUSED, NOT HALF-STRIPPED. A password with a `/` or a `://`
# in it leaves the `@` behind the first `/`, where it is not a login any more by the rule above:
# the "host" is then the user name, and the password stays in the value.
# THE RULE HAS NO EXEMPTION: any `@` left after the strip refuses the value. The first version
# let a "plain host[:port]" front through, to spare `host:8443/img@sha256:…`, and
# `admin:4411/SEKR@harbor.example` has exactly that front: MEASURED, the password stayed and
# `admin:4411` was dialled. These two variables hold a host, never an image reference, so a
# digest reference put there is refused as well.
while IFS='|' read -r in want what; do
  [ -n "$what" ] || continue
  if url_login_unreadable "$in"; then got=refused; else got=readable; fi
  if [ "$got" = "$want" ]; then ok "url_login_unreadable: ${what} -> ${want}"
  else bad "url_login_unreadable: ${what}" "wanted ${want}, got ${got}"; fi
done <<'ROWS'
u:s3cr3t/must-not-appear@h.example|refused|a password with a / in it
u:s3cr3t://must-not-appear@h.example|refused|a password with :// in it
https://u:s3cr3t/must-not-appear@h.example/v2/|refused|the same behind a scheme
admin:4411/SEKR@harbor.example|refused|a password that starts with digits and a / (the front looks like host:port)
ad:be/SEKR@harbor.example|refused|a password whose front looks like hex
admin:SEKR@4411/x@harbor.example|refused|a password with @ and / in it (a strip would leave a piece of it)
harbor.example/proj/img@sha256:0123abcd|refused|an image reference with a digest (not a host: refused too)
harbor.example:8443/proj/img@sha256:0123abcd|refused|the same with a port
h.example/r?u=https://evil.example|readable|a URL in the query, no @ at all
user:s3cr3t-must-not-appear@harbor.example:8443|readable|an ordinary login (it is stripped, not refused)
admin:SE@KR@harbor.example:8443|readable|a password with an @ in it and no / (stripped at the LAST @)
https://admin:SEKR@[::1]:8443/x|readable|a login before a bracketed IPv6 address
harbor.example:8443|readable|a plain address
ROWS
# load_env: the variable every script reads no longer holds the login, and the one line that
# says so does not print it.
LE="$T/le"; mkdir -p "$LE"
cp "${REPO}/.env.example" "$LE/.env.example"
sed -ri 's/^(HARBOR_URL=|ARGOCD_SERVER=)/# \1/' "$LE/.env.example"
printf "HARBOR_URL='admin:%s@harbor.example:8443'\nARGOCD_SERVER='https://admin:%s@argocd.example'\n" "$SECRET" "$SECRET" > "$LE/.env"
# The child expands its own variables (SC2016 is deliberate).
# shellcheck disable=SC2016
le_out="$(env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG -u VKS_STATE_FILE REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" \
            bash -c '. "$1"; load_env; printf "H=[%s] A=[%s]\n" "$HARBOR_URL" "$ARGOCD_SERVER"' _ "$LIB_OS" 2>"$T/le.err")"
if [ "$le_out" = 'H=[harbor.example:8443] A=[https://argocd.example]' ]; then ok "load_env: a login in HARBOR_URL / ARGOCD_SERVER is taken out of the variable"
else bad "load_env: the login is still in the variable (or the value was damaged)" "${le_out//$SECRET/<THE SECRET>}"; fi
if [ "$(command grep -c 'held a login' "$T/le.err")" = 2 ] && command grep -q "HARBOR_URL held a login" "$T/le.err" \
   && command grep -q "read as 'harbor.example:8443'" "$T/le.err" && ! command grep -qF -- "$SECRET" "$T/le.err" && ! command grep -qF 'admin:' "$T/le.err"; then
  ok "load_env: says so once per variable, shows the value it now uses, and prints no part of the login"
else
  _printed=no; if command grep -qF -- "$SECRET" "$T/le.err"; then _printed=YES; fi
  _n="$(command grep 'held a login' "$T/le.err" | wc -l)"
  bad "load_env: the notice is missing, repeated, or prints the login" "${_n} notice(s); secret printed: ${_printed}"
fi
# THROUGH THE REAL load_env. A value that cannot be read STOPS THE SCRIPT there (it used to carry
# on with the variable emptied, and installers then took their "not set, skipped" arms and
# returned 0). One line says so, and neither the value nor any piece of it is printed.
le() {  # <value for HARBOR_URL> ; sets LE_OUT (stdout), LE_RC ; stderr in $T/le.err
  printf "HARBOR_URL='%s'\n" "$1" > "$LE/.env"
  # The child expands its own variables (SC2016 is deliberate).
  # shellcheck disable=SC2016
  LE_OUT="$(env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG -u _LOAD_ENV_ON_REFUSED_ADDRESS REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" \
              bash -c '. "$1"; load_env; printf "REACHED H=[%s]\n" "$HARBOR_URL"' _ "$LIB_OS" 2>"$T/le.err")"; LE_RC=$?
}
for bad_url in 'u:s3cr3t/must-not-appear@h.example' 'u:s3cr3t://must-not-appear@h.example' 'admin:4411/SEKR@harbor.example' \
               'ad:be/SEKR@harbor.example' 'admin:SEKR@4411/x@harbor.example' 'harbor.example/proj/img@sha256:0123abcd' \
               'admin:SEKR@' 'https://admin:SEKR@' 'https://admin:SEKR@/v2/'; do
  le "$bad_url"
  shown="${bad_url//s3cr3t*must-not-appear/…}"; shown="${shown//SEKR/…}"
  if [ "$LE_RC" = 1 ] && [ -z "$LE_OUT" ] && [ "$(command grep -c 'HARBOR_URL is set, and it cannot be used' "$T/le.err")" = 1 ] \
     && command grep -q 'takes a host and an optional port' "$T/le.err" \
     && ! command grep -qF -e 's3cr3t' -e 'must-not-appear' -e 'SEKR' -e '4411' -e 'h.example' -e 'harbor.example' -e 'sha256' -e 'admin' "$T/le.err"; then
    ok "load_env: ${shown} STOPS the script (rc 1, nothing after load_env runs), one line says why, and no part of the value is printed"
  else
    _leaked=no; if command grep -qF -e 's3cr3t' -e 'SEKR' -e '4411' "$T/le.err"; then _leaked=YES; fi
    _n="$(command grep 'cannot be used' "$T/le.err" | wc -l)"
    bad "load_env: an address that cannot be used did not stop the script, or the value was printed" "rc=${LE_RC} reached='${LE_OUT//SEKR/<S>}' notices=${_n} leaked=${_leaked}"
  fi
done
# A line in .env must not be able to turn the stop into "report and go on": the two settings
# load_env reads from the environment are read-only inside it, so such a line fails loudly.
for planted in '_refused_mode=report' '_bounds_reported_in=x'; do
  printf "%s\nHARBOR_URL='admin:4411/SEKR@harbor.example'\n" "$planted" > "$LE/.env"
  # shellcheck disable=SC2016
  LE_OUT="$(env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG -u _LOAD_ENV_ON_REFUSED_ADDRESS REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" \
              bash -c '. "$1"; load_env; printf "REACHED H=[%s]\n" "$HARBOR_URL"' _ "$LIB_OS" 2>"$T/le.err")"; LE_RC=$?
  if [ "$LE_RC" != 0 ] && [ -z "$LE_OUT" ] && command grep -q "${planted%%=*}: readonly variable" "$T/le.err" && ! command grep -qF 'SEKR' "$T/le.err"; then
    ok "load_env: a .env line '${planted}' cannot switch the stop off: rc ${LE_RC}, bash names the read-only variable, nothing after load_env runs"
  else
    _leaked=no; if command grep -qF 'SEKR' "$T/le.err"; then _leaked=YES; fi
    bad "load_env: a .env line '${planted}' was accepted" "rc=${LE_RC} reached='${LE_OUT//SEKR/<S>}' leaked=${_leaked}; $(tail -n 2 "$T/le.err" | tr '\n' ' ')"
  fi
done
# What MUST still pass: an ordinary login is taken out (at the LAST @ before the first /), and the
# notice prints nothing that came from before that @.
while IFS='|' read -r in want; do
  [ -n "$want" ] || continue
  le "$in"
  if [ "$LE_RC" = 0 ] && [ "$LE_OUT" = "REACHED H=[${want}]" ] && [ "$(command grep -c 'HARBOR_URL held a login' "$T/le.err")" = 1 ] \
     && ! command grep -qF -e 'SEKR' -e 'SE@' -e 'KR@' -e 'admin' "$T/le.err"; then
    ok "load_env: ${in//SEKR/…} -> ${want}, one notice, nothing from before the @ printed"
  else
    bad "load_env: an ordinary login was not stripped cleanly" "rc=${LE_RC} out='${LE_OUT//SEKR/<S>}' leaked=$(command grep -qF -e 'SEKR' -e 'admin' "$T/le.err" && echo YES || echo no)"
  fi
done <<'ROWS'
admin:SEKR@h.example|h.example
admin:SE@KR@h.example:8443|h.example:8443
https://admin:SEKR@[::1]:8443/x|https://[::1]:8443/x
ROWS
# AN INSTALLER DIES BEFORE IT DOES ANYTHING. 40-install-gitea.sh used to take "HARBOR_URL is not
# set" arms on an emptied variable. kubectl and helm here are stand-ins that only record a call.
INS="$T/ins"; mkdir -p "$INS/bin" "$INS/root"
cp "${REPO}/.env.example" "$INS/root/.env.example"
printf "HARBOR_URL='admin:4411/SEKR@harbor.example'\n" > "$INS/root/.env"
for tool in kubectl helm; do
  # The stub's own "$*" is written literally (SC2016 is deliberate).
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 1\n' "$tool" "$INS/calls.log" > "$INS/bin/$tool"; chmod +x "$INS/bin/$tool"
done
: > "$INS/calls.log"
ins_out="$(env -u HARBOR_URL -u KUBECONFIG -u _LOAD_ENV_ON_REFUSED_ADDRESS PATH="$INS/bin:$PATH" REPO_ROOT="$INS/root" VKS_STATE_FILE="$INS/root/.env.state" \
             timeout 60 bash "${REPO}/scripts/40-install-gitea.sh" 2>&1 </dev/null)"; ins_rc=$?
if [ "$ins_rc" != 0 ] && has "$ins_out" 'HARBOR_URL is set, and it cannot be used' && [ ! -s "$INS/calls.log" ] && ! has "$ins_out" 'SEKR' && ! has "$ins_out" '4411'; then
  ok "an installer (40-install-gitea.sh) with an unusable HARBOR_URL stops inside load_env: rc ${ins_rc}, no kubectl or helm call, the value not printed"
else
  bad "an installer carried on (or printed the value) with an address that cannot be used" "rc=${ins_rc}; cluster calls made: $(wc -l < "$INS/calls.log"); $(printf '%s' "${ins_out//SEKR/<S>}" | tail -1 | cut -c1-160)"
fi
# `h.example/r?u=https://evil.example`: nothing to strip, nothing to refuse, and the host is h.example.
printf "HARBOR_URL='h.example/r?u=https://evil.example'\n" > "$LE/.env"
# shellcheck disable=SC2016
le_out="$(env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" \
            bash -c '. "$1"; . "$2"; load_env; printf "H=[%s] host=[%s]\n" "$HARBOR_URL" "$(harbor_url_host)"' _ "$LIB_OS" "${REPO}/scripts/lib/harbor.sh" 2>"$T/le.err")"
if [ "$le_out" = 'H=[h.example/r?u=https://evil.example] host=[h.example]' ] && ! command grep -qE 'held a login|is not used' "$T/le.err"; then
  ok "load_env: a URL inside the query is not a scheme and not a login: the value is untouched and its host is h.example"
else bad "load_env: a URL inside the query changed the value or the host" "$le_out"; fi
# Control: an address with no login is left exactly alone, and nothing is said.
printf "HARBOR_URL=harbor.example:8443\n" > "$LE/.env"
# shellcheck disable=SC2016
le_out="$(env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" \
            bash -c '. "$1"; load_env; printf "H=[%s]\n" "$HARBOR_URL"' _ "$LIB_OS" 2>"$T/le.err")"
if [ "$le_out" = 'H=[harbor.example:8443]' ] && ! command grep -q 'held a login' "$T/le.err"; then ok "load_env: an address with no login is untouched and nothing is said (control)"
else bad "load_env: an ordinary address was changed or reported" "$le_out"; fi

# ══ 3. real listeners: 127.0.0.1 and ::1 ═════════════════════════════════════════════════════
( cd "$T" || exit 1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ss.key -out ss.crt -days 1 -subj '/CN=localhost' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' >/dev/null 2>&1 )
[ -s "$T/ss.crt" ] || { echo "test-url-host-port: INCONCLUSIVE — could not mint the test certificate"; exit 1; }
_free_port() {
  local p
  for p in $(seq 39443 39643); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && ! (exec 3<>"/dev/tcp/::1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
_serve() {  # <accept-spec> <probe-host> <port> ; rc 0 when OUR listener answers
  local i
  openssl s_server -accept "$1" -cert "$T/ss.crt" -key "$T/ss.key" -www -quiet >/dev/null 2>&1 &
  SERVED_PID=$!; PIDS="${PIDS}${SERVED_PID}"$'\n'
  for i in $(seq 1 40); do
    if (exec 3<>"/dev/tcp/$2/$3") 2>/dev/null; then sleep 0.25; kill -0 "$SERVED_PID" 2>/dev/null; return $?; fi
    sleep 0.25
  done
  : "$i"; return 1
}
P4="$(_free_port)" || { echo "test-url-host-port: INCONCLUSIVE — no free port"; exit 1; }
_serve "127.0.0.1:${P4}" 127.0.0.1 "$P4" || { echo "test-url-host-port: INCONCLUSIVE — the IPv4 listener did not start"; exit 1; }
status() {  # <HARBOR_URL> ; echoes the ca-status report for it
  ( set +e; unset VKS_CA_CERT_FILE SUPERVISOR_HOST CA_STATUS_STRICT
    HARBOR_URL="$1" HARBOR_CA_FILE="$T/ss.crt" CA_VERIFY_TIMEOUT=5 ca_status_report 2>&1 )
}
# A login in the address: the report reaches the server and prints no part of the login.
r="$(status "admin:${SECRET}@localhost:${P4}")"
if has "$r" "Harbor CA ($T/ss.crt) matches localhost" && ! has "$r" "$SECRET" && ! has "$r" 'admin:'; then
  ok "ca-status: an address with a login reaches the server, and the report prints no part of the login"
else bad "ca-status: the login broke the check or was printed" "$(printf '%s' "${r//$SECRET/<THE SECRET>}" | tail -2 | cut -c1-160)"; fi
f_out="$(CA_VERIFY_TIMEOUT=5 timeout -k 2 40 bash "${REPO}/scripts/fetch-ca.sh" "https://admin:${SECRET}@localhost:${P4}/" "$T/out.crt" harbor </dev/null 2>&1)"
if has "$f_out" "fetching the harbor CA from localhost:${P4}" && has "$f_out" 'single SELF-SIGNED certificate' && ! has "$f_out" "$SECRET" && ! has "$f_out" 'admin:'; then
  ok "fetch-ca.sh: an address with a login is fetched from the right host and port, and no part of the login is printed"
else bad "fetch-ca.sh: the login broke the fetch or was printed" "$(printf '%s' "${f_out//$SECRET/<THE SECRET>}" | head -2 | cut -c1-160)"; fi

# The fetch refuses the unreadable shapes too (it takes its address as an argument, not from
# load_env), before it dials anything, and prints no part of the value.
f_out="$(timeout -k 2 20 bash "${REPO}/scripts/fetch-ca.sh" 'u:s3cr3t/must-not-appear@localhost' "$T/out-unreadable.crt" harbor </dev/null 2>&1)"; f_rc=$?
if [ "$f_rc" = 1 ] && has "$f_out" 'the harbor address cannot be used' && ! has "$f_out" 's3cr3t' && ! has "$f_out" 'must-not-appear' && ! has "$f_out" 'fetching the' && [ ! -e "$T/out-unreadable.crt" ]; then
  ok "fetch-ca.sh: an address whose login cannot be read out is refused before any dial, and no part of it is printed"
else bad "fetch-ca.sh: an unreadable login was dialled or printed" "rc=${f_rc}: $(printf '%s' "${f_out//s3cr3t/<THE SECRET>}" | head -2 | cut -c1-160)"; fi
f_out="$(timeout -k 2 20 bash "${REPO}/scripts/fetch-ca.sh" 'admin:4411/SEKR@localhost' "$T/out-unreadable2.crt" harbor </dev/null 2>&1)"; f_rc=$?
if [ "$f_rc" = 1 ] && has "$f_out" 'the harbor address cannot be used' && ! has "$f_out" 'SEKR' && ! has "$f_out" '4411' && ! has "$f_out" 'fetching the' && [ ! -e "$T/out-unreadable2.crt" ]; then
  ok "fetch-ca.sh: admin:4411/…@host (a front that looks like host:port) is refused before any dial, nothing of it printed"
else bad "fetch-ca.sh: a login with a host:port-looking front was dialled or printed" "rc=${f_rc}: $(printf '%s' "${f_out//SEKR/<S>}" | head -2 | cut -c1-160)"; fi

# THE ADDRESS NEVER RIDES ON A COMMAND LINE THROUGH make. The two fetch recipes pasted it into the
# recipe (`fetch-ca.sh "$(HARBOR_URL)" …`), so it was in the argv of the recipe's shell and of the
# script for the whole handshake: `ps` shows that to every user, and make read the value from .env
# itself, so load_env's removal of a login never ran. It goes in the environment now.
# A stub stands in for the script and records its arguments and what the environment held; the
# Makefile is the real one, in a sandbox directory whose .env carries a login in both addresses.
if command -v make >/dev/null 2>&1; then
  MKS="$T/mk"; mkdir -p "$MKS/stub" "$MKS/sb"
  # The stub's own "$*" is written literally (SC2016 is deliberate).
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "ARGV=[%%s]\nENDPOINT=[%%s]\n" "$*" "${_FETCH_CA_ENDPOINT-UNSET}"\n' > "$MKS/stub/fetch-ca.sh"
  chmod +x "$MKS/stub/fetch-ca.sh"
  printf "HARBOR_URL='admin:%s@harbor.example:8443'\nARGOCD_SERVER=\"admin:%s@argocd.example\"   # the server\n" "$SECRET" "$SECRET" > "$MKS/sb/.env"
  mkrun() {  # <target> [-n] ; real Makefile, sandbox cwd
    env -u HARBOR_URL -u ARGOCD_SERVER -u ARGOCD_LB_IP -u _FETCH_CA_ENDPOINT -u SKIP_DOTENV -u MAKEFLAGS -u MAKELEVEL -u MFLAGS \
      make --no-print-directory -f "${REPO}/Makefile" -C "$MKS/sb" "$@" SCRIPTS="$MKS/stub" HARBOR_CA_FILE="$MKS/h.crt" ARGOCD_CA_FILE="$MKS/a.crt" 2>&1 </dev/null
  }
  for row in "fetch-harbor-ca|harbor|admin:${SECRET}@harbor.example:8443|$MKS/h.crt" "fetch-argocd-ca|argocd|admin:${SECRET}@argocd.example|$MKS/a.crt"; do
    IFS='|' read -r tgt label ep out <<< "$row"
    m_out="$(mkrun "$tgt")"
    if [ "$(command grep '^ARGV=' <<< "$m_out")" = "ARGV=[- ${out} ${label}]" ] && [ "$(command grep '^ENDPOINT=' <<< "$m_out")" = "ENDPOINT=[${ep}]" ]; then
      ok "make ${tgt}: the script's arguments are '- <file> ${label}' and carry no address; the address arrives in the environment, unquoted and uncommented"
    else
      bad "make ${tgt}: the address is on the script's command line (or did not arrive at all)" "$(printf '%s' "${m_out//$SECRET/<THE SECRET>}" | command grep -E '^(ARGV|ENDPOINT)=' | tr '\n' ' ' | cut -c1-200)"
    fi
    # ...and not in the recipe either: `make -n` prints the text the recipe's shell is handed.
    n_out="$(mkrun "$tgt" -n)"
    if [ -n "$n_out" ] && has "$n_out" 'fetch-ca.sh - ' && ! has "$n_out" "$SECRET" && ! has "$n_out" 'admin:'; then
      ok "make ${tgt}: the recipe text (what the recipe's shell gets as its own command line) holds no address"
    else
      bad "make ${tgt}: the address is pasted into the recipe" "$(printf '%s' "${n_out//$SECRET/<THE SECRET>}" | head -2 | cut -c1-200)"
    fi
  done
  # Through the REAL script: it reads the endpoint from the environment, strips the login, dials
  # the right server, and prints no part of the login.
  printf "HARBOR_URL='admin:%s@localhost:%s'\n" "$SECRET" "$P4" > "$MKS/sb/.env"
  r_out="$(env -u HARBOR_URL -u _FETCH_CA_ENDPOINT -u HARBOR_CA_SHA256 -u CA_VERIFY_TIMEOUT -u SKIP_DOTENV -u MAKEFLAGS -u MAKELEVEL -u MFLAGS \
             timeout -k 2 40 make --no-print-directory -f "${REPO}/Makefile" -C "$MKS/sb" fetch-harbor-ca SCRIPTS="${REPO}/scripts" HARBOR_CA_FILE="$MKS/real.crt" CA_VERIFY_TIMEOUT=5 2>&1 </dev/null)"
  if has "$r_out" "fetching the harbor CA from localhost:${P4}" && has "$r_out" 'single SELF-SIGNED certificate' && ! has "$r_out" "$SECRET" && ! has "$r_out" 'admin:'; then
    ok "make fetch-harbor-ca, real script: the address from the environment is dialled without its login, and no part of the login is printed"
  else
    bad "make fetch-harbor-ca, real script: the environment endpoint was not used, or the login was printed" "$(printf '%s' "${r_out//$SECRET/<THE SECRET>}" | head -2 | cut -c1-200)"
  fi
  # `-` with nothing in the environment says so, and a positional address still works by hand.
  e_out="$(env -u _FETCH_CA_ENDPOINT timeout 20 bash "${REPO}/scripts/fetch-ca.sh" - "$T/out-none.crt" harbor </dev/null 2>&1)"; e_rc=$?
  if [ "$e_rc" = 1 ] && has "$e_out" 'reads it from _FETCH_CA_ENDPOINT, and that is empty'; then ok "fetch-ca.sh: '-' with an empty _FETCH_CA_ENDPOINT stops and says which variable it reads"
  else bad "fetch-ca.sh: '-' with no endpoint in the environment" "rc=${e_rc}: $(printf '%s' "$e_out" | tail -1 | cut -c1-160)"; fi
else
  printf 'SKIP  make is not installed: cannot check what the fetch recipes put on a command line\n'
fi

if (exec 3<>"/dev/tcp/::1/1") 2>/dev/null || [ -e /proc/sys/net/ipv6/conf/lo/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null)" = 0 ]; then
  P6="$(_free_port)" || { echo "test-url-host-port: INCONCLUSIVE — no free port for ::1"; exit 1; }
  if _serve "[::1]:${P6}" ::1 "$P6"; then
    r=0; CA_VERIFY_TIMEOUT=5 ca_verifies_endpoint ::1 "$P6" "$T/ss.crt" || r=$?
    if [ "$r" = 0 ]; then ok "ca_verifies_endpoint: the address ::1 verifies against a certificate carrying IP:::1 (dialled as [::1]:port, checked as an IP)"
    else bad "ca_verifies_endpoint: an IPv6 literal does not verify" "rc=${r} (2 = it never connected: the brackets are missing from the dial)"; fi
    r="$(status "[::1]:${P6}")"
    if has "$r" "Harbor CA ($T/ss.crt) matches ::1"; then ok "ca-status: HARBOR_URL=[::1]:port reaches the listener and matches"
    else bad "ca-status: a bracketed IPv6 address is mis-read" "$(printf '%s' "$r" | tail -2 | cut -c1-160)"; fi
    r="$(status "https://[::1]:${P6}/harbor")"
    if has "$r" "Harbor CA ($T/ss.crt) matches ::1"; then ok "ca-status: with a scheme and a path around it, the same"
    else bad "ca-status: scheme + bracketed IPv6 + path is mis-read" "$(printf '%s' "$r" | tail -2 | cut -c1-160)"; fi
    # A bare ::1 is port 443, where nothing listens here: the report must SAY which port it tried.
    r="$(status '::1')"
    if has "$r" 'Harbor CA: [::1]:443 did not answer'; then ok "ca-status: a bare ::1 is tried on port 443 and shown as [::1]:443"
    else bad "ca-status: a bare IPv6 literal is not shown as [::1]:443" "$(printf '%s' "$r" | head -1 | cut -c1-160)"; fi
    f_out="$(CA_VERIFY_TIMEOUT=5 timeout -k 2 40 bash "${REPO}/scripts/fetch-ca.sh" "[::1]:${P6}" "$T/out6.crt" harbor </dev/null 2>&1)"; f_rc=$?
    if has "$f_out" "fetching the harbor CA from [::1]:${P6}" && has "$f_out" 'single SELF-SIGNED certificate' && has "$f_out" 'CA SHA-256:' && [ ! -e "$T/out6.crt" ]; then
      ok "fetch-ca.sh: [::1]:port is fetched, passes the address check (an IP SAN) and stops only at the unconfirmed-fingerprint refusal"
    else bad "fetch-ca.sh: a bracketed IPv6 endpoint is mis-read" "rc=${f_rc}: $(printf '%s' "$f_out" | tail -3 | cut -c1-160 | tr '\n' ' ')"; fi
    if tls_port_accepts ::1 "$P6" 5 && ! tls_port_accepts ::1 "$P4" 5; then ok "tls_port_accepts: ::1 on the listening port yes, on another port no"
    else bad "tls_port_accepts: an IPv6 literal"; fi
  else
    printf 'SKIP  could not start a listener on ::1: the IPv6 cases against a real server did not run\n'
  fi
else
  printf 'SKIP  no IPv6 loopback on this machine: the IPv6 cases against a real server did not run\n'
fi

printf '\ntest-url-host-port: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-url-host-port: OK\n'
