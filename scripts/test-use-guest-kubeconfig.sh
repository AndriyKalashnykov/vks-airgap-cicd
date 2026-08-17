#!/usr/bin/env bash
# test-use-guest-kubeconfig.sh — the GUEST selector triple is published all-or-nothing.
#
# WHY THIS EXISTS. `27-use-guest-kubeconfig.sh` had ZERO coverage. It publishes three keys that are
# only meaningful TOGETHER — KUBECONFIG, VKS_CONTEXT, VKS_AUTH_METHOD — and B138's implementation
# round MEASURED a regression in the obvious fix: one `env_publish` per key means key #1 can abort
# under `set -e`, leaving #2 and #3 unwritten. `VKS_AUTH_METHOD` then stays `vcf` — the "stop talking
# to the Supervisor" switch that the ORIGINAL code did flip — while `.env` already reads
# `KUBECONFIG=<guest>`, so an operator inspecting the file believes the switch happened.
#
# Case A is the RED-proof for exactly that. It must FAIL on a per-key implementation and PASS on the
# two-phase one. Case B is the positive control: without it, case A passes for the trivial reason
# that nothing works at all.
#
# Offline: `kubectl` only reads a synthetic kubeconfig (no cluster is contacted).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

command -v kubectl >/dev/null 2>&1 || { echo "  SKIP  kubectl not on PATH"; echo "test-use-guest-kubeconfig: skipped"; exit 0; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT

# A sandbox that is a REPO_ROOT: the real script, the real libs, the real .env.example.
setup() {  # setup [<extra .env.kind line>]
  rm -rf "${TD:?}/repo"; mkdir -p "$TD/repo/scripts/lib" "$TD/repo/secrets"
  cp "$ROOT/scripts/27-use-guest-kubeconfig.sh" "$TD/repo/scripts/"
  cp "$ROOT"/scripts/lib/os.sh "$ROOT"/scripts/lib/state.sh "$TD/repo/scripts/lib/"
  cp "$ROOT/.env.example" "$TD/repo/.env.example"
  # A real kubeconfig, so the script's `kubectl config current-context` genuinely resolves.
  cat > "$TD/repo/secrets/gc1.kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: gc1, cluster: {server: https://10.0.0.1:6443}}]
users: [{name: gc1-admin, user: {token: x}}]
contexts: [{name: gc1-admin@gc1, context: {cluster: gc1, user: gc1-admin}}]
current-context: gc1-admin@gc1
KC
  # §3's state: talking to the SUPERVISOR.
  printf 'VKS_CLUSTER_NAME=gc1\nVKS_AUTH_METHOD=vcf\nVKS_CONTEXT=sup-ctx\n' > "$TD/repo/.env"
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$TD/repo/.env.kind"
  return 0
}

# The EFFECTIVE triple, read the way every consumer reads it — through load_env.
eff() { ( cd "$TD/repo" && REPO_ROOT="$TD/repo" bash -c '
  . scripts/lib/os.sh >/dev/null 2>&1
  load_env >/dev/null 2>&1
  printf "%s|%s|%s" "${KUBECONFIG:-}" "${VKS_CONTEXT:-}" "${VKS_AUTH_METHOD:-}"' ); }

run27() { ( cd "$TD/repo" && REPO_ROOT="$TD/repo" bash scripts/27-use-guest-kubeconfig.sh ) >/dev/null 2>&1; }

echo "27-use-guest-kubeconfig — the selector triple moves together"

# ── B (positive control) — a clean tree: all three take effect. ─────────────────────────────────
setup
run27; rc_b=$?
got_b="$(eff)"
if [ "$rc_b" -eq 0 ] && [ "$got_b" = "${TD}/repo/secrets/gc1.kubeconfig|gc1-admin@gc1|kubeconfig" ]; then
  ok "clean tree: rc 0 and all three effective [$got_b]"
else
  bad "clean tree: rc=$rc_b, got [$got_b]"
fi

# ── A (THE RED) — a legacy .env.kind pins KUBECONFIG, which load_env sources LAST. ──────────────
# The publish cannot win, so the script MUST fail. What it must NOT do is fail HALFWAY: with one
# env_publish per key, KUBECONFIG aborts first and VKS_AUTH_METHOD is never written, stranding 'vcf'.
setup 'KUBECONFIG=/LEGACY/wins.kubeconfig'
run27; rc_a=$?
got_a="$(eff)"
if [ "$rc_a" -ne 0 ]; then
  ok "legacy .env.kind: refuses (rc=$rc_a) rather than reporting a write that did not take effect"
else
  bad "legacy .env.kind: rc=0 — it claimed success while /LEGACY still wins"
fi
# The discriminator. Read the THIRD field: 'kubeconfig' = the triple moved; 'vcf' = stranded.
case "$got_a" in
  *'|kubeconfig') ok "VKS_AUTH_METHOD still flipped to kubeconfig despite the failure — no half-superseded triple" ;;
  *'|vcf')        bad "VKS_AUTH_METHOD STRANDED on 'vcf' — the abort left a half-superseded triple [$got_a]" ;;
  *)              bad "unexpected VKS_AUTH_METHOD in [$got_a]" ;;
esac
# And .env itself must show the later keys SUPERSEDED, not just the one written before an abort.
# ⚠️ NOT a count of the three keys: setup() already writes VKS_AUTH_METHOD and VKS_CONTEXT, so
# `grep -c` returns 3/3 on BOTH implementations — MEASURED, it passed on the refuted per-key form too.
# A count that cannot tell "the script wrote it" from "setup put it there" discriminates nothing, and
# a passing assertion that cannot fail is worse than no assertion. Assert the VALUES instead.
_env_auth="$(grep -E '^VKS_AUTH_METHOD=' "$TD/repo/.env" 2>/dev/null | tail -1 || true)"
_env_ctx="$(grep -E '^VKS_CONTEXT='     "$TD/repo/.env" 2>/dev/null | tail -1 || true)"
case "${_env_auth}|${_env_ctx}" in
  *kubeconfig*\|*gc1-admin@gc1*) ok ".env shows the later keys superseded (${_env_auth}, ${_env_ctx}) — all-or-nothing" ;;
  *) bad ".env kept a pre-supersession value — a partial write [${_env_auth} / ${_env_ctx}]" ;;
esac

echo
if [ "$fail" -eq 0 ]; then echo "test-use-guest-kubeconfig: ${pass} passed, 0 failed"; exit 0; fi
echo "test-use-guest-kubeconfig: ${pass} passed, ${fail} FAILED"; exit 1
