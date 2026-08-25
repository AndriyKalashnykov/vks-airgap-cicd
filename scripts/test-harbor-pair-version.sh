#!/usr/bin/env bash
# scripts/test-harbor-pair-version.sh — the Harbor def/values pair check must accept the naming the
# VENDOR ACTUALLY SHIPS, and still refuse a genuinely mismatched pair.
#
# WHY THIS EXISTS. The check compared the two filename-derived versions with whole-string equality.
# Broadcom names the two halves of one pair at DIFFERENT granularity — measured on a real download:
#     definition:  supervisor-service-harbor-legacy-v2.14.3+vmware.2-vks.1-25292931.yml
#     data-values: supervisor-service-harbor-data-values-v2.14.3.yml
# so the ONLY naming the vendor ships was rejected. It FATAL'd `make install-harbor-service` one
# second in and took out a walkthrough-matrix cut-B run: row 3 failed with 10 blocks, rows 4 and 6
# were never walked. It had never fired before because it is only reachable on a NOTHING-exists row
# — the rows that actually install Harbor — which had not run since the check was added.
#
# The gate is driven END-TO-END here (real script, fixture SRC_DIR) rather than by re-implementing
# its comparison, because re-implementing it is how a test agrees with a bug.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# Run 04 far enough to pass (or trip) the pair check. It dies later for want of a cluster; we only
# ever assert on whether the MISMATCH message appeared, never on the exit code.
run_pair() {   # run_pair <def-version> <tpl-version>
  local d="$TMP/src"; rm -rf "$d"; mkdir -p "$d"
  : > "${d}/supervisor-service-harbor-legacy-v${1}.yml"
  : > "${d}/supervisor-service-harbor-data-values-v${2}.yml"
  env HARBOR_URL=harbor.example.test HARBOR_STORAGE_CLASS=wcp-vmfs \
      VCF_CLI_SRC_DIR="$d" SKIP_DOTENV=1 KUBECONFIG="$TMP/none.kc" \
      bash "${REPO_ROOT}/scripts/04-install-harbor-service.sh" >"$TMP/out" 2>&1 || true
  grep -q 'version MISMATCH' "$TMP/out" && printf 'MISMATCH' || printf 'accepted'
}

# THE CASE THAT BROKE THE MATRIX. def carries build metadata, tpl does not — same release.
r="$(run_pair '2.14.3+vmware.2-vks.1-25292931' '2.14.3')"
if [ "$r" = accepted ]; then ok "the vendor's real naming is ACCEPTED (def stamped, values bare)"
else bad "the vendor's real naming was REJECTED — this is the regression ($r)"; fi

# Still refuses a genuine mismatch, with and without metadata.
r="$(run_pair '2.14.3' '2.9.1')"
if [ "$r" = MISMATCH ]; then ok "a genuinely different release is REFUSED"; else bad "2.14.3 vs 2.9.1 accepted ($r)"; fi

r="$(run_pair '2.14.3+vmware.2' '2.9.1')"
if [ "$r" = MISMATCH ]; then ok "different release refused even when one side is stamped"; else bad "stamped-vs-different accepted ($r)"; fi

# Build metadata is compared when BOTH sides carry it.
r="$(run_pair '2.14.3+vmware.2' '2.14.3+vmware.3')"
if [ "$r" = MISMATCH ]; then ok "two DIFFERENT builds of one release are REFUSED"; else bad "vmware.2 vs vmware.3 accepted ($r)"; fi

r="$(run_pair '2.14.3+vmware.2' '2.14.3+vmware.2')"
if [ "$r" = accepted ]; then ok "identical stamped pair is accepted"; else bad "identical stamped pair refused ($r)"; fi

r="$(run_pair '2.14.3' '2.14.3')"
if [ "$r" = accepted ]; then ok "identical bare pair is accepted"; else bad "identical bare pair refused ($r)"; fi

if [ "$fail" -eq 0 ]; then echo "test-harbor-pair-version: OK"; else echo "test-harbor-pair-version: FAILED"; exit 1; fi
