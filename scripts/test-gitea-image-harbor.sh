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
# ISOLATION: run 40 from a COPY of the repo with no overlays. SKIP_DOTENV skips only .env; load_env
# still sources .env.state and the legacy .env.kind from REPO_ROOT, and either can supply a HARBOR_URL
# (measured in review), which would make the "still a hard requirement" case unexpressible.
mkdir -p "$T/repo"
cp -r "$SCRIPT_DIR" "$T/repo/scripts"
cp "$SCRIPT_DIR/../.env.example" "$T/repo/"
cp -r "$SCRIPT_DIR/../k8s" "$T/repo/"
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
  local args=(-u HARBOR_URL -u GITEA_IMAGE -u REPO_ROOT -u VKS_STATE_FILE)
  [ -n "$1" ] && args+=(GITEA_IMAGE="$1")
  [ -n "$2" ] && args+=(HARBOR_URL="$2")
  rm -f "$T/curl.calls"
  env "${args[@]}" PATH="$T/bin:$PATH" SKIP_DOTENV=1 KUBECONFIG="$T/kubeconfig" GITEA_HOST=gitea.test \
    bash "$T/repo/scripts/40-install-gitea.sh" 2>&1
}

echo "== explicit GITEA_IMAGE, no HARBOR_URL: no die, no Harbor probe =="
out="$(run40 gitea/gitea:1.27.2-rootless '')"
if printf '%s' "$out" | grep -q 'STUB-KUBECTL'; then ok "reached the first cluster call"; else bad "did not reach kubectl: $out"; fi
if printf '%s' "$out" | grep -q 'HARBOR_URL: parameter'; then bad "died on HARBOR_URL although the image is not from Harbor"; else ok "no HARBOR_URL requirement"; fi
if [ -s "$T/curl.calls" ]; then bad "probed Harbor although the image is not from Harbor"; else ok "no Harbor probe"; fi

echo "== explicit GITEA_IMAGE WITH a HARBOR_URL: still no Harbor probe =="
out="$(run40 gitea/gitea:1.27.2-rootless harbor.test)"
if [ -s "$T/curl.calls" ]; then bad "probed Harbor for an image that does not come from it"; else ok "no Harbor probe"; fi

echo "== explicit GITEA_IMAGE that IS a Harbor ref: the Harbor checks stay (the form .env.example documents) =="
out="$(run40 harbor.test/infra/gitea/gitea:1.27.2-rootless harbor.test)"
if [ -s "$T/curl.calls" ]; then ok "a Harbor-ref image is still probed"; else bad "a Harbor-ref GITEA_IMAGE skipped the Harbor mirror check: $out"; fi

echo "== another SPELLING of the same registry is still ours (a prefix match skipped these) =="
out="$(run40 harbor.test:443/infra/gitea/gitea:1.27.2-rootless harbor.test)"
if [ -s "$T/curl.calls" ]; then ok "host:443 in the image -> probed"; else bad "host:443 skipped the mirror check: $out"; fi
out="$(run40 harbor.test/infra/gitea/gitea:1.27.2-rootless harbor.test/)"
if [ -s "$T/curl.calls" ]; then ok "a trailing slash on HARBOR_URL -> probed"; else bad "trailing slash skipped the mirror check: $out"; fi
if grep -q '//api' "$T/curl.calls" 2>/dev/null; then bad "the probe URL carries '//api' (some proxies 404 it -> a false 'absent')"; else ok "the probe URL is normalised (no '//api')"; fi

echo "== a LOOKALIKE host is NOT ours, and the skip is SAID, not silent =="
out="$(run40 harbor.test.evil/infra/gitea/gitea:1.27.2-rootless harbor.test)"
if [ -s "$T/curl.calls" ]; then bad "probed Harbor for a lookalike registry"; else ok "harbor.test.evil is not harbor.test"; fi
if printf '%s' "$out" | grep -q 'mirror check is SKIPPED (not a pass)'; then ok "the skip is announced"; else bad "the skip was silent: $out"; fi

echo "== POSITIVE CONTROL: default image WITH a HARBOR_URL does probe Harbor =="
out="$(run40 '' harbor.test)"
if [ -s "$T/curl.calls" ]; then ok "the probe fires when the image comes from Harbor"; else bad "the probe never fired, so the two no-probe checks above measure nothing: $out"; fi

echo "== default image (from Harbor), no HARBOR_URL: still a hard requirement =="
out="$(run40 '' '')"
if printf '%s' "$out" | grep -q 'HARBOR_URL: parameter'; then ok "dies on the missing HARBOR_URL"; else bad "must still require HARBOR_URL: $out"; fi
if printf '%s' "$out" | grep -q 'STUB-KUBECTL'; then bad "touched the cluster before failing"; else ok "failed before any cluster call"; fi

echo "== the probe checks the project the IMAGE names, not HARBOR_INFRA_PROJECT (measured: it asked for cicd) =="
probed() { grep -o '/api/v2.0/projects/[A-Za-z0-9._-]*' "$T/curl.calls" 2>/dev/null | sort -u | tr '\n' ' '; }
run40 harbor.test/myproj/gitea/gitea:1.27.2-rootless harbor.test >/dev/null
case "$(probed)" in *"/projects/myproj "*) ok "an explicit Harbor image -> its own project (myproj) is probed" ;; *) bad "probed '$(probed)' for an image in myproj" ;; esac
case "$(probed)" in *"/projects/cicd "*) bad "HARBOR_INFRA_PROJECT (cicd) was probed for an image that names myproj" ;; *) ok "HARBOR_INFRA_PROJECT is not probed for it" ;; esac
run40 harbor.test:443/myproj/gitea/gitea:1.27.2-rootless harbor.test >/dev/null
case "$(probed)" in *"/projects/myproj "*) ok "host:443 spelling -> myproj probed" ;; *) bad "host:443 spelling probed '$(probed)'" ;; esac
run40 '' harbor.test >/dev/null
case "$(probed)" in *"/projects/cicd "*) ok "the DEFAULT image still probes HARBOR_INFRA_PROJECT (cicd)" ;; *) bad "default image probed '$(probed)'" ;; esac
run40 '' harbor.test/ >/dev/null
case "$(probed)" in *"/projects/cicd "*) ok "the DEFAULT image with a trailing-slash HARBOR_URL still probes cicd" ;; *) bad "default image + 'harbor.test/' probed '$(probed)' (the re-parse lost the project)" ;; esac
out="$(run40 harbor.test/gitea:1.27.2-rootless harbor.test)"
if [ ! -s "$T/curl.calls" ] && printf '%s' "$out" | grep -q 'no Harbor project name given'; then ok "an image with no project segment -> SKIPPED, not probed"
else bad "no-project image: calls='$(probed)'"; fi

echo "== the FALSE-DIE direction: an empty infra project must not kill an image that lives elsewhere =="
# A routing curl that answers the probe's own `body\ncode` contract: cicd is 404, myproj holds repos.
cp "$T/bin/curl" "$T/curl.plain"
cat > "$T/bin/curl" <<STUB
#!/bin/sh
echo "STUB-CURL \$*" >> "$T/curl.calls"
case "\$*" in
  */projects/cicd*)   printf '{"errors":[]}\n404' ;;
  */projects/myproj*) printf '{"name":"myproj","repo_count":3}\n200' ;;
  *) exit 7 ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
out="$(run40 harbor.test/myproj/gitea/gitea:1.27.2-rootless harbor.test)"
if printf '%s' "$out" | grep -q 'STUB-KUBECTL' && ! printf '%s' "$out" | grep -q 'Nothing has been mirrored'; then ok "infra project absent, image project full -> no false die, reached the cluster"
else bad "false die: $(printf '%s' "$out" | grep -m2 -E 'harbor:|mirrored')"; fi
out="$(run40 '' harbor.test)"
if printf '%s' "$out" | grep -q 'Nothing has been mirrored'; then ok "the default image against an ABSENT infra project still dies (B527 kept)"
else bad "default image vs absent cicd did not die: $out"; fi
cp "$T/curl.plain" "$T/bin/curl"

echo "test-gitea-image-harbor: $((checks)) checks, rc=$rc"
exit "$rc"
