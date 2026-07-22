#!/usr/bin/env bash
# test-env-check.sh — `make env-check` is a PRESENCE gate; it MUST fail when a required value is
# missing or still the committed placeholder.
#
# WHY THIS EXISTS (a demonstrated false-green, not a hypothetical)
# ---------------------------------------------------------------------------
# On a bare jump box `make env-check` used to report "all required values present" when NEITHER Harbor
# NOR a kubeconfig was real:
#   * HARBOR_URL defaults to `harbor.vks.local` (.env.example) — a real-looking hostname that
#     is_placeholder() cannot catch, so the presence loop accepted it.
#   * load_env DEFAULTS KUBECONFIG to `secrets/vks.kubeconfig` (lib/os.sh), so the value was always
#     "set" even when the FILE did not exist.
# env_validate already special-cased the sentinel and existence-checked the file; env_check did not —
# so the two gates disagreed and check gave the false green. This test proves the RED.
#
# HERMETIC: a TEMP repo root holding a COPIED .env.example (load_env sources it unconditionally, so a
# missing one would `set -e`-kill the run) + a fabricated .env; KUBECONFIG is driven via the
# ENVIRONMENT (load_env snapshots/restores non-empty selectors, so the value survives the built-in
# default). The test's own env is stripped of any stray HARBOR_URL/KUBECONFIG/HARBOR_CA_FILE — either
# would be snapshotted and pin the value regardless of the fabricated .env.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVSH="$REPO/scripts/02-env.sh"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$REPO/.env.example" "$TMP/.env.example"

# A .env with everything real EXCEPT the value each case is probing.
write_env() {  # $1 = HARBOR_URL
  cat > "$TMP/.env" <<EOF
HARBOR_URL=$1
HARBOR_USERNAME=admin
HARBOR_PASSWORD=Sup3rStr0ngPw
GITEA_ADMIN_PASSWORD=Sup3rStr0ngPw
VKS_AUTH_METHOD=kubeconfig
EOF
}

run_check() {  # $1 = HARBOR_URL   $2 = KUBECONFIG path
  write_env "$1"
  env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u VKS_STATE_FILE \
    REPO_ROOT="$TMP" KUBECONFIG="$2" bash "$ENVSH" check >"$TMP/out" 2>&1
}

# RED1 — sentinel HARBOR_URL + absent kubeconfig -> FAIL, naming BOTH.
if run_check "harbor.vks.local" "$TMP/nope.kc"; then bad "RED1: env-check PASSED on the sentinel + absent kubeconfig"; else ok "RED1: env-check failed on sentinel + absent kubeconfig"; fi
grep -q HARBOR_URL "$TMP/out" || bad "RED1: failure did not name HARBOR_URL"
grep -q KUBECONFIG "$TMP/out" || bad "RED1: failure did not name KUBECONFIG"

# RED2 — real HARBOR_URL but absent kubeconfig -> FAIL, naming KUBECONFIG.
if run_check "harbor.example.com" "$TMP/nope.kc"; then bad "RED2: env-check PASSED with an absent kubeconfig"; else ok "RED2: env-check failed on absent kubeconfig"; fi
grep -q KUBECONFIG "$TMP/out" || bad "RED2: failure did not name KUBECONFIG"

# GREEN — real HARBOR_URL + a present kubeconfig file + all secrets -> PASS.
: > "$TMP/real.kc"
if run_check "harbor.example.com" "$TMP/real.kc"; then ok "GREEN: env-check passed with real values + present kubeconfig"; else bad "GREEN: env-check FAILED with real values"; cat "$TMP/out" >&2; fi

# --- VKS_AUTH_METHOD=vcf ---------------------------------------------------------------------
# This branch had ZERO coverage, which is how env-check came to hard-require two variables that
# 30-vks-login.sh defaults/discovers. The operator's obvious remedy for that failure (set
# VKS_NAMESPACE) takes the `if [ -z … ]` branch and permanently DISABLES discovery — so a false RED
# here is not a nag, it silently removes a feature.
write_env_vcf() {  # $1 = extra lines
  cat > "$TMP/.env" <<EOF
HARBOR_URL=harbor.example.com
HARBOR_USERNAME=admin
HARBOR_PASSWORD=Sup3rStr0ngPw
GITEA_ADMIN_PASSWORD=Sup3rStr0ngPw
VKS_AUTH_METHOD=vcf
SUPERVISOR_HOST=10.1.8.132
VKS_CONTEXT_NAME=sup
${1:-}
EOF
}
run_check_vcf() {
  env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u VKS_STATE_FILE -u VKS_USERNAME -u VKS_NAMESPACE \
    REPO_ROOT="$TMP" KUBECONFIG="$TMP/real.kc" bash "$ENVSH" check >"$TMP/out" 2>&1
}

# GREEN — the DOCUMENTED lab .env: neither VKS_USERNAME nor VKS_NAMESPACE set (both are optional on
# this path). If this ever goes red, discovery is about to be disabled for every operator.
write_env_vcf ""
if run_check_vcf; then
  ok "vcf: env-check passes WITHOUT VKS_USERNAME/VKS_NAMESPACE (they are defaulted/discovered)"
else
  bad "vcf: env-check FAILED on a correctly-configured lab .env — it is demanding a var the login script discovers"
  cat "$TMP/out" >&2
fi

# RED — the vars this path really does need are still enforced.
write_env_vcf "" ; sed -i '/^VKS_CONTEXT_NAME=/d' "$TMP/.env"
if run_check_vcf; then bad "vcf: env-check passed with VKS_CONTEXT_NAME missing"; else ok "vcf: env-check still fails on a genuinely required var"; fi
grep -q VKS_CONTEXT_NAME "$TMP/out" || bad "vcf: failure did not name VKS_CONTEXT_NAME"

if [ "$fail" -eq 0 ]; then echo "test-env-check: OK"; else echo "test-env-check: FAILED"; exit 1; fi
