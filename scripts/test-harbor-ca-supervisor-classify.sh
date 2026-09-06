#!/usr/bin/env bash
# test-harbor-ca-supervisor-classify.sh — an EMPTY namespace list must not be read as "Harbor is not
# installed" when the kubeconfig is simply the GUEST cluster (B210).
#
# WHY THIS EXISTS. `kubectl get ns -l <anything>` is rc=0-BY-CONSTRUCTION on any cluster: namespaces
# exist everywhere and labels are freeform. So an empty result is AMBIGUOUS — it is the TRUE answer
# on a Supervisor with no Harbor yet (scenario-1 before Step 4), and it is ALSO exactly what a GUEST
# kubeconfig returns. 27-harbor-ca-from-cluster.sh used to answer both with one bare die, and that
# die is confidently wrong for the second: it tells an operator to go look for a Harbor that is
# running, on a cluster that structurally cannot have it.
#
# ci-tier: fast
#
# Offline: a stub kubectl plays each shape. The stub SKIPS --request-timeout positionally, like its
# siblings — 27 passes that flag, and a stub that does not know it mis-parses and looks like a
# product bug rather than a harness bug.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$TMP/sup.kubeconfig"

cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=("$@"); i=0; sub=""
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in
  --kubeconfig) i=$((i+2));; --request-timeout=*) i=$((i+1));; --request-timeout) i=$((i+2));;
  *) sub="${args[$i]}"; break;; esac; done
case "$sub" in
  version)
    # tier 1 of kubeconfig_is_supervisor. `undetermined` models an endpoint we cannot reach at all,
    # which must yield rc=2 -> "could not determine", NOT "this is not a Supervisor".
    case "${STUB_MODE:-guest}" in
      undetermined) echo 'Unable to connect to the server: dial tcp: i/o timeout' >&2; exit 1 ;;
      *)            echo "Client Version: v1.34.0"; exit 0 ;;
    esac ;;
  api-resources)
    # tier 2. A NON-EMPTY vmoperator list is what makes a cluster a Supervisor. VM Operator is a core
    # Supervisor component and is independent of Harbor (Step 4), which is why a BARE Supervisor
    # still answers here — that is the whole reason this key was chosen over a Harbor-shaped probe.
    case "${STUB_MODE:-guest}" in
      bare_sup) echo "virtualmachines vm vmoperator.vmware.com/v1alpha2 true VirtualMachine" ;;
      *)        : ;;                       # guest: the API group does not exist -> empty -> rc=1
    esac; exit 0 ;;
  get) exit 0 ;;                           # ZERO serviceId=harbor namespaces, rc=0, on every mode
  *)   exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

run() {   # run <STUB_MODE>
  ( cd "$SCRIPT_DIR/.." && env PATH="$TMP/bin:$PATH" STUB_MODE="$1" SKIP_DOTENV=1 \
      VKS_SUPERVISOR_KUBECONFIG="$TMP/sup.kubeconfig" HARBOR_URL=harbor.example.test \
      HARBOR_INSECURE=1 bash scripts/27-harbor-ca-from-cluster.sh "$TMP/ca.crt" ) >"$TMP/out" 2>&1
  return $?
}
saw() { grep -qi -- "$1" "$TMP/out"; }

# POSITIVE CONTROL. Every assertion below is a NEGATIVE ("must not say X"), and a negative passes
# trivially when the script never ran. MEASURED: the first version of this harness omitted 27's
# required <out-file> argument, so it exited at its usage line and TWO cases reported PASS having
# tested nothing. This asserts the script actually reached the namespace probe.
control() {
  if saw "usage:"; then
    bad "POSITIVE CONTROL" "27 exited at its usage line — the harness never reached the code, so
        every negative assertion below would pass vacuously"
    return 1
  fi
  return 0
}

# --- 1. a GUEST kubeconfig must be NAMED, not reported as "Harbor is missing" -------------------
run guest || true
control || true
if saw 'not a Supervisor'; then ok "guest: the message names the WRONG-CLUSTER cause"
else bad "guest: the message names the WRONG-CLUSTER cause" "$(tail -3 "$TMP/out")"; fi
if saw 'vmoperator'; then ok "guest: it says WHICH capability was missing (not a bare assertion)"
else bad "guest: it says which capability was missing" "no vmoperator in the output"; fi
# The hedge is load-bearing: an identity that authenticates but may not perform API discovery would
# look identical, and B210's round could not rule that out from this box.
if saw 'strong evidence, not proof'; then ok "guest: hedged — discovery-denied would look identical"
else bad "guest: hedged" "it asserts more than the probe can support"; fi

# --- 2. a BARE Supervisor must keep the ORIGINAL message ----------------------------------------
# This is the true-negative pin. scenario-1 puts every new operator in exactly this state before
# Step 4, so a change that made THIS case say "not a Supervisor" would be a false-block on the
# repo's own documented happy path.
run bare_sup || true
control || true
if saw 'not a Supervisor'; then bad "bare Supervisor must NOT be called a guest" "it was"
else ok "bare Supervisor: does NOT claim 'not a Supervisor'"; fi
if saw 'EXACTLY ONE namespace'; then ok "bare Supervisor: keeps the original serviceId message"
else bad "bare Supervisor: keeps the original message" "$(tail -3 "$TMP/out")"; fi

# --- 3. COULD-NOT-DETERMINE must not be reported as a verdict -----------------------------------
# rc==2, not rc==1. Reading "unreachable" as "not a Supervisor" would swap one confidently-wrong
# message for another — which is the entire failure class B210 exists to close.
run undetermined || true
control || true
if saw 'not a Supervisor'; then bad "unreachable must NOT be called 'not a Supervisor'" "it was"
else ok "unreachable: makes no claim about what the cluster is"; fi

printf '\nharbor-ca supervisor classify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
