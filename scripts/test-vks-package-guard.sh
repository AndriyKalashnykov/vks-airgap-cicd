#!/usr/bin/env bash
# test-vks-package-guard.sh — RED-proof that vks-package.sh REFUSES a Supervisor kubeconfig.
#
# WHY THIS EXISTS. An idea-round adversary MEASURED, against a live Supervisor and a live guest,
# that a Supervisor serves the SAME Carvel package refNames at the SAME versions (ako, cert-manager,
# cilium, cluster-autoscaler, contour — five byte-identical rows; a Supervisor has MORE packages
# than a guest, not fewer). Every pre-existing guard is therefore VACUOUS on a Supervisor:
#   * `_list`'s "no Carvel Packages visible" die never fires;
#   * `install` never reaches `_list` — it calls `_versions`, which RETURNS versions;
#   * `install` has NO CONFIRM gate (only `uninstall` does).
# So `make install-vks-package` aimed at a Supervisor proceeded UNCONFIRMED and bound cluster-admin
# on the Supervisor control plane. That is what this pins.
#
# Offline by construction: kubectl is a STUB, so this needs no lab and cannot be flaky. The live
# proof needs a Supervisor kubeconfig, which exists only while a lab is up — hence a stub here.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return 0; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); return 0; }

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
KC="$STUB/kc"; printf 'apiVersion: v1\nkind: Config\n' > "$KC"

# A stub kubectl whose ONLY variable is what `api-resources --api-group=vmoperator.vmware.com`
# returns -- that is the discriminator's entire input (API-GROUP DISCOVERY, not a CRD read).
mk_kubectl() { # mk_kubectl <supervisor|guest|unreachable>
  cat > "$STUB/kubectl" <<EOF
#!/usr/bin/env bash
mode=$1
case " \$* " in
  *" version "*)        [ "\$mode" = unreachable ] && exit 1; exit 0 ;;
  *"vmoperator.vmware.com"*)
      [ "\$mode" = supervisor ] && { printf 'virtualmachineclasses  vmclass  vmoperator.vmware.com/v1alpha5\n'; exit 0; }
      exit 0 ;;   # a guest prints NOTHING (header suppressed by --no-headers) and still EXITS 0
  *" config "*)         printf 'stub-context\n'; exit 0 ;;
  # WARNING: this arm used to be written with " get " and " packages " as two separate
  # space-padded globs, which under a case over the space-padded argv can NEVER match -- the
  # first glob consumes the space BEFORE packages, leaving nothing for the second to match.
  # Harmless only because it and the fallthrough both produced empty output, and actively
  # misleading the moment the harness needs a real package list. Match the pair as ONE token.
  # (B489.) And keep this comment free of backticks: the heredoc is UNQUOTED, so a backtick
  # here is command substitution -- writing one produced 8 lines of shell errors mid-test.
  *"get packages"*) printf '{"items":[]}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
}

run() { PATH="$STUB:$PATH" KUBECONFIG="$KC" timeout 30 ./scripts/vks-package.sh "$@" 2>&1; }

# ── 1. a SUPERVISOR must be REFUSED on install ────────────────────────────────────────────────
mk_kubectl supervisor
out="$(run install istio.kubernetes.vmware.com)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSING'; then
  ok "install against a SUPERVISOR is REFUSED"
else bad "install against a SUPERVISOR was NOT refused (rc=$rc): $(printf '%s' "$out" | tail -2)"; fi

# ── 2. ...and on uninstall, BEFORE the CONFIRM prompt (which install does not even have) ───────
out="$(run uninstall istio.kubernetes.vmware.com)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSING'; then
  ok "uninstall against a SUPERVISOR is REFUSED"
else bad "uninstall against a SUPERVISOR was NOT refused (rc=$rc)"; fi

# ── 3. the refusal must NAME the cluster and say what to do ────────────────────────────────────
if printf '%s' "$out" | grep -q 'stub-context' && printf '%s' "$out" | grep -q 'Point KUBECONFIG at the guest'; then
  ok "the refusal names the cluster and the remedy"
else bad "the refusal does not name the cluster/remedy"; fi

# ── 4. a GUEST must NOT be refused (the false-block direction) ─────────────────────────────────
mk_kubectl guest
out="$(run uninstall nothing.here)"; rc=$?
if printf '%s' "$out" | grep -q 'REFUSING'; then
  bad "a GUEST kubeconfig was wrongly refused"
else ok "a GUEST kubeconfig is NOT refused"; fi

# ── 5. UNREACHABLE must FAIL OPEN — an air-gapped or slow lab must not be blocked by a probe
#      that could not reach it. This is the arm that keeps the gate from becoming a liability.
mk_kubectl unreachable
out="$(run uninstall nothing.here)"; rc=$?
if printf '%s' "$out" | grep -q 'REFUSING'; then
  bad "an UNREACHABLE cluster was refused — the gate must fail OPEN on rc=2"
else ok "an UNREACHABLE cluster fails OPEN (proceeds, warns, not a pass)"; fi

# ── 6. `list` is READ-ONLY and must never be gated ─────────────────────────────────────────────
mk_kubectl supervisor
out="$(run list)"; rc=$?
if printf '%s' "$out" | grep -q 'REFUSING'; then
  bad "read-only 'list' was gated — it mutates nothing and must stay usable"
else ok "read-only 'list' is not gated"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
