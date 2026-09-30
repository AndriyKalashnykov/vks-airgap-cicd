#!/usr/bin/env bash
# Every jdx/mise-action call site must be PINNED and BOT-TRACKED, all pins must agree, and
# .mise.toml's declared floor must not exceed them.
#
# WHY THIS EXISTS (2026-09-30). Two independent failures, both silent:
#
#   1. An UNPINNED site resolves https://mise.jdx.dev/VERSION at RUN TIME. That endpoint leads
#      release PUBLICATION by hours (v2026.9.3: tag 06:50:57Z, published 13:55:29Z), so a resolve
#      inside that window downloads a release that does not exist yet. That is the 2026-09-08
#      outage: the job died in SETUP and `make secrets-scan` was SKIPPED on every PR.
#      e2e-kind-smoke.yml carried that live hazard for 22 days while renovate.json's own manager
#      description claimed "CI resolves no 'latest' at run time".
#
#   2. A pin the customManager cannot SEE is worse than no pin: it works forever and is never
#      bumped again. MEASURED against the real pattern -- `version: "2026.9.2"` (quoted),
#      `version: v2026.9.2` (v-prefixed, which is how the release TAGS are spelled, so copy-paste
#      lands there), or a 5th line between the `# renovate:` comment and `version:` each yield
#      ZERO matches while the action itself works fine.
#
# ⚠️ THIS GATE'S FIRST DRAFT WAS REFUTED, and the refutation is why it is shaped like this.
# It counted `uses: jdx/mise-action` LINES against customManager MATCHES and required equality.
# Those are DIFFERENT POPULATIONS, so their equality was not evidence. MEASURED false green:
# a mise step that loses its `version:` lets its `# renovate:` annotation SLIDE FORWARD onto a
# NEIGHBOURING action's `version:` (the pattern has no depName anchor and tolerates 1-4
# intervening lines), yielding "1 step(s), all 1 tracked, all pinned to 3.16.2" -- helm's
# version -- rc=0, over exactly the unpinned shape this gate exists to catch. Renovate is fooled
# identically. It also FALSE-RED'd on any OTHER tool carrying a `# renovate:` + `version:` in a
# workflow (the repo's convention everywhere else), and its only remedy was to DELETE that
# annotation -- a gate whose only fix degrades the artifact is refuted on sight (gates.md).
#
# So a match counts ONLY when the nearest `uses:` line preceding the captured `version:` is
# jdx/mise-action. That is block shape, not arithmetic, and it is what makes the count mean
# something.
#
# WHY NOT "assert the pins are equal" (the obvious gate): when a site is silently untracked,
# Renovate bumps the sites it CAN see and an equality gate goes RED with no bot-reachable fix --
# a stall, exactly what renovate.json's go-toolchain and kubectl rule descriptions warn about.
#
# The pattern is READ FROM renovate.json, never re-typed here: a second copy is the drift this
# gate exists to prevent. Selection is STRUCTURAL (which customManager targets .github/workflows),
# never on the description PROSE -- a first draft keyed on `.description | test("mise")` and could
# be broken by rewording it, or crashed with a raw node stack trace by a sibling manager whose
# description merely contained the word "compromise".
#
# It needs `node` because the pattern uses `(?<name>` named groups, which Python's `re` rejects
# outright (PatternError: unknown extension ?<d) -- hand-translating `(?<` -> `(?P<` would be a
# third copy of the pattern.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$REPO_ROOT"

# vkey_jq — the repo's shared version-ordering key, for the floor<=pin arm at the bottom.
# NOT `sort -V`: test-vks-package-version-sort.sh bans it in product code because it is
# OS-DEPENDENT (Photon ships toybox, CI ships GNU) and reintroduces a divergence this repo
# already paid for. That test caught this gate using it — read its FAIL text before "simplifying"
# the comparison below back to a sort.
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

fail=0

command -v node >/dev/null 2>&1 || {
  echo "ERROR: check-mise-pins needs node (the customManager pattern uses (?<name> groups," >&2
  echo "       which Python's re cannot compile). It is pinned in .mise.toml — run 'make deps'." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "ERROR: check-mise-pins needs jq (pinned in .mise.toml)." >&2; exit 1; }

# STRUCTURAL selection: the one customManager whose file patterns target .github/workflows.
pattern="$(jq -r '
  [ .customManagers[]?
    | select([ (.managerFilePatterns // .fileMatch // [])[] | test("workflows") ] | any)
    | .matchStrings[0]
  ] | .[]
' renovate.json 2>/dev/null || true)"

if [ -z "$pattern" ]; then
  echo "ERROR: no customManager in renovate.json targets .github/workflows." >&2
  echo "       This gate REFUSES to guess the pattern — a second copy is the drift it guards." >&2
  exit 1
fi
if [ "$(printf '%s\n' "$pattern" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')" -ne 1 ]; then
  echo "ERROR: renovate.json has MORE THAN ONE customManager targeting .github/workflows." >&2
  echo "       This gate cannot tell which one owns the mise pin; disambiguate them." >&2
  exit 1
fi

# Tracked AND untracked: a brand-new unpinned workflow is exactly the case worth catching, and
# `git ls-files` alone is blind to it until someone remembers to `git add`.
files="$( { git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml';
            git ls-files --others --exclude-standard '.github/workflows/*.yml' '.github/workflows/*.yaml'; } | sort -u || true)"
[ -n "$files" ] || { echo "ERROR: no workflow files found — the corpus is empty, so this gate proved nothing." >&2; exit 1; }

scanned=0; steps_total=0; matches_total=0; values=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -r "$f" ] || continue
  scanned=$((scanned + 1))

  # One pass in node: count mise-action STEPS, and count only those customManager matches whose
  # captured `version:` BELONGS to a mise-action step (nearest preceding `uses:` line).
  # shellcheck disable=SC2016  # single quotes are REQUIRED: the body is JavaScript, and every $
  # in it belongs to node (process.env, template literals), not to the shell.
  analysis="$(PATTERN="$pattern" FILE="$f" node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.env.FILE, "utf8");
    const lines = src.split("\n");
    const starts = []; let acc = 0;
    for (const l of lines) { starts.push(acc); acc += l.length + 1; }
    const lineOf = (pos) => { let lo = 0, hi = starts.length - 1, r = 0;
      while (lo <= hi) { const mid = (lo + hi) >> 1;
        if (starts[mid] <= pos) { r = mid; lo = mid + 1; } else hi = mid - 1; } return r; };
    // `- uses: x` and a bare `uses: x` under `- name:` both count; a commented line never does.
    const usesAt = (i) => { const l = lines[i];
      if (/^\s*#/.test(l)) return null;
      const m = l.match(/^\s*(?:-\s+)?uses:\s*(\S+)/); return m ? m[1] : null; };
    const isMise = (u) => !!u && u.startsWith("jdx/mise-action");

    let steps = 0;
    for (let i = 0; i < lines.length; i++) if (isMise(usesAt(i))) steps++;

    const values = [];
    for (const m of src.matchAll(new RegExp(process.env.PATTERN, "g"))) {
      const cv = m.groups && m.groups.currentValue;
      if (!cv) continue;
      const off = m[0].lastIndexOf(cv);
      const pos = m.index + (off >= 0 ? off : m[0].length - cv.length);
      let owner = null;
      for (let i = lineOf(pos); i >= 0; i--) { const u = usesAt(i); if (u) { owner = u; break; } }
      if (isMise(owner)) values.push(cv);
    }
    process.stdout.write(JSON.stringify({ steps, values }));
  ')"

  steps="$(printf '%s' "$analysis" | jq -r '.steps')"
  [ "$steps" -gt 0 ] || continue
  found="$(printf '%s' "$analysis" | jq -r '.values[]?')"

  n_found="$(printf '%s\n' "$found" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  steps_total=$((steps_total + steps))
  matches_total=$((matches_total + n_found))
  if [ -n "$found" ]; then values="$values$found"$'\n'; fi

  if [ "$steps" -ne "$n_found" ]; then
    echo "FAIL $f: $steps mise-action step(s), but only $n_found carries a version: the customManager tracks."
    echo "     An UNPINNED step resolves mise at run time; an UNTRACKED pin is never bumped again."
    echo "     Required shape — bare, unquoted, digit-leading, within 4 lines of the comment,"
    echo "     and the version: must sit INSIDE the mise-action step (a stray one belongs to"
    echo "     whichever action precedes it, which is how the first draft of this gate was fooled):"
    echo "         # renovate: datasource=github-releases depName=jdx/mise"
    echo "         - uses: jdx/mise-action@<sha> # v4"
    echo "           with:"
    echo "             version: 2026.9.2"
    fail=1
  fi
done <<EOF
$files
EOF

# `wc -l` over `grep -c`: grep -c prints its count AND exits 1 on zero, so any fallback fires on
# the no-match path too and the capture becomes "0\n0" — the repo's own check-count-fallback
# caught exactly that in this gate's first draft.
distinct="$(printf '%s\n' "$values" | sed '/^[[:space:]]*$/d' | sort -u)"
uniq_vals="$(printf '%s\n' "$distinct" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
if [ "$matches_total" -gt 0 ] && [ "$uniq_vals" -ne 1 ]; then
  echo "FAIL: mise-action pins disagree across workflows:"
  printf '%s\n' "$distinct" | sed 's/^/       /'
  fail=1
fi

if [ "$steps_total" -eq 0 ]; then
  echo "ERROR: scanned $scanned workflow file(s) and found ZERO mise-action steps." >&2
  echo "       Either the action was removed (delete this gate) or the matcher rotted." >&2
  exit 1
fi

# The FLOOR must not exceed the pin. .mise.toml's min_version is a FOURTH copy of this version
# that no manager tracks, so Renovate bumping the CI pins can silently strand it — and raising it
# past the pin makes every `mise` call refuse with rc=1 and EMPTY stdout, which surfaces as the
# toolchain silently falling off PATH rather than as an error anyone can read.
pin="$(printf '%s\n' "$distinct" | head -1)"
floor="$(sed -n 's/^[[:space:]]*min_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' .mise.toml | head -1)"
if [ -n "$floor" ] && [ -n "$pin" ]; then
  # jq compares the vkey ARRAYS element-wise, which is the whole point of the shared key.
  if [ "$(jq -n --arg f "$floor" --arg p "$pin" "$(vkey_jq) (\$f | vkey) <= (\$p | vkey)")" != "true" ]; then
    echo "FAIL: .mise.toml min_version ($floor) is NEWER than the CI pin ($pin)."
    echo "     Every mise call then refuses with rc=1 and empty stdout, and the pinned toolchain"
    echo "     silently falls off PATH. Lower the floor, or raise the pins to match."
    fail=1
  fi
fi

[ "$fail" -eq 0 ] || exit 1
echo "OK — $scanned workflow file(s); $steps_total mise-action step(s), all $matches_total tracked and owned by a mise step, all pinned to $pin (floor ${floor:-none})."
