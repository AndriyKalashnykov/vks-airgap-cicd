#!/usr/bin/env bash
# test-vks-discover-namespace.sh — vks_discover_namespace() (lib/os.sh) resolves VKS_NAMESPACE from
# `vcf context list` when the operator did not pin one, and REFUSES to guess when it is ambiguous.
#
# WHY: 30-vks-login.sh used to hard-require VKS_NAMESPACE. The vcf CLI already exposes one context per
# namespace as '<ctx>:<namespace>' (lab-verified 2026-07-22), so the value is discoverable.
#
# THE CASE THAT MATTERS is the AMBIGUOUS one. A third-party automation of this same lab greps its
# context list and then `head -1`s the result — silently picking an arbitrary namespace. That is the
# "pick an arbitrary one" bug coding-style.md records. Here, >1 candidate must DIE and PRINT every
# candidate, mirroring istio_discover (lib/istio.sh:85-89). If that case ever starts returning a value,
# this test must go red.
#
# Offline: `vcf` is stubbed on PATH. The stub models the REAL argv (`vcf context list -o json`) — a
# stub that ignores its arguments would keep passing after the call site changes (testing.md).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

command -v jq >/dev/null 2>&1 || { echo "test-vks-discover-namespace: SKIP (jq not installed)"; exit 0; }

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# The stub asserts its own argv, so a future call-site change (an added flag, a different subcommand)
# fails LOUDLY here instead of silently returning canned data for a call we no longer make.
cat > "$STUB_DIR/vcf" <<'STUB'
#!/usr/bin/env bash
# Assert the WHOLE argv, not just the first four words. Asserting positionally let an ADDED TRAILING
# FLAG through silently — measured — which would have made every case below pass against a call we
# no longer make.
if [ "$*" != "context list -o json" ]; then
  echo "STUB: unexpected argv: $*" >&2; exit 64
fi
[ -n "${STUB_CONTEXTS:-}" ] || exit 1        # no contexts -> the CLI exits non-zero
printf '%s' "$STUB_CONTEXTS"
STUB
chmod +x "$STUB_DIR/vcf"
PATH="$STUB_DIR:$PATH"; export PATH

j() { printf '['; local first=1 n; for n in "$@"; do [ $first -eq 1 ] || printf ','; first=0; printf '{"name":"%s"}' "$n"; done; printf ']'; }

# 1. exactly one namespace context under this name -> that namespace
out="$(STUB_CONTEXTS="$(j 'sup:development-east-a-lng6r')" vks_discover_namespace sup 2>/dev/null)"
if [ "$out" = 'development-east-a-lng6r' ]; then ok "single candidate -> $out"; else bad "single candidate: got '$out'"; fi

# 2. contexts belonging to OTHER context names are ignored (prefix must discriminate)
out="$(STUB_CONTEXTS="$(j 'other:ns-a' 'sup:ns-b' 'supervisor-ctx:ns-c')" vks_discover_namespace sup 2>/dev/null)"
if [ "$out" = 'ns-b' ]; then ok "prefix discriminates -> $out"; else bad "prefix leak: got '$out'"; fi

# 3. AMBIGUOUS -> dies, and NAMES every candidate (never head -1)
err="$(STUB_CONTEXTS="$(j 'sup:ns-a' 'sup:ns-b')" vks_discover_namespace sup 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "AMBIGUOUS returned a value instead of dying — this is the head -1 bug"
else
  case "$err" in
    *ns-a*ns-b*) ok "ambiguous dies and lists both candidates" ;;
    *) bad "ambiguous died but did not name both candidates: $err" ;;
  esac
fi

# 4. no matching context -> dies (does NOT print an empty string and continue)
#    NOTE the SUBSHELL: die() calls `exit`, so calling this directly in an `if` condition would
#    terminate THIS TEST SCRIPT rather than testing the branch (it did, on the first run).
if ( STUB_CONTEXTS="$(j 'other:ns-a')" vks_discover_namespace sup ) >/dev/null 2>&1; then
  bad "no candidate did NOT die (an empty namespace would build 'ctx:' and fail later, confusingly)"
else
  ok "no candidate dies"
fi

# 5. the CLI itself failing (no contexts at all) -> a friendly die, not a set -e crash mid-function
err="$(unset STUB_CONTEXTS; vks_discover_namespace sup 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && [ -n "$err" ]; then ok "vcf failure dies with a message"; else bad "vcf failure: rc=$rc err='$err'"; fi

# 6. UNPARSEABLE output must NOT be reported as "no context exists" — the context was just created,
#    so that message names the wrong cause and sends the operator somewhere that contradicts it.
err="$(STUB_CONTEXTS='not json at all' vks_discover_namespace sup 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "unparseable context list returned a value"
else
  case "$err" in
    *"could not parse"*) ok "unparseable output is reported as a PARSE failure, not as 'no context'" ;;
    *) bad "unparseable output blamed the wrong cause: $err" ;;
  esac
fi

# 7. the no-match message must NAME the contexts it did see (so the operator can pick one), because
#    namespace contexts may hang off a different parent than VKS_CONTEXT_NAME.
err="$(STUB_CONTEXTS="$(j 'vcfa:e2e-ns')" vks_discover_namespace sup 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && case "$err" in *vcfa:e2e-ns*) true ;; *) false ;; esac; then
  ok "no-match lists the contexts it actually saw"
else
  bad "no-match did not name the observed contexts: $err"
fi

# 8. the stub is REAL: prove it rejects both a wrong subcommand AND an added trailing flag, so every
#    case above really exercised the argv the product sends. Without this the stub could be a no-op.
if "$STUB_DIR/vcf" context list >/dev/null 2>&1; then
  bad "the stub accepted a TRUNCATED argv — it is not asserting anything"
elif "$STUB_DIR/vcf" context list -o json --extra >/dev/null 2>&1; then
  bad "the stub accepted an ADDED FLAG — argv drift would pass silently"
else
  ok "stub rejects wrong argv AND an added flag (cases above exercised the real call)"
fi

if [ "$fail" -eq 0 ]; then echo "test-vks-discover-namespace: OK"; else echo "test-vks-discover-namespace: FAILED"; exit 1; fi
