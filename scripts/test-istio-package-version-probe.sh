#!/usr/bin/env bash
# test-istio-package-version-probe.sh — 43-install-istio-package.sh must inspect the Package that
# will ACTUALLY BE INSTALLED, and must never skip its air-gap check silently.
#
# B484 F1, LAB-MEASURED 2026-08-26: istio ships EIGHT Package objects, one per version, and the
# count GROWS (six before the 3.7 upgrade). The probe used to filter on refName alone and take
# whatever the API returned LAST, while the installer picks the SEMVER-latest (or an explicit pin).
# Those can be different objects, so the check could clear one bundle while a different version
# installed from somewhere else -- the exact false-green its own 25-line comment exists to prevent.
#
# The fixtures below put the two in CONFLICT on purpose: the semver-latest (1.30.2) sits at a
# MIRRORED host while a later-in-API-order but semver-EARLIER version (1.28.9) sits at the public
# registry. A refName-only + tail-1 probe reads the public one and DIES; a version-resolving probe
# reads the mirrored one and passes. That is the discriminator, and it is why the ordering is
# deliberately hostile.
#
# ⚠️ These cases are the RED-proof for a check that is the SOLE provenance guard on the package
# path -- 96-verify-gateway-image.sh exits 0 in this mode BY DESIGN and says so. If this file goes
# green while 43's probe is broken, nothing else is looking.
set -uo pipefail
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0; ran=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

STUB="$(mktemp -d)"; KC="$(mktemp)"
trap 'rm -rf "$STUB" "$KC"' EXIT

# ⚠️ HOW FAR THE REAL SCRIPT RUNS HERE, MEASURED (B751) with a line trace: to line ~231 of 289 --
# PAST the probe under test, into istio_refuse_foreign_owner, which dies only because the kubectl
# stub below answers `get deploy istiod -o json` with nothing. The next lines are `kubectl apply`,
# `vks-package.sh install` (the vcf CLI) and three `state_set`s. It used to run with the real
# REPO_ROOT and no VKS_STATE_FILE, so those would have written this checkout's .env.state.
# Now: the helper above gives a sandbox REPO_ROOT (so the overlay is a sandbox file); curl is a stub that fails and
# COUNTS; VCENTER_HOST cannot exist; and the run-time guard refuses vcf.
CURL_CALLS="$STUB/curl.calls"; : > "$CURL_CALLS"
# shellcheck disable=SC2016  # $* and $CURL_CALLS belong to the stub, at ITS run time
printf '#!/bin/sh\necho "curl $*" >> "$CURL_CALLS"\nexit 7\n' > "$STUB/curl"; chmod +x "$STUB/curl"
export CURL_CALLS
printf 'apiVersion: v1\nkind: Config\ncurrent-context: c\nclusters: []\ncontexts: []\nusers: []\n' > "$KC"

# Two istio Packages. API order puts the PUBLIC one last on purpose; semver puts the MIRRORED one
# last. A tail-1-by-API-order probe and a semver probe therefore disagree, which is the whole point.
_pkgs_json() {
  cat <<'JSON'
{"items":[
 {"metadata":{"name":"istio.kubernetes.vmware.com.1.30.2"},
  "spec":{"refName":"istio.kubernetes.vmware.com","version":"1.30.2+vmware.1-vks.1",
          "template":{"spec":{"fetch":[{"imgpkgBundle":{"image":"harbor.example.test/vks/istio@sha256:aaa"}}]}}}},
 {"metadata":{"name":"istio.kubernetes.vmware.com.1.28.9"},
  "spec":{"refName":"istio.kubernetes.vmware.com","version":"1.28.9+vmware.1-vks.1",
          "template":{"spec":{"fetch":[{"imgpkgBundle":{"image":"projects.packages.broadcom.com/vsphere/istio@sha256:bbb"}}]}}}}
]}
JSON
}

mk_kubectl() { # $1 = mode
  cat > "$STUB/kubectl" <<EOF
#!/usr/bin/env bash
MODE=$1
case "\$*" in
  *"version"*|*"current-context"*) echo ctx; exit 0 ;;
  *"get package"*"-o json"*)
     case "\$MODE" in
       unreachable) echo 'Unable to connect to the server: dial tcp 127.0.0.1:1: connect: connection refused' >&2; exit 1 ;;
       empty)       echo '{"items":[]}'; exit 0 ;;
       *)           cat <<'PKGJSON'
$(_pkgs_json)
PKGJSON
                    exit 0 ;;
     esac ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
}

# DRY_RUN=0 so the probe runs; every later step is stubbed to exit 0, and we only read the probe's
# own output, so the script's later failure (if any) does not affect these assertions.
probe() { # $1=mode  [$2=ISTIO_PACKAGE_VERSION]
  mk_kubectl "$1"
  PATH="$STUB:$PATH" KUBECONFIG="$KC" SKIP_DOTENV=1 \
    HARBOR_URL=harbor.example.test VKS_PACKAGE_NAMESPACE=vmware-system-tkg \
    ISTIO_PACKAGE_VERSION="${2:-}" INGRESS_CONTROLLER=istio ISTIO_INSTALL_METHOD=package \
    VCENTER_HOST=vc.invalid \
    timeout 60 bash scripts/43-install-istio-package.sh 2>&1
}

echo "  case 1: the SEMVER-latest is inspected, not whatever the API returned last"
out="$(probe normal)"; ran=$((ran+1))
if printf '%s' "$out" | grep -q '1\.30\.2'; then
  ok "resolved 1.30.2 (semver-latest), not 1.28.9 (API-order last)"
else bad "did not resolve the semver-latest: $(printf '%s' "$out" | grep -iE 'inspect|resolve' | head -1)"; fi
if printf '%s' "$out" | grep -qF 'projects.packages.broadcom.com'; then
  bad "DIED on 1.28.9's public host — it inspected a Package that will not be installed"
else ok "did not judge the version that will not install"; fi

echo "  case 2: an explicit ISTIO_PACKAGE_VERSION wins over the semver-latest"
out="$(probe normal '1.28.9+vmware.1-vks.1')"; ran=$((ran+1))
if printf '%s' "$out" | grep -q '1\.28\.9'; then ok "honoured the explicit pin"
else bad "ignored ISTIO_PACKAGE_VERSION"; fi

echo "  case 3: UNREACHABLE API must WARN and proceed — never claim local, never claim remote"
out="$(probe unreachable)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'bundle host is UNKNOWN'; then
  ok "says the bundle host is unknown"
else bad "did not report the read as unknown"; fi
if printf '%s' "$out" | grep -qF 'air-gap safe'; then
  bad "claimed air-gap safe off a read that FAILED"
else ok "did not claim air-gap safe"; fi

echo "  case 4: REACHED but ZERO matches must DIE — this is the sole provenance guard"
out="$(probe empty)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'cannot identify'; then ok "refused an ambiguous answer"
else bad "proceeded on 0 matches (silent skip — the original fail-open)"; fi


# ── B484 F2/F5: the host COMPARISON ────────────────────────────────────────────────────────────
# The bundle host is compared EXACTLY, host-for-host, through registry_hostport. A prefix match was
# measured wrong in BOTH directions, and the false-GREEN direction is the dangerous one.
hostcase() { # $1=HARBOR_URL  $2=bundle image ref
  mk_kubectl normal
  cat > "$STUB/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get package"*"-o json"*)
    cat <<'J'
{"items":[{"metadata":{"name":"p"},"spec":{"refName":"istio.kubernetes.vmware.com","version":"1.30.2+vmware.1-vks.1",
 "template":{"spec":{"fetch":[{"imgpkgBundle":{"image":"$2"}}]}}}}]}
J
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
  PATH="$STUB:$PATH" KUBECONFIG="$KC" SKIP_DOTENV=1 HARBOR_URL="$1"     VKS_PACKAGE_NAMESPACE=vmware-system-tkg INGRESS_CONTROLLER=istio ISTIO_INSTALL_METHOD=package     timeout 60 bash scripts/43-install-istio-package.sh 2>&1
}
safe()   { printf '%s' "$1" | grep -qE 'air-gap safe'; }

echo "  case 5: a LOOKALIKE host must NOT read as our mirror (the false-GREEN direction)"
ran=$((ran+1))
if safe "$(hostcase harbor.lab harbor.lab.evil.example/vks/istio@sha256:aaa)"; then
  bad "harbor.lab.evil.example ACCEPTED as our mirror"
else ok "lookalike rejected"; fi

echo "  case 6: an IP PREFIX must not match either (10.0.0.5 vs 10.0.0.50)"
ran=$((ran+1))
if safe "$(hostcase 10.0.0.5 10.0.0.50/vks/istio@sha256:aaa)"; then
  bad "10.0.0.50 ACCEPTED against HARBOR_URL=10.0.0.5"
else ok "IP prefix rejected"; fi

echo "  case 7: a SCHEME in HARBOR_URL must not false-BLOCK the real mirror"
ran=$((ran+1))
if safe "$(hostcase https://harbor.lab harbor.lab:443/vks/istio@sha256:aaa)"; then
  ok "scheme tolerated; the real mirror is accepted"
else bad "https://harbor.lab false-blocked its own mirror"; fi

echo "  case 8: the Software Depot hosts are air-gap SAFE (artefact-verified, B484 F5)"
for h in depot.kube-system.svc depot-image-proxy.kube-system.svc.cluster.local; do
  ran=$((ran+1))
  if safe "$(hostcase harbor.lab "$h/vcf/vks-standard-packages/ga/3.7.1/x@sha256:aaa")"; then
    ok "$h accepted"
  else bad "$h REFUSED — that is the vendor's own air-gapped configuration"; fi
done

# The fence, asserted (not counted in `ran`: these are about the harness, not the probe).
if [ ! -s "$CURL_CALLS" ]; then ok "no curl call in any run of the real installer"
else bad "the installer reached curl $(wc -l < "$CURL_CALLS" | tr -d ' ') time(s): $(head -1 "$CURL_CALLS")"; fi
if [ ! -e "$REPO_ROOT/.env.state" ]; then ok "no state overlay was written (the installer never reached state_set)"
else bad "the installer WROTE a state overlay -- it now runs past istio_refuse_foreign_owner on these fixtures"; fi
case "${REPO_ROOT}" in "${TEST_SANDBOX}"/*) ok "the installer ran with a sandbox REPO_ROOT, not this checkout" ;;
  *) bad "REPO_ROOT is not the sandbox root (${REPO_ROOT})" ;; esac

[ "$ran" -eq 9 ] || { echo "  harness lost track of itself (ran=$ran)"; exit 1; }
[ "$fail" -eq 0 ] || { echo "istio-package-version-probe: FAILED"; exit 1; }
echo "istio-package-version-probe: OK — ${ran} cases"
