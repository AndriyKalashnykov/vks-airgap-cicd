#!/usr/bin/env bash
# test-argocd-version.sh — offline RED proofs for lib/argocd.sh:argocd_print_versions (the read-only
# version peek behind `make argocd-version`). No cluster. Proves:
#   (a) both kubeconfigs unset -> UNAVAILABLE + exit 0, and kubectl is NEVER invoked (so it can never
#       fall through to ~/.kube/config and print an UNRELATED cluster's server). A call-counter shim,
#       asserted to ZERO — rc 0 + the string alone would NOT prove the non-dial guarantee.
#   (b) under `set -euo pipefail` with a kubectl that FAILS every call -> STILL exit 0 (the info-utility
#       contract): the `| sed || true` / `$(... || true)` guards must hold even under a strict caller.
#   (c) a kubeconfig path that does NOT exist -> UNAVAILABLE 'not found', exit 0, kubectl never called.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "$HERE/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "$HERE/lib/argocd.sh"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# A kubectl shim that COUNTS every invocation (to prove the non-dial guarantee) and FAILS (to prove the
# set -e safety). It is first on PATH, so `have kubectl` is true and the function proceeds to its
# kubeconfig checks — exactly the path we want to exercise.
SHIM="$(mktemp -d)"; CNT="$SHIM/calls"; : > "$CNT"
cat > "$SHIM/kubectl" <<EOF
#!/usr/bin/env bash
echo x >> "$CNT"
exit 1
EOF
chmod +x "$SHIM/kubectl"
export PATH="$SHIM:$PATH"

# (a) both kubeconfigs unset -> UNAVAILABLE, rc 0, kubectl NEVER called.
: > "$CNT"
out="$(argocd_print_versions "" argocd 2>&1)"; rc=$?
calls="$(wc -l < "$CNT" | tr -d ' ')"
if [ "$rc" = 0 ]; then ok "(a) no kubeconfig -> exit 0"; else bad "(a) exit $rc, want 0"; fi
if printf '%s' "$out" | grep -q UNAVAILABLE; then ok "(a) no kubeconfig -> UNAVAILABLE"; else bad "(a) missing UNAVAILABLE"; fi
if [ "$calls" = 0 ]; then ok "(a) no kubeconfig -> kubectl NEVER called (count=$calls)"; else bad "(a) kubectl called $calls time(s) — it dialed a default cluster!"; fi

# (b) kubeconfig FILE exists + kubectl fails every call, run under set -euo pipefail -> still exit 0.
KC="$SHIM/kc"; echo 'apiVersion: v1' > "$KC"; : > "$CNT"
( set -euo pipefail; argocd_print_versions "$KC" argocd 1s >/dev/null 2>&1 ); rc=$?
if [ "$rc" = 0 ]; then ok "(b) failing kubectl under set -e -> still exit 0"; else bad "(b) exit $rc, want 0 — a bare pipeline broke the exit-0 contract"; fi

# (c) kc points at a NON-existent file -> UNAVAILABLE 'not found', rc 0, kubectl never called.
: > "$CNT"
out="$(argocd_print_versions "$SHIM/does-not-exist" argocd 2>&1)"; rc=$?
calls="$(wc -l < "$CNT" | tr -d ' ')"
if [ "$rc" = 0 ] && [ "$calls" = 0 ] && printf '%s' "$out" | grep -qi 'not found'; then
  ok "(c) missing kubeconfig file -> UNAVAILABLE, exit 0, no dial"
else
  bad "(c) rc=$rc calls=$calls"
fi

rm -rf "$SHIM"
if [ "$fail" = 0 ]; then echo "test-argocd-version: OK"; exit 0; fi
echo "test-argocd-version: FAILED" >&2; exit 1
