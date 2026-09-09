#!/usr/bin/env bash
# ci-tier: fast
# Offline RED/GREEN for 28-harbor-admin-password.sh's ROBOT guard (B557).
#
# THE BUG, measured 2026-09-09. The robot refusal lived INSIDE `if ! is_placeholder "$HARBOR_PASSWORD"`,
# and `is_placeholder ''` returns TRUE -- '' is the FIRST pattern in its case (lib/os.sh:1204). So:
#
#     HARBOR_USERNAME=robot$vks-cicd  +  HARBOR_PASSWORD=   ->  guard SKIPPED
#                                                           ->  env_publish_all ... HARBOR_USERNAME admin
#
# i.e. a least-privilege pipeline identity was silently replaced by a FULL ADMIN credential -- the
# exact harm the guard's own die() message promises cannot occur. There was exactly ONE
# `harbor_username_is_robot` call in the file, so no second net existed.
#
# THE HALF-PAIR STATE IS DOCUMENTED, NOT EXOTIC: 28-harbor-admin-password.sh:250-252 records that a
# mid-pair abort "leaves the overlay holding HALF a credential pair, so the documented recovery
# (`make harbor-admin-password`) has the same structure". The operator most likely to run this
# command is the one most likely to be in the state that bypassed the guard.
#
# ⚠️ BOTH DIRECTIONS ARE ASSERTED. A guard that refuses a NON-robot username with an empty password
# would break the command's whole purpose (replacing a forgotten admin password), so the control
# cases below matter as much as the REDs.
#
# Sandboxed REPO_ROOT: a regression would write to $T/.env, never the operator's.
#
# ⚠️ WHAT THE `NO admin published` ASSERTIONS DO **NOT** PROVE, stated because a green is otherwise
# over-readable. MEASURED by removing the hoisted guard: the four REFUSES assertions go RED and all
# three `NO admin published` assertions stay GREEN -- because without a reachable Supervisor the
# script dies reading the admin secret, long before `env_publish_all`. So offline they cannot
# discriminate today, and they are NOT evidence that the downgrade is contained. They are kept as a
# CONTAINMENT tripwire for the regression where the publish moves ahead of the Supervisor read.
# The downgrade itself is provable only against a live Supervisor; the guard is what this file
# proves, and the guard is what stops it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'apiVersion: v1\n' > "$T/kubeconfig"
: > "$T/.env.example"

run() {  # run <username> <password> -> stdout+stderr, newlines squashed
  printf '' > "$T/.env"
  HARBOR_USERNAME="$1" HARBOR_PASSWORD="$2" \
  REPO_ROOT="$T" SKIP_DOTENV=1 KUBECONFIG="$T/kubeconfig" \
  VKS_SUPERVISOR_KUBECONFIG="/nonexistent/sup.kubeconfig" \
  HARBOR_URL="harbor.example.invalid" \
    bash "$SCRIPT_DIR/28-harbor-admin-password.sh" 2>&1 | tr '\n' ' '
}
# ⚠️ `grep -c` PRINTS 0 **AND EXITS 1** on no-match, so the obvious `|| echo 0` fires as well and
# the helper returns TWO lines ("0\n0") -- which fails every comparison against "0" and reads like
# the guard leaked. Measured while writing this file. Capture, absorb the rc, default the empty
# (missing-file) case.
leaked() { local n; n="$(grep -c '^HARBOR_USERNAME=admin' "$T/.env" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

# ---- 1. THE RED. robot + EMPTY password: the state that bypassed every guard. ------------------
out="$(run 'robot$vks-cicd' '')"
ck "robot + empty   -> REFUSES"            "$(printf '%s' "$out" | grep -c 'is a ROBOT account')" "1"
ck "robot + empty   -> says WHY (no check)" "$(printf '%s' "$out" | grep -c 'nothing here can check that robot')" "1"
ck "robot + empty   -> names the remedy"   "$(printf '%s' "$out" | grep -c 'make harbor-robot')" "1"
ck "robot + empty   -> NO admin published" "$(leaked)" "0"

# ---- 2. the same hole via the LITERAL placeholder .env.example ships. --------------------------
out="$(run 'robot$vks-cicd' '<SET-IN-.env>')"
ck "robot + <SET-IN-.env> -> REFUSES"      "$(printf '%s' "$out" | grep -c 'is a ROBOT account')" "1"
ck "robot + <SET-IN-.env> -> NO admin"     "$(leaked)" "0"

# ---- 3. CONTROL, and it is the one that matters: a NON-robot username with an empty password is
#         the command's ENTIRE PURPOSE (recovering a forgotten admin password). It must NOT be
#         refused by the new guard. It will fail later for want of a Supervisor -- that is fine and
#         is a different message.
out="$(run 'admin' '')"
ck "admin + empty   -> NOT refused as robot" "$(printf '%s' "$out" | grep -c 'is a ROBOT account')" "0"

# ---- 4. CONTROL: a robot with a REAL password still reaches the ORIGINAL guard, whose message
#         carries the verdict. Asserting the verdict text proves it took the in-block path, not the
#         new one -- otherwise this case would pass on the hoisted guard and prove nothing.
out="$(run 'robot$vks-cicd' 'a-real-32-character-password-here')"
ck "robot + real pw -> still REFUSES"      "$(printf '%s' "$out" | grep -c 'is a ROBOT account')" "1"
ck "robot + real pw -> via the VERDICT arm" "$(printf '%s' "$out" | grep -c 'Verdict for the credential')" "1"
ck "robot + real pw -> NO admin published" "$(leaked)" "0"

printf '\n  %s passed, %s failed\n' "$p" "$f"
[ "$f" -eq 0 ] || exit 1
