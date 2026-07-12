#!/usr/bin/env bash
# lint.sh — shellcheck the scripts, yamllint the manifests, hadolint the Dockerfile.
# Best-effort per tool: a missing tool is warned-and-skipped; a PRESENT tool that
# finds problems fails the run (so CI is honest about what it actually checked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0

echo "== shellcheck (scripts/*.sh + repo-root *.sh) =="
if have shellcheck; then
  # Exclude nothing; lib/os.sh is sourced so give it shell=bash via its directive.
  # Include repo-root *.sh (e.g. bootstrap-jumpbox.sh) — not just scripts/.
  { find "$REPO_ROOT/scripts" -name '*.sh' -print0; \
    find "$REPO_ROOT" -maxdepth 1 -name '*.sh' -print0; } \
    | xargs -0 shellcheck -x || rc=1
else
  log_warn "shellcheck not installed — skipped"
fi

echo "== yamllint (manifests) =="
if have yamllint; then
  # Relaxed: line-length off (manifests are wide); comma/colon spacing off
  # (we column-align inline maps for readability).
  yamllint -d "{extends: relaxed, rules: {line-length: disable, commas: disable, colons: disable}}" \
    "$REPO_ROOT/tekton" "$REPO_ROOT/deploy" "$REPO_ROOT/argocd" "$REPO_ROOT/k8s" 2>/dev/null || rc=1
else
  log_warn "yamllint not installed — skipped"
fi

echo "== hadolint (apps/java/webui/Dockerfile*) =="
if have hadolint; then
  # Glob covers both the runtime Dockerfile AND Dockerfile.builder (the
  # air-gapped Maven builder image) — both must be lint-clean.
  found=0
  for df in "$REPO_ROOT"/apps/java/webui/Dockerfile*; do
    [ -f "$df" ] || continue
    found=1
    hadolint "$df" || rc=1
  done
  [ "$found" -eq 1 ] || log_warn "apps/java/webui/Dockerfile* not present yet — skipped"
else
  log_warn "hadolint not installed — skipped"
fi

echo "== hadolint (jumpbox/Dockerfile.*) =="
if have hadolint; then
  for df in "$REPO_ROOT"/jumpbox/Dockerfile.*; do
    [ -f "$df" ] && { hadolint "$df" || rc=1; }
  done
else
  log_warn "hadolint not installed — skipped"
fi

echo "== exec bit (scripts/*.sh must be executable) =="
# A script the Makefile / CI invokes as `./scripts/NN-foo.sh` and that was committed
# mode 100644 fails at RUN time with `Permission denied` (exit 126) — never at lint or
# build time, so it ships green and only breaks the e2e. Files created by an editor/tool
# default to 0644, so this is easy to do and invisible until it bites.
# scripts/lib/*.sh are SOURCED, never executed, so they are exempt (0644 is correct).
_nonexec=0
while IFS= read -r f; do
  [ -x "$f" ] && continue
  log_error "not executable (Makefile/CI runs it directly): ${f#"$REPO_ROOT"/}  -> chmod +x"
  _nonexec=1
done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f | sort)
[ "$_nonexec" -eq 0 ] || rc=1

if [ "$rc" -eq 0 ]; then log_info "lint: OK"; else log_error "lint: findings above"; fi
exit "$rc"
