#!/usr/bin/env bash
# Every Photon image that has a NON-ROOT user + sudo must pin /etc/shadow to 0400 at build time,
# in the SAME RUN that asserts it, with NO package install after it.
#
# WHY (MEASURED 2026-08-23, two operating points each side). The discriminator is the tdnf
# TRANSACTION, not the base image and not the date:
#     photon:5.0 bare .................... no /etc/shadow at all
#     `shadow sudo` alone ................ 400
#     `shadow sudo` then `docker` LATER .. 400
#     `shadow sudo docker` in ONE tdnf ... 0000   <- reproduced twice
# At 0000, a `--privileged` container is AppArmor-UNCONFINED so the HOST's unix-chkpwd profile
# attaches by path, granting `capability audit_write` + `/etc/shadow r` and NOT dac_override ⇒
# setuid-root unix_chkpwd cannot open the file and `sudo -n true` returns 1. At 0400 root-owned it
# opens by OWNER and needs no capability. WITHOUT `--privileged` the same 0000 image sudo's FINE —
# so a re-test that drops the flag gets the WRONG answer.
#
# THREE THINGS THIS GATE LEARNED THE HARD WAY (adversary round, 2026-08-23):
#  1. ORDER IS THE MECHANISM. An earlier version asserted only that a chmod and an assertion both
#     EXISTED. It PASSED an image doing `chmod 0400` and THEN `tdnf install -y shadow` — which ships
#     broken. Coexistence is not coupling.
#  2. It reddened `chmod 400` (no leading zero) — the very spelling the FATAL message uses — plus
#     `&&`-chained, line-continued, quoted and symbolic forms. A gate that reddens a correct
#     reformat is a gate someone deletes.
#  3. Scope keyed on the FILENAME missed `Dockerfile.airgap` (photon-based, installs shadow+sudo,
#     runs USER vks). Scope is now derived from the HAZARD: a photon base AND a non-root user AND
#     sudo. Root-only images (bootstrap) never invoke unix_chkpwd and are correctly out of scope.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

shopt -s nullglob
candidates=(jumpbox/Dockerfile*)
(( ${#candidates[@]} )) || { echo "FATAL: no jumpbox/Dockerfile* found — has the layout moved?"; exit 1; }

in_scope=(); skipped=0
for f in "${candidates[@]}"; do
  # photon base, by FROM or by the ARG BASE default — never by filename.
  grep -qiE '^[[:space:]]*(FROM|ARG[[:space:]]+BASE=)[^#]*photon' "$f" || { skipped=$((skipped+1)); continue; }
  # the hazard needs a non-root user AND sudo; without both, unix_chkpwd is never invoked.
  if ! grep -qE '^[[:space:]]*(RUN[^#]*useradd|USER[[:space:]]+[^r])' "$f"; then
    skipped=$((skipped+1)); continue
  fi
  if ! grep -qE 'sudo' "$f"; then
    skipped=$((skipped+1)); continue
  fi
  in_scope+=("$f")
done

fail=0
for f in "${in_scope[@]}"; do
  # Fold `\`-continuations so a RUN is ONE logical line, then number them.
  folded=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$f")

  # The chmod and the stat-assertion must be in the SAME logical line. Accept 400/0400, quoted or not.
  coupled=$(printf '%s\n' "$folded" \
    | grep -nE 'chmod[[:space:]]+(0?400|u=r,go=)[[:space:]]+"?/etc/shadow' \
    | grep -E 'stat[[:space:]]+-c[[:space:]]+%a[^|]*/etc/shadow' || true)

  if [ -z "$coupled" ]; then
    printf '  FAIL  %s — no RUN that BOTH chmods /etc/shadow to 0400 AND asserts it via stat -c %%a\n' "$f"
    fail=1; continue
  fi

  # ORDER: nothing may install packages after the contract, or the mode is reset.
  ln=${coupled%%:*}
  after=$(printf '%s\n' "$folded" | tail -n "+$((ln+1))" \
    | grep -cE '(tdnf|apt-get|apt|yum|dnf|zypper)[[:space:]]+[^|]*install' || true)
  if [ "$after" -gt 0 ]; then
    printf '  FAIL  %s — %s package install(s) AFTER the contract at logical line %s; the mode is reset\n' "$f" "$after" "$ln"
    fail=1; continue
  fi
  printf '  OK    %s (contract at logical line %s, no install after)\n' "$f" "$ln"
done

# F5: on a FAILING run, printing "N skipped" beside N FAILs reads as "everything was skipped".
# Say OUT OF SCOPE (a classification) rather than skipped (which sounds like work not done).
printf 'check-jumpbox-shadow: %d in scope, %d out of scope (not photon, or root-only/no-sudo)\n' \
  "${#in_scope[@]}" "$skipped"
(( ${#in_scope[@]} )) || { echo "FATAL: ZERO files in scope — the hazard detector matched nothing, which is a gate that cannot fail."; exit 1; }
[ "$fail" -eq 0 ] || { echo "FATAL: a Photon jump-box image does not pin /etc/shadow correctly."; exit 1; }
