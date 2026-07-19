#!/usr/bin/env bash
# check-vks-terminology.sh — Broadcom's product nouns, enforced.
#
# WHY THIS EXISTS
# ---------------
# The repo shipped "VCF Supervisor Service" in SIX reader-facing files — a noun Broadcom does not
# use. It is not a harmless embellishment: "VCF Service" and "Supervisor Service" are DIFFERENT,
# deliberately-contrasted things in VCF 9.1 (a VCF Service spans a region and installs from the VCF
# Automation Provider UI; a Supervisor Service deploys on one Supervisor from the vSphere Client).
# The hybrid welds two real terms into one that means nothing, and points an operator at the wrong
# console.
#
# It also shipped "the VKS Supervisor" — a category error. VKS (vSphere Kubernetes Service) is the
# GUEST-cluster offering; in vSphere 9 VKS is ITSELF installed as a Supervisor Service. The
# Supervisor is a vSphere/VCF Supervisor. Nothing that runs ON the Supervisor is "a VKS <thing>",
# and that Supervisor-vs-guest asymmetry is the load-bearing fact of this whole repo (it is why
# `make gitops` needs a second kubeconfig).
#
# Primary sources (fetched live 2026-07-13, the /9-1/ tree serves REAL 9.1 content):
#   "You can deploy Harbor as a Supervisor Service in your Supervisor environment."
#     techdocs.broadcom.com/.../9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html
#     (note: the URL SLUG says vcf-service, the PAGE TITLE says "as a Supervisor Service" — we once
#      transcribed the slug as the title. Follow headings, not slugs.)
#   "The Argo CD Supervisor Service is a Broadcom developed Kubernetes Operator ..."
#     techdocs.broadcom.com/.../9-1/using-argo-cd-service/install-argo-cd-service.html
#   Download taxonomy: subFamily=vSphere Supervisor Services -> displayGroup=Harbor / ArgoCD Service
#
# Prose did not hold this (six files). A gate does.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

cd "$REPO_ROOT" || exit 1
rc=0

# BANNED -> what to say instead. Tab-separated; the pattern is a grep -E regex.
BANNED='VCF Supervisor Services?\tSupervisor Service(s) — Broadcom has no "VCF Supervisor Service". A VCF Service and a Supervisor Service are DIFFERENT things (different console, different scope).
VKS Supervisor\tthe Supervisor. VKS is the GUEST-cluster offering — in vSphere 9 VKS is itself installed AS a Supervisor Service. The Supervisor is not a VKS thing.
VKS Supervisor Services?\tSupervisor Service(s). Prefixing a Supervisor-resident service with VKS asserts the opposite of where it runs.'

# COMMENTS ARE SCANNED TOO. The first draft of this gate stripped comments from .sh files "so a rule
# explaining the banned term does not trip itself" — but this script is already excluded by NAME, and
# stripping comments created a blind spot that immediately hid a real hit: a wrong noun in a
# test-argocd-topology.sh comment. A comment teaches the reader exactly as a heading does.
# STRIP MARKDOWN EMPHASIS BEFORE MATCHING.
#
# The first version grepped the raw text — so `VCF **Supervisor Services**` did NOT match
# `VCF Supervisor Services`, and the phantom noun SHIPPED in two user-facing docs (architecture.md:5,
# scenario-1.md:5) with this gate GREEN beside them, in the very PR that claimed to eliminate it.
#
# A banned PHRASE must be matched against the text a READER sees, not the source bytes. Markdown
# emphasis (**bold**, *italic*, `code`, _under_) is invisible to the reader and must be invisible to
# the gate. This is the "a gate that passes by not looking" failure: green, and measuring nothing.
scan() { sed -E 's/\*\*|__|[*_`]//g' "$1"; }

# EVERY tracked text file — not just *.md/*.sh. The first draft globbed those two extensions and
# MISSED two real hits (.env.example and k8s/gitea/gitea.yaml). A gate's SCOPE LIST is the gate: a
# member you forget is not "not yet covered", it is the defect still shipping with a green check
# beside it. Binary/derived files are excluded by content, not by a hand-kept extension list.
files="$(git ls-files | grep -vE '^(scripts/check-vks-terminology\.sh|docs/diagrams/out/|.*\.(png|svg|jar|ico|gz|tgz))$' \
          | while IFS= read -r f; do [ -f "$f" ] && grep -Iq . "$f" 2>/dev/null && printf '%s\n' "$f"; done)"
n=0
while IFS=$'\t' read -r pat fix || [ -n "${pat:-}" ]; do
  [ -n "${pat:-}" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hits="$(scan "$f" | grep -nE "$pat" || true)"
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      log_error "${f}:${hit%%:*}: banned term — $(printf '%s' "$hit" | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-90)"
      log_error "    use: ${fix}"
      rc=1
    done <<< "$hits"
  done <<< "$files"
done <<< "$(printf '%b' "$BANNED")"

n="$(printf '%s\n' "$files" | grep -c . || true)"
# `n` is a file count, which is normally the metric this repo calls "the bug" — but here it IS the
# item count, because the `grep -Iq .` filter above EXCLUDES a zero-byte file (measured), so `files`
# is files-WITH-CONTENT, not files-opened. The other dimension (BANNED) is a script constant and
# cannot independently go to zero, so `n` is the only starvable axis.
#
# This gate is NOT STARVABLE by the vacuity harness — its corpus is every tracked text file, which
# necessarily includes scripts/lib/os.sh, so a full starvation would empty the gate's own library
# (blast radius) and a partial one leaves a real corpus and yields a false RED. So this guard is a
# CLAIM the harness cannot demonstrate. RED-PROVE IT BY HAND — COPY the gate and its lib into a
# directory that is NOT a git repo, and run it THERE:
#
#   T=$(mktemp -d); mkdir -p "$T/scripts/lib"
#   cp scripts/check-vks-terminology.sh "$T/scripts/"; cp scripts/lib/*.sh "$T/scripts/lib/"
#   ( cd "$T" && bash scripts/check-vks-terminology.sh ); echo "rc=$?"   # -> rc=1, FATAL ... BLIND
#
# NOTE the COPY. Merely `cd`-ing elsewhere and invoking this script by its repo path does NOT work:
# it resolves REPO_ROOT from its own BASH_SOURCE and cd's back here, so it happily scans all 225
# files and prints OK. That was the first RED-proof written into this comment, and it silently
# proved nothing — a recorded RED-proof that cannot fire is worse than none, because the next reader
# runs it, sees green, and concludes the guard works.
[ "$n" -gt 0 ] || die "check-vks-terminology: scanned 0 files — git ls-files returned nothing or the text filter excluded everything. The gate has gone BLIND; a clean result here would mean nothing."
if [ "$rc" -eq 0 ]; then
  log_info "check-vks-terminology: OK — scanned ${n} files; no phantom Broadcom nouns."
else
  log_error "check-vks-terminology: FAILED — see above. Broadcom's noun is 'Supervisor Service'."
fi
exit "$rc"
