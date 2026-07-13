#!/usr/bin/env bash
# check-app-hardcodes.sh — fail if any script/manifest/Makefile hardcodes an APP NAME.
#
# WHY THIS GATE EXISTS
# --------------------
# The demo is multi-app: apps/registry.tsv is the single source of truth, and everything (seeding,
# Tekton, ArgoCD, ingress, PSA, verify, the gates) loops over it. Adding an app must be ONE ROW.
#
# That only holds if nothing names an app. And the honest history here is that it did NOT hold: the
# repo had 12+ places hardcoding `webui`/`javawebapp`, and when a second app arrived the instinct
# was to COPY each block and hardcode the new name beside it (the image-alignment gate got a
# hand-written Java block AND a hand-written Go block before this was fixed). Prose in a rule file
# did not prevent that. A gate does: a hardcoded app name is now a RED build, not a code review.
#
# What counts as a hardcode: an app name from the registry appearing in code that is supposed to be
# app-agnostic. The registry itself, the apps' own source/deploy dirs, docs and dated history are
# exempt — those are the places an app name legitimately belongs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"; export REPO_ROOT
cd "$REPO_ROOT"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# Files that MUST be app-agnostic: the shared scripts, the shared manifests, the Makefile, and
# .env.example.
#
# .env.example is here because it was the ONE required second edit the gate could not see: adding a
# row to apps/registry.tsv used to ALSO require a `<APP>_HOST=<app>.vks.local` line here, or the new
# app died in app_host(). So "adding an app is ONE ROW" was certified by a gate that was blind to the
# second edit. The host is now DERIVED (<app>.${APP_DOMAIN}) and this file may no longer name an app
# in a VALUE — if it does, a required per-app edit has crept back in.
#
# (An app's own dirs — apps/<lang>/<app>/, deploy/<app>/ — obviously name it, as does the registry.)
# `--others --exclude-standard` alongside `--cached`: a NEW, not-yet-`git add`ed script is exactly
# where a hardcode gets written, and a tracked-files-only list gives it a free pass locally — the
# gate then first fires in CI, after the commit. (It did: the classifier's unit test named both apps
# and `make static-check` was green locally because the file was untracked.) Gitignored files stay
# out via --exclude-standard.
mapfile -t TARGETS < <(
  git ls-files --cached --others --exclude-standard \
    'scripts/*.sh' 'scripts/lib/*.sh' 'k8s/**/*.yaml' 'Makefile' 'renovate.json' '.env.example' 2>/dev/null | sort -u
)

rc=0
checked=0
for f in "${TARGETS[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    scripts/lib/apps.sh) continue ;;          # the registry reader: it may name languages, not apps
    scripts/check-app-hardcodes.sh) continue ;;
  esac
  checked=$((checked + 1))
  while read -r app; do
    [ -n "$app" ] || continue
    # DOCUMENTATION may name an app (a comment explaining why, a `make help` line, a YAML
    # `description:` giving an example). CODE may not. So strip the documentation first, then look:
    #   - whole-line shell/YAML comments        (^ #)
    #   - Makefile help text after `##`
    #   - YAML `description:` values
    # What remains is code, and an app name there means adding an app needs a code edit.
    hits="$(
      sed -E 's/##.*$//; s/^[[:space:]]*#.*$//; s/^[[:space:]]*(description|#).*$//' "$f" 2>/dev/null \
        | grep -nE "\\b${app}\\b" || true
    )"
    if [ -n "$hits" ]; then
      log_error "app name '${app}' is HARDCODED in ${f}:"
      printf '%s\n' "$hits" | sed 's/^/      /' >&2
      rc=1
    fi
  done <<EOF
$(app_names)
EOF
done

if [ "$rc" -eq 0 ]; then
  log_info "check-app-hardcodes: OK — none of the ${checked} shared files names an app ($(app_names | tr '\n' ' ')); adding an app stays ONE ROW in apps/registry.tsv."
else
  log_error "check-app-hardcodes: a shared file names a specific app."
  log_error "  Derive it from apps/registry.tsv instead (scripts/lib/apps.sh: app_names/app_src/app_host/"
  log_error "  app_lang/for_each_app). Language-specific behaviour keys off the LANG, never the app name."
  log_error "  If the mention is explanatory, put it in a comment."
fi
exit "$rc"
