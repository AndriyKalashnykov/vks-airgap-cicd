#!/usr/bin/env bash
# test-vks-class-readback.sh — B490. `25-vks-cluster-create.sh` must report the ClusterClass the
# Supervisor ACTUALLY STORED, not the one we asked for.
#
# WHY. MEASURED 2026-08-26 on VKS 3.7.1+v1.36 via six server-side dry-runs: the Supervisor's
# mutating webhook rewrites spec.topology.classRef.name to the newest compatible ClusterClass, and
# it does so EVEN WHEN THE ASKED CLASS IS ALREADY IN RANGE (asked builtin-generic-v3.6.0 with
# v1.35.6, which v3.6.0 supports; stored v3.7.0). rc is 0 and the only notice is a `Warning:` on the
# dry-run's stderr — which this script used to `rm -f` UNREAD on success.
#
# So the defect was never "the default is stale" (a discovery script was designed for that and
# REFUTED — admission would discard whatever it computed). The defect is REPORTING: we logged
# `class: builtin-generic-v3.6.0` for a cluster that is v3.7.0, and nothing read the object back. A
# green six-row certification would record the wrong class — the exact outcome B490 exists to stop.
#
# ⚠️ These cases are also correct if a FUTURE VKS stops auto-bumping: a read-back is right under
# both behaviours, which is precisely why it beat the discovery script.
#
# Offline by construction: kubectl is a STUB. envsubst is real (it renders the committed template).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return 0; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); return 0; }

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
KC="$STUB/sup.kubeconfig"; printf 'apiVersion: v1\nkind: Config\n' > "$KC"
ASKED=builtin-generic-v3.6.0

mk_kubectl() { # mk_kubectl <stored-class-or-empty> <dry-run-stderr-text>
  printf '%s' "$1" > "$STUB/stored"
  printf '%s' "$2" > "$STUB/dryerr"
  cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  # ORDER MATTERS: the classRef read is also a `get cluster`, so it must be matched FIRST.
  *"topology.classRef.name"*)   cat "${STUB_DIR}/stored"; exit 0 ;;
  *"controlPlaneEndpoint.host"*) printf '10.0.0.9\n'; exit 0 ;;
  *"loadBalancer.ingress"*)      printf '10.0.0.9\n'; exit 0 ;;
  *"--dry-run=server"*)
      # rc 0 WITH text on stderr — the shape the platform uses to say it rewrote something.
      [ -s "${STUB_DIR}/dryerr" ] && cat "${STUB_DIR}/dryerr" >&2
      exit 0 ;;
  *" apply "*)                   printf 'cluster.cluster.x-k8s.io/x created\n'; exit 0 ;;
  *"get cluster"*)               printf 'Error from server (NotFound): clusters.cluster.x-k8s.io "x" not found\n' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
}

run() {
  STUB_DIR="$STUB" PATH="$STUB:$PATH" SKIP_DOTENV=1 \
  VKS_SUPERVISOR_KUBECONFIG="$KC" \
  VKS_CLUSTER_NAME=x VKS_NAMESPACE=cicd VKS_K8S_VERSION=v1.36 \
  VKS_CLUSTERCLASS="$ASKED" VKS_VM_CLASS=best-effort-small VKS_STORAGE_CLASS=wcp-vmfs \
  VKS_CONTROL_PLANE_COUNT=1 VKS_NODE_COUNT=2 \
    timeout 90 ./scripts/25-vks-cluster-create.sh 2>&1
}

echo "── the class in effect must be READ BACK, never assumed ───────────────────"

# R1 — THE MEASURED CASE. Stored differs from asked: say so, and say which one to cite.
mk_kubectl builtin-generic-v3.7.0 ''
out="$(run)"
if grep -q 'ClusterClass in effect is builtin-generic-v3.7.0' <<< "$out" \
   && grep -q "NOT the ${ASKED} requested" <<< "$out"; then
  ok "R1 a rewritten class is reported, naming BOTH the stored and the requested"
else bad "R1 the rewrite was not reported: $(grep -iE 'class' <<< "$out" | head -2)"; fi
if grep -q 'Cite builtin-generic-v3.7.0' <<< "$out"; then
  ok "R1 tells the reader which value to put in a report"
else bad "R1 reported the difference but not which one is authoritative"; fi

# R2 — an unreadable object must be UNCONFIRMED, never silently treated as agreeing.
mk_kubectl '' ''
out="$(run)"
if grep -q 'UNCONFIRMED' <<< "$out"; then
  ok "R2 an unreadable class is UNCONFIRMED (not assumed equal)"
else bad "R2 an empty read-back was not surfaced: $(grep -iE 'class' <<< "$out" | head -2)"; fi

# R3 — the dry-run's stderr on a SUCCESSFUL run is where the platform announces a rewrite. It used
# to be `rm -f`'d unread, so the one path built to catch surprises discarded the notice of one.
mk_kubectl builtin-generic-v3.7.0 \
  'Warning: ClusterClass builtin-generic-v3.6.0 updated to the newest compatible ClusterClass builtin-generic-v3.7.0'
out="$(run)"
if grep -q 'updated to the newest compatible' <<< "$out"; then
  ok "R3 dry-run remarks on a rc=0 run are PRINTED, not discarded"
else bad "R3 the platform's own warning was thrown away on success"; fi

echo "── and it must not cry wolf ───────────────────────────────────────────────"

# C1 — agreement is confirmed positively, so a reader can tell "checked" from "not checked".
mk_kubectl "$ASKED" ''
out="$(run)"
if grep -q "class in effect: ${ASKED} (confirmed on the created object)" <<< "$out"; then
  ok "C1 agreement is CONFIRMED explicitly"
else bad "C1 no confirmation line when stored == requested"; fi
if grep -q 'NOT the' <<< "$out"; then
  bad "C1 warned about a rewrite that did not happen"
else ok "C1 no spurious rewrite warning"; fi

# C2 — a clean dry-run must not print an empty 'WITH remarks' banner.
if grep -q 'WITH remarks' <<< "$out"; then
  bad "C2 printed a remarks banner with nothing to remark on"
else ok "C2 no remarks banner when the dry-run said nothing"; fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
