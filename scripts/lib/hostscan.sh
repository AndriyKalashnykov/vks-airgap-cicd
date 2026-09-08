#!/usr/bin/env bash
# hostscan.sh — find registry hosts in carried manifests that NOTHING will mirror or rewrite.
#
# ⚠️ IT FLAGS THE UNHANDLED HOST. It does not search for known ones, and that direction is the
# whole point: searching for hosts you already thought of can only ever re-find them. This asks the
# complementary question — "which host-shaped strings are NOT covered by MIRROR_REGISTRY_HOSTS?" —
# so a host nobody has thought of yet is exactly what it reports.
#
# MEASURED 2026-09-08, the incident that motivates it: Tekton's controller injects a `place-scripts`
# init container from a hardcoded `-shell-image` FLAG STRING (not an `image:` field), pointing at
# cgr.dev/chainguard/busybox. Neither the mirror alternation nor the install-time rewrite carried
# `cgr.dev`, so on a LIVE air-gapped lab every TaskRun pod pulled busybox from the public internet.
# An image-oriented check could not have seen it; this one keys on the HOST, wherever it appears.
#
# ⚠️ SCOPE: the MANIFEST dir only. Carried helm CHARTS (.tgz) are out of scope BY CONSTRUCTION --
# they are gzipped, so grep is structurally blind there and "found nothing" could never mean
# anything. They are covered instead by their explicit `--set image…`/`--set global.hub` overrides
# at install time and, for Istio, by `make verify-gateway-image` at runtime. In-tree k8s/ deploy/
# apps/ kind/ are also unscanned; measured clean at the time of writing.
#
# shellcheck shell=bash
[ -n "${__VKS_HOSTSCAN_SH_LOADED:-}" ] && return 0
__VKS_HOSTSCAN_SH_LOADED=1

# hostscan_unhandled <manifest-dir> -> prints "host<TAB>count<TAB>example" per UNHANDLED host
#
# A "registry host" here is a dotted label sequence with a known-registry shape immediately followed
# by `/`. Bare `docker.io`-implied refs (`busybox:1.36`) are deliberately NOT matched: they carry no
# host, the rewrite cannot act on them, and treating every `word/word` as a registry would flag
# every file path in every manifest.
# Hosts we have DECIDED not to mirror, each with the reason and the evidence. This is deliberately
# NOT a convenience list: every entry is a claim that the ref cannot execute here, and a claim that
# a future change can falsify. Keep it to lines you can defend.
#
#   mcr.microsoft.com — Tekton's `-shell-image-win` flag (tekton-pipelines-v1.15.0.yaml:26843),
#     three lines below the `-shell-image` that caused the cgr.dev incident. It is the WINDOWS
#     variant, and this cluster's nodes are Linux: MEASURED 0 running containers from that host on
#     the live lab. Mirroring a Windows PowerShell image to satisfy a flag no node can execute
#     would add hundreds of MB to an air-gap bundle for nothing.
#     ⚠️ IF A WINDOWS NODE EVER JOINS, THIS ENTRY IS WRONG and the image must be mirrored.
#
# ⚠️ THERE IS DELIBERATELY NO ENV OVERRIDE. An earlier draft had `${HOSTSCAN_ALLOW:-$DEFAULT}`, and
# it was wrong twice: (a) it REPLACED the default rather than appending, so setting it to add one
# host silently dropped mcr.microsoft.com; and (b) far worse, it let anyone silence this gate from
# the environment with NO RECORDED REASON -- the "downgrade a failing contract to advisory to get
# green" move this repo treats as the cardinal fake-green. Adding a host here must cost an edit, a
# reason and a measurement, because that is what the entry IS.
HOSTSCAN_ALLOW='mcr\.microsoft\.com'
# The ref pattern, single-sourced so the SCAN and the DENOMINATOR below cannot drift apart.
#
# ⚠️ THE HOST CLASS IS DELIBERATELY [A-Za-z0-9._-], AND THE LOWERCASE VERSION WAS A REAL HOLE.
# An implementation round MEASURED it, and I reproduced it before fixing: with a lowercase-only
# class the leftmost match cannot BEGIN on an uppercase or `_` label, so it starts AFTER it and the
# `sed` below takes the TRUNCATED prefix as the host -- which then matches the mirrored-host list
# and is silently EXEMPTED:
#
#     EU.gcr.io/myteam/app:v1       -> host reported as `gcr.io`     -> SILENTLY EXEMPTED
#     my_mirror.gcr.io/team/app:v1  -> host reported as `gcr.io`     -> SILENTLY EXEMPTED
#     eu.gcr.io/team/app:v1         -> host reported as `eu.gcr.io`  -> flagged (the control)
#
# `eu.gcr.io` and `us.gcr.io` are REAL Google hosts that neither the mirror alternation nor the
# install-time rewrite handles, so the truncation forged an exemption for exactly the class of
# unmirrored host this scanner exists to report. Re-measured after the widening: all three flag
# with their FULL host, and 0 false positives across k8s/ deploy/ apps/ kind/ and bundle/manifests.
#
# ⚠️ A TAG OR A DIGEST IS REQUIRED, and it is the whole discriminator -- it lives in the MANDATORY
# final group of THIS regex, not in a separate filter. MEASURED: without it, a naive host-shaped
# scan finds 32 "hosts" on the carried Tekton manifests, of which 31 are Kubernetes API groups
# (rbac.authorization.k8s.io/v1), label keys, doc URLs and examples -- 97% false-RED, the rate at
# which a gate gets deleted. With it: exactly 1, the real image. (An earlier draft carried a SECOND
# `grep -E` re-asserting the tag; a round measured its output byte-identical with and without,
# because this group is mandatory. It was dead code presented as the safety net, and it is gone.)
#
# ⚠️ NAMED RESIDUAL -- a BARE, UNTAGGED ref on an unmirrored host is NOT reported:
#     registry.example.io/team/app        MISS  (would pull :latest from the public internet)
#     registry.example.io/x@sha512:abc    MISS  (OCI permits sha512; we match sha256 only)
#     10.0.0.5:5000/team/app:v1           MISS  (no dotted TLD-ish tail)
# That is the price of the 97%-noise fix above, paid knowingly. `mirror_collect_images` drops bare
# refs too, so such a ref is neither mirrored NOR reported -- the two blind spots line up. If this
# ever bites, the fix is a non-fatal WARN arm, not a widening of the fatal one.
HOSTSCAN_REF_RE='\b[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z]{2,}(:[0-9]+)?/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]+)'

# THE DENOMINATOR. Without it, "every ref is on a mirrored host" and "I could not read the corpus"
# print the SAME sentence. MEASURED: `chmod 000` on the one file holding a real violation gave rc=0
# and an empty result -- the gate reported OK over the exact breach it exists to catch. `2>/dev/null`
# and `|| true` are right for tolerating I/O, and they are PRECISELY what makes an unreadable corpus
# indistinguishable from a clean one, so the CALLER must check these counts and refuse on zero.
# Real carried corpus, measured 2026-09-08: 6 files, 15 tagged refs. Zero of either is a defect.
hostscan_nfiles() { find "${1:?}" -type f 2>/dev/null | wc -l | tr -d " "; }
hostscan_nrefs()  { grep -rhoE "$HOSTSCAN_REF_RE" "${1:?}" 2>/dev/null | wc -l | tr -d " "; }


hostscan_unhandled() {
  local mdir="${1:?hostscan_unhandled: manifest dir required}"
  [ -d "$mdir" ] || return 0
  local hosts_re="${MIRROR_REGISTRY_HOSTS:?hostscan: MIRROR_REGISTRY_HOSTS unset — source lib/mirror.sh}"
  # A host must contain a dot and a TLD-ish tail, so `kube-system/foo` and `apps/v1` cannot match.
  # ⚠️ A TAG OR A DIGEST IS REQUIRED, and it is the whole discriminator. Without it this scan is
  # ~97% noise on real manifests -- MEASURED: 32 "hosts", of which 31 were Kubernetes API groups
  # (rbac.authorization.k8s.io/v1), label keys (app.kubernetes.io/name), doc URLs
  # (www.apache.org/licenses/LICENSE-2.0) and examples (foo.example.com). Exactly ONE was a real
  # image ref. A gate at that false-RED rate is one people delete, so the noise is not cosmetic.
  # API groups and label keys never carry `:tag` or `@sha256:`; image refs essentially always do,
  # and this repo already REQUIRES it of every discovered ref (lib/mirror.sh).
  grep -rhoE "$HOSTSCAN_REF_RE" "$mdir" 2>/dev/null \
    | sed -E 's#^([^/]+)/.*#\1|&#' \
    | grep -vE "^(${hosts_re})\|" \
    | grep -vE "^(${HOSTSCAN_ALLOW})\|" \
    | awk -F'|' '{ n[$1]++; if (!(($1) in ex)) ex[$1]=$2 } END { for (h in n) printf "%s\t%s\t%s\n", h, n[h], ex[h] }' \
    | sort || true
  # ⚠️ THE `|| true` IS LOAD-BEARING, AND ITS ABSENCE BREAKS THE HAPPY PATH, NOT THE SAD ONE.
  # Every caller runs `set -euo pipefail`. On a CLEAN corpus the exclusion greps filter every ref
  # away and exit 1; pipefail promotes that to the pipeline, the caller's `_x="$(hostscan_unhandled)"`
  # returns 1, and `set -e` kills the script -- so the guard dies precisely when it should pass.
  # MEASURED before the fix: a one-line all-covered corpus gave rc=1 and the next statement never ran.
  # It cannot mask a real error: the directory is existence-checked above, and an unreadable file
  # would still yield no unhandled hosts (fail-open on I/O is the same posture as the `2>/dev/null`).
  # test-hostscan.sh pins this directly -- the unit tests alone CANNOT see it, because the harness
  # does not run under the caller's set flags.
}
