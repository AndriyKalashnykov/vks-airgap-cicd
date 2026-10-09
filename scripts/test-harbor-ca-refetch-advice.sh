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
# fetch-ca.sh ITSELF IS BOUNDED, and that is pinned in test-fetch-ca-bound.sh (slow tier: every
# case there waits out a bound). HERE, instantly: the clamp (tls_timeout_bound), the runner
# (tls_bounded) and the TCP question (tls_port_accepts) as units; that no script hands
# CA_VERIFY_TIMEOUT to `timeout` itself; and that make hands the variable to the two fetch targets
# (a stub stands in for fetch-ca.sh and prints what it was given).
#
# THE CA FILE'S OWN DATES (section 6b): an EXPIRED or NOT-YET-VALID CA file over a server whose
# certificate is valid is not "the CA is right, do not replace it". Every site shows the FILE's
# dates and the way to get the current CA.
#
# AN ADDRESS IS NEVER SHELL TEXT (section 6): `make creds` with an ingress address and an ArgoCD
# address of `$(touch …)` creates no file.
#
# A PATH WITH A `|` OR A SPACE (section 4): the report's fields are not separated by a character a
# path can hold, so the message names the file that was configured.
#
# THE SUPERVISOR ROW ASKS ABOUT DATES TOO (section 4): an expired or not-yet-valid certificate
# under the RIGHT CA gets the dates message, not "leftover"; a wrong CA still says leftover.
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
# The scripts under test make temp files of their own: keep them in this test's directory.
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
# EVERY SCRIPT RUN HERE IS GIVEN A SANDBOX AS ITS REPO_ROOT, WITH ITS OWN .env AS THE FIXTURE. A
# caller's SKIP_DOTENV=1 (the e2e sets it, and so does anyone fencing a test run) would make
# load_env ignore that fixture and every case would test an empty configuration. And a caller's
# "already reported" list would hide the one line the time-limit cases look for.
unset SKIP_DOTENV _VKS_BOUNDS_REPORTED
# RUN FROM `make test-scripts`, THIS FILE INHERITS make'S OWN ENVIRONMENT, and it failed there
# while passing by hand. The Makefile exports HARBOR_CA_SHA256 and ARGOCD_CA_SHA256 to every
# recipe, EMPTY when nobody set them; an empty-but-defined variable is "set" to the `?=` lines a
# sandbox .env is turned into, so the make cases below saw no pin at all, and a pin the operator
# really has would have reached every fetch here. MAKEFLAGS and MAKELEVEL change how an inner
# make prints and resolves. None of it belongs to these cases: each one states its own inputs.
unset HARBOR_CA_SHA256 ARGOCD_CA_SHA256 CA_VERIFY_TIMEOUT _FETCH_CA_ENDPOINT MAKEFLAGS MAKELEVEL MFLAGS
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
  done
  # THE CA ITSELF with dates that are wrong today: the SAME key and subject as ca.crt (so it
  # still verifies leaf.crt once dates are ignored), expired in 2021, or not valid for years.
  openssl req -new -key ca.key -out caself.csr -subj '/CN=Harbor CA' \
    -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
  for row in "caexp|20200101000000Z|20210101000000Z" "cany|$((y + 5))0101000000Z|$((y + 6))0101000000Z"; do
    n="${row%%|*}"; rest="${row#*|}"
    openssl ca -batch -notext -config ca.cnf -selfsign -keyfile ca.key -in caself.csr -out "$n.crt" \
      -startdate "${rest%%|*}" -enddate "${rest##*|}" >/dev/null 2>&1
  done )
for f in ss.crt ss.key ca.crt leaf.crt leaf.key old.crt garbage.crt inter.crt leaf2.crt inter-and-root.crt expired.crt notyet.crt caexp.crt cany.crt; do
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
# An expired certificate whose server DOES send its CA: the shape `make fetch-harbor-ca` gets as
# far as checking (a single not-self-signed certificate is refused before any date is looked at).
_serve "$T/expired.crt" "$T/expired.key" "$T/ca.crt" || { echo "SKIP: s_server did not start (expired + its CA)"; exit 0; }
P_EXPCHAIN="$SERVED_PORT"
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

# DATES FIRST, IN THE FETCH TOO. Its own consistency check (`openssl verify`) fails on an EXPIRED
# server certificate, and the message was "the certificate we extracted does NOT verify … ask the
# platform team for the issuing CA": the CA was right there, and right.
fetch_out="$(CA_VERIFY_TIMEOUT=5 timeout -k 2 40 bash "${REPO}/scripts/fetch-ca.sh" "localhost:${P_EXPCHAIN}" "$T/out-expchain.crt" harbor </dev/null 2>&1)"; fetch_rc=$?
if [ "$fetch_rc" = 1 ] && has "$fetch_out" "the CA localhost:${P_EXPCHAIN} sends is the right one, but the certificate it presents is outside its dates." \
   && has "$fetch_out" "$DATES" && has "$fetch_out" 'whoever operates Harbor has to renew it. Do NOT replace the CA file.' \
   && ! has "$fetch_out" 'does NOT verify' && ! has "$fetch_out" 'Ask the platform team' && [ ! -e "$T/out-expchain.crt" ]; then
  ok "fetch-ca.sh: an expired certificate under the CA the server sends -> the dates text, not 'does NOT verify … ask for the issuing CA'; nothing written"
else
  bad "fetch-ca.sh: an expired server certificate is still reported as a CA that does not verify" "rc=${fetch_rc}: $(printf '%s' "$fetch_out" | command grep -F -e 'right one' -e 'does NOT verify' | head -2 | cut -c1-160)"
fi
# …and ONLY then. Leaf + intermediate + root (refused above with 'does NOT verify') would also say
# yes to the dates question asked cold: the handshake verifies there with or without dates. The
# fetch asks it only after the plain check said "connected, and it does not verify".
fetch_out="$(CA_VERIFY_TIMEOUT=5 timeout -k 2 40 bash "${REPO}/scripts/fetch-ca.sh" "localhost:${P_FULL}" "$T/out-full.crt" harbor </dev/null 2>&1)"
if has "$fetch_out" 'does NOT verify' && ! has "$fetch_out" "$DATES" && ! has "$fetch_out" 'outside its dates'; then
  ok "fetch-ca.sh: a chain it cannot use (dates fine) is NOT called a dates problem (control)"
else
  bad "fetch-ca.sh: the dates text is printed over a chain problem" "$(printf '%s' "$fetch_out" | command grep -F -e 'dates' -e 'does NOT verify' | head -2 | cut -c1-160)"
fi

# A port nothing listens on: the fetch fails at once with the sentence it always had. (What it
# does when the time runs out is in test-fetch-ca-bound.sh: those cases wait out a bound.)
fetch_out="$(CA_VERIFY_TIMEOUT=5 timeout -k 2 40 bash "${REPO}/scripts/fetch-ca.sh" "127.0.0.1:${P_DEAD}" "$T/out-dead.crt" harbor </dev/null 2>&1)"; fetch_rc=$?
if [ "$fetch_rc" = 1 ] && has "$fetch_out" "could not connect to 127.0.0.1:${P_DEAD} — is harbor reachable over HTTPS?" && [ ! -e "$T/out-dead.crt" ]; then
  ok "fetch-ca.sh: a closed port says 'could not connect' and writes nothing"
else
  bad "fetch-ca.sh: the closed-port message changed" "rc=${fetch_rc}: $(printf '%s' "$fetch_out" | tail -1 | cut -c1-160)"
fi

# ══ 2b. the bound, the runner and the TCP question, as units (no waiting) ════════════════════
# tls_timeout_bound: what reaches `timeout`. `timeout 0` is NO limit, so nothing that is not a
# positive number may come out.
bound_is() {  # <CA_VERIFY_TIMEOUT or -> <argument> <want>
  local got
  if [ "$1" = - ]; then got="$(unset CA_VERIFY_TIMEOUT; tls_timeout_bound "$2")"
  else got="$(CA_VERIFY_TIMEOUT="$1" tls_timeout_bound "$2")"; fi
  if [ "$got" = "$3" ]; then ok "tls_timeout_bound: argument '${2}', CA_VERIFY_TIMEOUT '${1}' -> ${3}"
  else bad "tls_timeout_bound: argument '${2}', CA_VERIFY_TIMEOUT '${1}'" "wanted '${3}', got '${got}'"; fi
}
bound_is - 0 15;   bound_is - -1 15;  bound_is - abc 15; bound_is - '' 15; bound_is - 0.0 15
bound_is - 2.5 2.5; bound_is - 30 30
bound_is 7 0 7;    bound_is 7 '' 7;   bound_is 7 30 30
bound_is 0 '' 15;  bound_is abc '' 15; bound_is -3 0 15; bound_is '' '' 15
# A unit suffix is what `timeout` itself accepts; it was silently the default (2s -> 15).
bound_is 2s '' 2;  bound_is 1m '' 60; bound_is - 30s 30; bound_is 0s '' 15; bound_is '"3"' '' 15
# tls_bounded: the command's own status comes back; an unusable bound does not switch it off.
r=0; tls_bounded 5 sh -c 'exit 7' || r=$?
if [ "$r" = 7 ]; then ok "tls_bounded: the command's exit status comes back unchanged"
else bad "tls_bounded: the command's status was lost" "wanted 7, got ${r}"; fi
# The flag is PROBED. Two stand-in `timeout`s record what they were handed: one accepts
# --foreground, one refuses it. Both must end up running the command.
REAL_TIMEOUT="$(command -v timeout)"
mkdir -p "$T/fg-yes" "$T/fg-no"
# The stubs' own "$@" / "$1" are written literally into the generated scripts (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = "--foreground" ] && shift\nexec %s "$@"\n' "$T/fg-yes.log" "$REAL_TIMEOUT" > "$T/fg-yes/timeout"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = "--foreground" ] && { echo "unknown option" >&2; exit 125; }\nexec %s "$@"\n' "$T/fg-no.log" "$REAL_TIMEOUT" > "$T/fg-no/timeout"
chmod +x "$T/fg-yes/timeout" "$T/fg-no/timeout"
# Each in a fresh shell: the probe's answer is remembered per shell.
# shellcheck disable=SC2016
r_yes="$(PATH="$T/fg-yes:$PATH" bash -c '. "$1"; . "$2"; tls_bounded 0 sh -c "exit 3"; echo "rc=$?"' _ "$LIB_OS" "$LIB_TLS" 2>&1)"
# shellcheck disable=SC2016
r_no="$(PATH="$T/fg-no:$PATH" bash -c '. "$1"; . "$2"; tls_bounded 0 sh -c "exit 3"; echo "rc=$?"' _ "$LIB_OS" "$LIB_TLS" 2>&1)"
if [ "$r_yes" = 'rc=3' ] && [ "$(tail -1 "$T/fg-yes.log")" = '--foreground 15 sh -c exit 3' ]; then
  ok "tls_bounded: a timeout that has --foreground is given it, with the clamped bound (0 -> 15)"
else
  bad "tls_bounded: --foreground was not used where it is available" "said '${r_yes}'; last call '$(tail -1 "$T/fg-yes.log" 2>/dev/null)'"
fi
if [ "$r_no" = 'rc=3' ] && [ "$(tail -1 "$T/fg-no.log")" = '15 sh -c exit 3' ]; then
  ok "tls_bounded: a timeout that refuses --foreground is used without it, and the command still runs"
else
  bad "tls_bounded: a timeout without --foreground broke the command" "said '${r_no}'; last call '$(tail -1 "$T/fg-no.log" 2>/dev/null)'"
fi
# tls_port_accepts: yes on a listener, no on a closed port, no on a port that is not a number.
if tls_port_accepts 127.0.0.1 "$P_SS" 5; then ok "tls_port_accepts: a listening port -> yes"
else bad "tls_port_accepts: a listening port must be yes"; fi
if tls_port_accepts 127.0.0.1 "$P_SS" 0; then ok "tls_port_accepts: a bound of 0 is clamped, not refused (still yes on a listener)"
else bad "tls_port_accepts: a bound of 0 must be clamped to the default"; fi
if tls_port_accepts 127.0.0.1 "$P_DEAD" 5; then bad "tls_port_accepts: a closed port must be no"
else ok "tls_port_accepts: a closed port -> no"; fi
port_no=""
# One of the ports is shell text on purpose (SC2016 is deliberate).
# shellcheck disable=SC2016
for badport in http 80x '' "${P_SS};true" '$(echo 1)'; do
  if tls_port_accepts 127.0.0.1 "$badport" 5; then port_no="${port_no} [${badport}]"; fi
done
if [ -z "$port_no" ]; then ok "tls_port_accepts: a port that is not a number -> no (a service name, a suffix, empty, shell text)"
else bad "tls_port_accepts: a non-numeric port was accepted" "accepted:${port_no}"; fi
# ...and it is refused BEFORE anything is dialled: bash would look a word up as a service name
# (`http` is port 80), so "no" alone could just mean nothing listens there. The recording
# `timeout` from above must not be called at all.
: > "$T/fg-yes.log"
PATH="$T/fg-yes:$PATH" tls_port_accepts 127.0.0.1 http 5 || true
if [ ! -s "$T/fg-yes.log" ]; then ok "tls_port_accepts: a service-name port is refused without dialling anything"
else bad "tls_port_accepts: a service-name port was dialled" "timeout was run with: $(tail -1 "$T/fg-yes.log")"; fi
PATH="$T/fg-yes:$PATH" tls_port_accepts 127.0.0.1 "$P_SS" 5 || true
if [ -s "$T/fg-yes.log" ]; then ok "tls_port_accepts: (control) a numeric port does go through the recording timeout"
else bad "tls_port_accepts: the recording timeout saw nothing for a numeric port" "the no-dial assertion above would then prove nothing"; fi
# THE ADDRESS IS NEVER SHELL TEXT. Each of these would create the canary if the address were
# pasted into the child shell's script. The canary's path has no `/` in it on purpose (cd first):
# `/dev/tcp/<host>/<port>` would cut a path at its first slash and hide the execution.
( cd "$T" || exit 1
  # The command substitutions are the DATA under test (SC2016 is deliberate).
  # shellcheck disable=SC2016
  for evil in '$(touch canary-host)' '`touch canary-host`' '127.0.0.1; touch canary-host' 'x" ; touch canary-host ; "'; do
    tls_port_accepts "$evil" "$P_SS" 2 || true
  done
  # shellcheck disable=SC2016
  tls_port_accepts 127.0.0.1 '$(touch canary-port)' 2 || true )
if [ ! -e "$T/canary-host" ] && [ ! -e "$T/canary-port" ]; then
  ok "tls_port_accepts: an address or port holding \$(…), backticks or ';' is not executed (no canary)"
else
  bad "tls_port_accepts: text in the address was EXECUTED" "$(find "$T" -maxdepth 1 -name 'canary-*' | tr '\n' ' ')"
fi
# The same hostile addresses through the form this replaced DO create it: the instrument works.
# shellcheck disable=SC2016
( cd "$T" && evil='$(touch canary-control)' && timeout 2 bash -c "exec 3<>/dev/tcp/${evil}/1" 2>/dev/null ) || true
if [ -e "$T/canary-control" ]; then ok "canary control: the interpolating form this replaced does execute the address"
else bad "canary control: the old form did not create the canary" "the no-canary assertion above would then prove nothing"; fi

# NO SCRIPT HANDS CA_VERIFY_TIMEOUT TO `timeout` ITSELF: a 0 there is no limit. Comment lines are
# dropped; test files may spell the form (this one does, right here).
RAW_FORM='timeout[[:space:]]+(--[a-z-]+[[:space:]]+)*"?\$\{?CA_VERIFY_TIMEOUT'
raw_hits="$(command grep -rnE --include='*.sh' -- "$RAW_FORM" "${REPO}/scripts" \
              | command grep -vE '/scripts/test-[^/]*\.sh:' | command grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
n_scanned="$(command grep -rlE --include='*.sh' -- 'CA_VERIFY_TIMEOUT' "${REPO}/scripts" | command grep -cvE '/scripts/test-[^/]*\.sh$' || true)"
# The planted line is the form being looked for, written literally (SC2016 is deliberate).
# shellcheck disable=SC2016
printf 'timeout "${CA_VERIFY_TIMEOUT:-15}" openssl s_client\n' > "$T/raw-control.sh"
if [ -z "$raw_hits" ] && [ "${n_scanned:-0}" -ge 3 ] && command grep -qE -- "$RAW_FORM" "$T/raw-control.sh"; then
  ok "no script under scripts/ hands CA_VERIFY_TIMEOUT to timeout unclamped (${n_scanned} files name the variable; the pattern finds a planted line)"
else
  bad "a script hands CA_VERIFY_TIMEOUT straight to timeout (0 = no limit), or the scan looked at nothing" "files naming the variable: ${n_scanned:-0}; hits: $(printf '%s' "$raw_hits" | cut -c1-200)"
fi

# make HANDS CA_VERIFY_TIMEOUT TO THE TWO FETCH TARGETS. fetch-ca.sh does not read .env, so a
# value there reached it only if make exported it, and it did not. A stub stands in for the
# scripts and prints what it was given; the Makefile is the real one, run in a sandbox directory
# with its own .env. Both directions: .env reaches it, and a per-run value wins over .env.
if command -v make >/dev/null 2>&1; then
  MKS="$T/mk"; mkdir -p "$MKS/stub" "$MKS/with-env" "$MKS/no-env"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "bound=[%%s]\\n" "${CA_VERIFY_TIMEOUT-UNSET}"\n' > "$MKS/stub/fetch-ca.sh"
  cp "$MKS/stub/fetch-ca.sh" "$MKS/stub/27-harbor-ca-from-cluster.sh"
  chmod +x "$MKS/stub/"*.sh
  printf 'CA_VERIFY_TIMEOUT=3\n' > "$MKS/with-env/.env"
  mk() {  # <sandbox> <target> [make args / VAR=value …] ; prints the stub's line
    local sb="$1" tgt="$2"; shift 2
    env -u CA_VERIFY_TIMEOUT -u HARBOR_CA_SHA256 -u ARGOCD_CA_SHA256 -u HARBOR_URL -u ARGOCD_SERVER -u ARGOCD_LB_IP \
        -u SKIP_DOTENV -u VKS_STATE_FILE -u MAKEFLAGS -u MAKELEVEL -u MFLAGS ${MK_ENV:+"$MK_ENV"} \
      make --no-print-directory -f "${REPO}/Makefile" -C "$MKS/$sb" "$tgt" SCRIPTS="$MKS/stub" \
        HARBOR_URL=h.example HARBOR_CA_FILE="$MKS/x.crt" ARGOCD_SERVER=a.example "$@" 2>&1 </dev/null | command grep -F 'bound=[' | head -1
  }
  for row in "with-env|fetch-harbor-ca||bound=[3]|a value in .env reaches make fetch-harbor-ca" \
             "with-env|fetch-argocd-ca||bound=[3]|a value in .env reaches make fetch-argocd-ca" \
             "with-env|fetch-harbor-ca|CA_VERIFY_TIMEOUT=9|bound=[9]|make fetch-harbor-ca CA_VERIFY_TIMEOUT=9 wins over .env" \
             "no-env|fetch-harbor-ca|CA_VERIFY_TIMEOUT=9|bound=[9]|with no .env the per-run value still arrives" \
             "no-env|fetch-harbor-ca||bound=[]|set nowhere it arrives empty (the script reads that as the default)" \
             "with-env|harbor-ca-from-cluster||bound=[UNSET]|the export is for the two fetch targets only (another recipe does not get it)"; do
    IFS='|' read -r sb tgt arg want what <<< "$row"
    if [ -n "$arg" ]; then got="$(mk "$sb" "$tgt" "$arg")"; else got="$(mk "$sb" "$tgt")"; fi
    if [ "$got" = "$want" ]; then ok "make: ${what}"
    else bad "make: ${what}" "wanted '${want}', got '${got}'"; fi
  done
  # ONE .env, TWO PARSERS. A shell reads `KEY="3"` as 3 and `KEY=3   # seconds` as 3; make read the
  # first as the five characters "3" and the second as 3 plus the blanks before the #. The fetch
  # gets these values from make alone, so both became the 15 s default (and a quoted pin "is not a
  # SHA-256 digest"). What the script receives must be what a shell would have read.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "bound=[%%s] pin=[%%s]\\n" "${CA_VERIFY_TIMEOUT-UNSET}" "${HARBOR_CA_SHA256-UNSET}"\n' > "$MKS/stub/fetch-ca.sh"
  mkq() {  # <one .env line> [make args] ; prints what the stub received
    local sb="q$((PASS + FAIL))"; mkdir -p "$MKS/$sb"; printf '%s\n' "$1" > "$MKS/$sb/.env"; shift
    mk "$sb" fetch-harbor-ca "$@"
  }
  while IFS='|' read -r line want what; do
    [ -n "$what" ] || continue
    got="$(mkq "$line")"
    if [ "$got" = "$want" ]; then ok "make, .env parse: ${what}"
    else bad "make, .env parse: ${what}" "the line [${line}] arrived as '${got}', wanted '${want}'"; fi
  done <<'ENVROWS'
CA_VERIFY_TIMEOUT="3"|bound=[3] pin=[]|a double-quoted timeout arrives unquoted
CA_VERIFY_TIMEOUT='3'|bound=[3] pin=[]|a single-quoted timeout arrives unquoted
CA_VERIFY_TIMEOUT=3   # seconds|bound=[3] pin=[]|a timeout with an inline comment arrives without the blanks before it
CA_VERIFY_TIMEOUT=3   |bound=[3] pin=[]|a timeout with trailing blanks arrives trimmed
HARBOR_CA_SHA256="AA:BB:CC"   # from the platform team|bound=[] pin=[AA:BB:CC]|a quoted pin with an inline comment arrives as the digest alone
HARBOR_CA_SHA256='AA:BB:CC'  |bound=[] pin=[AA:BB:CC]|a single-quoted pin with trailing blanks arrives as the digest alone
HARBOR_CA_SHA256=AA:BB:CC|bound=[] pin=[AA:BB:CC]|an ordinary pin is unchanged (control)
ENVROWS
  got="$(mkq 'CA_VERIFY_TIMEOUT="3"' CA_VERIFY_TIMEOUT=9)"
  if [ "$got" = 'bound=[9] pin=[]' ]; then ok "make, .env parse: a per-run value still wins over a quoted .env value"
  else bad "make, .env parse: a per-run value lost to a quoted .env value" "got '${got}'"; fi
  # A value that STILL cannot be used reaches the real script, which says so (once) and uses 15 s.
  mkdir -p "$MKS/bad"; printf 'CA_VERIFY_TIMEOUT=soon\n' > "$MKS/bad/.env"
  bad_out="$(env -u CA_VERIFY_TIMEOUT -u HARBOR_CA_SHA256 -u SKIP_DOTENV -u MAKEFLAGS -u MAKELEVEL -u MFLAGS TMPDIR="$T" \
               timeout -k 2 40 make --no-print-directory -f "${REPO}/Makefile" -C "$MKS/bad" fetch-harbor-ca SCRIPTS="${REPO}/scripts" \
                 HARBOR_URL="127.0.0.1:${P_DEAD}" HARBOR_CA_FILE="$T/out-bad.crt" 2>&1 </dev/null)"
  if [ "$(command grep -c "CA_VERIFY_TIMEOUT='soon' is not a usable time limit, so 15 s is used instead" <<< "$bad_out")" = 1 ] && has "$bad_out" 'could not connect to'; then
    ok "make -> the real fetch: an unusable CA_VERIFY_TIMEOUT in .env is reported once, and 15 s is used"
  else
    bad "make -> the real fetch: an unusable CA_VERIFY_TIMEOUT is replaced without one clear line" "$(printf '%s' "$bad_out" | head -3 | cut -c1-160)"
  fi
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "bound=[%%s]\\n" "${CA_VERIFY_TIMEOUT-UNSET}"\n' > "$MKS/stub/fetch-ca.sh"
  got="$(MK_ENV='CA_VERIFY_TIMEOUT=4' mk with-env fetch-harbor-ca)"
  if [ "$got" = 'bound=[4]' ]; then ok "make: a value exported in the shell wins over .env"
  else bad "make: a value exported in the shell must win over .env" "wanted 'bound=[4]', got '${got}'"; fi
else
  printf 'SKIP  make is not installed: cannot check that CA_VERIFY_TIMEOUT reaches the fetch targets\n'
fi

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
    # THE REAL Makefile, IN AN EMPTY SANDBOX DIRECTORY. `make -C "$REPO"` here read the checkout's
    # own .env at make level (make includes it relative to where it runs), so on an operator's
    # box this case parsed THEIR configuration. -f names the Makefile; -C gives it a directory
    # with no .env, no state overlay and nothing else; SCRIPTS points back at the real scripts.
    mkdir -p "$T/mk-n"
    recipe="$(env -u SKIP_DOTENV -u MAKEFLAGS -u MAKELEVEL -u MFLAGS -u VKS_STATE_FILE \
                bash -c "make --no-print-directory -f $(printf '%q' "$REPO/Makefile") -C $(printf '%q' "$T/mk-n") SCRIPTS=$(printf '%q' "$REPO/scripts") -n ${cmd#make }" 2>/dev/null | command grep -F '27-harbor-ca-from-cluster.sh' | head -1)"
    got="$(bash -c "printf '%s' ${recipe#*27-harbor-ca-from-cluster.sh }" 2>/dev/null)"
    if [ -n "$recipe" ] && [ "$got" = "$path" ]; then ok "advice: pasted, through make and the recipe's shell, the script receives ${path}"
    else bad "advice: the printed command does not deliver ${path} to the script" "printed '${cmd}'; recipe '${recipe}'; delivered '${got}'"; fi
  done
else
  printf 'SKIP  make is not installed: cannot run the printed harbor-ca-from-cluster line through it\n'
fi

# THE DATES MESSAGE IS ONE BODY WITH ONE WORD THAT VARIES. Harbor's text is pinned whole (the
# three date lines are data and are cut out); the Supervisor's must differ in that word only.
DATES_BODY="The CA file is the right one: with the dates ignored, it verifies the certificate
localhost presents. What fails is that certificate's validity period on this machine:
If the clock is wrong, correct it. If it is right, the certificate has expired or is not
valid yet, and whoever operates Harbor has to renew it. Do NOT replace the CA file."
no_dates() { command grep -vE '^    (valid from:|valid until:|this machine.s clock \(date -u\):)' <<< "$1"; }
adv_h="$(CA_VERIFY_TIMEOUT=5 harbor_cert_dates_advice localhost "$P_EXP")"
if [ "$(no_dates "$adv_h")" = "$DATES_BODY" ] && [ "$(command grep -c '' <<< "$adv_h")" = 7 ]; then
  ok "dates advice: Harbor's text is the pinned one, byte for byte (4 fixed lines + 3 data lines)"
else
  bad "dates advice: Harbor's text changed" "$(no_dates "$adv_h" | cut -c1-120)"
fi
adv_s="$(CA_VERIFY_TIMEOUT=5 tls_cert_dates_advice 'the Supervisor' localhost "$P_EXP")"
if [ "$(no_dates "$adv_s")" = "${DATES_BODY/operates Harbor has/operates the Supervisor has}" ] && ! has "$adv_s" 'Harbor'; then
  ok "dates advice: the Supervisor's text is the same body with its own name, and never says Harbor"
else
  bad "dates advice: the Supervisor's text is not the Harbor body with one name changed" "$(no_dates "$adv_s" | cut -c1-120)"
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
if has "$r_sup" 'Supervisor CA' && has "$r_sup" 'does NOT match localhost — this is a leftover certificate.' \
   && has "$r_sup" 'Get it again — this overwrites in place and cannot lose anything:  make fetch-supervisor-ca' \
   && ! has "$r_sup" 'Harbor' && ! has "$r_sup" "$DATES"; then
  ok "ca-status: the Supervisor CA under the WRONG CA still says leftover, with its own remedy and none of Harbor's (control)"
else
  bad "ca-status: the Supervisor CA's wrong-CA message changed, or Harbor's routes leaked into it" "$(printf '%s' "$r_sup" | tail -6)"
fi
# THE SUPERVISOR ROW ASKS ABOUT DATES TOO. This pin used to require the OPPOSITE (an expired
# certificate under the right CA printed "leftover" and `make fetch-supervisor-ca`, and the test
# held it there as "unchanged"). That sentence sent the reader to replace a correct CA, so the pin
# is turned round on purpose: right CA + wrong dates is the dates message, for both dates.
sup_report() {  # <port> <ca-file> ; echoes the report, sets nothing
  ( set +e
    unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
    SUPERVISOR_HOST="localhost:$1" VKS_CA_CERT_FILE="$2" CA_VERIFY_TIMEOUT=5 ca_status_report 2>&1 )
}
for row in "$P_EXP|2020|expired" "$P_NY|$(( $(date -u +%Y) + 6 ))|not valid yet"; do
  IFS='|' read -r port year what <<< "$row"
  r_supd="$(sup_report "$port" "$T/ca.crt")"
  assert_dates "ca-status, Supervisor CA, ${what}" "$r_supd" "$year"
  if has "$r_supd" "Supervisor CA ($T/ca.crt) is the right CA for localhost, but the certificate localhost presents is outside its dates." \
     && has "$r_supd" 'whoever operates the Supervisor has to renew it. Do NOT replace the CA file.' \
     && ! has "$r_supd" 'Harbor' && ! has "$r_supd" 'fetch-supervisor-ca'; then
    ok "ca-status, Supervisor CA, ${what}: names the Supervisor, not Harbor, and does not name make fetch-supervisor-ca"
  else
    bad "ca-status, Supervisor CA, ${what}: the dates message is missing, names Harbor, or still names the fetch" "$(printf '%s' "$r_supd" | tail -8 | cut -c1-170)"
  fi
  ( set +e; unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
    SUPERVISOR_HOST="localhost:${port}" VKS_CA_CERT_FILE="$T/ca.crt" CA_VERIFY_TIMEOUT=5 ca_status_report >/dev/null 2>&1 ); sup_rc=$?
  if [ "$sup_rc" = 1 ]; then ok "ca-status, Supervisor CA, ${what}: still counted as one problem (the exit status is unchanged)"
  else bad "ca-status, Supervisor CA, ${what}: the problem count changed" "ca_status_report returned ${sup_rc}, wanted 1"; fi
done
( set +e; unset HARBOR_URL HARBOR_CA_FILE CA_STATUS_STRICT
  SUPERVISOR_HOST="localhost:${P_LEAF}" VKS_CA_CERT_FILE="$T/old.crt" CA_VERIFY_TIMEOUT=5 ca_status_report >/dev/null 2>&1 ); sup_rc=$?
if [ "$sup_rc" = 1 ]; then ok "ca-status, Supervisor CA, wrong CA: one problem (control)"
else bad "ca-status, Supervisor CA, wrong CA: the problem count changed" "returned ${sup_rc}, wanted 1"; fi
# Both pairs at once, both with wrong dates: two problems, each message with its own name.
r_both="$( set +e; unset CA_STATUS_STRICT
           HARBOR_URL="localhost:${P_EXP}" HARBOR_CA_FILE="$T/ca.crt" SUPERVISOR_HOST="localhost:${P_NY}" VKS_CA_CERT_FILE="$T/ca.crt" \
             CA_VERIFY_TIMEOUT=5 ca_status_report 2>&1 )"
( set +e; unset CA_STATUS_STRICT
  HARBOR_URL="localhost:${P_EXP}" HARBOR_CA_FILE="$T/ca.crt" SUPERVISOR_HOST="localhost:${P_NY}" VKS_CA_CERT_FILE="$T/ca.crt" \
    CA_VERIFY_TIMEOUT=5 ca_status_report >/dev/null 2>&1 ); both_rc=$?
if [ "$both_rc" = 2 ] && [ "$(command grep -cF 'whoever operates Harbor has to renew it' <<< "$r_both")" = 1 ] \
   && [ "$(command grep -cF 'whoever operates the Supervisor has to renew it' <<< "$r_both")" = 1 ]; then
  ok "ca-status: Harbor and the Supervisor both outside their dates -> two problems, each named once"
else
  bad "ca-status: two pairs with wrong dates are not two separately named problems" "rc=${both_rc}"
fi

# A PATH WITH A `|` IN IT, AND ONE WITH A SPACE. The report's fields were separated by `|`, so
# HARBOR_CA_FILE=/x/a|b/ca.crt was read as file `/x/a`, host `b/ca.crt`: the message named a file
# nobody configured and a host that is not one. Every arm below must name the WHOLE path.
mkdir -p "$T/a|b" "$T/my lab"
for dir in "$T/a|b" "$T/my lab"; do
  cp "$T/ss.crt" "$dir/ss.crt"; cp "$T/old.crt" "$dir/old.crt"; cp "$T/ca.crt" "$dir/ca.crt"
  what="a path holding '${dir#"$T"/}'"
  r_p="$(status_report "$P_SS" "" "$dir/ss.crt")"
  if has "$r_p" "Harbor CA ($dir/ss.crt) matches localhost"; then ok "ca-status, ${what}: a matching CA is reported with its whole path"
  else bad "ca-status, ${what}: the matching CA is not reported with its path" "$(printf '%s' "$r_p" | tail -3 | cut -c1-170)"; fi
  r_p="$(status_report "$P_LEAF" "" "$dir/old.crt")"
  assert_leaf_only "ca-status, ${what}" "$r_p" "$dir/old.crt" "$CLUSTER HARBOR_CA_FILE=$(printf '%q' "$dir/old.crt")"
  if has "$r_p" "Harbor CA ($dir/old.crt) does NOT match localhost — this is a leftover certificate."; then
    ok "ca-status, ${what}: the leftover line names the whole path and the real host"
  else
    bad "ca-status, ${what}: the leftover line names a wrong file or host" "$(command grep -F 'Harbor CA' <<< "$r_p" | cut -c1-170)"
  fi
  r_p="$(status_report "$P_SS" "" "$dir/no-such.crt")"
  if has "$r_p" "Harbor CA ($dir/no-such.crt) is missing or empty." && has "$r_p" 'Try  make fetch-harbor-ca  —'; then
    ok "ca-status, ${what}: a missing file is named with its whole path, with Harbor's command"
  else
    bad "ca-status, ${what}: the missing-file line names a wrong file or command" "$(printf '%s' "$r_p" | tail -3 | cut -c1-170)"
  fi
  r_p="$(sup_report "$P_EXP" "$dir/ca.crt")"
  if has "$r_p" "Supervisor CA ($dir/ca.crt) is the right CA for localhost,"; then ok "ca-status, ${what}: the Supervisor pair reads the path whole too"
  else bad "ca-status, ${what}: the Supervisor pair mis-reads the path" "$(printf '%s' "$r_p" | tail -3 | cut -c1-170)"; fi
done
# An ordinary host with a port, a scheme and a path still splits into host and port (the split
# of `host|port` moved; this pins that it still lands the same).
r_p="$( set +e; unset VKS_CA_CERT_FILE SUPERVISOR_HOST CA_STATUS_STRICT
        HARBOR_URL="https://localhost:${P_SS}/harbor" HARBOR_CA_FILE="$T/ss.crt" CA_VERIFY_TIMEOUT=5 ca_status_report 2>&1 )"
if has "$r_p" "Harbor CA ($T/ss.crt) matches localhost"; then ok "ca-status: HARBOR_URL with a scheme, a port and a path still reaches the right host and port"
else bad "ca-status: the host/port split changed" "$(printf '%s' "$r_p" | tail -2 | cut -c1-170)"; fi

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
  [ -z "${CREDS_EXTRA_ENV:-}" ] || printf '%s\n' "$CREDS_EXTRA_ENV" >> "$t/.env"
  ( cd "$t" && env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u HARBOR_INSECURE \
      PATH="$t/bin:${4:+$4:}$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      CREDS_NO_PROBE=0 CREDS_TOKEN=1 CREDS_PROBE_TIMEOUT_SECONDS="${5:-5}" \
      timeout -k 2 45 "${REPO}/scripts/creds.sh" 2>"$t/stderr" )
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

# AN ADDRESS IS NEVER SHELL TEXT. The ingress address and the ArgoCD address come from a state
# file or a cluster; the report used to paste them into `bash -c "exec 3<>/dev/tcp/…"`, where a
# value of $(command) runs. Single-quoted in .env so that loading the file does not run it either.
# The report runs with its sandbox as the working directory: a canary would land there.
# shellcheck disable=SC2016
c_inj="$(CREDS_EXTRA_ENV='INGRESS_LB_IP='"'"'$(touch canary-ingress)'"'"'
ARGOCD_SERVER='"'"'$(touch canary-argocd)'"'"'' creds_render "$T/c-inj" "localhost:$P_SS" "$T/ss.crt")"
if has "$c_inj" 'canary-ingress' && [ ! -e "$T/c-inj/canary-ingress" ] && [ ! -e "$T/c-inj/canary-argocd" ]; then
  ok "creds: an ingress address and an ArgoCD address of \$(touch …) are probed as text and run nothing (no canary)"
else
  bad "creds: an address from the state was EXECUTED (or the fixture never reached the report)" \
      "value shown in the report: $(has "$c_inj" 'canary-ingress' && echo yes || echo no); created: $(find "$T/c-inj" -maxdepth 1 -name 'canary-*' 2>/dev/null | tr '\n' ' ')"
fi

# AN ADDRESS THAT CANNOT BE USED STOPS EVERY OTHER SCRIPT; THE REPORT GOES ON AND SAYS THE TRUTH.
# `make creds` is what a reader runs to find out what is wrong, so it must still print, exit 0,
# and say the variable is SET and not used — not that it is "not set" — without showing it.
c_ref="$(CREDS_EXTRA_ENV="HARBOR_URL='admin:4411/SEKR@localhost'" creds_render "$T/c-ref" "localhost:$P_SS" "$T/ss.crt")"; c_ref_rc=$?
if [ "$c_ref_rc" = 0 ] && has "$c_ref" 'NOTE: HARBOR_URL is SET in .env but NOT USED' && has "$c_ref" 'Context' \
   && ! has "$c_ref" 'SEKR' && ! has "$c_ref" '4411' && ! command grep -qF -e 'SEKR' -e '4411' "$T/c-ref/stderr" \
   && [ "$(command grep -c 'HARBOR_URL is set, and it cannot be used' "$T/c-ref/stderr")" = 1 ]; then
  ok "creds: an unusable HARBOR_URL does not stop the report: exit 0, a NOTE says it is set and not used, the value is in neither stdout nor stderr"
else
  bad "creds: an unusable HARBOR_URL stopped the report, was called 'not set' with no note, or was printed" "rc=${c_ref_rc}; note: $(has "$c_ref" 'NOT USED' && echo yes || echo no); leaked: $( { has "$c_ref" 'SEKR' || command grep -qF 'SEKR' "$T/c-ref/stderr"; } && echo YES || echo no)"
fi

# THE REPORT'S OWN TIME LIMITS. CREDS_PROBE_TIMEOUT_SECONDS=0 used to reach `timeout` as 0 (no
# limit); the first clamp then made it the default without a word. It is replaced, and SAID.
c_zero="$(creds_render "$T/c-zero" "localhost:$P_SS" "$T/ss.crt" "" 0)"
if has "$c_zero" 'Harbor' && [ "$(command grep -c "CREDS_PROBE_TIMEOUT_SECONDS='0' is not a usable time limit, so 2 s is used instead" "$T/c-zero/stderr")" = 1 ] \
   && [ "$(command grep -c 'is not a usable time limit' "$T/c-zero/stderr")" = 1 ]; then
  ok "creds: CREDS_PROBE_TIMEOUT_SECONDS=0 is replaced by 2 s and reported once on stderr; the report still renders"
else
  bad "creds: an unusable CREDS_PROBE_TIMEOUT_SECONDS is not reported exactly once" "$(command grep -c 'CREDS_PROBE_TIMEOUT_SECONDS' "$T/c-zero/stderr" 2>/dev/null) line(s): $(command grep -m1 'CREDS_PROBE' "$T/c-zero/stderr" 2>/dev/null | cut -c1-140)"
fi
c_sfx="$(creds_render "$T/c-sfx" "localhost:$P_SS" "$T/ss.crt" "" 5s)"
if has "$c_sfx" 'Harbor' && ! command grep -q 'is not a usable time limit' "$T/c-sfx/stderr"; then
  ok "creds: CREDS_PROBE_TIMEOUT_SECONDS=5s is accepted (no warning)"
else
  bad "creds: a unit suffix on CREDS_PROBE_TIMEOUT_SECONDS is refused" "$(command grep -m1 'usable time limit' "$T/c-sfx/stderr" | cut -c1-140)"
fi

# THE ArgoCD BULLET ASKS ABOUT DATES TOO (it said "does NOT verify this address — re-fetch it").
# The bullet is printed for a bare-IP address with ARGOCD_CA_FILE set; the listeners carry IP:127.0.0.1.
c_adates="$(CREDS_EXTRA_ENV="ARGOCD_SERVER=127.0.0.1:${P_EXP}
ARGOCD_CA_FILE=$T/ca.crt" creds_render "$T/c-adates" "localhost:$P_SS" "$T/ss.crt")"
if has "$c_adates" "- ArgoCD CLI: the CA at $T/ca.crt is the right one; the certificate ArgoCD serves is outside its dates." \
   && has "$c_adates" 'whoever operates ArgoCD has to renew it. Do NOT replace the CA file.' \
   && ! has "$c_adates" 'does NOT verify this address'; then
  ok "creds, ArgoCD: an expired certificate under the right CA -> the dates text, for ArgoCD; not 're-fetch it'"
else
  bad "creds, ArgoCD: an expired certificate is still 'does NOT verify this address — re-fetch it' (or the bullet was not reached)" "$(command grep -F -A2 -- '- ArgoCD CLI' <<< "$c_adates" | cut -c1-170)"
fi
c_acad="$(CREDS_EXTRA_ENV="ARGOCD_SERVER=127.0.0.1:${P_LEAF}
ARGOCD_CA_FILE=$T/caexp.crt" creds_render "$T/c-acad" "localhost:$P_SS" "$T/ss.crt")"
if has "$c_acad" "- ArgoCD CLI: the CA at $T/caexp.crt is itself outside its dates, so it cannot verify ArgoCD." \
   && has "$c_acad" 'The CA file itself is outside its validity period on this machine:' && ! has "$c_acad" 'Do NOT replace the CA file'; then
  ok "creds, ArgoCD: an out-of-date CA FILE -> the file's own dates and make fetch-argocd-ca; never 'do NOT replace'"
else
  bad "creds, ArgoCD: an out-of-date CA file is not reported as such" "$(command grep -F -A2 -- '- ArgoCD CLI' <<< "$c_acad" | cut -c1-170)"
fi
c_awrong="$(CREDS_EXTRA_ENV="ARGOCD_SERVER=127.0.0.1:${P_LEAF}
ARGOCD_CA_FILE=$T/old.crt" creds_render "$T/c-awrong" "localhost:$P_SS" "$T/ss.crt")"
if has "$c_awrong" "- ArgoCD CLI: the CA at $T/old.crt does NOT verify this address — re-fetch it:" && ! has "$c_awrong" 'outside its dates'; then
  ok "creds, ArgoCD: the WRONG CA still says 'does NOT verify this address — re-fetch it' (control)"
else
  bad "creds, ArgoCD: the wrong-CA bullet changed" "$(command grep -F -A2 -- '- ArgoCD CLI' <<< "$c_awrong" | cut -c1-170)"
fi

# EVERY SCRIPT THAT ASKS "does this CA verify this endpoint" ALSO ASKS THE DATES QUESTION. A
# "connected, and it does not verify" (1) is three different faults (wrong CA, an expired server
# certificate, an expired CA file) and only the second question tells them apart. Derived by
# grep, not from a list: a new caller that reports a bare 1 as "wrong CA" fails here.
# What this does NOT check is what each one PRINTS: the sites with a case above are the reports,
# the fetch and the login; the installer-side ones are held only by this line.
askers="$(command grep -rlE --include='*.sh' -- '(^|[^A-Za-z_#])ca_verifies_endpoint "' "${REPO}/scripts" \
            | command grep -vE '/scripts/test-[^/]*\.sh$|/scripts/lib/tls\.sh$' | sort)"
n_askers="$(command grep -c . <<< "$askers" || true)"
no_dates=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  command grep -qE '(^|[^A-Za-z_#])(ca_endpoint_dates_only|supervisor_anchor_verdict) ' "$f" || no_dates="${no_dates} ${f##*/}"
done <<< "$askers"
if [ -z "$no_dates" ] && [ "${n_askers:-0}" -ge 8 ]; then
  ok "every script that calls ca_verifies_endpoint also asks the dates question (${n_askers} scripts)"
else
  bad "a script reports a failed CA check without asking whether dates are the cause (or the scan found too few)" "scripts found: ${n_askers:-0}; without the dates question:${no_dates:- none}"
fi

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

# ══ 6b. the CA FILE's own dates (all four sites) ══════════════════════════════════════════════════════════════
# caexp.crt / cany.crt are ca.crt's key and subject with dates that are wrong today. The server
# (leaf.crt) is VALID. Ignoring dates, the file verifies it; "dates only, the CA is right, do NOT
# replace it" was what every site printed, and replacing that file is the fix.
CA_DATES='The CA file itself is outside its validity period on this machine:'
CA_REPLACE='If the clock is wrong, correct it. If it is right, replace the file with the current CA:'
for row in "2|$P_LEAF|$T/caexp.crt|an EXPIRED CA file over a valid certificate" "2|$P_LEAF|$T/cany.crt|a NOT-YET-VALID CA file over a valid certificate" \
           "2|$P_EXP|$T/caexp.crt|an expired CA file over an expired certificate (the file comes first)"; do
  IFS='|' read -r want port ca what <<< "$row"
  r=0; CA_VERIFY_TIMEOUT=5 ca_endpoint_dates_only localhost "$port" "$ca" || r=$?
  if [ "$r" = "$want" ]; then ok "ca_endpoint_dates_only: ${what} -> ${r}"
  else bad "ca_endpoint_dates_only: ${what}" "wanted ${want}, got ${r}"; fi
done
for row in "0|$T/ca.crt|a CA file in date" "1|$T/caexp.crt|an expired CA file" "1|$T/cany.crt|a CA file not valid yet" \
           "0|$T/garbage.crt|a file that is not a certificate (no claim)" "0|$T/no-such.crt|a missing file (no claim)"; do
  IFS='|' read -r want ca what <<< "$row"
  r=0; tls_ca_file_in_dates "$ca" || r=$?
  if [ "$r" = "$want" ]; then ok "tls_ca_file_in_dates: ${what} -> ${r}"
  else bad "tls_ca_file_in_dates: ${what}" "wanted ${want}, got ${r}"; fi
done
# A BUNDLE makes no claim about its own dates: [expired old CA, valid current CA] over an EXPIRED
# server certificate is the server's dates (6), never "replace the CA file" (7).
cat "$T/caexp.crt" "$T/ca.crt" > "$T/bundle-exp-first.crt"
r=0; tls_ca_file_in_dates "$T/bundle-exp-first.crt" || r=$?
if [ "$r" = 0 ]; then ok "tls_ca_file_in_dates: a bundle whose FIRST certificate is expired makes no claim -> 0"
else bad "tls_ca_file_in_dates: a bundle whose first certificate is expired" "wanted 0, got ${r}"; fi
r=0; CA_VERIFY_TIMEOUT=5 supervisor_anchor_verdict localhost "$T/bundle-exp-first.crt" "$P_EXP" || r=$?
if [ "$r" = 6 ]; then ok "supervisor_anchor_verdict: [expired CA, valid CA] over an expired certificate -> 6, the server's dates"
else bad "supervisor_anchor_verdict: [expired CA, valid CA] over an expired certificate" "wanted 6, got ${r}"; fi
for row in "7|$P_LEAF|$T/caexp.crt|an expired CA file" "7|$P_LEAF|$T/cany.crt|a CA file not valid yet" "6|$P_EXP|$T/ca.crt|an expired certificate under a CA in date" \
           "6|$P_NY|$T/ca.crt|a not-yet-valid certificate under a CA in date" "1|$P_LEAF|$T/old.crt|the wrong CA" "0|$P_LEAF|$T/ca.crt|the right CA, all in date"; do
  IFS='|' read -r want port ca what <<< "$row"
  r=0; CA_VERIFY_TIMEOUT=5 supervisor_anchor_verdict localhost "$ca" "$port" || r=$?
  if [ "$r" = "$want" ]; then ok "supervisor_anchor_verdict: ${what} -> ${r}"
  else bad "supervisor_anchor_verdict: ${what}" "wanted ${want}, got ${r}"; fi
done
# assert_ca_dates <site> <text> <year the FILE's dates must show>
assert_ca_dates() {
  local s="$1" t="$2" year="$3" bad_p="" p
  for p in 'Do NOT replace the CA file' 'leftover certificate' 'is the right CA for' 'is the RIGHT one' 'is the right one;' 'DIFFERENT (usually a' 'does NOT verify' 'has to renew it'; do
    has "$t" "$p" && bad_p="${bad_p} [${p}]"
  done
  if has "$t" "$CA_DATES" && has "$t" "$CA_REPLACE" && [ -z "$bad_p" ]; then
    ok "${s} / CA file dates: says the FILE is outside its dates and to replace it; never 'do NOT replace', 'leftover' or 'the right CA'"
  else
    bad "${s} / CA file dates: the wrong sentence is printed over an out-of-date CA file" "has the CA-dates text: $(has "$t" "$CA_DATES" && echo yes || echo no); forbidden:${bad_p:- none}"
  fi
  if command grep -F 'valid from:' <<< "$t" | command grep -qF -- "$year" \
     && command grep -F 'valid until:' <<< "$t" | command grep -qE '[0-9]{4} GMT' \
     && command grep -F '(date -u):' <<< "$t" | command grep -qF -- "$(date -u +%Y)"; then
    ok "${s} / CA file dates: shows the FILE's two dates (not the server's) and this machine's UTC clock"
  else
    bad "${s} / CA file dates: the file's dates or the clock are missing" "$(command grep -F -e 'valid ' -e 'date -u' <<< "$t" | cut -c1-120)"
  fi
}
NY_YEAR="$(( $(date -u +%Y) + 5 ))"
for row in "caexp|2020|expired" "cany|${NY_YEAR}|not valid yet"; do
  IFS='|' read -r cf year what <<< "$row"
  # make ca-status, Harbor. This Harbor sends one certificate, so the routes are the not-sent ones.
  r_c="$(status_report "$P_LEAF" "" "$T/$cf.crt")"
  assert_ca_dates "ca-status, Harbor, CA file ${what}" "$r_c" "$year"
  if has "$r_c" "Harbor CA ($T/$cf.crt) is itself outside its dates, so it cannot verify localhost." && has "$r_c" "$NOT_WIRE" \
     && [ "$(line_after "$r_c" "$ADMIN")" = "$CLUSTER HARBOR_CA_FILE=$T/$cf.crt" ]; then
    ok "ca-status, Harbor, CA file ${what}: names the file, then Harbor's routes for a CA that is not sent"
  else
    bad "ca-status, Harbor, CA file ${what}: the headline or the routes are missing" "$(printf '%s' "$r_c" | head -2 | cut -c1-170)"
  fi
  ( set +e; unset VKS_CA_CERT_FILE SUPERVISOR_HOST CA_STATUS_STRICT
    HARBOR_URL="localhost:$P_LEAF" HARBOR_CA_FILE="$T/$cf.crt" CA_VERIFY_TIMEOUT=5 ca_status_report >/dev/null 2>&1 ); c_rc=$?
  if [ "$c_rc" = 1 ]; then ok "ca-status, Harbor, CA file ${what}: one problem (the exit status is unchanged)"
  else bad "ca-status, Harbor, CA file ${what}: the problem count changed" "returned ${c_rc}, wanted 1"; fi
  # make ca-status, Supervisor: its own fetch target, none of Harbor's routes.
  r_c="$(sup_report "$P_LEAF" "$T/$cf.crt")"
  assert_ca_dates "ca-status, Supervisor, CA file ${what}" "$r_c" "$year"
  if has "$r_c" "Supervisor CA ($T/$cf.crt) is itself outside its dates, so it cannot verify localhost." \
     && has "$r_c" 'Get it again — this overwrites in place and cannot lose anything:  make fetch-supervisor-ca' && ! has "$r_c" 'Harbor'; then
    ok "ca-status, Supervisor, CA file ${what}: names the file and make fetch-supervisor-ca, nothing of Harbor's"
  else
    bad "ca-status, Supervisor, CA file ${what}: the headline or the remedy is wrong" "$(printf '%s' "$r_c" | tail -3 | cut -c1-170)"
  fi
  # make env-validate
  v_c="$(validate "$P_LEAF" "" "$T/$cf.crt")"
  assert_ca_dates "env-validate, CA file ${what}" "$v_c" "$year"
  if has "$v_c" "the CA at $T/$cf.crt is itself outside its dates, so it cannot verify the certificate 127.0.0.1:${P_LEAF} presents." \
     && has "$v_c" "$NOT_WIRE" && has "$v_c" 'env-validate: ' && has "$v_c" 'problem(s)'; then
    ok "env-validate, CA file ${what}: names the file, gives Harbor's routes, and is still an error"
  else
    bad "env-validate, CA file ${what}: the headline, the routes or the error count is missing" "$(printf '%s' "$v_c" | tail -4 | cut -c1-170)"
  fi
  # make creds
  c_c="$(creds_render "$T/c-$cf" "localhost:$P_LEAF" "$T/$cf.crt")"
  assert_ca_dates "creds, CA file ${what}" "$c_c" "$year"
  if has "$c_c" "- Harbor: the CA at $T/c-$cf/secrets/harbor-ca.crt is itself outside its dates, so it cannot verify Harbor." && has "$c_c" "$NOT_WIRE"; then
    ok "creds, CA file ${what}: names the file, then Harbor's routes"
  else
    bad "creds, CA file ${what}: the bullet or the routes are missing" "$(command grep -F -A3 -- '- Harbor' <<< "$c_c" | cut -c1-170)"
  fi
done
# The same out-of-date CA file where Harbor DOES send its CA: the fetch is the route, named bare.
r_c="$(status_report "$P_CHAIN" "" "$T/caexp.crt")"
assert_ca_dates "ca-status, Harbor sends its CA, CA file expired" "$r_c" 2020
if has "$r_c" 'Get it again — this overwrites in place and cannot lose anything:  make fetch-harbor-ca' && ! has "$r_c" "$NOT_WIRE"; then
  ok "ca-status, Harbor sends its CA, CA file expired: the route is make fetch-harbor-ca"
else
  bad "ca-status, Harbor sends its CA, CA file expired: the fetch is not named" "$(printf '%s' "$r_c" | tail -2 | cut -c1-170)"
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
  elif command grep -qxF 'openssl x509 -in ./secrets/harbor-ca.download.crt -noout -fingerprint -sha256' "$DOC"; then
    ok "scenario-1 Step 8 compares the certificate fingerprint, the number the scripts print (of the DOWNLOAD)"
  else
    bad "scenario-1 Step 8 has no fingerprint command for the Harbor CA" "expected the openssl x509 -fingerprint -sha256 line"
  fi
  # THE ORDER OF STEP 8's MAIN FLOW: keep the download aside, print ITS fingerprint, and only after
  # that install it where everything trusts it; then make ca-status. The flow used to install to
  # ./secrets/harbor-ca.crt first and print the fingerprint of the installed file afterwards.
  # The first pattern is the doc's own line, `$tmp` and all (SC2016 is deliberate).
  # shellcheck disable=SC2016
  d_keep="$(command grep -nF 'install -m0644 "$tmp/ca.crt" ./secrets/harbor-ca.download.crt' "$DOC" | head -1 | cut -d: -f1)"
  d_fp="$(command grep -nxF 'openssl x509 -in ./secrets/harbor-ca.download.crt -noout -fingerprint -sha256' "$DOC" | head -1 | cut -d: -f1)"
  d_inst="$(command grep -nxF 'install -m0644 ./secrets/harbor-ca.download.crt ./secrets/harbor-ca.crt' "$DOC" | head -1 | cut -d: -f1)"
  d_stat="$(command grep -nxF 'make ca-status' "$DOC" | awk -F: -v a="${d_inst:-0}" '$1 > a { print $1; exit }')"
  # shellcheck disable=SC2016
  if [ -n "$d_keep" ] && [ -n "$d_fp" ] && [ -n "$d_inst" ] && [ -n "$d_stat" ] \
     && [ "$d_keep" -lt "$d_fp" ] && [ "$d_fp" -lt "$d_inst" ] && [ "$d_inst" -lt "$d_stat" ] \
     && ! command grep -qF 'install -m0644 "$tmp/ca.crt" ./secrets/harbor-ca.crt' "$DOC"; then
    ok "scenario-1 Step 8: download kept aside, its fingerprint printed, THEN installed, then make ca-status (lines ${d_keep} < ${d_fp} < ${d_inst} < ${d_stat})"
  else
    bad "scenario-1 Step 8 installs the downloaded CA before its fingerprint is printed (or a step is missing)" "keep=${d_keep:-none} fingerprint=${d_fp:-none} install=${d_inst:-none} ca-status=${d_stat:-none}"
  fi
  # THE FIRST FENCE STARTS BY REMOVING AN EARLIER DOWNLOAD (a failed run must not leave the old
  # file for the fingerprint step to print), and NO FENCE OF STEP 8 CARRIES A COMMENT LINE: in an
  # interactive zsh a pasted `# …` line is a command, and two of them were in this block.
  step8="$(awk '/^## 8\. /{s=1; next} s && /^## /{exit} s' "$DOC")"
  first_cmd="$(awk '/^```bash/{f=1; next} f{print; exit}' <<< "$step8")"
  fence_comments="$(awk '/^```bash/{f=1; next} /^```/{f=0} f && /^[[:space:]]*#/' <<< "$step8")"
  n_fences="$(command grep -c '^```bash' <<< "$step8" || true)"
  if [ "$first_cmd" = 'rm -f ./secrets/harbor-ca.download.crt' ] && [ -z "$fence_comments" ] && [ "${n_fences:-0}" -ge 4 ]; then
    ok "scenario-1 Step 8: the first fence begins by removing an earlier download, and none of its ${n_fences} fences holds a comment line"
  else
    bad "scenario-1 Step 8: a stale download can survive, or a fence carries a comment line (it breaks a paste into zsh)" "first command: '${first_cmd}'; comment lines in fences: $(command grep -c . <<< "$fence_comments")"
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
