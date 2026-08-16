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
            if c in '\'"': q = c; out.append(' '); i += 1; continue
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

CALL = re.compile(r'(?:^|[;&|(]|\$\(|`|&&|\|\||\bthen\b|\belse\b|\bdo\b)\s*([a-z_][a-z0-9_]*)\s*(?=$|[\s;&|)])', re.M)

rc, scanned, calls = 0, 0, 0
for f in sorted(glob.glob('scripts/*.sh')):
    scanned += 1
    src = open(f, errors='replace').read()
    self_name = os.path.basename(f)
    direct = set(re.findall(r'lib/[a-z_]+\.sh', src))
    have = set(os.path.basename(d) for d in direct)
    for d in list(direct):                                   # one level of transitivity
        p = os.path.join('scripts', d)
        if os.path.isfile(p):
            have |= set(os.path.basename(x) for x in re.findall(r'lib/[a-z_]+\.sh', open(p, errors='replace').read()))
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
