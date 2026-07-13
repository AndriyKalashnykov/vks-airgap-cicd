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
t() { # <name> <expected-code> <expected-docs> [<expected-diagrams>] <file...>
  local name="$1" want_code="$2" want_docs="$3"; shift 3
  local want_diag=""
  case "$1" in true|false) want_diag="$1"; shift ;; esac
  local out; out="$(printf '%s\n' "$@" | "$CLASSIFY")"
  local got_code got_docs got_diag
  got_code="$(printf '%s\n' "$out" | sed -n 's/^code=//p')"
  got_docs="$(printf '%s\n' "$out" | sed -n 's/^docs=//p')"
  got_diag="$(printf '%s\n' "$out" | sed -n 's/^diagrams=//p')"
  if [ "$got_code" = "$want_code" ] && [ "$got_docs" = "$want_docs" ] \
     && { [ -z "$want_diag" ] || [ "$got_diag" = "$want_diag" ]; }; then
    printf 'ok    %-42s code=%s docs=%s diagrams=%s\n' "$name" "$got_code" "$got_docs" "$got_diag"
  else
    printf 'FAIL  %-42s want code=%s docs=%s diagrams=%s, got code=%s docs=%s diagrams=%s\n' \
      "$name" "$want_code" "$want_docs" "$want_diag" "$got_code" "$got_docs" "$got_diag" >&2
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

# THE regression this change exists to prevent: a README-only PR must NOT pay for a PlantUML
# render (a ~478 MB image pull + a JVM re-render of every diagram it never touched).
t "docs only -> NO diagram render"   false true  false "README.md"
t "docs only (many)"                 false true  false "README.md" "docs/vks-services/istio.md"
# A diagram source or a committed PNG changed -> the drift gate MUST run.
t "puml changed -> render"           false true  true  "docs/diagrams/container.puml"
t "committed PNG changed -> render"  false true  true  "docs/diagrams/out/container.png"
# The renderer itself is pinned in the Makefile: a plantuml bump changes the rendered BYTES, so
# the drift gate must run even though no .puml changed (else every PNG silently goes stale).
t "Makefile (PLANTUML_VERSION) -> render" true false true "Makefile"
# Unknown/empty input -> run everything (never guess cheap).
t "empty input -> everything"        true  true  true

if [ "$fail" -ne 0 ]; then
  echo "test-classify-changes: FAILED" >&2
  exit 1
fi
echo "test-classify-changes: OK — 16 case(s); a docs-only change does not pay for a build."
