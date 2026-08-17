#!/usr/bin/env bash
# test-require-kind-target.sh — the KinD-only guard, RED-proven in both directions.
#
# WHY THIS EXISTS. `require_kind_target` (lib/tls.sh:233) is the fail-closed guard on the three
# scripts that would otherwise install Harbor/ArgoCD INTO whatever cluster the current context names,
# take one of its LoadBalancer addresses, repoint this repo's registry selector at it, and exit 0.
#
# It had ZERO committed coverage. B67 recorded a BY-HAND red-proof on 2026-08-17 ("refuses on
# kind-cc-guest"), and gates.md is explicit that a by-hand proof EXPIRES at the next commit touching
# the file or its toolchain. A B66 idea round then closed that row by leaning on this guard — which
# makes "the guard is untested" the obvious route to re-opening it. This closes that.
#
# Offline: `kubectl` is stubbed, so no cluster is contacted. `die` exits, so every case runs the
# guard in a SUBSHELL and reads its rc.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

pass=0; fail=0
# `not` is NOT a shell builtin. Without this, every negative case below dies "command not found" —
# which at least FAILS loudly rather than silently passing, but the assertion would be measuring
# nothing. Defined here rather than in os.sh: it is test vocabulary, not product vocabulary.
# shellcheck disable=SC2329  # invoked INDIRECTLY: `ck <label> not _guard ...` passes it as an arg.
not() { ! "$@"; }
ck() {  # ck <label> <predicate-command...>
  local label="$1"; shift
  if "$@"; then echo "  PASS  ${label}"; pass=$((pass+1))
  else echo "  FAIL  ${label}"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# stub kubectl: $STUB_CTX is the context it reports; STUB_CTX=__ERR__ makes it fail like a real
# kubectl with no current-context (which is the fail-CLOSED case the guard's comment cites).
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = config ] && [ "$2" = current-context ]; then
  case "${STUB_CTX:-__ERR__}" in
    __ERR__) echo "error: current-context is not set" >&2; exit 1 ;;
    *)       printf '%s\n' "$STUB_CTX" ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"

# run the guard in a subshell; print rc so a `die` (exit) is observable
# shellcheck disable=SC2329  # invoked INDIRECTLY via `ck`/`not`, which shellcheck cannot trace.
_guard() {  # _guard <ctx-or-__ERR__> [cluster-name-override]
  ( export STUB_CTX="$1"
    # NOT `A && B || C` — that is not if-then-else (C runs when A is true and B fails), and this
    # repo's own rules forbid it. Here it would silently export the WRONG cluster name.
    if [ "${2-unset}" = unset ]; then export KIND_CLUSTER_NAME="vks-demo"
    else                              export KIND_CLUSTER_NAME="$2"; fi
    require_kind_target "the-step" >/dev/null 2>&1 )
}

echo "require_kind_target — the KinD-only guard"

# GREEN: the context IS this repo's KinD cluster.
ck "ACCEPTS the matching context (kind-vks-demo)"            _guard "kind-vks-demo"

# 🔴 THE RED. B67's by-hand proof used exactly this context; it is now a committed case.
ck "REFUSES a DIFFERENT kind cluster (kind-cc-guest)"    not _guard "kind-cc-guest"
ck "REFUSES a real-lab context (a Supervisor)"           not _guard "vks-supervisor-admin@vsphere"
ck "REFUSES a look-alike WITHOUT the kind- prefix"       not _guard "vks-demo"

# FAIL-CLOSED: the guard's own comment claims an unset/empty/no-context state refuses. Pin it —
# this is the arm that decides whether an operator with a half-configured shell gets protected.
ck "FAILS CLOSED when kubectl has no current-context"    not _guard "__ERR__"
ck "FAILS CLOSED on an EMPTY context string"             not _guard ""

# The `:?` on KIND_CLUSTER_NAME: with no cluster name there is nothing to compare against, so it must
# refuse rather than compare against the literal 'kind-'.
ck "REFUSES when KIND_CLUSTER_NAME is empty"             not _guard "kind-" ""

echo
echo "call sites — the guard must not be silently dropped"
# Keyed on the CALL, not the name: the name appears in comments (91-e2e-tenant-mechanism.sh:42).
for f in 06-install-harbor.sh 07-install-argocd.sh 91-e2e-tenant-mechanism.sh; do
  n="$(sed 's/#.*//' "${SCRIPT_DIR}/${f}" | grep -c '^require_kind_target ' || true)"
  ck "${f} still CALLS the guard (${n})" test "$n" -ge 1
done

echo
if [ "$fail" -eq 0 ]; then echo "test-require-kind-target: ${pass} passed, 0 failed"; exit 0; fi
echo "test-require-kind-target: ${pass} passed, ${fail} FAILED"; exit 1
