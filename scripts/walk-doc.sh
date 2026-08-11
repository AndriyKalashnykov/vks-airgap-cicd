#!/usr/bin/env bash
# walk-doc.sh — execute docs/scenario-1.md ITSELF, block by block, in document order.
#
# WHY THIS REPLACES A HAND-WRITTEN DRIVER. The previous walker carried ~50 hardcoded steps that were
# a SECOND COPY of the runbook, and second copies drift: it had encoded the OLD document's ordering
# defects as workarounds, it never opened <details> blocks, and after the doc was renumbered its
# labels named steps that no longer existed. A walker that does not READ the document cannot
# validate it — it validates the author's memory of it.
#
# So: parse the fenced bash blocks out of the doc, in order, and run them. What it cannot run it
# reports OUT LOUD, because a walk that silently drops steps claims a coverage it does not have.
# Two different mechanisms, deliberately:
#   SKIP        - a whole block a walk must not run (teardown; the branch this row did not take)
#   NEUTRALIZE  - a single LINE that needs a TTY or blocks forever, commented out so the RUNNABLE
#                 commands beside it still execute. Block [13] is why: `argocd login` sits next to
#                 the credential read the walk needs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${WALK_DOC:-${SCRIPT_DIR}/../docs/scenario-1.md}"
[ -s "$DOC" ] || { echo "no document at $DOC"; exit 1; }

STEP=0; RAN=0; FAILED=0; SKIPPED=0
SKIP_LOG="$(mktemp)"; NEUT_LOG="$(mktemp)"; CWD_FILE="$(mktemp)"
trap 'rm -f "$SKIP_LOG" "$NEUT_LOG" "$CWD_FILE"' EXIT
CWD="${WALK_START_DIR:-$PWD}"

# ── Whole-block skips. Each is a block a WALK must not run, never a block that is broken.
should_skip() {
  case "$1" in
    *"make uninstall-all"*)     printf 'teardown - would destroy the lab mid-walk' ;;
    *"install-harbor-service"*) [ "${WALK_EXISTS:-1}" = 1 ] && printf 'Harbor already exists (this row)' ;;
    *"install-argocd-service"*) [ "${WALK_EXISTS:-1}" = 1 ] && printf 'ArgoCD already exists (this row)' ;;
    *"make vsphere-namespace"*) [ "${WALK_EXISTS:-1}" = 1 ] && printf 'namespace already exists (this row)' ;;
    *"vks-cluster-create"*)     [ "${WALK_EXISTS:-1}" = 1 ] && printf 'cluster already exists (this row)' ;;
    *"git clone https"*)        [ "${WALK_SKIP_CLONE:-0}" = 1 ] && printf 'already cloned by the harness' ;;
  esac
}

# Exactly ONE placeholder in the doc is a value a walk can supply.
substitute() { printf '%s' "${1//<your SSO password>/${VCF_CLI_VSPHERE_PASSWORD:-}}"; }

neutralize() {
  local out="" line
  while IFS= read -r line; do
    case "$line" in
      *"argocd login"*|*"argocd account update-password"*|*"port-forward"*)
        out+="# WALK-NEUTRALIZED (needs a TTY / blocks forever): ${line}"$'\n'
        printf '  neutralized: %s\n' "${line# }" >> "$NEUT_LOG" ;;
      *) out+="${line}"$'\n' ;;
    esac
  done <<< "$1"
  printf '%s' "$out"
}

# A <placeholder> in a COMMENT is prose, not a value. Checking the raw block skipped the LOGIN block
# — the single most important one — over `# note the <ctx>:<ns> colon form`. Strip comments first.
has_live_placeholder() {
  local code; code="$(printf '%s' "$1" | sed 's/#.*//')"
  printf '%s' "$code" | grep -q '<[a-z][^>]*>'
}

mapfile -t PARSED < <(python3 - "$DOC" <<'PY'
import re, sys, json
doc = open(sys.argv[1]).read()
heading = "(preamble)"
# [^\n]+ not .+ : under re.S a greedy `.` swallows the whole file and yields ZERO blocks.
# The fence is NOT ^-anchored: block [21] is indented inside a <details> and a naive grep misses it.
for m in re.finditer(r'^(## [^\n]+)$|```bash\n(.*?)```', doc, re.M | re.S):
    if m.group(1): heading = m.group(1)[3:].strip()
    else:          print(json.dumps({"h": heading, "b": m.group(2)}))
PY
)

printf '\n======== walking %s (%d bash blocks, in document order) ========\n' "$(basename "$DOC")" "${#PARSED[@]}"
for row in "${PARSED[@]}"; do
  H="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["h"])')"
  B="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["b"])')"
  STEP=$((STEP + 1))
  reason="$(should_skip "$B")"
  B="$(neutralize "$(substitute "$B")")"
  if [ -z "$reason" ] && has_live_placeholder "$B"; then
    reason='unsubstituted <placeholder> in a COMMAND - a walk must not invent a value'
  fi
  if [ -n "$reason" ]; then
    printf '\n--- [%02d] %s  SKIPPED: %s\n' "$STEP" "$H" "$reason"
    SKIPPED=$((SKIPPED + 1)); printf '  skipped: [%02d] %s - %s\n' "$STEP" "$H" "$reason" >> "$SKIP_LOG"
    continue
  fi
  printf '\n=== [%02d] %s\n' "$STEP" "$H"
  printf '%s\n' "${B%$'\n'}" | sed 's/^/    $ /'
  t0=$SECONDS
  if [ "${WALK_DRY:-0}" = 1 ]; then printf '    (dry run - not executed)\n'; rc=0
  else
    # Each block gets its own `bash -c`, so cwd does NOT persist -- and `cd vks-airgap-cicd` in the
    # clone block must. Carry it forward explicitly. ENV continuity is deliberately NOT carried: the
    # doc re-sources ./.env in every block that needs it, and a block that forgot to should FAIL here
    # rather than be rescued by state the reader's shell would not have.
    bash -c "cd '$CWD' || exit 1
$B
printf '\n__WALK_CWD__%s\n' \"\$PWD\"" 2>&1 | while IFS= read -r l; do
      case "$l" in __WALK_CWD__*) printf '%s' "${l#__WALK_CWD__}" > "$CWD_FILE" ;;
                   *) printf '    %s\n' "$l" ;; esac
    done
    rc=${PIPESTATUS[0]}
    nc="$(cat "$CWD_FILE" 2>/dev/null || true)"
    if [ -n "$nc" ] && [ "$nc" != "$CWD" ]; then printf '    (cwd -> %s)\n' "$nc"; CWD="$nc"; fi
  fi
  RAN=$((RAN + 1)); [ "$rc" -ne 0 ] && FAILED=$((FAILED + 1))
  printf -- '--- [%02d] rc=%d (%ds)\n' "$STEP" "$rc" "$((SECONDS - t0))"
done

printf '\n======== WALK DONE - %d blocks: %d ran, %d failed, %d skipped, %d line(s) neutralized ========\n' \
  "$STEP" "$RAN" "$FAILED" "$SKIPPED" "$(wc -l < "$NEUT_LOG")"
# A coverage number without its exclusions is a claim, not a measurement.
cat "$SKIP_LOG" "$NEUT_LOG"
exit $(( FAILED > 0 ? 1 : 0 ))
