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
# ⚠️ MATCH THE ERROR **CODE TOKEN**, NEVER THE TRAILING PROSE (B703, measured on live Harbor).
# Harbor's absent-PROJECT error is:
#     UNAUTHORIZED: project nosuchproject not found: project nosuchproject not found
# It contains BOTH `UNAUTHORIZED` and `not found`, so a prose match makes ORDER decide the verdict,
# and AUTH's remedy ("request a fresh credential") vs ABSENT's ("re-mirror this one image") is
# exactly the expensive inversion for the RULE ZERO-B tenant who CANNOT self-renew a credential.
# Matching `UNAUTHORIZED:` (the code token, first field after the URL colon) removes the ambiguity.
#
# ORDER: CORRUPT, then TRANSPORT, then AUTH, then ABSENT.
#   TRANSPORT before ABSENT — a plain-HTTP-behind-https endpoint's stderr carries BOTH
#     `server gave HTTP response to HTTPS client` AND `not found`; test-mirror-verify-class.sh
#     already ships that exact shape as a committed TRANSPORT fixture.
#
# ⚠️ ABSENT SYSTEMATICALLY UNDER-DETECTS, and that is inherent to the code token, not a bug to fix.
# Registries hide EXISTENCE behind authorization — MEASURED: Docker Hub returns `UNAUTHORIZED:
# authentication required` for an absent REPOSITORY (MANIFEST_UNKNOWN only for an absent TAG in a
# repo that exists), and Harbor returns `UNAUTHORIZED: project ... not found` for an absent PROJECT.
# So an artifact genuinely ABSENT because its project or repo is gone is reported as AUTH, sending a
# tenant to their platform team for a credential that is fine. That is the SAFE direction (its remedy
# is "ask", not "re-carry 12 GB"), and no text rule can separate the two — the registry declines to
# say. Named here rather than silently mis-attributed.
#   AUTH before ABSENT — DEFENSIVE, and the justification is weaker than it first looks.
#     ⚠️ MEASURED 2026-09-06: swapping these two arms does NOT change the verdict for the real
#     Harbor project string, because that string's only CODE TOKEN is `UNAUTHORIZED:` — its
#     "not found" is lowercase PROSE, which this classifier deliberately does not match. So
#     code-token matching is what removes the ambiguity; the ordering is a second line of defence
#     for a hypothetical stderr carrying BOTH code tokens. That case is not observed in the wild,
#     so it is pinned by a SYNTHETIC fixture (clearly labelled as such) rather than left as an
#     untested claim — an ordering nothing can RED-prove is decoration.
#
# ⚠️ MANIFEST_UNKNOWN MOVED FROM CORRUPT TO ABSENT (B703 finding (b)). It is the OCI-STANDARD
# signature for an ABSENT tag — measured 3/3 on Docker Hub, gcr.io and ghcr.io. The corruption
# signature of the 2026-07-13 lying-registry incident was "153 manifest links, ZERO blobs", i.e.
# manifests PRESENT and blobs gone, which is **BLOB_UNKNOWN** — that stays CORRUPT.
_verify_class() {
  case "$1" in
    # ⚠️ ARCH-ABSENT FIRST, and it is EXCLUSIVE: `crane validate --platform` errors out before it
    # validates anything, so this string cannot co-occur with a corruption string. It is an operator
    # CONFIG fault (MIRROR_ARCH names an arch this index does not contain), not an integrity verdict,
    # and without its own arm it fell to UNCLASSIFIED -> probe -> CORRUPT -> "re-carry 12 GB".
    *"no child with platform"*) printf 'ARCH-ABSENT' ;;
    # ⚠️ THESE ARE THE STRINGS go-containerregistry 0.21.9 ACTUALLY EMITS, extracted from the module
    # cache, NOT written from memory. An idea round measured that the previous patterns matched
    # almost NONE of them: `mismatched digest` does not match `mismatched layer[0] digest:`, nor
    # `mismatched config digest:`, nor `mismatched manifest digest:`. EIGHT of ten real corruption
    # signatures classified UNCLASSIFIED and were caught ONLY by `_verify_probe` — so the text arm
    # was very nearly decorative on the image path, while its own test pinned it green with a
    # SYNTHETIC string (`mismatched digest: got ... want ...`) that occurs only on the non-image
    # `default:` branch of validateChildren and therefore never on the path every mirrored image
    # takes. `mismatched number of diffids` is 0.22.x's; harmless here and correct after a bump.
    *"mismatched layer["*|*"mismatched config digest"*|*"mismatched config size"* \
      |*"mismatched manifest digest"*|*"mismatched number of diffids"* \
      |*"error verifying "*|*"does not match requested digest"* \
      |*"mismatched digest"*|*"mismatched diffid"*|*"undersized layer"* \
      |*"does not match expected size"*|*BLOB_UNKNOWN*) printf 'CORRUPT' ;;
    *"no such host"*|*"connection refused"*|*"i/o timeout"*|*"no route to host"* \
      |*"certificate signed by unknown authority"*|*"x509:"*|*"TLS handshake"* \
      |*"server gave HTTP response to HTTPS client"*|*"context deadline exceeded"*) printf 'TRANSPORT' ;;
    *UNAUTHORIZED:*|*DENIED:*|*FORBIDDEN:*) printf 'AUTH' ;;
    *NOT_FOUND:*|*MANIFEST_UNKNOWN:*) printf 'ABSENT' ;;
    *) printf 'UNCLASSIFIED' ;;
  esac
}

# ⚠️ THERE IS NO harbor-auth-check PRECONDITION ON THIS TARGET, and that is deliberate — see the
# comment above `mirror-verify:` in the Makefile. The AUTH class below IS the mechanism: it gives a
# rejected credential its own verdict and its own remedy, instead of letting it reach the corrupt
# tally and prescribe a 12 GB re-carry. Related and unfixed: B710 measured that `harbor-auth-check`
# is a NO-OP for the default `robot$...` credential anyway (HTTP 412 -> "inconclusive" -> exit 0),
# so it could not have been the backstop even where it does run.
# _verify_probe <dst> — ASK, DON'T PARSE (B703's surviving design).
#
# The only distinction that costs 12 GB is CORRUPT-vs-ABSENT, and it is structurally decidable with
# ZERO text parsing: after a `crane validate` failure, fetch the MANIFEST.
#   rc=0  => the manifest is served => the failure was in the layers/blobs => CORRUPT
#            (exactly the 2026-07-13 shape: manifests present, blobs gone)
#   rc!=0 => the manifest itself is unreachable; only THEN split by text, where all remaining
#            remedies agree on "do NOT re-carry the bundle", so a mistake is cheap.
# Immune to upstream rewording, registry choice and Harbor version.
#
# ⚠️ This does NOT reintroduce the 2026-07-13 HEAD-lies hazard: that lie was a *blob* HEAD served
# from Redis's descriptor cache; `crane manifest` is a GET of the manifest BODY.
# ⚠️ On a multi-arch index `crane manifest` fetches the INDEX only, so a dangling child gives rc=0
# => CORRUPT — which is the correct verdict per spec (MANIFEST_BLOB_UNKNOWN).
# Cost: one extra request, for FAILING images only.
# ⚠️ NOT SOUND UNDER MIRROR_VERIFY_FAST=1, so the caller must not rely on it there. `crane validate
# --fast` is "Skip downloading/digesting layers" (measured from --help), so "manifest served =>
# the failure was in the layers/blobs" cannot hold — no layers were fetched. validate and this probe
# would then fetch nearly the same object, and a transient manifest flake would be labelled CORRUPT,
# i.e. "re-carry 12 GB". FAST is a documented operator knob (docs/scenario-1-notes.md), not
# hypothetical, so the caller SKIPS the probe in fast mode and leaves the text verdict standing.
_verify_probe() {
  local _mout _mrc=0
  _mout="$(crane manifest "$1" "${INSECURE[@]}" 2>&1)" || _mrc=$?
  if [ "$_mrc" -eq 0 ]; then printf 'CORRUPT'; else _verify_class "$_mout"; fi
}

fails=0; warns=0; transport_fails=0; absent_fails=0; auth_fails=0; arch_fails=0
pg_init "${#IMAGES[@]}"
for src in "${IMAGES[@]}"; do
  dst="$(mirror_target_ref "$src")"
  pg_step "verify $dst"
  # 1. INTEGRITY (hard gate)
  # ⚠️ `--platform` IS THE FIX, and it is upstream-sanctioned: go-containerregistry PR #1776, which
  # ADDED the index-wide platform check, says in as many words "If you pass a --platform flag, it
  # will behave how it previously behaved." With it, crane runs validate.Image on the ONE child that
  # matters -- full layer/config/manifest verification -- and never invokes validatePlatform.
  # MEASURED on the failing index: no flag -> rc=1 FAIL in 6.6s (8 children); --platform linux/amd64
  # -> rc=0 PASS in 1.3s. Safe on single-arch images too (verified on distroless), so it is applied
  # unconditionally rather than only to indexes.
  #
  # ⚠️ SCOPE REDUCTION, DISCLOSED: for a multi-arch index we now blob-validate ONE child (the arch
  # this box runs) and skip validateIndexManifest. The other children's blobs are NOT validated --
  # a Harbor that lost only an arm64 blob would read green here. That is bounded (nothing pulls
  # them) and it is the honest cost of not asking a text classifier to adjudicate a publisher's
  # metadata. The digest evidence below, and images.lock, are what cover the index itself.
  #
  # ⚠️ NOT AT THE MIRROR. Copying a single arch was refuted by lib/mirror.sh's own comment: digest-
  # pinned refs must copy EVERY arch or the index digest changes and the by-digest pull that
  # 41-install-tekton.sh rewrites would fail MANIFEST_UNKNOWN on every TaskRun. Narrow the CHECK,
  # never the COPY.
  if ! err="$(crane validate --platform "linux/${MIRROR_ARCH:-amd64}" --remote "$dst" "${FAST[@]}" "${INSECURE[@]}" 2>&1)"; then
    cls="$(_verify_class "$err")"
    # FLAPPING-LINK MITIGATION (B703, graded `inferred` — the hole this guards is reasoned, not
    # observed). `crane validate` fetches EVERY blob (long, many requests) while `_verify_probe`'s
    # `crane manifest` is ONE small GET immediately afterwards. Under a flapping link a transient
    # fault kills validate and lets manifest succeed => rc=0 => CORRUPT => "re-carry 12 GB": the
    # exact expensive answer this design exists to prevent, reachable by a network blip. So when the
    # VALIDATE stderr already looks like transport, trust that and do NOT probe.
    # ⚠️ CORRUPT IS DEFINITIVE AND MUST NOT BE OVERWRITTEN (found by the implementation round).
    # The first version guarded only one direction (validate=TRANSPORT -> skip the probe) and left
    # the mirror image wide open. MEASURED with an injected crane: `BLOB_UNKNOWN` (the documented
    # 2026-07-13 corruption signature) + a probe that times out => FINAL=TRANSPORT, and with fails==0
    # the transport die then says verbatim "Harbor's copy is NOT known to be bad ... Do NOT re-mirror
    # on the strength of this." A PROVEN corruption downgraded into an instruction not to fix it —
    # the exact inversion of this script's own "fail toward corrupt". The trigger is not exotic: a
    # registry pod rolling makes validate see a blob error and the follow-up manifest GET time out,
    # i.e. the same event as the 2026-07-13 incident.
    # So probe ONLY when the text classifier was inconclusive. Also saves a request.
    case "$cls" in
      # ⚠️ ARCH-ABSENT MUST BE HERE. A round measured that adding a class to `_verify_class` WITHOUT
      # adding it to this list is a NO-OP: it falls to `*)`, the probe runs, `crane manifest` on an
      # index returns rc=0, and the verdict is overwritten with CORRUPT. The class is computed and
      # immediately discarded. Trace any new class through to the `die`, not just to the classifier.
      TRANSPORT|CORRUPT|ARCH-ABSENT) : ;;           # already definitive — do not second-guess it
      *) # see _verify_probe's header: the probe's inference is UNSOUND with --fast, so in fast
         # mode leave the text verdict standing rather than manufacture a CORRUPT.
         if [ "${MIRROR_VERIFY_FAST:-0}" != "1" ]; then
           cls="$(_verify_probe "$dst")"
         fi ;;
    esac
    # ⚠️ THE `*)` ARM IS THE FAIL-SAFE AND MUST STAY LAST. Every class that is not explicitly
    # non-integrity falls to `fails`, which is what makes UNCLASSIFIED behave as CORRUPT — see the
    # "UNCLASSIFIED IS TREATED AS CORRUPT, DELIBERATELY" note above. A `case` is used rather than an
    # if/elif chain precisely so that adding a class cannot silently bypass the tally.
    case "$cls" in
      TRANSPORT)
        # NOT an integrity verdict. Say so in the label, because the label is what a hurried operator
        # reads, and "INTEGRITY FAIL" on a DNS error is how the 12 GB re-carry gets started.
        log_error "  UNREACHABLE     $dst  (transport/trust — NOT an integrity verdict)"
        transport_fails=$((transport_fails+1)) ;;
      ABSENT)
        log_error "  ABSENT          $dst  (not present in Harbor — NOT corruption)"
        absent_fails=$((absent_fails+1)) ;;
      AUTH)
        log_error "  UNAUTHORIZED    $dst  (credential rejected — NOT an integrity verdict)"
        auth_fails=$((auth_fails+1)) ;;
      ARCH-ABSENT)
        log_error "  ARCH ABSENT     $dst  (MIRROR_ARCH not in this index — a CONFIG fault, NOT corruption)"
        arch_fails=$((arch_fails+1)) ;;
      *)
        log_error "  INTEGRITY FAIL  $dst${cls:+  [${cls}]}"
        fails=$((fails+1)) ;;
    esac
    # 800, not 200: the real message is 339 bytes and the discriminating words are at the END of
    # it. Truncating below the length of the thing you are truncating is how the evidence for the
    # correct diagnosis gets removed while the wrong one is printed in full.
    log_error "    $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-800)"
    # ⚠️ REPORT THE PROVENANCE DIGEST ON THE FAILING PATH TOO. It used to `continue` straight past
    # section 2, so the ONE structural discriminator was withheld from exactly the operator facing a
    # 12 GB decision -- and this incident had to be settled by hand with two `crane digest` calls.
    # A digest that MATCHES images.lock beside a validate failure is definitionally "our copy is
    # byte-for-byte what we pulled", which is evidence no text classifier can produce.
    _w="$(lock_digest "$src")"
    if [ -n "$_w" ]; then
      _g="$(crane digest "$dst" "${INSECURE[@]}" 2>/dev/null || true)"
      if [ "$_g" = "$_w" ]; then
        log_error "    evidence: Harbor's digest MATCHES images.lock ($_g) — the copy is byte-for-byte what we pulled."
      else
        log_error "    evidence: Harbor's digest ${_g:-<unreadable>} does NOT match images.lock $_w"
      fi
    fi
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
  die "$transport_fails/${#IMAGES[@]} images could not be REACHED — this is NOT an integrity verdict and Harbor's copy is NOT known to be bad. Check the endpoint, DNS and CA trust (make harbor-reachable), then re-run. Do NOT re-mirror on the strength of this.${_also}"
fi
# ⚠️ BUILT ONCE, ABOVE ALL FOUR DIES. The first version built `_also` inside the `fails` branch
# only, so the TRANSPORT die swallowed the ABSENT and AUTH counts entirely — MEASURED across all 11
# tally combinations: (transport=1, absent=1, auth=1, fails=0) printed only "1/N could not be
# REACHED" and never mentioned the other two. The operator fixes DNS, re-runs, and only then learns
# there was more. On a gate whose stated principle is that the verdict line is the one sentence an
# operator acts on, a two-pass discovery is a defect.
#
# ⚠️ NOT `${transport_fails:+...}`. `:+` tests for a NON-EMPTY string, and "0" is non-empty, so that
# form appends the suffix even when the count is zero. Test the NUMBER. And `if`, not
# `[ ... ] && _also=...`: the AND-list returns 1 on the false branch, and under `set -e` that kills
# the script one line before the die it was decorating.
_also=""
if [ "$transport_fails" -gt 0 ]; then
  _also="${_also} — plus ${transport_fails} UNREACHABLE, a SEPARATE problem and not evidence of corruption"
fi
if [ "$absent_fails" -gt 0 ]; then
  _also="${_also} — plus ${absent_fails} ABSENT (not present in Harbor), a SEPARATE problem"
fi
if [ "$auth_fails" -gt 0 ]; then
  _also="${_also} — plus ${auth_fails} UNAUTHORIZED (credential rejected), a SEPARATE problem"
fi

if [ "$fails" -gt 0 ]; then
  die "$fails/${#IMAGES[@]} images FAILED integrity — Harbor's copy is corrupt/incomplete (re-mirror; see the no-concurrent-load rule)${_also}"
fi
# AUTH before ABSENT: an expired credential can render a present image as absent-looking, so a
# credential problem must never be reported as "these images are missing, re-mirror them".
if [ "$auth_fails" -gt 0 ]; then
  die "$auth_fails/${#IMAGES[@]} images could not be read because Harbor REJECTED the credential — this is NOT an integrity verdict and NOTHING is known to be missing or corrupt. Per RULE ZERO-B the common case is a tenant whose robot credential was handed over and CANNOT be self-renewed: request a fresh one, then re-run. Do NOT re-mirror and do NOT re-carry the bundle."
fi
if [ "$arch_fails" -gt 0 ]; then
  die "$arch_fails/${#IMAGES[@]} images do not contain platform linux/${MIRROR_ARCH:-amd64} — this is a CONFIG fault in .env, NOT corruption and NOT a missing image. Harbor's copy is NOT known to be bad. Set MIRROR_ARCH to an arch these indexes actually carry (amd64|arm64) and re-run. Do NOT re-mirror and do NOT re-carry the bundle."
fi
if [ "$absent_fails" -gt 0 ]; then
  die "$absent_fails/${#IMAGES[@]} images are ABSENT from Harbor — the manifest is not served, so Harbor's copy of the REMAINING images is NOT known to be bad. Re-push just these ('make mirror' is resumable and cache-skips what is already intact). Do NOT re-carry the 12 GB bundle on the strength of this."
fi
# ⚠️ BELT AND BRACES — the success line below is the one sentence an operator acts on, and B703
# records the exact way it goes wrong: give a new class a NON-FATAL branch and, with fails=0, NO die
# fires, so the gate prints "N images intact" and EXITS 0 while N are absent. That is a false green
# carrying a literally false sentence, on the gate that stands before an air-gap install. This guard
# makes the success line structurally unreachable whenever ANY tally is non-zero, so a future class
# added without its own die fails LOUD instead of passing silently.
_tot=$((fails + transport_fails + absent_fails + auth_fails + arch_fails))
if [ "$_tot" -gt 0 ]; then
  die "INTERNAL: ${_tot} image(s) failed but no specific verdict fired (fails=$fails transport=$transport_fails absent=$absent_fails auth=$auth_fails arch=$arch_fails) — refusing to report the mirror intact. A verification class was added without a matching die."
fi
pg_done "mirror-verify: ${#IMAGES[@]} images intact in Harbor${warns:+ (${warns} provenance warnings)}"
