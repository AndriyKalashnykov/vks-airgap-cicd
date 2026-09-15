#!/usr/bin/env bash
# ci-tier: fast — offline; a loopback TCP listener on 127.0.0.1, no cluster, no network.
#
# B729-D1: creds.sh's /etc/hosts advice must name the *_HOST whose DNS verdict was computed, NOT the
# host parsed out of the *_URL column. When GITEA_URL diverges from GITEA_HOST (an .env.example knob
# that e2e-cross-cluster.sh actually sets), the old code recovered the advice host with
# `_row_host "$c2"` (the URL column) and told the operator to add an /etc/hosts entry for a host with
# NO problem, while the host that actually failed (GITEA_HOST) was never named. The fix carries the
# true host as add_row's 7th positional (c7); the DNS arms prefer it: `${c7:-$(_row_host "$c2")}`.
#
# WHY THE FULL RENDER: the arm lives in creds.sh's main flow, not a callable function, so this drives
# the whole script. To make the `no DNS here` arm fire it needs _ing_live=1 (a real TCP connect to
# INGRESS_LB_IP:INGRESS_PROBE_PORT -> a loopback listener) AND a getent that FAILS. CREDS_NO_PROBE is
# deliberately NOT set — under it every c5 is `not probed` and the DNS arms never fire (the vacuity
# trap test-creds-show.sh STATE 8 records).
#
# THE DISCRIMINATOR: with GITEA_URL=http://git.corp.example.com:3000 diverging from
# GITEA_HOST=gitea.vks.local, the string `gitea.vks.local` reaches the printed output ONLY via the
# D1 advice (GITEA_HOST is otherwise used only in the un-printed reachability probe). Revert the c7
# read/arg and it vanishes — which is the RED-proof. Conversely `git.corp.example.com` must appear
# ONLY once, in the Gitea URL cell, and never in the advice.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
T="$(mktemp -d)"
_lpid=""
cleanup() { [ -n "$_lpid" ] && kill "$_lpid" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

p=0; f=0
ck() { if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
       else f=$((f+1)); printf '  FAIL  %s (got=[%s] want=[%s])\n' "$1" "$2" "$3"; fi; }

# --- a held loopback listener so creds.sh's _ing_live TCP probe succeeds -------------------------
# bind in the child, write the kernel-assigned port to a file, then accept-and-close forever.
python3 - "$T/lport" <<'PY' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(64)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        break
PY
_lpid=$!
for _ in $(seq 1 50); do [ -s "$T/lport" ] && break; sleep 0.1; done
_port="$(cat "$T/lport" 2>/dev/null || true)"
if [ -z "$_port" ]; then echo "  FAIL  loopback listener did not start (no port)"; exit 1; fi

# --- stub the PATH tools: getent FAILS (-> no DNS here), curl/kubectl offline -------------------
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/getent"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/curl"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/kubectl"
chmod +x "$T/bin/getent" "$T/bin/curl" "$T/bin/kubectl"
cp "$REPO/.env.example" "$T/.env.example"

# .env is sourced AFTER .env.example (set -a), so these win over any committed default (clobber-safe).
cat > "$T/.env" <<ENV
GITEA_HOST=gitea.vks.local
GITEA_URL=http://git.corp.example.com:3000
INGRESS_LB_IP=127.0.0.1
INGRESS_PROBE_PORT=${_port}
HARBOR_URL=10.0.0.1
ENV

out="$( cd "$T" && PATH="$T/bin:$PATH" REPO_ROOT="$T" VKS_STATE_FILE="$T/.env.state" \
        CREDS_TOKEN=1 bash "$REPO/scripts/creds.sh" 2>/dev/null )"

# Sanity: the arm actually fired (else the assertions below are vacuous).
ck "the 'no DNS here' arm fired (advice printed)" \
   "$(grep -qiE 'etc/hosts' <<< "$out" && echo yes || echo no)" "yes"

# THE FIX: the advice names the TRUE host, which reaches the output ONLY via D1.
ck "advice names the true GITEA_HOST (gitea.vks.local)" \
   "$(grep -qF 'gitea.vks.local' <<< "$out" && echo yes || echo no)" "yes"

# THE INVERSE: the divergent URL host appears ONLY in the URL cell, never in the advice.
# (Revert the c7 fix and this count becomes 2: the URL cell + the advice.)
ck "the divergent URL host git.corp.example.com appears ONCE (URL cell only, not the advice)" \
   "$(grep -cF 'git.corp.example.com' <<< "$out")" "1"

printf '\n  %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
