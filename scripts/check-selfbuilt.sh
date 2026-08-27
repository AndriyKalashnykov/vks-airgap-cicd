#!/usr/bin/env bash
# check-selfbuilt.sh — images/selfbuilt.tsv is VALID and NON-EMPTY.
#
# WHY THIS EXISTS. An implementation round REFUTED my claim that check-image-alignment was the
# backstop for a deleted row. MEASURED on the branch: deleting the kaniko row -- and even deleting
# images/selfbuilt.tsv entirely -- left the alignment gate at rc=0 with BYTE-IDENTICAL output,
# because its self-built branch is only reached for a repo ABSENT from images.txt, and both scripts
# then `exit 0` with a cheerful INFO line. So the inventory was unguarded by construction: an image
# we BUILD could silently stop being built, and the first symptom would be an ImagePullBackOff at the
# far end of the pipeline, on the air-gap box.
#
# It also enforces the reproducibility contract the TSV header argues for: an immutable, version-
# shaped git_ref and a concretely-pinned go_get. `selfbuilt_validate` does the per-row work; this
# gate adds the DENOMINATOR, which is the part that catches an empty or vanished inventory.
#
# RED-PROOF (do it, do not assume): delete the kaniko row -> this gate must exit non-zero.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
REPO_ROOT="$ROOT"; export REPO_ROOT
# shellcheck source=scripts/lib/selfbuilt.sh
. "${ROOT}/scripts/lib/selfbuilt.sh"

f="$(selfbuilt_file)"
if [ ! -f "$f" ]; then
  echo "check-selfbuilt: ERROR — ${f} is MISSING." >&2
  echo "  It is the inventory of images this repo BUILDS because no free published build exists." >&2
  echo "  Losing it silently stops building them; nothing else in the tree notices." >&2
  exit 1
fi

n="$(selfbuilt_names | grep -c . || true)"
if [ "${n:-0}" -eq 0 ]; then
  echo "check-selfbuilt: ERROR — ${f} lists ZERO images." >&2
  echo "  If that is intentional, delete the file and the two selfbuilt-* targets in the same change;" >&2
  echo "  an empty inventory that still ships targets is a silent no-op, not a configuration." >&2
  exit 1
fi

selfbuilt_validate || { echo "check-selfbuilt: ${f} has invalid row(s) — see above." >&2; exit 1; }

# Every row's tag must carry its git_ref, so a bumped ref cannot ship under the old tag. That is the
# mutable-tag hazard that already cost this repo an e2e cycle: the KinD nodes served a cached image
# because new content was pushed under a tag they already had (imagePullPolicy=IfNotPresent).
rc=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  ref="$(selfbuilt_git_ref "$name")"; tag="$(selfbuilt_tag "$name")"
  case "$tag" in
    *"$ref"*) ;;
    *) echo "check-selfbuilt: row '${name}' tag '${tag}' does not contain its git_ref '${ref}'" >&2
       echo "  A bumped ref would ship under the old tag, and imagePullPolicy=IfNotPresent would serve the cached image." >&2
       rc=1 ;;
  esac
done <<< "$(selfbuilt_names)"
[ "$rc" -eq 0 ] || exit 1

echo "check-selfbuilt: clean (${n} self-built image(s); refs immutable, go_get pinned, tags carry their ref)"
