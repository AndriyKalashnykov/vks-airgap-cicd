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

# 2. "Nothing failed" must not equal "nothing happened". TWO ways that can happen, and they need
#    separate cases -- the floor used to be a hand-typed constant (WALK_MIN_BLOCKS, default 20),
#    which caught neither honestly: this fixture "passed" only because 1 < 20, while its own comment
#    claimed to be testing ZERO extracted blocks. The floor is now DERIVED (parser vs an independent
#    source-side count), so both properties get a real case.
#
# 2a. ZERO blocks -- the derived floor alone would read `0 >= 0` and PASS.
printf '## S\n\njust prose, no fences at all\n' > "$T/zero.md"
o="$(WALK_DOC="$T/zero.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q 'ZERO command blocks'; then c=0; else c=1; fi
assert "ZERO blocks REFUSES" "$c" "rc=$r — 'nothing failed' must not equal 'nothing happened'"

# 2c. A CLOSING </details> NOT ALONE ON ITS LINE silently un-runs THE REST OF THE DOCUMENT.
#     The parser resets its details state only on a line STARTING with </details>, so `prose.</details>`
#     leaves it open forever. MEASURED before the fix on a 3-block fixture: rc=0, "3 extracted, 3
#     counted independently", "3 Expect, 3 parsed" -- every counter reconciling -- and 1 of 3 ran.
#     On a real row one collapsed note at step 2 would silently skip steps 3-7 and report green.
#     REFUSED rather than guessed: closing on any occurrence would remove the silent skip but
#     introduce the opposite hazard, RUNNING a block that is an alternative for another scenario.
printf '## A\n\n```bash\necho ONE\n```\n\n## B\n\n<details><summary>n</summary>\nprose.</details>\n\n```bash\necho TWO\n```\n' > "$T/badclose.md"
o="$(WALK_DOC="$T/badclose.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q 'not alone on its line'; then c=0; else c=1; fi
assert "a </details> not alone on its line REFUSES" "$c" "rc=$r — the rest of the document would be silently skipped"

# 2b. A block PRESENT IN THE SOURCE and INVISIBLE TO THE PARSER. A blockquoted fence is the real
#     instance (measured in scenario-2: the ingress step's `make istio-preflight` was silently
#     dropped while `14 extracted, 14 counted` reconciled perfectly). A hand-typed constant can
#     NEVER catch this -- the human types the number to match whatever the parser happened to see.
printf '## S\n\n```bash\ntrue\n```\n\n> ```bash\n> echo INVISIBLE\n> ```\n' > "$T/quoted.md"
o="$(WALK_DOC="$T/quoted.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q 'BLOCKQUOTED fence'; then c=0; else c=1; fi
assert "a BLOCKQUOTED fence REFUSES" "$c" "rc=$r — the parser cannot see it, so the floor must"
if printf '%s' "$o" | grep -q 'INVISIBLE'; then c=1; else c=0; fi
assert "...and it was indeed never executed" "$c" "the blockquoted block ran"

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

# A `\`-CONTINUATION MUST STAY ONE COMMAND. `bash -n` accepts a trailing backslash as complete, so
# the completeness test alone CUT one into pieces. Measured on a real walk: the runbook's three-line
# `vcf context create ... \` ran as THREE commands (`accepts at most 1 arg(s), received 2`, then
# `--ca-certificate: command not found`, then `--username: command not found`) -- the walk executed
# something no reader ever would, which makes every verdict about it worthless.
doc cont 'printf %s-%s-%s one \\\n  two \\\n  three'
o="$(run cont)"
if printf '%s' "$o" | grep -q 'one-two-three'; then c=0; else c=1; fi
assert "a backslash-continuation stays ONE command" "$c" "the continuation was split into pieces"
if [ "$(printf '%s' "$o" | grep -c -- '-> rc=')" -eq 1 ]; then c=0; else c=1; fi
assert "...and reports ONE rc, not one per line" "$c" "it ran as several statements"

# A CLAIM DESCRIBES THE STEP, NOT ONE BLOCK OF IT. The document attaches Expect: to a step, and a
# step often has several blocks; checking only the preceding block produced a FALSE UNMET on text
# plainly present in the log. (The original example was scenario-1 step 4, whose claim has since been
# moved to sit directly after the block that produces it -- but the mechanism is still load-bearing
# for the claims that legitimately describe an EARLIER block in the same step.)
printf '## S\n\n```bash\necho "seven secrets generated"\n```\n\n```bash\necho "second block"\n```\n\n**Expect:** `seven secrets generated`\n' > "$T/step.md"
o="$(WALK_DOC="$T/step.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"; r=$?
if [ "$r" -eq 0 ] && printf '%s' "$o" | grep -q '0 UNMET'; then c=0; else c=1; fi
assert "a claim is checked against the whole STEP" "$c" "rc=$r; a claim about an earlier block false-UNMETs"

# A COLLAPSED <details> IS AN ALTERNATIVE, NOT A STEP. Its summary says who it is for, and a reader
# expands it only if that is them. MEASURED on row 1: the walker ran the block under "No Supervisor
# access (the Scenario-2 tenant)? Ask the vcf CLI instead" during a Scenario-1 walk; it failed with
# exactly the `pinniped-info` error the document PREDICTS two lines later, and the route the
# document actually prescribes had already succeeded.
printf '## S\n\n<details><summary>Not you? do it another way</summary>\n\n```bash\necho MUST_NOT_RUN\n```\n</details>\n\n```bash\necho main_path\n```\n' > "$T/det.md"
o="$(WALK_DOC="$T/det.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'MUST_NOT_RUN'; then c=1; else c=0; fi
assert "a block inside <details> is NOT executed" "$c" "an alternative for another scenario was run"
if printf '%s' "$o" | grep -q 'main_path'; then c=0; else c=1; fi
assert "...and the main path still runs" "$c" "skipping the alternative also skipped the real step"

# THE DOCUMENT INSTRUCTS THROUGH TABLES, NOT ONLY COMMANDS. Step 6's "set in ./.env" table says to
# change VKS_AUTH_METHOD back to `kubeconfig`; ignoring it left every later guest-cluster check
# pointed at the SUPERVISOR, where they failed with true-but-irrelevant errors that named neither
# the variable nor the cluster. That one missed cell cost Steps 7-13 of a row.
printf '## S\n\n**set in `./.env`:**\n\n| key | example | how |\n|---|---|---|\n| `WALK_TBL_DEMO` | `kubeconfig` | set it |\n\n```bash\necho "mode=[$WALK_TBL_DEMO]"\n```\n' > "$T/tbl.md"
o="$(WALK_DOC="$T/tbl.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'mode=\[kubeconfig\]'; then c=0; else c=1; fi
assert "a value the doc sets in a TABLE reaches the commands" "$c" "table instructions are ignored"

# A LATER ROW MUST OVERRIDE AN EARLIER ONE. Step 5's table sets VKS_AUTH_METHOD=vcf and Step 6 sets
# it back to kubeconfig. Comparing against "is it set right now" made Step 6 lose to the walker's
# OWN earlier export, and report it as "the harness supplied vcf" -- a false attribution that sends
# the reader to debug the harness. So the feature did not do the thing it was built for.
printf '## A\n\n| key | example | how |\n|---|---|---|\n| `WALK_TBL_SEQ` | `vcf` | first |\n\n```bash\ntrue\n```\n\n## B\n\n| key | example | how |\n|---|---|---|\n| `WALK_TBL_SEQ` | `kubeconfig` | later |\n\n```bash\necho "mode=[$WALK_TBL_SEQ]"\n```\n' > "$T/seq.md"
o="$(env -u WALK_TBL_SEQ WALK_DOC="$T/seq.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=2 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'mode=\[kubeconfig\]'; then c=0; else c=1; fi
assert "a LATER table row overrides an EARLIER one" "$c" "the doc's later instruction lost to its own earlier row"

# ...but a value the HARNESS supplied before the walk still outranks the document's example.
o="$(WALK_TBL_SEQ=harness WALK_DOC="$T/seq.md" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=2 bash "$W" 2>&1)"
if printf '%s' "$o" | grep -q 'mode=\[harness\]'; then c=0; else c=1; fi
assert "...while a PRE-WALK harness value still wins" "$c" "the doc's example overwrote a lab-specific value"

# A VALUE NO DUAL-PARSER .env CAN HOLD MUST NOT BE WRITTEN. .env is read by BOTH `make -include`
# and a shell `source`, and no quoting satisfies both. MEASURED on the real document: an italic
# placeholder (`*your value*`) and a LEGITIMATE value with a space both produced a shell syntax
# error, and a syntax error ABORTS THE REST OF THE FILE -- 20 later keys were never assigned, and
# every make target that loads the env died `Error 127` naming neither the file nor the variable.
D="$T/poison"; mkdir -p "$D"; : > "$D/.env"
printf '## S\n\n| key | example | how |\n|---|---|---|\n| `WALK_TBL_PH` | `*your value*` | supply it |\n| `WALK_TBL_SP` | `a b` | legit, has a space |\n| `WALK_TBL_OK` | `plain` | safe |\n\n```bash\ntrue\n```\n' > "$T/poison.md"
o="$(WALK_DOC="$T/poison.md" WALK_START_DIR="$D" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"
if bash -c "set -e; . '$D/.env'" 2>/dev/null; then c=0; else c=1; fi
assert "the written .env still sources under set -e" "$c" "the walk poisoned .env; every later make target dies Error 127"
if grep -qE '^(WALK_TBL_PH|WALK_TBL_SP)=' "$D/.env"; then c=1; else c=0; fi
assert "...because unwritable values are NOT written" "$c" "a placeholder or space-bearing value was persisted"
if printf '%s' "$o" | grep -q 'BY HAND'; then c=0; else c=1; fi
assert "...and the reader is told to set them by hand" "$c" "the row was dropped silently"

# 13. walk-include. A scenario that DELEGATES shared steps to a common file must EXECUTE them.
#     Without expansion the walk silently skipped every shared block AND both counters still
#     reconciled -- measured: a 2-block doc linking a 2-block file printed
#     "blocks: 2 extracted, 2 counted independently", 0 claims, EXIT 0.
I="$T/inc"; mkdir -p "$I"
# The block must actually PRODUCE the claim's literal, or the walk fails on an UNMET Expect and the
# case would be measuring its own fixture rather than the include. (It cost two FAILs to learn.)
printf '## S. Shared\n\n```bash\necho walkincludealpha\n```\n\n**Expect:** `walkincludealpha` somewhere.\n\n```bash\ntrue\n```\n' > "$I/common.md"
inc_main() { printf '# M\n\n%s\n\n## 1. Own\n\n```bash\ntrue\n```\n' "$1" > "$I/main.md"; }
inc_run() { WALK_DOC="$I/main.md" WALK_START_DIR="$I" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 \
            WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1; }

inc_main '<!-- walk-include: common.md -->'
o="$(inc_run)"; r=$?
if [ "$r" -eq 0 ] && printf '%s' "$o" | grep -q 'blocks: 3 extracted'; then c=0; else c=1; fi
assert "walk-include EXECUTES the shared blocks" "$c" "rc=$r; the include was not followed"

#     THE LOAD-BEARING HALF. The Expect floor must count the SOURCE files, never the parser's own
#     expansion: an expansion-side count makes an extractor death read `0 >= 0` PASS, where a
#     source-side count makes the same death read `0 >= N` and REFUSE. main.md carries ZERO Expect
#     lines, so if the floor read only $DOC this would be 0 and pass vacuously.
if printf '%s' "$o" | grep -q '1 Expect: lines in the doc'; then c=0; else c=1; fi
assert "...and the Expect floor counts the INCLUDED file's claims" "$c" "the floor read only \$DOC — it is self-certifying"

inc_main '<!-- walk-include: nope.md -->'
inc_run >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "an UNRESOLVABLE include refuses" "$c" "rc=0 — a missing shared file was walked past"

printf '## D\n\n<!-- walk-include: deeper.md -->\n\n```bash\ntrue\n```\n' > "$I/nested.md"; : > "$I/deeper.md"
inc_main '<!-- walk-include: nested.md -->'
inc_run >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "a NESTED include refuses (depth 1 only)" "$c" "rc=0 — it recursed"

inc_main '<!-- walk-include: common.md -->
<!-- walk-include: common.md -->'
inc_run >/dev/null 2>&1; r=$?
if [ "$r" -ne 0 ]; then c=0; else c=1; fi
assert "a REPEATED include refuses" "$c" "rc=0 — a step would run twice"

# 14. The extractor's `|| { EXTRACTOR FAILED }` was DEAD CODE: mapfile's exit status is its OWN,
#     never the substituted process's. Measured both ways -- a death before any output read as
#     len=0, and a death AFTER one row read as a TRUNCATED PARSE THAT LOOKED LIKE SUCCESS. Only a
#     terminal sentinel can tell "finished" from "died partway".
printf '# M\n\n## 1. A\n\n```bash\ntrue\n```\n\n## 2. B\n\n```bash\ntrue\n' > "$T/trunc.md"
o="$(WALK_DOC="$T/trunc.md" WALK_START_DIR="$T" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 \
     WALK_ISTIO=existing WALK_MIN_BLOCKS=1 bash "$W" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q 'did not run to completion'; then c=0; else c=1; fi
assert "a TRUNCATED extractor parse refuses" "$c" "rc=$r; a partial parse was reported as a walk"

# 15. A POSITIONAL argument used to be silently ignored, so `walk-doc.sh docs/scenario-2.md`
#     walked the DEFAULT document and reported ITS numbers. Measured 2026-08-16: a one-block probe
#     invoked that way reported scenario-1's "40 extracted, 29 Expect". A wrong answer delivered
#     confidently is worse than an error, so it must REFUSE -- and the refusal must name WALK_DOC.
printf '# P\n\n## 1. A\n\n```bash\ntrue\n```\n' > "$T/pos.md"
o="$(WALK_DOC="$T/pos.md" WALK_START_DIR="$T" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 \
     WALK_ISTIO=existing WALK_MIN_BLOCKS=1 WALK_DRY=1 bash "$W" "$T/pos.md" 2>&1)"; r=$?
if [ "$r" -ne 0 ] && printf '%s' "$o" | grep -q 'WALK_DOC'; then c=0; else c=1; fi
assert "a POSITIONAL argument refuses, and says WALK_DOC" "$c" "rc=$r; it was ignored silently"

# ...and the no-argument form still works, or the guard would have broken every real caller.
o="$(WALK_DOC="$T/pos.md" WALK_START_DIR="$T" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 \
     WALK_ISTIO=existing WALK_MIN_BLOCKS=1 WALK_DRY=1 bash "$W" 2>&1)"; r=$?
if [ "$r" -eq 0 ]; then c=0; else c=1; fi
assert "...and the NO-argument form still walks" "$c" "rc=$r; the guard broke the real callers"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
