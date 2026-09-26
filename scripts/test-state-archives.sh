#!/usr/bin/env bash
# test-state-archives.sh — state_archive never overwrites, `make state-archives` never prints a value,
# and `make state-restore` refuses anything that is not a plain archive and is reversible (B723).
# Everything runs against a throwaway sink via VKS_STATE_FILE; the operator's own state is untouched.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export VKS_STATE_FILE="$T/.env.state"
unset KUBECONFIG
rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

echo "== state_archive: two archives in the same second keep BOTH =="
printf 'X=first\n' > "$VKS_STATE_FILE"; state_archive t1 2>/dev/null
printf 'X=second\n' > "$VKS_STATE_FILE"; state_archive t2 2>/dev/null
n="$(find "$T" -maxdepth 1 -name '.env.state.stale-*' | wc -l | tr -d ' ')"
if [ "$n" = 2 ] && grep -rqx 'X=first' "$T"/.env.state.stale-* && grep -rqx 'X=second' "$T"/.env.state.stale-*; then ok "2 archives, both contents kept"
else bad "same-second archives: ${n} file(s) — an archive was overwritten"; fi

echo "== state_key_is_secret agrees with state_show's redaction =="
dis=0
for k in HARBOR_PASSWORD GPG_PASSPHRASE ARGOCD_TOKEN SOME_SECRET GITHUB_PAT TLS_KEY DB_CRED \
         ARGOCD_PASSWORD_WAIT_SECONDS SSH_KEY_FILE INGRESS_LB_IP HARBOR_USERNAME; do
  red="$(printf '%s=v\n' "$k" | sed 's/\(PASSWORD\|PASSPHRASE\|TOKEN\|SECRET\|PAT\|KEY\|CRED\)=.*/\1=<redacted>/')"
  case "$red" in *'<redacted>') s=1 ;; *) s=0 ;; esac
  state_key_is_secret "$k" && p=1 || p=0
  [ "$s" = "$p" ] || { bad "disagree on ${k}: state_show=${s} predicate=${p}"; dis=1; }
done
if [ "$dis" = 0 ]; then ok "predicate and redaction agree on 11 keys"; fi

echo "== the reporter lists key NAMES and never a value =="
rm -f "$T"/.env.state*
printf 'VKS_STATE_SERVER=https://10.0.0.1:6443\nVKS_STATE_CONTEXT=lab\nHARBOR_PASSWORD=HUNTER2SECRET\nINGRESS_LB_IP=10.9.9.9\n' > "$T/.env.state.stale-20260101-000000"
chmod 600 "$T/.env.state.stale-20260101-000000"
: > "$T/.env.state.a1B2c3"
ln -s /etc/hosts "$T/.env.state.stale-20260102-000000"
printf "GITEA_ADMIN_PASSWORD='Hunter2Top\nMIIEvQIBADANBgkqhkiG9w0B=='\nOTHER_KEY=x\nPOUND=a#b\nTAIL='never closed\n" > "$T/.env.state.stale-20260104-000000"
printf 'VKS_STATE_SERVER=https://10.0.0.2\xc2\x9b31m:6443\n' > "$T/.env.state.stale-20260105-000000"
: > "$T/.env.state.backup"
out="$(bash "$SCRIPT_DIR/state-archives.sh" 2>&1)"; r=$?
if [ "$r" = 0 ] && grep -q 'HARBOR_PASSWORD(secret)' <<< "$out" && grep -q 'INGRESS_LB_IP' <<< "$out"; then ok "names listed, the secret flagged"
else bad "reporter output (rc=$r): $out"; fi
if grep -qE 'HUNTER2SECRET|10\.9\.9\.9|Hunter2Top|MIIEvQ' <<< "$out"; then bad "the reporter printed a VALUE (or a line of a multi-line one)"; else ok "no value printed, not even a continuation line"; fi
if grep -q 'OTHER_KEY' <<< "$out" && grep -q 'unterminated quote' <<< "$out"; then ok "a key after a multi-line value is read; an unclosed quote is reported, not guessed"
else bad "multi-line parse: $(grep -A1 20260104 <<< "$out")"; fi
if LC_ALL=C grep -q $'\xc2\x9b' <<< "$out"; then bad "a C1 control byte reached the terminal"; else ok "C1 control bytes stripped"; fi
if grep -A1 'env.state.backup' <<< "$out" | grep -q '\[other\]'; then ok "a human '.backup' is not mistaken for a temp leftover"; else bad ".backup misclassified: $(grep 'env.state.backup' <<< "$out")"; fi
if grep -q 'https://10.0.0.1:6443' <<< "$out"; then ok "the stamp server is shown"; else bad "stamp missing"; fi
if grep -q '\[temp\]' <<< "$out" && grep -q '\[symlink\]' <<< "$out" && grep -q '6 archive(s)' <<< "$out"; then ok "temp leftover and symlink classified; denominator 6"
else bad "classification/denominator: $out"; fi

restore() { R=0; O="$(ARCHIVE="$1" bash "$SCRIPT_DIR/state-restore.sh" 2>&1)" || R=$?; }
echo "== restore refuses anything that is not a plain archive =="
restore ''; if [ "$R" != 0 ]; then ok "empty name refused"; else bad "empty name accepted"; fi
restore '../etc/passwd'; if [ "$R" != 0 ]; then ok "a path refused"; else bad "a path accepted"; fi
restore '.env.state.a1B2c3'; if [ "$R" != 0 ] && grep -q 'temp leftover' <<< "$O"; then ok "temp leftover refused, by its own reason"; else bad "temp: rc=$R $O"; fi
restore '.env.state.stale-20260102-000000'; if [ "$R" != 0 ] && grep -q 'SYMLINK\|symlink' <<< "$O" && [ ! -L "$VKS_STATE_FILE" ]; then ok "symlink refused, the sink is not a link"; else bad "symlink restored"; fi
restore '.env.state.stale-19990101-000000'; if [ "$R" != 0 ] && grep -q 'is not an archive' <<< "$O"; then ok "a missing archive refused"; else bad "missing archive accepted"; fi

echo "== restore with NO current sink =="
restore '.env.state.stale-20260101-000000'
if [ "$R" = 0 ] && grep -q 'HUNTER2SECRET' "$VKS_STATE_FILE" && [ ! -e "$T/.env.state.stale-20260101-000000" ] \
   && [ "$(stat -c %a "$VKS_STATE_FILE")" = 600 ]; then ok "restored, 0600, archive moved in"
else bad "restore into an absent sink: rc=$R $O"; fi

echo "== restore over a CURRENT sink archives it first, and prints the undo =="
printf 'Y=other\n' > "$T/.env.state.stale-20260103-000000"
restore '.env.state.stale-20260103-000000'
undo="$(printf '%s' "$O" | grep -oE 'to undo: make state-restore ARCHIVE=[^ ]+' | head -1 | cut -d= -f2)"
if [ "$R" = 0 ] && grep -qx 'Y=other' "$VKS_STATE_FILE" && [ -n "$undo" ] && grep -q 'HUNTER2SECRET' "$T/$undo"; then ok "previous sink archived as ${undo}, undo printed"
else bad "restore over a sink: rc=$R undo='${undo}' $O"; fi
restore "$undo"
if [ "$R" = 0 ] && grep -q 'HUNTER2SECRET' "$VKS_STATE_FILE" && grep -rqx 'Y=other' "$T"/.env.state.stale-*; then ok "the undo restores it, and nothing was lost"
else bad "undo: rc=$R $O"; fi
left="$(find "$T" -maxdepth 1 -name '.env.state*' ! -type l | wc -l | tr -d ' ')"
if [ "$left" -ge 3 ]; then ok "no file was deleted (${left} state files)"; else bad "files lost: ${left}"; fi

echo "test-state-archives: ${checks} checks, rc=$rc"
exit "$rc"
