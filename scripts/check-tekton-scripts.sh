#!/usr/bin/env bash
# check-tekton-scripts.sh — the shell contract for Tekton `script:` blocks.
#
# WHY THIS EXISTS. A six-app KinD e2e died with:
#     env: can't execute 'bash': No such file or directory
# because k8s/tekton/tasks/nodejs-test.yaml declared `#!/usr/bin/env bash` and the nodejs builder
# image is alpine, which has no bash. MEASURED across the six real builder images: java and go
# (debian) HAVE bash; nodejs, python, rust and dotnet (alpine) do NOT. So four of six task scripts
# could never have run, and only the FIRST one to reach the pipeline reported it.
#
# `make lint` was structurally blind: scripts/lint.sh shellchecks scripts/*.sh and repo-root *.sh
# only, so all 11 embedded `script:` blocks were UNLINTED. That blind spot, not the shebang, is the
# defect this gate closes.
#
# TWO ARMS, because neither alone suffices -- measured in both directions:
#
#   A. the SHEBANG must be `#!/bin/sh`. This is a STATIC invariant, legitimately checkable offline:
#      /bin/sh is POSIX-guaranteed, it is Tekton's own default when no shebang is given, and it
#      needs ONE thing where `#!/usr/bin/env sh` needs TWO (measured: with a stripped PATH,
#      `env sh` -> rc=127 while /bin/sh -> rc=0; the `env` layer is also what made the original
#      error name `env` rather than the missing shell).
#
#   B. the BODY must pass `shellcheck -s sh`. Arm A alone cannot see a bashism inside a script that
#      correctly claims `#!/bin/sh`; arm B alone cannot see the original defect at all -- MEASURED:
#      running it on the broken `#!/usr/bin/env bash` script returned rc=0, because it IS valid
#      bash. The image was the problem, not the syntax. (Note: a comment line whose first token
#      after `#` is the linter's own name is parsed as a DIRECTIVE -- SC1073/SC1072 -- so this
#      paragraph deliberately never starts a line with it.)
#
# WHAT THIS CANNOT SEE, stated so nobody reads the green as more than it is:
#   * a base-image bump that removes /bin/sh entirely (distroless, scratch). Only running the
#     interpreter INSIDE the image catches that; not offline, so it belongs in the e2e, not here.
#   * a `script:` block written as a YAML ANCHOR/ALIAS (`script: *shared`) -- the denominator counts
#     `[|>]` forms only, so an alias is neither extracted nor counted, and the gate stays green.
#   * whether the six test SUITES pass under sh. This proves the SHELL layer only; the e2e settles
#     the rest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

TASK_DIR="${REPO_ROOT}/k8s/tekton/tasks"
# `#!/busybox/sh` is ALLOWED for kaniko ONLY. Its image is gcr.io/kaniko-project/executor:*-debug,
# whose shell lives at /busybox/sh and which has no /bin/sh. It is the same coupling-to-one-image
# class as the defect above and is left standing DELIBERATELY, named here so it is a decision rather
# than an oversight: dropping the `-debug` suffix in a Renovate bump breaks it identically.
ALLOW_BUSYBOX_SHEBANG="kaniko-build.yaml"

# PIN the linter, exactly as scripts/lint.sh does. Without this, arm B runs whatever shellcheck the
# runner happens to ship (measured: the GitHub runner image carries 0.9.0 while this repo pins
# 0.11.0). They agree on today's 11 blocks, so this is latent rather than live -- but an ABSENT
# linter would make the gate fail closed while HEADLINING "not POSIX sh" over what is really
# `command not found`, sending the reader to the wrong file.
require_gate_tool shellcheck || exit 1

rc=0
blocks=0
files=0

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

for f in "$TASK_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  files=$((files + 1))
  base="$(basename "$f")"

  # Extract every `script: |` block, preserving one file per block so arm B can lint each
  # independently. The count is reconciled against an INDEPENDENT grep below -- an extractor that
  # silently finds fewer blocks than exist is precisely how this kind of gate passes by not looking.
  python3 - "$f" "$work" "$base" <<'PYEOF'
import re, sys, os
src, work, base = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(src).read()
# A file whose last line has NO trailing newline silently TRUNCATES the final body line -- measured:
# a script ending `[[ 1 == 1 ]]` with no \n extracted without it, so the bashism vanished and the
# gate went green. The denominator counts BLOCKS, so it cannot see a short body.
if not txt.endswith("\n"):
    txt += "\n"
# Accept every block-scalar form, not just `|`. An unsupported form must fail CLOSED (the
# denominator above now counts them), never be skipped.
for i, m in enumerate(re.finditer(r'\n(?P<ind>[ ]+)script:[ \t]*[|>][-+]?[0-9]*[ \t]*\n(?P<body>(?:(?P=ind)[ ].*\n|[ \t]*\n)+)', txt)):
    # DERIVE the content indent from the first non-blank body line. YAML requires only that the body
    # be MORE indented than the key, not exactly two -- measured, a body at +4 with a correct
    # `#!/bin/sh` was reported as shebang `'  #!/bin/sh'` plus a bogus SC1114.
    ind = None
    for l in m.group('body').splitlines():
        if l.strip():
            ind = len(l) - len(l.lstrip()); break
    if ind is None:
        continue
    body = ''.join(l[ind:] if len(l) > ind else l.lstrip() for l in m.group('body').splitlines(True))
    # NEUTRALISE TEKTON'S OWN SUBSTITUTION SYNTAX BEFORE LINTING. `$(params.x)`,
    # `$(workspaces.x.path)` and `$(results.x.path)` are replaced TEXTUALLY BY TEKTON before any
    # shell sees them -- but shellcheck reads them as command substitutions and reports SC2046
    # ("quote this to prevent word splitting") on the deliberately-unquoted ones. MEASURED: that is
    # exactly one finding today, `set -- "$@" $(params.build-args)` in kaniko-build.yaml, which
    # carries a comment explaining that it MUST word-split into separate kaniko flags and is empty
    # when an app needs none. Suppressing SC2046 wholesale would blind arm B to a real unquoted
    # substitution; rewriting Tekton's syntax to an opaque word keeps the rule live for real shell.
    #
    # The pattern requires at least one DOT and NO WHITESPACE, so a genuine command substitution is
    # untouched -- `$(ls tests/*.csproj | head -1)` has spaces and no dotted head, and stays.
    # ANCHORED to Tekton's actual namespaces. The old pattern was "any dotted word with no spaces",
    # which also swallowed REAL command substitutions -- measured: `foo $(get_version.sh)` is a
    # genuine SC2046 (warning, rc=1), but blanking it dropped the finding to SC2086 (info) and the
    # gate went GREEN. A neutralised real substitution is a hidden real finding, which is strictly
    # worse than the false positive it was written to remove.
    body, nsubst = re.subn(
        r'\$\((?:params|workspaces|results|context|steps|tasks|inputs)\.[a-zA-Z0-9_.-]+\)',
        '${TEKTON_SUBST}', body)
    # A VARIABLE, not a literal token. A literal makes `[ "$(params.x)" = "true" ]` become
    # `[ "TEKTON_SUBST" = "true" ]`, which shellcheck correctly reports as SC2050 "this expression is
    # constant" -- trading one false-positive class for another. An opaque variable keeps every
    # comparison lint-meaningful. It is ASSIGNED on the line after the shebang so it is neither
    # constant (SC2050) nor unassigned (SC2154); that shifts reported line numbers by one, which the
    # error message says out loud rather than leaving the reader to discover.
    # ONLY when a substitution was actually replaced: an unconditional assignment makes every
    # substitution-free script report SC2034 "TEKTON_SUBST appears unused" -- a third false-positive
    # class, invented by the fix for the second.
    if nsubst:
        lines = body.splitlines(True)
        if lines and lines[0].startswith('#!'):
            body = lines[0] + 'TEKTON_SUBST=x\n' + ''.join(lines[1:])
        else:
            body = 'TEKTON_SUBST=x\n' + body
    open(os.path.join(work, f"{base}.{i}.sh"), 'w').write(body)
PYEOF
done

# DENOMINATOR, reconciled against a source the extractor does not share.
# `/dev/null` is LOAD-BEARING: with a SINGLE matching file `grep -c` omits the `file:` prefix, so
# the awk -F: sums field 2 of a bare number and yields 0 -- the gate would then die on every run
# blaming the extractor. Latent at 9 files, fatal at 1. And the pattern matches EVERY block scalar
# form (`|`, `|-`, `|+`, `>`, `>-`, `|2`), not just `script: |`: measured, `script: >` and
# `script:  |` (two spaces) each hid a bash shebang AND a `[[ ]]` while the gate reported OK, because
# the regex and the old denominator were blind in the SAME direction.
declared="$(grep -chE '^[[:space:]]*script:[[:space:]]*[|>]' "$TASK_DIR"/*.yaml /dev/null | awk '{s+=$1} END{print s+0}')"
extracted="$(find "$work" -name '*.sh' | wc -l)"
if [ "$extracted" -ne "$declared" ]; then
  log_error "check-tekton-scripts: extracted ${extracted} script block(s) but ${declared} are declared."
  log_error "  The EXTRACTOR is wrong, not the tasks. A gate that silently looks at fewer blocks than"
  log_error "  exist is the failure mode this denominator exists to make impossible."
  exit 1
fi

for s in "$work"/*.sh; do
  [ -f "$s" ] || continue
  blocks=$((blocks + 1))
  b="$(basename "$s")"
  # strip the trailing `.N.sh` the extractor appends -- `${b%%.*}` cuts at the FIRST dot,
  # so a task named `my.task.yaml` would be reported as `my.yaml`.
  origin="${b%.*.sh}"   # the extractor writes <task>.yaml.<N>.sh, so this already ends .yaml
  shebang="$(head -1 "$s")"

  # --- arm A: the shebang ---
  case "$shebang" in
    '#!/bin/sh') : ;;
    '#!/busybox/sh')
      if [ "$origin" != "$ALLOW_BUSYBOX_SHEBANG" ]; then
        log_error "${origin}: '#!/busybox/sh' is allowlisted for ${ALLOW_BUSYBOX_SHEBANG} only."
        rc=1
      fi ;;
    *)
      log_error "${origin}: shebang is '${shebang}' — must be '#!/bin/sh'."
      log_error "  MEASURED: four of six builder images (nodejs, python, rust, dotnet — all alpine)"
      log_error "  have NO bash, so a bash shebang cannot run there. /bin/sh is POSIX-guaranteed and"
      log_error "  is Tekton's own default. If a script genuinely needs bash, prove that image HAS"
      log_error "  bash first — arm B will then force the argument for the bashism itself."
      rc=1 ;;
  esac

  # --- arm B: the body must be POSIX ---
  # --severity=warning keeps EVERY SC3xxx -- SC3040 (pipefail), SC3010 ([[ ]]), SC3030 (arrays),
  # SC3037 (echo -e) are all `warning`, so arm B's portability core is intact. What it costs today is
  # exactly ONE finding, SC2012 (`ls` in a pipeline), and in general SC2086 (unquoted expansion).
  # An earlier version of this comment justified the floor by SC2005 on Tekton's `$(params.x)`;
  # that was wrong twice over -- SC2005 is `style` (below `info`, so the floor is irrelevant to it)
  # and the substitution-neutralisation above removes its trigger anyway.
  if ! out="$(shellcheck -s sh --severity=warning "$s" 2>&1)"; then
    # The +1 applies ONLY to blocks where a Tekton substitution was replaced (the harness then
    # inserts an assignment after the shebang). Measured: all six *-test.yaml blocks have ZERO
    # substitutions, so for exactly the files this gate was written for the offset is +0 -- an
    # unconditional note would send the reader to the wrong line.
    if grep -q '^TEKTON_SUBST=x$' "$s"; then
      log_error "${origin}: not POSIX sh — (line numbers are +1: the harness assigns TEKTON_SUBST after the shebang)"
    else
      log_error "${origin}: not POSIX sh —"
    fi
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  log_info "check-tekton-scripts: OK — ${blocks} script block(s) across ${files} task file(s): shebang + POSIX sh"
else
  log_error "check-tekton-scripts: a Tekton script block would not run in its own image."
fi
exit "$rc"
