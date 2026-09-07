#!/usr/bin/env bash
# Every app must ship ONE icon, serve it at the SAME constant path, and no two apps may ship the
# SAME icon. Four independent conditions, all required — see check_app() below.
#
# WHY A ROUTE AT A CONSTANT PATH AND NOT AN INLINE data: URI. Not because of any escaper: a LITERAL
# data URI in a template survives Go's html/template AND Thymeleaf untouched (measured 2026-09-07 —
# only an `{{.Action}}` is rewritten to `#ZgotmplZ`). The reason is `make check-ui-contract`: the six
# rendered pages must be BYTE-IDENTICAL, so a PER-APP icon cannot live in the shared markup at all.
# Behind a constant URL it can — the markup is the same six times, and the difference is the body
# this gate checks. MEASURED: adding the three markup lines to javawebapp ALONE took
# check-ui-contract RED (rc=2) naming all three; adding them to all six took it green, 1423 -> 1643
# bytes. So the shared MARKUP is already gated. This gate exists for everything the markup gate
# structurally cannot see: the icon BODY, its path JOIN, and the per-app test.
#
# WHY EACH CONDITION, AND THE FAKE-GREEN IT CLOSES (an adversary named all four):
#   1. ENUMERATION — driven off apps/registry.tsv, hard-failing on any app with no icon. Six
#      independent per-app tests with nothing asserting all six EXIST is exactly the defect
#      check-ui-contract.sh's own header records: a find-discovered producer set once reported
#      "OK — all 2 app(s)" over a THREE-row registry, rc=0. Delete the python icon and this goes RED.
#   2. THE MARKUP<->ROUTE JOIN — check-ui-contract proves href="/favicon.svg" is identical six times;
#      a per-app test proves the route it registered answers. NOTHING joins those two strings.
#      Register the route at /icon.svg in one app and both gates stay GREEN over a broken image.
#   3. DISTINCTNESS — a copy-pasted icon returns 200 + image/svg+xml and passes any per-app test.
#      It is a pure offline property of six strings; leaving it to the LIVE ingress check would fire
#      hours later, behind a cluster.
#   4. THE PER-APP TEST EXISTS — same enumeration argument as 1, one layer down.
#
# ⚠️ This is a STRUCTURAL check — it proves each icon is SHAPED like an SVG and is UNIQUE, not that a
# browser DRAWS a visible mark. That is un-gateable offline. It deliberately does NOT shell out to
# xmllint or python3 for real XML parsing: python3 IS ABSENT on a Photon jump box (measured
# 2026-08-09, `python3: command not found` seconds after check-tools printed OK) and adding either to
# the OS floor was rejected. The behavioural proof is a browser; scripts/98-verify-ingress.sh proves
# reachability on a live cluster.
#
# ⚠️ It also holds NO table of the six colours. Doing so would put each colour in two places (here
# and in the app) — the mirrored-value defect. Distinctness by hash subsumes colour distinctness and
# needs no table, so each colour exists EXACTLY ONCE, in its own app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# The ONE path. Every app's route, every app's markup and every app's test must use THIS string —
# that agreement is condition 2, and this constant is what makes it one value and not four.
ICON_PATH="/favicon.svg"

fail=0 checked=0
_hashes=""   # "<sha>  <app>" lines, for the distinctness pass

# The app's source files, excluding build output and vendored trees. A generated copy of the icon
# under obj/ or node_modules/ would otherwise be counted as a second icon and fail condition 1 for
# the wrong reason.
_src_files() {
  local _d="$1"; shift
  find "$_d" -type f \
    ! -path '*/node_modules/*' ! -path '*/target/*' ! -path '*/obj/*' ! -path '*/bin/*' \
    ! -path '*/.git/*' ! -path '*/__pycache__/*' ! -name '*.svg' "$@"
}

check_app() {
  local app="$1" d n icon sha lt gt want
  d="${REPO_ROOT}/$(app_src "$app")"
  checked=$((checked + 1))

  # ── 1. EXACTLY ONE icon in the app's source ──────────────────────────────────────────────────
  # -h (no filename), -o (the match only), -a (treat binaries as text so one stray blob cannot
  # abort the scan). The shape is OUR generated shape, so a greedy .* is safe: there is one SVG.
  icon="$(_src_files "$d" -print0 2>/dev/null | xargs -0 grep -hao \
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32".*</svg>' 2>/dev/null || true)"
  n="$(printf '%s' "$icon" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    log_error "[${app}] ships NO icon. Every app needs one 32x32 SVG constant served at ${ICON_PATH}."
    log_error "        Adding an app enrols it here; see another app's route for the shape."
    fail=1; return
  elif [ "$n" -gt 1 ]; then
    log_error "[${app}] ships ${n} icons — there must be exactly ONE, so the served body is unambiguous."
    fail=1; return
  fi

  # ── 2. STRUCTURE. Not a parser (see the header) — the properties that actually bite. ─────────
  case "$icon" in
    *'#'*) log_error "[${app}] the icon contains a '#'. Use rgb(r,g,b): a '#' truncates the SVG at a URL"
           log_error "        fragment if it is ever inlined as a data: URI, and '\"#' terminates a Rust r#\"\"# literal."
           fail=1 ;;
  esac
  lt="$(printf '%s' "$icon" | tr -cd '<' | wc -c)"
  gt="$(printf '%s' "$icon" | tr -cd '>' | wc -c)"
  if [ "$lt" -ne "$gt" ]; then
    log_error "[${app}] the icon has ${lt} '<' and ${gt} '>' — it is not balanced markup."; fail=1
  fi
  for want in '<rect ' '<text ' '</text>' '</svg>'; do
    case "$icon" in *"$want"*) ;; *)
      log_error "[${app}] the icon is missing '${want}' — it will not draw a mark."; fail=1 ;;
    esac
  done

  # ── 3. THE JOIN. The route, the markup and the test must all name ICON_PATH. ─────────────────
  # Herestrings, NOT `find | xargs grep -q`: under pipefail `grep -q` exits at its first match and
  # SIGPIPEs the producer, so a FOUND pattern reports ABSENT at random (check-grep-q-pipe).
  local all
  all="$(_src_files "$d" -print0 2>/dev/null | xargs -0 grep -hao "\"${ICON_PATH}\"" 2>/dev/null || true)"
  if [ -z "$all" ]; then
    log_error "[${app}] nothing under $(app_src "$app") names \"${ICON_PATH}\". The markup in the shared page"
    log_error "        points there, so the route MUST be registered at exactly that path — a route at any"
    log_error "        other path leaves check-ui-contract green over a broken image."
    fail=1
  fi

  # ── 4. A TEST that EXTRACTS the href from the rendered page and follows it. ──────────────────
  # It looks for `rel="icon"` (or the \"-escaped form java and C# need), NOT for ICON_PATH: the
  # whole point of the test is that it does NOT hardcode the path — it reads the href out of the
  # real render, which is what makes it a JOIN rather than a second independent claim.
  #
  # COMMENTS ARE STRIPPED FIRST. Measured while writing this gate: checking for ICON_PATH passed
  # java, go and dotnet purely because their test COMMENTS name the path — a gate satisfied by
  # prose, and the same bypass check-sigterm.sh records as its #5.
  # NOT filtered to files NAMED *test*: rustwebapp has no separate test file at all — its tests are a
  # `#[cfg(test)] mod tests` inside src/main.rs, the same file that holds the template.
  #
  # Which creates the trap this pattern exists to dodge: that file contains `rel="icon"` TWICE — once
  # in the TEMPLATE and once in the test's extractor — so a naive match would pass VACUOUSLY off the
  # markup. The template is always `rel="icon" type=`; every extractor continues immediately with a
  # regex or a quote. So: require `rel="icon"` NOT followed by a space. Comments are stripped first
  # (bypass #5 of check-sigterm.sh: a match satisfied by prose).
  local tf found=0
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    if grep -qE 'rel=\\?"icon\\?"[^ ]' <<< "$(sed -E 's@^[[:space:]]*(//|#|--|\*|/\*).*@@' "$tf")"; then
      found=1; break
    fi
  done <<TESTS
$(_src_files "$d" 2>/dev/null || true)
TESTS
  if [ "$found" -eq 0 ]; then
    log_error "[${app}] no TEST parses \`rel=\"icon\"\` out of the rendered page and follows the href."
    log_error "        Without one the route is unexercised, and nothing JOINS the markup to the route:"
    log_error "        a route at any OTHER path leaves check-ui-contract green over a broken image."
    fail=1
  fi

  sha="$(printf '%s' "$icon" | sha256sum | cut -d' ' -f1)"
  _hashes="${_hashes}${sha}  ${app}"$'\n'
}

# ⚠️ NOT `for_each_app`: that calls app_export(), which needs HARBOR_URL — and HARBOR_URL is
# COMMENTED in .env.example (it is a SELECTOR), so on CI, which has no .env, for_each_app dies
# `HARBOR_URL: unbound variable`. The heredoc (not a pipe) keeps `checked`/`fail`/`_hashes` in THIS
# shell; a `while read` off a pipe runs in a subshell and every counter comes back zero.
while IFS= read -r _app; do
  [ -n "$_app" ] || continue
  check_app "$_app"
done <<APPS
$(app_names)
APPS

# ── 5. MUTUAL DISTINCTNESS across every app that produced a hash. ──────────────────────────────
_dupes="$(printf '%s' "$_hashes" | awk '{print $1}' | sort | uniq -d || true)"
if [ -n "$_dupes" ]; then
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    log_error "check-app-icons: these apps ship the SAME icon — a copy-paste that every per-app test"
    log_error "        passes (200 + image/svg+xml) and no browser distinguishes:"
    printf '%s' "$_hashes" | awk -v d="$_d" '$1==d {print "          " $2}' >&2
  done <<DUPES
$_dupes
DUPES
  fail=1
fi

[ "$checked" -gt 0 ] || die "check-app-icons: scanned ZERO apps — apps/registry.tsv is empty or unreadable"
if [ "$fail" -ne 0 ]; then
  log_error "check-app-icons: FAILED (${checked} app(s) checked)."
  exit 1
fi
log_info "check-app-icons: OK — all ${checked} app(s) ship exactly one structurally-sound icon, serve it at ${ICON_PATH}, exercise it in a test, and no two are identical."
