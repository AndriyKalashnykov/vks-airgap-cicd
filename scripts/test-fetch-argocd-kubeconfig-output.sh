#!/usr/bin/env bash
# test-fetch-argocd-kubeconfig-output.sh — what 31-fetch-argocd-kubeconfig.sh PRINTS around
# `vcf context create/use` must be true (B734), the sibling of test-vks-login-output.sh.
#
# Before B734, 31 printed "the VCF CLI will prompt for the password" on every run — false, the create
# read it from VCF_CLI_VSPHERE_PASSWORD — and answered the benign "[x] … system Harbor registry could not
# be discovered" from `vcf context use` with a WARN "could not select", which reads as a fault.
#
# Offline: the real script runs with `vcf` and `kubectl` STUBBED on PATH, from a copy of scripts/ +
# .env.example (no secrets/, so no real CA is picked up), SKIP_DOTENV=1, and every written path in $T.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1

fail=0; n=0
ok()  { n=$((n+1)); printf 'ok    %s\n' "$1"; }
bad() { n=$((n+1)); printf 'FAIL  %s\n' "$1" >&2; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BENIGN='[x] : failed to discover plugin sources from the system Harbor registry: the system Harbor registry could not be discovered from the Supervisor cluster.'
BROKEN='[x] : failed to discover plugin sources from the system Harbor registry: the system Harbor registry (the OCI registry on the Supervisor cluster used to serve CLI plugins) was discovered but did not pass the health check.'
WANT='argocd-supervisor:argocd-ns'

mkdir -p "$T/bin"
cat > "$T/bin/vcf" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "context delete") exit 0 ;;
  "context create")
    case "${STUB_CREATE:-ok}" in
      ok)      echo "[i] Reading the password from env variable" >&2; exit 0 ;;
      generic) echo "[x] : Invalid vSphere Supervisor endpoint" >&2; exit 7 ;;
      flag)    echo "[x] : unknown flag: --username" >&2; exit 3 ;;
    esac ;;
  "context use")
    echo "[i] Successfully activated context '$3' (Type: kubernetes)" >&2
    printf '%s\n' "${STUB_USE_ERR:-}" >&2
    exit "${STUB_USE_RC:-1}" ;;
  "version") echo "version: v9.1.0" ; exit 0 ;;
esac
echo "STUB vcf: unexpected argv: $*" >&2; exit 64
STUB
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"config current-context"*) printf '%s\n' "${STUB_CUR:-}"; exit 0 ;;
  *"get deploy argocd-server"*) exit "${STUB_ARGO_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$T/bin/vcf" "$T/bin/kubectl"

mkdir -p "$T/repo"; cp -a scripts .env.example "$T/repo/"
[ ! -e "$T/repo/secrets" ] || bad "harness: the copy must not contain secrets/"
run() {  # STUB_* and overrides as arguments
  ( cd "$T/repo" && env -i HOME="$T" PATH="$T/bin:$PATH" LANG="${LANG:-C.UTF-8}" SKIP_DOTENV=1 \
    SUPERVISOR_HOST=192.0.2.10 ARGOCD_NAMESPACE=argocd-ns VKS_USERNAME=administrator@vsphere.local \
    VKS_INSECURE_SKIP_TLS_VERIFY=1 ARGOCD_KUBECONFIG="$T/argocd.kc" VKS_STATE_FILE="$T/state" \
    VCF_CLI_VSPHERE_PASSWORD=x "$@" bash scripts/31-fetch-argocd-kubeconfig.sh 2>&1 )
}

out="$(run STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT")"; rc=$?
if grep -qiE 'will prompt|interactive:' <<< "$out"; then bad "the false 'will prompt for the password' claim is printed"
else ok "no 'will prompt' claim"; fi
# The test's own stdin is never a TTY, so a runtime probe could not tell; check the SCRIPT instead:
# the create command (continuation lines joined, comments stripped) must redirect stdin.
_joined="$(sed 's/#.*//' scripts/31-fetch-argocd-kubeconfig.sh | sed -e :a -e '/\\$/N; s/\\\n//; ta')"
if grep -qE 'vcf context create.*</dev/null' <<< "$_joined"; then ok "the create command redirects stdin (it can never prompt)"
else bad "31's vcf context create no longer has </dev/null — it can prompt, and the warning above lies"; fi
if [ "$rc" = 0 ] && grep -qF 'OK — argocd-server is visible' <<< "$out" \
   && grep -qF 'did not' <<< "$out" && grep -qF 'stop the ArgoCD kubeconfig fetch' <<< "$out"; then
  ok "benign [x] + right context -> success AND the note, naming this script's operation"
else bad "benign [x] + right context should succeed and print the note (rc=$rc)"; fi
if grep -qF 'stop the login' <<< "$out"; then bad "the note says 'login' — false for this script"
else ok "the note does not claim a login"; fi
if grep -qF 'could not select' <<< "$out"; then bad "the old 'could not select' WARN is back"
else ok "no 'could not select' WARN for a context that was activated"; fi
if grep -qF 'from the Supervisor cluster.' <<< "$out"; then ok "use's stderr is replayed"
else bad "use's captured stderr was NOT replayed"; fi

out="$(run STUB_USE_ERR="$BROKEN" STUB_CUR="$WANT")"
if grep -qF 'stop the ArgoCD kubeconfig fetch' <<< "$out"; then bad "the BROKEN-registry variant got the reassuring note"
else ok "BROKEN-registry variant -> no note"; fi
out="$(run STUB_USE_ERR="$BENIGN" STUB_CUR="other:ctx")"
if grep -qF 'stop the ArgoCD kubeconfig fetch' <<< "$out"; then bad "note printed although the context is wrong"
else ok "wrong current-context -> no note"; fi

out="$(run STUB_CREATE=generic)"; rc=$?
if [ "$rc" = 7 ] && ! grep -qF 'selecting the vSphere-Namespace context' <<< "$out" \
   && grep -qF 'Invalid vSphere Supervisor endpoint' <<< "$out"; then ok "a generic create failure stops at the create with its rc (7) and replays vcf's error"
else bad "generic create failure: want rc 7, replay, no 'selecting' (rc=$rc)"; fi
if grep -qF 'rejected an argument' <<< "$out"; then bad "generic failure must not print the flag-rejection hint"
else ok "generic failure prints no flag-rejection hint"; fi

out="$(run STUB_CREATE=flag)"; rc=$?
if [ "$rc" = 3 ] && grep -qF 'rejected an argument this script passes: unknown flag: --username' <<< "$out" \
   && grep -qF 'make install-vcf-cli' <<< "$out" && ! grep -qF 'insecure-skip-tls-verify --auth-type' <<< "$out"; then
  ok "flag rejection -> names it, points at the upgrade, no TLS downgrade"
else bad "flag rejection hint (rc=$rc)"; fi

out="$(run VCF_CLI_VSPHERE_PASSWORD= STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT")"
if grep -qF 'VCF_CLI_VSPHERE_PASSWORD is not set' <<< "$out" && grep -qF 'fails HERE' <<< "$out"; then ok "unset password -> the warning says it fails here"
else bad "unset password should warn that the create cannot prompt"; fi

if [ "$fail" = 0 ]; then echo "test-fetch-argocd-kubeconfig-output: ALL PASS ($n)"; else echo "test-fetch-argocd-kubeconfig-output: FAILED" >&2; exit 1; fi
