#!/usr/bin/env bash
# check-dockerfile-no-install.sh — no app's RUNTIME stage may install anything.
#
# THE INVARIANT. The jump box HAS the internet: it pulls dependencies, bakes them into
# Dockerfile.builder, and pushes that to Harbor. The app image is then built IN-CLUSTER by kaniko,
# where there is NO egress. So a package-manager call in a RUNTIME stage is the architecture broken,
# and it fails in the one place the error is hardest to read.
#
# WHY A TEXT GATE AND NOT A NETWORK CONTROL. MEASURED 2026-08-22 on a real VKS guest: `kubectl get
# netpol -A` and `get acnp,anp` both returned "No resources found", and a probe pod in `ci` reached
# http://archive.ubuntu.com. The kaniko build of the image then serving had pulled 48 MB from the
# public Ubuntu archives. A NetworkPolicy would catch that AT BUILD TIME, on a lab, after a push.
# This catches it AT PR TIME, offline, before it can ever run -- which is where this repo already
# prevents drift (check-image-alignment, check-toolchain-alignment).
#
# BUILDER Dockerfiles are EXEMPT BY DESIGN. They are built on the internet-connected jump box and
# their whole job is to fetch. Scanning them would be the gate misunderstanding the architecture.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/os.sh" 2>/dev/null
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/apps.sh" 2>/dev/null

# The forbidden verbs, COMPOSED at runtime rather than written out. This file is not a Dockerfile so
# it is not in its own corpus today -- but a future caller that widened the corpus to "every file"
# would make the gate flag its own pattern list, and that trap has already fired three times in this
# repo (a comment containing the string a gate scans for). Composing costs one line and removes it.
_pm() { printf '%s-get (install|update|upgrade)|%s add|%s upgrade|yum (install|update)|dnf (install|update)|pip3? install|npm (ci|install|i) |gem install|cargo install|go install|curl [^|]*\| *(ba)?sh|wget [^|]*\| *(ba)?sh' apt apk apk; }

rc=0 scanned=0 flagged=0

# EVERY runtime Dockerfile ON DISK, not just the ENROLLED ones. Deriving the list from the registry
# alone leaves a blind spot exactly where new violations are written: an app's files live under
# apps/<lang>/<app>/ for as long as it takes to finish it, and its row is added LAST. Measured
# 2026-08-22: the registry had 2 apps while 5 runtime Dockerfiles existed, so a registry-only scan
# covered 2 of 5 and would have reported "OK" over three unscanned files.
#
# NOTE this deliberately does NOT name any app -- it globs apps/<lang>/<app>/Dockerfile, so
# check-app-hardcodes stays satisfied and a sixth language needs no edit here.
dockerfiles="$(find apps -mindepth 3 -maxdepth 3 -name Dockerfile -type f 2>/dev/null | sort)"
[ -n "$dockerfiles" ] || { log_error "check-dockerfile-no-install: found ZERO runtime Dockerfiles under apps/ — refusing to report OK over an empty scan"; exit 2; }

while read -r df; do
  [ -n "$df" ] || continue
  app="$(basename "$(dirname "$df")")"

  # A Dockerfile with no identifiable runtime stage would make the scan VACUOUS: sed would print
  # nothing and the app would report clean while installing whatever it likes. Fail instead.
  if ! grep -qE '^FROM .* [Aa][Ss] runtime' "$df"; then
    log_error "  $app: $df has no 'FROM ... AS runtime' stage, so this gate cannot tell which lines ship."
    log_error "        Name the final stage 'runtime' (every other app does) or this check is vacuous for it."
    rc=1; continue
  fi

  scanned=$((scanned + 1))
  # Comments are STRIPPED. This is a must-NOT-exist check, so a commented-out install is harmless --
  # and javawebapp's Dockerfile legitimately EXPLAINS the apt-get that was removed from it. Keeping
  # comments would flag the retraction and teach people to delete the explanation.
  hits="$(sed -n '/^FROM .* [Aa][Ss] runtime/,$p' "$df" | sed 's/#.*//' | grep -nEi "$(_pm)" || true)"
  if [ -n "$hits" ]; then
    log_error "  $app: the RUNTIME stage of $df installs something — that stage is built IN-CLUSTER with no egress:"
    printf '%s\n' "$hits" | sed 's/^/        /'
    log_error "        Bake it into $(dirname "$df")/Dockerfile.builder instead (that one runs on the jump box, which HAS the internet)."
    rc=1; flagged=$((flagged + 1))
  fi
done <<EOF
$dockerfiles
EOF

if [ "$scanned" -eq 0 ]; then
  log_error "check-dockerfile-no-install: scanned ZERO runtime stages — the gate looked at nothing, which is not a pass."
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  log_info "check-dockerfile-no-install: OK — $scanned runtime stage(s) scanned, none installs anything."
else
  log_error "check-dockerfile-no-install: $flagged of $scanned runtime stage(s) reach the network."
fi
exit "$rc"
