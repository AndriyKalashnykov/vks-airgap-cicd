#!/usr/bin/env bash
# ci-tier: fast — offline; a throwaway HTTP responder on 127.0.0.1, no cluster, no network.
#
# B528: `make creds` printed `serving` for a route whose BACKEND was dead. MEASURED on the live lab
# with every app pod in ImagePullBackOff: javawebapp.vks.local answered HTTP 503 and the report said
# `serving`. The `_ing_live` TCP probe is shared by every ingress-backed row and cannot see a
# backend, but `serving` is a claim ABOUT THE BACKEND — the reader clicks a URL the report promised
# works and gets an error page.
#
# THE POINT OF THESE CASES IS DISCRIMINATION, not "does it say serving". A verdict that cannot tell
# 503 from 404 sends the reader to the wrong place: 503 means "run the pipeline" (the normal state
# after install-all, which builds no app image — B529), while 404 means the ingress does not know
# this host, i.e. a rendering/attach fault.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract by function name up to its closing brace at column 0 — deliberately NOT a line range, so a
# shifted file cannot silently yield a fragment. An empty extraction is a HARD FAILURE: a test that
# passes over an empty function is worse than no test.
# ⚠️ EXTRACT ITS DEPENDENCIES TOO, AND GUARD EACH ONE SEPARATELY. This suite went 21/21 -> 12/9
# the moment _reach_ingress grew a call to _ing_authority (B560, #1165): the extraction pulled the
# body and not the helper, so 13 cases died on `_ing_authority: command not found` and every route
# status collapsed to `silent` -- the "false dead" creds.sh:173 calls THE RISK TO AVOID. Production
# was never affected (the helper is defined above both call sites); only this suite was.
# The FATAL guard below did not fire because it tests for "printf 'serving'", which is still in the
# extracted text -- a content guard is structurally blind to a NEW DEPENDENCY. So each extraction
# gets its own non-empty check, and adding a dependency here is a one-line change with a loud
# failure rather than a silent 9-case collapse.
_extract() {  # _extract <fn-name> -> its source, or die
  local _n="$1" _o
  # index()==1, not a dynamic regex: `_ing_authority() {` is full of ERE metacharacters, and
  # building the pattern in the shell produced `awk: warning: escape sequence \( treated as plain (`
  # on gawk -- a warning, not an error, so it would have degraded silently on another awk.
  _o="$(awk -v f="${_n}() {" 'index($0,f)==1{p=1} p{print} p&&/^\}/{exit}' "${REPO_ROOT}/scripts/creds.sh")"
  [ -n "$_o" ] || { echo "FATAL: could not extract ${_n}() from scripts/creds.sh — renamed or reshaped."
                    echo "       Fix the extraction; do NOT let this test pass over an empty function."; exit 1; }
  printf '%s' "$_o"
}
_helpers="$(_extract _ing_authority)"
_fn="$(_extract _reach_ingress)"
case "$_fn" in
  *"printf 'serving'"*) : ;;
  *) echo "FATAL: _reach_ingress extracted but does not contain \`printf 'serving'\` — reshaped."
     echo "       Fix the extraction; do NOT let this test pass over a fragment."; exit 1 ;;
esac
case "$_helpers" in
  *'INGRESS_PROBE_PORT'*) : ;;
  *) echo "FATAL: _ing_authority extracted but does not read INGRESS_PROBE_PORT — reshaped."; exit 1 ;;
esac
_fn="${_helpers}
${_fn}"

# ⚠️ AND A GUARD FOR THE *NEXT* ONE. The per-extraction non-empty checks above catch a RENAME; they
# are structurally blind to a NEW DEPENDENCY -- which is the defect that took this suite 21/21 ->
# 12/9 (#1165), and the same blindness the old content guard had. So: scan what we extracted for
# calls to functions creds.sh defines but we did NOT extract, and die naming them. Adding a
# dependency then costs one line here with a loud failure, instead of nine silent collapses.
_defined="$(grep -oE '^[a-z_][a-z0-9_]*\(\) \{' "${REPO_ROOT}/scripts/creds.sh" | sed 's/() {//' | sort -u)"
_missing=""
for _d in $_defined; do
  case "$_fn" in
    *"${_d}()"*) continue ;;                       # it IS one of the functions we extracted
  esac
  # A call is the name at a command position: line start, or after ( | && || ; $( -- not a substring
  # of a longer identifier, and not inside a word.
  if grep -qE "(^|[;&|(]|\\$\()[[:space:]]*${_d}([[:space:]]|\)|;|\||\$)" <<< "$_fn"; then
    _missing="${_missing} ${_d}"
  fi
done
if [ -n "$_missing" ]; then
  echo "FATAL: the extracted code calls creds.sh function(s) that were NOT extracted:${_missing}"
  echo "       That is exactly how this suite went 21/21 -> 12/9 (#1165): _reach_ingress grew a call"
  echo "       to _ing_authority and the extraction did not pull it, so every route status collapsed"
  echo "       to 'silent'. Add it to the _extract list above."
  exit 1
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

# A responder that returns whatever status the request's Host asks for, so one server covers every
# case and the test never depends on a real ingress.
cat > "$T/srv.py" <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get('Host', '')
        code = 200
        for tok, c in (('c503', 503), ('c404', 404), ('c302', 302), ('c418', 418),
                       ('c401', 401), ('c403', 403)):
            if tok in host: code = c
        self.send_response(code); self.send_header('Content-Length', '0'); self.end_headers()
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    s.serve_forever()
PY
python3 "$T/srv.py" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port")"
[ -n "$PORT" ] || { echo "FATAL: the responder never reported a port"; exit 1; }

# ⚠️ THE DNS ARM RUNS BEFORE THE HTTP ARM, and none of these test hosts resolve — so without this
# every HTTP case returns `no DNS here` and the suite measures nothing. (It did: 6 of 10 failed that
# way on the first run. The instrument, not the product.) A fake `getent` isolates the arm under
# test; the DNS arm keeps its own case below, with the stub removed from PATH.
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/getent"; chmod +x "$T/bin/getent"
_REAL_PATH="$PATH"
export PATH="$T/bin:$PATH"

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%q want=%q)\n' "$1" "$2" "$3"; fi; }

probe() { # probe <host> ; runs the REAL extracted function
  ( eval "$_fn"
    _ing="127.0.0.1:${PORT}"; _ing_live=1
    CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress "$1" )
}

# Positive control FIRST: if a healthy host does not read `serving`, every case below is meaningless.
ck "control: a 200 backend reads serving"        "$(probe ok.local)"   "serving"
# The discriminating cases — this is the defect.
ck "503 -> no backend (NOT serving: the B528 defect)" "$(probe c503.local)" "no backend"
ck "404 -> no route (a rendering fault, not a dead pod)" "$(probe c404.local)" "no route"
ck "302 -> serving (a redirect IS a working route)"   "$(probe c302.local)" "serving"
ck "an unexpected status is REPORTED, not swallowed"  "$(probe c418.local)" "HTTP 418"

# ── F6: an auth challenge is the STRONGEST confirmation this row's URL works ────────────────────
# 401/403 proves the route resolved AND a live app answered AND it wants the very credential
# printed beside it. They used to fall into the `HTTP %s` catch-all and read as an anomaly.
ck "401 -> serving (an auth challenge means the app ANSWERED)" "$(probe c401.local)" "serving"
ck "403 -> serving (ditto — the backend is up)"                "$(probe c403.local)" "serving"

# ── F2: THE PORT, in the shape PRODUCTION actually produces ─────────────────────────────────────
# ⚠️ `probe` above sets `_ing=127.0.0.1:$PORT` — a shape creds.sh NEVER produces (`_ing` is
# `${INGRESS_LB_IP}`, a BARE IP) — which is exactly why 14/14 passed while the route probe
# hardcoded port 80 and the TCP gate honoured INGRESS_PROBE_PORT. This case uses the real shape.
# RED-PROOF: revert the `_u`/`case` lines in _reach_ingress and this returns `silent`.
probe_bare() { # bare `_ing` + the documented port knob, i.e. what creds.sh really passes
  ( eval "$_fn"
    _ing="127.0.0.1"; _ing_live=1
    CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 INGRESS_PROBE_PORT="$PORT" _reach_ingress "$1" )
}
ck "bare-IP ingress + INGRESS_PROBE_PORT -> serving (not a false 'silent')" \
   "$(probe_bare ok.local)" "serving"

# ── F3: one dead route must not cost eight more timeouts ────────────────────────────────────────
# Every ingress row targets the SAME LB, so after one HTTP probe fails to complete the rest will
# too. MEASURED: 9 rows serial at the 2s default = 18.1s; 1.0s once the first stops the rest.
# `LB up` is what this function already says when it cannot ask about a route — not a new meaning.
_sc="$T/route-dead"
ck "after a 000 the sentinel is SET (the first row still says silent)" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:1"; _ing_live=1; _route_dead="$_sc"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=1 _reach_ingress dead.local ) )" "silent"
ck "the sentinel file was created" "$( [ -e "$_sc" ] && echo yes || echo no )" "yes"
ck "a LATER row short-circuits to LB up instead of timing out again" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:${PORT}"; _ing_live=1; _route_dead="$_sc"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress ok.local ) )" "LB up"
ck "with NO sentinel the same row probes normally (the short-circuit is not always-on)" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:${PORT}"; _ing_live=1; _route_dead="$T/never-created"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress ok.local ) )" "serving"

# The short-circuits must still win, or the probe would run where the report promised it would not.
ck "CREDS_NO_PROBE=1 short-circuits"  \
   "$(eval "$_fn"; CREDS_NO_PROBE=1 _ing=1.2.3.4 _ing_live=1 _reach_ingress h.local)" "not probed"
# ⚠️ EXPECTATION UPDATED 2026-09-10 -- THE PRODUCT SIDE IS THE CORRECT ONE.
# #1241 changed this cell from `no ingress` to `-` deliberately (creds.sh, "NOT 'no ingress'"):
# the legend defines the column as "Reachable = the address answered", and `no ingress` answered a
# DIFFERENT question while merely restating the URL cell, which already says `<needs ingress>`.
# MEASURED then: the cell read `no ingress` on NINE rows while all nine answered HTTP 200.
# That PR did not update this assertion, so `main` shipped RED at its own tip (b6d214b) -- the
# FIFTH prose-pinned assertion to break in one day. The case NAME now states the PROPERTY, so a
# future re-word of the cell does not silently re-point what this case is about.
ck "no ingress recorded -> the column makes NO reachability claim" \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing='' _ing_live=1 _reach_ingress h.local)"        "-"

# ⚠️ THE PAIR. `-` is honest ONLY because the URL cell independently says `<needs ingress>` under
# the IDENTICAL `[ -n "$_ing" ]` test (creds.sh: `ingress_url`). Nothing asserted that coupling, so
# a reword of `ingress_url` that emitted a URL anyway would leave `-` as an information-free cell
# with every gate still green. Asserting the two arms as a pair is what makes the `-` case mean
# something. Prescribed by adversary-bash-git-cli 2026-09-10.
_fn_url="$(_extract ingress_url)"
case "$_fn_url" in
  *'<needs ingress>'*) : ;;
  *) echo "FATAL: ingress_url extracted but does not contain '<needs ingress>' — reshaped."
     echo "       Fix the extraction; do NOT let this test pass over a fragment."; exit 1 ;;
esac
ck "...and the URL cell EXPLAINS it (the coupled arm)" \
   "$(eval "$_fn_url"; _ing='' ingress_url h.local)"                                  "<needs ingress>"
ck "...while a recorded ingress yields a real URL (the other direction)" \
   "$(eval "$_fn_url"; _ing=1.2.3.4 ingress_url h.local)"                           "http://h.local"
ck "LB not live -> silent (never a per-host verdict)" \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing=1.2.3.4 _ing_live=0 _reach_ingress h.local)" "silent"
# An empty host cannot name a vhost; sending `Host: ` would earn a 404 and INVENT a "no route".
ck "empty host -> LB up (does not invent a route fault)" \
   "$(probe '')" "LB up"
# Nothing answering at all is `silent`, not a fabricated status. Port 1 is closed by construction.
ck "dead endpoint -> silent" \
   "$(eval "$_fn"; _ing=127.0.0.1:1; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=2 _reach_ingress h.local)" "silent"

# ── STALE DNS: it RESOLVES, but not to THIS ingress (2026-09-06) ───────────────────────────────
# MEASURED on the live lab: /etc/hosts still carried a PREVIOUS lab's ingress (192.168.101.135)
# while the current one was .134. The name resolved, so the DNS arm passed; the route probe reaches
# the LB BY IP with a Host header and got 200; and the table printed `serving` for NINE rows a
# browser could not open. Verified three ways — curl on the URL as printed: HTTP 000 x9; Chrome:
# error page; curl --resolve to .134: 200 x9, each app serving its own marker. The LAB was healthy
# and the REPORT was wrong.
#
# ⚠️ "`localhost` resolves to 127.0.0.1 everywhere" IS FALSE, and these two cases used to rely on it
# via the REAL resolver. MEASURED on a GitHub runner: `localhost` comes back IPv6, so comparing it to
# `_ing=127.0.0.1` reported `stale DNS` and the CONTROL failed -- green on this box, red there, for
# weeks. Worse, on an IPv6-only answer `stale DNS` is arguably CORRECT, so the product was not even
# wrong; the test's assumption about the host was.
#
# They now use a DETERMINISTIC stub. The default stub two blocks up is `exit 0` with NO OUTPUT (it
# isolates the route arm), which is why the real resolver was reached for -- this one PRINTS an
# address, so the arm can be exercised without asking the host anything.
#
# ⚠️ WHAT THIS GREEN NO LONGER LICENSES, said plainly because a stub always costs something: NO case
# now asserts that REAL `getent hosts` output parses to a bare address. The two comparing cases use a
# synthetic stub; line ~229 runs the real parse but never asserts on it (a name-shaped `_ing` skips
# the compare); the unresolvable case produces no output at all. If real getent output ever parsed to
# something other than a bare address, creds.sh would invent `stale DNS` on a healthy operator box
# and nothing here would go red. That coverage WAS the environment-dependent thing, so the trade is
# right -- but it is a trade, not a free win.
#
# ⚠️ AND TWO CASES BELOW REMAIN ENVIRONMENT-DEPENDENT BY NECESSITY (~229, ~233): both need the
# resolver to FAIL on an RFC-reserved TLD (.test / .invalid), which a printing stub cannot express.
# A wildcard resolver, a captive portal or a search domain would make them resolve and both would
# fail. Accepted and named rather than hidden.
mkdir -p "$T/bin4"
# shellcheck disable=SC2016  # single quotes REQUIRED: "$2" is the STUB's positional, not ours.
printf '#!/bin/sh\nprintf "127.0.0.1       %%s\\n" "$2"\n' > "$T/bin4/getent"
chmod +x "$T/bin4/getent"
ck "resolves to a DIFFERENT address than the ingress -> stale DNS" \
   "$(PATH="$T/bin4:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=203.0.113.9 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "stale DNS"
# ⚠️ A STALE ADDRESS FIRST, THE INGRESS SECOND — the state THIS REPORT'S OWN REMEDY CREATES.
# `creds.sh`'s /etc/hosts advice says remove-then-add; an operator who does the ADD without the
# REMOVE leaves the old line winning and appends ours after it. `getent hosts` then returns BOTH, in
# file order, and a `grep -qxF` over the whole set goes SILENT because the ingress appears somewhere.
# MEASURED end-to-end before this case existed: the row printed `serving` while a browser would use
# the stale address — so re-running the report CONFIRMED the broken state as fixed, and the advice's
# own warning ("an appended line LOSES to an earlier one") had no instrument behind it.
# The verdict must key on the FIRST same-family address, not on membership.
mkdir -p "$T/bin4b"
# shellcheck disable=SC2016  # single quotes REQUIRED: "$2" is the STUB's positional, not ours.
printf '#!/bin/sh\nprintf "10.9.9.9 %%s\\n203.0.113.9 %%s\\n" "$2" "$2"\n' > "$T/bin4b/getent"
chmod +x "$T/bin4b/getent"
ck "a STALE address FIRST and the ingress second -> stale DNS (membership is not enough)" \
   "$(PATH="$T/bin4b:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=203.0.113.9 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "stale DNS"
# ...and its CONTROL, which is the 2026-09-08 false-stale fix: an IPv6 address routinely comes FIRST
# and must NOT be compared against an IPv4 ingress. Filtering to the same family is what keeps this
# silent; a naive "first address" rule would re-break it.
mkdir -p "$T/bin4c"
# shellcheck disable=SC2016  # single quotes REQUIRED: "$2" is the STUB's positional, not ours.
printf '#!/bin/sh\nprintf "::1 %%s\\n203.0.113.9 %%s\\n" "$2" "$2"\n' > "$T/bin4c/getent"
chmod +x "$T/bin4c/getent"
# `silent`, not empty: "NOT stale" means it falls THROUGH to the route probe, which reports
# `silent` for an unreachable ingress — the same value the sibling control below asserts. My first
# version wanted '' and failed for that reason, which would have read as a product defect.
ck "::1 FIRST, then the ingress -> NOT stale (same-family only; the 2026-09-08 regression)" \
   "$(PATH="$T/bin4c:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=203.0.113.9 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"

# THE CONTROL. If a MATCHING address also read `stale DNS`, the check would flag every healthy host
# and the state would be worthless — a verdict that cannot be false is not a verdict.
ck "resolves to the ingress itself -> NOT stale (falls through to the route probe)" \
   "$(PATH="$T/bin4:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=127.0.0.1 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"

# ⚠️ THE CASE ABOVE **USED** THE REAL RESOLVER (until this change), AND THAT MADE IT
# ENVIRONMENT-DEPENDENT: it passed on
# this box and FAILED on a GitHub runner, where `localhost` resolves `::1` FIRST. It was invisible
# for weeks because the fast set does not run per-PR (B571) and the weekly was already red for an
# unrelated reason (B573) -- two layers of masking over a real operator-facing bug.
#
# `getent hosts` returns EVERY family and the order is the resolver's, so the product must compare
# against ALL of them. The cases below pin that with a DETERMINISTIC multi-family stub rather than
# whatever the host happens to answer. RED-proof: restore `awk 'NR==1{print $1}'` in creds.sh and
# the first of the two goes red.
mkdir -p "$T/bin6"
# shellcheck disable=SC2016  # single quotes REQUIRED: "$2" is the STUB's positional, not ours.
printf '#!/bin/sh\nprintf "::1             %%s\\n127.0.0.1       %%s\\n" "$2" "$2"\n' > "$T/bin6/getent"
chmod +x "$T/bin6/getent"
ck "IPv6 FIRST, ingress is the IPv4 -> NOT stale (all families are compared, not just the first)" \
   "$(PATH="$T/bin6:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=127.0.0.1 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"
# THE CONTROL: the arm must still fire when NO family matches, or the fix above would have made the
# verdict unfalsifiable — a check that cannot say `stale DNS` is not a check.
ck "IPv6 FIRST, ingress matches NEITHER family -> still stale DNS" \
   "$(PATH="$T/bin6:$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=203.0.113.9 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "stale DNS"
# An ingress given as a NAME cannot be compared to a resolved ADDRESS. Claiming `stale DNS` there
# would INVENT a fault, so the guard must fall through and let the route probe speak instead.
ck "ingress is a NAME, not an address -> must NOT claim stale" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=ingress.example.test _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"

# The DNS arm must still win when a host genuinely does not resolve — with the stub OFF PATH.
ck "unresolvable host -> no DNS here (the arm still short-circuits)" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; _ing="127.0.0.1:'"$PORT"'"; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress definitely-not-a-real-host.invalid' _ "$_fn")" \
   "no DNS here"

printf '\ntest-creds-reach-ingress: %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
