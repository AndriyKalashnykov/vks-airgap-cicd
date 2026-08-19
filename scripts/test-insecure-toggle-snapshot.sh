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
  # ⚠️ SCRUB THE AMBIENT ENVIRONMENT. Measured: `HARBOR_INSECURE=0 ./this-test` made arm 2 FAIL,
  # because the "caller silent" case inherited the ambient value and the caller was never silent —
  # and the failure text blames the PRODUCT ("a snapshot that fires unconditionally..."). An
  # inherited REPO_ROOT (os.sh EXPORTS it) is worse: the probe reads the real repo instead of its
  # fixture, 4 FAILs. The repo's own convention for this is test-env-validate.sh:56.
  # shellcheck disable=SC2016  # the `bash -c` body below is single-quoted DELIBERATELY: $3/$4
  # must expand in the CHILD, from the positional args passed after the `_`, so the probe runs
  # under the scrubbed environment. Double quotes would expand them in the PARENT and defeat
  # the `env -u` scrub this whole block exists for.
  # ⚠️ And the directive goes HERE, not inside the command: a comment between backslash-
  # continued lines is a SYNTAX ERROR (SC1073/SC1126), which is how the first attempt broke it.
  out="$( cd "$T" || exit 1
          env -u HARBOR_INSECURE -u ARGOCD_INSECURE -u MIRROR_VERIFY_FAST \
              -u ARGOCD_ADMIN_PASSWORD -u GITEA_ADMIN_PASSWORD -u ARGOCD_LB_IP \
              -u INGRESS_CONTROLLER -u GITEA_ADMIN_USER -u REPO_ROOT -u VKS_STATE_FILE \
              bash -c '
                [ -n "${4:-}" ] && export "$3=$4"
                . scripts/lib/os.sh >/dev/null 2>&1
                load_env >/dev/null 2>&1
                printf "%s" "${!3:-<unset>}"
              ' _ "$1" "$2" "$3" "${4:-}" )"
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

# ── THE CREDENTIAL CLASS — the same defect, found by an adversary round on the commit above. ─────
# ARGOCD_ADMIN_PASSWORD / GITEA_ADMIN_PASSWORD are `state_set` into the overlay (05-kind-up.sh:131,
# :142) and ship in .env.example as `# VAR=<SET-IN-.env>`, i.e. documented operator-settable —
# byte-for-byte HARBOR_PASSWORD's situation, which os.sh already protects. 3 of the 5 credentials
# state_set writes were protected; these 2 were not.
for v in ARGOCD_ADMIN_PASSWORD GITEA_ADMIN_PASSWORD; do
  got="$(probe .env.state "${v}=fromOverlay" "$v" fromCaller)"
  if [ "$got" = fromCaller ]; then
    ok "${v}: an explicit caller value beats the overlay (same class as HARBOR_PASSWORD)"
  else
    bad "${v}: caller said fromCaller, got '${got}'. The overlay outranks the command line for a
        credential the operator is documented to set, so \`VAR=x make <target>\` is a silent no-op."
  fi
done

# THE INVERSE CONTROL FOR THAT CLASS, and it is the one that keeps the list a LIST. ARGOCD_LB_IP is
# a DISCOVERED value: the overlay SHOULD win. If this ever flips, the snapshot has grown to cover
# everything and every discovered-state flow breaks.
got="$(probe .env.state 'ARGOCD_LB_IP=fromOverlay' ARGOCD_LB_IP fromCaller)"
if [ "$got" = fromOverlay ]; then
  ok "control: ARGOCD_LB_IP (DISCOVERED) still takes the overlay — the snapshot is not 'everything'"
else
  bad "control: ARGOCD_LB_IP is a discovered value and the overlay must win; got '${got}'. Adding it
        to the snapshot list would break every flow that reads a published address."
fi

# ── THE DISCRIMINATING CONTROL. Without it, arm 1 passing proves nothing about the MECHANISM —
# a harness bug that dropped every sourced file would produce the same six PASSes above. ──────────
got="$(probe .env.state 'INGRESS_CONTROLLER=traefik' INGRESS_CONTROLLER istio)"
if [ "$got" = istio ]; then
  ok "control: an already-PROTECTED selector still survives the widening (see the note below)"
else
  bad "control: INGRESS_CONTROLLER has been snapshotted since long before this change and must
        survive; got '${got}' — the widening broke an existing protection.
        ⚠️ This case does NOT prove the probe reaches load_env, and its first version claimed it did.
        MEASURED: with lib/os.sh replaced by garbage it still printed ok, because its expected value
        EQUALS the caller's — a dead load_env produces the same answer. The anti-vacuity evidence is
        ARM 2 and the GITEA_ADMIN_USER control below, whose expected values DIFFER from the caller's;
        both fire when load_env is dead."
fi

# And the inverse control: a var that is deliberately NOT snapshotted must still be clobberable,
# or the snapshot list has silently become "everything" and this file cannot detect a regression.
got="$(probe .env.state 'GITEA_ADMIN_USER=fromoverlay' GITEA_ADMIN_USER fromcaller)"
if [ "$got" = fromoverlay ]; then
  ok "control: a NON-snapshotted var is still overridden — and THIS case, not the one above, is
      what proves the probe reaches load_env: its expected value DIFFERS from the caller's"
else
  bad "control: GITEA_ADMIN_USER is not in the snapshot list, so the overlay should win; got
        '${got}'. Either it was added to the list (update this case and say why) or the guard now
        fires for everything, which would break every flow that relies on discovered state."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — the caller can re-secure TLS and blob validation for a single run, and a silent\n'
printf '          caller still gets the discovered state.\n'
