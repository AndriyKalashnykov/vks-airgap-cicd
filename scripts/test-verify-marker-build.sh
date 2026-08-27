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
marker_sha="5981b0ecafe1234567890abcdef1234567890abcd"
CUR=""
kubectl() { printf '%s' "$CUR"; }
ns=x; app=y

_img_is_marker_build() {
  local cur tag
  cur="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{...}' 2>/dev/null)" || return 1
  tag="${cur##*:}"
  case "$cur" in *@sha256:*) return 1 ;; esac
  [ -n "$tag" ] && [ "$tag" != "$cur" ] || return 1
  [ "${#tag}" -ge 7 ] && [ "${marker_sha#"$tag"}" != "$marker_sha" ]
}

t() { CUR="$2"; if _img_is_marker_build; then r=MATCH; else r=no; fi
      if [ "$r" = "$3" ]; then printf '  ok    %-46s -> %s\n' "$1" "$r"
      else printf '  FAIL  %-46s -> %s (want %s)\n' "$1" "$r" "$3"; fail=1; fi; }
fail=0

t "this marker's build (7-char tag)"      "reg/apps/py:5981b0e"                     MATCH
t "this marker's build (12-char tag)"     "reg/apps/py:5981b0ecafe1"                MATCH
t "A DIFFERENT build (the run-8 bug)"     "reg/apps/py:d443b2a"                     no
t "the seeded pre-image 0.1.0"            "reg/apps/py:0.1.0"                       no
t "no tag at all"                         "reg/apps/py"                             no
t "digest-pinned (unattributable)"        "reg/apps/py@sha256:5981b0ecafe1234567890" no
t "empty (kubectl returned nothing)"      ""                                        no
t "short tag that is a sha prefix (:598)" "reg/apps/py:598"                         no
t "registry with a PORT, correct sha"     "reg:5000/apps/py:5981b0e"                MATCH
t "registry with a PORT, wrong sha"       "reg:5000/apps/py:d443b2a"                no

printf '  --- %s ---\n' "$([ $fail -eq 0 ] && echo ALL PASS || echo FAILURES)"
exit $fail
