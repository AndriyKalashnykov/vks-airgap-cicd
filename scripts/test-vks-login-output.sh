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
[ -n "${STUB_PWLOG:-}" ] && printf 'vcf %s %s pw=%s\n' "$1" "$2" "${VCF_CLI_VSPHERE_PASSWORD+set:${VCF_CLI_VSPHERE_PASSWORD}}" >> "$STUB_PWLOG"
case "$1 $2" in
  "context delete") exit 0 ;;
  "context create")
    [ -n "${STUB_NEWTOK:-}" ] && printf '%s' "$STUB_NEWTOK" > "$STUB_TOKFILE"
    [ -n "${STUB_NEWUSER:-}" ] && printf '%s' "$STUB_NEWUSER" > "$STUB_USERFILE"
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
[ -n "${STUB_PWLOG:-}" ] && [ -n "${VCF_CLI_VSPHERE_PASSWORD+x}" ] && printf 'kubectl SAW the password: %s\n' "$*" >> "$STUB_PWLOG"
case "$*" in
  *"config current-context"*) printf '%s\n' "${STUB_CUR:-}"; exit 0 ;;
  *"context.user"*) cat "${STUB_USERFILE:-/nonexistent}" 2>/dev/null; exit 0 ;;
  *"config view"*) cat "${STUB_TOKFILE:-/nonexistent}" 2>/dev/null; exit 0 ;;
  *"get ns"*) exit 0 ;;
  *"cluster-info"*) exit "${STUB_CLUSTERINFO_RC:-0}" ;;
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
# ⚠️ A WRONG CONTEXT IS NOW FATAL (2026-09-30). `get ns` is cluster-scoped and ignores -n, so it
# could not see that `use` left a DIFFERENT context current; this run used to exit 0 here.
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="other:ctx")"; rc=$?
if grep -qF 'stop the login' <<< "$out"; then bad "script: note printed although the context is wrong"
else ok "script: wrong current-context -> no note"; fi
if [ "$rc" != 0 ] && grep -qF "did not select that context" <<< "$out" && grep -qF "'other:ctx'" <<< "$out" \
   && ! grep -qF 'Supervisor context verified' <<< "$out"; then ok "script: 'use' left another context current -> FATAL, names it (rc=$rc)"
else bad "script: a wrong current-context after 'use' must die and name it (rc=$rc)"; fi

# ── 4. the token line (2026-09-30): vcf's "Skipped the token refresh" was read as "nothing was
# renewed" while the expiry had moved. The script now MEASURES before/after and says which.
_jwt() { printf 'h.%s.s' "$(printf '{"exp":%s}' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '=')"; }
TF="$T/tok"; _now=$(date +%s)
printf 'apiVersion: v1\n' > "$T/sup.kc"   # kube_token_expiry needs a non-empty file; the stub serves the token
printf '%s' "$(_jwt $((_now - 3600)))" > "$TF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF" STUB_NEWTOK="$(_jwt $((_now + 36000)))")"
if grep -qF 'this login RENEWED it (before: EXPIRED' <<< "$out"; then ok "token: expired -> new token is reported as RENEWED, with the before value"
else bad "token: an expired->valid login must say RENEWED [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
printf '%s' "$(_jwt $((_now + 7200)))" > "$TF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF")"
if grep -qF 'UNCHANGED by this login' <<< "$out" && ! grep -qF 'RENEWED' <<< "$out"; then ok "token: a still-valid token that did not move is reported UNCHANGED, never RENEWED"
else bad "token: an unchanged token must say UNCHANGED [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
rm -f "$TF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF" STUB_NEWTOK="$(_jwt $((_now + 36000)))")"
if grep -qF 'obtained by this login' <<< "$out" && ! grep -qE 'RENEWED|UNCHANGED' <<< "$out"; then ok "token: no token before, one after -> 'obtained', never 'renewed'"
else bad "token: a first login must not claim a renewal [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
# Same expiry MINUTE, different token: renewal is decided by the token, not the displayed expiry.
printf '%s' "$(_jwt $((_now + 7200)))" > "$TF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF" STUB_NEWTOK="$(_jwt $((_now + 7201)))x")"
if grep -qF 'RENEWED' <<< "$out"; then ok "token: a re-minted token with the same displayed expiry is still RENEWED"
else bad "token: same-minute re-mint must read RENEWED [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
if grep -qF "Skipped the token refresh' above" <<< "$out"; then bad "token: the vcf 'Skipped' note printed although vcf never said it"
else ok "token: the vcf 'Skipped' note prints only when vcf said it"; fi
printf '%s' "$(_jwt $((_now + 7200)))" > "$TF"
out="$(run insecure STUB_USE_ERR="[ok] Token is still active. Skipped the token refresh for context \"$WANT\"" STUB_CUR="$WANT" STUB_TOKFILE="$TF")"
if grep -qF "Skipped the token refresh' above refers to this token" <<< "$out"; then ok "token: when vcf DID say 'Skipped the token refresh', the note explains it"
else bad "token: the note must print when vcf said 'Skipped the token refresh'"; fi
rm -f "$TF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF")"
if grep -qF 'its expiry could not be read' <<< "$out" && ! grep -qE 'RENEWED|UNCHANGED|valid until' <<< "$out"; then ok "token: no readable token -> says so, claims nothing"
else bad "token: an unreadable token must claim nothing [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi

# ── 5. the password reaches ONLY vcf (2026-09-30) ────────────────────────────────────────────────
# load_env exports every .env key, so it used to sit in every kubectl's /proc/<pid>/environ.
PW="$T/pwlog"
: > "$PW"; out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_PWLOG="$PW")"
if grep -qF 'kubectl SAW the password' "$PW"; then bad "password: kubectl saw VCF_CLI_VSPHERE_PASSWORD [$(grep -m1 kubectl "$PW")]"
else ok "password: no kubectl call sees it"; fi
if grep -qx 'vcf context create pw=set:x' "$PW" && grep -qx 'vcf context use pw=set:x' "$PW"; then ok "password: vcf create AND use receive it"
else bad "password: vcf create/use must receive it [$(tr '\n' ' ' < "$PW")]"; fi
if grep -qx 'vcf context delete pw=' "$PW"; then ok "password: the context delete does not receive it"
else bad "password: the delete should run without it [$(tr '\n' ' ' < "$PW")]"; fi
# EMPTY must stay UNSET for vcf: an empty password is a failed SSO bind, which counts toward lockout.
: > "$PW"; out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_PWLOG="$PW" VCF_CLI_VSPHERE_PASSWORD=)"
if grep -qx 'vcf context create pw=' "$PW"; then ok "password: an empty value is NOT passed to vcf (unset, not empty)"
else bad "password: an empty value reached vcf [$(tr '\n' ' ' < "$PW")]"; fi
if grep -qF 'VCF_CLI_VSPHERE_PASSWORD is not set' <<< "$out"; then ok "password: empty -> the not-set warning still prints"
else bad "password: the not-set warning is gone"; fi

# ── 6. RENEWED only compares like with like (2026-09-30) ─────────────────────────────────────────
# The lab's supervisor.kubeconfig holds TWO user entries; a before/after across them is two creds.
UF="$T/user"
printf '%s' "$(_jwt $((_now + 7200)))" > "$TF"; printf 'argocd-supervisor:admin@x' > "$UF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF" STUB_USERFILE="$UF" \
        STUB_NEWTOK="$(_jwt $((_now + 36000)))" STUB_NEWUSER='vks-test:admin@x')"
if grep -qF 'Not compared with the token before it' <<< "$out" && ! grep -qE 'RENEWED|UNCHANGED' <<< "$out"; then ok "token: a different user entry before -> not compared, never 'RENEWED'"
else bad "token: across user entries must not claim RENEWED [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
printf '%s' "$(_jwt $((_now + 7200)))" > "$TF"; printf 'vks-test:admin@x' > "$UF"
out="$(run insecure STUB_USE_ERR="$BENIGN" STUB_CUR="$WANT" STUB_TOKFILE="$TF" STUB_USERFILE="$UF" \
        STUB_NEWTOK="$(_jwt $((_now + 36000)))" STUB_NEWUSER='vks-test:admin@x')"
if grep -qF 'this login RENEWED it' <<< "$out"; then ok "token: same user entry, new token -> RENEWED"
else bad "token: same user entry + new token must say RENEWED [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
rm -f "$UF"

# ── 7. supervisor_token_notice, pure (lib/os.sh) ─────────────────────────────────────────────────
note() { ( PATH="$T/bin:$PATH" STUB_TOKFILE="$TF" SUPERVISOR_TOKEN_WARN_HOURS="${WH:-2}" supervisor_token_notice "$@" ); }
K="$T/sup.kc"
printf '%s' "$(_jwt $((_now + 36000)))" > "$TF"
o="$(note "$K" creds)"; r=$?
if [ -z "$o" ] && [ "$r" = 0 ]; then ok "notice: creds, 10h left -> silent"; else bad "notice: creds far from expiry must be silent [$o] rc=$r"; fi
o="$(note "$K" login)"; r=$?
if [ "$r" = 0 ] && grep -qF 'NOT renewed by this run' <<< "$o" && ! grep -qF 'creds-renew' <<< "$o"; then ok "notice: login, 10h left -> says NOT renewed, no command"
else bad "notice: login far from expiry [$o] rc=$r"; fi
printf '%s' "$(_jwt $((_now + 3600)))" > "$TF"
o="$(note "$K" creds)"; r=$?
if [ "$r" = 10 ] && grep -qF 'make creds-renew' <<< "$o"; then ok "notice: creds, 1h left -> warns + names make creds-renew (rc 10)"
else bad "notice: creds near expiry must warn [$o] rc=$r"; fi
o="$(note "$K" login)"; r=$?
if [ "$r" = 10 ] && grep -qF 'did NOT renew it' <<< "$o" && grep -qF 'make creds-renew' <<< "$o"; then ok "notice: login, 1h left -> warns + command (rc 10)"
else bad "notice: login near expiry [$o] rc=$r"; fi
o="$(WH=abc note "$K" creds)"; r=$?
if [ "$r" = 10 ]; then ok "notice: a non-integer threshold falls back to 2h"; else bad "notice: WARN_HOURS=abc must fall back to 2 [$o] rc=$r"; fi
o="$(WH=0 note "$K" creds)"; r=$?
if [ -z "$o" ]; then ok "notice: threshold 0 -> never warns early"; else bad "notice: WARN_HOURS=0 must stay silent [$o]"; fi
printf '%s' "$(_jwt $((_now - 60)))" > "$TF"
o="$(note "$K" creds)"; r=$?
if [ -z "$o" ]; then ok "notice: creds, EXPIRED -> silent (the report has its own expired banner)"; else bad "notice: creds must not double the expired banner [$o]"; fi
o="$(note "$K" login)"; r=$?
if [ "$r" = 10 ] && grep -qF 'EXPIRED at' <<< "$o"; then ok "notice: login, EXPIRED -> warns"; else bad "notice: login expired [$o] rc=$r"; fi
o="$(note "$T/absent.kc" login)"; r=$?
if [ -z "$o" ] && [ "$r" = 0 ]; then ok "notice: no Supervisor kubeconfig (a tenant) -> silent"; else bad "notice: absent file must be silent [$o]"; fi
rm -f "$TF"
o="$(note "$K" login)"
if [ -z "$o" ]; then ok "notice: no readable token -> silent"; else bad "notice: unreadable token must be silent [$o]"; fi
if note "$K" bogus >/dev/null 2>&1; then bad "notice: an unknown mode must be refused"
else ok "notice: an unknown mode is refused"; fi

# ── 8. the kubeconfig arm now says what it did NOT do ────────────────────────────────────────────
printf 'apiVersion: v1\n' > "$T/guest.kc"
printf '%s' "$(_jwt $((_now + 3600)))" > "$TF"
out="$(run insecure VKS_AUTH_METHOD=kubeconfig STUB_CUR=guest-ctx STUB_TOKFILE="$TF")"; rc=$?
if [ "$rc" = 0 ] && grep -qF 'did NOT renew it' <<< "$out" && grep -qF "$T/sup.kc" <<< "$out" && grep -qF 'make creds-renew' <<< "$out"; then
  ok "kubeconfig arm: 1h left -> names the file, says NOT renewed, gives the command"
else bad "kubeconfig arm: must warn about the Supervisor token (rc=$rc) [$(grep -F 'Supervisor token' <<< "$out" || echo none)]"; fi
if grep -qE 'vcf context (create|use)' <<< "$out"; then bad "kubeconfig arm: must not run vcf"; else ok "kubeconfig arm: runs no vcf login"; fi
out="$(run insecure VKS_AUTH_METHOD=kubeconfig STUB_CUR=guest-ctx STUB_TOKFILE="$TF" VKS_SUPERVISOR_KUBECONFIG="$T/absent.kc")"; rc=$?
if [ "$rc" = 0 ] && ! grep -qF 'Supervisor token' <<< "$out"; then ok "kubeconfig arm: no Supervisor kubeconfig (a tenant) -> nothing extra"
else bad "kubeconfig arm: a tenant must see no Supervisor line (rc=$rc)"; fi
out="$(run insecure VKS_AUTH_METHOD=kubeconfig STUB_CUR=guest-ctx STUB_TOKFILE="$TF" VKS_SUPERVISOR_KUBECONFIG="$T/guest.kc")"
if ! grep -qF 'Supervisor token' <<< "$out"; then ok "kubeconfig arm: Supervisor path == KUBECONFIG -> no line (already exercised)"
else bad "kubeconfig arm: must stay silent when the Supervisor file IS \$KUBECONFIG"; fi
rm -f "$TF"

if [ "$fail" = 0 ]; then echo "test-vks-login-output: ALL PASS ($n)"; else echo "test-vks-login-output: FAILED" >&2; exit 1; fi
