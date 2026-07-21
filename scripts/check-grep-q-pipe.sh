#!/usr/bin/env bash
# check-grep-q-pipe.sh — no FILE-READING producer may pipe into `grep -q` under `set -o pipefail`.
#
# THE BUG, MEASURED. `grep -q` exits at its FIRST match. The producer still holding unissued writes
# then takes SIGPIPE and exits 141, and `set -o pipefail` promotes that to the pipeline's status —
# so a pattern that was FOUND is reported ABSENT. It is a RACE: the producer does not need to block,
# it only needs an outstanding write when grep leaves.
#
#   sed 's/#.*//' scripts/lib/istio.sh | grep -qE '^[[:space:]]*ensure_namespace…'
#     PIPESTATUS=(141 0)   <- grep MATCHED (0). sed died. Pipeline reports non-zero. The gate lies.
#
# WHY IT IS CI-ONLY AND LOOKS LIKE A GHOST. On an idle 24-core box: 0/200. Pinned to ONE cpu (the
# closest local analogue of a 2-vCPU runner): 11/400 = 2.75%. With ~9 rolls per CI job the cumulative
# failure rate is tens of percent — so it "passes locally, fails in CI, passes on rerun", which is
# exactly the shape that gets misfiled as flake. It cost this session SEVEN refuted hypotheses,
# including one where I "refuted" the correct diagnosis by measuring an idle machine.
#
# WHY IT HIT ONLY ONE ROW. Exposure is the bytes the producer still owes AFTER the match:
#   40-install-gitea 1390 · 41-install-tekton 932 · 60-configure-tekton 2730 · 45-install-traefik 2337
#   lib/istio.sh 13802   <- 5x the next, and the only row that ever failed. Not special. Just wider.
#
# IT PRODUCES FALSE GREENS, NOT ONLY FALSE REDS — and that is the reason this is a gate. When the
# match is the OFFENDER (a scan for a forbidden pattern), SIGPIPE silently un-records a real
# violation. Measured on the gate enforcing this repo's headline "docker is NEVER required"
# invariant: 7/300 runs reported CLEAN over a script that plainly required docker.
#
# WHY A GATE AND NOT A RULE. The rule already exists in the portfolio corpus AND is written out in
# THREE places in this repo (99-verify.sh, test-argocd-topology.sh, lib/istio.sh) — and it recurred
# anyway. Worse, one of those three "fixes" was itself wrong (`printf | grep -q`, which still
# SIGPIPEs on a large variable). Prose demonstrably did not hold.
#
# SCOPE, STATED HONESTLY — this covers the UNBOUNDED case only. A producer that READS A FILE can owe
# arbitrarily many bytes, so it is always a latent lie; that is what is banned here. A `printf '%s'
# "$var" | grep -q` is bounded by the variable, and MEASURED that boundary is structural, not a
# hope: below the 64KB pipe buffer the producer's write COMPLETES and SIGPIPE cannot occur
# (4KB: 0/120), and data with NO NEWLINES is immune at ANY size (3MB single-line: 0/120) because
# grep buffers hunting a line terminator and thereby drains the producer. Risk needs >32KB AND
# multiline (82KB multiline: 120/120). ~70 such sites remain and NONE qualifies, so they are
# deliberately NOT converted -- see backlog B52, closed on that measurement.
#
# DO NOT "fix" them with a `<<<` herestring sweep: `printf '%s' "$v"` on an EMPTY value emits zero
# bytes (rc=1) while `<<< "$v"` emits ONE EMPTY LINE, so every nullable pattern ('' ^$ .* ^ $ x*)
# flips rc 1 -> 0. Several of those sites are `if`-conditions in TESTS, where that flip is a silent
# verdict change -- a false green in a test, the worst place for one.
#
# THE FIX, both forms measured 400/400 clean under the same race:
#   grep -q PAT <<< "$(producer)"      # bash spools the herestring; nothing to SIGPIPE
#   producer | grep PAT >/dev/null     # no -q: grep DRAINS its input, so the producer never SIGPIPEs
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# Producers that read a FILE (unbounded output). Composed at runtime for the same reason the
# namespace chokepoint gate composes its patterns: a gate that is a script in the tree it scans must
# not contain the form it hunts, or it flags itself — and the reflex fix (excluding this file) would
# blind it to every future real finding here.
_Q="$(printf 'grep -%s' 'q')"
_FILE_READERS='sed|awk|cut|cat|head|tail|tr|sort|uniq|grep'
# EXTERNAL producers whose output size we do NOT control: a cluster's object list, a box's container
# list. Added 2026-07-19 after an adversary showed the gate was aimed BACKWARDS -- it banned the
# file readers (all converted, all small) while waving through `kubectl get -A | grep -q` and
# `docker ps -a | grep -q`, the only sites in the repo that can plausibly cross the threshold.
# These need no path argument to be unbounded, so they are matched on the command alone.
_EXTERNAL='kubectl|docker|kind|helm|crane|curl|argocd|tkn|podman'

# The two matchers are named ONCE, here, so the positive control below and the scan loop provably
# use the SAME regex. A control that tested a COPY of the pattern would stay green while the real
# matcher rotted — the copy is the thing that drifts.
# The fold is a FUNCTION, named ONCE, so the loop below and its positive control provably use the
# SAME sed expression. A control that tested a COPY of the expression would stay green while the
# real one rotted — the copy is the thing that drifts (same reason the three regexes are named once).
_fold() { sed -e :a -e '/\\$/N; s/\\\n//; ta' "$@"; }

_RE_PIPE="\| *${_Q}"
_RE_FILE="(^|[^a-zA-Z0-9_-])(${_FILE_READERS})[^|]*(\"[^\"]*/[^\"]*\"|[A-Za-z0-9_./-]*/[A-Za-z0-9_.-]+)[^|]*\| *${_Q}"
_RE_EXT="(^|[^a-zA-Z0-9_-])(${_EXTERNAL})[[:space:]][^|]*\| *${_Q}"

# --- POSITIVE CONTROL -----------------------------------------------------------------------
# This gate's only other assertion is `hits == 0` — a NEGATIVE, which passes just as happily when
# the matcher is DEAD as when the tree is clean. MEASURED 2026-07-21 by an adversary: setting
# _FILE_READERS to a string matching nothing still returned rc=0, "OK — scanned 125 script(s)".
# The gate is also UNDECLARED in test-gate-vacuity, so nothing else covers it. So: assert the
# matcher FIRES on a known-bad line and STAYS SILENT on a line this gate deliberately allows,
# before any scan result is trusted. (testing.md: a negative assertion needs a positive control —
# otherwise "the defence worked" and "the threat never fired" are the same green.)
# The fixtures are built from ${_Q} rather than written literally, for the same reason the patterns
# are composed at runtime: this file must not contain the form it hunts, or it flags itself.
_ctl_file="  cat scripts/foo.sh | ${_Q} pattern"
_ctl_ext="  kubectl get pods -A | ${_Q} pattern"
_ctl_ok="  printf '%s' \"\$v\" | ${_Q} pattern"
# A SECOND allowed fixture, carrying a PATH-shaped token. Measured: with only the fixture above,
# widening _FILE_READERS to a bounded producer (adding `printf`) leaves the negative control
# GREEN while the gate starts flagging safe code — it fired only when TWO regressions landed at
# once. This one is sensitive to the reader-list widening on its own.
_ctl_ok2="  printf '%s' \"\$HOME/x\" | ${_Q} pattern"
# The PREFILTER first: it gates the loop, so if it dies no line reaches the two matchers below
# and THEIR controls pass anyway. RED-proven 2026-07-21 with a planted violation: prefilter
# live -> rc=1 "FAILED — 1 site(s)"; prefilter dead -> rc=0 "OK — scanned 1 script(s)".
# Note an INVALID ere makes [[ =~ ]] return 2, which `|| continue` on the prefilter line
# swallows silently under `set -uo pipefail` — so a typo there is fatal-and-quiet too.
if ! [[ $_ctl_file =~ $_RE_PIPE ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the PREFILTER did not fire on a known-bad line. No line can reach the matchers, so every result below is a vacuous green. Do NOT satisfy this by editing the fixture."
fi
if ! [[ $_ctl_file =~ $_RE_FILE ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the file-reader matcher did not fire on a known-bad line. The matcher is dead; every result below would be a vacuous green. Do NOT satisfy this by editing the fixture."
fi
if ! [[ $_ctl_ext =~ $_RE_EXT ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the external-producer matcher did not fire on a known-bad line. The matcher is dead; every result below would be a vacuous green. Do NOT satisfy this by editing the fixture."
fi
if [[ $_ctl_ok  =~ $_RE_FILE ]] || [[ $_ctl_ok  =~ $_RE_EXT ]] \
|| [[ $_ctl_ok2 =~ $_RE_FILE ]] || [[ $_ctl_ok2 =~ $_RE_EXT ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the matcher fired on a bounded \$var producer, which this gate deliberately does NOT judge (see SCOPE). It would now flag safe code."
fi
# FOURTH CONTROL — THE FOLD ITSELF. The three above prove the MATCHERS are alive; none of them
# proves the fold still JOINS, and the fold is what makes a two-line violation visible at all.
# The gap is not theoretical: a fold that keeps EMITTING but stops JOINING (drop the `s/\\\n//`,
# keep `:a … ta`) leaves every matcher healthy AND raises `items`, so the denominator guard below
# passes MORE comfortably while the continuation-line violation is silently missed — MEASURED
# (2026-07-21): real fold -> items=3 HITS=1 (caught); rotted fold -> items=4 HITS=0 (MISSED).
# That is exactly the decorative state line 125 warns about, so it gets a control like the rest.
# THREE lines, not two, and that is load-bearing: a TWO-line fixture cannot distinguish "joins ONE
# continuation" from "joins ALL of them", so the realistic rot of dropping the `:a`/`ta` LOOP (which
# still joins exactly one) slips through. MEASURED across three rots — join-removed, loop-removed,
# sed-dead — a 2-line fixture MISSES loop-removed; a 3-line fixture catches all three.
# THROUGH A FILE ARGUMENT, NOT STDIN — this is not stylistic, it is the whole point of the control.
# The scan loop calls `_fold "$f"`; piping the fixture in would exercise a DIFFERENT invocation mode,
# so a rot in the file-argument path would be invisible to every control here. MEASURED: dropping
# `"$@"` from _fold (the likeliest slip in a fresh extraction) makes `_fold "$f"` read STDIN — which
# inside the outer `while … done <<EOF` is THE HEREDOC HOLDING THE FILE LIST. The gate then reports
# `OK — scanned 1 script(s), 125 lines examined` (it "scanned" the filenames), with all four controls
# green, both denominator guards green, and a planted two-line violation MISSED. Routing the fixture
# through a real file is what makes this control cover the invocation as well as the expression.
_ctl_tmp="$(mktemp)"
printf '  cat \\\n     scripts/foo.sh 2>/dev/null \\\n       | %s pattern\n' "$_Q" > "$_ctl_tmp"
_ctl_fold="$(_fold "$_ctl_tmp")"
rm -f "$_ctl_tmp"
# ⚠️ THE NEWLINE TEST IS THE LOAD-BEARING HALF, and asserting only the regex is DECORATIVE — proven
# by RED-proof, 2026-07-21. `_RE_FILE`'s `[^|]*` matches a NEWLINE too, so the UNJOINED two-line
# fixture still satisfies the regex and the control passes on a fold that has stopped joining.
# What actually discriminates is that the fold collapsed the two lines into ONE.
# EMPTINESS FIRST, and the order is load-bearing. Without this arm a MISSING or broken sed reaches
# the newline test, finds no newline in an EMPTY string, falls through to the regex arm, and dies
# telling the operator the fold EXPRESSION rotted — while explicitly telling them the items guard
# "CANNOT catch this", when the items guard is exactly what was built for it. An error that names
# the wrong cause is worse than a crash, and this control sits ABOVE that guard so it preempts it.
[ -n "$_ctl_fold" ] || die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the fold produced NO OUTPUT AT ALL for a file it was handed. This is NOT an expression rot; it is one of two things: (a) sed is missing, not executable, or failing outright — check it is on PATH and runnable; or (b) _fold has lost its \"\$@\", so it reads STDIN instead of the file it was given (in the scan loop that STDIN is the heredoc holding the FILE LIST, and the gate then 'scans' filenames while missing every real violation)."
case $_ctl_fold in
  *$'\n'*) die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the FOLD no longer JOINS backslash-continuations (its output still contains a newline), so a violation written across two lines (which is how the real CI failure was written) is INVISIBLE. The 'items' guard CANNOT catch this — a non-joining fold still emits lines and raises items. Do NOT satisfy this by editing the fixture." ;;
esac
if ! [[ $_ctl_fold =~ $_RE_FILE ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the FOLD no longer JOINS backslash-continuations, so a violation written across two lines (which is how the real CI failure was written) is INVISIBLE to every matcher. The 'items' guard below CANNOT catch this — a non-joining fold still emits lines and raises items. Do NOT satisfy this by editing the fixture."
fi

scanned=0; hits=0; items=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  n=0
  # FOLD BACKSLASH-CONTINUATIONS FIRST. The real CI failure was written across two lines —
  #     if sed 's/#.*//' "scripts/${script}" 2>/dev/null \
  #          | grep -qE "…"; then
  # so a line-at-a-time scan sees `| grep -q` with NO producer on that line and waves it through.
  # A first version of this gate did exactly that and passed BOTH RED-proofs; it was decorative.
  # `sed -e :a -e '/\\$/N; s/\\\n//; ta'` joins each continued logical line into one.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Builtins, not `printf | sed | cut` + `printf | grep` — that forked FOUR processes per line.
    # The strip is correctness-critical here, not just speed: this file's own header contains the
    # literal bug form, so a broken strip makes the gate flag itself (loud, safe).
    _s=${line#"${line%%[![:space:]]*}"}
    case $_s in '#'*) continue ;; esac
    # Counted HERE — after the fold and after the comment skip — so `items` is the number of lines
    # that actually reached the matchers. See the guard below for what this does and does NOT prove.
    items=$((items + 1))
    [[ $line =~ $_RE_PIPE ]] || continue
    # A file-reading producer with a PATH-shaped argument before the pipe. `"$x"`/`$x` alone is a
    # variable, which this gate deliberately does not judge (see SCOPE above).
    # The prefix is a NON-WORD boundary, not a command separator: the producer is routinely preceded
    # by `if `/`elif `/`! `/`while `, and requiring `[|;&(]` missed every one of them (RED-proven).
    # RHS UNQUOTED — a quoted RHS is a LITERAL comparison, which matches nothing and would make this
    # gate a vacuous green. The POSITIVE CONTROL above is what catches that; it did not exist before
    # 2026-07-21, and a dead matcher here returned rc=0 "OK — scanned 125 script(s)".
    if [[ $line =~ $_RE_FILE ]] || [[ $line =~ $_RE_EXT ]]; then
      log_error "  ${f}: an UNBOUNDED producer (a file reader, or kubectl/docker/kind/helm/crane/curl) pipes into ${_Q} — under pipefail this reports a FOUND pattern as ABSENT, at random, and reports a real violation as CLEAN."
      log_error "      ${line}"
      n=$((n + 1))
    fi
  done < <(_fold "$f")
  hits=$((hits + n))
done <<EOF
$(git ls-files '*.sh' 2>/dev/null)
EOF
# CORPUS IS EVERY TRACKED *.sh, not 'scripts/*.sh'. The narrower pathspec missed
# bootstrap-jumpbox.sh, which lint.sh explicitly DOES lint and which carries `set -euo pipefail` —
# the precondition for the exact bug this gate exists to catch, on the bare Photon/Ubuntu box where
# it is most expensive to debug. Latent when found (that file had no `| grep` of any kind), so this
# is a scope fix, not a bug fix. If the FILE count below is not 126, the pathspec did not take.
# Do NOT pin the LINE count anywhere durable: this gate's corpus contains its own source and its
# siblings, so editing them moves it — it drifted 9552 -> 9575 during this very change. The file
# count is the stable claim; the line count is self-referential.

# TWO DENOMINATORS, AND THEY PROVE DIFFERENT THINGS. Read this before "strengthening" either.
#
#   scanned — files opened. Guards a BROKEN PATHSPEC.
#   items   — lines that reached the matchers, post-fold and post-comment-skip. Guards TOTAL FOLD
#             DEATH ONLY: `sed` absent, or an expression so broken it emits nothing. Then the
#             process substitution yields NOTHING, every file contributes zero lines, and the gate
#             reports a serene green over ZERO examined lines. MEASURED (2026-07-21, `sed` shimmed
#             to exit 127): before this guard, `scanned 125, items 0, rc=0`.
#             ⚠️ It does NOT prove the fold still JOINS. A fold that keeps emitting but stops
#             joining RAISES `items` and passes this guard MORE comfortably while the two-line
#             violation goes missed (measured; the exact counts are fixture-shaped, the RELATION
#             is the point — items up, HITS to 0). That is the FOURTH CONTROL's job, not this one.
#             ⚠️ It does NOT prove the loop READ THE FILES either: with `"$@"` dropped from _fold,
#             `items` was 125 — it had counted the FILENAMES out of the heredoc, not file content.
#             ⚠️ And it does NOT prove the corpus has content (see below).
#
# ⚠️ NEITHER GUARD PROVES THE CORPUS HAS CONTENT, and `items` CANNOT be made to — do not try.
# This gate's corpus contains its OWN SOURCE and lib/os.sh (which it sources), so it can only run at
# all when those two are non-empty, and those two alone supply items. MEASURED: with every other
# tracked *.sh emptied, `items` floors at 372, so an items-based vacuity guard is unfireable by
# construction — "a comment with an if in front of it". That is also why this gate is listed
# NOT STARVABLE in test-gate-vacuity.sh; read the note there before declaring it.
[ "$scanned" -gt 0 ] || die "check-grep-q-pipe: scanned 0 files — the pathspec is broken and a green here would mean nothing."
[ "$items" -gt 0 ] || die "check-grep-q-pipe: examined 0 lines across ${scanned} file(s) — the fold pipeline (sed) produced nothing, so no line ever reached the matchers. A green here would be vacuous. Check that sed exists and its expression still folds backslash-continuations."

# SELF-TEST: this file must contribute zero hits, or the runtime composition has been undone.
if [ "$hits" -gt 0 ]; then
  log_error "check-grep-q-pipe: FAILED — ${hits} site(s) across ${scanned} scanned file(s) (${items} lines examined)."
  log_error "  Fix with EITHER form (both measured 400/400 clean under the race):"
  log_error "    grep -q PAT <<< \"\$(producer)\"       # bash spools it; nothing to SIGPIPE"
  log_error "    producer | grep PAT >/dev/null       # no -q: grep drains, producer never SIGPIPEs"
  exit 1
fi
log_info "check-grep-q-pipe: OK — no FILE-READING or EXTERNAL (kubectl/docker/kind/helm/crane/curl) producer pipes into ${_Q} (scanned ${scanned} script(s), ${items} lines examined). SCOPE: bounded \$var producers are NOT judged — measured structurally safe (<32KB or single-line); see the header before \"fixing\" them."
