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
# A SEPARATE axis from WALK_EXISTS: a Harbor robot can already exist on a lab whose namespace and
# cluster do not (a previous jump box minted it), and the reverse. Harbor shows a robot secret
# ONCE, so `make harbor-robot` CANNOT be re-run to recover it -- stopping is correct, and a walk
# must not score that as a document defect.
: "${WALK_ROBOT_EXISTS:?set 0 (mint a robot) or 1 (one already exists elsewhere) explicitly}"
# PER-RESOURCE AXES. "everything exists" and "nothing exists" are not the only two states a real lab
# is in, and treating them as such cost a matrix row: Harbor deregistered cleanly while ArgoCD would
# not, leaving a lab that is genuinely "Harbor absent, ArgoCD present" -- a legitimate cell that one
# boolean cannot express. Each defaults to WALK_EXISTS, so the simple case stays one knob.
WALK_NS_EXISTS="${WALK_NS_EXISTS:-$WALK_EXISTS}"
WALK_HARBOR_EXISTS="${WALK_HARBOR_EXISTS:-$WALK_EXISTS}"
WALK_ARGOCD_EXISTS="${WALK_ARGOCD_EXISTS:-$WALK_EXISTS}"
WALK_CLUSTER_EXISTS="${WALK_CLUSTER_EXISTS:-$WALK_EXISTS}"
# NO DEFAULT, and it cost a row to learn why. Step 12 says to run the command `make istio-preflight`
# PRINTS. With WALK_ISTIO defaulting to `existing`, the walk ran the ATTACH variant on a cluster
# whose preflight had just said, in the block immediately before, "NO Istio detected -> use
# 'make install-ingress' to INSTALL it". The walk contradicted the document and then scored the
# resulting failure against the document. A default here is a silent wrong answer.
: "${WALK_ISTIO:?set to 'install' or 'existing' — read it off 'make istio-preflight' for THIS cluster, do not guess}"

STEP=0; RAN=0; FAILED=0; SKIPPED=0
# The DOCUMENT's own claims, counted separately from the commands' exit codes. "32 blocks ran"
# says the COMMANDS worked; it says nothing about whether the reader saw what they were told
# they would see. These two numbers answer different questions and must not be conflated.
EXPECT_TOTAL=0; EXPECT_MISS=0
SKIP_LOG="$(mktemp)"; NEUT_LOG="$(mktemp)"; CWD_FILE="$(mktemp)"; RC_FILE="$(mktemp)"; UNSAFE_FILE="$(mktemp)"; OUT_FILE="$(mktemp)"; EXPECT_LOG="$(mktemp)"
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
    *"install-harbor-service"*) [ "$WALK_HARBOR_EXISTS" = 1 ] && printf 'Harbor already exists (this row)' ;;
    *"install-argocd-service"*) [ "$WALK_ARGOCD_EXISTS" = 1 ] && printf 'ArgoCD already exists (this row)' ;;
    *"make vsphere-namespace"*) [ "$WALK_NS_EXISTS" = 1 ] && printf 'namespace already exists (this row)' ;;
    *"make harbor-robot"*)      [ "$WALK_ROBOT_EXISTS" = 1 ] && printf 'a Harbor robot already exists; its secret is shown ONCE and cannot be re-read' ;;
    *"vks-cluster-create"*)     [ "$WALK_CLUSTER_EXISTS" = 1 ] && printf 'cluster already exists (this row)' ;;
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
# $2 = "log" -> record what was neutralized. Called twice per block (once to build the text that is
# PRINTED, once to build the text that RUNS), so exactly one caller may log or the count doubles.
neutralize() {
  local out="" line prev=""
  while IFS= read -r line; do
    case "$line" in
      *"argocd login"*|*"argocd account update-password"*|*"port-forward"*)
        case "$line" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # continues into the next line
        case "$prev" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # is a continuation of the previous
        out+="# WALK-NEUTRALIZED (needs a TTY / blocks forever): ${line}"$'\n'
        [ "${2:-}" = log ] && printf '  neutralized: %s\n' "${line# }" >> "$NEUT_LOG" ;;
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

# LINE BY LINE, as a reader runs it. Executing a whole block as ONE `bash -c` collapses four
# commands into one exit code and one lump of output -- so a reader who runs them one at a time,
# looking at each result before typing the next, is NOT what was tested. The unit must be the
# STATEMENT.
#
# Where a statement ENDS is decided by BASH ITSELF (`bash -n` on the accumulated text), not by a
# regex: `\`-continuations, `if/then/fi`, `for/do/done`, heredocs and multi-line quotes are all
# incomplete until they are complete, and any hand-rolled splitter gets one of them wrong and then
# executes a fragment.
split_statements() {   # <block text> -> NUL-separated statements on stdout
  local acc="" line
  while IFS= read -r line || [ -n "$line" ]; do
    acc="${acc}${line}"$'\n'
    # skip blank/comment-only accumulations rather than emitting them as "commands"
    case "$(printf '%s' "$acc" | sed 's/#.*//' | tr -d '[:space:]')" in '') continue ;; esac
    if bash -n <<< "$acc" 2>/dev/null; then
      printf '%s\0' "${acc%$'\n'}"
      acc=""
    fi
  done <<< "$1"
  # An unterminated remainder is a DOC BUG (an unclosed quote or heredoc). Emit it so it runs and
  # fails loudly, rather than silently dropping the tail of a block.
  case "$(printf '%s' "$acc" | tr -d '[:space:]')" in '') : ;; *) printf '%s\0' "${acc%$'\n'}" ;; esac
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
        # The document's CONTRACT WITH THE READER. `**Expect:** ...` states what they will SEE, and
        # nothing has ever checked it -- a walk that reports rc=0 for every block proves the COMMANDS
        # ran, not that the DOCUMENT is truthful. Attach it to the block it follows.
        elif line.startswith('**Expect') and out: out[-1]["e"].append(line.rstrip())
    elif m and not m.group(3) and len(m.group(2)) >= fence[1]:
        if fence[0] in ('bash', 'sh', 'shell'): out.append({"h": heading, "b": "".join(body), "e": []})
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
printf 'blocks: %d extracted, %d counted independently | os=%s\n' "${#PARSED[@]}" "$INDEP" "${WALK_OS:-?}"
# Print the RESOLVED per-resource row, not the WALK_EXISTS shorthand -- the whole point is that they
# can differ, and a reader of the log must be able to see which cell of the matrix this run was.
printf 'row: ns=%s harbor=%s argocd=%s cluster=%s robot=%s clone-skipped=%s istio=%s\n' \
  "$WALK_NS_EXISTS" "$WALK_HARBOR_EXISTS" "$WALK_ARGOCD_EXISTS" "$WALK_CLUSTER_EXISTS" \
  "$WALK_ROBOT_EXISTS" "${WALK_SKIP_CLONE:-0}" "${WALK_ISTIO:-existing}"
# Disclosed, because it is a real trade: carrying the environment means a block that forgot to
# source ./.env is rescued by the previous one -- exactly as it would be for a reader in one terminal.
printf 'shell: ONE INTERACTIVE bash per STATEMENT, ENV AND CWD CARRIED FORWARD (a reader has one terminal,\n        and runs one command at a time -- each result is printed under the command that produced it)\n'
[ "${#PARSED[@]}" -ge "${WALK_MIN_BLOCKS:-20}" ] \
  || { echo "REFUSING: only ${#PARSED[@]} blocks (< ${WALK_MIN_BLOCKS:-20}) — the parser and the document have diverged"; exit 1; }

for row in "${PARSED[@]}"; do
  H="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["h"])')"
  B="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["b"])')"
  E="$(printf '%s' "$row" | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin).get("e",[])))')"
  STEP=$((STEP + 1))
  reason="$(should_skip "$B")"
  : > "$UNSAFE_FILE"
  RAWB="$B"                           # pre-substitution, so statements are split on the DOCUMENT's text
  # The RESULT is unused now (each statement renders its own safe text), but the CALL is not: it is
  # what arms the UNSAFE_FILE guard below on the pre-substitution text. Deliberately WITHOUT `log`,
  # or every neutralized line would be counted twice -- once here and once per statement.
  neutralize "$B" >/dev/null
  B="$(neutralize "$(substitute "$B")")"   # what actually RUNS -- may carry a real credential
  [ -s "$UNSAFE_FILE" ] && [ -z "$reason" ] \
    && reason='a TTY-bound command sits inside a \-continued command - neutralizing one line would delete an argument from the survivor'
  # $B, not $SHOWN: the guard asks whether a placeholder SURVIVED substitution.
  if [ -z "$reason" ] && has_live_placeholder "$B"; then
    reason='unsubstituted <placeholder> in a COMMAND - a walk must not invent a value'
  fi
  if [ -n "$reason" ]; then
    printf '\n--- [%02d] %s  SKIPPED: %s\n' "$STEP" "$H" "$reason"
    SKIPPED=$((SKIPPED + 1)); printf '  skipped: [%02d] %s - %s\n' "$STEP" "$H" "$reason" >> "$SKIP_LOG"
    continue
  fi
  printf '\n=== [%02d] %s\n' "$STEP" "$H"
  t0=$SECONDS
  if [ "${WALK_DRY:-0}" = 1 ]; then printf '    (dry run - not executed)\n'; rc=0
  else
    : > "$OUT_FILE"
    rc=0
    # ONE STATEMENT AT A TIME, each with its own output and its own rc printed underneath it --
    # because that is what the reader sees. Running the block as one `bash -c` produced ONE exit
    # code for four commands: a reader who runs them individually, reading each result before
    # typing the next, was never what got tested.
    #
    # `done < <(...)` and NOT a pipe: the loop body must run in THIS shell so the cwd it learns
    # carries to the next statement, exactly as it would in the reader's one terminal.
    while IFS= read -r -d '' _raw; do
      _show="$(neutralize "$_raw" log)"
      _run="$(neutralize "$(substitute "$_raw")")"
      printf '%s\n' "${_show%$'\n'}" | sed 's/^/    $ /'
      : > "$CWD_FILE"; : > "$RC_FILE"
      # (1) `bash -c` exits with its LAST command's status and the marker printf ALWAYS succeeds --
      # so capture the statement's own status FIRST, then emit the markers, then exit with it.
      # (11) the leading newline is load-bearing: a statement ending in `\` would swallow `__rc=$?`.
      # (9) the cwd goes in as an ARGUMENT, never interpolated -- a balanced quote pair in a path
      # was a proven injection.
      #   -i  : ~/.bashrc's `case $- in *i*` guard passes, so `make shell-init`'s PATH survives.
      #   env : `export -p` at the end, sourced at the start of the next -- ONE terminal.
      bash -i -c '. "$2" 2>/dev/null; cd "$1" || exit 1
'"$_run"'
__rc=$?
# ALL variables, not just exported ones. `export -p` carries only the exported set, so a plain
# `V=present` on one line was GONE by the next -- measured: `echo "$V"` printed empty where a
# reader in one terminal would see the value. That is the one-terminal property, and executing
# statement-by-statement is exactly what put it at risk.
# The readonly/special names are filtered: re-assigning UID, BASHOPTS, PIPESTATUS et al. errors
# on the way back in, and one error there would poison every later statement.
{ declare -p 2>/dev/null | grep -vE "^declare -[a-zA-Z]*r" \
    | grep -vE "^declare -[a-zA-Z-]+ (BASH|BASHOPTS|BASHPID|BASH_[A-Z]+|COMP_[A-Z]+|DIRSTACK|EPOCH[A-Z]*|EUID|FUNCNAME|GROUPS|HISTCMD|LINENO|OPTARG|OPTIND|PIPESTATUS|PPID|RANDOM|SECONDS|SHELLOPTS|SRANDOM|UID|_)="
  declare -f 2>/dev/null
} > "$2" 2>/dev/null
printf "\n__WALK_RC__%s\n__WALK_CWD__%s\n" "$__rc" "$PWD"
exit $__rc' _ "$CWD" "$ENV_FILE" 2>&1 \
        | grep -vE '^bash: (cannot set terminal process group|no job control)' \
        | while IFS= read -r l; do
          case "$l" in
            __WALK_RC__*)  printf '%s' "${l#__WALK_RC__}"  > "$RC_FILE" ;;
            __WALK_CWD__*) printf '%s' "${l#__WALK_CWD__}" > "$CWD_FILE" ;;
            *) printf '    %s\n' "$l"; printf '%s\n' "$l" >> "$OUT_FILE" ;;
          esac
        done
      _src=${PIPESTATUS[0]}
      _mrc="$(cat "$RC_FILE" 2>/dev/null || true)"
      [ -n "$_mrc" ] && _src="$_mrc"       # the marker is authoritative when the statement finished
      _nc="$(cat "$CWD_FILE" 2>/dev/null || true)"
      if [ -n "$_nc" ] && [ "$_nc" != "$CWD" ]; then printf '    (cwd -> %s)\n' "$_nc"; CWD="$_nc"; fi
      # The per-statement result, printed where the reader would see it -- not folded into a block.
      printf '      -> rc=%d\n' "$_src"
      [ "$_src" -ne 0 ] && rc=1
    done < <(split_statements "$RAWB")
  fi
  RAN=$((RAN + 1)); [ "$rc" -ne 0 ] && FAILED=$((FAILED + 1))
  if [ -n "$E" ] && [ "${WALK_DRY:-0}" != 1 ]; then
    _seen=0; _tot=0; _missed=""
    while IFS=$'\t' read -r verdict lit; do
      [ -n "${lit:-}" ] || continue
      printf '    expect: %-56s %s\n' "$lit" "$verdict"
      _tot=$((_tot + 1))
      if [ "$verdict" = "SEEN" ]; then _seen=$((_seen + 1)); else _missed="${_missed}
      - ${lit}"; fi
    done < <(EXPECT_TEXT="$E" BLOCK_TEXT="$B" python3 - "$OUT_FILE" <<'PYX'
import os, re, sys
out  = open(sys.argv[1], errors='replace').read()
blk  = os.environ.get('BLOCK_TEXT', '')
for line in os.environ.get('EXPECT_TEXT', '').splitlines():
    for lit in re.findall(r'`([^`]+)`', line):
        lit = lit.strip()
        # A literal carrying a placeholder or an ellipsis cannot be matched verbatim -- the document
        # is telling the reader the SHAPE, not the text.
        if len(lit) < 6 or re.search(r'[<>]|\.\.\.|…', lit):      continue
        # Skip the literals that name the COMMAND the reader just ran: they appear in the block
        # itself, so finding them in the output proves nothing about the claim.
        if lit in blk:                                            continue
        print(("SEEN" if lit in out else "NOT SEEN") + "\t" + lit)
PYX
    )
    # THE UNIT IS THE BLOCK. A single literal missing is prose noise (the doc hedges, abbreviates,
    # and mixes the command with the output). A block whose claims produced NOTHING is the document
    # telling the reader they will see something they do not -- which is the whole question this
    # walk exists to answer, and which an rc-only report is structurally blind to.
    if [ "$_tot" -gt 0 ]; then
      EXPECT_TOTAL=$((EXPECT_TOTAL + 1))
      if [ "$_seen" -eq 0 ]; then
        EXPECT_MISS=$((EXPECT_MISS + 1))
        printf '    EXPECT UNMET: the document promises output this block did not produce\n'
        printf '  expect-unmet: [%02d] %s%s\n' "$STEP" "$H" "$_missed" >> "$EXPECT_LOG"
      fi
    fi
  fi
  printf -- '--- [%02d] rc=%d (%ds)\n' "$STEP" "$rc" "$((SECONDS - t0))"
done

printf '\n======== WALK DONE - %d blocks: %d ran, %d FAILED, %d skipped, %d line(s) neutralized ========\n' \
  "$STEP" "$RAN" "$FAILED" "$SKIPPED" "$(wc -l < "$NEUT_LOG")"
# TWO different questions, never one number: did the COMMANDS work, and is the DOCUMENT truthful?
# A walk that reports only the first is the failure this line exists to make impossible.
printf '======== DOCUMENT - %d blocks make an Expect: claim, %d UNMET ========\n' \
  "$EXPECT_TOTAL" "$EXPECT_MISS"
cat "$EXPECT_LOG"
# A coverage number without its exclusions is a claim, not a measurement.
cat "$SKIP_LOG" "$NEUT_LOG"
# (2) "nothing failed" and "nothing happened" must not share an exit code.
[ "$RAN" -gt 0 ] || { echo "REFUSING: the walk executed NOTHING"; exit 1; }
# An UNMET claim fails the walk. WALK_EXPECT_ADVISORY=1 downgrades it -- use it only with a written
# reason, because "the document says something untrue" is exactly what a doc walk is for.
if [ "$EXPECT_MISS" -gt 0 ] && [ "${WALK_EXPECT_ADVISORY:-0}" != 1 ]; then
  exit 1
fi
exit $(( FAILED > 0 ? 1 : 0 ))
