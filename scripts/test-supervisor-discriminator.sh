#!/usr/bin/env bash
# test-supervisor-discriminator.sh — RED-proof for kubeconfig_is_supervisor() + not_a_supervisor_note().
#
# WHY THIS EXISTS. B210 concluded "there is no Supervisor-vs-guest discriminator" after two CRD reads
# failed, and ~11 scripts therefore read an rc=0-EMPTY answer as a fact about the world: they told an
# operator "Harbor is not installed / the Supervisor rejected your credentials" when the credential
# was fine and the only mistake was asking the GUEST cluster. The discriminator is API-GROUP
# DISCOVERY, not a CRD read.
#
# ⚠️ THE TRAP THIS TEST PINS: `kubectl api-resources --api-group=<absent>` EXITS 0 and prints only a
# header. So rc is USELESS and the implementation MUST assert a non-empty list. Case 2 below is the
# one that fails if anyone "simplifies" it back to a status check.
#
# Offline by construction: kubectl is a STUB on PATH, so this needs no cluster and cannot be flaky.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/os.sh" 2>/dev/null

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n         got: %s\n    wanted: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
mk_kubectl() {  # $1 = what `api-resources` prints on stdout
  cat > "$STUB/kubectl" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *" api-resources "*) printf '%s' '$1' ;;
  *) exit 0 ;;
esac
exit 0
STUBEOF
  chmod +x "$STUB/kubectl"
}
KC="$STUB/kc"; : > "$KC"

# 1. a SUPERVISOR: the group is served, so the list is non-empty.
mk_kubectl 'virtualmachineclasses  vmclass  vmoperator.vmware.com/v1alpha5  false  VirtualMachineClass
'
if PATH="$STUB:$PATH" kubeconfig_is_supervisor "$KC"; then ok "a non-empty api-group list => SUPERVISOR"
else bad "a non-empty api-group list must read as SUPERVISOR" "rc!=0" "rc=0"; fi

# 2. ⚠️ THE LOAD-BEARING CASE. A guest exits 0 and prints NOTHING. If the implementation ever keys on
#    rc instead of the list, this case flips and every consumer silently mis-identifies a guest as a
#    Supervisor -- which is B210 restored, with a green test suite.
mk_kubectl ''
if PATH="$STUB:$PATH" kubeconfig_is_supervisor "$KC"; then
  bad "an EMPTY list at rc=0 must NOT read as SUPERVISOR (this is the whole bug)" "rc=0" "rc!=0"
else ok "an EMPTY list at rc=0 => NOT a Supervisor (rc is useless here; the LIST decides)"; fi

# 3. a header-only reply is still empty of RESOURCES. --no-headers is what makes case 2 hold, so a
#    change that drops that flag must fail here rather than pass by accident.
mk_kubectl 'NAME  SHORTNAMES  APIVERSION  NAMESPACED  KIND
'
if PATH="$STUB:$PATH" kubeconfig_is_supervisor "$KC"; then
  printf '  note  a header-only reply read as SUPERVISOR — that means --no-headers was dropped\n'
  bad "header-only must not read as SUPERVISOR" "rc=0" "rc!=0"
else ok "header-only (i.e. --no-headers dropped) does not read as SUPERVISOR"; fi

# 4. no kubeconfig at all is not a Supervisor -- and must not blow up.
if kubeconfig_is_supervisor "" 2>/dev/null; then bad "an empty kubeconfig path must not read as SUPERVISOR" "rc=0" "rc!=0"
else ok "an empty kubeconfig path => NOT a Supervisor"; fi

# 5. the note must name the CAUSE, the FIX and the TENANT case. A message that says only "not a
#    Supervisor" sends the reader hunting; RULE ZERO-B's whole point is that the default operator
#    CANNOT get a Supervisor kubeconfig and must be told to ask instead of to run something.
note="$(not_a_supervisor_note)"
for want in 'vmoperator.vmware.com' 'GUEST' 'VKS_SUPERVISOR_KUBECONFIG' 'make vks-login' 'TENANT'; do
  case "$note" in *"$want"*) ok "the note names '$want'" ;;
                   *) bad "the note must name '$want'" "absent" "present" ;; esac
done

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
