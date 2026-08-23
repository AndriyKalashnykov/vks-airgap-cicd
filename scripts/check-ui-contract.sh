#!/usr/bin/env bash
# ── check-ui-contract.sh — every app must render the SAME page (plan Phase B) ────────────────────
#
# OWNER REQUIREMENT: "apps in all languages must render same web ui layout, different by whatever
# app specifics you reflecting on those pages, like app name, version, etc, look and feel should be
# exactly the same".
#
# WHY A GATE AND WHY NOW. Measured 2026-08-22: javawebapp's Thymeleaf template and gowebapp's
# html/template hold the CSS block VERBATIM TWICE, byte-identical, with NOTHING asserting it. Two
# hand-maintained copies today; the plan adds four more apps. The right moment to gate a duplicated
# invariant is while the copies still agree -- after the first drift you are reconciling, not gating.
#
# WHY THE RENDERED PAGE, NOT THE TEMPLATE SOURCE. The sources CANNOT be compared across Thymeleaf /
# html-template / Razor / Jinja2 / JSX -- they are different languages expressing the same output.
# Only the rendered page is comparable, and it is also the thing the requirement is actually about:
# what the user SEES.
#
# WHY WHITESPACE IS NORMALISED. Thymeleaf controls its own output indentation and Go's template
# controls its own; requiring byte-identical INDENTATION would gate a thing no user can perceive and
# would be unfixable without contorting each template. Measured: after aligning the two real
# differences (a rendered HTML comment, and dt/dd line breaks) the two pages differ by exactly 5
# bytes, all indentation. So: collapse whitespace runs, strip leading/trailing, drop blank lines,
# then require the results to be IDENTICAL. Everything a user can see is still gated -- element
# order, nesting, classes, the entire CSS block, the text.
#
# WHY A PER-APP PRODUCER FILE. apps/<lang>/<app>/ui-contract.sh, discovered by convention. lib/apps.sh
# already carries SEVEN per-language `case` branches (app_test_task, app_set_message,
# app_builder_image, app_runtime_image, app_health_path, app_toolchain, app_build_args) plus three
# more outside it -- ten branch points, so four new languages would be forty edits, each forgettable
# on its own. This deliberately does not become the eleventh.
#
# THE MASKED FIELDS are the app-specific data the requirement explicitly ALLOWS to differ. Each
# producer renders with these exact literals, so no masking pass is needed -- they are already
# uniform, and a producer that renders its own real values will FAIL, loudly, which is correct.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

REPO="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

norm() { tr -s ' \t' ' ' < "$1" | sed 's/^ //; s/ $//' | grep -v '^$'; }

producers=()
while IFS= read -r p; do producers+=("$p"); done < <(find "$REPO/apps" -mindepth 3 -maxdepth 3 -name 'ui-contract.sh' | sort)

# A gate with fewer than two producers cannot COMPARE anything -- it would pass by not looking.
[ "${#producers[@]}" -ge 2 ] || die "check-ui-contract: found ${#producers[@]} producer(s) under apps/*/*/ui-contract.sh — need at least 2 to compare. A one-app run proves nothing."

log_info "check-ui-contract: rendering ${#producers[@]} app(s)"
names=()
for p in "${producers[@]}"; do
  app="$(basename "$(dirname "$p")")"
  names+=("$app")
  "$p" "$T/${app}.html" || die "check-ui-contract: producer failed for '${app}' ($p)"
  norm "$T/${app}.html" > "$T/${app}.norm"
  log_info "  ${app}: $(wc -c < "$T/${app}.html") bytes rendered"
done

ref="${names[0]}"
fail=0
for app in "${names[@]:1}"; do
  if ! diff -q "$T/${ref}.norm" "$T/${app}.norm" >/dev/null 2>&1; then
    fail=1
    log_error "check-ui-contract: '${app}' does NOT render the same page as '${ref}':"
    diff "$T/${ref}.norm" "$T/${app}.norm" | head -30 | sed 's/^/    /' >&2
  fi
done

[ "$fail" -eq 0 ] || die "check-ui-contract: the shared-UI contract is BROKEN (compared ${#names[@]} apps against '${ref}')."
log_info "check-ui-contract: OK — all ${#names[@]} app(s) render an identical page (${names[*]})."
