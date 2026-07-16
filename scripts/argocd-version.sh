#!/usr/bin/env bash
# argocd-version.sh — READ-ONLY: print the ArgoCD CLI / running-server / repo-pin versions. Never gates,
# exits 0 always. The version-curious sibling of `make argocd-preflight` (the full install GATE, which
# hard-requires a kubeconfig and exits non-zero without a live cluster — the right behaviour for a gate,
# the wrong ergonomics for "what versions am I on?"). Un-numbered on purpose: it is an info utility like
# creds.sh, not a step in any install sequence. Reachable as `make argocd-version`.
#
# NOT `set -e`: an info utility must exit 0 even when the cluster is unreachable. The heavy lifting is in
# lib/argocd.sh:argocd_print_versions (self-contained, degrades gracefully, never dials a default cluster).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

echo "── ArgoCD version ──"
# ARGOCD_KUBECONFIG defaults to KUBECONFIG (ArgoCD-in-guest / KinD); both may legitimately be unset —
# the function then prints the CLI + pin and a loud UNAVAILABLE for the server, and still exits 0.
argocd_print_versions "${ARGOCD_KUBECONFIG:-${KUBECONFIG:-}}" "${ARGOCD_NAMESPACE:-argocd}"
exit 0
