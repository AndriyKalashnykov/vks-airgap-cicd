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
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

REPO="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# NORMALISATION IS DELIBERATELY MINIMAL: blank lines only.
#
# It started as `tr -s ' \t' ' '` + strip + drop-blanks, justified as "the two renders differ by 5
# bytes, all indentation". MEASURED, that justification was WRONG: the only difference is one
# WHOLE whitespace-only LINE (left behind by the stripped Thymeleaf comment), so dropping blank
# lines ALONE makes them identical and the collapse/strip did nothing. Worse, the unexercised half
# is not free -- 2-space vs 4-space indentation inside a <pre> compares IDENTICAL after collapsing,
# and that IS visible to a user. Removing it is strictly tighter at zero cost today.
norm() { grep -v '^[[:space:]]*$' "$1" || true; }

# THE APP LIST COMES FROM THE REGISTRY, NOT FROM THE FILESYSTEM.
#
# It used to be `find apps -mindepth 3 -maxdepth 3 -name ui-contract.sh`, which compared only the
# apps that HAPPENED to have a producer. MEASURED on a fake tree with 3 registry rows and 2
# producers: "OK -- all 2 app(s) render an identical page", rc=0. The third app was invisible and
# the word "all" asserted a completeness it had never established. With six apps, forgetting a
# producer is the DEFAULT outcome. The fixed depth was wrong too: the registry's `src` column is
# free-form, so a producer at apps/z/app3/src/ was invisible to the find and visible to the author.
_apps="$(app_names)"
n_registry=0; n_cmp=0
names=(); missing=()
while read -r app; do
  [ -n "$app" ] || continue
  n_registry=$((n_registry + 1))
  prod="${REPO}/$(app_src "$app")/ui-contract.sh"
  if [ ! -x "$prod" ]; then missing+=("${app} (expected ${prod#"$REPO"/})"); continue; fi
  names+=("$app")
done <<EOF
${_apps}
EOF

# A missing producer is a HARD FAIL, not a silent skip. This is the whole difference between
# "every app renders the same page" and "the apps I happened to look at agreed".
if [ "${#missing[@]}" -gt 0 ]; then
  log_error "check-ui-contract: ${#missing[@]} registry app(s) have NO executable ui-contract.sh producer:"
  printf '    %s\n' "${missing[@]}" >&2
  die "check-ui-contract: refusing to report on a SUBSET. Every app in apps/registry.tsv must ship apps/<lang>/<app>/ui-contract.sh (executable) that writes its rendered page to \$1."
fi
[ "${#names[@]}" -ge 2 ] || die "check-ui-contract: ${#names[@]} app(s) in the registry — need at least 2 to compare. A one-app run proves nothing."

log_info "check-ui-contract: rendering ${#names[@]} app(s) from apps/registry.tsv"
for app in "${names[@]}"; do
  # KEYED ON THE APP NAME FROM THE REGISTRY, which is unique by construction. It used to be keyed
  # on basename(dirname(producer)): MEASURED, apps/java/webapp and apps/go/webapp then wrote the
  # SAME temp file, the second clobbered the first, and the gate diffed a file against itself --
  # "OK -- all 2 app(s) render an identical page (webapp webapp)", rc=0, with the two different
  # byte counts printed in its own log and ignored.
  f="$T/${app}.html"
  # RUN THE PRODUCER IN THE APP'S BUILDER IMAGE, not on the host. These producers were the LAST
  # consumers of the host java/go/rust/dotnet/node toolchains: each shells out to `go test`,
  # `cargo test`, `dotnet run` or `./mvnw`, so as long as they ran here, .mise.toml had to pin all
  # six regardless of what app-test did.
  #
  # Same shape as scripts/app-test.sh run_in_builder, and for the same measured reasons: source is
  # READ-ONLY (nothing can land root-owned in the operator's tree), the work tree is a tmpfs
  # (cargo/maven/node HARD-FAIL on a read-only source), --network=none proves the builders really
  # are self-contained, and --pull=never stops a stale tag silently fetching from a registry.
  #
  # The rendered page comes back on STDOUT rather than through a writable mount -- that is what keeps
  # the bind mount read-only. A missing -v cannot pass: `cp -a /src/.` fails.
  _img="localhost/${app}-builder:${BUILDER_IMAGE_TAG:-0.3.0}"
  _eng="$(container_engine)"
  "$_eng" image exists "$_img" 2>/dev/null \
    || die "check-ui-contract: builder image ${_img} not present for '${app}' — run 'make builder-image'"
  "$_eng" run --rm --network=none --pull=never \
      -v "${REPO}/$(app_src "$app"):/src:ro" --tmpfs "/work:exec,size=${BUILDER_TMPFS_SIZE:-2g}" -w /work \
      "$_img" sh -c 'cp -a /src/. /work/ && cp -a /build/node_modules /work/ 2>/dev/null; ./ui-contract.sh /work/.ui-out >/dev/null 2>&1 && cat /work/.ui-out' \
      > "$f" || die "check-ui-contract: producer failed for '${app}'"
  [ -s "$f" ] || die "check-ui-contract: '${app}' producer exited 0 but wrote NOTHING to its output file."
  norm "$f" > "$T/${app}.norm"
  [ -s "$T/${app}.norm" ] || die "check-ui-contract: '${app}' rendered only blank lines — that is not a page."
  log_info "  ${app}: $(wc -c < "$f") bytes rendered"
done

ref="${names[0]}"
fail=0
for app in "${names[@]:1}"; do
  n_cmp=$((n_cmp + 1))
  if ! diff -q "$T/${ref}.norm" "$T/${app}.norm" >/dev/null 2>&1; then
    fail=1
    log_error "check-ui-contract: '${app}' does NOT render the same page as '${ref}':"
    diff "$T/${ref}.norm" "$T/${app}.norm" | head -30 | sed 's/^/    /' >&2
  fi
done

[ "$fail" -eq 0 ] || die "check-ui-contract: the shared-UI contract is BROKEN."
# PRINT THE DENOMINATOR against the REGISTRY, so "all" is a claim this gate can actually support.
log_info "check-ui-contract: OK — ${#names[@]} of ${n_registry} registry app(s) render an identical page (${names[*]}); ${n_cmp} comparison(s)."
