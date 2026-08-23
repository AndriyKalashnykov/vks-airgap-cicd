#!/usr/bin/env bash
# check-image-alignment.sh — fail if any mirrored image referenced in a k8s/ or
# manifest under k8s/ (as ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<repo>:<tag>) has a
# tag that differs from images/images.txt (the mirror's source of truth).
#
# Why this gate exists: image versions are duplicated between images/images.txt
# (Renovate-tracked) and the rendered manifests. When Renovate bumps images.txt
# but a manifest still pins the old tag, the mirror pushes only the images.txt
# tag, so the workload pulls a tag Harbor does not have -> ImagePullBackOff. This
# gate makes that drift a RED CI failure instead of a runtime surprise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

drift=0
# The ITEM count for arm 1: every ref this arm actually JUDGED, including the WARN branch (a WARN is
# a judgment about that ref). NOT `drift` — zero drift is the healthy state, so guarding it would be
# backwards. Measured 2026-07-19: with k8s/ emptied this arm ran ZERO iterations and the gate still
# printed "all mirrored image tags aligned", rc=0. The `gate has gone BLIND` guard further down
# covers a DIFFERENT arm's derivation, which is exactly why this one read as covered.
refs_examined=0
while read -r ref; do
  [ -n "$ref" ] || continue
  refs_examined=$((refs_examined + 1))
  repo="${ref%:*}"
  mtag="${ref##*:}"
  # `|| true`: `head -1` closes the pipe → `grep` SIGPIPEs (141), and a repo absent from
  # images.txt makes `grep` exit 1; either non-zero would abort this `set -e` script mid-loop
  # and skip the `[ -z "$itag" ]` WARN guard below. The captured value is already correct.
  itag="$(grep -oE "${repo}:[^[:space:]\"]+" images/images.txt | head -1 | sed "s|${repo}:||" || true)"
  if [ -z "$itag" ]; then
    echo "WARN  ${repo}: referenced in a manifest but absent from images/images.txt (not mirrored?)"
    continue
  fi
  if [ "$mtag" != "$itag" ]; then
    echo "DRIFT ${repo}: manifest=${mtag} vs images/images.txt=${itag}"
    drift=1
  else
    echo "ok    ${repo}=${mtag}"
  fi
done < <( { grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"}<>]+:[^[:space:]"}<>]+' k8s/ 2>/dev/null || true
            # Gitea's ref lives in the SCRIPT's default, not the manifest: the manifest carries
            # ${GITEA_IMAGE} so a Harbor-less test (e2e-cross-cluster) can override it. A gate that
            # only greps k8s/ would have gone BLIND to the gitea tag the moment that changed — the
            # gate must follow its content. (Same treatment as eclipse-temurin below.)
            #
            # SCOPE is scripts/ — NOT a named file. Naming 40-install-gitea.sh was an enumerated
            # list of one: the next script to gain a Harbor ref would drift silently, and Renovate's
            # manager (renovate.json, widened in the same change) would not track it either. Measured
            # 2026-07-28: broad and narrow yield the IDENTICAL ref set (arm 1 total = 5), so the
            # widening is behaviour-neutral today and rot-proof tomorrow.
            #
            # BOTH classes exclude `}` AND `<>`. The `<>` half is LOAD-BEARING, not tidiness: this
            # file's OWN docstring (line 3) carries the pattern UNESCAPED, and 14-builder-build.sh +
            # 22-builder-push.sh carry `<app>-builder:<tag>` in prose. Without `<>` those COMMENTS
            # become refs, which (a) emits permanent false WARNs, and (b) silently DISABLES the
            # `refs_examined -eq 0` blind-guard below, because the comments alone hold the count at 2.
            # Measured 2026-07-28 with k8s/ AND 40-install-gitea.sh emptied: without `<>` the gate
            # printed "all mirrored image tags aligned" rc=0 (BLIND, undetected); with `<>` it printed
            # the BLIND error, rc=1. No legal Docker repo or tag contains `<` or `>`, so excluding
            # them can never drop a real ref. (adversary-bash-git-cli F1/F2, 2026-07-28.)
            #
            # `|| true` on BOTH greps is load-bearing under `set -euo pipefail`: when the FIRST grep
            # finds nothing it exits 1, `set -e` terminates this brace group, and the SECOND grep
            # NEVER RUNS — so the gitea mitigation directly above was defeated by exactly the
            # scenario it was written for. Measured 2026-07-19: k8s/ emptied -> 0 iterations, while
            # running the gitea grep alone still yields its ref.
            grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"}<>]+:[^[:space:]"}<>]+' scripts/ 2>/dev/null || true
          } | sed -E 's|\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/||' | sort -u)

# `die` is NOT available here — lib/os.sh is sourced further down (see the source line below), so a
# `die` at this point would be `command not found` -> rc 127, which the vacuity harness classifies
# as INCONCLUSIVE (never a pass) rather than a demonstrated RED. Inline the failure.
if [ "$refs_examined" -eq 0 ]; then
  echo "ERROR check-image-alignment: examined 0 mirrored image ref(s) from k8s/ + scripts/ — the gate has gone BLIND on this arm." >&2
  exit 1
fi

# SELF-HIT ASSERTION. Arm 1 greps scripts/, and THIS FILE lives in scripts/ — so the gate reads its
# own source. Its docstring and the comments above spell the pattern out in prose; the `<>` exclusion
# in both char classes is the ONLY reason those do not register as refs. Assert that directly, so a
# future edit that reintroduces a matching literal here fails LOUDLY instead of silently inflating
# refs_examined and disabling the blind-guard above.
#
# ⚠️ DO NOT "FIX" A FAILURE HERE BY EXCLUDING THIS FILE FROM THE GREP. Excluding it blinds the gate
# to every future REAL ref in it. Fix the literal instead (write it escaped, or with <> around the
# placeholders, exactly as lines 3 and 43-55 do).
self_hits="$(grep -cE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"}<>]+:[^[:space:]"}<>]+' "${SCRIPT_DIR}/check-image-alignment.sh" || true)"
if [ "${self_hits:-0}" -ne 0 ]; then
  echo "ERROR check-image-alignment: this gate's OWN source contributes ${self_hits} ref(s) to arm 1." >&2
  echo "       That inflates refs_examined and DISABLES the blind-guard above. Fix the literal in" >&2
  echo "       check-image-alignment.sh (escape it, or use <> placeholders) — do NOT exclude the file." >&2
  exit 1
fi

check_pinned() { # <label> <actual> <expected-from-images.txt>
  [ -n "$3" ] || return 0
  if [ "$2" != "$3" ]; then
    echo "DRIFT ${1}: ${2:-<absent>} vs images/images.txt=${3}"
    drift=1
  else
    echo "ok    ${1}=${2}"
  fi
}

# --- .env.example tag vars, DERIVED FROM THEIR CONSUMER (lib/apps.sh) --------------------------
# This used to be ONE HARDCODED LINE (`check_pinned "TEMURIN_JRE_TAG …"`), and that enumerated list
# ROTTED THE MOMENT A SECOND LANGUAGE ARRIVED. The Go app added GOLANG_BUILD_TAG and
# DISTROLESS_STATIC_TAG; neither was ever added here — so when Renovate bumped the distroless DIGEST
# in images.txt + the Dockerfile but NOT in .env.example, this gate went GREEN on a broken tree, the
# PR merged, and the mirror pushed a digest the pipeline never asks for. Kaniko then failed with
# `NOT_FOUND: artifact …@sha256:… not found` at the FAR END of the pipeline, naming the image and not
# the drift. (A gate whose scope is a hand-typed list is the defect — the same lesson the per-app
# Dockerfile loop below already learned.)
#
# So DERIVE the list from the only thing that actually renders these vars into the refs the pipeline
# pulls from Harbor: app_builder_image()/app_runtime_image() in lib/apps.sh. Each branch looks like
#     go)  printf '%s/%s/distroless/static-debian12:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DISTROLESS_STATIC_TAG:?}"
# giving us (repo=distroless/static-debian12, var=DISTROLESS_STATIC_TAG). A repo containing a `%s`
# (`%s-builder`) is an image WE BUILD, not one we mirror — it has no images.txt row, so it is skipped.
# A new language's var is covered here the day it is written, with zero edits to this gate.
env_pairs="$(sed -n '/^app_builder_image()/,/^}/p;/^app_runtime_image()/,/^}/p' scripts/lib/apps.sh \
  | sed -nE "s|.*printf '%s/%s/([^:']+):%s'.*\\\$\{([A-Z_]+):\?\}.*|\1 \2|p" \
  | grep -v '%s' | sort -u || true)"
[ -n "$env_pairs" ] || { echo "ERROR check-image-alignment: parsed ZERO tag vars out of lib/apps.sh — the gate has gone BLIND (did app_*_image() change shape?)"; exit 1; }

env_checked=0
while read -r repo var; do
  [ -n "$repo" ] || continue
  # The images.txt row for this repo: match the repo as a whole path segment-suffix (images.txt may
  # carry a registry prefix, e.g. gcr.io/distroless/static-debian12), then take everything after the
  # FIRST colon as the tag (which may itself be `tag@sha256:...`).
  row="$(grep -E "(^|/)${repo}:" images/images.txt | grep -v '^[[:space:]]*#' | head -1 || true)"
  if [ -z "$row" ]; then
    echo "WARN  ${var}: '${repo}' is rendered by lib/apps.sh but is absent from images/images.txt (not mirrored?)"
    continue
  fi
  expected="${row#*:}"
  actual="$(grep -E "^${var}=" .env.example | head -1 | cut -d= -f2- || true)"
  check_pinned "${var} (.env.example → ${repo})" "$actual" "$expected"
  env_checked=$((env_checked + 1))
done <<< "$env_pairs"
echo "      (checked ${env_checked} .env.example tag var(s), derived from lib/apps.sh)"
# The `gate has gone BLIND` guard above is on the DERIVATION (env_pairs parsed out of lib/apps.sh),
# not on the checks PERFORMED. env_checked was printed and never compared to zero — the same
# FILE-vs-ITEM confusion this effort exists to kill, one arm over. (Still before lib/os.sh, so
# inline rather than die.)
if [ "$env_checked" -eq 0 ]; then
  echo "ERROR check-image-alignment: derived tag vars but checked 0 of them — the gate has gone BLIND on this arm." >&2
  exit 1
fi

# --- EVERY app's Dockerfile base images, DERIVED from the app registry ------------------------
# NOT one hardcoded block per language. For each app in apps/registry.tsv we read ITS Dockerfile's
# base-image ARGs and assert each ref appears VERBATIM in images/images.txt. Adding an app (or a
# language) needs ZERO edits here — the gate follows the registry.
#
# Why it matters: if images.txt is bumped (Renovate) and an app's Dockerfile ARG is not, the mirror
# pushes the NEW ref while the build asks Harbor for one it never received — Kaniko fails with
# MANIFEST_UNKNOWN at PIPELINE time, never at build time. Digest-pinned refs (`tag@sha256:...`) are
# compared whole, so a digest bump that misses a Dockerfile is caught too.
# lib/apps.sh needs REPO_ROOT (this script calls its root $ROOT) and os.sh's die().
REPO_ROOT="$ROOT"; export REPO_ROOT
# shellcheck source=scripts/lib/os.sh
. "${ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${ROOT}/scripts/lib/apps.sh"

while read -r app; do
  [ -n "$app" ] || continue
  df="${ROOT}/$(app_src "$app")/Dockerfile"
  [ -f "$df" ] || { echo "DRIFT ${app}: no Dockerfile at ${df#"$ROOT"/}"; drift=1; continue; }
  for arg in BUILDER_IMAGE RUNTIME_IMAGE; do
    ref="$(grep -oE "^ARG ${arg}=[^[:space:]\"]+" "$df" | head -1 | sed "s|^ARG ${arg}=||" || true)"
    [ -n "$ref" ] || continue          # an app need not define both (a single-stage build)
    if grep -qxF "$ref" images/images.txt; then
      echo "ok    ${arg} (${app})=${ref}"
    else
      echo "DRIFT ${arg} (${app}): ${ref} is NOT in images/images.txt (so it is never mirrored)"
      drift=1
    fi
  done
done <<EOF
$(app_names)
EOF

# Istio's version is carried in .env.example (ISTIO_VERSION, which feeds the helm
# global.tag in 46-install-istio.sh) and mirrored as istio/pilot + istio/proxyv2
# in images.txt. Keep them aligned (both istio images share the one version).
# `|| true`: standalone `set -e` assignments — a `head -1` SIGPIPE (or istio absent from
# images.txt) would abort the script before the aligning `check_pinned` calls below run.
istio_itag="$(grep -oE 'istio/pilot:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/pilot:||' || true)"
proxyv2_itag="$(grep -oE 'istio/proxyv2:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/proxyv2:||' || true)"
check_pinned "ISTIO_VERSION (.env.example)" "$(grep -E '^ISTIO_VERSION=' .env.example | cut -d= -f2)" "$istio_itag"
check_pinned "istio/proxyv2 (images.txt)" "$proxyv2_itag" "$istio_itag"

# The following are NOT registry-derived on purpose: they guard the Java OFFLINE-BUILDER apparatus
# (Dockerfile.builder + 15-build-push-builder.sh), which exists because an in-cluster build cannot
# reach its language's package registry. As of 2026-08-22 EVERY app ships one (owner decision: one
# uniform air-gap pole), so the arm above derives them by EXECUTING app_builder_base() per builder
# app rather than naming a language. This comment used to say "no other language has one (gowebapp
# is stdlib-only)" -- both halves stopped being true when gowebapp gained chi and a builder.
#
# The Maven BUILD image (maven:<mvn>-eclipse-temurin-<jdk>) is mirrored in images.txt and its
# FULL tag is re-typed in four consumers the manifest grep above cannot see: the two app
# Dockerfile ARGs and 15-build-push-builder.sh's upstream-pull + Harbor-ref lines. Renovate tracks
# it (depName=maven) via images.txt only, and check-java-alignment aligns just the JDK MAJOR — so a
# maven `3.9 -> 3.10` bump would drift the consumers silently. Assert the full tag across all four.
# `|| true`: standalone `set -e` assignments — a head-1 SIGPIPE / no-match must not abort here.
mvn_itag="$(grep -oE '^maven:[^[:space:]"]+' images/images.txt | head -1 | sed 's|maven:||' || true)"
# The builder Dockerfile belongs to whichever app SHIPS one (see app_has_builder) — found via the
# registry, never by hardcoding which app is the Java one.
# `if…fi`, NOT `app_has_builder "$a" && { …; }`: as a loop-body TAIL that `A && B` returns non-zero
# when the LAST app has no builder, the `$( )` returns non-zero, the ASSIGNMENT returns non-zero,
# and `set -euo pipefail` kills the script HERE — making the `if [ -n "$builder_app" ]` guard on the
# next line unreachable dead code. Measured 2026-07-19 with the registry emptied: rc=1, output
# truncated mid-run, ZERO bytes of stderr. The twin of check-java-alignment.sh's line 40.
builder_app="$(app_names | while read -r a; do if app_has_builder "$a"; then printf '%s' "$a"; break; fi; done)"
if [ -n "$builder_app" ]; then
  builder_df="$(app_src "$builder_app")/Dockerfile.builder"
  check_pinned "MAVEN_IMAGE (${builder_df})" \
    "$(grep -oE 'MAVEN_IMAGE=maven:[^[:space:]"]+' "$builder_df" | head -1 | sed 's|MAVEN_IMAGE=maven:||' || true)" "$mvn_itag"
fi
# The builder base ref MOVED on 2026-08-22. It was `MAVEN_SRC=` in 14-builder-build.sh, resolved ONCE
# above the loop -- so it could not vary per app, and a node builder would have been handed
# MAVEN_IMAGE and silently built on an UNPINNED base (measured: podman warns, exits 0). It now lives
# in lib/apps.sh's app_builder_base(), resolved PER APP inside the loop.
#
# So this arm EXECUTES the hook for every app that ships a Dockerfile.builder instead of grepping a
# literal. That is not merely an adaptation: a grep for one hardcoded NAME could only ever check ONE
# language, and it went `<absent>` the moment the name moved (measured, rc=2 -- loudly, which is why
# this is a fix and not a discovery). Executing it covers every builder app, including ones added
# later, with no edit here.
#
# The tag must still match images.txt -- it is the KEY the digest lookup uses, so a drift means the
# lookup finds nothing (or the wrong image) rather than an ImagePullBackOff.
_builder_apps="$(app_names | while read -r _a; do if app_has_builder "$_a"; then printf '%s ' "$_a"; fi; done)"
for _ba in $_builder_apps; do
  _bkey="$(app_builder_base "$_ba")"   # the images.txt KEY: <repo>:<tag>
  _brepo="${_bkey%%:*}"; _btag="${_bkey#*:}"
  _bwant="$(grep -oE "^${_brepo}:[^[:space:]\"]+" images/images.txt | head -1 | sed "s|^${_brepo}:||" || true)"
  check_pinned "app_builder_base(${_ba}) [${_brepo}]" "$_btag" "$_bwant"
done

# --- BARE docker.io refs the repo owns, DERIVED from images/images.txt ------------------------
# ARM 1 sees only refs written as ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<repo>:<tag>. A ref written
# WITHOUT that prefix -- the plain upstream coordinate, used where a leg deliberately does not go
# through Harbor -- scored ZERO, so the inventory could be bumped while such a ref kept the old tag
# indefinitely. Not hypothetical: it had ALREADY drifted when this arm was written (B100).
#
# THIS ARM MUST SIT ABOVE THE `drift` EXIT BELOW. The first version did not, so it printed DRIFT
# lines and still exited 0 -- a fake-green introduced while closing a fake-green row.
#
# FOUR TRAPS, each measured, each of which shipped in a draft of this arm:
#   1. `[...{}$-]` inside DOUBLE QUOTES: `$-` is a shell parameter (the option flags, measured
#      `hBc`). It mangled the class, dropped `-`, and truncated every tag at its first dash ->
#      confident false DRIFT on the shortened tag. `-` is FIRST and `$` is escaped below.
#   2. `}` in the tag class: `${VAR:-<repo>:<tag>}` then captures a trailing `}` -> false DRIFT on a
#      CORRECT ref. That shape is live in this repo. The literal class excludes braces; a fully
#      interpolated tag is matched as its OWN alternative so it can be counted and skipped.
#   3. `sed 's/#.*//'` is a `#`-TRUNCATOR, not a comment stripper: it also cuts `${VAR#...}` and a
#      quoted "#", destroying a real ref -> FALSE GREEN. 35 files here use `${VAR#`. Drop
#      whole-line comments instead; measured to give an identical denominator.
#   4. The blind guard must key on the INVENTORY, not on refs found. Every ref that gets correctly
#      DERIVED stops matching, so a found-refs guard falls to 0 exactly when the tree reaches the
#      GOAL state -- a false RED whose cheapest silencer is to re-hardcode a tag. VERIFIED: with the
#      last literal derived, arm 4 reports `0 ref(s) found` and does NOT error.
#
# THE BUILDER BASE REFS ARE DELIBERATELY EXEMPT FROM THE "just derive it" ADVICE. They live in
# lib/apps.sh's app_builder_base() -- one branch per language -- and arm 3 above EXECUTES that hook
# per builder app and compares the tag against images.txt. (Until 2026-08-22 there was exactly one,
# `MAVEN_SRC=` in 14-builder-build.sh, greped literally; it moved because a single ref above the
# loop could not vary per app.) Arm 3 is not weakened to accommodate arm 4: it guards the
# offline-builder apparatus, where the tag is the KEY `bundle/images.lock` is looked up by. So for
# those refs the literal is correct and arm 4 simply agrees with arm 3.
#
# Not flagged, deliberately: an interpolated tag (correct BY CONSTRUCTION -- it derives at runtime);
# a ref preceded by `/` (that is arm 1's, and double-counting hides a blind arm); a ref in
# `scripts/test-*.sh` (a unit test's fixture inventory is SYNTHETIC and deployed by nothing).
bare_entries=0; bare_seen=0; bare_checked=0; bare_excluded=0
bare_excluded="$(find scripts k8s -type f -name 'test-*.sh' 2>/dev/null | wc -l)"
while read -r inv; do
  [ -n "$inv" ] || continue
  case "$inv" in *"@sha256:"*) inv="${inv%@sha256:*}" ;; esac   # digest-pinned: compare the TAG half
  case "$inv" in *.*/*) continue ;; esac                        # has a registry host -> not bare
  case "$inv" in *:*) : ;; *) continue ;; esac                  # tagless -> `${inv%:*}` would be nonsense
  brepo="${inv%:*}"; binv_tag="${inv##*:}"
  [ -n "$brepo" ] && [ -n "$binv_tag" ] || continue
  bare_entries=$((bare_entries + 1))
  while read -r hit; do
    [ -n "$hit" ] || continue
    bare_seen=$((bare_seen + 1))
    htag="${hit##*:}"
    case "$htag" in *'$'*) continue ;; esac                     # derived at runtime -> correct
    bare_checked=$((bare_checked + 1))
    if [ "$htag" != "$binv_tag" ]; then
      echo "DRIFT bare ref ${brepo}:${htag} does not match images/images.txt (${binv_tag})"
      drift=1
    fi
  done < <(find scripts k8s -type f ! -name 'test-*.sh' -print0 2>/dev/null \
             | xargs -0 grep -hvE '^[[:space:]]*#' \
             | grep -oE "(^|[^A-Za-z0-9./_-])${brepo}:(\\\$\{[A-Za-z_][A-Za-z0-9_]*\}|[-A-Za-z0-9._]+)" \
             | sed -E 's|^[^A-Za-z0-9$]||' || true)
done < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' images/images.txt)

# SELF-HIT ASSERTION, mirroring arm 1's. This gate lives in scripts/, which this arm greps, so its
# own source can contribute refs and silently inflate the counts. Measured: adding one non-comment
# line naming a real ref here made a deliberately-blinded arm's error DISAPPEAR.
# DO NOT "fix" a failure here by excluding this file -- that blinds the arm to every future real ref
# in it. Write the literal so it cannot match (escaped, or with the placeholders in <>), as above.
bare_self="$(grep -vE '^[[:space:]]*#' "${SCRIPT_DIR}/check-image-alignment.sh" \
             | grep -cE "(^|[^A-Za-z0-9./_-])(gitea/gitea|maven|golang|traefik|alpine/git):[-A-Za-z0-9._]+" || true)"
if [ "${bare_self:-0}" -ne 0 ]; then
  echo "ERROR check-image-alignment: this gate's OWN source contributes ${bare_self} bare ref(s) to arm 4." >&2
  exit 1
fi

# GUARD ON THE INVENTORY, per trap 4 above: this is the number of things the arm set out to judge,
# and it cannot be driven to zero by the tree becoming correct.
if [ "$bare_entries" -eq 0 ]; then
  echo "ERROR check-image-alignment: parsed 0 BARE entries from images/images.txt — arm 4 is BLIND." >&2
  exit 1
fi
echo "      (arm 4: ${bare_entries} bare inventory entr(ies); ${bare_seen} ref(s) found in-tree —" \
     "${bare_checked} literal, $((bare_seen - bare_checked)) derived; ${bare_excluded} test fixture file(s) excluded)"

if [ "$drift" -ne 0 ]; then
  echo "ERROR: image tag drift between manifests and images/images.txt (BLOCKING)." >&2
  echo "       The mirror pushes the images.txt tag; each manifest pulls its own tag." >&2
  echo "       Align the manifest tag(s) above with images/images.txt." >&2
  exit 1
fi
echo "check-image-alignment: all mirrored image tags aligned with images/images.txt"
