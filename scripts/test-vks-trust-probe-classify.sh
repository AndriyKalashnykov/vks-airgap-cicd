#!/usr/bin/env bash
# ci-tier: fast
# Offline RED/GREEN for vks-trust-probe.sh's PULL-EVENT classifier (B575).
#
# THE BUG. A kubelet DNS failure emits
#     Failed to pull image "harbor.env1.lab.test/apps/probeimg:0.1.0": ... dial tcp: lookup
#     harbor.env1.lab.test on 10.96.0.10:53: no such host
# which matched the old `*x509*|*"Failed"*` arm, so the operator was told
#     => the pull FAILED. Read the event above: an x509 line is a TRUST problem.
# for a fault that has nothing to do with trust. This repo's own rule: an error message that names
# the wrong cause is worse than a crash -- it sends the operator to fix a thing that is not broken.
# The vocabulary already existed twice in-tree (lib/os.sh:2608, 23-mirror-verify.sh:115); only this
# consumer lacked an arm.
#
# WHY THIS TEST EXISTS AT ALL, rather than a new `make dns-node-check` target: an idea round refuted
# building one. vks-trust-probe IS that design already (PSA-compliant pod, imagePullPolicy: Always,
# event-not-phase, trap cleanup, credentialed via the copied harbor-pull secret). And a node-vantage
# probe's RED is NOT DEMONSTRABLE in KinD -- HARBOR_URL there is a bare LB IP
# (06-install-harbor.sh:304) and containerd is pinned to it (:256), so there is no name to fail to
# resolve and any such gate would be green by construction. THIS classifier's RED is offline.
#
# ⚠️ WHAT A GREEN HERE DOES NOT PROVE: that a real node resolves a real name. This asserts the
# CLASSIFIER, on canned kubelet events. The live half needs a lab (`make vks-trust-probe`).
#
# Fakes kubectl on PATH; touches no cluster, no network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf 'apiVersion: v1\n' > "$T/kubeconfig"
: > "$T/.env.example"

# The stub dispatches on argv. `get events` returns the FIXTURE -- that is the thing under test.
# Everything else returns whatever keeps the script walking to the classifier.
# EVFILE is read at call time, so each case rewrites it rather than rebuilding the stub.
mk_kubectl() {  # $1 = rc for `label` calls (1 makes ensure_namespace fail == the tenant-RBAC case)
  cat > "$T/bin/kubectl" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"get events"*)        cat "$T/ev"; exit 0 ;;
  *"label"*)             exit $1 ;;
  *"get pod pullprobe"*) printf 'Pending|ErrImagePull'; exit 0 ;;
  *"current-context"*)   printf 'fake@fake'; exit 0 ;;
  *)                     exit 0 ;;
esac
STUB
  chmod +x "$T/bin/kubectl"
}

run() {  # run <event-text>  -> the script's stdout+stderr, newlines squashed
  printf '%s\n' "$1" > "$T/ev"
  PATH="$T/bin:$PATH" REPO_ROOT="$T" SKIP_DOTENV=1 \
    KUBECONFIG="$T/kubeconfig" HARBOR_URL="https://harbor.env1.lab.test:443/" \
    HARBOR_CA_FILE="$T/nope.crt" PROBE_IMAGE="harbor.env1.lab.test/apps/probeimg:0.1.0" \
    PROBE_WAIT_ITERATIONS=1 PROBE_WAIT_INTERVAL=0 \
    bash "$SCRIPT_DIR/vks-trust-probe.sh" 2>&1 | tr '\n' ' '
}

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

mk_kubectl 0

# ---- 1. THE RED THAT DID NOT EXIST. A DNS fault must be named DNS, and must NOT say TRUST. -------
out="$(run 'Warning  Failed  pod/pullprobe  Failed to pull image "harbor.env1.lab.test/apps/probeimg:0.1.0": failed to pull and unpack image: failed to resolve reference: failed to do request: Head "https://harbor.env1.lab.test/v2/apps/probeimg/manifests/0.1.0": dial tcp: lookup harbor.env1.lab.test on 10.96.0.10:53: no such host')"
ck "no such host -> names DNS"          "$(printf '%s' "$out" | grep -c 'could NOT RESOLVE')" "1"
ck "no such host -> names the HOST"     "$(printf '%s' "$out" | grep -c 'RESOLVE harbor.env1.lab.test')" "1"
ck "no such host -> does NOT say TRUST" "$(printf '%s' "$out" | grep -c 'TRUST')" "0"
ck "no such host -> gives the remedy"   "$(printf '%s' "$out" | grep -c 'make show-dns-records')" "1"

# ---- 2. TRUST must NOT regress into the DNS arm. -------------------------------------------------
out="$(run 'Warning  Failed  pod/pullprobe  Failed to pull image "harbor.env1.lab.test/apps/probeimg:0.1.0": tls: failed to verify certificate: x509: certificate signed by unknown authority')"
ck "x509 -> names TRUST"                "$(printf '%s' "$out" | grep -c 'FAILED on TRUST')" "1"
ck "x509 -> does NOT claim DNS"         "$(printf '%s' "$out" | grep -c 'could NOT RESOLVE')" "0"

# ---- 3. ARM ORDER, asserted rather than incidental: x509 outranks a stale `no such host` in the
#         same 3-event window, because an x509 line PROVES the address resolved.
out="$(run 'Warning  Failed  lookup harbor.env1.lab.test on 10.96.0.10:53: no such host
Warning  Failed  x509: certificate signed by unknown authority')"
ck "x509 + DNS in one window -> TRUST"  "$(printf '%s' "$out" | grep -c 'FAILED on TRUST')" "1"
ck "x509 + DNS in one window -> not DNS" "$(printf '%s' "$out" | grep -c 'could NOT RESOLVE')" "0"

# ---- 4. a resolver TIMEOUT is still DNS (`: lookup ` is the Go resolver's own prefix) ------------
out="$(run 'Warning  Failed  Failed to pull image "x": dial tcp: lookup harbor.env1.lab.test on 10.96.0.10:53: read udp: i/o timeout')"
ck "resolver timeout -> names DNS"      "$(printf '%s' "$out" | grep -c 'could NOT RESOLVE')" "1"

# ---- 5. …but a ROUTING timeout is NOT DNS. Naming it DNS would re-commit the very defect. --------
out="$(run 'Warning  Failed  Failed to pull image "x": dial tcp 192.168.101.130:443: i/o timeout')"
ck "routing timeout -> NOT called DNS"  "$(printf '%s' "$out" | grep -c 'could NOT RESOLVE')" "0"
ck "routing timeout -> generic FAILED"  "$(printf '%s' "$out" | grep -c 'the pull FAILED. Read the event')" "1"

# ---- 6. the happy path still passes, and no longer over-claims DNS -------------------------------
out="$(run 'Normal  Pulled  pod/pullprobe  Successfully pulled image "harbor.env1.lab.test/apps/probeimg:0.1.0" in 104ms')"
ck "success -> WORKS"                   "$(printf '%s' "$out" | grep -c 'Node<->Harbor WORKS')" "1"
ck "success -> disclaims DNS"           "$(printf '%s' "$out" | grep -c 'NOT a DNS assertion')" "1"

# ---- 7. no event at all -> inconclusive (unchanged) ---------------------------------------------
out="$(run '')"
ck "no event -> inconclusive"           "$(printf '%s' "$out" | grep -c 'inconclusive')" "1"

# ---- 8. TENANT RBAC. An ensure_namespace refusal used to be swallowed and surface as
#         "inconclusive - no pull event ... within the wait budget": an RBAC denial reported as a
#         TIMING problem. It must now SKIP, say RBAC, and name the PROBE_NS fallback.
# ⚠️ THE FIXTURE IS AN EMPTY EVENT LIST, DELIBERATELY. With a successful-pull fixture the
# `NOT inconclusive` assertion below is VACUOUS -- the old swallowing code walks past the refusal
# and prints WORKS, so it reads 0 either way (MEASURED: mutation 2 left that one assertion green).
# An empty event list is the state the founding incident actually produced -- every apply failed
# silently, so no pod, so no event -- and it is the only fixture in which the old code prints the
# misleading "inconclusive ... within the wait budget" line this arm exists to replace.
mk_kubectl 1
out="$(run '')"
ck "RBAC refusal -> SKIPs"              "$(printf '%s' "$out" | grep -c 'could not create namespace')" "1"
ck "RBAC refusal -> names RBAC"         "$(printf '%s' "$out" | grep -c 'this is RBAC, not a lab fault')" "1"
ck "RBAC refusal -> names PROBE_NS"     "$(printf '%s' "$out" | grep -c 'PROBE_NS=<your-namespace>')" "1"
ck "RBAC refusal -> NOT 'inconclusive'" "$(printf '%s' "$out" | grep -c 'inconclusive')" "0"

# ---- 9. an OPERATOR-SUPPLIED namespace must NEVER be deleted. Case 8 tells a tenant to pass
#         PROBE_NS, which ARMS `_cleanup` -- so the ownership flag is part of that fix, not a nicety.
mk_kubectl 0
: > "$T/delcalls"
cat > "$T/bin/kubectl" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"delete ns"*)         printf 'x' >> "$T/delcalls"; exit 0 ;;
  *"get events"*)        cat "$T/ev"; exit 0 ;;
  *"get pod pullprobe"*) printf 'Pending|ErrImagePull'; exit 0 ;;
  *"current-context"*)   printf 'fake@fake'; exit 0 ;;
  *)                     exit 0 ;;
esac
STUB
chmod +x "$T/bin/kubectl"
printf '%s\n' 'Normal Pulled Successfully pulled image "x" in 104ms' > "$T/ev"
PATH="$T/bin:$PATH" REPO_ROOT="$T" SKIP_DOTENV=1 KUBECONFIG="$T/kubeconfig" \
  HARBOR_URL="harbor.env1.lab.test" HARBOR_CA_FILE="$T/nope.crt" \
  PROBE_IMAGE="harbor.env1.lab.test/apps/x:1" PROBE_NS="my-own-namespace" \
  PROBE_WAIT_ITERATIONS=1 PROBE_WAIT_INTERVAL=0 \
  bash "$SCRIPT_DIR/vks-trust-probe.sh" >/dev/null 2>&1
ck "operator PROBE_NS -> NOT deleted"   "$(wc -c < "$T/delcalls" | tr -d ' ')" "0"

: > "$T/delcalls"
PATH="$T/bin:$PATH" REPO_ROOT="$T" SKIP_DOTENV=1 KUBECONFIG="$T/kubeconfig" \
  HARBOR_URL="harbor.env1.lab.test" HARBOR_CA_FILE="$T/nope.crt" \
  PROBE_IMAGE="harbor.env1.lab.test/apps/x:1" \
  PROBE_WAIT_ITERATIONS=1 PROBE_WAIT_INTERVAL=0 \
  bash "$SCRIPT_DIR/vks-trust-probe.sh" >/dev/null 2>&1
ck "invented PROBE_NS -> IS deleted"    "$([ "$(wc -c < "$T/delcalls" | tr -d ' ')" -ge 1 ] && echo deleted || echo leaked)" "deleted"

printf '\n  %s passed, %s failed\n' "$p" "$f"
[ "$f" -eq 0 ] || exit 1
