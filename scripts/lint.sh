#!/usr/bin/env bash
# lint.sh — shellcheck the scripts, yamllint the manifests, hadolint the Dockerfile.
# Best-effort per tool: a missing tool is warned-and-skipped; a PRESENT tool that
# finds problems fails the run (so CI is honest about what it actually checked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0

echo "== shellcheck (scripts/*.sh) =="
if have shellcheck; then
  # Exclude nothing; lib/os.sh is sourced so give it shell=bash via its directive.
  find "$REPO_ROOT/scripts" -name '*.sh' -print0 | xargs -0 shellcheck -x || rc=1
else
  log_warn "shellcheck not installed — skipped"
fi

echo "== yamllint (manifests) =="
if have yamllint; then
  # Relaxed: line-length off (kubernetes manifests are wide); document-start off.
  yamllint -d "{extends: relaxed, rules: {line-length: disable}}" \
    "$REPO_ROOT/tekton" "$REPO_ROOT/deploy" "$REPO_ROOT/argocd" 2>/dev/null || rc=1
else
  log_warn "yamllint not installed — skipped"
fi

echo "== hadolint (app/Dockerfile) =="
if [ -f "$REPO_ROOT/app/Dockerfile" ]; then
  if have hadolint; then
    hadolint "$REPO_ROOT/app/Dockerfile" || rc=1
  else
    log_warn "hadolint not installed — skipped"
  fi
else
  log_warn "app/Dockerfile not present yet — skipped"
fi

if [ "$rc" -eq 0 ]; then log_info "lint: OK"; else log_error "lint: findings above"; fi
exit "$rc"
