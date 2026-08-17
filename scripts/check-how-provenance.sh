#!/usr/bin/env bash
# check-how-provenance.sh — every acquisition command in .env.example must be one we can actually
# stand behind. A gate, not a reminder.
#
# WHY THIS IS A GATE AND NOT A RULE:
#   The rule already existed ("check facts — no assumptions, no guessing", BLOCKING) and was loaded
#   the whole session. It still got violated: ARGOCD_KUBECONFIG was given a fabricated
#   `# how: vcf cluster kubeconfig get ... --export-file ...`, which is the WRONG subcommand (that
#   fetches a workload-cluster kubeconfig; ArgoCD runs on the Supervisor) for a file nothing in this
#   repo even creates. Prose loaded at the start of a session does not fire at the moment text is
#   generated. A check that runs does.
#
# ⚠️ 2026-08-17 — THE OLD GATE FIRED ON **0 OF 21** VENDOR-CLI LINES, i.e. it had never once looked
# at the class it was built for. Measured on the real .env.example, twice, independently:
#
#     vendor-CLI lines (vcf|kubectl-vsphere|govc|esxcli) ............ 21  (24 occurrences)
#     of which the OLD gate scanned (line literally contains "# how")  0
#
# The cause was the CORPUS, not the matcher: the old scan was `grep -n '# *how'`, so a `# how:`
# HEADER whose command sits on a LATER line was invisible. That is this file's prevailing style —
# :127-128 is `# how: ask your platform admin — or, if you can list namespaces:` followed by
# `#      kubectl get ns -l …`, and the real `vcf cluster kubeconfig get` commands live exactly
# there. A fabricated `vcf` subcommand indented one line under a header escaped with rc=0.
#
# ⚠️ HONEST SCOPE, because the headline reads wider than it is: this scans `# how` BLOCKS. The
# `vcf context create/use` block at ~:950-954 carries NO `# how` token at all and is STILL not
# scanned. Extending to "any line naming a vendor CLI must be graded" was NOT done — its
# false-positive rate over this file's ~19 prose mentions of `vcf` is unmeasured and looks high.
# Measure it before building it.
#
# ⚠️ DO NOT "FIX" THIS BY REQUIRING A COLON AFTER `how`. Measured: the ORIGINAL fabricated line was
# `# how (VKS 9): vcf cluster kubeconfig get …` — the colon sits after the parenthetical, so a
# require-colon matcher CANNOT SEE the exact line this gate exists for.
#
# THE CONTRACT — each acquisition line must be exactly one of:
#   1. a `make <target>` we ship                   -> the target must exist (verified mechanically)
#   2. built from tools WE run                     -> kubectl / jq / crane / helm / argocd / tkn / …
#   3. a VENDOR command we cannot execute here     -> MUST carry its OWN provenance tag
#   4. an ANSWER, not a command                    -> "you choose", "leave unset", a UI location
#
# ⚠️ A VENDOR COMMAND MUST BE GRADED ON ITS OWN LINE — IT DOES NOT INHERIT ITS HEADER'S GRADE.
# An implementation round MEASURED the laundering: appending a fabricated
# `vcf … --export-file /tmp/fabricated` under an already-graded header took `graded` 16→17 and
# rc=0 — the ORIGINAL INCIDENT'S EXACT SHAPE, re-admitted by the first draft of this rewrite. A
# header's grade was written about the command that was there THEN; it cannot vouch for one added
# later. Everything else still inherits, so a graded header covers its own prose.
#
# ⚠️ RESIDUAL, stated rather than implied: `(verified)`/`(inferred)` is UNFALSIFIABLE here. This
# gate enforces DISCLOSURE, not truth — a fabricated command with a false `(verified)` tag is
# accepted by design, because no offline check can run a vendor CLI. A green does not mean "these
# commands work".
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

ENV_FILE="${REPO_ROOT}/.env.example"
[ -f "$ENV_FILE" ] || die "no .env.example"

# argocd and tkn are here because 00-install-prereqs.sh INSTALLS them (install_tkn:345,
# install_argocd:375, both invoked at :398-399) and the operator flow runs them. Their absence was
# 3 of the old gate's 24 WARNs — false positives about tools we ship.
OURS='kubectl|jq|crane|helm|openssl|curl|make|git|base64|awk|sed|grep|podman|docker|kind|yq|argocd|tkn'
VENDOR='vcf|kubectl-vsphere|govc|esxcli'

# ⚠️ COMPOSED AT RUNTIME so a literal `# how:` never appears in this file. The gate reads only
# .env.example today, so this is belt-and-braces against a future widening of the corpus — not a
# claim that the gate currently scans itself.
HOW_TOK="$(printf '# *%s' 'how')"

rc=0
corpus=0        # every line CONSIDERED (headers + continuations)
graded=0        # accepted on a provenance tag (its own, or inherited for a NON-vendor line)
commands=0      # COMMAND-CHECKED against OURS / a real make target
noncmd=0        # not a command: an answer, or wrapped prose inside a how block

in_block=0
block_graded=0

# ANCHORED command-shape discriminator, for a command built from a binary we do NOT recognise.
# Measured over all 1508 comment lines: a flag-bearing test ANYWHERE in the line hits 74 (4%) and
# fires on this file's own prose ("load_env sources this file with `set -a`"); anchored at the
# payload START it hits 7, with 0 false positives on the answers.
#   arm 1: <token> [<subcommand>] -<flag>
#   arm 2: a hyphenated binary name + an argument — a FLAGLESS fabrication is still a command
CMD_SHAPE_FLAG='^[a-z][a-z0-9._/-]*([[:space:]]+[a-z0-9][a-z0-9._-]*)?[[:space:]]+--?[a-z]'
# arm 2: <token> <HYPHENATED-subcommand> — a FLAGLESS fabrication is still a command
#   ('totallymadeup fetch-kubeconfig now'). Measured on the real file: 30 comment lines match
#   this shape, but 27 are `make <hyphenated-target>` which check 4 resolves FIRST, so they
#   never reach here. The residual false-positive surface is ordinary prose that happens to
#   put a hyphenated word second; if one lands inside a how block, grade it or reword it.
CMD_SHAPE_BARE='^[a-z][a-z0-9._/-]*[[:space:]]+[a-z0-9][a-z0-9._]*-[a-z0-9._-]+'

_payload() {   # strip the leading '#', an optional `how…:` prefix, and surrounding whitespace
  local s="$1"
  s="${s#\#}"
  s="${s#"${s%%[![:space:]]*}"}"
  if [[ $s =~ ^how[^:]*:[[:space:]]*(.*)$ ]]; then s="${BASH_REMATCH[1]}"; fi
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "$s"
}

# CASE-INSENSITIVE, and it accepts `lab-verified` — this repo's STRONGEST grade. The first draft
# hardcoded six spellings and dropped the old gate's `grep -qiE`, which REJECTED
# `(Lab-verified 2026-07-22)` while ACCEPTING `(inferred)`: the weakest grade passed and the
# strongest failed. MEASURED: `Lab-verified` and `LAB-VERIFIED` each appear once in .env.example
# but ZERO currently sit on a how line — so this is a latent defect and a real regression against
# the old gate, NOT a live breakage. `${1,,}` lowercases, so one pattern covers every casing.
# ⚠️ NOT `\b`: bash's [[ =~ ]] is POSIX ERE and `\b` is a GNU-grep EXTENSION, so the pattern
# silently matches NOTHING. Measured here: `(inferred)` failed to match with `\b` and matched
# without it — the gate stayed RED on three correctly-graded lines. `([^a-z]|$)` is the portable
# boundary and still rejects `(verifiedGARBAGE`.
_is_graded() {
  local l="${1,,}"
  [[ $l =~ \((lab-)?(verified|inferred)([^a-z]|$) ]] || [[ $l == *unverified* ]] || [[ $l =~ ask\ (your|the)\  ]]
}

_first_token() { local p="$1"; printf '%s' "${p%%[![:alnum:]._/-]*}"; }

_check() {     # _check <lineno> <raw line> <inherited-grade 0|1>
  local lineno="$1" text="$2" inherited="$3" pay tok own=0
  corpus=$((corpus+1))
  pay="$(_payload "$text")"
  _is_graded "$text" && own=1

  # 1. graded ON ITS OWN LINE -> honest, accept whatever it is.
  if [ "$own" = 1 ]; then graded=$((graded+1)); return 0; fi

  # 2. a VENDOR CLI demands its OWN tag — an INHERITED grade does NOT vouch for it (see the header).
  #    ⚠️ BACKTICKED SPANS ARE STRIPPED FIRST. A vendor name inside backticks in a SENTENCE is a
  #    CITATION, not an instruction — .env.example:512 is "…a Supervisor context is created with
  #    `vcf context create …`, the VCF CLI respects…", a clause, not something anyone copy-pastes.
  #    Demanding a per-line grade there produced "`vcf context create …` (inferred), the" — which
  #    reads as if the word "the" is inferred, and the owner rightly asked what it was supposed to
  #    mean. The ORIGINAL incident was a BARE command (`# how (VKS 9): vcf cluster kubeconfig get`),
  #    which this still catches; a fabrication hidden inside backticks is the disclosed residual.
  local bare="${text//\`*\`/}"
  if [[ $bare =~ (^|[^a-z-])($VENDOR)[[:space:]] ]]; then
    log_error ".env.example:${lineno}: a vendor CLI we cannot run here, with NO provenance tag ON THIS LINE."
    log_error "    A header's grade does NOT carry to a vendor command — it was written about the"
    log_error "    command that was there then. Tag THIS line '(verified)' / '(inferred)' / UNVERIFIED."
    rc=1; return 1
  fi

  # 3. inherited grade covers everything else in a graded block (its prose, its notes).
  if [ "$inherited" = 1 ]; then graded=$((graded+1)); return 0; fi

  # 4. names a make target -> it must exist. `[a-z][a-z0-9-]*` so `make -C dir tgt` cannot capture
  #    `-` and report "names 'make -'"; a flag/VAR= form is not a target reference at all.
  if [[ $text =~ (^|[^a-z-])make[[:space:]]+([a-z][a-z0-9-]*) ]]; then
    local tgt="${BASH_REMATCH[2]}"
    commands=$((commands+1))
    grep -qE "^${tgt}:" "${REPO_ROOT}/Makefile" && return 0
    log_error ".env.example:${lineno}: names 'make ${tgt}', which is NOT a Makefile target"
    rc=1; return 1
  fi

  # 5. built from a tool we run — matched on the FIRST TOKEN of the payload, not anywhere in the
  #    line. MEASURED: matching the raw line let an incidental mention in a trailing parenthetical
  #    ("(faster than kubectl get)") launder a fabricated binary, defeating check 6 entirely.
  tok="$(_first_token "$pay")"
  if [[ $tok =~ ^($OURS)$ ]]; then commands=$((commands+1)); return 0; fi

  # 6. COMMAND-SHAPED but built from nothing we recognise -> an invented binary.
  if [[ $pay =~ $CMD_SHAPE_FLAG ]] || [[ $pay =~ $CMD_SHAPE_BARE ]]; then
    log_error ".env.example:${lineno}: looks like a COMMAND ('${pay:0:60}') but names no tool we run,"
    log_error "    no make target, and no vendor CLI — so nothing here can vouch for it. Grade it, or"
    log_error "    rewrite it as an answer if it is not a command."
    rc=1; return 1
  fi

  # 7. not a command: an answer ("you choose", "leave unset") or wrapped prose inside a block.
  noncmd=$((noncmd+1)); return 0
}

lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno+1))

  # The CONVENTIONS legend: bullets that TALK about the convention. `{0,3}` and a REQUIRED space,
  # because `^#[[:space:]]*-` also matched a wrapped `--flag` continuation and killed the block —
  # a shape that exists in this file today.
  if [[ $line =~ ^#[[:space:]]{0,3}-[[:space:]] ]]; then in_block=0; continue; fi

  if [[ $line =~ $HOW_TOK ]]; then
    in_block=1
    block_graded=0; _is_graded "$line" && block_graded=1
    _check "$lineno" "$line" 0
    continue
  fi

  # A CONTINUATION: an indented comment line under a how-header or another continuation. `{3,}`,
  # not `{4,}` — this file's explanatory style is 3-space, and at `{4,}` a fabricated vendor
  # command at 6-space indent inside a 3-space block left the corpus UNCHANGED, i.e. invisible.
  if [ "$in_block" = 1 ] && [[ $line =~ ^#[[:space:]]{3,}[^[:space:]] ]]; then
    _check "$lineno" "$line" "$block_graded"
    continue
  fi

  in_block=0
done < "$ENV_FILE"

# THE DENOMINATOR, printed and reconcilable. The old gate said "all 85 '# how:' commands" while
# every continuation line and every answer had never been command-checked — it called answers
# commands. `noncmd` is deliberately NOT called "answers": it also counts wrapped prose inside a
# how block, and labelling that as answers would overstate what was classified.
if [ "$rc" -eq 0 ]; then
  [ "$corpus" -gt 0 ] || die "check-how-provenance: examined 0 acquisition lines in .env.example — EITHER the convention moved out of .env.example (in which case RETIRE this gate, do not weaken it) OR the file is empty / the matcher no longer matches. Naming both: a zero here is not automatically blindness."
  log_info "check-how-provenance: OK — ${corpus} acquisition line(s): ${commands} command-checked, ${graded} provenance-graded, ${noncmd} non-command (answers + wrapped prose, NOT command-checked)."
else
  log_error "check-how-provenance: an acquisition command is an UNMARKED GUESS. Fix it or grade it."
fi
exit "$rc"
