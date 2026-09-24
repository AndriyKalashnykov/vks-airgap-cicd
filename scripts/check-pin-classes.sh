#!/usr/bin/env bash
# check-pin-classes.sh — Gate (B738): every version pin in .env.example declares WHO owns it.
#
# load_env treats the two classes oppositely, so an unmarked pin is a silent policy choice:
#   repo  (`# renovate:` on the line above) — .env.example wins; an old copy in .env is ignored
#   lab   (`# pin: lab` on the line above)  — .env wins; it must match the licensed artifacts you hold
# Fails when:
#   - an ACTIVE *_VERSION / *_TAG key has neither marker directly above it
#   - a `# pin: lab` marker is not directly followed by an active KEY= line (it marks nothing)
#   - it classified nothing at all (a blind gate reads as a clean one)
# The markers are read by the SAME function load_env uses (pin_keys), so the gate cannot drift from it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
EX="${PIN_CLASSES_FILE:-${REPO_ROOT}/.env.example}"
[ -s "$EX" ] || die "check-pin-classes: ${EX} is missing or empty"

repo="$(pin_keys repo "$EX")"
lab="$(pin_keys lab "$EX")"
classified="$(printf '%s\n%s\n' "$repo" "$lab" | grep -c . || true)"
[ "$classified" -gt 0 ] || die "check-pin-classes: classified 0 pins in ${EX} — the markers or pin_keys are broken"

rc=0
pins=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  pins=$((pins + 1))
  if ! printf '%s\n%s\n' "$repo" "$lab" | grep -qxF "$k"; then
    log_error "check-pin-classes: ${k} is a version pin with no owner. Put ONE of these on the line above it:"
    log_error "    # renovate: datasource=... depName=...   (the repo owns it; .env cannot freeze it)"
    log_error "    # pin: lab                                (the licensed artifacts you hold; .env wins)"
    rc=1
  fi
done <<EOF
$(grep -oE '^[A-Z_][A-Z0-9_]*(VERSION|_TAG)=' "$EX" | tr -d '=')
EOF

dangling="$(awk 'pend { if ($0 !~ /^[A-Z_][A-Z0-9_]*=/) print pl; pend = 0 }
                 /^# pin: lab[[:space:]]*$/ { pend = 1; pl = NR }
                 END { if (pend) print pl }' "$EX")"
if [ -n "$dangling" ]; then
  log_error "check-pin-classes: '# pin: lab' marks no key (line(s) ${dangling//$'\n'/, } of ${EX}): the key must be the very next line"
  rc=1
fi

[ "$rc" -eq 0 ] || die "check-pin-classes: FAILED"
log_info "check-pin-classes: OK — ${pins} version pin(s) in .env.example, every one owned (repo $(printf '%s\n' "$repo" | grep -c .), lab $(printf '%s\n' "$lab" | grep -c .))"
