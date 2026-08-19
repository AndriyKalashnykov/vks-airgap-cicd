#!/usr/bin/env bash
# 23-mirror-verify.sh — verify every mirrored image is INTACT in Harbor.
#
# Why this exists: `crane push` verifies the local->registry transfer, but nothing
# confirmed Harbor SERVES the images intact afterwards. Registry blob corruption
# (e.g. from concurrent load during a mirror) surfaces LATER as a Kaniko/pull
# `MANIFEST_UNKNOWN` / `BLOB_UNKNOWN` mid-pipeline — the worst place to find it.
# For a human operator on a real jump box, this is the "are the images good?"
# gate to run AFTER `make mirror`, BEFORE driving the pipeline.
#
# Two checks per image:
#   1. INTEGRITY (hard gate) — `crane validate --remote <dst>` fetches the manifest
#      AND every layer blob and verifies their digests. A missing/corrupt blob or
#      manifest FAILS here. (MIRROR_VERIFY_FAST=1 -> --fast: manifest/config only,
#      skips layer download; faster but does NOT catch a corrupt layer blob.)
#   2. PROVENANCE (reported) — Harbor's digest vs the source digest recorded in
#      images.lock at pull time. A match proves Harbor serves the exact content we
#      mirrored. A benign difference can occur when crane rewraps a multi-arch
#      OCI layout, so a mismatch WITH integrity OK is a WARN, not a failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
# shellcheck source=scripts/lib/progress.sh
. "${SCRIPT_DIR}/lib/progress.sh"

require_cmd crane

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${BUNDLE_DIR:?}"
LOCK_FILE="${BUNDLE_DIR}/images.lock"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
# harbor_setup exports SSL_CERT_FILE (crane trusts the self-signed CA) + sets
# HARBOR_TLS_VERIFY; crane uses a boolean --insecure flag for the plain-HTTP mode.
harbor_setup "$HARBOR_TMP"
INSECURE=(); [ "$HARBOR_TLS_VERIFY" = "false" ] && INSECURE=(--insecure)

FAST=(); [ "${MIRROR_VERIFY_FAST:-0}" = "1" ] && FAST=(--fast)

# lock_digest SRC -> the source digest recorded for SRC in images.lock (empty if none).
lock_digest() {
  [ -f "$LOCK_FILE" ] || { printf ''; return; }
  awk -v s="$1" '$1==s {print $2; exit}' "$LOCK_FILE"
}

mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images to verify (run 'make mirror' first)"
[ -f "$LOCK_FILE" ] || log_warn "no images.lock at $LOCK_FILE — provenance check skipped (run 'make mirror-pull' to generate it)"

log_info "verifying ${#IMAGES[@]} images in Harbor $HARBOR_URL/$HARBOR_INFRA_PROJECT (mode: ${MIRROR_VERIFY_FAST:+fast}${MIRROR_VERIFY_FAST:-full})"
# _verify_class <crane-stderr> — TRANSPORT | CORRUPT | UNCLASSIFIED.
#
# WHY THIS EXISTS. `crane validate --remote` fails for two completely different reasons, and this
# script used to report BOTH as "Harbor's copy is corrupt/incomplete (re-mirror)". On the air-gap
# box "re-mirror" means RE-CARRYING A 12 GB BUNDLE ACROSS THE GAP. MEASURED — real crane stderr for
# a Harbor ref is 339 bytes, and the old `cut -c1-200` left the operator with:
#
#     … dial tcp: lookup harbor.env1.lab.test on 12
#
# `no such host` — the words that refute the corruption verdict — were cut off ENTIRELY, and the
# run then died telling them to re-carry the bundle. For a DNS typo. That is this corpus's own
# "an error message that names the wrong cause is worse than a crash", at its most expensive.
#
# ⚠️ UNCLASSIFIED IS TREATED AS CORRUPT, DELIBERATELY. `unexpected EOF` is BOTH the network-cut
# signature AND the 2026-07-13 blob-store corruption signature; it is genuinely ambiguous. A
# classifier that guessed "transient" there would silently downgrade a real corruption to a
# warning, which is the one failure this gate exists to prevent. Fail toward corrupt, and print the
# FULL stderr so the operator can judge what the classifier could not.
_verify_class() {
  case "$1" in
    *"mismatched digest"*|*"mismatched diffid"*|*"undersized layer"* \
      |*"does not match expected size"*|*MANIFEST_UNKNOWN*|*BLOB_UNKNOWN*) printf 'CORRUPT' ;;
    *"no such host"*|*"connection refused"*|*"i/o timeout"*|*"no route to host"* \
      |*"certificate signed by unknown authority"*|*"x509:"*|*"TLS handshake"* \
      |*"server gave HTTP response to HTTPS client"*|*"context deadline exceeded"*) printf 'TRANSPORT' ;;
    *) printf 'UNCLASSIFIED' ;;
  esac
}

fails=0; warns=0; transport_fails=0
pg_init "${#IMAGES[@]}"
for src in "${IMAGES[@]}"; do
  dst="$(mirror_target_ref "$src")"
  pg_step "verify $dst"
  # 1. INTEGRITY (hard gate)
  if ! err="$(crane validate --remote "$dst" "${FAST[@]}" "${INSECURE[@]}" 2>&1)"; then
    cls="$(_verify_class "$err")"
    if [ "$cls" = TRANSPORT ]; then
      # NOT an integrity verdict. Say so in the label, because the label is what a hurried operator
      # reads, and "INTEGRITY FAIL" on a DNS error is how the 12 GB re-carry gets started.
      log_error "  UNREACHABLE     $dst  (transport/trust — NOT an integrity verdict)"
      transport_fails=$((transport_fails+1))
    else
      log_error "  INTEGRITY FAIL  $dst${cls:+  [${cls}]}"
      fails=$((fails+1))
    fi
    # 800, not 200: the real message is 339 bytes and the discriminating words are at the END of
    # it. Truncating below the length of the thing you are truncating is how the evidence for the
    # correct diagnosis gets removed while the wrong one is printed in full.
    log_error "    $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-800)"
    continue
  fi
  # 2. PROVENANCE (reported; WARN-only when integrity already passed)
  want="$(lock_digest "$src")"
  if [ -n "$want" ]; then
    got="$(crane digest "$dst" "${INSECURE[@]}" 2>/dev/null || true)"
    if [ "$got" = "$want" ]; then
      log_info "  OK    $dst (integrity + digest $got)"
    else
      log_warn "  WARN  $dst integrity OK but digest differs from lock (want $want got ${got:-<none>}) — likely OCI-layout rewrap"
      warns=$((warns+1))
    fi
  else
    log_info "  OK    $dst (integrity; no lock digest to match)"
  fi
done

# TWO verdicts, because there are two causes and they have OPPOSITE remedies. Transport is checked
# FIRST: when Harbor is simply unreachable EVERY image "fails", and telling the operator to re-carry
# 12 GB because their DNS is wrong is the most expensive wrong answer this script can give.
if [ "$transport_fails" -gt 0 ] && [ "$fails" -eq 0 ]; then
  die "$transport_fails/${#IMAGES[@]} images could not be REACHED — this is NOT an integrity verdict and Harbor's copy is NOT known to be bad. Check the endpoint, DNS and CA trust (make harbor-reachable), then re-run. Do NOT re-mirror on the strength of this."
fi
if [ "$fails" -gt 0 ]; then
  # ⚠️ NOT `${transport_fails:+...}`. `:+` tests for a NON-EMPTY string, and "0" is non-empty, so
  # that form appends the suffix even when there were zero transport failures. Test the NUMBER.
  # `if`, not `[ ... ] && _also=...`: the AND-list returns 1 on the false branch, and under
  # `set -e` that kills the script one line before the die it was decorating.
  _also=""
  if [ "$transport_fails" -gt 0 ]; then
    _also=" — plus ${transport_fails} UNREACHABLE, which are a SEPARATE problem and not evidence of corruption"
  fi
  die "$fails/${#IMAGES[@]} images FAILED integrity — Harbor's copy is corrupt/incomplete (re-mirror; see the no-concurrent-load rule)${_also}"
fi
pg_done "mirror-verify: ${#IMAGES[@]} images intact in Harbor${warns:+ (${warns} provenance warnings)}"
