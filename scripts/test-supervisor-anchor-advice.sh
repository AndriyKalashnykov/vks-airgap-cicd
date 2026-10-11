#!/usr/bin/env bash
# ci-tier: fast
# test-supervisor-anchor-advice.sh — what the access report and the login SAY when the stored
# Supervisor anchor no longer belongs to the Supervisor that is running.
#
# WHY (measured 2026-10-08, a lab destroyed and rebuilt): `make creds` led with "the recorded
# ingress did not answer either — check the lab is UP" although the Supervisor, Harbor and ArgoCD
# all answered, and then named `make creds-renew`. That login stops (correctly, before the password
# is sent) because the stored CA does not verify the new Supervisor — and its message ended "Re-pin
# it from the lab that is actually running", which names no command.
#
# What is pinned here:
#   1. supervisor_repin_how (lib/os.sh): the commands, with the caller's real values, no placeholder.
#   2. creds.sh's expired-token banner, one case per verdict of the credential-free anchor check:
#        stale    -> "renewing cannot work yet" + the re-pin commands; NO "check the lab is UP"
#        dates    -> the anchor is right, the certificate's dates are not valid here: two commands
#                    to compare; NO re-pin, NO renew, NO "check the lab is UP"
#        verifies -> the renew command; NO "check the lab is UP"
#        silent   -> "check the lab is UP" first, then the renew command
#        skip     -> the wording the banner had before the check existed (no new claim)
#      and that the check is bounded, sends nothing, and never runs `vcf`.
#   3. 30-vks-login.sh's refusal carries the same commands, and still sends no password.
#   4. Both scripts ask ONE function (supervisor_anchor_verdict), not two copies of the check.
#
# WHAT THIS DOES NOT PROVE: that a real Supervisor's handshake produces these verdicts. `openssl`
# is a stand-in here; the verdict functions themselves (including the expired-leaf case behind
# "dates") are tested against real TLS listeners in test-ca-verifies-endpoint.sh. Nor does it prove `make fetch-supervisor-ca` works on a lab.
#
# Offline: `openssl`, `kubectl`, `vcf`, `curl`, `getent` are stand-ins on PATH, every path is in a
# temp dir, and the only address dialled is a closed port on 127.0.0.1.
set -uo pipefail
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1

# An exported value from the caller's shell must not reach the scripts under test: load_env keeps
# some caller-set values over the fixture's .env, and the fixture would then measure this machine.
unset SUPERVISOR_HOST VKS_CA_CERT_FILE VKS_CA_SHA256 VCENTER_HOST VKS_NAMESPACE VKS_CLUSTER_NAME \
      CREDS_PROBE_TIMEOUT_SECONDS CA_VERIFY_TIMEOUT INGRESS_LB_IP INGRESS_PROBE_PORT CREDS_NO_PROBE \
      SKIP_DOTENV SHOW_SECRETS VKS_AUTH_METHOD VCF_CLI_VSPHERE_PASSWORD HARBOR_URL ARGOCD_SERVER \
      VKS_SUPERVISOR_KUBECONFIG VKS_STATE_FILE KUBECONFIG REPO_ROOT 2>/dev/null || true

# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

fail=0; n=0
ok()  { n=$((n+1)); printf 'ok    %s\n' "$1"; }
bad() { n=$((n+1)); printf 'FAIL  %s\n' "$1" >&2; fail=1; }
has() { command grep -qF -- "$2" <<< "$1"; }      # has <text> <fixed string>
hasline() { command grep -qxF -- "$2" <<< "$1"; } # hasline <text> <whole line>
# hasflat <text> <sentence>: the sentence may be WRAPPED and INDENTED in the text, so compare with
# every run of whitespace (newlines included) collapsed to one space.
flat() { tr '\n' ' ' <<< "$1" | tr -s ' '; }
hasflat() { command grep -qF -- "$2" <<< "$(flat "$1")"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REAL_TIMEOUT="$(command -v timeout)"
[ -n "$REAL_TIMEOUT" ] || { echo "test-supervisor-anchor-advice: no 'timeout' on this machine" >&2; exit 1; }

HOST=192.0.2.10                 # TEST-NET-1: documentation range, routed nowhere
VC=vcsa.example.test
NS=demo-ns
GC=demo-gc
CANARY='CANARY-password-must-not-appear'

# s_client transcripts, one per verdict of ca_verifies_endpoint (lib/tls.sh).
SC_STALE='CONNECTED(00000003)
Verify return code: 21 (unable to verify the first certificate)'
SC_OK='CONNECTED(00000003)
depth=0 CN = supervisor
Verify return code: 0 (ok)'
SC_SILENT='connect: Connection refused
connect:errno=111'
SC_NAME='CONNECTED(00000003)
IP address mismatch
Verify return code: 64 (IP address mismatch)'
# An EXPIRED leaf under the right anchor: the first handshake fails on the date...
SC_EXPIRED='CONNECTED(00000003)
verify error:num=10:certificate has expired
Verify return code: 10 (certificate has expired)'
# ...and a listener that is not speaking TLS at all (ca_verifies_endpoint's verdict 4).
SC_NOCERT='CONNECTED(00000003)
no peer certificate available
Verify return code: 0 (ok)
wrong version number'

# ── 1. supervisor_repin_how, pure ────────────────────────────────────────────────────────────────
echo "== 1. the re-pin text =="
repin() {  # repin <env assignments...> ; runs the function in a clean subshell
  ( unset VCENTER_HOST VKS_CA_SHA256 VKS_NAMESPACE VKS_CLUSTER_NAME
    for _kv in "$@"; do export "${_kv?}"; done
    supervisor_repin_how "$HOST" ./secrets/supervisor-ca.crt )
}
r_all="$(repin "VCENTER_HOST=$VC" "VKS_NAMESPACE=$NS" "VKS_CLUSTER_NAME=$GC" "VCF_CLI_VSPHERE_PASSWORD=$CANARY")"
if [ -n "$r_all" ]; then ok "repin: the function printed something (the cases below are live)"
else bad "repin: supervisor_repin_how printed NOTHING — every absence check below would pass on an empty string"; fi
if hasline "$r_all" '  make fetch-supervisor-ca' \
   && hasline "$r_all" '  openssl x509 -in ./secrets/supervisor-ca.crt -noout -fingerprint -sha256' \
   && hasline "$r_all" '  VKS_AUTH_METHOD=vcf make vks-login'; then
  ok "repin: the three commands are each on a line of their own, with the real file in them"
else bad "repin: a command is missing or is not a whole pasteable line"; fi
if has "$r_all" "$HOST" && has "$r_all" "$VC" && has "$r_all" "'$NS'" && has "$r_all" "'$GC'"; then
  ok "repin: names the endpoint, the vCenter, the namespace and the cluster by their real values"
else bad "repin: a real value (endpoint / vCenter / namespace / cluster) is missing"; fi
if command grep -q '[<>]' <<< "$r_all"; then bad "repin: a <placeholder> is printed: $(command grep '[<>]' <<< "$r_all" | head -1)"
else ok "repin: no <placeholder> anywhere in the text"; fi
if has "$r_all" 'docs/scenario-1.md' && has "$r_all" '"2. The vSphere Namespace"'; then
  ok "repin: says where to start again on a rebuilt lab"
else bad "repin: the doc section for a rebuilt lab is missing"; fi
# The pointer must name a heading the document really has, and the login step it promises.
if command grep -qxF '## 2. The vSphere Namespace' docs/scenario-1.md \
   && command grep -qxF '## 3. Log in to the Supervisor' docs/scenario-1.md; then
  ok "repin: docs/scenario-1.md has the headings the text points at (2 and 3)"
else bad "repin: docs/scenario-1.md no longer has '## 2. The vSphere Namespace' / '## 3. Log in to the Supervisor' — the pointer is stale"; fi
# Every `make <target>` the text names must be a real target.
_tg_n=0; _tg_missing=""
while IFS= read -r _tg; do
  [ -n "$_tg" ] || continue
  _tg_n=$((_tg_n + 1))
  command grep -qE "^${_tg}:" Makefile || _tg_missing="${_tg_missing} ${_tg}"
done <<< "$(command grep -oE 'make [a-z][a-z0-9-]+' <<< "$r_all" | sed 's/^make //' | sort -u)"
if [ "$_tg_n" -ge 2 ] && [ -z "$_tg_missing" ]; then ok "repin: all ${_tg_n} make targets it names exist in the Makefile"
else bad "repin: named make target(s) not in the Makefile:${_tg_missing:- (and only ${_tg_n} were found)}"; fi
if has "$r_all" "$CANARY"; then bad "repin: a password reached the text"
else ok "repin: no password in the text"; fi
if command grep -qE '(^|[^A-Za-z0-9])(B[0-9]{2,}|#[0-9]{3,})([^A-Za-z0-9]|$)' <<< "$r_all"; then bad "repin: an internal tracker id is printed"
else ok "repin: no internal tracker id"; fi
if has "$r_all" 'VKS_CA_SHA256'; then bad "repin: talks about VKS_CA_SHA256 although none is set (advice on a non-finding)"
else ok "repin: silent about VKS_CA_SHA256 when no pin is set"; fi
r_pin="$(repin "VCENTER_HOST=$VC" "VKS_NAMESPACE=$NS" "VKS_CLUSTER_NAME=$GC" "VKS_CA_SHA256=PINVALUE0123456789")"
if has "$r_pin" 'VKS_CA_SHA256 is set' && hasflat "$r_pin" 'Set it to the SHA-256 you confirmed.' \
   && ! has "$r_pin" 'PINVALUE0123456789'; then
  ok "repin: with a pin set, says to set it to the confirmed SHA-256 — and does not print its value"
else bad "repin: with a pin set, the pin line is missing or prints the value"; fi
# The pin is the ONLY thing that separates "the lab was rebuilt" from "this connection is
# intercepted": without it the login only warns and then sends the password. The text must never
# offer removing it, and must say why the confirmation is not optional.
if hasflat "$r_pin" 'Do NOT remove it: without it the login only warns before it sends your password.'; then
  ok "repin: says not to remove the pin, and what the login does without it"
else bad "repin: does not say that without the pin the login only warns before sending the password"; fi
if hasflat "$r_pin" 'An intercepted connection looks exactly like this, so confirming the SHA-256 is not optional.'; then
  ok "repin: says an intercepted connection looks exactly like this"
else bad "repin: the intercepted-connection sentence is missing"; fi
# "matched the OLD file" is a claim: printed only when the pin really equals the file's SHA-256.
if has "$r_pin" 'matched the OLD file'; then bad "repin: claims the pin matched a file it could not read (the pin here is not even a digest)"
else ok "repin: no 'matched the OLD file' when that was not measured"; fi
if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/pin.key" -out "$T/pin.crt" -days 1 -subj "/CN=pin-fixture" >/dev/null 2>&1; then
  _pin_fp="$(openssl x509 -in "$T/pin.crt" -noout -fingerprint -sha256 | sed 's/^.*=//')"
  # Both libraries, as the login and the report have them (ca_pin_verdict lives in lib/tls.sh).
  r_match="$(VCENTER_HOST="$VC" VKS_CA_SHA256="$_pin_fp" bash -c \
              '. scripts/lib/os.sh; . scripts/lib/tls.sh; supervisor_repin_how "$1" "$2"' _ "$HOST" "$T/pin.crt")"
  if has "$r_match" 'VKS_CA_SHA256 is set, and it matched the OLD file.' && ! has "$r_match" "$_pin_fp"; then
    ok "repin: a pin equal to the stored file's SHA-256 -> 'it matched the OLD file' (value not printed)"
  else bad "repin: a pin that DOES match the stored file is not reported as matching, or its value is printed"; fi
else
  r_match=""
  bad "harness: could not mint a certificate for the pin case (openssl unusable)"
fi
# Over BOTH forms of the pin paragraph (matched and not): one of them alone left the other free.
if [ -z "$r_match" ] || command grep -qiE 'delete that line|or delete|remove the line|delete the line' <<< "${r_pin}
${r_match}"; then
  bad "repin: offers DELETING the pin — that removes the only check between a rebuilt lab and an intercepted connection"
else ok "repin: never offers deleting the pin (both forms of the paragraph)"; fi
# The two sentences that make the procedure more than blind trust in a download.
if hasflat "$r_all" 'Confirm it with whoever runs the lab, over a channel that is not this connection'; then
  ok "repin: says to confirm the SHA-256 with whoever runs the lab, over another channel"
else bad "repin: the out-of-band confirmation sentence is missing"; fi
if hasflat "$r_all" 'the download is unverified TLS, so that SHA-256 is what proves the file'; then
  ok "repin: says the download is unverified TLS and the SHA-256 is what proves the file"
else bad "repin: does not say the download is unverified TLS / that the SHA-256 proves the file"; fi
# The login command: a warning directly above it, and the truth about the missing-namespace stop.
if command grep -B1 -xF '  VKS_AUTH_METHOD=vcf make vks-login' <<< "$r_all" | command grep -qxF 'Do not run it until you have confirmed the SHA-256.'; then
  ok "repin: 'do not run it until the SHA-256 is confirmed' sits directly above the login command"
else bad "repin: the line directly above the login command is not the confirm-first warning"; fi
if hasflat "$r_all" 'Without the namespace that login still sends your password, and stops after it.' \
   && ! hasflat "$r_all" 'which stops while the namespace is missing'; then
  ok "repin: says the missing-namespace stop comes AFTER the password is sent"
else bad "repin: does not say the login sends the password before it stops on a missing namespace"; fi
r_novc="$(repin "VKS_NAMESPACE=$NS" "VKS_CLUSTER_NAME=$GC")"
if has "$r_novc" 'VCENTER_HOST' && has "$r_novc" 'NOT set'; then ok "repin: VCENTER_HOST unset -> says so before the reader runs the command that needs it"
else bad "repin: VCENTER_HOST unset is not mentioned — make fetch-supervisor-ca would stop on it"; fi
r_nonames="$(repin "VCENTER_HOST=$VC")"
if has "$r_nonames" "''"; then bad "repin: prints an empty quoted name when the namespace/cluster are unset"
else ok "repin: no empty quoted name when the namespace and cluster are unset"; fi

# ── 2. creds.sh's banner, per verdict ────────────────────────────────────────────────────────────
echo "== 2. the access report's expired-token banner =="
_b64u() { printf '%s' "$1" | { base64 -w0 2>/dev/null || base64 | tr -d '\n'; } | tr -d '=' | tr '+/' '-_'; }
EXPIRED_TOKEN="h.$(_b64u "{\"exp\":$(( $(date +%s) - 3600 ))}").s"
VALID_TOKEN="h.$(_b64u "{\"exp\":$(( $(date +%s) + 86400 ))}").s"
DEAD_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || true)"
[ -n "$DEAD_PORT" ] || { bad "harness: could not pick a closed port (python3 missing?)"; DEAD_PORT=1; }

# creds_render <s_client transcript> <s_client rc> <ingress: silent|none> [extra .env lines] [anchor: yes|no]
# Prints the report; leaves the stand-ins' call log at $T/creds.log.
# Three knobs, read from the caller's variables and reset by `knobs`:
#   SC2      the transcript for a handshake whose argv carries -no_check_time (default: the first one,
#            i.e. "ignoring dates changes nothing")
#   X509RC   the exit status of `openssl x509` (1 = the anchor file does not parse)
#   NOPROBE  CREDS_NO_PROBE for the run
#   VERIFYOUT what `openssl verify` prints (the anchor FILE's own date check reads it; empty = in date)
# Five more, for the nothing-answered block (section 2b):
#   OFF      1 = the powered-off signature holds: Harbor is silent too (curl completes nothing) and
#            the guest cluster API refuses the connection. 0 = Harbor serves, as in the measured report.
#   TCPRC    what the TCP connect to ${HOST}:443 returns (0 accepted, 1 refused). The address is in a
#            documentation range and 443 cannot be bound here, so the `timeout` stand-in answers for
#            that ONE connect and records it; every other bounded command still runs for real.
#   TOKEN    expired | valid: the Supervisor token in the stored kubeconfig
#   SUPKC    yes | no: whether a Supervisor kubeconfig is stored at all
#   NAMES    yes | no: whether VKS_NAMESPACE and VKS_CLUSTER_NAME are in .env
#   HANG     argocd | headlamp: that one read hangs past this report's limit (it then ends 124)
knobs() { SC2=""; X509RC=0; NOPROBE=0; VERIFYOUT=""; OFF=0; TCPRC=0; TOKEN=expired; SUPKC=yes; NAMES=yes; HANG=no; }
CA_EXPIRED_OUT='error 10 at 0 depth lookup: certificate has expired'
CA_DATES_HEAD='The CA file itself is outside its validity period on this machine:'
knobs
creds_render() {
  local sc="$1" scrc="$2" ing="$3" extra="${4:-}" anchor="${5:-yes}" t="$T/creds" tok supkc
  tok="$EXPIRED_TOKEN"; [ "$TOKEN" = valid ] && tok="$VALID_TOKEN"
  supkc="$t/sup"; [ "$SUPKC" = no ] && supkc=""
  rm -rf "$t"; mkdir -p "$t/bin" "$t/secrets"; : > "$T/creds.log"
  cp .env.example "$t/.env.example"
  [ "$anchor" = yes ] && printf 'stand-in anchor\n' > "$t/secrets/supervisor-ca.crt"
  printf '%s\n' "$sc" > "$t/sclient.txt"
  printf '%s\n' "${SC2:-$sc}" > "$t/sclient-nct.txt"
  {
    printf "HARBOR_URL=harbor.lab.example\nHARBOR_USERNAME='robot\$probe'\nHARBOR_PASSWORD=x\n"
    printf 'VCENTER_HOST=%s\n' "$VC"
    [ "$NAMES" = yes ] && printf 'VKS_NAMESPACE=%s\nVKS_CLUSTER_NAME=%s\n' "$NS" "$GC"
    printf "VCF_CLI_VSPHERE_PASSWORD='%s'\n" "$CANARY"
    [ "$ing" = silent ] && printf 'INGRESS_LB_IP=127.0.0.1\nINGRESS_PROBE_PORT=%s\n' "$DEAD_PORT"
    [ -n "$extra" ] && printf '%s\n' "$extra"
  } > "$t/.env"
  : > "$t/kc"; printf 'apiVersion: v1\nkind: Config\n' > "$t/sup"
  # kubectl: an EXPIRED Supervisor token, and an Unauthorized answer to every read.
  { printf '#!/bin/sh\ncase "$*" in\n'
    [ "$HANG" = argocd ] && printf '  *argocd-initial-admin-secret*) sleep 6; exit 0 ;;\n'
    [ "$HANG" = headlamp ] && printf '  *"create token"*) sleep 6; exit 0 ;;\n'
    printf '  *user.token*) printf %%s %s; exit 0 ;;\n' "'$tok'"
    printf '  *current-context*) echo stub-ctx; exit 0 ;;\n'
    if [ "$OFF" = 1 ]; then
      # The guest cluster is gone, so its API refuses the headlamp token request too.
      printf '  *version*|*"create token"*) echo "The connection to the server 192.0.2.1:6443 was refused - did you specify the right host or port?" >&2; exit 1 ;;\n'
    else
      printf '  *version*) exit 0 ;;\n'
    fi
    printf '  *"get ns"*|*"get secret"*) echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;\n'
    printf 'esac\nexit 0\n'; } > "$t/bin/kubectl"
  # Harbor resolves and serves, as it did in the measured report (so the report is NOT "nothing answered").
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "10.0.0.1 %%s\\n" "$2"\n' > "$t/bin/getent"
  if [ "$OFF" = 1 ]; then printf '#!/bin/sh\nprintf 000\nexit 7\n' > "$t/bin/curl"
  else printf '#!/bin/sh\nprintf 200\n' > "$t/bin/curl"; fi
  # openssl: logs its argv and how many bytes it was fed, then replays a transcript: one for an
  # ordinary handshake, ANOTHER when -no_check_time is on the command line.
  cat > "$t/bin/openssl" <<STUB
#!/bin/sh
printf 'openssl %s\n' "\$*" >> "$T/creds.log"
case "\$1" in
  x509) exit ${X509RC} ;;
  verify) printf '%s\n' '${VERIFYOUT}'; exit 0 ;;
  s_client)
    in="\$(cat)"; printf 's_client-stdin-bytes=%s\n' "\${#in}" >> "$T/creds.log"
    case " \$* " in
      *" -no_check_time "*) cat "$t/sclient-nct.txt" ;;
      *)                    cat "$t/sclient.txt" ;;
    esac
    exit ${scrc} ;;
esac
exit 0
STUB
  # timeout: records the budget given to the handshake, then runs the real one.
  # shellcheck disable=SC2016
  # The budget is the first argument that is not `--foreground` (lib/tls.sh passes that flag
  # first when this machine's timeout has it).
  { printf '#!/bin/sh\nb="$1"; [ "$b" = "--foreground" ] && b="$2"\ncase "$*" in *"openssl s_client"*) printf "timeout-budget=%%s\\n" "$b" >> "%s" ;; esac\n' "$T/creds.log"
    # The ONE connect this stand-in answers itself: tls_port_accepts to the Supervisor on 443.
    # shellcheck disable=SC2016
    printf 'case "$*" in *"/dev/tcp/"*" _ %s 443") printf "tcp-connect=%%s budget=%%s\\n" "%s:443" "$b" >> "%s"; exit %s ;; esac\n' \
      "$HOST" "$HOST" "$T/creds.log" "$TCPRC"
    printf 'exec "%s" "$@"\n' "$REAL_TIMEOUT"; } > "$t/bin/timeout"
  # vcf: must never run from a read-only report. It only records that it did.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nprintf "vcf %%s\\n" "$*" >> "%s"\nexit 1\n' "$T/creds.log" > "$t/bin/vcf"
  chmod +x "$t/bin/"*
  # Proxies cleared: a refused cluster connection is judged against the proxy environment, and the
  # machine running the suite must not decide whether the powered-off signature holds.
  ( cd "$t" && env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u NO_PROXY -u no_proxy \
      PATH="$t/bin:$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      KUBECONFIG="$t/kc" VKS_SUPERVISOR_KUBECONFIG="$supkc" VKS_LAB_STATE_DIR="$t/no-lab" \
      CREDS_TOKEN=1 CREDS_NO_PROBE="$NOPROBE" "${REPO}/scripts/creds.sh" 2>/dev/null )
}
banner() { sed -n '/Supervisor token EXPIRED/,/^  Context$/p' <<< "$1"; }
# The separate paragraph under "Access the UIs" about the silent ingress.
ingress_par() { sed -n '/is NOT ANSWERING on port/,/reachable ONLY through this ingress/p' <<< "$1"; }
ING_CHECK='Check the lab is up FIRST'
ING_UP='The Supervisor answered on this run, so the lab is UP'
ANCHOR_ENV="SUPERVISOR_HOST=${HOST}
VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt"
RENEW='renew and re-print, one step: make creds-renew'
LAB_UP='check the lab is UP'

# -- stale: the measured case (ingress silent, Harbor serving, Supervisor answers, anchor is old) --
out="$(creds_render "$SC_STALE" 0 silent "$ANCHOR_ENV")"; b="$(banner "$out")"; log_stale="$(cat "$T/creds.log")"
if has "$b" 'Supervisor token EXPIRED' && hasline "$out" 'lab-off: 0'; then ok "stale: the fixture reached the expired-token banner, not the nothing-answered block"
else bad "stale: the fixture did not reach the banner — fix the fixture; every case below is vacuous"; fi
if hasline "$out" 'sup-anchor: stale'; then ok "stale: the check's verdict is 'stale'"
else bad "stale: verdict is '$(command grep '^sup-anchor:' <<< "$out" || echo none)', want stale"; fi
if has "$b" 'RENEWING CANNOT WORK YET' && has "$b" "The Supervisor ${HOST} answers" \
   && has "$b" './secrets/supervisor-ca.crt does not verify its certificate' && has "$b" 'DIFFERENT Supervisor'; then
  ok "stale: says the stored login is for a different Supervisor and that renewing cannot work yet"
else bad "stale: the banner does not say the stored login is for a different Supervisor"; fi
if has "$b" "$LAB_UP"; then bad "stale: still says '$LAB_UP' although the Supervisor answered"
else ok "stale: does NOT say '$LAB_UP'"; fi
if has "$b" "$RENEW"; then bad "stale: still offers the renew command, which cannot work"
else ok "stale: does not offer the renew command"; fi
if hasline "$b" '       make fetch-supervisor-ca' \
   && hasline "$b" '       openssl x509 -in ./secrets/supervisor-ca.crt -noout -fingerprint -sha256' \
   && hasline "$b" '       VKS_AUTH_METHOD=vcf make vks-login'; then
  ok "stale: prints the re-pin commands, each a whole line with the real file"
else bad "stale: the re-pin commands are missing from the banner"; fi
if has "$b" "$VC" && has "$b" "'$NS'" && has "$b" "'$GC'" && has "$b" 'docs/scenario-1.md'; then
  ok "stale: names the vCenter, the namespace, the cluster and the doc section"
else bad "stale: the vCenter / namespace / cluster / doc section is missing from the banner"; fi
if command grep -q '[<>]' <<< "$b"; then bad "stale: a <placeholder> is printed in the banner: $(command grep '[<>]' <<< "$b" | head -1)"
else ok "stale: no <placeholder> in the banner"; fi

_ip="$(ingress_par "$out")"
if [ -n "$_ip" ] && has "$_ip" "$ING_UP" && ! has "$_ip" "$ING_CHECK"; then
  ok "stale: the ingress paragraph no longer says '$ING_CHECK' (the Supervisor answered)"
else bad "stale: the ingress paragraph is missing, or still says '$ING_CHECK' below a banner that says the Supervisor answers"; fi
if has "$_ip" 'is NOT ANSWERING on port' && has "$_ip" 'Do not add /etc/hosts entries for it yet' \
   && has "$_ip" 'Harbor and ArgoCD have' && has "$_ip" 'reachable ONLY through this ingress'; then
  ok "stale: the rest of the ingress paragraph is unchanged"
else bad "stale: the ingress paragraph lost a sentence other than the one clause"; fi

# -- the check itself: bounded, sends nothing, never logs in --
# A stale verdict costs TWO handshakes: the ordinary one, and one that ignores validity dates.
_n_hs="$(command grep -c "^openssl s_client -connect ${HOST}:443" <<< "$log_stale" || true)"
_n_nct="$(command grep -c "^openssl s_client .* -no_check_time " <<< "$log_stale" || true)"
if [ "$_n_hs" = 2 ] && [ "$_n_nct" = 1 ]; then ok "check: two handshakes to the configured endpoint on 443, the second with -no_check_time"
else bad "check: want 2 handshakes to ${HOST}:443 (1 with -no_check_time), got ${_n_hs} (${_n_nct}) (log: $(head -3 <<< "$log_stale" | tr '\n' '|'))"; fi
if [ "$(command grep -cx 'timeout-budget=2' <<< "$log_stale" || true)" = 2 ] \
   && [ "$(command grep -c '^timeout-budget=' <<< "$log_stale" || true)" = 2 ]; then ok "check: BOTH handshakes are bounded by this report's probe budget (2s by default)"
else bad "check: the handshakes' time limits are '$(command grep '^timeout-budget' <<< "$log_stale" | tr '\n' ' ')', want 2 and 2"; fi
if [ "$(command grep -cx 's_client-stdin-bytes=0' <<< "$log_stale" || true)" = 2 ] && ! has "$log_stale" "$CANARY"; then ok "check: nothing is written to either connection, and no password is on any openssl command line"
else bad "check: something was sent to a handshake, or the password reached an openssl command line"; fi
if command grep -q '^vcf ' <<< "$log_stale"; then bad "check: the report ran vcf — a read-only report must never log in"
else ok "check: the report never runs vcf"; fi
if has "$out" "$CANARY"; then bad "check: the password is in the report (stdout is not a terminal here)"
else ok "check: the password is not in the report"; fi

# -- verifies --
out="$(creds_render "$SC_OK" 0 silent "$ANCHOR_ENV")"; b="$(banner "$out")"
if hasline "$out" 'sup-anchor: verifies'; then ok "verifies: the check's verdict is 'verifies'"
else bad "verifies: verdict is '$(command grep '^sup-anchor:' <<< "$out" || echo none)', want verifies"; fi
if has "$b" "$RENEW" && ! has "$b" 'RENEWING CANNOT WORK YET' && ! has "$b" 'fetch-supervisor-ca'; then ok "verifies: offers the renew command, and no re-pin"
else bad "verifies: the renew command is missing, or a re-pin is offered for a good anchor"; fi
if has "$b" "$LAB_UP"; then bad "verifies: says '$LAB_UP' although the Supervisor answered and verified"
else ok "verifies: does NOT say '$LAB_UP' (the Supervisor answered), even with a silent ingress"; fi

if has "$(ingress_par "$out")" "$ING_UP" && ! has "$(ingress_par "$out")" "$ING_CHECK"; then
  ok "verifies: the ingress paragraph does not say '$ING_CHECK'"
else bad "verifies: the ingress paragraph still says '$ING_CHECK' although the Supervisor answered"; fi

# -- dates: the anchor is RIGHT; the certificate's dates are not valid on this machine --
SC2="$SC_OK"
out="$(creds_render "$SC_EXPIRED" 0 silent "$ANCHOR_ENV")"; b="$(banner "$out")"; knobs
if hasline "$out" 'sup-anchor: dates'; then ok "dates: the check's verdict is 'dates'"
else bad "dates: verdict is '$(command grep '^sup-anchor:' <<< "$out" || echo none)', want dates"; fi
if hasflat "$b" "The Supervisor ${HOST} answers, and the CA stored at ./secrets/supervisor-ca.crt is the right one, but the certificate's dates are not valid on this machine" \
   && hasflat "$b" "the certificate has expired (or is not valid yet), or this machine's clock is wrong"; then
  ok "dates: says the stored CA is the right one and the certificate's dates are not valid on this machine"
else bad "dates: the banner does not name the cause (right CA, dates not valid here: expired or wrong clock)"; fi
# ONE WORDING for this situation since supervisor_dates_how became tls_cert_dates_advice for the
# Supervisor (lib/tls.sh). These two assertions used to pin a text of its own: two commands for
# the reader to run and compare, ending "Do NOT re-fetch or re-pin the CA". The shared text READS
# the dates itself and shows them with this machine's clock; the pins are turned to it on purpose.
if hasflat "$b" "The CA file is the right one: with the dates ignored, it verifies the certificate ${HOST} presents." \
   && has "$b" 'valid from:' && has "$b" 'valid until:' && has "$b" "this machine's clock (date -u):" \
   && hasflat "$b" 'whoever operates the Supervisor has to renew it.'; then
  ok "dates: the shared dates text, for the Supervisor: the certificate's two dates, this machine's clock, who renews"
else bad "dates: the shared dates text (valid from / valid until / this machine's clock / who renews) is missing"; fi
if has "$b" "$RENEW" || has "$b" 'fetch-supervisor-ca' || has "$b" 'DIFFERENT Supervisor' || has "$b" "$LAB_UP"; then
  bad "dates: offers a renew, a re-pin, 'different Supervisor' or '$LAB_UP' for a clock/expiry problem"
else ok "dates: no renew command, no re-pin, no 'different Supervisor', no '$LAB_UP'"; fi
if hasflat "$b" 'Do NOT replace the CA file.' && ! hasflat "$b" 'whoever operates Harbor'; then ok "dates: says not to replace the CA file, and it is the Supervisor's text, not Harbor's"
else bad "dates: does not say the CA file must NOT be replaced (or it is Harbor's text)"; fi
# One `<` is legitimate here, and only here: the `</dev/null` redirect inside the pasteable command.
if command grep -q '[<>]' <<< "${b//<\/dev\/null 2>\/dev\/null/}"; then bad "dates: a <placeholder> is printed in the banner"
else ok "dates: no <placeholder> in the banner"; fi
if has "$(ingress_par "$out")" "$ING_UP"; then ok "dates: the ingress paragraph does not say '$ING_CHECK' either"
else bad "dates: the ingress paragraph still tells the reader to check the lab is up"; fi

# -- cadates: ignoring dates it verifies, and the stored CA FILE is itself outside its dates --
# The opposite remedy to "dates": the file has to be replaced, so the banner re-pins and must NOT
# say the CA is the right one to keep.
SC2="$SC_OK"; VERIFYOUT="$CA_EXPIRED_OUT"
out="$(creds_render "$SC_EXPIRED" 0 silent "$ANCHOR_ENV")"; b="$(banner "$out")"; knobs
if hasline "$out" 'sup-anchor: cadates'; then ok "cadates: the check's verdict is 'cadates'"
else bad "cadates: verdict is '$(command grep '^sup-anchor:' <<< "$out" || echo none)', want cadates"; fi
if hasflat "$b" "The Supervisor ${HOST} answers, but the CA stored at ./secrets/supervisor-ca.crt is itself outside its dates, so it cannot verify the certificate." \
   && has "$b" "$CA_DATES_HEAD" && has "$b" 'replace the file with the current CA:'; then
  ok "cadates: says the stored CA file is outside its own dates, and to replace it"
else bad "cadates: the banner does not say the CA FILE is outside its dates"; fi
if hasline "$b" '       make fetch-supervisor-ca' && hasline "$b" '       openssl x509 -in ./secrets/supervisor-ca.crt -noout -fingerprint -sha256'; then
  ok "cadates: prints the re-pin commands, each a whole line with the real file"
else bad "cadates: the re-pin commands are missing"; fi
if hasflat "$b" 'is the right one' || hasflat "$b" 'Do NOT re-fetch or re-pin the CA' || hasflat "$b" 'DIFFERENT Supervisor' || has "$b" "$RENEW"; then
  bad "cadates: says the CA is the right one to keep, blames a different Supervisor, or offers a renew"
else ok "cadates: no 'the right one', no 'do NOT re-pin', no 'different Supervisor', no renew command"; fi
if has "$(ingress_par "$out")" "$ING_UP"; then ok "cadates: the ingress paragraph knows the Supervisor answered"
else bad "cadates: the ingress paragraph still tells the reader to check the lab is up"; fi

# A second handshake that "verifies" only because there is NO certificate (a plaintext listener
# prints the ok line too) must not be read as "the anchor is right".
SC2="$SC_NOCERT"
out="$(creds_render "$SC_STALE" 0 silent "$ANCHOR_ENV")"; knobs
if hasline "$out" 'sup-anchor: stale'; then ok "dates: a date-ignoring handshake with NO peer certificate is not 'dates' (stays stale)"
else bad "dates: verdict '$(command grep '^sup-anchor:' <<< "$out" || echo none)' from a date-ignoring handshake that served no certificate"; fi

# -- silent --
out="$(creds_render "$SC_SILENT" 1 silent "$ANCHOR_ENV")"; b="$(banner "$out")"
if hasline "$out" 'sup-anchor: silent'; then ok "silent: the check's verdict is 'silent'"
else bad "silent: verdict is '$(command grep '^sup-anchor:' <<< "$out" || echo none)', want silent"; fi
if has "$b" 'FIRST: the recorded ingress did not answer either' && has "$b" "$LAB_UP" && has "$b" "$RENEW" \
   && ! has "$b" 'RENEWING CANNOT WORK YET'; then ok "silent + silent ingress: 'check the lab is UP' first, then the renew command"
else bad "silent + silent ingress: the lab-up advice or the renew command is missing"; fi
if has "$(ingress_par "$out")" "$ING_CHECK" && ! has "$(ingress_par "$out")" "$ING_UP"; then
  ok "silent: the ingress paragraph still says '$ING_CHECK' (nothing answered to say otherwise)"
else bad "silent: the ingress paragraph claims the Supervisor answered, or lost '$ING_CHECK'"; fi
out="$(creds_render "$SC_SILENT" 1 none "$ANCHOR_ENV")"; b="$(banner "$out")"
if has "$b" "FIRST: the Supervisor ${HOST} did not answer within 2s — $LAB_UP" && has "$b" "$RENEW"; then
  ok "silent + no ingress recorded: names the Supervisor and the time it was given (2s), then the renew command"
else bad "silent + no ingress recorded: no 'did not answer within 2s — check the lab is UP' although the Supervisor did not answer"; fi
out="$(creds_render "$SC_SILENT" 1 none "$ANCHOR_ENV
CREDS_PROBE_TIMEOUT_SECONDS=3")"; b="$(banner "$out")"
if has "$b" "FIRST: the Supervisor ${HOST} did not answer within 3s"; then ok "silent: the time printed is the budget really used (3s when the probe budget is 3)"
else bad "silent: with a 3s probe budget the banner does not say 'within 3s'"; fi

# -- skip: the check did not run, or its verdict is not one of the three. No new claim. --
skip_case() {  # skip_case <label> <want-handshake: yes|no> <render args...>
  local label="$1" want_hs="$2" o bb lg; shift 2
  o="$(creds_render "$@")"; bb="$(banner "$o")"; lg="$(cat "$T/creds.log")"
  if hasline "$o" 'sup-anchor: skip' && has "$bb" 'FIRST: the recorded ingress did not answer either' \
     && has "$bb" "$RENEW" && ! has "$bb" 'RENEWING CANNOT WORK YET' && ! has "$bb" 'did not answer within' \
     && has "$(ingress_par "$o")" "$ING_CHECK"; then
    ok "skip (${label}): the banner is the one it was before the check existed"
  else bad "skip (${label}): verdict '$(command grep '^sup-anchor:' <<< "$o" || echo none)', or the banner makes a claim the check did not make"; fi
  if [ "$want_hs" = no ]; then
    if has "$lg" 'openssl s_client'; then bad "skip (${label}): a handshake was attempted anyway"
    else ok "skip (${label}): no handshake attempted"; fi
  fi
}
skip_case "wrong-name verdict" yes "$SC_NAME" 0 silent "$ANCHOR_ENV"
skip_case "no anchor file"     no  "$SC_STALE" 0 silent "$ANCHOR_ENV" no
skip_case "no SUPERVISOR_HOST" no  "$SC_STALE" 0 silent "VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt"
# Verdict 4: the endpoint answered but served no certificate. Verdict 5: the anchor file is not
# empty and does not parse. Neither is "a different Supervisor", so neither may print the re-pin.
skip_case "no-certificate verdict" yes "$SC_NOCERT" 0 silent "$ANCHOR_ENV"
X509RC=1
skip_case "anchor file does not parse" no "$SC_STALE" 0 silent "$ANCHOR_ENV"
knobs

# -- probes forbidden (CREDS_NO_PROBE=1): no handshake, and no claim from one --
# End to end first. With probes off this report reads nothing from the Supervisor, so it prints no
# expired-token banner at all (the previous behaviour) — which is why the guard itself is then
# exercised directly below: the banner cannot reach it today.
NOPROBE=1
out="$(creds_render "$SC_STALE" 0 silent "$ANCHOR_ENV")"; lg="$(cat "$T/creds.log")"; knobs
if has "$lg" 'openssl s_client'; then bad "no-probe: a handshake was made under CREDS_NO_PROBE=1"
else ok "no-probe: no handshake under CREDS_NO_PROBE=1"; fi
if has "$out" 'RENEWING CANNOT WORK YET' || has "$out" 'DIFFERENT Supervisor' || has "$out" "$ING_UP" || has "$out" 'sup-anchor: stale'; then
  bad "no-probe: the report makes a claim only a handshake could support"
else ok "no-probe: the report says nothing a handshake would have had to establish"; fi
if has "$out" 'Access the UIs' ; then ok "no-probe: the fixture rendered a report (the two cases above are live)"
else bad "no-probe: the fixture rendered no report — the two cases above are vacuous"; fi
# The guard itself: _sup_anchor_probe, run alone, with a stand-in for the handshake that records
# whether it was called.
_probe_fn="$(awk 'index($0,"_sup_anchor_probe() {")==1{p=1} p{print} p&&/^\}/{exit}' scripts/creds.sh)"
[ -n "$_probe_fn" ] || bad "harness: could not extract _sup_anchor_probe() from creds.sh (renamed or reshaped)"
printf 'stand-in anchor\n' > "$T/probe-anchor.crt"
probe_says() {  # probe_says <no-probe 0|1> <verdict rc the stand-in returns> ; prints "<word> called=<0|1>"
  bash -c 'eval "$1"; _no_probe_snapshot="$2"; _want="$3"; SUPERVISOR_HOST="$4"; _mark="$5"
           supervisor_anchor_verdict() { : > "$_mark"; return "$_want"; }
           w="$(_sup_anchor_probe "$6")"; c=0; [ -e "$_mark" ] && c=1; rm -f "$_mark"; printf "%s called=%s" "$w" "$c"' \
    _ "$_probe_fn" "$1" "$2" "$HOST" "$T/probe-called" "$T/probe-anchor.crt"
}
_pc="$(probe_says 0 1)"
if [ "$_pc" = 'stale called=1' ]; then ok "probe guard control: with probes allowed the check runs (stale, called)"
else bad "probe guard control: want 'stale called=1' with probes allowed, got '${_pc}' — the cases below are vacuous"; fi
_pc="$(probe_says 1 1)"
if [ "$_pc" = 'skip called=0' ]; then ok "probe guard: with probes forbidden the check is NOT made and the answer is skip"
else bad "probe guard: with probes forbidden want 'skip called=0', got '${_pc}'"; fi
for _pv in '0 verifies' '2 silent' '6 dates' '7 cadates' '3 skip' '4 skip' '5 skip' '9 skip'; do
  _pc="$(probe_says 0 "${_pv%% *}")"
  if [ "$_pc" = "${_pv#* } called=1" ]; then ok "probe: verdict ${_pv%% *} -> ${_pv#* }"
  else bad "probe: verdict ${_pv%% *} should read '${_pv#* }', got '${_pc}'"; fi
done

# ── 2b. the nothing-answered block, when the Supervisor DOES answer ──────────────────────────────
# MEASURED 2026-10-10 on a lab restored to a bare state: the Supervisor was up, nothing this repo
# had installed existed any more, and the report said "NOTHING answered ... Otherwise the lab is
# off: if you run it, start it". Every case here holds the powered-off signature (`lab-off: 1`:
# the ingress refuses, Harbor completes nothing, the guest cluster API refuses) and varies only
# what the Supervisor does.
# WHAT THIS DOES NOT PROVE: that a real Supervisor accepts a connection on 443 (the connect is a
# stand-in here; tls_port_accepts itself runs against real listeners in
# test-harbor-ca-refetch-advice.sh and test-url-host-port.sh), nor which of these verdicts a
# restored lab really produces.
echo "== 2b. the nothing-answered block, by what the Supervisor did =="
# The block: from the token line that precedes it to the Context heading.
top() { sed -n '/^lab-off-sup:/,/^  Context$/p' <<< "$1"; }
# off_render <creds_render args>: the report is left in OFF_OUT and its exit status in OFF_RC (not
# printed: a command substitution would lose the status).
off_render() { OFF=1; OFF_RC=0; OFF_OUT="$(creds_render "$@")" || OFF_RC=$?; OFF=0; }
OLD_HEAD='NOTHING answered on this run'
UP_HEAD='The Supervisor answered, but nothing this repo installed did, and the cluster API did not answer either.'
ANS_HEAD="Something answered at the Supervisor address ${HOST}, but nothing this repo installed did, and the cluster API did not answer either."
STALE_HEAD='The lab is UP, but nothing this repo installed on it answered, and the cluster API did not answer either.'
CLOSE_OLD='Every URL and login below needs the lab answering.'
CLOSE_NEW='Every URL and login below except the Lab access rows needs what this repo installed.'
STATUS='make vks-cluster-status'
# The seven sentences of the old block that say "off" or "nothing", plus the Context line's clause.
# Each must be ABSENT from an arm in which the Supervisor answered.
old_absent() {  # old_absent <label> <report>
  local label="$1" o="$2" s miss=""
  for s in "$OLD_HEAD" 'The lab is still starting, is OFF, or this machine cannot reach it' \
           'Check this machine can reach the lab network' 'Otherwise the lab is off' \
           'Once it answers, renew the Supervisor token' "$CLOSE_OLD" 'nothing answered>' \
           'the lab did not answer'; do
    has "$o" "$s" && miss="${miss}[${s}] "
  done
  if [ -z "$miss" ]; then ok "${label}: none of the sentences that say the lab is off or that nothing answered is printed"
  else bad "${label}: still printed although the Supervisor answered: ${miss}"; fi
}
# The suppressions the powered-off signature already makes must hold in every arm.
off_kept() {  # off_kept <label> <report> <want lab-off-sup verdict>
  local label="$1" o="$2" want="$3"
  if hasline "$o" 'lab-off: 1' && hasline "$o" "lab-off-sup: ${want}"; then ok "${label}: the powered-off signature holds, and the Supervisor's verdict is '${want}'"
  else bad "${label}: want 'lab-off: 1' and 'lab-off-sup: ${want}', got '$(command grep '^lab-off' <<< "$o" | tr '\n' ' ')' — every case below is vacuous"; fi
  if has "$o" 'Supervisor token EXPIRED' || has "$o" 'sup-anchor:' || has "$o" 'is NOT ANSWERING on port' || has "$o" 're-check: make'; then
    bad "${label}: something the powered-off signature withholds is printed (the token banner, the ingress paragraph or the re-check line)"
  else ok "${label}: what the powered-off signature withholds is still withheld"; fi
}

# -- stale: it answers, and it is not the Supervisor this repo logged in to --
off_render "$SC_STALE" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; lg="$(cat "$T/creds.log")"
off_kept "off+stale" "$out" stale
if has "$tb" "$STALE_HEAD"; then ok "off+stale: the headline says the lab is UP and that nothing this repo installed on it answered"
else bad "off+stale: the headline is not '$STALE_HEAD'"; fi
old_absent "off+stale" "$out"
if hasflat "$tb" "answered: the Supervisor ${HOST}, with a certificate the CA stored at ./secrets/supervisor-ca.crt does NOT verify." \
   && hasflat "$tb" 'It is a DIFFERENT Supervisor from the one this repo logged in to: usually a lab that was destroyed and rebuilt, or restored from another build.'; then
  ok "off+stale: names the Supervisor that answered, the CA file, and that it is a different Supervisor"
else bad "off+stale: does not say which Supervisor answered, with which CA file, or that it is a different one"; fi
if has "$tb" "silent (stored addresses; they are probably the previous lab's): the ingress 127.0.0.1" && has "$tb" 'Harbor harbor.lab.example'; then
  ok "off+stale: lists the silent stored addresses as probably the previous lab's"
else bad "off+stale: the silent list (the ingress and Harbor, probably the previous lab's) is missing"; fi
if has "$tb" 'Do not start the lab, and do not run make creds-renew (it stops before it sends the password).' \
   && ! has "$tb" "$RENEW" && ! has "$tb" "$STATUS"; then ok "off+stale: says not to start the lab and not to renew, and offers neither a renew nor a cluster read"
else bad "off+stale: 'do not start the lab / do not renew' is missing, or a renew or ${STATUS} is offered"; fi
if hasline "$tb" '          make fetch-supervisor-ca' \
   && hasline "$tb" '          openssl x509 -in ./secrets/supervisor-ca.crt -noout -fingerprint -sha256' \
   && hasline "$tb" '          VKS_AUTH_METHOD=vcf make vks-login' && hasline "$tb" '        Then: make creds'; then
  ok "off+stale: prints the re-pin commands, each a whole line with the real file, then 'make creds'"
else bad "off+stale: the re-pin commands or the closing 'Then: make creds' are missing"; fi
if has "$tb" "$CLOSE_NEW"; then ok "off+stale: the closing line excepts the Lab access rows"
else bad "off+stale: the closing line is not '$CLOSE_NEW'"; fi
if command grep -q '[<>]' <<< "$tb"; then bad "off+stale: a <placeholder> is printed in the block: $(command grep '[<>]' <<< "$tb" | head -1)"
else ok "off+stale: no <placeholder> in the block"; fi
if has "$out" 'nothing this repo installed answered, so treat them as last known'; then ok "off+stale: the Context line says what did not answer (the install), not 'the lab'"
else bad "off+stale: the Context line does not say 'nothing this repo installed answered'"; fi
# The check itself, on this path: one connect first, then the two handshakes; nothing sent; no login.
if [ "$(command grep -c "^tcp-connect=${HOST}:443 budget=2$" <<< "$lg" || true)" = 1 ] \
   && [ "$(command grep -c "^openssl s_client -connect ${HOST}:443" <<< "$lg" || true)" = 2 ]; then
  ok "off check: one TCP connect to ${HOST}:443 (2s), then the two handshakes"
else bad "off check: want 1 connect and 2 handshakes to ${HOST}:443, got: $(command grep -c '^tcp-connect' <<< "$lg" || true) / $(command grep -c '^openssl s_client' <<< "$lg" || true)"; fi
if [ "$(command grep -cx 's_client-stdin-bytes=0' <<< "$lg" || true)" = 2 ] && ! has "$lg" "$CANARY" && ! command grep -q '^vcf ' <<< "$lg" \
   && ! has "$lg" "$VC"; then ok "off check: nothing is written to a connection, no password is on a command line, vcf never runs, vCenter is never dialled"
else bad "off check: something was sent, the password or the vCenter name reached a command line, or vcf ran"; fi
if [ "$OFF_RC" = 0 ] && ! has "$out" "$CANARY"; then ok "off check: the report exits 0 and the password is not in it"
else bad "off check: exit status ${OFF_RC} (want 0), or the password is in the report"; fi

# -- verifies, the stored token expired: renew, then ask the Supervisor --
knobs; off_render "$SC_OK" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"
off_kept "off+verifies" "$out" verifies
if has "$tb" "$UP_HEAD"; then ok "off+verifies: the headline says the Supervisor answered and nothing this repo installed did"
else bad "off+verifies: the headline is not '$UP_HEAD'"; fi
old_absent "off+verifies" "$out"
if hasflat "$tb" "answered: the Supervisor ${HOST}, and the CA stored at ./secrets/supervisor-ca.crt verifies it, so the lab is not off and this machine reaches it."; then
  ok "off+verifies: says the stored CA verifies the Supervisor, so the lab is not off"
else bad "off+verifies: does not say the stored CA verifies the Supervisor and the lab is not off"; fi
if has "$tb" 'silent (stored addresses): the ingress 127.0.0.1' \
   && has "$tb" 'This report does not log in to the Supervisor, so it cannot tell which of these it is:' \
   && has "$tb" '- the lab was just started and the guest cluster is still coming up' \
   && has "$tb" "- the guest cluster '${GC}' was deleted, or the lab was restored to a point before the install;" \
   && has "$tb" "- this machine reaches the Supervisor's address but not the guest cluster's."; then
  ok "off+verifies: the silent list, and the three states it cannot tell apart (naming the guest cluster)"
else bad "off+verifies: the silent list or one of the three states is missing"; fi
if hasline "$tb" '        1. If the lab was just started, wait a few minutes and re-run: make creds' \
   && has "$tb" '2. Otherwise ask the Supervisor whether the guest cluster exists. The Supervisor token this' \
   && has "$tb" "$RENEW" && has "$tb" "$(sso_lockout_note) — do not retry blind." \
   && hasline "$tb" "           Then: ${STATUS}"; then
  ok "off+verifies (token expired): wait and re-run; else renew (with the lockout note), then ${STATUS}"
else bad "off+verifies (token expired): step 1, the renew with its lockout note, or 'Then: ${STATUS}' is missing"; fi
if has "$tb" '3. If it prints DOES NOT EXIST, start again at docs/scenario-1.md "6. Guest cluster"' \
   && has "$tb" '(or "2. The vSphere Namespace" if the namespace is gone too).' && has "$tb" "$CLOSE_NEW"; then
  ok "off+verifies: step 3 names what ${STATUS} prints and the two doc sections; the closing line excepts the Lab access rows"
else bad "off+verifies: step 3 (DOES NOT EXIST, the two doc sections) or the closing line is missing"; fi
if has "$tb" 'fetch-supervisor-ca' || has "$tb" 'DIFFERENT Supervisor' || has "$tb" 'start it'; then
  bad "off+verifies: offers a re-pin, blames a different Supervisor, or says to start the lab"
else ok "off+verifies: no re-pin, no 'different Supervisor', no 'start it'"; fi
if command grep -q '[<>]' <<< "$tb"; then bad "off+verifies: a <placeholder> is printed in the block"
else ok "off+verifies: no <placeholder> in the block"; fi
# What step 3 quotes must be what the command prints, and the two section titles must exist.
if command grep -qF 'DOES NOT EXIST — the Supervisor answered, and has no such Cluster.' scripts/26-vks-cluster-status.sh \
   && command grep -qxF '## 6. Guest cluster' docs/scenario-1.md && command grep -qxF '## 2. The vSphere Namespace' docs/scenario-1.md \
   && command grep -q '^vks-cluster-status:' Makefile; then
  ok "off+verifies: ${STATUS} exists and prints DOES NOT EXIST; both doc sections exist under those titles"
else bad "off+verifies: step 3 cites a string ${STATUS} no longer prints, a target that is gone, or a doc section that was renamed"; fi

# -- verifies, the stored token still valid: no renew, no login, one command --
knobs; TOKEN=valid; off_render "$SC_OK" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; knobs
off_kept "off+verifies+valid token" "$out" verifies
if hasline "$tb" "        2. Otherwise ask the Supervisor whether the guest cluster exists: ${STATUS}" \
   && ! has "$tb" "$RENEW" && ! has "$tb" 'make vks-login' && ! has "$tb" 'SSO'; then
  ok "off+verifies (token valid): step 2 is ${STATUS} alone — no renew, no login, no SSO note"
else bad "off+verifies (token valid): step 2 is not the one command, or a renew/login is offered for a token that is valid"; fi

# -- verifies, no Supervisor login stored: log in first --
knobs; SUPKC=no; off_render "$SC_OK" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; knobs
off_kept "off+verifies+no login" "$out" verifies
if has "$tb" 'This repo has no Supervisor' && hasline "$tb" '             VKS_AUTH_METHOD=vcf make vks-login' \
   && has "$tb" "$(sso_lockout_note) — do not retry blind." && hasline "$tb" "           Then: ${STATUS}" && ! has "$tb" "$RENEW"; then
  ok "off+verifies (no login stored): says so, names the login with the lockout note, then ${STATUS}"
else bad "off+verifies (no login stored): does not say there is no stored login, or the login/lockout note/${STATUS} is missing"; fi

# -- verifies, the names unset: the command cannot run, so it is not prescribed --
knobs; NAMES=no; off_render "$SC_OK" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; knobs
off_kept "off+verifies+no names" "$out" verifies
if has "$tb" '2. Otherwise ask whoever runs the lab whether the guest cluster still exists.' \
   && has "$tb" 'VKS_NAMESPACE and VKS_CLUSTER_NAME' && has "$tb" '- the guest cluster was deleted' && ! has "$tb" "''" \
   && has "$tb" '3. If the guest cluster is gone, start again at docs/scenario-1.md "6. Guest cluster"' && ! has "$tb" 'If it prints'; then
  ok "off+verifies (names unset): asks the operator of the lab, says which two names ${STATUS} needs, prints no empty quoted name, and step 3 quotes no command output"
else bad "off+verifies (names unset): prescribes a command that stops on the unset names, prints an empty quoted name, or step 3 quotes the output of a command step 2 did not name"; fi

# -- answers: the address accepts a connection and there is no CA file to check it with --
knobs; off_render "$SC_STALE" 0 silent "$ANCHOR_ENV" no; out="$OFF_OUT"; tb="$(top "$out")"; lg="$(cat "$T/creds.log")"
off_kept "off+answers" "$out" answers
if has "$tb" "$ANS_HEAD" && ! has "$tb" "The Supervisor answered" && hasflat "$tb" "answered: the Supervisor address ${HOST} accepted a connection on port 443. This report could not check which Supervisor it is, so that is all it knows: something is running at that address, and this machine reaches it."; then
  ok "off+answers: says a connection was accepted, and that this is all the report knows"
else bad "off+answers: does not say the address accepted a connection and that the report could not check which Supervisor it is"; fi
old_absent "off+answers" "$out"
if has "$tb" 'verifies it' || has "$tb" 'the lab is not off' || has "$tb" 'DIFFERENT Supervisor' || has "$tb" 'fetch-supervisor-ca'; then
  bad "off+answers: makes a claim only a handshake could support (verifies / the lab is not off / a different Supervisor / a re-pin)"
else ok "off+answers: claims nothing a handshake would have had to establish"; fi
if has "$lg" 'openssl s_client'; then bad "off+answers: a handshake was attempted with no CA file"
else ok "off+answers: no handshake attempted (there is no CA file)"; fi
if has "$tb" "$STATUS" && has "$tb" "$CLOSE_NEW"; then ok "off+answers: the same steps and closing line as 'verifies'"
else bad "off+answers: ${STATUS} or the closing line is missing"; fi
# One of the login's own verdicts (wrong name) after an accepted connection is 'answers' too.
off_render "$SC_NAME" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"
if hasline "$out" 'lab-off-sup: answers' && ! has "$out" 'verifies it' && ! has "$out" "$OLD_HEAD"; then ok "off+answers: a wrong-name verdict after an accepted connection is 'answers', not 'verifies'"
else bad "off+answers: a wrong-name verdict reads '$(command grep '^lab-off-sup:' <<< "$out" || echo none)', want answers"; fi

# -- dates: the anchor is right; a login cannot work until the dates are valid --
knobs; SC2="$SC_OK"; off_render "$SC_EXPIRED" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; knobs
off_kept "off+dates" "$out" dates
old_absent "off+dates" "$out"
if has "$tb" "$UP_HEAD" && hasflat "$tb" "answered: the Supervisor ${HOST}, and the CA stored at ./secrets/supervisor-ca.crt is the right one (the certificate's dates are not valid on this machine: step 2), so the lab is not off and this machine reaches it."; then
  ok "off+dates: says the stored CA is the right one and points at step 2 for the dates"
else bad "off+dates: does not say the stored CA is the right one with dates that are not valid here"; fi
if has "$tb" "2. Otherwise settle the certificate's dates first." && has "$tb" 'valid from:' && has "$tb" 'valid until:' \
   && hasflat "$tb" 'Do NOT replace the CA file.' && hasline "$tb" '           Once the time is inside those two dates: make creds'; then
  ok "off+dates: step 2 is the shared dates text (the two dates, this machine's clock), then 'make creds'"
else bad "off+dates: step 2 does not carry the shared dates text, or its closing 'make creds' is missing"; fi
if has "$tb" "$RENEW" || has "$tb" 'fetch-supervisor-ca' || has "$tb" "$STATUS" || has "$tb" 'DIFFERENT Supervisor'; then
  bad "off+dates: offers a renew, a re-pin, ${STATUS} or 'different Supervisor' for a clock/expiry problem"
else ok "off+dates: no renew, no re-pin, no ${STATUS} (none can work until the dates are valid)"; fi

# -- cadates: the stored CA FILE is out of date; replacing it is the fix --
knobs; SC2="$SC_OK"; VERIFYOUT="$CA_EXPIRED_OUT"; off_render "$SC_EXPIRED" 0 silent "$ANCHOR_ENV"; out="$OFF_OUT"; tb="$(top "$out")"; knobs
off_kept "off+cadates" "$out" cadates
old_absent "off+cadates" "$out"
if has "$tb" "$UP_HEAD" && hasflat "$tb" "answered: the Supervisor ${HOST}; the CA stored at ./secrets/supervisor-ca.crt is outside its own dates (step 2)" \
   && has "$tb" '2. Otherwise replace the stored CA file first.' && has "$tb" "$CA_DATES_HEAD" \
   && hasline "$tb" '             make fetch-supervisor-ca' && hasline "$tb" '           After the login: make creds'; then
  ok "off+cadates: says the CA file is outside its dates; step 2 is the file's dates and the re-pin commands"
else bad "off+cadates: the CA-file dates text or the re-pin commands are missing from step 2"; fi
if has "$tb" "$RENEW" || hasflat "$tb" 'is the right one' || has "$tb" 'DIFFERENT Supervisor'; then
  bad "off+cadates: offers a renew, says the CA is the right one to keep, or blames a different Supervisor"
else ok "off+cadates: no renew, no 'the right one', no 'different Supervisor'"; fi

# -- the cells: a read that ran out of time says what did not answer --
# With the Supervisor answering, '<not read — nothing answered>' would contradict the headline.
knobs; TOKEN=valid; HANG=argocd; off_render "$SC_OK" 0 silent "$ANCHOR_ENV
CREDS_KUBE_TIMEOUT_SECONDS=1"; out="$OFF_OUT"; knobs
off_kept "off+verifies+cells" "$out" verifies
# TWO cells: ArgoCD's password (the read ran out of time) and the headlamp token (the guest
# cluster's API refused the request). Both must say it, so the count is asserted, not presence.
_nc="$(command grep -c '<not read — the install did not answer>' <<< "$out" || true)"
if [ "$_nc" = 2 ] && ! has "$out" 'nothing answered>'; then
  ok "off+verifies: the ArgoCD and headlamp cells both read '<not read — the install did not answer>'"
else bad "off+verifies: want 2 cells reading '<not read — the install did not answer>' and none saying 'nothing answered', got ${_nc} (cells: $(command grep -o '<not read[^>]*>' <<< "$out" | sort | uniq -c | tr '\n' ' '))"; fi
knobs; TOKEN=valid; HANG=argocd; TCPRC=1; off_render "$SC_OK" 0 silent "$ANCHOR_ENV
CREDS_KUBE_TIMEOUT_SECONDS=1"; out="$OFF_OUT"; knobs
_nc="$(command grep -c '<not read — nothing answered>' <<< "$out" || true)"
if hasline "$out" 'lab-off-sup: silent' && [ "$_nc" = 2 ] && ! has "$out" 'the install did not answer'; then
  ok "off+silent: the same two cells still read '<not read — nothing answered>' when the Supervisor did not answer"
else bad "off+silent: want 2 cells reading '<not read — nothing answered>', got ${_nc} (cells: $(command grep -o '<not read[^>]*>' <<< "$out" | sort | uniq -c | tr '\n' ' '))"; fi
# The headlamp token has a second way to get no reply: the request itself runs out of time.
knobs; TOKEN=valid; HANG=headlamp; off_render "$SC_OK" 0 silent "$ANCHOR_ENV
CREDS_KUBE_TIMEOUT_SECONDS=1"; out="$OFF_OUT"; knobs
_nc="$(command grep -c '<not read — the install did not answer>' <<< "$out" || true)"
if hasline "$out" 'lab-off-sup: verifies' && [ "$_nc" = 1 ] && ! has "$out" 'nothing answered>'; then
  ok "off+verifies: a headlamp token request that ran out of time reads '<not read — the install did not answer>' too"
else bad "off+verifies: a timed-out headlamp token request: want 1 cell reading '<not read — the install did not answer>', got ${_nc} (cells: $(command grep -o '<not read[^>]*>' <<< "$out" | sort | uniq -c | tr '\n' ' '))"; fi

# -- silent and skip: the block as it was before the check existed --
# `silent` two ways (the connect is refused; the connect is accepted and the handshake gets no
# answer) and `skip` (no SUPERVISOR_HOST). The three blocks must be the SAME TEXT, and that text
# must be the old one: its seven sentences are pinned in test-creds-show.sh's powered-off fixture.
knobs; TCPRC=1; off_render "$SC_OK" 0 silent "$ANCHOR_ENV"; out_ref="$OFF_OUT"; lg="$(cat "$T/creds.log")"; knobs
off_kept "off+silent (refused)" "$out_ref" silent
if has "$lg" 'openssl s_client'; then bad "off+silent (refused): a handshake was attempted after the connect was refused"
else ok "off+silent (refused): the refused connect is the whole cost — no handshake follows"; fi
off_render "$SC_SILENT" 1 silent "$ANCHOR_ENV"; out_hs="$OFF_OUT"
off_kept "off+silent (handshake)" "$out_hs" silent
off_render "$SC_STALE" 0 silent "VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt"; out_skip="$OFF_OUT"; lg="$(cat "$T/creds.log")"
off_kept "off+skip (no SUPERVISOR_HOST)" "$out_skip" skip
if has "$lg" 'tcp-connect=' || has "$lg" 'openssl s_client'; then bad "off+skip: a connect or a handshake was made with no SUPERVISOR_HOST"
else ok "off+skip: nothing is dialled when SUPERVISOR_HOST is not set"; fi
_blk() { top "$1" | command grep -v '^lab-off-sup:'; }
if [ -n "$(_blk "$out_ref")" ] && [ "$(_blk "$out_ref")" = "$(_blk "$out_hs")" ] && [ "$(_blk "$out_ref")" = "$(_blk "$out_skip")" ]; then
  ok "off+silent/skip: the three blocks are the same text"
else bad "off+silent/skip: the block differs between a refused connect, a silent handshake and no SUPERVISOR_HOST"; fi
for _o in "$out_ref" "$out_skip"; do
  if has "$_o" "$OLD_HEAD" && has "$_o" 'The lab is still starting, is OFF, or this machine cannot reach it. Do this, in order:' \
     && has "$_o" 'Otherwise the lab is off: if you run it, start it; if not, ask whoever runs it.' && has "$_o" "$CLOSE_OLD" \
     && has "$_o" 'the lab did not answer, so treat them as last known' \
     && ! has "$_o" 'The Supervisor answered' && ! has "$_o" 'The lab is UP' && ! has "$_o" "$CLOSE_NEW" && ! has "$_o" 'the install did not answer'; then
    ok "off+$(command grep '^lab-off-sup:' <<< "$_o" | cut -d' ' -f2): the old block, and no sentence from the new arms"
  else bad "off+$(command grep '^lab-off-sup:' <<< "$_o" | cut -d' ' -f2): the old block lost a sentence, or carries one from the new arms"; fi
done

# -- a report that is NOT in the powered-off state pays nothing for this check --
knobs; out="$(creds_render "$SC_STALE" 0 silent "$ANCHOR_ENV")"; lg="$(cat "$T/creds.log")"
if hasline "$out" 'lab-off: 0' && ! has "$out" 'lab-off-sup:' && ! has "$lg" 'tcp-connect='; then
  ok "not off: no 'lab-off-sup' token and no extra connect when the signature does not hold"
else bad "not off: the Supervisor connect ran (or its token printed) although 'lab-off' is 0"; fi

# -- the function alone: every guard, with stand-ins that record whether they were called --
_off_fn="$(awk 'index($0,"_sup_off_probe() {")==1{p=1} p{print} p&&/^\}/{exit}' scripts/creds.sh)"
[ -n "$_off_fn" ] || bad "harness: could not extract _sup_off_probe() from creds.sh (renamed or reshaped)"
off_says() {  # off_says <no-probe 0|1> <host> <connect rc> <anchor word> ; prints "<word> tcp=<0|1> anchor=<0|1>"
  bash -c 'eval "$1"; _no_probe_snapshot="$2"; SUPERVISOR_HOST="$3"; _trc="$4"; _aw="$5"; _m="$6"
           tls_port_accepts() { : > "$_m.tcp"; return "$_trc"; }
           _sup_anchor_probe() { : > "$_m.anchor"; printf "%s" "$_aw"; }
           w="$(_sup_off_probe /some/ca)"; t=0; a=0; [ -e "$_m.tcp" ] && t=1; [ -e "$_m.anchor" ] && a=1
           printf "%s tcp=%s anchor=%s" "$w" "$t" "$a"' \
    _ "$_off_fn" "$1" "$2" "$3" "$4" "$T/off-mark"
  rm -f "$T/off-mark.tcp" "$T/off-mark.anchor"
}
for _oc in "0|${HOST}|0|stale|stale tcp=1 anchor=1"     "0|${HOST}|0|verifies|verifies tcp=1 anchor=1" \
           "0|${HOST}|0|dates|dates tcp=1 anchor=1"     "0|${HOST}|0|cadates|cadates tcp=1 anchor=1" \
           "0|${HOST}|0|silent|silent tcp=1 anchor=1"   "0|${HOST}|0|skip|answers tcp=1 anchor=1" \
           "0|${HOST}|1|stale|silent tcp=1 anchor=0"    "1|${HOST}|0|stale|skip tcp=0 anchor=0" \
           "0||0|stale|skip tcp=0 anchor=0"; do
  IFS='|' read -r _o1 _o2 _o3 _o4 _o5 <<< "$_oc"
  _og="$(off_says "$_o1" "$_o2" "$_o3" "$_o4")"
  if [ "$_og" = "$_o5" ]; then ok "off probe: no-probe=${_o1} host='${_o2}' connect-rc=${_o3} anchor=${_o4} -> ${_o5}"
  else bad "off probe: no-probe=${_o1} host='${_o2}' connect-rc=${_o3} anchor=${_o4} should give '${_o5}', got '${_og}'"; fi
done
_oa="$(bash -c 'eval "$1"; _no_probe_snapshot=0; SUPERVISOR_HOST="$2"; CREDS_PROBE_TIMEOUT_SECONDS=3
                tls_port_accepts() { printf "%s %s %s" "$1" "$2" "$3" >&2; return 1; }
                _sup_anchor_probe() { :; }; _sup_off_probe /some/ca >/dev/null' _ "$_off_fn" "$HOST" 2>&1)"
if [ "$_oa" = "${HOST} 443 3" ]; then ok "off probe: the connect goes to SUPERVISOR_HOST on 443 with this report's probe budget (3s when it is 3)"
else bad "off probe: the connect was asked as '${_oa}', want '${HOST} 443 3'"; fi

# ── 3. 30-vks-login.sh's refusal ─────────────────────────────────────────────────────────────────
echo "== 3. the login's refusal =="
L="$T/login"; mkdir -p "$L/bin" "$L/repo"; cp -a scripts .env.example "$L/repo/"
printf 'stand-in anchor\n' > "$L/anchor.crt"
cat > "$L/bin/vcf" <<STUB
#!/bin/sh
printf 'vcf %s\n' "\$*" >> "$L/vcf.log"
printf 'group=%s\n' "\${VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION-UNSET}" >> "$L/vcf.group"
case "\$1 \$2" in "context delete") exit 0 ;; "context create") echo "Logged in successfully." >&2; exit 0 ;; esac
exit 1
STUB
cat > "$L/bin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in *"config current-context"*) printf '%s\n' "${STUB_CUR:-}"; exit 0 ;; esac
exit 0
STUB
cat > "$L/bin/openssl" <<'STUB'
#!/bin/sh
case "$1" in
  x509)
    case "$*" in
      *-subject*)     printf 'subject=%s\n' "$STUB_SUBJ" ;;
      *-issuer*)      cat >/dev/null; printf 'issuer=%s\n' "$STUB_ISS" ;;
      *-fingerprint*) printf 'sha256 Fingerprint=AA:BB\n' ;;
    esac
    exit 0 ;;
  verify) printf '%s\n' "${STUB_VERIFY:-}"; exit 0 ;;
  s_client) cat >/dev/null
    case " $* " in
      *" -no_check_time "*) printf '%s\n' "${STUB_SCLIENT2:-$STUB_SCLIENT}" ;;
      *)                    printf '%s\n' "$STUB_SCLIENT" ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$L/bin/"*
login() {  # login <s_client transcript> <anchor subject> <endpoint issuer> [transcript when -no_check_time]
  : > "$L/vcf.log"
  ( cd "$L/repo" && env -i HOME="$L" PATH="$L/bin:$PATH" LANG="${LANG:-C.UTF-8}" SKIP_DOTENV=1 \
      VKS_AUTH_METHOD=vcf SUPERVISOR_HOST="$HOST" VKS_CONTEXT_NAME=vks-test VKS_NAMESPACE="$NS" \
      VKS_CLUSTER_NAME="$GC" VCENTER_HOST="$VC" VKS_USERNAME=administrator@vsphere.local \
      VCF_CLI_VSPHERE_PASSWORD="$CANARY" VKS_CA_CERT_FILE="$L/anchor.crt" \
      KUBECONFIG="$L/guest.kc" VKS_SUPERVISOR_KUBECONFIG="$L/sup.kc" VKS_STATE_FILE="$L/state" \
      STUB_SCLIENT="$1" STUB_SCLIENT2="${4:-$1}" STUB_SUBJ="$2" STUB_ISS="$3" STUB_CUR="vks-test:${NS}" \
      STUB_VERIFY="${STUB_VERIFY:-}" \
      bash scripts/30-vks-login.sh 2>&1 )
}
# CONTROL first: with an anchor that verifies, the login goes on to `vcf context create`. Without
# this, "vcf was never called" below would also be true of a script that died for any other reason.
: > "$L/vcf.group"
out="$(login "$SC_OK" 'CN=CA' 'CN=CA')"; rc=$?
# EVERY vcf THE LOGIN RUNS IS TOLD WHICH ESSENTIALS PLUGIN GROUP TO USE (.env.example's value,
# exported by load_env; the harness passes a clean environment, so nothing else can supply it).
# Left to itself a v9.1.1 CLI asks for a group whose telemetry plugin is not published, and
# every login printed a failed download.
_grp_want="group=$(command grep -E '^VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION=' "$L/repo/.env.example" | head -1 | cut -d= -f2-)"
if [ -s "$L/vcf.group" ] && [ "$_grp_want" != 'group=' ] && [ "$(sort -u "$L/vcf.group")" = "$_grp_want" ]; then
  ok "login: every vcf command it ran ($(command grep -c . "$L/vcf.group")) had VCF_CLI_ESSENTIALS_PLUGIN_GROUP_VERSION set to .env.example's value"
else bad "login: a vcf command ran without the essentials plugin group set (wanted '${_grp_want}', saw: $(sort -u "$L/vcf.group" 2>/dev/null | tr '\n' ' '))"; fi
if command grep -q '^vcf context create ' "$L/vcf.log" && ! has "$out" 'does NOT verify'; then ok "login control: an anchor that verifies -> the login proceeds to vcf context create (rc=$rc)"
else bad "login control: with a verifying anchor the stand-in login did not reach vcf context create (rc=$rc) — the cases below are vacuous"; fi

out="$(login "$SC_STALE" 'CN=CA, O=vcsa.example.test' 'CN=CA, O=vcsa.example.test')"; rc=$?
if [ "$rc" != 0 ] && has "$out" "does NOT verify the certificate ${HOST}"; then ok "login: a stale anchor stops the login (rc=$rc)"
else bad "login: a stale anchor must stop the login with the does-NOT-verify message (rc=$rc)"; fi
if [ ! -s "$L/vcf.log" ] && has "$out" 'No password was sent.'; then ok "login: vcf was never run, and the message says no password was sent"
else bad "login: vcf ran before the refusal (log: $(tr '\n' '|' < "$L/vcf.log")), or the message does not say no password was sent"; fi
if hasline "$out" '    make fetch-supervisor-ca' \
   && hasline "$out" "    openssl x509 -in ${L}/anchor.crt -noout -fingerprint -sha256" \
   && hasline "$out" '    VKS_AUTH_METHOD=vcf make vks-login'; then
  ok "login: the refusal prints the re-pin commands, each a whole line with the real file"
else bad "login: the refusal does not print the re-pin commands"; fi
if has "$out" "$VC" && has "$out" "'$NS'" && has "$out" "'$GC'" && has "$out" 'docs/scenario-1.md'; then
  ok "login: names the vCenter, the namespace, the cluster and the doc section"
else bad "login: the vCenter / namespace / cluster / doc section is missing from the refusal"; fi
_refusal="$(sed -n '/does NOT verify the certificate/,$p' <<< "$out")"
if command grep -q '[<>]' <<< "$_refusal"; then bad "login: a <placeholder> is printed: $(command grep '[<>]' <<< "$_refusal" | head -1)"
else ok "login: no <placeholder> in the refusal"; fi
if command grep -B1 -xF '    VKS_AUTH_METHOD=vcf make vks-login' <<< "$out" | command grep -qxF '  Do not run it until you have confirmed the SHA-256.'; then
  ok "login: 'do not run it until the SHA-256 is confirmed' sits directly above the login command"
else bad "login: the line directly above the login command is not the confirm-first warning"; fi
if has "$out" 'Re-pin it from the lab that is actually running'; then bad "login: the command-less 'Re-pin it from the lab that is actually running' is back"
else ok "login: the command-less re-pin sentence is gone"; fi
if has "$out" "$CANARY"; then bad "login: the password is in the output"
else ok "login: the password is not in the output"; fi
if has "$out" 'VKS_INSECURE_SKIP_TLS_VERIFY' && ! command grep -qE '^ *VKS_INSECURE_SKIP_TLS_VERIFY=' <<< "$out"; then
  ok "login: still warns against skipping TLS verification, and prints no command that does"
else bad "login: the warning against VKS_INSECURE_SKIP_TLS_VERIFY is missing, or a skip command is printed"; fi
# Equal names (the rebuilt-lab case: a new CA under the old subject) must be explained, and only then.
if has "$out" 'The two names are the same and the CAs are NOT'; then ok "login: equal anchor/issuer names -> says the name cannot tell the CAs apart"
else bad "login: anchor subject == endpoint issuer, and nothing explains why it still fails"; fi
out="$(login "$SC_STALE" 'CN=CA, O=old.example.test' 'CN=CA, O=new.example.test')"
if has "$out" 'The two names are the same'; then bad "login: claims the names are the same when they differ"
else ok "login: different names -> no 'same names' line"; fi

# Dates: the anchor is right, the certificate's dates are not valid on this machine. Its own
# message — not "a different Supervisor", and not a re-pin.
out="$(login "$SC_EXPIRED" 'CN=CA' 'CN=CA' "$SC_OK")"; rc=$?
if [ "$rc" != 0 ] && hasflat "$out" "is the RIGHT anchor for ${HOST}, but the certificate it presents is not valid at this machine's current time" \
   && hasflat "$out" "the certificate has expired (or is not valid yet), or this machine's clock is wrong"; then
  ok "login dates: stops, and names the cause (right anchor, dates not valid here) (rc=$rc)"
else bad "login dates: an expired certificate under the right anchor must stop with the dates message (rc=$rc)"; fi
if [ ! -s "$L/vcf.log" ] && has "$out" 'No password was sent.'; then ok "login dates: vcf was never run, and the message says no password was sent"
else bad "login dates: vcf ran before the refusal, or the message does not say no password was sent"; fi
if hasflat "$out" "The CA file is the right one: with the dates ignored, it verifies the certificate ${HOST} presents." \
   && has "$out" 'valid from:' && has "$out" "this machine's clock (date -u):" \
   && hasflat "$out" 'whoever operates the Supervisor has to renew it. Do NOT replace the CA file.'; then
  ok "login dates: the shared dates text, for the Supervisor (the same one the report prints)"
else bad "login dates: the shared dates text is missing from the refusal"; fi
if has "$out" 'does NOT verify' || has "$out" 'fetch-supervisor-ca' || has "$out" 'DESTROYED and rebuilt'; then
  bad "login dates: blames a different Supervisor / offers a re-pin for a clock or expiry problem"
else ok "login dates: no 'different Supervisor', no re-pin"; fi
if has "$out" 'VKS_INSECURE_SKIP_TLS_VERIFY' && ! command grep -qE '^ *VKS_INSECURE_SKIP_TLS_VERIFY=' <<< "$out"; then
  ok "login dates: warns against skipping TLS verification, and prints no command that does"
else bad "login dates: the warning against VKS_INSECURE_SKIP_TLS_VERIFY is missing, or a skip command is printed"; fi
# The stored CA FILE is itself outside its dates (verdict 7): its own refusal. Not the dates
# message (that one says to keep the CA), not "a different Supervisor"; it re-pins.
out="$(STUB_VERIFY="$CA_EXPIRED_OUT" login "$SC_EXPIRED" 'CN=CA' 'CN=CA' "$SC_OK")"; rc=$?
if [ "$rc" != 0 ] && hasflat "$out" "the CA at ${L}/anchor.crt is itself outside its dates, so it cannot verify the certificate ${HOST} presents." \
   && has "$out" "$CA_DATES_HEAD" && has "$out" 'replace the file with the current CA:'; then
  ok "login cadates: stops, and says the CA FILE is outside its own dates (rc=$rc)"
else bad "login cadates: an out-of-date CA file must stop with its own message (rc=$rc)"; fi
if [ ! -s "$L/vcf.log" ] && has "$out" 'No password was sent.'; then ok "login cadates: vcf was never run, and the message says no password was sent"
else bad "login cadates: vcf ran before the refusal, or the message does not say no password was sent"; fi
if hasline "$out" '    make fetch-supervisor-ca' && hasline "$out" "    openssl x509 -in ${L}/anchor.crt -noout -fingerprint -sha256"; then
  ok "login cadates: prints the re-pin commands with the real file"
else bad "login cadates: the re-pin commands are missing"; fi
if hasflat "$out" 'RIGHT anchor' || hasflat "$out" 'Do NOT re-fetch or re-pin the CA' || hasflat "$out" 'DESTROYED and rebuilt'; then
  bad "login cadates: says to keep the CA, or blames a rebuilt Supervisor"
else ok "login cadates: no 'RIGHT anchor', no 'do NOT re-pin', no 'rebuilt Supervisor'"; fi
if has "$out" "$CANARY"; then bad "login cadates: the password is in the output"
else ok "login cadates: the password is not in the output"; fi
# And the other direction: when ignoring dates does NOT make it verify, it is still the stale arm.
out="$(login "$SC_EXPIRED" 'CN=CA' 'CN=CA' "$SC_STALE")"
if has "$out" 'does NOT verify' && has "$out" 'make fetch-supervisor-ca' && ! has "$out" 'RIGHT anchor'; then
  ok "login: a failure that survives ignoring the dates is still 'does NOT verify' + the re-pin"
else bad "login: a chain failure was reported as a dates problem"; fi

# ── 4. one implementation, two callers ───────────────────────────────────────────────────────────
echo "== 4. one check, two callers =="
# The USAGE form, on comment-stripped source: a mention in a comment proves nothing.
_code() { command grep -v '^[[:space:]]*#' "$1"; }
# The literal text `"$SUPERVISOR_HOST"` is what is searched for (SC2016 is deliberate).
# shellcheck disable=SC2016
_form='supervisor_anchor_verdict "$SUPERVISOR_HOST"'
# shellcheck disable=SC2016
_old='ca_verifies_endpoint "$SUPERVISOR_HOST"'
for f in scripts/30-vks-login.sh scripts/creds.sh; do
  if command grep -qF -- "$_form" <<< "$(_code "$f")" && ! command grep -qF -- "$_old" <<< "$(_code "$f")"; then
    ok "shared: ${f#scripts/} asks supervisor_anchor_verdict, and has no private copy of the check"
  else bad "shared: ${f#scripts/} does not call supervisor_anchor_verdict \"\$SUPERVISOR_HOST\" (or still carries its own ca_verifies_endpoint call)"; fi
done
if [ "$(command grep -c '^supervisor_anchor_verdict() {' scripts/lib/tls.sh)" = 1 ] \
   && [ "$(command grep -c '^supervisor_repin_how() {' scripts/lib/os.sh)" = 1 ] \
   && [ "$(command grep -c '^supervisor_dates_how() {' scripts/lib/tls.sh)" = 1 ] \
   && [ "$(command grep -c '^supervisor_dates_how() {' scripts/lib/os.sh)" = 0 ]; then
  ok "shared: each helper is defined exactly once"
else bad "shared: supervisor_anchor_verdict / supervisor_repin_how / supervisor_dates_how is not defined exactly once"; fi

if [ "$fail" = 0 ]; then echo "test-supervisor-anchor-advice: ALL PASS ($n)"; else echo "test-supervisor-anchor-advice: FAILED ($n ran)" >&2; exit 1; fi
