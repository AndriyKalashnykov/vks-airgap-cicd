#!/usr/bin/env bash
# ============================================================================
# B570 — the legacy `.env.kind` sink must NOT be EXEMPT from state_check's cross-cluster refusal.
#
# THE BUG THIS PINS. `.env.state` carries a cluster stamp and state_check refuses it when the
# operator has explicitly selected a DIFFERENT cluster. `.env.kind` carries no stamp and was sourced
# UNCONDITIONALLY, and it is sourced LAST — so it WON. Measured A/B with a control: the refusal
# printed "NOT sourcing it — its LB IPs, CA paths and passwords belong to the other cluster" and the
# legacy file then handed over that other cluster's password anyway. The checked file was refused;
# the unchecked one was not. A control whose refusal is silently overridden is worse than no control,
# because it manufactures confidence.
#
# ⚠️ THE THREE ARMS ARE THE WHOLE POINT — arm 3 is what makes this a fix and not a regression.
#   1 CONTROL      mismatch, NO legacy      -> secret ABSENT   (the refusal already worked here)
#   2 TREATMENT    mismatch, WITH legacy    -> secret ABSENT   (this is the arm that used to leak)
#   3 BACK-COMPAT  no state file at all     -> secret PRESENT  (gating on _VKS_STATE_SOURCED instead
#                                                               of a MISMATCH-specific flag destroys
#                                                               this: state_check also returns 1 when
#                                                               the file is merely ABSENT, and the
#                                                               legacy sink may hold the ONLY copy of
#                                                               a generated password)
# Without arm 3 the "fix" passes arms 1-2 while losing operator data.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib"
cp "$REPO"/scripts/lib/*.sh "$T/scripts/lib/"
cp "$REPO"/.env.example "$T/.env.example"

# two kubeconfigs naming DIFFERENT servers — the only thing that can contradict the stamp
mk_kc() { printf 'apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: %s\n  name: c\ncontexts:\n- context:\n    cluster: c\n    user: u\n  name: x\ncurrent-context: x\nusers:\n- name: u\n  user: {}\n' "$2" > "$1"; }
mk_kc "$T/A.kubeconfig" "https://10.0.0.A1:6443"
mk_kc "$T/B.kubeconfig" "https://10.0.0.B1:6443"

# run load_env under an EXPLICIT selection of cluster B, and print the secret that only cluster A set
probe() {
  ( cd "$T" && REPO_ROOT="$T" VKS_STATE_FILE="$T/.env.state" SKIP_DOTENV=1 \
      KUBECONFIG="$T/B.kubeconfig" bash -c '
        . scripts/lib/os.sh
        load_env >/dev/null 2>&1
        printf "%s" "${B570_SECRET:-<EMPTY>}"
      ' 2>/dev/null )
}

echo "B570 — the legacy sink must obey state_check's refusal"

# ---- arm 1: CONTROL — mismatch, no legacy file. The refusal already worked here. ----------------
rm -f "$T/.env.state" "$T/.env.kind"
printf 'VKS_STATE_SERVER=https://10.0.0.A1:6443\nB570_SECRET=SECRET_OF_CLUSTER_A\n' > "$T/.env.state"
got="$(probe)"
if [ "$got" = "<EMPTY>" ]; then
  ok "CONTROL: a mismatched .env.state is refused (secret absent)"
else
  bad "CONTROL: the refusal itself is broken — got '$got'. Every other arm is meaningless until this passes."
fi

# ---- arm 2: TREATMENT — the same mismatch, plus the unstamped legacy sink. THE BUG. -------------
rm -f "$T/.env.state" "$T/.env.kind"
printf 'VKS_STATE_SERVER=https://10.0.0.A1:6443\nB570_SECRET=SECRET_OF_CLUSTER_A\n' > "$T/.env.state"
printf 'B570_SECRET=LEGACY_SECRET_OF_CLUSTER_A\n' > "$T/.env.kind"
got="$(probe)"
if [ "$got" = "<EMPTY>" ]; then
  ok "TREATMENT: the unstamped .env.kind is refused TOO (the bypass is closed)"
else
  bad "TREATMENT: the refusal was OVERRIDDEN by .env.kind — got '$got'. The operator selected
        cluster B, was told we declined to source cluster A's state, and received it anyway."
fi

# ---- arm 3: BACK-COMPAT — no state file at all. Must STILL be read. -----------------------------
# This is the arm that refutes the naive fix. state_check returns 1 for "file absent" as well as for
# "wrong cluster"; gating the legacy sourcing on _VKS_STATE_SOURCED would lose the only copy here.
rm -f "$T/.env.state" "$T/.env.kind"
printf 'B570_SECRET=ONLY_COPY_OF_THIS\n' > "$T/.env.kind"
got="$(probe)"
if [ "$got" = "ONLY_COPY_OF_THIS" ]; then
  ok "BACK-COMPAT: with no state file the legacy sink is STILL read (no data loss)"
else
  bad "BACK-COMPAT: the legacy sink was refused when there was no mismatch — got '$got'. This is the
        naive _VKS_STATE_SOURCED fix, and it destroys the operator's only copy of a generated value."
fi

# ---- arm 4: the ORDINARY path is unchanged — legacy still wins when there is no mismatch --------
rm -f "$T/.env.state" "$T/.env.kind"
printf 'VKS_STATE_SERVER=https://10.0.0.B1:6443\nB570_SECRET=FROM_STATE\n' > "$T/.env.state"
printf 'B570_SECRET=FROM_LEGACY\n' > "$T/.env.kind"
got="$(probe)"
if [ "$got" = "FROM_LEGACY" ]; then
  ok "ORDINARY: with a MATCHING stamp the legacy sink still wins (precedence contract intact)"
else
  bad "ORDINARY: the documented precedence changed — expected FROM_LEGACY, got '$got'. This fix must
        not re-order the sinks; test-env-precedence.sh pins .env.kind > .env.state at the make layer."
fi

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
