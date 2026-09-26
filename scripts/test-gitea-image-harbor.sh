#!/usr/bin/env bash
# test-gitea-image-harbor.sh — 40-install-gitea.sh requires Harbor only when the image comes FROM Harbor.
#
# The cross-cluster e2e installs Gitea from an explicit public GITEA_IMAGE and has no HARBOR_URL (the
# stamped .env.state is correctly refused for the guest kubeconfig), and it died on `: "${HARBOR_URL:?}"`.
# kubectl and curl are STUBS that record and fail, so the script stops at its first cluster call;
# what matters is what happened BEFORE it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "STUB-KUBECTL $*" >&2\nexit 97\n' > "$T/bin/kubectl"
# curl records to a FILE: the Harbor probe discards curl's stderr, so a stderr marker is invisible.
printf '#!/bin/sh\necho "STUB-CURL $*" >> "%s/curl.calls"\nexit 7\n' "$T" > "$T/bin/curl"
chmod +x "$T/bin/kubectl" "$T/bin/curl"
: > "$T/kubeconfig"

rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

# $1 = GITEA_IMAGE ('' = unset), $2 = HARBOR_URL ('' = unset)
run40() {
  local args=(-u HARBOR_URL -u GITEA_IMAGE)
  [ -n "$1" ] && args+=(GITEA_IMAGE="$1")
  [ -n "$2" ] && args+=(HARBOR_URL="$2")
  rm -f "$T/curl.calls"
  env "${args[@]}" PATH="$T/bin:$PATH" SKIP_DOTENV=1 KUBECONFIG="$T/kubeconfig" GITEA_HOST=gitea.test \
    bash "$SCRIPT_DIR/40-install-gitea.sh" 2>&1
}

echo "== explicit GITEA_IMAGE, no HARBOR_URL: no die, no Harbor probe =="
out="$(run40 gitea/gitea:1.27.2-rootless '')"
if printf '%s' "$out" | grep -q 'STUB-KUBECTL'; then ok "reached the first cluster call"; else bad "did not reach kubectl: $out"; fi
if printf '%s' "$out" | grep -q 'HARBOR_URL: parameter'; then bad "died on HARBOR_URL although the image is not from Harbor"; else ok "no HARBOR_URL requirement"; fi
if [ -s "$T/curl.calls" ]; then bad "probed Harbor although the image is not from Harbor"; else ok "no Harbor probe"; fi

echo "== explicit GITEA_IMAGE WITH a HARBOR_URL: still no Harbor probe =="
out="$(run40 gitea/gitea:1.27.2-rootless harbor.test)"
if [ -s "$T/curl.calls" ]; then bad "probed Harbor for an image that does not come from it"; else ok "no Harbor probe"; fi

echo "== POSITIVE CONTROL: default image WITH a HARBOR_URL does probe Harbor =="
out="$(run40 '' harbor.test)"
if [ -s "$T/curl.calls" ]; then ok "the probe fires when the image comes from Harbor"; else bad "the probe never fired, so the two no-probe checks above measure nothing: $out"; fi

echo "== default image (from Harbor), no HARBOR_URL: still a hard requirement =="
out="$(run40 '' '')"
if printf '%s' "$out" | grep -q 'HARBOR_URL: parameter'; then ok "dies on the missing HARBOR_URL"; else bad "must still require HARBOR_URL: $out"; fi
if printf '%s' "$out" | grep -q 'STUB-KUBECTL'; then bad "touched the cluster before failing"; else ok "failed before any cluster call"; fi

echo "test-gitea-image-harbor: $((checks)) checks, rc=$rc"
exit "$rc"
