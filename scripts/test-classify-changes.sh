#!/usr/bin/env bash
# test-classify-changes.sh — unit-test the CI gate selector (scripts/classify-changes.sh).
#
# This logic decides whether a change pays for a full Java+Go build. It was previously a
# paths-filter deny-list that silently ALWAYS said code=true, so every docs-only PR was billed
# for a build it did not need. That is what this test exists to prevent recurring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="${SCRIPT_DIR}/classify-changes.sh"

fail=0
t() { # <name> <expected-code> <expected-docs> <file...>
  local name="$1" want_code="$2" want_docs="$3"; shift 3
  local out; out="$(printf '%s\n' "$@" | "$CLASSIFY")"
  local got_code got_docs
  got_code="$(printf '%s\n' "$out" | sed -n 's/^code=//p')"
  got_docs="$(printf '%s\n' "$out" | sed -n 's/^docs=//p')"
  if [ "$got_code" = "$want_code" ] && [ "$got_docs" = "$want_docs" ]; then
    printf 'ok    %-42s code=%s docs=%s\n' "$name" "$got_code" "$got_docs"
  else
    printf 'FAIL  %-42s want code=%s docs=%s, got code=%s docs=%s\n' \
      "$name" "$want_code" "$want_docs" "$got_code" "$got_docs" >&2
    fail=1
  fi
}

# THE regression: a docs-only PR must NOT run static-check. (The old paths-filter said code=true.)
t "docs only (CLAUDE.md)"          false true  "CLAUDE.md"
t "docs only (README + docs/)"     false true  "README.md" "docs/vks-services/istio.md"
t "docs only (nested md)"          false true  "apps/some/app/README.md"

# Code must always run static-check.
t "code only"                      true  false "scripts/lib/apps.sh"
t "app source (nested)"            true  false "apps/some/app/main.go"
t "mixed code + docs"              true  true  "Makefile" "README.md"

# Deny-list semantics: a root-config-only change is CODE (an allow-list would skip BOTH gates
# and go green having run nothing).
t "root config only (renovate.json)" true false "renovate.json"
t "root config only (.trivyignore)"  true false ".trivyignore"
t "workflow only"                    true false ".github/workflows/ci.yml"

# Unknown file list (workflow_dispatch / tag / first push) -> run everything, never guess cheap.
t "empty list"                     true  true  ""

if [ "$fail" -ne 0 ]; then
  echo "test-classify-changes: FAILED" >&2
  exit 1
fi
echo "test-classify-changes: OK — 10 case(s); a docs-only change does not pay for a build."
