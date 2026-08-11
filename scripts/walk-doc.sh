#!/usr/bin/env bash
# walk-doc.sh — execute docs/scenario-1.md ITSELF, block by block, in document order.
#
# WHY THIS REPLACES A HAND-WRITTEN DRIVER. The previous walker carried ~50 hardcoded steps that were
# a SECOND COPY of the runbook, and second copies drift: it encoded the OLD document's ordering
# defects as workarounds, never opened <details> blocks, and after a renumbering its labels named
# steps that no longer existed. A walker that does not READ the document validates the author's
# memory of it, not the document.
#
# ⚠️ THE FIRST VERSION OF THIS SCRIPT REPORTED "0 failed" OVER A WALK IN WHICH EVERY BLOCK DIED WITH
# `make: command not found`. An adversary round measured why, and most of what follows is the fix.
# Read the numbered notes before "simplifying" any of it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${WALK_DOC:-${SCRIPT_DIR}/../docs/scenario-1.md}"
[ -s "$DOC" ] || { echo "no document at $DOC"; exit 1; }
# (8) NO DEFAULT. `WALK_EXISTS:-1` skipped all four provisioning blocks, so a row meant to exercise
# the install path scored green having installed nothing. Forgetting must not be the cheap option.
: "${WALK_EXISTS:?set 0 (install path) or 1 (already-exists path) explicitly}"

STEP=0; RAN=0; FAILED=0; SKIPPED=0
SKIP_LOG="$(mktemp)"; NEUT_LOG="$(mktemp)"; CWD_FILE="$(mktemp)"; RC_FILE="$(mktemp)"; UNSAFE_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"; : > "$ENV_FILE"
trap 'rm -f "$SKIP_LOG" "$NEUT_LOG" "$CWD_FILE" "$RC_FILE" "$UNSAFE_FILE" "$ENV_FILE"' EXIT
CWD="${WALK_START_DIR:-$PWD}"

# ── Whole-block skips: a block a WALK must not run, never a block that is broken.
# (4) Match COMMAND LINES only. Matching the raw block let a comment that merely WARNS about
# `make uninstall-all` skip the `make verify` beside it -- and label it a teardown block.
should_skip() {
  local code; code="$(printf '%s' "$1" | sed 's/#.*//')"
  case "$code" in
    *"make uninstall-all"*)     printf 'teardown - would destroy the lab mid-walk' ;;
    # ORDER MATTERS: the attach variant's text also contains "make install-ingress", and `case` takes
    # the FIRST match -- with the general pattern first, BOTH blocks were skipped and Step 12 ran no
    # install at all, which is the defect the document was just fixed for.
    *"INGRESS_CONTROLLER=istio-existing"*)
                                [ "${WALK_ISTIO:-existing}" != existing ] && printf 'attach variant; this row installs' ;;
    *"make install-ingress"*)   [ "${WALK_ISTIO:-existing}" = existing ] && printf 'install variant; this row attaches to an existing mesh' ;;
    *"install-harbor-service"*) [ "$WALK_EXISTS" = 1 ] && printf 'Harbor already exists (this row)' ;;
    *"install-argocd-service"*) [ "$WALK_EXISTS" = 1 ] && printf 'ArgoCD already exists (this row)' ;;
    *"make vsphere-namespace"*) [ "$WALK_EXISTS" = 1 ] && printf 'namespace already exists (this row)' ;;
    *"vks-cluster-create"*)     [ "$WALK_EXISTS" = 1 ] && printf 'cluster already exists (this row)' ;;
    *"git clone https"*)        [ "${WALK_SKIP_CLONE:-0}" = 1 ] && printf 'already cloned by the harness' ;;
    *"apt-get install"*)        [ "${WALK_OS:-}" = photon ] && printf 'Ubuntu block; this box is Photon' ;;
    *"tdnf install"*)           case "${WALK_OS:-}" in ubuntu|debian) printf 'Photon block; this box is %s' "$WALK_OS" ;; esac ;;
  esac
}

# (6) Substitute ONLY when the value is non-empty. Replacing the placeholder with "" deleted the
# evidence the guard keys on, so two blocks ran `export VCF_CLI_VSPHERE_PASSWORD=''` and were counted
# as RAN -- then failed downstream on an auth error that reads like a document defect. An empty
# string IS an invented value.
substitute() {
  [ -n "${VCF_CLI_VSPHERE_PASSWORD:-}" ] || { printf '%s' "$1"; return; }
  printf '%s' "${1//<your SSO password>/$VCF_CLI_VSPHERE_PASSWORD}"
}

# (5) A line a walk cannot run is COMMENTED OUT and counted -- not grounds to drop the whole block,
# which would also drop the runnable commands beside it (block [13]: `argocd login` sits next to the
# credential read the walk needs). BUT a matched line inside a `\` continuation cannot be commented
# out in isolation: doing so silently DELETES an argument from the surviving command and still
# reports "1 line neutralized". Refuse the block instead -- half-executing is worse than not.
neutralize() {
  local out="" line prev=""
  while IFS= read -r line; do
    case "$line" in
      *"argocd login"*|*"argocd account update-password"*|*"port-forward"*)
        case "$line" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # continues into the next line
        case "$prev" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # is a continuation of the previous
        out+="# WALK-NEUTRALIZED (needs a TTY / blocks forever): ${line}"$'\n'
        printf '  neutralized: %s\n' "${line# }" >> "$NEUT_LOG" ;;
      *) out+="${line}"$'\n' ;;
    esac
    prev="$line"
  done <<< "$1"
  printf '%s' "$out"
}

# (7) `[a-z]` missed `<EXTERNAL-IP>`, `<NS>`, `<YOUR-TOKEN>` -- every conventional UPPERCASE
# placeholder. (Comments are prose: checking the raw block skipped the LOGIN block, the most
# important one in the walk, over `# note the <ctx>:<ns> colon form`.)
has_live_placeholder() {
  printf '%s' "$1" | sed 's/#.*//' | grep -q '<[A-Za-z][^>]*>'
}

# (3) FENCE-AWARE, not regex. A ```bash nested inside another fenced block -- an illustrative
# snippet, a doc-about-docs example, a command the reader must NOT run -- was extracted and
# scheduled for execution. Tracking fence state also makes ```sh / ```bash-with-attributes an
# explicit decision rather than a silent zero.
mapfile -t PARSED < <(python3 - "$DOC" <<'PY'
import json, re, sys
heading, fence, body, out = "(preamble)", None, [], []
for line in open(sys.argv[1]):
    # CommonMark: a fence is >=3 backticks and closes on a run of AT LEAST that many with no
    # info string. Assuming exactly 3 mis-parses the ````markdown wrapper people use to SHOW a
    # ```bash block -- and the inner one then gets extracted and EXECUTED.
    m = re.match(r'^(\s*)(`{3,})(\S*)', line)
    if fence is None:
        if m: fence = (m.group(3).split(':')[0].lower(), len(m.group(2))); body = []
        elif line.startswith('## '): heading = line[3:].strip()
    elif m and not m.group(3) and len(m.group(2)) >= fence[1]:
        if fence[0] in ('bash', 'sh', 'shell'): out.append({"h": heading, "b": "".join(body)})
        fence = None
    else:
        body.append(line)
if fence is not None: sys.exit("UNCLOSED fence in the document")
for o in out: print(json.dumps(o))
PY
) || { echo "EXTRACTOR FAILED — refusing to report a walk"; exit 1; }

# (2) A zero-block extraction reported "0 blocks: 0 ran, 0 failed" and EXIT 0. Three reachable
# paths measured: a fence attribute, ```sh, and one invalid UTF-8 byte. That state HAS occurred here
# (a greedy `.` under re.S). The floor is reconciled against an INDEPENDENT count, because a
# denominator that only the parser produces cannot detect the parser being wrong.
INDEP="$(grep -c '^[[:space:]]*```bash' "$DOC" || true)"
printf '\n======== walking %s ========\n' "$(basename "$DOC")"
printf 'blocks: %d extracted, %d counted independently | row: WALK_OS=%s WALK_EXISTS=%s WALK_SKIP_CLONE=%s\n' \
  "${#PARSED[@]}" "$INDEP" "${WALK_OS:-?}" "$WALK_EXISTS" "${WALK_SKIP_CLONE:-0}"
# Disclosed, because it is a real trade: carrying the environment means a block that forgot to
# source ./.env is rescued by the previous one -- exactly as it would be for a reader in one terminal.
printf 'shell: ONE INTERACTIVE bash per block, ENV AND CWD CARRIED FORWARD (a reader has one terminal)\n'
[ "${#PARSED[@]}" -ge "${WALK_MIN_BLOCKS:-20}" ] \
  || { echo "REFUSING: only ${#PARSED[@]} blocks (< ${WALK_MIN_BLOCKS:-20}) — the parser and the document have diverged"; exit 1; }

for row in "${PARSED[@]}"; do
  H="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["h"])')"
  B="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["b"])')"
  STEP=$((STEP + 1))
  reason="$(should_skip "$B")"
  : > "$UNSAFE_FILE"
  B="$(neutralize "$(substitute "$B")")"
  [ -s "$UNSAFE_FILE" ] && [ -z "$reason" ] \
    && reason='a TTY-bound command sits inside a \-continued command - neutralizing one line would delete an argument from the survivor'
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
    : > "$CWD_FILE"; : > "$RC_FILE"           # (10) never carry a stale marker into the next block
    # (1) THE CRITICAL FIX. `bash -c` exits with its LAST command's status, and the marker printf I
    # append ALWAYS succeeds -- so every rc was the printf's. Measured: `make no-such-target` -> rc=0,
    # `false` -> rc=0, and a 25-block walk in which nothing worked reported "0 failed". Capture the
    # block's own status FIRST, then emit the markers, then exit with it.
    # (11) the leading newline is load-bearing: a block ending in `\` would otherwise swallow `__rc=$?`.
    # (9) the cwd goes in as an ARGUMENT, not interpolated -- a balanced quote pair in a path was a
    # proven injection.
    # A READER HAS ONE TERMINAL. The first version gave each block its own non-interactive
    # `bash -c`, reasoning that the doc re-sources ./.env in every block that needs it -- true for
    # .env, and WRONG for PATH. Measured: `make shell-init` puts the toolchain on PATH through the
    # shell's rc file, that shell exited, and the next twelve blocks died `kubectl: command not
    # found` / `vcf: command not found`, cascading into "vks.kubeconfig does not exist" for every
    # remaining step. A reader would have hit none of it.
    #   -i  : $- then contains `i`, so ~/.bashrc's `case $- in *i*` guard passes and rc files load.
    #         Costs two job-control lines on stderr, filtered below.
    #   env : `export -p` at the end of each block, sourced at the start of the next. Verified to
    #         round-trip values containing quotes and newlines.
    bash -i -c '. "$2" 2>/dev/null; cd "$1" || exit 1
'"$B"'
__rc=$?
export -p > "$2" 2>/dev/null
printf "\n__WALK_RC__%s\n__WALK_CWD__%s\n" "$__rc" "$PWD"
exit $__rc' _ "$CWD" "$ENV_FILE" 2>&1 \
      | grep -vE '^bash: (cannot set terminal process group|no job control)' \
      | while IFS= read -r l; do
      case "$l" in
        __WALK_RC__*)  printf '%s' "${l#__WALK_RC__}"  > "$RC_FILE" ;;
        __WALK_CWD__*) printf '%s' "${l#__WALK_CWD__}" > "$CWD_FILE" ;;
        *) printf '    %s\n' "$l" ;;
      esac
    done
    rc=${PIPESTATUS[0]}
    mrc="$(cat "$RC_FILE" 2>/dev/null || true)"
    [ -n "$mrc" ] && rc="$mrc"                # the marker is authoritative when the block ran to its end
    nc="$(cat "$CWD_FILE" 2>/dev/null || true)"
    if [ -n "$nc" ] && [ "$nc" != "$CWD" ]; then printf '    (cwd -> %s)\n' "$nc"; CWD="$nc"; fi
  fi
  RAN=$((RAN + 1)); [ "$rc" -ne 0 ] && FAILED=$((FAILED + 1))
  printf -- '--- [%02d] rc=%d (%ds)\n' "$STEP" "$rc" "$((SECONDS - t0))"
done

printf '\n======== WALK DONE - %d blocks: %d ran, %d FAILED, %d skipped, %d line(s) neutralized ========\n' \
  "$STEP" "$RAN" "$FAILED" "$SKIPPED" "$(wc -l < "$NEUT_LOG")"
# A coverage number without its exclusions is a claim, not a measurement.
cat "$SKIP_LOG" "$NEUT_LOG"
# (2) "nothing failed" and "nothing happened" must not share an exit code.
[ "$RAN" -gt 0 ] || { echo "REFUSING: the walk executed NOTHING"; exit 1; }
exit $(( FAILED > 0 ? 1 : 0 ))
