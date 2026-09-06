#!/usr/bin/env bash
# bundle-orphans.sh — REPORT artefacts in bundle/ that no longer belong. PRINTS, NEVER DELETES.
#
# WHY A REPORTER AND NOT A PRUNE (B709). The row prescribed a deleter. An adversary round refuted
# that against three precedents set in this same tree on the same day:
#   B704: "only then consider an opt-in prune, which must never remove a file it cannot prove is dead"
#   B706: a `die` over disk waste ON THE INTERNET BOX was refuted as a FALSE-BLOCK and shipped as a
#         log_warn naming each file WITH ITS SIZE
#   B707: "a READ-ONLY reporter prints what is safely deletable ... NEVER SHIP A DELETER FIRST"
# The harm here is CARRY WEIGHT, not correctness — measured: 22-builder-push.sh:81-84 drives off
# app_names and does a NAMED lookup (${IN_DIR}/${app}-builder.tar). It never globs the directory, so
# an orphan is never opened and never pushed. (Contrast mirror_collect_images, which greps EVERY file
# in manifests/ — that glob is why B705 was a correctness bug and this is not.)
#
# WHY NOT builders/ ALONE. B709 named builders/ (3.8 G) — which has ZERO orphans today, so a prune
# there would print `0 pruned` forever, a denominator indistinguishable from a broken check. The live
# orphans are in charts/. Two of bundle/'s six subdirs already have prunes (images/ via
# mirror_prune_cache, manifests/ via mirror_prune_manifests + B705's air-gap replace); this reports
# the three that do not.
#
# EVERY keep-set here is DERIVED — from apps/registry.tsv, from the version pins, from
# images/selfbuilt.tsv — so it follows a Renovate bump or a registry edit and cannot rot into an
# enumerated list.
#
# ⚠️ WHAT THIS DOES NOT DO: it does not delete, it does not gate (always exits 0), and it cannot tell
# a truncated tarball from a good one — 14-builder-build.sh:129 saves at the FINAL name with no .tmp
# staging, so an interrupted save leaves a short file the glob matches. The printed size is the only
# tell, which is why sizes are printed rather than counts alone.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh
# shellcheck source=scripts/lib/apps.sh
. scripts/lib/apps.sh
load_env

# ARG BEATS ENV, deliberately. `.env.example:1898` carries BUNDLE_DIR=./bundle UNCOMMENTED, so
# load_env's `set -a` CLOBBERS a per-run `BUNDLE_DIR=... make bundle-orphans` back to ./bundle
# (MEASURED: the override does not survive, and SKIP_DOTENV=1 does not help because .env.example is
# still sourced). An explicit positional argument cannot be clobbered by anything, which is also what
# makes this script testable against a fixture tree.
BD="${1:-${BUNDLE_DIR:-./bundle}}"
[ -d "$BD" ] || { log_info "bundle-orphans: no $BD on this box — nothing to report."; exit 0; }

total=0; found=0
_report() {   # $1=label  $2=file  -> print + accumulate
  local sz; sz="$(stat -c %s "$2" 2>/dev/null || echo 0)"
  total=$((total + sz)); found=$((found + 1))
  printf '  ORPHAN  %-10s %-46s %s\n' "$1" "$(basename "$2")" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")"
}

# --- builders/ : keep an <app>-builder.tar iff <app> is a ROW in apps/registry.tsv ---------------
# Keyed on REGISTRY MEMBERSHIP, not on app_has_builder(). That function is a FILE TEST
# (lib/apps.sh: Dockerfile.builder exists), so a missing or renamed file would silently narrow the
# keep-set and mark a LIVE app's 1.2 GB tarball an orphan. A registry row is a reviewed edit; a
# file's presence is not. registry.tsv's own header calls removing a row a sanctioned workflow.
if [ -d "$BD/builders" ]; then
  keep_apps=" $(app_names | tr '\n' ' ') "
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    a="$(basename "$f")"; a="${a%-builder.tar}"
    case "$keep_apps" in *" $a "*) ;; *) _report builders "$f" ;; esac
  done < <(find "$BD/builders" -maxdepth 1 -type f -name '*-builder.tar' 2>/dev/null)
fi

# --- charts/ : keep a .tgz iff its version suffix matches a live PIN ------------------------------
# Derived from the pins, not from an enumerated chart list, so an ISTIO_VERSION bump moves the
# keep-set automatically. Orphans here are INERT — 46-install-istio.sh CONSTRUCTS the wanted
# filename from the pin and dies if absent, explicitly refusing a glob fallback — so this is purely
# carry weight. It is also the only one of the three with orphans TODAY.
if [ -d "$BD/charts" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="$(basename "$f")"
    case "$b" in
      *"-${ISTIO_VERSION:-__none__}.tgz"|*"-${HEADLAMP_VERSION:-__none__}.tgz") ;;
      *) _report charts "$f" ;;
    esac
  done < <(find "$BD/charts" -maxdepth 1 -type f -name '*.tgz' 2>/dev/null)
fi

# --- selfbuilt/ : keep a .tar iff its name is a ROW in images/selfbuilt.tsv -----------------------
if [ -d "$BD/selfbuilt" ] && [ -f images/selfbuilt.tsv ]; then
  keep_sb=" $(grep -vE '^\s*#|^\s*$' images/selfbuilt.tsv | awk -F'\t' '{print $1}' | tr '\n' ' ') "
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(basename "$f")"; n="${n%.tar}"
    case "$keep_sb" in *" $n "*) ;; *) _report selfbuilt "$f" ;; esac
  done < <(find "$BD/selfbuilt" -maxdepth 1 -type f -name '*.tar' 2>/dev/null)
fi

# The DENOMINATOR is what makes a zero trustworthy: "0 orphans of 13 examined" is a measurement,
# "0 orphans" alone is indistinguishable from a check that looked at nothing.
examined=$(find "$BD/builders" "$BD/charts" "$BD/selfbuilt" -maxdepth 1 -type f \
             \( -name '*-builder.tar' -o -name '*.tgz' -o -name '*.tar' \) 2>/dev/null | wc -l)
if [ "$found" -eq 0 ]; then
  log_info "bundle-orphans: none — examined ${examined} artefact(s) across builders/ charts/ selfbuilt/"
else
  log_warn "bundle-orphans: ${found} orphan(s) of ${examined} examined — $(numfmt --to=iec "$total" 2>/dev/null || echo "${total}B") carried across the air gap every generation"
  log_warn "  These are SAFE to delete on the INTERNET box (rebuildable there). Nothing here deletes them."
  log_warn "  Review the list above, then remove the ones you recognise."
fi
exit 0    # a PRINTER, never a gate — see the header
