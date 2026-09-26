#!/usr/bin/env bash
# check-brew-lists.sh — the macOS (Homebrew) package lists are written in FOUR places and the gnubin
# formula list in THREE, and they had already disagreed (B735): lib/os.sh's hint lacked git, curl,
# openssl@3 and python while the bootstrap installed them. Nothing compared them.
#
# The invariant is NOT "all four are identical" — they legitimately differ:
#   * bootstrap-jumpbox.sh (macOS BASE_PKGS) is the SOURCE: what a fresh Mac gets.
#   * docs/common-bootstrap.md is what an operator TYPES, so it must EQUAL the source.
#   * lib/os.sh prints a MINIMAL hint (the GNU tools its own guard needs); every one of them must be
#     in the source, the docs and 00-install-prereqs.sh, or following the hint leaves a gap.
#   * 00-install-prereqs.sh may add tools (jq) and omit what macOS ships (curl) — it is checked only
#     for the required set.
#   * the three gnubin lists (lib/os.sh, shell-init.sh, Makefile DARWIN_GNU_PATH) must be the SAME
#     set, and each gnubin formula must be installed by the source.
# Offline, no Mac needed.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT" || exit 2
fail=0
err() { printf 'check-brew-lists: %s\n' "$1" >&2; fail=1; }
words() { tr -s ' \t' '\n' | sed '/^$/d' | sort -u; }   # a word list -> sorted unique lines

# Each extraction must find something: an empty list compares equal to another empty list, and a
# gate that parsed nothing would pass (the vacuous-alignment trap).
need() { [ -n "$2" ] || { err "could not extract the $1 list — did its line move? refusing to guess"; exit 1; }; }

src="$(sed -n '/Darwin/,/return 0/s/^ *BASE_PKGS="\(.*\)"$/\1/p' bootstrap-jumpbox.sh | head -1 | words)"
need "bootstrap-jumpbox.sh macOS BASE_PKGS" "$src"
doc="$(sed -n 's/^brew install \(.*\)$/\1/p' docs/common-bootstrap.md | head -1 | words)"
need "docs/common-bootstrap.md brew install" "$doc"
hint="$(sed -n 's/^ *"  brew install \([^"]*\)" \\$/\1/p' scripts/lib/os.sh | head -1 | words)"
need "lib/os.sh hint" "$hint"
pre="$(awk '/pkg_mgr\)" = brew \]; then/{f=1} f && /pkg_install /{sub(/^ *pkg_install /,""); print; exit}' scripts/00-install-prereqs.sh | words)"
need "00-install-prereqs.sh brew pkg_install" "$pre"

g_os="$(grep -o '_brew/opt/[^/]*/libexec/gnubin' scripts/lib/os.sh | sed 's#_brew/opt/##;s#/libexec/gnubin##')"
g_os="$(printf '%s\n' "$g_os" | words)"
need "lib/os.sh gnubin" "$g_os"
g_init="$(sed -n 's/^ *for _f in \(.*\); do _gnu=.*/\1/p' scripts/shell-init.sh | head -1 | words)"
need "shell-init.sh gnubin" "$g_init"
g_mk="$(sed -n 's/^DARWIN_GNU_PATH := .*foreach f,\([^,]*\),.*/\1/p' Makefile | head -1 | words)"
need "Makefile DARWIN_GNU_PATH" "$g_mk"

[ "$doc" = "$src" ] || err "docs/common-bootstrap.md must EQUAL bootstrap-jumpbox.sh's macOS list:
    only in docs:      $(comm -23 <(printf '%s\n' "$doc") <(printf '%s\n' "$src") | tr '\n' ' ')
    only in bootstrap: $(comm -13 <(printf '%s\n' "$doc") <(printf '%s\n' "$src") | tr '\n' ' ')"
for name in src doc pre; do
  missing="$(comm -23 <(printf '%s\n' "$hint") <(printf '%s\n' "${!name}") | tr '\n' ' ')"
  [ -z "$missing" ] || err "the lib/os.sh hint names '$missing' but the ${name} list does not install it"
done
[ "$g_os" = "$g_init" ] && [ "$g_os" = "$g_mk" ] || err "the three gnubin lists differ:
    lib/os.sh:     $(printf '%s' "$g_os" | tr '\n' ' ')
    shell-init.sh: $(printf '%s' "$g_init" | tr '\n' ' ')
    Makefile:      $(printf '%s' "$g_mk" | tr '\n' ' ')"
gm="$(comm -23 <(printf '%s\n' "$g_os") <(printf '%s\n' "$src") | tr '\n' ' ')"
[ -z "$gm" ] || err "gnubin puts '$gm' on PATH but the bootstrap never installs it"

n() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
if [ "$fail" -eq 0 ]; then
  echo "check-brew-lists: OK — source $(n "$src"), docs $(n "$doc"), hint $(n "$hint") (all installed), prereqs $(n "$pre"); gnubin $(n "$g_os") x3 equal"
else
  exit 1
fi
