#!/usr/bin/env bash
# test-vks-username.sh — vks_username() (lib/os.sh) resolves the effective VKS SSO principal.
#
# WHY THIS EXISTS, AND WHY IT IS A TEST AND NOT A GATE
# ----------------------------------------------------
# `.env.example` documents VKS_USERNAME as OPTIONAL-with-a-default. That claim was FALSE once
# already: the default lived as a local assignment inside 30-vks-login.sh's `vcf` case, while
# 31-fetch-argocd-kubeconfig.sh kept an unconditional `: "${VKS_USERNAME:?}"`. So the doc was right
# for `make vks-login` and wrong for `make fetch-argocd-kubeconfig`, which Scenario 1 runs regardless
# of VKS_AUTH_METHOD.
#
# A grep-style gate for that contradiction was BUILT AND REFUTED (measured: identical verdict on the
# defective and the fixed tree — zero discrimination; plus it could not see per-branch requirements,
# and its remedies all degraded something). The mechanical control that DOES discriminate is this:
# a unit test on the shared resolver. It goes red the moment a consumer stops sharing the default.
#
# Offline, pure-string, no network, no cluster.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

DEF="$(vks_username_default)"
case "$DEF" in *@*) ok "the default is fully qualified ($DEF)" ;; *) bad "default '$DEF' has no @SSO.DOMAIN" ;; esac

# 1. unset + no VKS_SSO_DOMAIN -> the announced default, verbatim.
out="$(env -u VKS_USERNAME -u VKS_SSO_DOMAIN bash -c '. scripts/lib/os.sh; vks_username' 2>/dev/null)"
if [ "$out" = "$DEF" ]; then ok "unset + no domain -> the default ($out)"; else bad "unset + no domain: got '$out', want '$DEF'"; fi

# 2. THE REGRESSION THIS FILE EXISTS FOR: unset + VKS_SSO_DOMAIN -> the operator's domain is HONOURED.
#    The first implementation printed the default and returned WITHOUT calling vks_sso_user, so the
#    one knob an operator sets to say "my lab's SSO domain differs" was SILENTLY DISCARDED — and they
#    then typed a real password against a principal from someone else's lab.
out="$(env -u VKS_USERNAME VKS_SSO_DOMAIN=MYLAB.SSO bash -c '. scripts/lib/os.sh; vks_username' 2>/dev/null)"
want="${DEF%%@*}@MYLAB.SSO"
if [ "$out" = "$want" ]; then ok "unset + VKS_SSO_DOMAIN -> domain honoured ($out)"; else bad "VKS_SSO_DOMAIN DISCARDED: got '$out', want '$want'"; fi

# 3. an explicit VKS_USERNAME beats both the default and VKS_SSO_DOMAIN (C10 idempotency).
out="$(env VKS_USERNAME=bob@X.SSO VKS_SSO_DOMAIN=MYLAB.SSO bash -c '. scripts/lib/os.sh; vks_username' 2>/dev/null)"
if [ "$out" = 'bob@X.SSO' ]; then ok "explicit qualified username wins ($out)"; else bad "got '$out', want bob@X.SSO"; fi

# 4. a BARE explicit username + domain -> joined (not double-domained).
out="$(env VKS_USERNAME=bob VKS_SSO_DOMAIN=MYLAB.SSO bash -c '. scripts/lib/os.sh; vks_username' 2>/dev/null)"
if [ "$out" = 'bob@MYLAB.SSO' ]; then ok "bare username + domain -> $out"; else bad "got '$out', want bob@MYLAB.SSO"; fi

# 5. a BARE explicit username with NO domain still DIES (the C10 guard must not be bypassed).
if ( env VKS_USERNAME=bob -u VKS_SSO_DOMAIN bash -c '. scripts/lib/os.sh; vks_username' ) >/dev/null 2>&1; then
  bad "bare username with no domain did NOT die (a silent default is the C10 failure class)"
else
  ok "bare username with no domain dies"
fi

# 6. the default is NOT overridable by a sourced KEY=value (it is a function, not a variable).
#    As a plain assignment it WAS overridable from .env — load_env sources that with `set -a` AFTER
#    this lib — i.e. an undocumented knob steering a security principal.
out="$(env -u VKS_USERNAME bash -c 'VKS_USERNAME_DEFAULT=evil@attacker.sso; . scripts/lib/os.sh; vks_username' 2>/dev/null)"
if [ "$out" = "$DEF" ]; then ok "the default cannot be overridden by a sourced assignment"; else bad "default was overridden: got '$out'"; fi

# 7. the WARN must not contaminate the captured value (callers do user="$(vks_username)").
out="$(env -u VKS_USERNAME -u VKS_SSO_DOMAIN bash -c '. scripts/lib/os.sh; vks_username' 2>/dev/null)"
case "$out" in *level=WARN*|*msg=*) bad "log output leaked into the captured value: '$out'" ;; *) ok "warn goes to stderr; capture is clean" ;; esac

# 8. BOTH consumers must call the shared resolver — that is the whole contract. A consumer that
#    reverts to its own `:?` or its own default re-creates the original bug.
for f in scripts/30-vks-login.sh scripts/31-fetch-argocd-kubeconfig.sh; do
  if grep -qF 'vks_username' "$f"; then ok "$(basename "$f") uses the shared resolver"; else bad "$(basename "$f") no longer calls vks_username — the default is not shared"; fi
  # SC2016 disabled deliberately: this is a FIXED STRING to search for (`grep -F`), not an expression
  # to expand. Double-quoting it would make the shell substitute VKS_USERNAME and search for its value.
  # shellcheck disable=SC2016
  if grep -qF ': "${VKS_USERNAME:?' "$f" && ! grep -qF 'vsphere)' "$f"; then bad "$(basename "$f") hard-requires VKS_USERNAME while .env.example calls it optional"; fi
done

if [ "$fail" -eq 0 ]; then echo "test-vks-username: OK"; else echo "test-vks-username: FAILED"; exit 1; fi
