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

  # ⚠️ THE TAG MUST ALSO ENCODE EVERY go_get OVERRIDE, NOT JUST THE REF.
  # The ref check alone was byte-identical GREEN in all three of these, MEASURED:
  #   baseline                                   -> rc=0
  #   go_get bumped v0.21.6 -> v0.22.0, tag same -> rc=0   (different content, same tag)
  #   go_get column DELETED entirely, tag same   -> rc=0   (image built WITHOUT the fix)
  # The third is the dangerous one: the image ships under a tag still advertising the override, and
  # every node with imagePullPolicy=IfNotPresent keeps serving the old working image -- a GREEN e2e
  # over a build that no longer contains the fix. That is exactly the incident the header above
  # memorialises, re-armed by the column the header itself calls load-bearing.
  gg="$(selfbuilt_go_get "$name")"
  if [ -n "$gg" ]; then
    for _mod in $gg; do
      _ver="${_mod##*@}"                 # module@vX.Y.Z -> vX.Y.Z
      _bare="${_ver#v}"                  # the tag spells it without the leading v (gcr0.21.6)
      case "$tag" in
        *"$_bare"*) ;;
        *) echo "check-selfbuilt: row '${name}' tag '${tag}' does not encode its go_get override '${_mod}'" >&2
           echo "  Two builds with DIFFERENT dependency pins would share one tag, and a node with" >&2
           echo "  imagePullPolicy=IfNotPresent would keep serving whichever it cached first." >&2
           rc=1 ;;
      esac
    done
  fi

  case "$tag" in
    *"$ref"*) ;;
    *) echo "check-selfbuilt: row '${name}' tag '${tag}' does not contain its git_ref '${ref}'" >&2
       echo "  A bumped ref would ship under the old tag, and imagePullPolicy=IfNotPresent would serve the cached image." >&2
       rc=1 ;;
  esac
done <<< "$(selfbuilt_names)"
[ "$rc" -eq 0 ] || exit 1

echo "check-selfbuilt: clean (${n} self-built image(s); refs immutable, go_get pinned, tags carry their ref)"
