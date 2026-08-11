#!/usr/bin/env bash
# test-walk-doc.sh — the demonstrated RED for scripts/walk-doc.sh. Offline, no cluster, no VM.
#
# EVERY CASE HERE IS A DEFECT THAT SHIPPED. walk-doc.sh's first version reported
#     "30 blocks: 25 ran, 0 failed"
# over two complete walks in which essentially nothing worked -- the logs were solid
# `make: command not found` / `kubectl: command not found`. An adversary round measured the cause
# (below, case 1) and eleven more. A walker whose RED nobody has seen is not a measuring instrument,
# it is a green-printing machine, and this file is what stops that recurring.
# shellcheck disable=SC2016  # the backticks below are MARKDOWN FENCES in printf format strings;
# they must stay literal. shellcheck reads them as command substitution.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${SCRIPT_DIR}/walk-doc.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }
# assert <name> <cond-rc> <why-if-it-fails> : takes an ALREADY-EVALUATED status, so no case can
# accidentally read `$?` of the wrong command.
assert() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "$3"; fi; }
doc() { printf '## S\n\n```bash\n%b\n```\n' "$2" > "$T/$1.md"; }
run() { WALK_DOC="$T/$1.md" WALK_EXISTS="${2:-1}" WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1; }

# 1. THE ONE THAT SHIPPED: bash -c exits with its LAST command's status, and walk-doc appends a
#    marker printf that always succeeds -- so every rc was the printf's and no block could ever fail.
doc fail1 'make definitely-no-such-target'
o="$(run fail1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q '1 FAILED'; then c=0; else c=1; fi
assert "a failing block is SEEN" "$c" "rc=$r; the walk cannot detect failure"
doc fail2 'false'
run fail2 >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "a bare 'false' is seen" "$c" "rc=0"
#    ...and the fix must not simply always fail, or it is useless in the other direction.
doc ok1 'true'
o="$(run ok1)"; r=$?
if [ "$r" -eq 0 ] && printf '%s' "$o" | grep -q '0 FAILED'; then c=0; else c=1; fi
assert "a passing block stays green" "$c" "rc=$r"

# 2. Zero extracted blocks reported a clean walk and exit 0 -- reachable via a fence attribute,
#    ```sh, or one invalid UTF-8 byte. This project HAS been in that state (a greedy . under re.S).
printf '## S\n\n```sh\ntrue\n```\n' > "$T/zero.md"
o="$(WALK_DOC="$T/zero.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q REFUSING; then c=0; else c=1; fi
assert "too few blocks REFUSES" "$c" "rc=$r — 'nothing failed' must not equal 'nothing happened'"

# 3. A ```bash nested inside a ````-fenced example is a snippet the reader must NOT run. The
#    regex extractor scheduled `rm -rf /important` for execution.
printf '## S\n\n````markdown\n```bash\nrm -rf /important\n```\n````\n\n```bash\ntrue\n```\n' > "$T/nest.md"
o="$(WALK_DOC="$T/nest.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'rm -rf /important'; then c=1; else c=0; fi
assert "a nested fence is not executed" "$c" "the illustrative snippet was scheduled"

# 4. should_skip matched the RAW block, so a comment WARNING about a command skipped the real
#    command beside it -- and labelled it a teardown block.
doc cmt 'true   # do NOT run make uninstall-all here'
o="$(run cmt)"; if printf '%s' "$o" | grep -q '1 ran'; then c=0; else c=1; fi
assert "a comment mention does not skip" "$c" "the block beside the warning was dropped"

# 5. Neutralizing ONE line of a \-continued command deletes an argument from the survivor and still
#    reports "1 line neutralized" -- it MUTATES what the document says. Refuse instead.
printf '## S\n\n```bash\nsome_cmd --flag \\\n  port-forward-target\n```\n' > "$T/cont.md"
o="$(WALK_DOC="$T/cont.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 WALK_DRY=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'SKIPPED: a TTY-bound command sits inside'; then c=0; else c=1; fi
assert "a continued TTY line refuses" "$c" "it neutralized one line and mutated the command"
doc neut 'kubectl -n x port-forward svc/y 1:1'   # the ordinary case must STILL neutralize
o="$(WALK_DRY=1 run neut)"; if printf '%s' "$o" | grep -q '1 ran'; then c=0; else c=1; fi
assert "an ordinary TTY line neutralizes" "$c" "the whole block was dropped"

# 6. Substituting an UNSET password put an empty string where the placeholder was, deleting the
#    evidence the guard keys on. An empty string is an invented value.
doc pw 'export P=<your SSO password>'
o="$(env -u VCF_CLI_VSPHERE_PASSWORD WALK_DOC="$T/pw.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'must not invent'; then c=0; else c=1; fi
assert "an empty password does not disarm the guard" "$c" "it ran with a blank credential"

# 7. `<[a-z]...>` missed every conventional UPPERCASE placeholder.
doc up 'connect <EXTERNAL-IP>'
o="$(run up)"; if printf '%s' "$o" | grep -q 'must not invent'; then c=0; else c=1; fi
assert "an UPPERCASE placeholder is caught" "$c" "<EXTERNAL-IP> would be run literally"

# 8. WALK_EXISTS defaulted to 1, so a row meant to exercise the INSTALL path skipped all four
#    provisioning blocks and scored green having installed nothing.
env -u WALK_EXISTS WALK_DOC="$T/ok1.md" bash "$W" >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "WALK_EXISTS must be explicit" "$c" "it defaulted"

# 8b. `make harbor-robot` is the fifth already-exists resource. Harbor shows a robot secret ONCE, so
#     the command CANNOT be re-run to recover it -- stopping is correct product behaviour, and a walk
#     must not score it as a document defect. It is its OWN axis: a robot can exist on a lab whose
#     namespace and cluster do not.
env -u WALK_ROBOT_EXISTS WALK_DOC="$T/ok1.md" WALK_EXISTS=1 bash "$W" >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "WALK_ROBOT_EXISTS must be explicit" "$c" "it defaulted"

# 8c. THE ECHO MUST NOT PRINT THE SECRET. walk-doc echoes each block so the log shows what ran --
#     and it echoed the SUBSTITUTED text, so the operator's real SSO password was written into every
#     walk log. Measured: 2 lines per log across two rows. The block must still RECEIVE the value.
printf '## S\n\n```bash\nexport VCF_CLI_VSPHERE_PASSWORD='"'"'<your SSO password>'"'"'\necho "len=${#VCF_CLI_VSPHERE_PASSWORD}"\n```\n' > "$T/sec.md"
o="$(VCF_CLI_VSPHERE_PASSWORD='SuperSecret123' WALK_DOC="$T/sec.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'SuperSecret123'; then c=1; else c=0; fi
assert "the echoed block does NOT leak the secret" "$c" "the real credential was printed into the log"
if printf '%s' "$o" | grep -q 'len=14'; then c=0; else c=1; fi
assert "...and the block still RECEIVES it" "$c" "redaction broke the substitution"

# 9. The cwd was interpolated into `cd '...'`; a balanced quote pair in the path was an injection.
mkdir -p "$T/q"
WALK_DOC="$T/ok1.md" WALK_EXISTS=1 WALK_MIN_BLOCKS=1 \
  WALK_START_DIR="$T/q'; touch $T/PWNED; cd '$T" bash "$W" >/dev/null 2>&1
if [ -f "$T/PWNED" ]; then c=1; else c=0; fi
assert "a quoted cwd cannot inject" "$c" "it executed"

# 10. cwd must still carry across blocks -- `cd vks-airgap-cicd` in the clone block depends on it.
mkdir -p "$T/sub"
printf '## t\n\n```bash\ncd sub\n```\n\n```bash\npwd\n```\n' > "$T/cw.md"
o="$(WALK_DOC="$T/cw.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 WALK_START_DIR="$T" bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q '/sub'; then c=0; else c=1; fi
assert "cwd carries across blocks" "$c" "it reset"

# 10b. A reader has ONE terminal. Isolating each block lost PATH from `make shell-init`, and the
#      next twelve blocks died `kubectl: command not found` -- cascading into "vks.kubeconfig does
#      not exist" for every remaining step. A reader would have hit none of it.
printf '## t\n\n```bash\nexport WALKVAR=carried\nexport PATH="/opt/probe:$PATH"\n```\n\n```bash\necho "V=$WALKVAR"\ncase "$PATH" in /opt/probe:*) echo PATH-CARRIED;; *) echo PATH-LOST;; esac\n```\n' > "$T/env.md"
o="$(WALK_DOC="$T/env.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'V=carried' && printf '%s' "$o" | grep -q 'PATH-CARRIED'; then c=0; else c=1; fi
assert "env and PATH carry across blocks" "$c" "each block was isolated; shell-init's PATH would be lost"

# 11. The real document must still extract completely, and the parser's count must agree with an
#     INDEPENDENT one -- a denominator only the parser produces cannot detect the parser being wrong.
o="$(WALK_DRY=1 WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing bash "$W" 2>&1)"
e="$(printf '%s' "$o" | sed -n 's/^blocks: \([0-9]*\) extracted, \([0-9]*\) counted.*/\1 \2/p')"
read -r n_ext n_indep <<< "$e"
if [ "${n_ext:-0}" = "${n_indep:-x}" ] && [ "${n_ext:-0}" -ge 25 ]; then c=0; else c=1; fi
assert "the real doc: ${n_ext:-?} extracted == ${n_indep:-?} counted" "$c" "extracted=${n_ext:-?} independent=${n_indep:-?}"

# ── LINE BY LINE, and the DOCUMENT's own claims ─────────────────────────────────────────────────
# The walk used to run a whole block as ONE `bash -c`: four commands, one exit code, one lump of
# output. A reader runs them one at a time and looks at each result before typing the next, so the
# unit must be the STATEMENT -- and the failing command must be identifiable.
doc perstmt 'echo alpha\nfalse\necho omega'
o="$(run perstmt)"; r=$?
if printf '%s' "$o" | grep -q 'omega'; then c=0; else c=1; fi
assert "a later statement still RUNS after one fails" "$c" "execution stopped at the failure"
if [ "$(printf '%s' "$o" | grep -c -- '-> rc=')" -ge 3 ]; then c=0; else c=1; fi
assert "each statement reports its OWN rc" "$c" "results are folded into one block rc"
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "...and the block still FAILS" "$c" "a failing statement was swallowed"

# Splitting by statement put the ONE-TERMINAL property at risk, and broke it: `export -p` carries
# only EXPORTED names, so a plain `V=1` on one line was gone by the next. Measured: `echo "$V"`
# printed empty where a reader would see the value.
doc plainvar 'V=carried\necho "value=[$V]"'
o="$(run plainvar)"
if printf '%s' "$o" | grep -q 'value=\[carried\]'; then c=0; else c=1; fi
assert "a NON-EXPORTED variable survives to the next statement" "$c" "only exported names carried"
doc fn 'greet() { echo "hi $1"; }\ngreet there'
o="$(run fn)"
if printf '%s' "$o" | grep -q 'hi there'; then c=0; else c=1; fi
assert "a FUNCTION survives to the next statement" "$c" "functions were not carried"

# The document's contract. walk-doc.sh had ZERO references to `Expect` -- 24 claims about what the
# reader would SEE, checked by nothing, while the walk reported rc=0 and called it a pass.
printf '## S\n\n```bash\necho something else entirely\n```\n\n**Expect:** `all REQUIRED tools present.`\n' > "$T/exp_red.md"
o="$(WALK_DOC="$T/exp_red.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q '1 UNMET'; then c=0; else c=1; fi
assert "an UNMET Expect: claim FAILS the walk" "$c" "rc=$r; the document can lie and still pass"
printf '## S\n\n```bash\nV=present\necho "all REQUIRED tools $V."\n```\n\n**Expect:** `all REQUIRED tools present.`\n' > "$T/exp_green.md"
o="$(WALK_DOC="$T/exp_green.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"; r=$?
if [ "$r" -eq 0 ] && printf '%s' "$o" | grep -q '0 UNMET'; then c=0; else c=1; fi
assert "...and a claim that HOLDS stays green" "$c" "rc=$r; false-REDs on a truthful document"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
