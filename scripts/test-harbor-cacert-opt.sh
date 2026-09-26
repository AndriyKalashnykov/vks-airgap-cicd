#!/usr/bin/env bash
# test-harbor-cacert-opt.sh — the --cacert that 98-uninstall-all.sh prints into pasteable advice.
# A self-signed Harbor fails the printed curl with rc=60 without it, and the RELATIVE default
# (./secrets/harbor-ca.crt) fails with rc=77 when pasted from another directory, so the DELETE the
# operator believes they sent never is. Offline: the real function, sourced from lib/os.sh ONLY --
# exactly what 98 sources; a first version also sourced harbor.sh and so could not see that 98 lacked it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }
opt() { ( cd "$T" && SKIP_DOTENV=1 HARBOR_INSECURE="$1" HARBOR_CA_FILE="$2" \
          bash -c '. "$1/lib/os.sh"; harbor_curl_cacert_opt; echo " rc=$?"' _ "$SCRIPT_DIR" 2>/dev/null ); }

mkdir -p "$T/secrets" "$T/it's"; printf 'x' > "$T/secrets/ca.crt"; printf 'x' > "$T/it's/ca.crt"; : > "$T/secrets/empty.crt"
o="$(opt 0 ./secrets/ca.crt)"
case "$o" in " --cacert '$T/secrets/ca.crt' rc=0") ok "https + a relative CA -> ABSOLUTE --cacert" ;; *) bad "relative CA -> absolute" "got '$o'" ;; esac
o="$(opt 1 ./secrets/ca.crt)"
case "$o" in " rc=0") ok "http (insecure) -> no --cacert" ;; *) bad "http -> none" "got '$o'" ;; esac
o="$(opt 0 ./secrets/empty.crt)"
case "$o" in " rc=0") ok "an EMPTY CA file -> no --cacert (a flag naming nothing would fail)" ;; *) bad "empty CA -> none" "got '$o'" ;; esac
o="$(opt 0 ./secrets/absent.crt)"
case "$o" in " rc=0") ok "an absent CA file -> no --cacert" ;; *) bad "absent CA -> none" "got '$o'" ;; esac
o="$(opt 0 "./it's/ca.crt")"
case "$o" in " rc=2") ok "a CA path with a single quote -> refused (rc 2), nothing printed" ;; *) bad "quote in path" "got '$o'" ;; esac

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
