#!/usr/bin/env bash
# ci-tier: fast — OFFLINE. Real certificates + `openssl s_server` on 127.0.0.1. No lab, no login.
#
# test-harbor-ca-refetch-advice.sh — a message that says "your Harbor CA is a leftover, get it
# again" must name a command that can WORK on the Harbor it is talking about.
#
# THE DEFECT. `make lab-preflight` on a rebuilt lab said "Get it again: make fetch-harbor-ca".
# That Harbor sends ONE certificate, signed by a CA it does not send, so the command it named
# refused ("presents ONE certificate that is NOT self-signed") and named the two routes that do
# work. The reader lost a step. `make env-validate` and `make creds` gave the same advice.
#
# WHAT IS PINNED, at each of the three places that print it (ca_status_report, which is
# `make ca-status` and `make lab-preflight`; `make env-validate`; `make creds`):
#   self-signed   Harbor sends one certificate that is its own issuer -> make fetch-harbor-ca
#   leaf-only     one certificate, issued by something not sent       -> the UI route (fingerprint
#                 the DOWNLOAD, confirm, only then save), then "ask the operator", then
#                 make harbor-ca-from-cluster, then make ca-status; NOT "re-fetch it"
#   chain-incomplete  several certificates, and the last one does not verify the server's own by
#                 itself (leaf + intermediate; leaf + intermediate + root) -> the same routes
#   unknown       the question could not be answered                  -> the text it always had
#   dates         the CA is RIGHT and the served certificate is expired or not valid yet
#                                                                      -> the dates, never "re-fetch"
# plus tls_ca_on_the_wire itself (the one implementation the three share with fetch-ca.sh), and
# fetch-ca.sh's own verdict on each of those listeners. That pins agreement on THESE shapes. It is
# not a proof that the advice and the fetch can never disagree: the round before this one called
# every multi-certificate answer "chain" and named the fetch on a server it refuses, with this
# header claiming they could not disagree. A shape with no listener here is not covered.
#
# AND THE MESSAGES THAT DO NOT ASK (section 6): with no CA file, an empty one or an unreadable
# one, nothing has dialled Harbor, so `make fetch-harbor-ca` is named as an ATTEMPT together with
# what to do when it refuses. Six places print that hedge.
#
# HOW "unknown" IS PRODUCED. The CA check has to say "does NOT verify" (the endpoint answered)
# while the second handshake gets nothing. A wrapper `openssl` first on PATH fails ONLY the
# `-showcerts` handshake and passes everything else to the real one: the server is up, the
# question goes unanswered. A dead port would not do — the CA check would then abstain and this
# arm would never be reached.
#
# HOW "accepts and never answers" IS PRODUCED. An `openssl s_server` that is then sent SIGSTOP:
# the kernel still completes the TCP handshake from the listen queue, and nothing ever replies.
# A second wrapper sends ONLY the `-showcerts` handshake there, so the CA check still gets its
# answer from the live server and the wire question hangs until its bound cuts it off.
#
# DOES NOT PROVE: that a real Supervisor-Service Harbor sends one certificate (measured on a lab,
# recorded in 27-harbor-ca-from-cluster.sh), that the Harbor UI has the button the text names, or
# that the two routes work there. It proves the sentence follows the shape of what the server sends.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$REPO_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl is not installed"; exit 0; }
REAL_OPENSSL="$(command -v openssl)"

LIB_OS="${REPO}/scripts/lib/os.sh"
LIB_TLS="${REPO}/scripts/lib/tls.sh"
# shellcheck source=scripts/lib/os.sh
. "$LIB_OS"
# shellcheck source=scripts/lib/tls.sh
. "$LIB_TLS"

T="$(mktemp -d)"
PIDS=""
cleanup() {
  local p
  # KILL, not TERM: one listener is STOPPED on purpose and a stopped process ignores TERM.
  while read -r p; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done <<< "$PIDS"
  rm -rf "$T"
}
trap cleanup EXIT

# ── certificates ─────────────────────────────────────────────────────────────────────────────
# ss.*     a SELF-SIGNED server certificate (the KinD stand-in's shape)
# ca.*     a private CA;  leaf.*  a certificate it issues (the Supervisor-Service Harbor's shape)
# old.crt  an unrelated, well-formed CA: the "leftover from the lab before the rebuild"
( cd "$T" || exit 1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > ext.cnf
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ss.key -out ss.crt -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 \
    -subj '/CN=Harbor CA' >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
    -subj '/CN=localhost' >/dev/null 2>&1
  openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out leaf.crt -days 1 -extfile ext.cnf >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout old.key -out old.crt -days 1 \
    -subj '/CN=the-lab-before-the-rebuild' >/dev/null 2>&1
  printf 'this is not a certificate\n' > garbage.crt
  # An INTERMEDIATE under ca.crt, and a server certificate it issues: the "corporate" shape.
  printf 'basicConstraints=critical,CA:TRUE\n' > inter.cnf
  openssl req -newkey rsa:2048 -nodes -keyout inter.key -out inter.csr -subj '/CN=Harbor Intermediate' >/dev/null 2>&1
  openssl x509 -req -in inter.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out inter.crt -days 1 \
    -extfile inter.cnf >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout leaf2.key -out leaf2.csr -subj '/CN=localhost' >/dev/null 2>&1
  openssl x509 -req -in leaf2.csr -CA inter.crt -CAkey inter.key -CAcreateserial -out leaf2.crt -days 1 \
    -extfile ext.cnf >/dev/null 2>&1
  cat inter.crt ca.crt > inter-and-root.crt
  # Two certificates ca.crt issues with DATES that are wrong today: one long expired, one not
  # valid for years. `openssl ca` is the form that sets both dates on every OpenSSL 3.x.
  mkdir -p db; : > db/index.txt; echo 01 > db/serial
  cat > ca.cnf <<CNF
[ ca ]
default_ca = d
[ d ]
dir = $T/db
database = $T/db/index.txt
new_certs_dir = $T/db
serial = $T/db/serial
default_md = sha256
policy = p
copy_extensions = copy
unique_subject = no
[ p ]
commonName = supplied
CNF
  y="$(date -u +%Y)"
  for row in "expired|20200101000000Z|20200102000000Z" "notyet|$((y + 5))0101000000Z|$((y + 6))0101000000Z"; do
    n="${row%%|*}"; rest="${row#*|}"
    openssl req -new -newkey rsa:2048 -nodes -keyout "$n.key" -out "$n.csr" -subj '/CN=localhost' \
      -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
    openssl ca -batch -notext -config ca.cnf -cert ca.crt -keyfile ca.key -in "$n.csr" -out "$n.crt" \
      -startdate "${rest%%|*}" -enddate "${rest##*|}" >/dev/null 2>&1
  done )
for f in ss.crt ss.key ca.crt leaf.crt leaf.key old.crt garbage.crt inter.crt leaf2.crt inter-and-root.crt expired.crt notyet.crt; do
  [ -s "$T/$f" ] || { echo "fixture $f missing — aborting rather than testing nothing"; exit 1; }
done

# ── listeners ────────────────────────────────────────────────────────────────────────────────
_next_port=35443
_free_port() {   # prints a port nothing is listening on (a connect that FAILS means free)
  local p
  for p in $(seq "$_next_port" $((_next_port + 200))); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
# ⚠️ "A CONNECT SUCCEEDED" IS NOT "OUR LISTENER IS UP". If something else takes the port between
# _free_port and the bind, our s_server exits and the stranger answers the connect: every
# assertion after that would be about someone else's certificate. So the connect counts only
# while OUR process is still alive. SERVE_ON forces a port, for the self-test of exactly that.
_serve() {  # <cert> <key> [chain-file] ; sets SERVED_PORT and SERVED_PID, or returns 1
  local p i
  if [ -n "${SERVE_ON:-}" ]; then p="$SERVE_ON"; else p="$(_free_port)" || return 1; _next_port=$((p + 1)); fi
  openssl s_server -accept "$p" -cert "$1" -key "$2" ${3:+-cert_chain "$3"} -www -quiet >/dev/null 2>&1 &
  SERVED_PID=$!
  PIDS="${PIDS}${SERVED_PID}"$'\n'
  for i in $(seq 1 40); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      sleep 0.25                                   # a bind that failed needs a moment to exit
      if kill -0 "$SERVED_PID" 2>/dev/null; then SERVED_PORT="$p"; return 0; fi
      return 1
    fi
    sleep 0.25
  done
  : "$i"
  return 1
}
SERVED_PORT=""; SERVED_PID=""
_serve "$T/ss.crt"   "$T/ss.key"             || { echo "SKIP: s_server did not start (self-signed)"; exit 0; }
P_SS="$SERVED_PORT"
_serve "$T/leaf.crt" "$T/leaf.key"           || { echo "SKIP: s_server did not start (leaf only)"; exit 0; }
P_LEAF="$SERVED_PORT"
_serve "$T/leaf.crt" "$T/leaf.key" "$T/ca.crt" || { echo "SKIP: s_server did not start (chain)"; exit 0; }
P_CHAIN="$SERVED_PORT"
_serve "$T/leaf2.crt" "$T/leaf2.key" "$T/inter.crt" || { echo "SKIP: s_server did not start (leaf + intermediate)"; exit 0; }
P_INTER="$SERVED_PORT"
_serve "$T/leaf2.crt" "$T/leaf2.key" "$T/inter-and-root.crt" || { echo "SKIP: s_server did not start (leaf + intermediate + root)"; exit 0; }
P_FULL="$SERVED_PORT"
_serve "$T/expired.crt" "$T/expired.key"     || { echo "SKIP: s_server did not start (expired)"; exit 0; }
P_EXP="$SERVED_PORT"
_serve "$T/notyet.crt" "$T/notyet.key"       || { echo "SKIP: s_server did not start (not valid yet)"; exit 0; }
P_NY="$SERVED_PORT"
# The one that accepts and never answers: started like the others, then STOPPED.
_serve "$T/ss.crt"   "$T/ss.key"             || { echo "SKIP: s_server did not start (silent)"; exit 0; }
P_SILENT="$SERVED_PORT"
kill -STOP "$SERVED_PID" 2>/dev/null || { echo "SKIP: could not stop the silent listener"; exit 0; }
P_DEAD="$(_free_port)" || { echo "SKIP: no free port for the dead endpoint"; exit 0; }

# ── the two wrappers ─────────────────────────────────────────────────────────────────────────
mkdir -p "$T/noshow" "$T/hang"
# The stubs' own "$@" is written literally into the generated scripts (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-showcerts" ] && exit 1; done\nexec %s "$@"\n' "$REAL_OPENSSL" \
  > "$T/noshow/openssl"
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-showcerts" ] && exec %s s_client -connect 127.0.0.1:%s -showcerts; done\nexec %s "$@"\n' \
  "$REAL_OPENSSL" "$P_SILENT" "$REAL_OPENSSL" > "$T/hang/openssl"
chmod +x "$T/noshow/openssl" "$T/hang/openssl"

has()  { command grep -qF -- "$2" <<< "$1"; }
# strip <line> — drop a log prefix (`… msg=`) and leading spaces, so a line can be compared whole.
strip() { sed -e 's/^.* msg=//' -e 's/^[[:space:]]*//' <<< "$1"; }
# line_after <text> <marker> — the line FOLLOWING the first line that contains <marker>, stripped.
line_after() { strip "$(command grep -A1 -F -- "$2" <<< "$1" | sed -n 2p)"; }
# before <text> <first> <second> — true when <first> appears on an EARLIER line than <second>.
before() {
  local a b
  a="$(command grep -nF -- "$2" <<< "$1" | head -1 | cut -d: -f1)"
  b="$(command grep -nF -- "$3" <<< "$1" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# The phrases every leaf-only assertion keys on.
NOT_WIRE='make fetch-harbor-ca cannot get the new one'
UI='from the Harbor UI: your project, Repositories tab, Registry Certificate'
NO_BUTTON='if the button is not there, use the next route'
FP_DL='openssl x509 -in ~/Downloads/ca.crt -noout -fingerprint -sha256'
CONFIRM='confirm that SHA-256 with whoever operates Harbor, over another channel'
SAVE='only then save the file as:'
RECIPE='More detail: docs/scenario-1.md Step 8.'
ASK='or ask whoever operates Harbor to send you the CA file, then do steps 1 to 3'
ADMIN='if you are the lab admin'
LEAF_WHY='sends only its own'
CHAIN_WHY='does not verify its own certificate by itself'
DATES='What fails is that certificate'"'"'s validity period on this machine:'
CLUSTER='make harbor-ca-from-cluster'
CHECK='Then check it:  make ca-status'
HEDGE1='Try  make fetch-harbor-ca  — it works only when the issuing CA is sent by the server.'
HEDGE2='If it says the CA is not sent: see docs/scenario-1.md Step 8, or as the lab admin'
HEDGE3='  make harbor-ca-from-cluster'

# assert_leaf_only <site> <text> <file-it-must-name> <cluster-command-it-must-print> [why-sentence]
# (the name is from the first shape it covered; it also judges chain-incomplete, with its sentence)
assert_leaf_only() {
  local s="$1" t="$2" file="$3" cmd="$4" why="${5:-$LEAF_WHY}" p miss=""
  for p in "$NOT_WIRE" "$why" "$UI" "$NO_BUTTON" "$FP_DL" "$CONFIRM" "$SAVE" "$RECIPE" "$ASK" "$ADMIN" "$CLUSTER" "$CHECK"; do
    has "$t" "$p" || miss="${miss} [${p}]"
  done
  if [ -z "$miss" ]; then
    ok "${s} / leaf-only: says fetch-harbor-ca cannot get it and why; gives the UI route, ask-the-operator, the admin route and the ca-status check"
  else
    bad "${s} / leaf-only: part of the advice is missing" "missing:${miss}"
  fi
  # THE ORDER IS THE POINT: the downloaded file is fingerprinted and confirmed BEFORE it is saved
  # where every consumer trusts it.
  if before "$t" "$UI" "$FP_DL" && before "$t" "$FP_DL" "$CONFIRM" && before "$t" "$CONFIRM" "$SAVE" \
     && before "$t" "$SAVE" "$ASK" && before "$t" "$ASK" "$ADMIN" && before "$t" "$ADMIN" "$CHECK"; then
    ok "${s} / leaf-only: fingerprint the download, confirm, only then save; UI, then ask the operator, then the admin route; ca-status last"
  else
    bad "${s} / leaf-only: the steps are out of order" "saving before confirming means trusting an unconfirmed file"
  fi
  if [ "$(line_after "$t" "$SAVE")" = "$file" ]; then
    ok "${s} / leaf-only: the file to save it as is the real one (${file##*/})"
  else
    bad "${s} / leaf-only: the save-as line does not carry the real file" "wanted '${file}', got '$(line_after "$t" "$SAVE")'"
  fi
  if has "$t" "openssl x509 -in ${file} "; then
    bad "${s} / leaf-only: the fingerprint command names the LIVE file" "it must name the download, which is not trusted yet"
  else
    ok "${s} / leaf-only: the fingerprint command names the download, not the live file"
  fi
  if [ "$(line_after "$t" "$ADMIN")" = "$cmd" ]; then
    ok "${s} / leaf-only: the admin route names the file that was judged (HARBOR_CA_FILE=${file##*/})"
  else
    bad "${s} / leaf-only: the admin route's command is wrong" "wanted '${cmd}', got '$(line_after "$t" "$ADMIN")'"
  fi
}
# assert_present_wording <site> <case> <text> <the-line-it-always-printed>
assert_present_wording() {
  local s="$1" c="$2" t="$3" old="$4"
  if has "$t" "$old" && ! has "$t" "$NOT_WIRE" && ! has "$t" "$CLUSTER"; then
    ok "${s} / ${c}: names make fetch-harbor-ca, in the wording it always had"
  else
    bad "${s} / ${c}: expected the unchanged wording and no new claim" "$(printf '%s' "$t" | tail -12)"
  fi
}
# assert_hedge <site> <text> <phrase-that-proves-the-arm-was-reached> [forbidden-old-phrase]
assert_hedge() {
  local s="$1" t="$2" arm="$3" old="${4:-}"
  if ! has "$t" "$arm"; then
    bad "${s}: the fixture did not reach the message under test" "wanted a line containing: ${arm}"
    return
  fi
  if has "$t" "$HEDGE1" && has "$t" "$HEDGE2" && [ "$(line_after "$t" "$HEDGE2")" = "$(strip "$HEDGE3")" ] \
     && { [ -z "$old" ] || ! has "$t" "$old"; }; then
    ok "${s}: names make fetch-harbor-ca as an attempt, with what to do when it refuses"
  else
    bad "${s}: still prescribes make fetch-harbor-ca with no way on when it refuses" "$(command grep -F -A3 -- "$arm" <<< "$t" | cut -c1-200)"
  fi
}

# assert_dates <site> <text> <year-the-certificate's-dates-must-show>
# The CA is right and the certificate's dates are not. The message must show the dates and this
# machine's clock, and must NOT send the reader for another CA.
assert_dates() {
  local s="$1" t="$2" year="$3" bad_p="" p
  for p in 'leftover certificate' 'DIFFERENT (usually a' 're-fetch it' 'Re-fetch it' 'Get it again' "$NOT_WIRE" "$CLUSTER"; do
    has "$t" "$p" && bad_p="${bad_p} [${p}]"
  done
  if has "$t" "$DATES" && has "$t" 'Do NOT replace the CA file.' && [ -z "$bad_p" ]; then
    ok "${s} / dates: says the CA is right and the certificate's dates are not; does not send the reader for another CA"
  else
    bad "${s} / dates: the stale-CA advice is printed over a certificate whose only fault is its dates" "has dates text: $(has "$t" "$DATES" && echo yes || echo no); forbidden:${bad_p:- none}"
  fi
  if command grep -F 'valid until:' <<< "$t" | command grep -qF -- "$year" \
     && command grep -F 'valid from:' <<< "$t" | command grep -qE '[0-9]{4} GMT' \
     && command grep -F '(date -u):' <<< "$t" | command grep -qF -- "$(date -u +%Y)"; then
    ok "${s} / dates: shows the certificate's two dates and this machine's UTC clock"
  else
    bad "${s} / dates: the dates or the clock are missing" "$(command grep -F -e 'valid ' -e 'date -u' <<< "$t" | cut -c1-120)"
  fi
}

# ══ 0. the instrument: a listener only counts while it is OURS ═══════════════════════════════
# P_SS is taken (by our own first listener). A second s_server told to use it cannot bind and
# exits; a connect to that port still succeeds. _serve must say NO.
if SERVE_ON="$P_SS" _serve "$T/leaf.crt" "$T/leaf.key"; then
  bad "_serve: reported a listener that never bound" "a stranger on the port would stand in for the listener under test"
else
  ok "_serve: a port someone else holds is not taken for our listener"
fi

# ══ 1. the ONE classifier ════════════════════════════════════════════════════════════════════
for row in "self-signed|$P_SS" "leaf-only|$P_LEAF" "chain|$P_CHAIN" "chain-incomplete|$P_INTER" "chain-incomplete|$P_FULL" "unknown|$P_DEAD"; do
  want="${row%%|*}"; port="${row##*|}"
  got="$(tls_ca_on_the_wire localhost "$port" 5)"
  if [ "$got" = "$want" ]; then ok "tls_ca_on_the_wire: ${want} (port ${port})"
  else bad "tls_ca_on_the_wire: ${want} (port ${port})" "got '${got}'"; fi
done
got="$(PATH="$T/noshow:$PATH" tls_ca_on_the_wire localhost "$P_LEAF" 5)"
if [ "$got" = unknown ]; then ok "tls_ca_on_the_wire: a handshake that fails is 'unknown', not a verdict"
else bad "tls_ca_on_the_wire: a failed handshake must be 'unknown'" "got '${got}'"; fi
# Run in a child under its own 30 s guard: if the bound is ever lost, this is a FAIL, not a hung suite.
t0=$SECONDS
# The child expands its own "$1".."$3" (SC2016 is deliberate).
# shellcheck disable=SC2016
got="$(timeout -k 2 30 bash -c '. "$1"; . "$2"; tls_ca_on_the_wire 127.0.0.1 "$3" 2' _ "$LIB_OS" "$LIB_TLS" "$P_SILENT" 2>/dev/null)"
el=$((SECONDS - t0))
if [ "$got" = unknown ] && [ "$el" -ge 1 ] && [ "$el" -le 6 ]; then
  ok "tls_ca_on_the_wire: a listener that accepts and never answers is 'unknown' at its bound (${el}s for a 2s bound)"
else
  bad "tls_ca_on_the_wire: a silent listener must be 'unknown' at its bound" "got '${got}' after ${el}s (under 1s means the listener was not silent)"
fi

# A bound of 0 is NO bound to `timeout`. It must fall back to CA_VERIFY_TIMEOUT (2 s here).
t0=$SECONDS
# shellcheck disable=SC2016
got="$(CA_VERIFY_TIMEOUT=2 timeout -k 2 30 bash -c '. "$1"; . "$2"; tls_ca_on_the_wire 127.0.0.1 "$3" 0' _ "$LIB_OS" "$LIB_TLS" "$P_SILENT" 2>/dev/null)"
el=$((SECONDS - t0))
if [ "$got" = unknown ] && [ "$el" -ge 1 ] && [ "$el" -le 6 ]; then
  ok "tls_ca_on_the_wire: a bound of 0 is replaced by the default bound (${el}s, CA_VERIFY_TIMEOUT=2)"
else
  bad "tls_ca_on_the_wire: a bound of 0 switched the bound off" "got '${got}' after ${el}s"
fi
# The second check: dates only. Right CA + expired, right CA + not valid yet, and the control
# (a WRONG CA is not "dates").
for row in "0|$P_EXP|$T/ca.crt|an expired certificate under the right CA" "0|$P_NY|$T/ca.crt|a not-yet-valid certificate under the right CA" "1|$P_LEAF|$T/old.crt|a valid certificate under the WRONG CA (control)"; do
  IFS='|' read -r want port ca what <<< "$row"
  r=0; CA_VERIFY_TIMEOUT=5 ca_endpoint_dates_only localhost "$port" "$ca" || r=$?
  if [ "$r" = "$want" ]; then ok "ca_endpoint_dates_only: ${what} -> ${r}"
  else bad "ca_endpoint_dates_only: ${what}" "wanted ${want}, got ${r}"; fi
done

# ══ 2. fetch-ca.sh gives the SAME verdict on the same two servers ════════════════════════════
# The advice and the fetch share tls_presented_shape. If they ever stop sharing it, the advice
# can name a command the fetch refuses: that is the defect, so pin the fetch's side too.
fetch_out="$(bash "${REPO}/scripts/fetch-ca.sh" "localhost:${P_LEAF}" "$T/out-leaf.crt" harbor </dev/null 2>&1)"; fetch_rc=$?
if [ "$fetch_rc" -ne 0 ] && has "$fetch_out" 'presents ONE certificate that is NOT self-signed' && [ ! -e "$T/out-leaf.crt" ]; then
  ok "fetch-ca.sh: refuses the leaf-only server and writes nothing"
else
  bad "fetch-ca.sh: must refuse the leaf-only server" "rc=${fetch_rc}: $(printf '%s' "$fetch_out" | head -3)"
fi
fetch_out="$(bash "${REPO}/scripts/fetch-ca.sh" "localhost:${P_SS}" "$T/out-ss.crt" harbor </dev/null 2>&1)"; fetch_rc=$?
if has "$fetch_out" 'single SELF-SIGNED certificate' && ! has "$fetch_out" 'presents ONE certificate that is NOT self-signed'; then
  ok "fetch-ca.sh: takes the self-signed server's certificate as its own CA (control)"
else
  bad "fetch-ca.sh: must accept the self-signed server as its own CA" "rc=${fetch_rc}: $(printf '%s' "$fetch_out" | head -3)"
fi

for row in "$P_INTER|leaf + intermediate" "$P_FULL|leaf + intermediate + root"; do
  fetch_out="$(bash "${REPO}/scripts/fetch-ca.sh" "localhost:${row%%|*}" "$T/out-chain.crt" harbor </dev/null 2>&1)"; fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ] && has "$fetch_out" 'does NOT verify' && [ ! -e "$T/out-chain.crt" ]; then
    ok "fetch-ca.sh: refuses ${row##*|} and writes nothing (so the advice must not name it bare)"
  else
    bad "fetch-ca.sh: was expected to refuse ${row##*|}" "rc=${fetch_rc}: $(printf '%s' "$fetch_out" | tail -3 | cut -c1-160)"
  fi
done

# ══ 3. the wording itself: which file the admin route names ══════════════════════════════════
# `make harbor-ca-from-cluster` writes to make's HARBOR_CA_FILE. Told about one file and handed a
# command that writes another, the reader fixes the wrong file.
adv="$(harbor_ca_not_on_wire_advice ./secrets/harbor-ca.crt harbor.example)"
if [ "$(line_after "$adv" "$ADMIN")" = "$CLUSTER HARBOR_CA_FILE=./secrets/harbor-ca.crt" ]; then ok "advice: the default file is named too (an override can BE the default while .env names another)"
else bad "advice: the default file must be named on the command" "got '$(line_after "$adv" "$ADMIN")'"; fi
# THE PRINTED LINE IS PASTED INTO A SHELL, READ BY make, AND RE-READ BY THE RECIPE'S SHELL. So it is
# run that way here: paste -> `make -n` (prints the recipe, runs nothing) -> the recipe line with
# the script swapped for printf. What comes out must be the path that went in.
if command -v make >/dev/null 2>&1; then
  # The third path holds literal `$` on purpose (SC2016 is deliberate).
  # shellcheck disable=SC2016
  for path in /srv/other/ca.crt '/srv/my lab/ca.crt' '/srv/pa$$y/c$HOME.crt'; do
    adv="$(harbor_ca_not_on_wire_advice "$path" harbor.example)"
    cmd="$(line_after "$adv" "$ADMIN")"
    recipe="$(bash -c "make --no-print-directory -C $(printf '%q' "$REPO") -n ${cmd#make }" 2>/dev/null | command grep -F '27-harbor-ca-from-cluster.sh' | head -1)"
    got="$(bash -c "printf '%s' ${recipe#*27-harbor-ca-from-cluster.sh }" 2>/dev/null)"
    if [ -n "$recipe" ] && [ "$got" = "$path" ]; then ok "advice: pasted, through make and the recipe's shell, the script receives ${path}"
    else bad "advice: the printed command does not deliver ${path} to the script" "printed '${cmd}'; recipe '${recipe}'; delivered '${got}'"; fi
  done
else
  printf 'SKIP  make is not installed: cannot run the printed harbor-ca-from-cluster line through it\n'
fi

# ══ 4. ca_status_report — `make ca-status` and `make lab-preflight` ══════════════════════════
status_report() {  # <port> [path-prefix] [ca-file] ; echoes the report (it prints to stderr)
  ( set +e
    unset VKS_CA_CERT_FILE SUPERVISOR_HOST CA_STATUS_STRICT
    PATH="${2:+$2:}$PATH" HARBOR_URL="localhost:$1" HARBOR_CA_FILE="${3:-$T/old.crt}" CA_VERIFY_TIMEOUT=5 \
      ca_status_report 2>&1 )
}
OLD_STATUS='Get it again — this overwrites in place and cannot lose anything:  make fetch-harbor-ca'
r_ss="$(status_report "$P_SS")"
r_leaf="$(status_report "$P_LEAF")"
r_unk="$(status_report "$P_LEAF" "$T/noshow")"
if has "$r_ss" 'does NOT match' && has "$r_leaf" 'does NOT match' && has "$r_unk" 'does NOT match'; then
  ok "ca-status: all three fixtures reach the leftover-certificate arm (the cases are live)"
else
  bad "ca-status: a fixture did not reach the leftover-certificate arm" "fix the fixture, not the product"
fi
assert_present_wording "ca-status" "self-signed" "$r_ss" "$OLD_STATUS"
assert_leaf_only "ca-status" "$r_leaf" "$T/old.crt" "$CLUSTER HARBOR_CA_FILE=$T/old.crt"
r_inter="$(status_report "$P_INTER")"
assert_leaf_only "ca-status, leaf + intermediate" "$r_inter" "$T/old.crt" "$CLUSTER HARBOR_CA_FILE=$T/old.crt" "$CHAIN_WHY"
if has "$r_inter" 'Get it again' || has "$r_inter" "$LEAF_WHY"; then
  bad "ca-status, leaf + intermediate: names make fetch-harbor-ca bare, or gives the one-certificate reason" "fetch-ca.sh refuses this server"
else
  ok "ca-status, leaf + intermediate: no bare 'Get it again: make fetch-harbor-ca'"
fi
# DATES. The saved CA is the RIGHT one (ca.crt); the served certificate expired in 2020.
r_exp="$(status_report "$P_EXP" "" "$T/ca.crt")"
assert_dates "ca-status" "$r_exp" 2020
( set +e; unset VKS_CA_CERT_FILE SUPERVISOR_HOST CA_STATUS_STRICT
  HARBOR_URL="localhost:$P_EXP" HARBOR_CA_FILE="$T/ca.crt" CA_VERIFY_TIMEOUT=5 ca_status_report >/dev/null 2>&1 ); exp_rc=$?
if [ "$exp_rc" = 1 ]; then ok "ca-status / dates: still counted as one problem (the exit status is unchanged)"
else bad "ca-status / dates: the problem count changed" "ca_status_report returned ${exp_rc}, wanted 1"; fi
if has "$r_leaf" 'Get it again'; then
  bad "ca-status / leaf-only: still says 'Get it again: make fetch-harbor-ca'" "that command refuses on this Harbor"
else
  ok "ca-status / leaf-only: no longer names make fetch-harbor-ca as the way to get it"
fi
if [ "$(command grep -cF -- "$CHECK" <<< "$r_leaf")" = 1 ]; then ok "ca-status / leaf-only: 'Then check it' is printed once"
else bad "ca-status / leaf-only: 'Then check it' is not printed exactly once" "$(command grep -cF -- "$CHECK" <<< "$r_leaf") times"; fi
assert_present_wording "ca-status" "unknown" "$r_unk" "$OLD_STATUS"
# The routes are Harbor's. The Supervisor pair on the SAME leaf-only server keeps its own remedy.
r_sup="$( set +e
          unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
          SUPERVISOR_HOST="localhost:${P_LEAF}" VKS_CA_CERT_FILE="$T/old.crt" CA_VERIFY_TIMEOUT=5 \
            ca_status_report 2>&1 )"
if has "$r_sup" 'make fetch-supervisor-ca' && ! has "$r_sup" 'Harbor UI' && ! has "$r_sup" "$CLUSTER"; then
  :
else
  bad "ca-status: Harbor's routes leaked into the Supervisor CA's message" "$(printf '%s' "$r_sup" | tail -6)"
fi
r_supexp="$( set +e
             unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
             SUPERVISOR_HOST="localhost:${P_EXP}" VKS_CA_CERT_FILE="$T/ca.crt" CA_VERIFY_TIMEOUT=5 \
               ca_status_report 2>&1 )"
if has "$r_sup" 'make fetch-supervisor-ca' && has "$r_supexp" 'make fetch-supervisor-ca' && ! has "$r_supexp" "$DATES"; then
  ok "ca-status: the Supervisor CA on a leaf-only server keeps its own remedy (Harbor's routes are Harbor's)"
else
  bad "ca-status: Harbor's routes leaked into the Supervisor CA's message" "$(printf '%s' "$r_sup" | tail -6)"
fi

# ══ 5. make env-validate ═════════════════════════════════════════════════════════════════════
EV="$T/ev"; mkdir -p "$EV"
cp "${REPO}/.env.example" "$EV/.env.example"
# Comment the two keys in the COPY so load_env cannot put the committed values over the fixture's.
sed -ri 's/^(HARBOR_CA_FILE=|HARBOR_URL=)/# \1/' "$EV/.env.example"
validate() {  # <port> [path-prefix] [ca-file] ; echoes env-validate's output
  cat > "$EV/.env" <<EOF
HARBOR_URL=127.0.0.1:$1
HARBOR_USERNAME=admin
HARBOR_PASSWORD=not-a-real-password
GITEA_ADMIN_PASSWORD=not-a-real-password
VKS_AUTH_METHOD=kubeconfig
HARBOR_INSECURE=0
HARBOR_CA_FILE=${3:-$T/old.crt}
EOF
  env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u VKS_STATE_FILE -u HARBOR_INSECURE \
    PATH="${2:+$2:}$PATH" CA_VERIFY_TIMEOUT=5 REPO_ROOT="$EV" \
    bash "${REPO}/scripts/02-env.sh" validate 2>&1 || true
}
OLD_VALIDATE='Re-fetch it from the lab that is actually running:  make fetch-harbor-ca'
v_ss="$(validate "$P_SS")"
v_leaf="$(validate "$P_LEAF")"
v_unk="$(validate "$P_LEAF" "$T/noshow")"
if has "$v_ss" 'does NOT verify the certificate' && has "$v_leaf" 'does NOT verify the certificate' \
   && has "$v_unk" 'does NOT verify the certificate'; then
  ok "env-validate: all three fixtures reach the wrong-CA arm (the cases are live)"
else
  bad "env-validate: a fixture did not reach the wrong-CA arm" "$(printf '%s' "$v_unk" | tail -6)"
fi
assert_present_wording "env-validate" "self-signed" "$v_ss" "$OLD_VALIDATE"
assert_leaf_only "env-validate" "$v_leaf" "$T/old.crt" "$CLUSTER HARBOR_CA_FILE=$T/old.crt"
v_inter="$(validate "$P_INTER")"
assert_leaf_only "env-validate, leaf + intermediate" "$v_inter" "$T/old.crt" "$CLUSTER HARBOR_CA_FILE=$T/old.crt" "$CHAIN_WHY"
if has "$v_inter" 'Re-fetch it'; then bad "env-validate, leaf + intermediate: names make fetch-harbor-ca bare" "fetch-ca.sh refuses this server"
else ok "env-validate, leaf + intermediate: no bare 'Re-fetch it: make fetch-harbor-ca'"; fi
v_exp="$(validate "$P_EXP" "" "$T/ca.crt")"
assert_dates "env-validate" "$v_exp" 2020
if has "$v_exp" 'env-validate: ' && has "$v_exp" 'problem(s)'; then ok "env-validate / dates: still an error (the run fails as before)"
else bad "env-validate / dates: the run no longer reports a problem" "$(printf '%s' "$v_exp" | tail -3 | cut -c1-160)"; fi
if has "$v_leaf" 'Re-fetch it'; then
  bad "env-validate / leaf-only: still says 'Re-fetch it: make fetch-harbor-ca'" "that command refuses on this Harbor"
else
  ok "env-validate / leaf-only: no longer names make fetch-harbor-ca as the way to get it"
fi
assert_present_wording "env-validate" "unknown" "$v_unk" "$OLD_VALIDATE"

# ══ 6. make creds ════════════════════════════════════════════════════════════════════════════
# Stub `getent`/`curl` make Harbor's row `serving` (the bullet is gated on it); openssl is REAL
# and talks to the listeners above.
creds_render() {  # <dir> <HARBOR_URL> <ca-file-to-install | -> [path-prefix] [probe-timeout] ; echoes the report
  local t="$1"
  mkdir -p "$t/bin" "$t/secrets"
  cp "${REPO}/.env.example" "$t/.env.example"
  [ "$3" = - ] || cp "$3" "$t/secrets/harbor-ca.crt"
  # `$2` is the STUB's positional, written literally into the generated script (SC2016 is deliberate).
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "127.0.0.1 %%s\\n" "$2"\n' > "$t/bin/getent"
  printf '#!/bin/sh\nprintf 200\n' > "$t/bin/curl"
  chmod +x "$t/bin/getent" "$t/bin/curl"
  printf 'HARBOR_URL=%s\nHARBOR_PASSWORD=x\nHARBOR_CA_FILE=./secrets/harbor-ca.crt\n' "$2" > "$t/.env"
  ( cd "$t" && env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u HARBOR_INSECURE \
      PATH="$t/bin:${4:+$4:}$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      CREDS_NO_PROBE=0 CREDS_TOKEN=1 CREDS_PROBE_TIMEOUT_SECONDS="${5:-5}" \
      timeout -k 2 45 "${REPO}/scripts/creds.sh" 2>/dev/null )
}
OLD_CREDS='does NOT verify it — re-fetch it:'
c_ss="$(creds_render "$T/c-ss" "localhost:$P_SS" "$T/old.crt")"
c_leaf="$(creds_render "$T/c-leaf" "localhost:$P_LEAF" "$T/old.crt")"
c_unk="$(creds_render "$T/c-unk" "localhost:$P_LEAF" "$T/old.crt" "$T/noshow")"
if has "$c_ss" 'does NOT verify it' && has "$c_leaf" 'does NOT verify it' && has "$c_unk" 'does NOT verify it'; then
  ok "creds: all three fixtures reach the wrong-CA bullet (the cases are live)"
else
  bad "creds: a fixture did not reach the wrong-CA bullet" "fix the getent/curl stubs, not the product"
fi
assert_present_wording "creds" "self-signed" "$c_ss" "$OLD_CREDS"
if command grep -qxF '      make fetch-harbor-ca' <<< "$c_ss"; then
  ok "creds / self-signed: the command stands alone on its line"
else
  bad "creds / self-signed: make fetch-harbor-ca is not on a line of its own"
fi
# creds names the file by its ABSOLUTE path (a relative one resolved against the CWD once reported
# a CA that was there as missing), on the save-as line and on the admin route alike.
assert_leaf_only "creds" "$c_leaf" "$T/c-leaf/secrets/harbor-ca.crt" "$CLUSTER HARBOR_CA_FILE=$T/c-leaf/secrets/harbor-ca.crt"
c_inter="$(creds_render "$T/c-inter" "localhost:$P_INTER" "$T/old.crt")"
assert_leaf_only "creds, leaf + intermediate" "$c_inter" "$T/c-inter/secrets/harbor-ca.crt" "$CLUSTER HARBOR_CA_FILE=$T/c-inter/secrets/harbor-ca.crt" "$CHAIN_WHY"
if has "$c_inter" 're-fetch it' || command grep -qxF '      make fetch-harbor-ca' <<< "$c_inter"; then
  bad "creds, leaf + intermediate: prescribes make fetch-harbor-ca bare" "fetch-ca.sh refuses this server"
else
  ok "creds, leaf + intermediate: no bare make fetch-harbor-ca line"
fi
c_exp="$(creds_render "$T/c-exp" "localhost:$P_EXP" "$T/ca.crt")"
assert_dates "creds" "$c_exp" 2020
if has "$c_leaf" 're-fetch it' || command grep -qxF '      make fetch-harbor-ca' <<< "$c_leaf"; then
  bad "creds / leaf-only: still prescribes make fetch-harbor-ca" "that command refuses on this Harbor"
else
  ok "creds / leaf-only: no longer prescribes make fetch-harbor-ca"
fi
assert_present_wording "creds" "unknown" "$c_unk" "$OLD_CREDS"

# THE BOUND. The wire question is sent to the listener that never answers. The report must come
# back at about CREDS_PROBE_TIMEOUT_SECONDS, with the wording it always had. `creds_render` gives
# up at 45 s, so a missing bound is a FAIL here and not a hung suite.
t0=$SECONDS
c_base="$(creds_render "$T/c-base" "localhost:$P_LEAF" "$T/old.crt" "$T/noshow" 3)"
base_el=$((SECONDS - t0))
t0=$SECONDS
c_hang="$(creds_render "$T/c-hang" "localhost:$P_LEAF" "$T/old.crt" "$T/hang" 3)"
hang_el=$((SECONDS - t0))
: "$c_base"
# The same render with the question failing at once is the baseline; the hang may add the bound
# (3 s) and a margin, and must add SOMETHING or the listener was not silent.
if has "$c_hang" "$OLD_CREDS" && ! has "$c_hang" "$NOT_WIRE" \
   && [ "$hang_el" -le $((base_el + 3 + 6)) ] && [ "$hang_el" -ge $((base_el + 2)) ]; then
  ok "creds: a Harbor that stops answering costs the probe bound and no more (${hang_el}s against ${base_el}s, bound 3s), wording unchanged"
else
  bad "creds: the wire question is not bounded by CREDS_PROBE_TIMEOUT_SECONDS" \
      "took ${hang_el}s against a ${base_el}s baseline with a 3s bound; wording kept: $(has "$c_hang" "$OLD_CREDS" && echo yes || echo no)"
fi

# rc=3: the CA is right and HARBOR_URL is not a name the certificate carries. The line printed
# must LIST the names. `make fetch-harbor-ca` does not on this Harbor: it stops at the
# one-certificate check before it reads any name. So the printed line is RUN here.
c_name="$(creds_render "$T/c-name" "127.0.0.2:$P_LEAF" "$T/ca.crt")"
SAN_CMD="openssl s_client -connect 127.0.0.2:${P_LEAF} -servername 127.0.0.2 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName"
if ! has "$c_name" 'is not a name its cert carries'; then
  bad "creds rc=3: the fixture did not reach the name-mismatch bullet" "$(command grep -F -A3 -- '- Harbor' <<< "$c_name" | cut -c1-200)"
elif has "$c_name" 'make fetch-harbor-ca lists them'; then
  bad "creds rc=3: still says make fetch-harbor-ca lists the names" "on a Harbor that sends one certificate it refuses before reading any"
elif [ "$(line_after "$c_name" 'This lists them:')" = "$SAN_CMD" ]; then
  ok "creds rc=3: prints a login-free command with the real host and port"
  san_out="$(bash -c "$SAN_CMD" 2>&1)"
  if has "$san_out" 'DNS:localhost'; then ok "creds rc=3: that command, run as printed, lists the certificate's names"
  else bad "creds rc=3: the printed command does not list the names" "it printed: $(printf '%s' "$san_out" | head -3)"; fi
else
  bad "creds rc=3: the command that lists the names is missing or wrong" "got '$(line_after "$c_name" 'This lists them:')'"
fi

# ══ 7. the messages that do not ask what Harbor sends ════════════════════════════════════════
# (a) make ca-status, a CA file that is not a certificate. Harbor gets the hedge; the Supervisor
#     pair keeps its own line.
r_bad="$(status_report "$P_LEAF" "" "$T/garbage.crt")"
assert_hedge "ca-status, unusable CA file" "$r_bad" 'is not a usable CA certificate' 'run: make fetch-harbor-ca'
r_supbad="$( set +e
             unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
             SUPERVISOR_HOST="localhost:${P_LEAF}" VKS_CA_CERT_FILE="$T/garbage.crt" CA_VERIFY_TIMEOUT=5 \
               ca_status_report 2>&1 )"
if has "$r_supbad" 'is not a usable CA certificate — run: make fetch-supervisor-ca' && ! has "$r_supbad" "$CLUSTER"; then
  ok "ca-status, unusable CA file: the Supervisor CA keeps its own line"
else
  bad "ca-status, unusable CA file: the Supervisor CA's line changed" "$(printf '%s' "$r_supbad" | tail -3)"
fi
# (b) make env-validate, a CA file that is there and is not a certificate. The message used to say
#     it "exists but is EMPTY", which is false for what reaches this arm (an empty file takes
#     another one): the wording is judged here. No internal tracker id may reach the reader.
v_empty="$(validate "$P_LEAF" "" "$T/garbage.crt")"
assert_hedge "env-validate, unusable CA file" "$v_empty" 'is not a usable CA certificate (empty, truncated,' 're-fetch it:  make fetch-harbor-ca'
if has "$v_empty" 'exists but is EMPTY'; then bad "env-validate, unusable CA file: still calls a non-empty file EMPTY"
else ok "env-validate, unusable CA file: does not call a non-empty file EMPTY"; fi
if has "$v_empty" 'is not a usable CA certificate (empty, truncated,' && ! command grep -qE '\bB[0-9]{2,}\b' <<< "$(command grep -F -A6 'is not a usable CA certificate (empty, truncated,' <<< "$v_empty")"; then
  ok "env-validate, unusable CA file: no internal tracker id in the message"
else
  bad "env-validate, unusable CA file: an internal tracker id is printed (or the arm was not reached)" "$(command grep -F -A6 'is not a usable CA certificate (empty, truncated,' <<< "$v_empty" | cut -c1-160)"
fi
# (c) make creds, a CA file that is not a certificate; (d) make creds, no CA file at all.
c_unread="$(creds_render "$T/c-unread" "localhost:$P_LEAF" "$T/garbage.crt")"
assert_hedge "creds, unreadable CA file" "$c_unread" 'is not a readable certificate — get one:'
if command grep -qxF '      make fetch-harbor-ca' <<< "$c_unread"; then
  bad "creds, unreadable CA file: a bare make fetch-harbor-ca line is still printed"
else
  ok "creds, unreadable CA file: no bare make fetch-harbor-ca line"
fi
# The report is read in a terminal: the hedge is wrapped to the width its neighbours use.
wide="$(command grep -F -A2 -- "$HEDGE1" <<< "$c_unread" | awk 'length($0) > 96 { print length($0) ": " $0 }')"
if has "$c_unread" "$HEDGE1" && [ -z "$wide" ]; then ok "creds, unreadable CA file: no hedge line is wider than 96 columns"
else bad "creds, unreadable CA file: a hedge line is too wide (or the hedge is missing)" "$wide"; fi
c_none="$(creds_render "$T/c-none" "localhost:$P_LEAF" -)"
assert_hedge "creds, no CA file" "$c_none" 'no readable CA — get one, then re-run this report:'
if command grep -qxF '      make fetch-harbor-ca' <<< "$c_none"; then
  bad "creds, no CA file: a bare make fetch-harbor-ca line is still printed"
else
  ok "creds, no CA file: no bare make fetch-harbor-ca line"
fi
# (e) make vks-trust-probe with no local CA. kubectl is a stub that fails: nothing is contacted.
VP="$T/vp"; mkdir -p "$VP/bin" "$VP/root"
cp "${REPO}/.env.example" "$VP/root/.env.example"; : > "$VP/kubeconfig"
printf '#!/bin/sh\nexit 1\n' > "$VP/bin/kubectl"; chmod +x "$VP/bin/kubectl"
vp_out="$(env -u HARBOR_URL PATH="$VP/bin:$PATH" KUBECONFIG="$VP/kubeconfig" REPO_ROOT="$VP/root" \
            HARBOR_CA_FILE="$VP/no-such-ca.crt" timeout 60 bash "${REPO}/scripts/vks-trust-probe.sh" 2>&1 </dev/null)"
assert_hedge "vks-trust-probe, no local CA" "$vp_out" 'SKIP - no local CA at' 'run: make fetch-harbor-ca'
# (f) make trust-harbor with docker chosen and no CA file. `docker` is a stub that only answers
#     `info`; the script stops at the missing file, before any login.
TH="$T/th"; mkdir -p "$TH/bin" "$TH/root"
cp "${REPO}/.env.example" "$TH/root/.env.example"
sed -ri 's/^(HARBOR_CA_FILE=|HARBOR_URL=)/# \1/' "$TH/root/.env.example"
# `$1` is the STUB's positional, written literally into the generated script (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" = info ] && { echo "name=rootless"; exit 0; }\nexit 1\n' > "$TH/bin/docker"; chmod +x "$TH/bin/docker"
printf 'HARBOR_URL=localhost:%s\nHARBOR_USERNAME=admin\nHARBOR_PASSWORD=x\nHARBOR_CA_FILE=%s\n' "$P_LEAF" "$TH/no-such-ca.crt" > "$TH/root/.env"
th_out="$(env -u HARBOR_URL -u HARBOR_CA_FILE -u HARBOR_INSECURE -u KUBECONFIG PATH="$TH/bin:$PATH" \
            CONTAINER_ENGINE=docker REPO_ROOT="$TH/root" VKS_STATE_FILE="$TH/root/.env.state" \
            timeout 60 bash "${REPO}/scripts/19-trust-harbor.sh" 2>&1 </dev/null)"
if [ "$(os_id)" = macos ]; then
  printf 'SKIP  trust-harbor refuses on macOS before the message under test\n'
else
  assert_hedge "trust-harbor, no CA file" "$th_out" 'could not wire the CA' "'make fetch-harbor-ca' re-fetches it"
fi

# ══ 8. one kind of digest ════════════════════════════════════════════════════════════════════
# The runbook's step and the scripts must ask for the SAME number. `sha256sum` of the PEM file and
# the certificate fingerprint are different values that never match.
DOC="${REPO}/docs/scenario-1.md"
if [ -f "$DOC" ]; then
  if command grep -qE '^sha256sum .*harbor-ca\.crt' "$DOC"; then
    bad "scenario-1 Step 8 tells the reader to compare sha256sum of the CA file" "the scripts print the certificate fingerprint; the two never match"
  elif command grep -qxF 'openssl x509 -in ./secrets/harbor-ca.crt -noout -fingerprint -sha256' "$DOC"; then
    ok "scenario-1 Step 8 compares the certificate fingerprint, the number the scripts print"
  else
    bad "scenario-1 Step 8 has no fingerprint command for the Harbor CA" "expected the openssl x509 -fingerprint -sha256 line"
  fi
  # The UI bullet must carry the command for the DOWNLOADED file itself. "The command above"
  # names ./secrets/harbor-ca.crt, which is the file not to have saved yet.
  # Literal backticks: this is the doc's inline-code form (SC2016 is deliberate).
  # shellcheck disable=SC2016
  if command grep -qF '`openssl x509 -in ~/Downloads/ca.crt -noout -fingerprint -sha256`' "$DOC"; then
    ok "scenario-1 Step 8: the UI alternative gives the fingerprint command for the downloaded file"
  else
    bad "scenario-1 Step 8: the UI alternative points at a command that names the live file" "expected the ~/Downloads/ca.crt line in the bullet"
  fi
  fa="$(openssl x509 -in "$T/ca.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
  fb="$(ca_fingerprint "$T/ca.crt")"
  if [ -n "$fa" ] && [ "$fa" = "$fb" ]; then ok "the documented command prints the same value the scripts print (ca_fingerprint)"
  else bad "the documented command and ca_fingerprint disagree" "'${fa}' vs '${fb}'"; fi
else
  printf 'SKIP  docs/scenario-1.md is not present next to these scripts\n'
fi

printf '\ntest-harbor-ca-refetch-advice: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-harbor-ca-refetch-advice: OK\n'
