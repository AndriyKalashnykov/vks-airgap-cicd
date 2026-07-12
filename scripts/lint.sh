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
  # NOTE: stderr is NOT silenced. It used to be (`2>/dev/null`), and when a listed
  # directory stopped existing, yamllint failed with its reason hidden — the gate printed
  # "findings above" with nothing above. A gate that cannot say why it failed is a bug.
  yamllint -d "{extends: relaxed, rules: {line-length: disable, commas: disable, colons: disable}}" \
    "$REPO_ROOT/k8s" "$REPO_ROOT/deploy" || rc=1
else
  log_warn "yamllint not installed — skipped"
fi

echo "== hadolint (EVERY app's Dockerfile*, from apps/registry.tsv) =="
if have hadolint; then
  # Every app, not one hardcoded path: this glob used to name the Java app, which meant the Go
  # app's Dockerfile was never linted at all. The glob covers the runtime Dockerfile AND any
  # Dockerfile.builder (the air-gapped Maven builder) — both must be lint-clean.
  # shellcheck source=scripts/lib/apps.sh
  . "${SCRIPT_DIR}/lib/apps.sh"
  found=0
  while read -r _app; do
    [ -n "$_app" ] || continue
    for df in "${REPO_ROOT}/$(app_src "$_app")"/Dockerfile*; do
      [ -f "$df" ] || continue
      found=$((found + 1))
      hadolint "$df" || rc=1
    done
  done <<EOF
$(app_names)
EOF
  # Print the denominator: a gate that cannot say how many Dockerfiles it linted cannot be trusted.
  # (if/else, NOT `A && B || C` — that runs C when A is true and B fails: SC2015.)
  if [ "$found" -gt 0 ]; then
    log_info "hadolint: linted ${found} Dockerfile(s)"
  else
    log_warn "no app Dockerfiles found — skipped"
  fi
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
