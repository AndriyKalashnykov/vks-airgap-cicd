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
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

# ⚠️ WHAT USED TO STAND BETWEEN THIS TEST AND vCenter WAS AN EMPTY FILE (B751). The script under
# test is run for real, and 5 lines after the pair check it calls vc_login -- a POST of
# VCENTER_USERNAME/VCENTER_PASSWORD to VCENTER_HOST. MEASURED with a line trace: an ACCEPTED pair
# ran on to `die "hostname did not render"`, and only because the fixture template is zero bytes.
# REPO_ROOT was the real repo and VKS_STATE_FILE was unset, so the .env.state overlay (the
# discovered vCenter credentials) WAS sourced. A fixture with one more line would have logged in.
# Now: the helper above gives a sandbox REPO_ROOT, where no state overlay exists; curl is a stub that
# fails and COUNTS; and VCENTER_HOST names a host that cannot exist.
mkdir -p "$TMP/bin"; CURL_CALLS="$TMP/curl.calls"; : > "$CURL_CALLS"
# shellcheck disable=SC2016  # $* and $CURL_CALLS belong to the stub, at ITS run time
printf '#!/bin/sh\necho "curl $*" >> "$CURL_CALLS"\nexit 7\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
export CURL_CALLS
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
      PATH="$TMP/bin:$PATH" VCENTER_HOST=vc.invalid \
      bash "${TEST_REAL_REPO}/scripts/04-install-harbor-service.sh" >"$TMP/out" 2>&1 || true
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

# Six runs of the real installer, three of them past the pair check -- and not one network call.
# If this goes red the script now gets FURTHER on these fixtures than it did (it reached the curl
# stub), which is exactly when the fence above stops being a precaution: read what it called.
if [ ! -s "$CURL_CALLS" ]; then ok "the installer made NO curl call in any run (it never reached vc_login)"
else bad "the installer reached curl $(wc -l < "$CURL_CALLS" | tr -d ' ') time(s): $(head -1 "$CURL_CALLS")"; fi
case "${REPO_ROOT}" in "${TEST_SANDBOX}"/*) ok "the installer ran with a sandbox REPO_ROOT, not this checkout" ;;
  *) bad "REPO_ROOT is not the sandbox root (${REPO_ROOT})" ;; esac

if [ "$fail" -eq 0 ]; then echo "test-harbor-pair-version: OK"; else echo "test-harbor-pair-version: FAILED"; exit 1; fi
