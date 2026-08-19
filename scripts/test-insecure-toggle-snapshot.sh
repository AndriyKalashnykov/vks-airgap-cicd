#!/usr/bin/env bash
# ci-tier: fast — offline; throwaway REPO_ROOTs under mktemp, no network, no cluster.
#
# test-insecure-toggle-snapshot.sh — `.env.state` IS A THIRD CLOBBER CHANNEL, and the two values it
# could silently pin are TLS VERIFICATION and BLOB INTEGRITY.
#
# `load_env` sources, in order: `.env.example`, `.env`, then the discovered-state overlay
# `.env.state` — all under `set -a`, all AFTER the caller's environment. So the LAST file wins over
# the command line. `check-env-clobber` cannot see this and is not wrong to miss it: it is a gate
# over the COMMITTED `.env.example`, where these ship commented. The overlay is written by OUR OWN
# tooling (`state_set` in 05-kind-up.sh / 06-install-harbor.sh / 07-install-argocd.sh).
#
# MEASURED before the fix, with a discriminating control:
#     HARBOR_INSECURE=0    + overlay 1 -> 1     caller DEFEATED
#     ARGOCD_INSECURE=0    + overlay 1 -> 1     caller DEFEATED
#     MIRROR_VERIFY_FAST=0 + .env    1 -> 1     caller DEFEATED
#     HARBOR_URL=X         + overlay Y -> X     already snapshotted -> SURVIVED
# That last row is why the probe is trustworthy: it proves the harness is not simply overwriting
# everything, which is the way this measurement would otherwise lie.
#
# WHY THESE THREE. The first two pin TLS verification OFF with no way back from the command line —
# and CLAUDE.md already records this exact incident through the OTHER channel (`make e2e-kind
# HARBOR_INSECURE=1` silently ran the full SECURE stack), so this is a recurrence via a new sink.
# The third turns `crane validate` into `--fast`, which 23-mirror-verify.sh:14-15 says is
# "manifest/config only, skips layer download" — i.e. it skips precisely the blob fetch that caught
# the 2026-07-13 Harbor wipe (153 manifest links, ZERO blobs, a state `--fast` passes clean).
#
# ⚠️ ARM 2 IS NOT PADDING, AND IT IS THE HALF THAT CONSTRAINS THE FIX. A "fix" that forced these to
# a fixed value, or that snapshotted unconditionally, would break the KinD flow — where the overlay
# legitimately records "this Harbor WAS installed insecure" and must still apply when the caller is
# silent. The `[ -n "${!_sel:-}" ]` guard is what makes the pair possible, and only the pair
# discriminates a working snapshot from a stuck one.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# Replay load_env in a throwaway REPO_ROOT. The real .env/.env.state are never read or written.
#   $1 = file to plant the clobber in (.env | .env.state)
#   $2 = line to plant
#   $3 = var name
#   $4 = value the CALLER exports, or the empty string for "caller sets nothing"
probe() {
  local T out; T="$(mktemp -d)"
  cp .env.example "$T/.env.example" 2>/dev/null || { rm -rf "$T"; printf 'NOENVEXAMPLE'; return; }
  printf '%s\n' "$2" > "$T/$1"
  cp -r scripts "$T/scripts"
  out="$( cd "$T" || exit 1
          [ -n "${4:-}" ] && export "$3=$4"
          . scripts/lib/os.sh >/dev/null 2>&1
          load_env >/dev/null 2>&1
          printf '%s' "${!3:-<unset>}" )"
  rm -rf "$T"
  printf '%s' "$out"
}

# ── ARM 1: the caller's EXPLICIT choice must beat the overlay / .env ──────────────────────────────
for v in HARBOR_INSECURE ARGOCD_INSECURE; do
  got="$(probe .env.state "${v}=1" "$v" 0)"
  if [ "$got" = 0 ]; then
    ok "${v}: caller 0 beats a .env.state 1 (TLS verification cannot be pinned off)"
  else
    bad "${v}: caller said 0, got '${got}'. The state overlay is sourced LAST, so it outranks the
        command line — an insecure-mode install pins TLS verification OFF and there is no way to
        turn it back on for a single run."
  fi
done

got="$(probe .env 'MIRROR_VERIFY_FAST=1' MIRROR_VERIFY_FAST 0)"
if [ "$got" = 0 ]; then
  ok "MIRROR_VERIFY_FAST: caller 0 beats a .env 1 (blob validation cannot be silently skipped)"
else
  bad "MIRROR_VERIFY_FAST: caller said 0, got '${got}'. --fast is manifest/config only, so a .env
        line downgrades the ONLY gate that detected the 2026-07-13 Harbor blob wipe — and the
        operator cannot re-enable it for one run."
fi

# ── ARM 2: with the caller SILENT, the overlay must still apply (the KinD flow depends on it) ─────
for v in HARBOR_INSECURE ARGOCD_INSECURE; do
  got="$(probe .env.state "${v}=1" "$v" '')"
  if [ "$got" = 1 ]; then
    ok "${v}: caller silent -> the overlay still wins (the insecure KinD flow is not broken)"
  else
    bad "${v}: with no caller value the overlay must apply; got '${got}'. A snapshot that fires
        unconditionally would force the secure path onto a Harbor that was installed insecure, and
        every subsequent pull would fail TLS. The [ -n ... ] guard is what prevents this."
  fi
done

got="$(probe .env 'MIRROR_VERIFY_FAST=1' MIRROR_VERIFY_FAST '')"
if [ "$got" = 1 ]; then
  ok "MIRROR_VERIFY_FAST: caller silent -> the .env value still applies (the knob still works)"
else
  bad "MIRROR_VERIFY_FAST: with no caller value the .env setting must apply; got '${got}'."
fi

# ── THE DISCRIMINATING CONTROL. Without it, arm 1 passing proves nothing about the MECHANISM —
# a harness bug that dropped every sourced file would produce the same six PASSes above. ──────────
got="$(probe .env.state 'INGRESS_CONTROLLER=traefik' INGRESS_CONTROLLER istio)"
if [ "$got" = istio ]; then
  ok "control: an ALREADY-snapshotted selector also survives, so the probe reaches load_env"
else
  bad "control: INGRESS_CONTROLLER has been snapshotted since long before this change and must
        survive; got '${got}'. If THIS fails, the harness is broken, not the product — every other
        case above is measuring nothing."
fi

# And the inverse control: a var that is deliberately NOT snapshotted must still be clobberable,
# or the snapshot list has silently become "everything" and this file cannot detect a regression.
got="$(probe .env.state 'GITEA_ADMIN_USER=fromoverlay' GITEA_ADMIN_USER fromcaller)"
if [ "$got" = fromoverlay ]; then
  ok "control: a NON-snapshotted var is still overridden by the overlay (the list is still a list)"
else
  bad "control: GITEA_ADMIN_USER is not in the snapshot list, so the overlay should win; got
        '${got}'. Either it was added to the list (update this case and say why) or the guard now
        fires for everything, which would break every flow that relies on discovered state."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — the caller can re-secure TLS and blob validation for a single run, and a silent\n'
printf '          caller still gets the discovered state.\n'
