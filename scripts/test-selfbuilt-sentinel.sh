#!/usr/bin/env bash
# test-selfbuilt-sentinel.sh — the skip-sentinel of 14-selfbuilt-build.sh must key on the FULL
# build identity (the TAG), never on the git ref alone.
#
# WHY THIS EXISTS (measured 2026-08-27): the sentinel compared the recorded stamp against the git
# REF. Reverting the ggcr dependency override v0.21.6 -> v0.21.9 leaves the ref at v1.25.18, so the
# STALE v0.21.6 tarball was reused while WEARING the v0.21.9 tag. The e2e's kaniko step then hung
# 8m16s on the v0.21.6 pullLimiter deadlock, and the failure pointed at kaniko rather than at the
# sentinel. check-selfbuilt.sh already REQUIRES the tag to encode every go_get override, so the tag
# is the complete identity by construction.
#
# The discriminator is the REAL script, not a reconstruction of its condition: the fixture's git URL
# is unreachable, so SKIP => rc 0 with the skip line, REBUILD => a clone attempt that fails loudly.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/selfbuilt-sentinel.XXXXXX")"
cleanup() { rm -rf -- "$T"; }
trap cleanup EXIT

cp -r "${SRC_ROOT}/scripts" "$T/scripts"
mkdir -p "$T/images" "$T/bundle/selfbuilt"
# load_env FATALs without it: .env.example is the committed source of truth for every tunable.
cp "${SRC_ROOT}/.env.example" "$T/.env.example"

# One row, unreachable URL. Columns must match images/selfbuilt.tsv's header.
hdr="$(grep -m1 -E '^#[[:space:]]*name' "${SRC_ROOT}/images/selfbuilt.tsv" || true)"
printf '%s\n' "${hdr:-# name	git_url	git_ref	dockerfile	target	repo_path	tag	go_get}" > "$T/images/selfbuilt.tsv"
printf 'probe\tfile:///nonexistent-%s\tv1.0.0\tDockerfile\t\tprobe\tv1.0.0-dep1.2.3\t\n' "$$" \
  >> "$T/images/selfbuilt.tsv"

TAG='v1.0.0-dep1.2.3'
REF='v1.0.0'
TAR="$T/bundle/selfbuilt/probe.tar"
STAMP="$T/bundle/selfbuilt/.probe.built"

# Decide from the REAL script's behaviour. "skip" is the ONLY outcome that reports the skip line.
decide() {
  local out
  out="$(cd "$T" && BUNDLE_DIR="$T/bundle" REPO_ROOT="$T" \
        bash "$T/scripts/14-selfbuilt-build.sh" 2>&1)"
  case "$out" in
    *"already built at"*) printf 'skip' ;;
    *)                    printf 'rebuild' ;;
  esac
}

printf '%s\n' "== selfbuilt sentinel =="

# The fixture must be able to produce BOTH answers, or the test discriminates nothing.
: > "$TAR"; printf 'x\n' > "$TAR"          # non-empty
printf '%s\n' "$TAG" > "$STAMP"
if [ "$(decide)" = skip ]; then ok "current tag + tarball -> SKIP"
else bad "current tag + tarball -> SKIP (fixture cannot skip; test is vacuous)"
fi

# THE DEFECT: same git ref, different dependency override => a DIFFERENT tag.
printf '%s\n' "v1.0.0-dep1.2.0" > "$STAMP"
if [ "$(decide)" = rebuild ]; then ok "stale TAG, same git ref -> REBUILD"
else bad "stale TAG, same git ref -> REBUILD"
fi

# A bare git ref must NOT satisfy a tag-keyed stamp.
printf '%s\n' "$REF" > "$STAMP"
if [ "$(decide)" = rebuild ]; then ok "bare git ref in stamp -> REBUILD (THE SHIPPED DEFECT: a ref-keyed sentinel wrote the ref, so a go_get change still matched and skipped)"
else bad "bare git ref in stamp -> REBUILD  <-- ref-keyed sentinel is blind to a dependency-override change"
fi

# Missing tarball wins over a matching stamp.
printf '%s\n' "$TAG" > "$STAMP"; rm -f "$TAR"
if [ "$(decide)" = rebuild ]; then ok "no tarball -> REBUILD"
else bad "no tarball -> REBUILD"
fi

# Empty tarball (a died-mid-save artifact) must not count.
: > "$TAR"
if [ "$(decide)" = rebuild ]; then ok "empty tarball -> REBUILD"
else bad "empty tarball -> REBUILD"
fi

# The force escape hatch.
printf 'x\n' > "$TAR"; printf '%s\n' "$TAG" > "$STAMP"
out="$(cd "$T" && BUNDLE_DIR="$T/bundle" REPO_ROOT="$T" SELFBUILT_FORCE=1 \
      bash "$T/scripts/14-selfbuilt-build.sh" 2>&1)"
case "$out" in *"already built at"*) bad "SELFBUILT_FORCE=1 -> REBUILD" ;;
               *)                    ok  "SELFBUILT_FORCE=1 -> REBUILD" ;; esac

# ROUND-TRIP: the case that binds the stamp WRITE to the stamp COMPARE.
# Every case above writes the fixture stamp ITSELF, so none of them observes what the script
# actually writes. An adversary proved that blindness exploitable: mutating ONLY the write
# (tag -> ref) while leaving the compare correct left this file 6/6 GREEN, with the sentinel a
# PERMANENT NO-OP -- the stamp could never equal the tag again, so every run paid a full clone and
# container build, silently, forever. Here the SCRIPT writes the stamp and the NEXT run reads it.
rt_probe() {
  local d="$T/rt"; rm -rf "$d"; mkdir -p "$d/bin"
  # Fake git: clone produces a minimal tree. Fake engine: `save -o <f>` writes a non-empty file.
  # Quoted heredocs: this is the TEXT of the fake binaries, so $@ / \n must stay literal.
  # (Written with echo previously, which drew SC2016+SC2028 -- correct warnings about text that is
  # deliberately unexpanded. A quoted heredoc makes that literal by construction, not by suppression.)
  cat > "$d/bin/git" <<'FAKEGIT'
#!/usr/bin/env bash
if [ "${1:-}" = clone ]; then
  for a in "$@"; do t="$a"; done
  mkdir -p "$t"
  printf 'FROM scratch\n' > "$t/Dockerfile"
fi
exit 0
FAKEGIT
  cat > "$d/bin/podman" <<'FAKEENGINE'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && printf 'tar\n' > "$a"
  prev="$a"
done
exit 0
FAKEENGINE
  chmod +x "$d/bin/git" "$d/bin/podman"
  ( cd "$T" && PATH="$d/bin:$PATH" CONTAINER_ENGINE=podman SELFBUILT_FORCE=1 \
      bash "$T/scripts/14-selfbuilt-build.sh" >/dev/null 2>&1 ) || return 1
  [ -s "$STAMP" ] || return 1
}
if rt_probe; then
  # LINE 1, not the whole file: the stamp now carries the tag on line 1 and the image's lock record
  # on line 2, so a SKIPPED image can re-emit its record instead of the lock self-erasing (the
  # 0-byte selfbuilt.lock measured 2026-08-28). The skip comparison reads `head -1` for the same
  # reason, which is also what keeps an OLD one-line stamp valid.
  got="$(head -1 "$STAMP" 2>/dev/null)"
  if [ "$got" = "$TAG" ]; then ok "round-trip: the script WRITES the tag on line 1 (write bound to compare)"
  else bad "round-trip: the script writes the tag (wrote [$got], want [$TAG])"
  fi
  if [ -n "$(sed -n '2p' "$STAMP" 2>/dev/null)" ]; then ok "round-trip: line 2 carries the lock record (so a skip can re-emit it)"
  else bad "round-trip: the stamp has no line 2 — a skipped image would vanish from selfbuilt.lock"
  fi
  if [ "$(decide)" = skip ]; then ok "round-trip: the NEXT run skips on what the script itself wrote"
  else bad "round-trip: the NEXT run skips on what the script itself wrote"
  fi
else
  printf '  SKIP  round-trip (fake git/engine probe could not complete)\n'
fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
