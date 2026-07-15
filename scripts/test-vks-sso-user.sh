#!/usr/bin/env bash
# test-vks-sso-user.sh — vks_sso_user() (lib/os.sh) normalises a VKS SSO username to 'user@SSO.DOMAIN'
# WITHOUT double-domaining an already-qualified name.
#
# WHY (C10): 31-fetch-argocd-kubeconfig.sh appended '@${SSO_DOMAIN}' UNCONDITIONALLY, so a doc shipping
# VKS_USERNAME=administrator@vsphere.local produced 'administrator@vsphere.local@vsphere.local' — auth
# fails, reads as "wrong password". The helper is idempotent on '@' and refuses to silently default the
# domain (real VCF workload domains are custom, e.g. WLD.SSO). Offline, pure-string.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# already-qualified -> UNCHANGED (the C10 regression: must NOT append a second @domain)
out="$(VKS_SSO_DOMAIN=vsphere.local vks_sso_user 'administrator@vsphere.local')"
if [ "$out" = 'administrator@vsphere.local' ]; then ok "qualified username unchanged ($out)"; else bad "double-domained: got '$out'"; fi

# already-qualified beats a DIFFERENT VKS_SSO_DOMAIN (the '@' wins)
out="$(VKS_SSO_DOMAIN=WLD.SSO vks_sso_user 'administrator@vsphere.local')"
if [ "$out" = 'administrator@vsphere.local' ]; then ok "qualified beats VKS_SSO_DOMAIN ($out)"; else bad "got '$out'"; fi

# bare user + VKS_SSO_DOMAIN -> appended
out="$(VKS_SSO_DOMAIN=WLD.SSO vks_sso_user 'administrator')"
if [ "$out" = 'administrator@WLD.SSO' ]; then ok "bare user + domain -> $out"; else bad "got '$out'"; fi

# bare user + NO VKS_SSO_DOMAIN -> DIES (no silent 'vsphere.local' default — the wrong-principal trap)
if ( unset VKS_SSO_DOMAIN; vks_sso_user 'administrator' ) >/dev/null 2>&1; then
  bad "bare user with no VKS_SSO_DOMAIN did NOT die (a silent default is the C10 failure class)"
else
  ok "bare user with no VKS_SSO_DOMAIN dies (no silent default)"
fi

if [ "$fail" -eq 0 ]; then echo "test-vks-sso-user: OK"; else echo "test-vks-sso-user: FAILED"; exit 1; fi
