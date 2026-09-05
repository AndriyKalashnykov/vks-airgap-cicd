#!/usr/bin/env bash
# test-verify-marker-build.sh — the predicate deciding whether the DEPLOYED image is the build of
# the marker commit verify_app just pushed.
#
# WHY IT EXISTS (measured 2026-08-27, e2e run 8). verify_app used to wait for the image to be
# != pre_img, which ANY image change satisfies. pythonwebapp had two PipelineRuns in flight:
#   ci-v8lx9  14:06:20-14:06:54  triggered BEFORE the marker push at 14:10:00 -- unrelated
#   ci-5l22n  14:10:02-14:10:28  the marker's own build
# The stray run's tag write-back rolled the image before the wait began, satisfying it with 0s delay
# where every other app took +5s. verify then polled for the marker in the WRONG image for ten
# minutes and died 'end result not observed' -- an error naming the page, about a page that was
# never going to contain it.
#
# HONESTY -- WHAT THIS DOES AND DOES NOT PROVE. It RECONSTRUCTS the predicate's logic with kubectl
# stubbed; it does NOT source the real one, which lives inside verify_app and is not extractable
# without refactoring that function. So it guards the LOGIC (tag parsing, the prefix test, the
# unattributable cases) and CANNOT catch the predicate being deleted, renamed, or never invoked.
# The authoritative proof is a green end-to-end run. If you change the predicate in 99-verify.sh,
# change it here too: nothing enforces that.
# ⚠️ REWRITTEN when the DEPLOYED TAG became the app's DECLARED VERSION rather than the commit sha.
# The old cases pinned a sha-PREFIX test, and after the predicate changed they kept passing while
# testing a predicate the product no longer contains — green over dead code, because (per the note
# above) this file RE-IMPLEMENTS the predicate instead of sourcing it. That is the hazard this
# comment block already warned about, realised. If you change it in 99-verify.sh, change it here.
new_ver="0.1.1"
CUR=""
kubectl() { printf '%s' "$CUR"; }
ns=x; app=y

_img_is_marker_build() {
  local cur tag
  cur="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{...}' 2>/dev/null)" || return 1
  tag="${cur##*:}"
  case "$cur" in *@sha256:*) return 1 ;; esac
  [ -n "$tag" ] && [ "$tag" != "$cur" ] || return 1
  # EQUALITY: a version is exact, nobody abbreviates it.
  [ "$tag" = "$new_ver" ]
}

t() { CUR="$2"; if _img_is_marker_build; then r=MATCH; else r=no; fi
      if [ "$r" = "$3" ]; then printf '  ok    %-46s -> %s\n' "$1" "$r"
      else printf '  FAIL  %-46s -> %s (want %s)\n' "$1" "$r" "$3"; fail=1; fi; }
fail=0

t "this release's build"                  "reg/apps/py:0.1.1"                       MATCH
t "the PREVIOUS release (not ours)"       "reg/apps/py:0.1.0"                       no
t "a NEWER release than ours"             "reg/apps/py:0.1.2"                       no
# The sha is still a SECOND tag on the same digest, but it is NOT what gets deployed — so a
# deployment sitting on a sha tag means the write-back did not land, and must NOT read as success.
t "a sha tag (the write-back did NOT run)" "reg/apps/py:5981b0e"                    no
t "the seeded UNPULLABLE placeholder"     "reg/apps/py:NEVER-BUILT-RUN-THE-PIPELINE" no
t "no tag at all"                         "reg/apps/py"                             no
t "digest-pinned (unattributable)"        "reg/apps/py@sha256:5981b0ecafe1234567890" no
t "empty (kubectl returned nothing)"      ""                                        no
# A version is a PREFIX of a longer one; equality must reject it, or 0.1.1 would satisfy 0.1.10.
t "a LONGER version with ours as prefix"  "reg/apps/py:0.1.10"                      no
t "registry with a PORT, our release"     "reg:5000/apps/py:0.1.1"                  MATCH
t "registry with a PORT, wrong release"   "reg:5000/apps/py:0.1.0"                  no

printf '  --- %s ---\n' "$([ $fail -eq 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
