#!/usr/bin/env bash
# test-vks-login-output.sh — what 30-vks-login.sh PRINTS around `vcf context create/use` must be true.
#
# WHY (2026-09-23): a successful `make creds-renew` printed three misleading things —
#   1. "INTERACTIVE: expect a PASSWORD prompt" on a run that could not prompt and did not;
#   2. a pre-emptive "fall back to ... --insecure-skip-tls-verify" hint, before anything failed,
#      offering a TLS downgrade to a run that had just verified the Supervisor CA;
#   3. the vcf CLI's "[x] ... system Harbor registry ... Contact your administrator", with nothing
#      saying it is expected, so an operator would escalate a non-fault.
# Each arm below pins one of those, AND the two traps an adversary round found in the fix:
#   - the benign-error note must NOT fire for Broadcom's OTHER variant under the same prefix
#     ("...was discovered but did not pass the health check" = a registry that EXISTS and is BROKEN);
#   - it must NOT fire when the kubeconfig is not on the wanted context;
#   - a GENERIC create failure must stop at the create (the capture disables set -e for that call).
#
# Offline: the real script runs with `vcf` and `kubectl` STUBBED on PATH, SKIP_DOTENV=1, and every
# path it writes pointed into a temp dir — the operator's .env, state and kubeconfigs are untouched.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

fail=0; n=0
ok()  { n=$((n+1)); printf 'ok    %s\n' "$1"; }
bad() { n=$((n+1)); printf 'FAIL  %s\n' "$1" >&2; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BENIGN='[x] : failed to discover plugin sources from the system Harbor registry: the system Harbor registry could not be discovered from the Supervisor cluster.'
BROKEN='[x] : failed to discover plugin sources from the system Harbor registry: the system Harbor registry (the OCI registry on the Supervisor cluster used to serve CLI plugins) was discovered but did not pass the health check.'
WANT='vks-test:ns1'

# ── 1. vcf_use_plugin_note_ok, pure ──────────────────────────────────────────────────────────────
f="$T/err"
printf "[i] Successfully activated context '%s' (Type: kubernetes)\n%s\n" "$WANT" "$BENIGN" > "$f"
if vcf_use_plugin_note_ok "$f" "$WANT" "$WANT"; then ok "note: benign error + right context -> note"
else bad "note: benign error + right context should print the note"; fi
printf '%s\n' "$BROKEN" > "$f"
if vcf_use_plugin_note_ok "$f" "$WANT" "$WANT"; then bad "note: the BROKEN-registry variant must NOT be called benign"
else ok "note: the 'did not pass the health check' variant gets no reassurance"; fi
printf '%s\n' "$BENIGN" > "$f"
if vcf_use_plugin_note_ok "$f" "other:ctx" "$WANT"; then bad "note: must not fire when the context is not the wanted one"
else ok "note: wrong current-context -> no note"; fi
if vcf_use_plugin_note_ok "$f" "" "$WANT"; then bad "note: must not fire when the current-context is unreadable"
else ok "note: unreadable current-context -> no note"; fi
printf '%s\n[x] : some other failure\n' "$BENIGN" > "$f"
if vcf_use_plugin_note_ok "$f" "$WANT" "$WANT"; then bad "note: must not fire when ANOTHER [x] error is present"
else ok "note: a second [x] error -> no note"; fi
: > "$f"
if vcf_use_plugin_note_ok "$f" "$WANT" "$WANT"; then bad "note: must not fire with no error at all"
else ok "note: no error -> no note"; fi

# ── 2. vcf_create_flag_rejected, pure ────────────────────────────────────────────────────────────
for l in '[x] : unknown flag: --username' '[x] : unknown shorthand flag: '"'"'t'"'"' in -t' \
         '[x] : invalid argument "kubernetes" for "-t, --type" flag: bad type'; do
  printf '%s\n' "$l" > "$f"
  if vcf_create_flag_rejected "$f"; then ok "flag-rejected: '${l:6:40}' detected"
  else bad "flag-rejected: '$l' missed"; fi
done
printf '[x] : Invalid vSphere Supervisor endpoint\n' > "$f"
if vcf_create_flag_rejected "$f"; then bad "flag-rejected: an endpoint error is NOT a flag rejection"
else ok "flag-rejected: an endpoint error is not a flag rejection"; fi

# ── 3. the real script, stubbed ──────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/vcf" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "context delete") exit 0 ;;
  "context create")
    case "${STUB_CREATE:-ok}" in
      ok)      echo "Logged in successfully." >&2; exit 0 ;;
      generic) echo "[x] : Invalid vSphere Supervisor endpoint" >&2; exit 7 ;;
      flag)    echo "[x] : unknown flag: --username" >&2; exit 3 ;;
      flagca)  echo "[x] : unknown flag: --ca-certificate" >&2; exit 3 ;;
    esac ;;
  "context use")
    echo "[i] Successfully activated context '$3' (Type: kubernetes)" >&2
    printf '%s\n' "${STUB_USE_ERR:-}" >&2
    exit "${STUB_USE_RC:-1}" ;;
esac
echo "STUB vcf: unexpected argv: $*" >&2; exit 64
STUB
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"config current-context"*) printf '%s\n' "${STUB_CUR:-}"; exit 0 ;;
  *"get ns"*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/vcf" "$T/bin/kubectl"

# ⚠️ RUN FROM A COPY. The script picks up ${REPO_ROOT}/secrets/supervisor-ca.crt when it exists
# (vks_ca_default, lib/tls.sh), so running it in the working tree made this test depend on the
# operator's box: the first draft's "no TLS flag" arm passed BY ACCIDENT because the real CA was
# found, and the CA arm dialled the endpoint for 15 s. A copy of scripts/ + .env.example has no
# secrets/ at all, and env -i drops any inherited REPO_ROOT.
mkdir -p "$T/repo"; cp -a scripts .env.example "$T/repo/"
[ ! -e "$T/repo/secrets" ] || { bad "harness: the copy must not contain secrets/"; }
run() {  # run <tls: insecure|none> + STUB_* in the environment
  local tls="$1"; shift
  ( cd "$T/repo" && env -i HOME="$T" PATH="$T/bin:$PATH" LANG="${LANG:-C.UTF-8}" SKIP_DOTENV=1 \
    VKS_AUTH_METHOD=vcf SUPERVISOR_HOST=192.0.2.10 VKS_CONTEXT_NAME=vks-test VKS_NAMESPACE=ns1 \
    VKS_USERNAME=administrator@vsphere.local VCF_CLI_VSPHERE_PASSWORD=x \
    KUBECONFIG="$T/guest.kc" VKS_SUPERVISOR_KUBECONFIG="$T/sup.kc" VKS_STATE_FILE="$T/state" \
    ${tls:+$( [ "$tls" = insecure ] && echo VKS_INSECURE_SKIP_TLS_VERIFY=1 )} \
    "$@" bash scripts/30-vks-login.sh 2>&1 )
}

out="$(run insecure STUB_CREATE=generic)"; rc=$?
if { [ "$rc" = 7 ] && ! grep -qE 'activating context|discovering it' <<< "$out"; }; then ok "script: a generic create failure stops AT the create with its rc (7)"
else bad "script: generic create failure should exit 7 before discovery/use (rc=$rc)"; fi
if grep -qF 'rejected an argument' <<< "$out"; then bad "script: generic failure must NOT print the flag-rejection hint"
else ok "script: generic failure prints no flag-rejection hint"; fi
# The replay after CREATE: vcf's own error must reach the operator. Keyed on text ONLY the stub prints.
if grep -qF '[x] : Invalid vSphere Supervisor endpoint' <<< "$out"; then ok "script: create's stderr is replayed on failure"
else bad "script: create's captured stderr was NOT replayed — the operator would see only an exit code"; fi

# The rejection hint names the flag vcf ACTUALLY rejected and offers an UPGRADE. It must print no
# by-hand `vcf context create`: a re-run deletes and recreates the context with the same flags, and a
# bare create writes into $KUBECONFIG. And it must never offer --insecure-skip-tls-verify.
for arm in 'flag|--username' 'flagca|--ca-certificate'; do
  out="$(run insecure STUB_CREATE="${arm%%|*}")"; rc=$?
  if { [ "$rc" = 3 ] && grep -qF "rejected an argument this script passes: unknown flag: ${arm#*|}" <<< "$out" \
       && grep -qF 'make install-vcf-cli' <<< "$out"; }; then ok "script: rejection of ${arm#*|} -> names it + points at the upgrade"
  else bad "script: rejection of ${arm#*|} -> hint must name it and point at make install-vcf-cli (rc=$rc)"; fi
  if grep -qE "vcf context create '|insecure-skip-tls-verify --auth-type" <<< "$out"; then bad "script: the hint prints a by-hand create / TLS downgrade (${arm#*|})"
  else ok "script: no by-hand create command, no TLS downgrade (${arm#*|})"; fi
done

out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT")"; rc=$?
if grep -qF 'INTERACTIVE' <<< "$out"; then bad "script: the false 'INTERACTIVE: expect a PASSWORD prompt' is back"
else ok "script: no 'INTERACTIVE: expect a PASSWORD prompt'"; fi
if grep -qF 'fall back to the LAB-VERIFIED' <<< "$out"; then bad "script: the pre-emptive fallback hint is back"
else ok "script: no pre-emptive fallback hint on a successful create"; fi
if { grep -qF 'Supervisor context verified via' <<< "$out" && grep -qF "context is '$WANT'" <<< "$out"; }; then ok "script: benign [x] + right context -> the note prints (rc=$rc)"
else bad "script: benign [x] + right context should print the note (rc=$rc)"; fi
# The replay after USE, keyed on text ONLY vcf prints — the note itself also contains "could not be
# discovered", so grepping for that would be satisfied by the note alone (an adversary deleted this
# replay and the old check stayed green).
if { grep -qF "[i] Successfully activated context '$WANT'" <<< "$out" && grep -qF 'from the Supervisor cluster.' <<< "$out"; }; then ok "script: use's stderr is replayed"
else bad "script: use's captured stderr was NOT replayed"; fi

out="$(run insecure STUB_USE_ERR="$BROKEN" STUB_CUR="$WANT")"
if grep -qF 'stop the login' <<< "$out"; then bad "script: the BROKEN-registry variant got the reassuring note"
else ok "script: the BROKEN-registry variant gets no note"; fi
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="other:ctx")"
if grep -qF 'stop the login' <<< "$out"; then bad "script: note printed although the context is wrong"
else ok "script: wrong current-context -> no note"; fi

if [ "$fail" = 0 ]; then echo "test-vks-login-output: ALL PASS ($n)"; else echo "test-vks-login-output: FAILED" >&2; exit 1; fi
