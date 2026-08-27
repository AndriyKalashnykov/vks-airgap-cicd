#!/usr/bin/env bash
# check-lib-sourcing.sh — a script that CALLS a lib function must SOURCE the lib that defines it.
#
# WHY THIS EXISTS. `scripts/lib/` is several independent libraries, and which one defines a helper is
# not guessable from its name: `container_engine`, `engine_choice` and `engine_packages` live in
# lib/os.sh, while `engine_mode`, `engine_trust_ca` and `engine_build_isolation` live in
# lib/engine.sh. So "it starts with engine_, and I already source os.sh" is wrong for half of them.
#
# MEASURED 2026-08-16: a call to engine_build_isolation was added to 14-builder-build.sh, which
# sources os.sh and apps.sh but not engine.sh. It died on a real matrix row with
#     14-builder-build.sh: line 76: engine_build_isolation: command not found
#     make: *** [Makefile:406: builder-image] Error 127
# after ~20 minutes of mirroring, on the ONE step that row existed to exercise.
#
# NOTHING OFFLINE COULD SEE IT. `make ci` was green: shellcheck does not resolve `.`-sourced symbols
# across files, and no unit test executes that build path (it needs Maven Central and an engine). The
# unit test for the new helper passed precisely because IT sources engine.sh explicitly -- testing the
# function, not its REACHABILITY from the caller. That gap is this gate.
#
# THREE THINGS THIS GATE LEARNED ABOUT ITSELF, each on a run that looked fine:
#
#   1. It must model SHELL QUOTING, not just strip it. Stripping every quoted span killed the true
#      positive, because the real call is `_iso="$(engine_build_isolation)"` -- a substitution INSIDE
#      double quotes. Inside '...' a `$(` is literal; inside "..." it EXECUTES. So: single-quoted
#      spans are blanked entirely, double-quoted spans are blanked EXCEPT their $( ... ) contents.
#      Without that distinction the gate reported OK over the exact defect it was written for.
#   2. Generic helper names live in PROSE. Before the quoting model it flagged three call sites that
#      were English: "crane not on PATH (run 'make deps')" matched `run`, "(die)" matched `die`.
#   3. ONE pass per script, not one per (script x function). The naive shape is 161 helpers x 154
#      scripts = 24,794 greps and did not finish inside two minutes; this runs in about four seconds.
#
# Polarity note: comments ARE stripped here, and that is the opposite of a must-EXIST gate. A
# commented-out CALL needs no source; a commented-out REQUIRED call is itself the defect.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

python3 - <<'PY'
import glob, os, re, sys

# name -> defining lib, read from the libs themselves. Never an enumerated list: a helper added to a
# lib tomorrow is covered without touching this gate.
defined = {}
for lib in sorted(glob.glob('scripts/lib/*.sh')):
    for m in re.finditer(r'^([a-z_][a-z0-9_]*)\(\)', open(lib, errors='replace').read(), re.M):
        defined[m.group(1)] = os.path.basename(lib)
if not defined:
    print("check-lib-sourcing: FAIL — 0 lib functions found; the extractor is broken"); sys.exit(1)

def executable_text(src):
    """Blank what the shell will NOT execute: comments, and quoted spans -- except a $( ) inside
    double quotes, which the shell really does run. This is the whole reason the gate works."""
    out, i, n = [], 0, len(src)
    q = None          # None | "'" | '"'
    while i < n:
        c = src[i]
        if q is None:
            if c == '#' and (not out or out[-1] in '\n \t;&|('):
                while i < n and src[i] != '\n': i += 1
                continue
            # ⚠️ A PLACEHOLDER, NOT A SPACE. Blanking the opening quote to whitespace makes the
            # next word look like a COMMAND: `"$ENGINE" run --rm` became `          run --rm`, so
            # podman's `run` SUBCOMMAND was read as a call to os.sh's run(). 'Q' is not a separator
            # in CALL and cannot be captured (CALL captures [a-z_]...), so the word after a quoted
            # span is correctly seen as an ARGUMENT.
            if c in '\'"': q = c; out.append('Q'); i += 1; continue
            out.append(c); i += 1; continue
        # inside a quoted span
        if c == '\\' and q == '"': out.append(' '); i += 2; continue
        if c == q: q = None; out.append(' '); i += 1; continue
        if q == '"' and c == '$' and i + 1 < n and src[i+1] == '(':
            depth, j = 0, i
            while j < n:
                if src[j] == '(': depth += 1
                elif src[j] == ')':
                    depth -= 1
                    if depth == 0: j += 1; break
                j += 1
            out.append(src[i:j]); i = j; continue      # KEEP it: this is executed
        out.append(' '); i += 1
    return ''.join(out)

# A real `. "${SCRIPT_DIR}/lib/<x>.sh"` statement: anchored at line start (so a comment, which
# begins with '#', can never match) and tolerant of indentation (06 sources lib/psa.sh inside a
# branch). Optional quotes because both spellings occur in the tree.
# Any source statement, whatever variable spells the prefix -- the tree uses both
# `${SCRIPT_DIR}/lib/x.sh` and `${REPO_ROOT}/scripts/lib/x.sh`, and pinning one spelling produced 93
# false positives. Anchored at line start so a comment (which begins with '#') can never match, and
# tolerant of indentation (06 sources lib/psa.sh inside a branch).
def sourced_libs(src):
    """Which lib files does this file actually pull in?

    Two sources of truth, unioned, because the tree uses two shapes and BOTH are real:

      1. a real source STATEMENT at line start -- take the last `<name>.sh` on the line, so all of
         `. "${SCRIPT_DIR}/lib/os.sh"`, `. scripts/lib/os.sh` and
         `. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"` resolve. That THIRD shape has
         no `lib/` in it at all, and it is how os.sh pulls in state.sh (os.sh:1824).
      2. a `lib/<name>.sh` mention on any other UNCOMMENTED line -- some scripts legitimately source
         inside a `bash -c "..."` string (test-supervisor-kubeconfig.sh:33, test-state-overlay.sh:72).

    COMMENTS ARE EXCLUDED, and that is the whole point. Scanning raw text folded in every comment
    that merely NAMES a lib: os.sh mentions lib/harbor.sh 10 times, all 10 in comments, which
    silently exempted all 249 scripts sourcing os.sh from harbor.sh (and apps.sh, govc.sh, istio.sh,
    state.sh, vcenter.sh) -- a comment in a THIRD file voting on whether a FOURTH was sourced. That
    is how `harbor_credential_settle` shipped as a `command not found` under a green gate.

    ⚠️ Excluding comments also removes the crutch the gate was leaning on: os.sh:1824's bare
    `state.sh` was only ever matched via the `# shellcheck source=scripts/lib/state.sh` comment
    above it. Rule 1 is what replaces it -- without rule 1 this change produces 26 false positives.

    NOT executable_text(): it blanks quoted string CONTENTS, and the path lives inside the quotes
    (it turns `. "${SCRIPT_DIR}/lib/vcenter.sh"` into `.`).
    """
    out = set()
    for line in src.split('\n'):
        if re.match(r'^[ \t]*#', line):
            continue
        m = re.match(r'^[ \t]*(?:\.|source)[ \t]+(.*)$', line)
        if m:
            names = re.findall(r'([a-z_]+\.sh)', m.group(1))
            if names:
                out.add(names[-1])
        out |= set(os.path.basename(x) for x in re.findall(r'lib/[a-z_]+\.sh', line))
    return out


# A real `. "${SCRIPT_DIR}/lib/<x>.sh"` statement: anchored at line start (so a comment, which
# begins with '#', can never match) and tolerant of indentation (06 sources lib/psa.sh inside a
# branch). Optional quotes because both spellings occur in the tree.
# Any source statement, whatever variable spells the prefix -- the tree uses both
# `${SCRIPT_DIR}/lib/x.sh` and `${REPO_ROOT}/scripts/lib/x.sh`, and pinning one spelling produced 93
# false positives. Anchored at line start so a comment (which begins with '#') can never match, and
# tolerant of indentation (06 sources lib/psa.sh inside a branch).
def uncommented_lines(src):
    # Drop FULL-LINE comments only. MEASURED: every false exemption in this tree is a full-line
    # comment (os.sh mentions lib/harbor.sh 10 times, all 10 full-line; tls.sh once, full-line).
    # Deliberately NOT executable_text(): that blanks quoted string CONTENTS, and the lib path lives
    # inside the quotes -- it turned `. "${SCRIPT_DIR}/lib/vcenter.sh"` into `.` and made
    # wcp-service.sh a false positive. Deliberately NOT an anchored source-statement matcher either:
    # some scripts legitimately source inside a `bash -c "..."` string (test-supervisor-kubeconfig.sh
    # :33, :95), and anchoring produced 33 false positives. Lenient about WHERE, strict about
    # COMMENTS -- which is the axis that was actually broken.
    return '\n'.join(l for l in src.split('\n') if not re.match(r'^[ \t]*#', l))

# ⚠️ THE ENV-VAR ASSIGNMENT PREFIX IS PART OF A COMMAND POSITION.
# `HARBOR_SETTLE_FRESH="${X:-0}" harbor_credential_settle --may-reconcile` is a call, but the verb
# follows `= ` rather than a separator, so without the prefix group below it matches NOTHING and the
# call site is INVISIBLE to this gate. MEASURED: that exact line shipped a `command not found`
# (rc 127) at the last step of every `make install-harbor`, while this gate reported
# "OK - 917 call sites ... every one backed by its source". This is the same grammar rules/common/
# hooks.md prescribes for the read-only hook, and for the same reason ("GIT_AUTHOR_NAME=x git commit
# ... env-var assignments sit in front of the verb").
CALL = re.compile(
    r'(?:^|[;&|(]|\$\(|`|&&|\|\||\bthen\b|\belse\b|\bdo\b)'
    # ⚠️ the unquoted value is [^\s;&|()]*, NOT \S*. With \S* the group swallows a command
    # substitution: `REG_CID="$(docker run -d ...)"` normalises to `REG_CID=Q$(docker run`, \S*
    # eats `Q$(docker`, and `run` is then read as a call to os.sh's run(). Excluding ( ) ; & |
    # stops the value crossing into a new command context.
    r'\s*(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|[^\s;&|()]*)\s+)*'
    r'([a-z_][a-z0-9_]*)\s*(?=$|[\s;&|)])', re.M)

rc, scanned, calls = 0, 0, 0
for f in sorted(glob.glob('scripts/*.sh')):
    scanned += 1
    src = open(f, errors='replace').read()
    self_name = os.path.basename(f)
    # ⚠️ MATCH THE SOURCE *STATEMENT*, not any mention of a lib path.
    # Built from a bare `lib/[a-z_]+\.sh` scan of raw src, this folded in every COMMENT that merely
    # MENTIONS a lib -- and os.sh names lib/harbor.sh 10 times in comments, so all 249 scripts that
    # source os.sh were silently exempted from harbor.sh (and apps.sh, govc.sh, istio.sh, state.sh,
    # vcenter.sh): a comment in a THIRD file voted on whether a FOURTH file was sourced.
    #
    # executable_text() is NOT the fix here, though it is on the CALL side: it BLANKS quoted string
    # contents, and the lib path lives inside the quotes. MEASURED -- it turns
    #   . "${SCRIPT_DIR}/lib/vcenter.sh"   into   .
    # which made wcp-service.sh (which DOES source vcenter.sh at :24) a false positive.
    # An anchored source statement is immune to both: a comment line begins with '#', so it cannot
    # match, and nothing is stripped.
    direct = sourced_libs(src)
    have = set(direct)
    for d in list(direct):                                   # one level of transitivity
        p = os.path.join('scripts', 'lib', os.path.basename(d))
        if os.path.isfile(p):
            have |= sourced_libs(open(p, errors='replace').read())
    own = set(re.findall(r'^([a-z_][a-z0-9_]*)\(\)', src, re.M))
    for name in sorted(set(CALL.findall(executable_text(src)))):
        if name not in defined or name in own: continue
        want = defined[name]
        if self_name == want: continue                        # a lib may call its own functions
        calls += 1
        if want not in have:
            print(f"ERROR: {f} calls {name}() but never sources lib/{want}")
            rc = 1

if rc == 0:
    print(f"check-lib-sourcing: OK — {calls} lib-function call site(s) across {scanned} script(s), every one backed by its source")
else:
    print("check-lib-sourcing: that call dies 'command not found' (rc=127) at runtime. Add '. ${SCRIPT_DIR}/lib/<lib>.sh'.")
sys.exit(rc)
PY
