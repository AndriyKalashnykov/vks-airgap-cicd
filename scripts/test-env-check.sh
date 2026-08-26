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
# ⚠️ THIS FIXTURE USED TO BE `: > "$TMP/real.kc"` — a ZERO-BYTE FILE. The gate tested `-f`, which a
# 0-byte file satisfies, so the GREEN case was ASSERTING THE BUG: an empty kubeconfig passed
# env-check, and kubectl then silently fell back to localhost:8080 with an error naming neither the
# file nor this gate. That is the exact shape row 5 of the VM matrix hit, and a 0-byte
# secrets/testcluster.kubeconfig was sitting in the tree when it was found. The gate is `-s` now, so
# the fixture must contain something.
printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$TMP/real.kc"
if run_check "harbor.example.com" "$TMP/real.kc"; then ok "GREEN: env-check passed with real values + present kubeconfig"; else bad "GREEN: env-check FAILED with real values"; cat "$TMP/out" >&2; fi

# RED2b — an EMPTY kubeconfig must be refused, not merely an absent one. Without this case the
# `-f` -> `-s` fix has no guard and reverts silently.
: > "$TMP/empty.kc"
if run_check "harbor.example.com" "$TMP/empty.kc"; then bad "RED2b: env-check PASSED with a 0-BYTE kubeconfig"; else ok "RED2b: env-check refused a 0-byte kubeconfig"; fi
grep -qE 'KUBECONFIG.*(EMPTY|missing)' "$TMP/out" || bad "RED2b: the failure did not say the file was empty"

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

# --- B473 finding 9: a LOOPBACK server sitting in the LAB slot -----------------------------------
# PRESENCE is not identity. `./secrets/vks.kubeconfig` is the DOCUMENTED real-lab guest default, and a
# KinD run of an older vintage wrote ITS kubeconfig there. MEASURED 2026-08-26 on this box: that file
# held `server: https://127.0.0.1:42961`, the -s check above passed, and the first thing that noticed
# was env-validate — a REACHABILITY gate that needs the network and is a separate step.
#
# ⚠️ The GREEN cases are the load-bearing ones. A check that only ever refuses is indistinguishable
# from one that refuses everything, and this one MUST NOT fire on KinD, where loopback is CORRECT.
kc_with() {  # $1 = server URL  -> writes a parseable kubeconfig with a current-context
  cat > "$TMP/lb.kc" <<EOF
apiVersion: v1
kind: Config
current-context: c
clusters: [{name: cl, cluster: {server: $1, insecure-skip-tls-verify: true}}]
contexts: [{name: c, context: {cluster: cl, user: u}}]
users: [{name: u, user: {token: x}}]
EOF
}
run_kc() {  # $1 = VKS_STATE_KIND value  [$2 = extra PATH prefix]
  write_env "harbor.example.com"
  env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u VKS_STATE_FILE \
    ${2:+PATH="$2:$PATH"} REPO_ROOT="$TMP" KUBECONFIG="$TMP/lb.kc" VKS_STATE_KIND="$1" \
    bash "$ENVSH" check >"$TMP/out" 2>&1
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "skip  B473-9 loopback cases (kubectl absent — the check fails open by design)"
else
  # RED — loopback in the LAB slot must be refused, and must NAME the address and the file.
  kc_with 'https://127.0.0.1:42961'
  if run_kc 0; then bad "B473-9 RED: env-check PASSED on a LOOPBACK kubeconfig in the lab slot"
  else ok "B473-9 RED: loopback in the lab slot refused"; fi
  grep -q '127.0.0.1:42961' "$TMP/out" || bad "B473-9 RED: the refusal did not name the address"
  grep -q 'lb.kc'           "$TMP/out" || bad "B473-9 RED: the refusal did not name the file"

  # GREEN — the SAME shape with a routable server must pass. Without this the check could be
  # refusing every kubeconfig and the RED above would not notice.
  kc_with 'https://192.168.101.132:6443'
  if run_kc 0; then ok "B473-9 GREEN: a routable server passes"
  else bad "B473-9 GREEN: a routable kubeconfig was REFUSED"; cat "$TMP/out" >&2; fi

  # GREEN — loopback is CORRECT for KinD. VKS_STATE_KIND is the discriminator, not the address.
  kc_with 'https://127.0.0.1:42961'
  if run_kc 1; then ok "B473-9 GREEN: loopback accepted when VKS_STATE_KIND=1 (KinD)"
  else bad "B473-9 GREEN: the check fired on KinD, where loopback is correct"; cat "$TMP/out" >&2; fi

  # GREEN — FAIL OPEN when the config cannot be read. A presence gate that starts refusing what it
  # cannot parse is worse than the defect it was added for.
  mkdir -p "$TMP/stub"; printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/stub/kubectl"; chmod +x "$TMP/stub/kubectl"
  kc_with 'https://127.0.0.1:42961'
  if run_kc 0 "$TMP/stub"; then ok "B473-9 GREEN: unreadable config skips the check (fails OPEN)"
  else bad "B473-9: a kubectl that cannot read the config turned into a REFUSAL"; cat "$TMP/out" >&2; fi
fi

if [ "$fail" -eq 0 ]; then echo "test-env-check: OK"; else echo "test-env-check: FAILED"; exit 1; fi
