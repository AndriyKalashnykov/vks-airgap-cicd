#!/usr/bin/env bash
# ci-tier: slow — asserts WALL-CLOCK by design: every case waits out a time bound. OFFLINE: a real
# `openssl s_server` on 127.0.0.1 that is then STOPPED, so it accepts connections and never answers.
#
# test-fetch-ca-bound.sh — `make fetch-harbor-ca` / `make fetch-argocd-ca` (scripts/fetch-ca.sh)
# must not hang on a server that accepts the connection and stays silent.
#
# THE DEFECT. fetch-ca.sh's own handshake had no time bound. Against a listener that accepts and
# never answers (a load balancer whose backend is still starting looks like that) it printed
# "fetching …" and then nothing, until it was killed.
#
# WHAT IS PINNED:
#   1. it stops at CA_VERIFY_TIMEOUT and says the endpoint accepted the connection and did not
#      answer within N s; the command it prints raises the bound; the CA file already there is
#      untouched; no internal tracker id is printed; a run with no label reads as a sentence
#   2. CA_VERIFY_TIMEOUT=0 is NOT handed to `timeout` (0 = no limit): the default bound applies
#   3. the time running out where NOTHING listens is "could not connect", never "accepted"
#   4. a CA_VERIFY_TIMEOUT written in .env reaches the real script through the real Makefile
#   5. Ctrl-C at a terminal ends the fetch at once, with a line saying nothing was written
#
# WHY THIS FILE IS IN THE SLOW TIER. Cases 1 to 4 can only be observed by waiting for the bound
# (2 s, 15 s, 2 s, 3 s), and case 5 asserts promptness. The instant halves of the same contract
# (the clamp, the runner, the TCP question, what make exports) are unit cases in
# test-harbor-ca-refetch-advice.sh, which runs on every change.
#
# HOW "accepts and never answers" IS PRODUCED: an s_server that is sent SIGSTOP. The kernel still
# completes the TCP handshake from the listen queue, and nothing ever replies.
# HOW "the time ran out and nothing is there" IS PRODUCED: a wrapper `openssl` first on PATH that
# sleeps on the `-showcerts` handshake, with a CLOSED port as the endpoint.
#
# DOES NOT PROVE: anything about a real Harbor or ArgoCD; a host whose packets are dropped (no
# such address is dialled here); or Ctrl-C with a `timeout` other than the one on this machine.
set -uo pipefail
TEST_SANDBOX_REPO_ROOT=keep   # this test sets REPO_ROOT itself, as a plain (unexported) variable naming this checkout
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$REPO_ROOT"
FETCH="${REPO}/scripts/fetch-ca.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
# A harness that asserted nothing must not read as a pass.
inconclusive() { echo "test-fetch-ca-bound: INCONCLUSIVE — $1 (nothing was asserted)"; exit 1; }

command -v openssl >/dev/null 2>&1 || inconclusive "openssl is not installed"
command -v timeout >/dev/null 2>&1 || inconclusive "timeout is not installed"
[ -f "$FETCH" ] || inconclusive "${FETCH} is missing"
REAL_OPENSSL="$(command -v openssl)"

T="$(mktemp -d)"
# The scripts under test make temp files of their own: keep them in this test's directory.
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
# A caller's "already reported" list would hide the one line a case below looks for.
unset _VKS_BOUNDS_REPORTED
# Run from `make test-scripts` this file inherits make's own environment (see
# test-harbor-ca-refetch-advice.sh): a pin exported there would change what every fetch here does.
unset HARBOR_CA_SHA256 ARGOCD_CA_SHA256 _FETCH_CA_ENDPOINT MAKEFLAGS MAKELEVEL MFLAGS
PIDS=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
  local p
  # KILL, not TERM: the listener is STOPPED on purpose and a stopped process ignores TERM.
  while read -r p; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done <<< "$PIDS"
  rm -rf "$T"
}
trap cleanup EXIT

has()  { command grep -qF -- "$2" <<< "$1"; }
strip() { sed -e 's/^.* msg=//' -e 's/^[[:space:]]*//' <<< "$1"; }
line_after() { strip "$(command grep -A1 -F -- "$2" <<< "$1" | sed -n 2p)"; }

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────
( cd "$T" || exit 1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ss.key -out ss.crt -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -keyout old.key -out old.crt -days 1 \
    -subj '/CN=the-file-that-was-already-there' >/dev/null 2>&1 )
[ -s "$T/ss.crt" ] && [ -s "$T/old.crt" ] || inconclusive "could not mint the test certificates"

_free_port() {   # prints a port nothing is listening on (a connect that FAILS means free)
  local p
  for p in $(seq 38443 38643); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
P_SILENT="$(_free_port)" || inconclusive "no free port for the silent listener"
openssl s_server -accept "$P_SILENT" -cert "$T/ss.crt" -key "$T/ss.key" -www -quiet >/dev/null 2>&1 &
SILENT_PID=$!
PIDS="${PIDS}${SILENT_PID}"$'\n'
up=0
for _ in $(seq 1 40); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$P_SILENT") 2>/dev/null; then
    sleep 0.25                                     # a bind that failed needs a moment to exit
    kill -0 "$SILENT_PID" 2>/dev/null && up=1      # the connect counts only while OUR process lives
    break
  fi
  sleep 0.25
done
[ "$up" = 1 ] || inconclusive "the test listener did not start"
kill -STOP "$SILENT_PID" 2>/dev/null || inconclusive "could not stop the listener"
P_DEAD="$(_free_port)" || inconclusive "no free port for the dead endpoint"
[ "$P_DEAD" != "$P_SILENT" ] || inconclusive "the dead port is the silent listener's port"

mkdir -p "$T/stall"
# The stub's own "$@" is written literally into the generated script (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-showcerts" ] && exec sleep 30; done\nexec %s "$@"\n' "$REAL_OPENSSL" \
  > "$T/stall/openssl"
chmod +x "$T/stall/openssl"

ACCEPTED='accepted the connection and did not answer within'
LONGER='give it longer (CA_VERIFY_TIMEOUT is in seconds):'
# fetch_bounded <endpoint> <CA_VERIFY_TIMEOUT> [path-prefix] [label, or - for none]
# Sets FB_OUT FB_RC FB_EL. The output path is $T/out.crt, with a CA file PLANTED there first: a
# refusal must leave it alone. Each run is under a 40 s guard, so a lost bound is a FAIL here and
# not a hung suite.
fetch_bounded() {
  local t0=$SECONDS label="${4:-harbor}"
  cp "$T/old.crt" "$T/out.crt"
  if [ "$label" = - ]; then
    FB_OUT="$(PATH="${3:+$3:}$PATH" CA_VERIFY_TIMEOUT="$2" timeout -k 2 40 bash "$FETCH" "$1" "$T/out.crt" </dev/null 2>&1)"; FB_RC=$?
  else
    FB_OUT="$(PATH="${3:+$3:}$PATH" CA_VERIFY_TIMEOUT="$2" timeout -k 2 40 bash "$FETCH" "$1" "$T/out.crt" "$label" </dev/null 2>&1)"; FB_RC=$?
  fi
  FB_EL=$((SECONDS - t0))
}

# ══ 1. the bound, and what the message says ══════════════════════════════════════════════════
fetch_bounded "127.0.0.1:${P_SILENT}" 2
if [ "$FB_RC" = 1 ] && has "$FB_OUT" "127.0.0.1:${P_SILENT} ${ACCEPTED} 2 s." && [ "$FB_EL" -ge 1 ] && [ "$FB_EL" -le 8 ]; then
  ok "a listener that accepts and never answers stops the fetch at its bound, and it says so (${FB_EL}s for a 2s bound)"
else
  bad "a silent listener must stop the fetch at CA_VERIFY_TIMEOUT with the did-not-answer message" "rc=${FB_RC} after ${FB_EL}s (124 = it hung until the guard): $(printf '%s' "$FB_OUT" | tail -2 | cut -c1-160)"
fi
if [ "$(line_after "$FB_OUT" "$LONGER")" = 'make fetch-harbor-ca CA_VERIFY_TIMEOUT=60' ] && has "$FB_OUT" 'If harbor is only slow to answer'; then
  ok "silent: names CA_VERIFY_TIMEOUT and prints the command that raises it"
else
  bad "silent: the command that raises the bound is missing or wrong" "got '$(line_after "$FB_OUT" "$LONGER")'"
fi
if cmp -s "$T/old.crt" "$T/out.crt" && has "$FB_OUT" "$T/out.crt is UNCHANGED"; then
  ok "silent: the CA file that was there is untouched, and the message says so"
else
  bad "silent: the output file changed, or the message does not say it is unchanged"
fi
if command grep -qE '\bB[0-9]{2,}\b' <<< "$(command grep -F -A6 -- "$ACCEPTED" <<< "$FB_OUT")"; then
  bad "silent: an internal tracker id is printed"
else
  ok "silent: no internal tracker id in the message"
fi
# A direct run with no label: the default label is the bare word `endpoint`, and the sentence has
# to read as one. There is no make target for it, so the command printed is the script's own.
fetch_bounded "127.0.0.1:${P_SILENT}" 2 "" -
if has "$FB_OUT" 'If the endpoint is only slow to answer' && ! has "$FB_OUT" 'If endpoint is' \
   && [ "$(line_after "$FB_OUT" "$LONGER")" = "CA_VERIFY_TIMEOUT=60 ${FETCH} 127.0.0.1:${P_SILENT} $(printf '%q' "$T/out.crt") endpoint" ]; then
  ok "silent, no label: the sentence reads 'If the endpoint is only slow …', and the command is the script with its real arguments"
else
  bad "silent, no label: the default-label sentence or its command is wrong" "$(command grep -F -A1 -- 'only slow' <<< "$FB_OUT" | cut -c1-200)"
fi

# ══ 2. a bound of 0 is not handed to `timeout` ═══════════════════════════════════════════════
fetch_bounded "127.0.0.1:${P_SILENT}" 0
if [ "$FB_RC" = 1 ] && has "$FB_OUT" "${ACCEPTED} 15 s." && [ "$FB_EL" -ge 14 ] && [ "$FB_EL" -le 24 ]; then
  ok "CA_VERIFY_TIMEOUT=0 is replaced by the default bound, not passed to timeout (${FB_EL}s)"
else
  bad "CA_VERIFY_TIMEOUT=0 switched the bound off (or the default moved)" "rc=${FB_RC} after ${FB_EL}s: $(printf '%s' "$FB_OUT" | tail -2 | cut -c1-160)"
fi

# ══ 3. the time ran out and NOTHING is listening ═════════════════════════════════════════════
fetch_bounded "127.0.0.1:${P_DEAD}" 2 "$T/stall"
if [ "$FB_RC" = 1 ] && [ "$FB_EL" -ge 1 ] && has "$FB_OUT" "could not connect to 127.0.0.1:${P_DEAD} — is harbor reachable over HTTPS?" && ! has "$FB_OUT" "$ACCEPTED"; then
  ok "time ran out with nothing listening -> 'could not connect', not 'accepted the connection' (${FB_EL}s)"
else
  bad "a timeout with no server there must not claim the connection was accepted" "rc=${FB_RC} after ${FB_EL}s (under 1s means the stall wrapper was not used): $(printf '%s' "$FB_OUT" | tail -2 | cut -c1-160)"
fi

# ══ 4. .env -> the real Makefile -> the real script ══════════════════════════════════════════
# The Makefile is the real one, run in a sandbox directory whose .env holds the bound. The script
# is the real one too, so "within 3 s" in its message is the .env value having arrived. A per-run
# value must still win. (What make exports in every other combination is pinned, instantly, with a
# stub script in test-harbor-ca-refetch-advice.sh.)
if command -v make >/dev/null 2>&1; then
  mkdir -p "$T/mk"; printf 'CA_VERIFY_TIMEOUT=3\n' > "$T/mk/.env"
  mk_fetch() {  # [VAR=value …] ; prints the fetch's output
    env -u CA_VERIFY_TIMEOUT -u HARBOR_CA_SHA256 -u SKIP_DOTENV -u MAKEFLAGS -u MAKELEVEL -u MFLAGS \
      timeout -k 2 40 make --no-print-directory -f "${REPO}/Makefile" -C "$T/mk" fetch-harbor-ca \
        SCRIPTS="${REPO}/scripts" HARBOR_URL="127.0.0.1:${P_SILENT}" HARBOR_CA_FILE="$T/out-make.crt" "$@" </dev/null 2>&1
  }
  mk_out="$(mk_fetch)"
  if has "$mk_out" "${ACCEPTED} 3 s." && [ ! -e "$T/out-make.crt" ]; then
    ok "make: CA_VERIFY_TIMEOUT=3 in .env reaches fetch-ca.sh ('within 3 s')"
  else
    bad "make: a CA_VERIFY_TIMEOUT set in .env does not reach fetch-ca.sh" "$(printf '%s' "$mk_out" | command grep -F -- 'within' | cut -c1-160)"
  fi
  mk_out="$(mk_fetch CA_VERIFY_TIMEOUT=2)"
  if has "$mk_out" "${ACCEPTED} 2 s."; then
    ok "make: 'make fetch-harbor-ca CA_VERIFY_TIMEOUT=2' wins over the .env value ('within 2 s')"
  else
    bad "make: a per-run CA_VERIFY_TIMEOUT does not win over .env" "$(printf '%s' "$mk_out" | command grep -F -- 'within' | cut -c1-160)"
  fi
else
  printf 'SKIP  make is not installed: cannot run fetch-harbor-ca through it\n'
fi

# ══ 5. Ctrl-C at a terminal ══════════════════════════════════════════════════════════════════
# `timeout` normally puts its command in a process group of its own, where a Ctrl-C typed at the
# terminal never reaches it: the fetch then ran on to its bound. The fetch is run on a pty here,
# Ctrl-C is typed once it has printed "fetching", and it must end within 4 s of that (the bound
# is 12 s), saying that nothing was written.
if command -v python3 >/dev/null 2>&1; then
  cat > "$T/ptyc.py" <<'PY'
import os, pty, select, signal, sys, time
marker = sys.argv[1].encode(); grace = float(sys.argv[2]); limit = float(sys.argv[3]); cmd = sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    os.execvp(cmd[0], cmd)
buf = b""; seen = None; sent = None; status = None; start = time.time()
def pump(wait):
    global buf
    r, _, _ = select.select([fd], [], [], wait)
    if not r:
        return True
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        return False
    buf += chunk
    return bool(chunk)
while True:
    pump(0.1)
    now = time.time()
    if seen is None and marker in buf:
        seen = now
    if sent is None and seen is not None and now - seen >= grace:
        os.write(fd, b"\x03"); sent = now
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid:
        status = st
        break
    if (sent is not None and now - sent > limit) or (sent is None and now - start > limit + grace + 10):
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
        os.waitpid(pid, 0)
        break
end = time.time()
stop = time.time() + 1.0
while time.time() < stop and pump(0.1):
    pass
code = -1 if status is None else (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
print("sent=%d exited=%d after=%d code=%d" % (1 if sent else 0, 0 if status is None else 1,
      int(round((end - sent) if sent else -1)), code))
sys.stdout.write(buf.decode("utf-8", "replace"))
PY
  cp "$T/old.crt" "$T/out.crt"
  pty_out="$(CA_VERIFY_TIMEOUT=12 timeout -k 2 60 python3 -I "$T/ptyc.py" fetching 1.5 6 bash "$FETCH" "127.0.0.1:${P_SILENT}" "$T/out.crt" harbor 2>&1)"
  pty_head="$(head -1 <<< "$pty_out")"
  after="$(sed -n 's/.* after=\(-\{0,1\}[0-9]*\) .*/\1/p' <<< "$pty_head")"
  if has "$pty_head" 'sent=1 exited=1' && [ -n "$after" ] && [ "$after" -ge 0 ] && [ "$after" -le 4 ] && ! has "$pty_out" "$ACCEPTED"; then
    ok "Ctrl-C on a terminal ends the fetch at once (${after}s after it was typed; the bound was 12s)"
  else
    bad "Ctrl-C did not end the fetch: it ran on to its bound" "${pty_head}; said 'did not answer within': $(has "$pty_out" "$ACCEPTED" && echo yes || echo no)"
  fi
  if has "$pty_head" 'code=130' && has "$pty_out" "interrupted: nothing was written, $T/out.crt is unchanged." \
     && ! has "$pty_out" 'could not connect' && cmp -s "$T/old.crt" "$T/out.crt"; then
    ok "Ctrl-C: exit 130, says nothing was written, does not say 'could not connect', and the CA file is untouched"
  else
    bad "Ctrl-C: the interrupted run reports something else" "${pty_head}: $(printf '%s' "$pty_out" | tail -2 | tr '\r\n' '  ' | cut -c1-200)"
  fi
else
  printf 'SKIP  python3 is not installed: the Ctrl-C case needs a pty\n'
fi

printf '\ntest-fetch-ca-bound: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-fetch-ca-bound: OK\n'
