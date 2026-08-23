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
# Scan the LIBS as well as the scripts. Restricting this to scripts/*.sh left a blind spot that
# the gate's OWN rule covers: lib/apps.sh called mirror_target_ref without sourcing lib/mirror.sh,
# and `make e2e-kind` died at seed-gitea on nodejswebapp AFTER seeding two apps. Extending the
# scan surfaced 7 more latent instances (engine.sh, psa.sh, state.sh -> os.sh), all of which
# worked only because callers happened to source os.sh first.
for f in sorted(glob.glob('scripts/*.sh') + glob.glob('scripts/lib/*.sh')):
    scanned += 1
    src = open(f, errors='replace').read()
    self_name = os.path.basename(f)
    # CODE ONLY. This used to scan the whole file, so a `# shellcheck source=scripts/lib/os.sh`
    # COMMENT satisfied the check with no actual source line -- the gate's own explanatory comments
    # could make it blind. RED-PROVEN 2026-08-23: deleting state.sh's real source line left the gate
    # GREEN until this strip was added.
    code = '\n'.join(l for l in src.split('\n') if not l.lstrip().startswith('#'))
    # Match a SOURCE STATEMENT by the file's BASENAME, not by a literal 'lib/' in the path.
    # A lib sourcing a SIBLING writes `. "${_STATE_SH_DIR}/os.sh"` -- correct, and containing no
    # 'lib/' at all, so the old pattern reported every one of them as a violation (a false RED that
    # would push someone to write a wrong path just to satisfy the gate).
    # `.*?` not `\S*?`: a real source line's path can CONTAIN SPACES, because it is usually a
    # command substitution -- os.sh:1687 is `. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"`.
    # \S*? cannot cross those spaces, so transitivity through os.sh -> state.sh found nothing.
    SRC_STMT = re.compile(r'^\s*(?:\.|source)\s+.*?([a-z_]+)\.sh', re.M)
    direct = set(m + '.sh' for m in SRC_STMT.findall(code))
    have = set(direct)
    for d in list(direct):                                   # one level of transitivity
        # `direct` holds BASENAMES now, so the lib dir must be rejoined here. Joining 'scripts'+d
        # yields scripts/os.sh, which does not exist -- transitivity then silently found nothing and
        # the gate accused test-state-overlay.sh of a violation that does not exist (os.sh sources
        # state.sh at its foot, so state_set IS resolvable; measured with command -v).
        p = os.path.join('scripts', 'lib', d)
        if os.path.isfile(p):
            tcode = '\n'.join(l for l in open(p, errors='replace').read().split('\n')
                               if not l.lstrip().startswith('#'))
            have |= set(m + '.sh' for m in SRC_STMT.findall(tcode))
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
