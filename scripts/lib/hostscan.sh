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
HOSTSCAN_ALLOW_DEFAULT='mcr\.microsoft\.com'

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
  grep -rhoE '\b[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(:[0-9]+)?/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]+)' "$mdir" 2>/dev/null \
    | grep -E ':[A-Za-z0-9._-]+$|@sha256:[a-f0-9]+$' \
    | sed -E 's#^([^/]+)/.*#\1|&#' \
    | grep -vE "^(${hosts_re})\|" \
    | grep -vE "^(${HOSTSCAN_ALLOW:-$HOSTSCAN_ALLOW_DEFAULT})\|" \
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
