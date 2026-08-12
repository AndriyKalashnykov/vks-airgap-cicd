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

# SKIP_DOTENV=1 IS LOAD-BEARING. Without it `load_env` sources the operator's real ./.env AFTER
# this HARBOR_URL is set, and the fixture's address is silently replaced by whatever that box uses.
# MEASURED 2026-08-11: the "resolvable + dead" case passed HARBOR_URL=127.0.0.1 and the gate
# examined harbor.env1.lab.test instead -- which was ANSWERING -- so the gate correctly did not
# fire and the test reported a failure of the gate. A test that reads its own environment measures
# the environment.
run() { PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kc" SKIP_DOTENV=1 HARBOR_URL="$1" \
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

# The SECOND entry point. `make harbor-reachable` is what scenario-1 §4 tells the operator to run --
# lab-preflight cannot serve that step, because its other three checks are GUEST-cluster preconditions
# and at §4 the context is the SUPERVISOR (the guest cluster does not exist until §6). Both call the
# same lib/harbor.sh function, and this asserts the standalone path actually reaches it: a target
# nobody exercises is decoration, and a shared function with one tested caller is one tested caller.
# NOTE it needs NO kubectl stub -- that is the point of the split.
# HARBOR_REACHABLE_WAIT_SECONDS=0 — this asserts the REPORT's verdict, not the wait. The target
# defaults to 900 so an operator who types the bare command gets patience; an OFFLINE test against
# 127.0.0.1 would then burn its whole `timeout 90` at each of these three call sites and assert on
# timeout's kill code instead of the script's own rc. MEASURED 2026-08-12 the moment that default
# was introduced: three stacked 90s waits inside static-check, and the assertions silently stopped
# measuring what they name.
o="$(SKIP_DOTENV=1 HARBOR_URL=127.0.0.1 HARBOR_REACHABLE_WAIT_SECONDS=0 timeout 90 bash "$SCRIPT_DIR/04-harbor-reachable.sh" 2>&1 || true)"
if printf '%s' "$o" | grep -q 'NOTHING is serving there'; then ok "make harbor-reachable fires standalone (no cluster)"
else bad "make harbor-reachable fires standalone (no cluster)" "the standalone entry point did not reach the check"; fi
o="$(SKIP_DOTENV=1 HARBOR_URL=127.0.0.1 HARBOR_REACHABLE_WAIT_SECONDS=0 timeout 90 bash "$SCRIPT_DIR/04-harbor-reachable.sh" 2>&1 || true; echo "rc=$?")"
o2="$(SKIP_DOTENV=1 HARBOR_URL=127.0.0.1 HARBOR_REACHABLE_WAIT_SECONDS=0 timeout 90 bash "$SCRIPT_DIR/04-harbor-reachable.sh" >/dev/null 2>&1; echo $?)"
if [ "$o2" != 0 ]; then ok "...and EXITS NON-ZERO, so install-all/CI can gate on it"
else bad "...and EXITS NON-ZERO" "it printed a PROBLEM and exited 0 — a gate that cannot fail"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
