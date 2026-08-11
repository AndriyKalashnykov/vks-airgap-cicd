#!/usr/bin/env bash
# test-harbor-reachable.sh — the demonstrated RED for lab-preflight's Harbor-reachability gate.
#
# WHY THE GATE EXISTS. MEASURED 2026-08-11 on both OS rows of the create-from-nothing walk: a
# REINSTALLED Harbor came up healthy on a NEW LoadBalancer IP (192.168.101.141, 9 pods Running)
# while DNS still answered with the PREVIOUS install's address (192.168.101.135). The name resolved,
# so nothing looked wrong -- and it cost FIVE failures, none of which mentioned DNS:
#
#   Step 8's CA fetch   129s, then `openssl: Could not find certificate` (names the FILE, not the reason)
#   make harbor-robot   262s
#   make env-populate / install-ingress / verify-ingress
#
# Offline: a stub kubectl gets past the cluster gate, and a real local listener (or the absence of
# one) drives the reachability branch. No cluster, no Harbor, no network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

# A kubectl that satisfies every check BEFORE the Harbor one, so the branch under test is reached.
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=(); for a in "$@"; do case "$a" in --kubeconfig) skip=1;; *) [ "${skip:-}" = 1 ] && skip= || args+=("$a");; esac; done
case "${args[0]:-}" in
  version) echo "Client Version: v1.34.0" ;;
  config)  echo "https://stub.invalid:6443" ;;
  auth)    echo yes ;;
  get) case "${args[1]:-}" in
         storageclass) [ "${args[2]:-}" = --no-headers ] && echo "sc-default  csi  Delete  true" || echo "sc-default" ;;
         svc) echo "" ;;
         *) echo "" ;;
       esac ;;
  *) echo "" ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

run() { PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kc" HARBOR_URL="$1" \
        timeout 90 bash "$SCRIPT_DIR/24-lab-preflight.sh" 2>&1; }
: > "$TMP/kc"

# RED: a name that RESOLVES and serves NOTHING. 127.0.0.1 on a port nobody listens on is exactly the
# shape of the incident -- resolution succeeds, so no DNS tool reports a problem.
o="$(run 127.0.0.1)"
if printf '%s' "$o" | grep -q 'NOTHING is serving there'; then ok "resolvable + dead -> PROBLEM"
else bad "resolvable + dead -> PROBLEM" "the gate did not fire"; fi
if printf '%s' "$o" | grep -q 'REINSTALLED Harbor gets a NEW LoadBalancer IP'; then ok "...and it names the CAUSE"
else bad "...and it names the CAUSE" "it reported a failure without saying why"; fi

# GREEN: something actually answering must NOT be flagged. It has to be a TLS listener -- the gate
# probes https, so a plain-HTTP server answers 000 and is CORRECTLY flagged (my first version of
# this test used `python3 -m http.server` and read that correct behaviour as a false positive).
# Any HTTP status proves it is serving: a 404 from a live Harbor is still a live Harbor, which is
# why the gate judges on 000 rather than on 2xx.
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 -nodes \
  -subj /CN=localhost >/dev/null 2>&1
openssl s_server -quiet -accept 18099 -cert "$TMP/c.pem" -key "$TMP/k.pem" -www >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 40); do (exec 3<>/dev/tcp/127.0.0.1/18099) 2>/dev/null && break; sleep 0.25; done
o="$(run 127.0.0.1:18099)"
if printf '%s' "$o" | grep -q 'NOTHING is serving there'; then bad "a live TLS listener is NOT flagged" "false positive"
else ok "a live TLS listener is NOT flagged"; fi

# HARBOR_URL genuinely unset must not invent a problem -- create-from-nothing reaches here before
# Harbor exists, and .env.example ships it COMMENTED (`# HARBOR_URL=<SET-IN-.env>`) for that reason.
# SKIP_DOTENV=1 because load_env would otherwise source this box's real .env and supply one.
o="$(PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kc" SKIP_DOTENV=1 timeout 90 \
     env -u HARBOR_URL bash "$SCRIPT_DIR/24-lab-preflight.sh" 2>&1)"
if printf '%s' "$o" | grep -q 'NOTHING is serving there'; then bad "unset HARBOR_URL is silent" "it invented a problem"
else ok "unset HARBOR_URL is silent"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
