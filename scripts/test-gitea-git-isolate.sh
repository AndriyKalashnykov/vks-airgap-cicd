#!/usr/bin/env bash
# test-gitea-git-isolate.sh — gitea_git_isolate must make a temp clone use ONLY our store file.
#
# A HOSTILE global config stands in for the operator's: an unscoped spy helper (their osxkeychain /
# libsecret), a url-scoped spy, credential.useHttpPath=true (common with GCM) and credential.username=bob.
# The spy answers `get` with a STALE credential and logs every call. Isolated: `fill` must return OUR
# user and token, `approve` must not reach the spy (that is the keychain leak). CONTROL: the same clone
# WITHOUT the isolation must return the stale value, or the test measures nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

# GIT_CONFIG_GLOBAL needs git >= 2.32. On an older git it is ignored, the REAL global config applies,
# and the control `approve` below would hand the fake token to the operator's real keychain. Refuse.
_gv="$(git --version | awk '{print $3}')"
if [ "$(printf '%s\n2.32\n' "$_gv" | sort -V | head -1)" != 2.32 ]; then
  echo "test-gitea-git-isolate: SKIP — git ${_gv} < 2.32 cannot isolate this test from your real config"; exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

cat > "$T/spy" <<EOF
#!/bin/sh
echo "\$1" >> "$T/spy.log"
[ "\$1" = get ] && printf 'username=stale\npassword=STALEPW\n'
exit 0
EOF
chmod +x "$T/spy"
cat > "$T/global" <<EOF
[credential]
	helper = $T/spy
	useHttpPath = true
	username = bob
[credential "http://localhost:3999"]
	helper = $T/spy
	username = bob
[credential "http://localhost:3999/demo"]
	useHttpPath = true
EOF
( umask 077; printf 'http://admin:REALTOKEN@localhost:3999\n' > "$T/creds" )

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/global" GIT_TERMINAL_PROMPT=0
query() { printf 'protocol=http\nhost=localhost:3999\npath=demo/app.git\n\n'; }

mkclone() { rm -rf "$1"; git init -q "$1"; git -C "$1" config --add credential.helper "store --file=$T/creds"; }

echo "== CONTROL: without isolation the inherited helper wins =="
mkclone "$T/c0"; : > "$T/spy.log"
out="$(query | git -C "$T/c0" credential fill 2>&1)"
if printf '%s' "$out" | grep -q 'password=STALEPW'; then ok "control: the stale inherited credential is returned"
else bad "control: expected the stale credential, got: $out"; fi

echo "== ISOLATED: our store file, and only it =="
rm -rf "$T/c1"; git init -q "$T/c1"; gitea_git_isolate "$T/c1" "$T/creds" admin; : > "$T/spy.log"
out="$(query | git -C "$T/c1" credential fill 2>&1)"; frc=$?
if [ "$frc" = 0 ] && printf '%s' "$out" | grep -q 'username=admin' && printf '%s' "$out" | grep -q 'password=REALTOKEN'
then ok "fill returns our user and token"; else bad "fill (rc=$frc): $out"; fi
if [ -s "$T/spy.log" ]; then bad "the inherited helper was consulted on get: $(tr '\n' ' ' < "$T/spy.log")"
else ok "the inherited helper is never asked (get)"; fi

printf 'protocol=http\nhost=localhost:3999\nusername=admin\npassword=REALTOKEN\n\n' | git -C "$T/c1" credential approve
if [ -s "$T/spy.log" ]; then bad "the token reached the inherited helper on approve (the keychain leak)"
else ok "approve does not reach the inherited helper"; fi

echo "== the same approve WITHOUT isolation does reach it (control for the line above) =="
: > "$T/spy.log"
printf 'protocol=http\nhost=localhost:3999\nusername=admin\npassword=REALTOKEN\n\n' | git -C "$T/c0" credential approve
if grep -q store "$T/spy.log"; then ok "control: approve fans out to the inherited helper"
else bad "control: approve never reached the spy, so the isolated check above proves nothing"; fi

echo "== env-injected config beats LOCAL: the scripts must unset it (they do; this proves why) =="
: > "$T/spy.log"
printf 'protocol=http\nhost=localhost:3999\nusername=admin\npassword=REALTOKEN\n\n' \
  | GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0="$T/spy" git -C "$T/c1" credential approve
if grep -q store "$T/spy.log"; then ok "control: an injected helper still receives the token even after isolation"
else bad "control: the injected helper was not reached, so the unset in the scripts is untested"; fi
for f in 50-seed-gitea-repos.sh 75-build-apps.sh 99-verify.sh; do
  if grep -q '^unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS' "$SCRIPT_DIR/$f"; then ok "$f unsets env-injected git config"
  else bad "$f does not unset GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS"; fi
done

echo "test-gitea-git-isolate: ${checks} checks, rc=$rc"
exit "$rc"
