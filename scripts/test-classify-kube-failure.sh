#!/usr/bin/env bash
# scripts/test-classify-kube-failure.sh — classify_kube_failure's arms, pinned.
#
# WHY THIS EXISTS. This function decides WHICH CAUSE the operator is told about, and its arm ORDER
# is part of its contract: first match wins, so an arm that can match another class's text SHADOWS
# every arm below it. lib/os.sh records two such incidents in comments (UNAUTHORIZED once sat above
# FORBIDDEN and swallowed it; an unanchored `401` matched a byte offset in unrelated output). It had
# NO test, so every one of those orderings was held in place by prose alone.
#
# ⚠️ IT TAKES A FILE PATH, NOT A MESSAGE STRING. `classify_kube_failure "$some_string"` returns
# UNKNOWN for everything, because the string is not a readable file. That cost a wrong diagnosis
# while writing these tests: the harness reported UNKNOWN for six known-good inputs and the obvious
# conclusion ("my change broke it") was wrong — the harness was.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

pass=0; fail=0
t() { # t <expected> <stderr-text>
  local f got; f="$(mktemp)"; printf '%s' "$2" > "$f"
  got="$(classify_kube_failure "$f")"; rm -f "$f"
  if [ "$got" = "$1" ]; then echo "  PASS  ${1}"; pass=$((pass+1))
  else echo "  FAIL  want ${1}, got ${got}"; echo "        input: $2"; fail=$((fail+1)); fi
}

echo "classify_kube_failure — one cause per message"

# KUBECONFIG_UNUSABLE — NOTHING WAS DIALLED, so this must never be reported as a reachability
# verdict. MEASURED against a genuinely down lab: a missing kubeconfig fell through to UNKNOWN and
# argocd-preflight rendered it as "the GUEST cluster did not answer" — a claim about the network
# from an error about the filesystem.
t KUBECONFIG_UNUSABLE "error: stat /x/kc.kubeconfig: no such file or directory"
# ...and the four causes that are NOT a missing kubeconfig, which is why the class is named
# "unusable" rather than "missing" and the operator message prints the error verbatim.
t KUBECONFIG_UNUSABLE "error: unable to read certificate-authority /gone.crt: no such file or directory"
t KUBECONFIG_UNUSABLE "* unable to read client-cert /gone.crt"
t KUBECONFIG_UNUSABLE "Unable to connect to the server: getting credentials: exec: fork/exec /x/plugin: no such file or directory"
t KUBECONFIG_UNUSABLE 'error: error loading config file "/x": yaml: line 3: mapping values are not allowed'

# ⚠️ THE SHADOWING CASES. The arm sits FIRST (a config fault precedes any dial), so a pattern as
# broad as a bare `no such file or directory` swallows the auth classes below whenever a message
# carries both phrases. MEASURED: both of these classified KUBECONFIG_UNUSABLE before the patterns
# were anchored on kubectl's config vocabulary.
t FORBIDDEN    "Error from server (Forbidden): namespaces is forbidden; open /gone: no such file or directory"
t UNAUTHORIZED "error: You must be logged in to the server; open /gone: no such file or directory"

# UNREACHABLE — the negative control for the narrowing above: `no such host` must stay a network
# verdict. Without this case the narrowing has no guard. The third form is kubectl's own
# format-string, which contains NEITHER "connection refused" NOR "dial tcp".
t UNREACHABLE "Unable to connect to the server: dial tcp: lookup api.lab: no such host"
t UNREACHABLE "Unable to connect to the server: dial tcp 192.0.2.1:6443: i/o timeout"
t UNREACHABLE "The connection to the server 10.0.0.1:6443 was refused - did you specify the right host or port?"

# STALE_CA — the server ANSWERED, so every remedy differs from UNREACHABLE.
t STALE_CA "Unable to connect to the server: x509: certificate signed by unknown authority"
t PLAINTEXT "error: server gave HTTP response to HTTPS client"

# UNAUTHORIZED vs FORBIDDEN, unmixed — the ordering incident lib/os.sh records. One says
# re-authenticate, the other says ask for RBAC; sending an operator to re-authenticate a working
# credential is a dead end.
t UNAUTHORIZED "error: You must be logged in to the server (Unauthorized)"
t FORBIDDEN    'Error from server (Forbidden): applications.argoproj.io is forbidden: User "x" cannot list resource'

# UNKNOWN is a real verdict, not a bucket: an unrecognised error is printed verbatim rather than
# guessed at, so this pins that we still HAVE an unknown.
t UNKNOWN "Unable to connect to the server: EOF"

echo
echo "classify_kube_failure: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
