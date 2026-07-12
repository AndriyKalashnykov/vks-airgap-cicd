#!/usr/bin/env bash
# check-env-clobber.sh — fail if an UNCOMMENTED value in .env.example would silently CLOBBER a
# runtime fallback or a per-run override.
#
# WHY THIS GATE EXISTS
# --------------------
# `load_env` sources .env.example with `set -a`, so every uncommented line becomes an EXPORTED
# environment variable. That is fine for a plain default. It is a BUG in two shapes:
#
#   (a) DYNAMIC FALLBACK — the code reads the var as `${VAR:-$(pick_port)}` / `${VAR:-${OTHER}}`.
#       An uncommented value means the fallback can NEVER fire. GITEA_LOCAL_PORT=3000 killed the
#       ephemeral-port parallel-safety this way: two runs on one box collided on a fixed port,
#       while the code comments promised otherwise.
#
#   (b) PER-RUN OVERRIDE — a make target (or a script) passes `VAR=<value>` for that run. The
#       sourced .env.example value is applied AFTER make put the override in the environment, so
#       the override loses. This broke `make e2e-sneakernet` twice: BUNDLE_OUT_DIR sent the tarball
#       into the directory tar was archiving ("file changed as we read it"), and BUNDLE_TARBALL
#       made bundle-load look for ./bundle.tar.gz while the carried tarball sat in the transfer dir.
#
# Three instances of one class is not bad luck, it is a missing gate. This is the gate.
# A var in either shape MUST be left commented in .env.example (documented, with its default).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

ENV_EXAMPLE="${REPO_ROOT}/.env.example"
[ -f "$ENV_EXAMPLE" ] || die ".env.example missing"

# Vars set UNCOMMENTED in .env.example (these get exported by load_env's `set -a`).
mapfile -t UNCOMMENTED < <(grep -oE '^[A-Z][A-Z0-9_]*=' "$ENV_EXAMPLE" | tr -d '=' | sort -u)

# EXEMPT — verified, with the reason. Two legitimate shapes look like a clobber but are not:
#
#   APP_DEV_PORT        used only at MAKE level ($(APP_DEV_PORT)), never re-read by a script's
#                       load_env. Make gives command-line variables the highest precedence, so
#                       `make check-ports APP_DEV_PORT=9999` genuinely wins (verified: "9999 free").
#   INGRESS_CONTROLLER  44-install-ingress.sh:16 deliberately CAPTURES the explicit override into
#                       _override BEFORE calling load_env, precisely so the persisted .env.kind /
#                       .env.example value cannot win (verified: the traefik e2e permutation passes).
#
# Anything added here needs the same treatment: an empirical check, and the reason written down.
EXEMPT='APP_DEV_PORT|INGRESS_CONTROLLER'

rc=0
checked=0
for v in "${UNCOMMENTED[@]}"; do
  [[ "$v" =~ ^(${EXEMPT})$ ]] && continue
  checked=$((checked + 1))

  # (a) DYNAMIC fallback in any script: ${VAR:-$(...)} or ${VAR:-${OTHER}}
  dyn="$(grep -rlE "\\\$\{${v}:-\\\$[({]" "${REPO_ROOT}/scripts" 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$dyn" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but the code reads it with a DYNAMIC fallback"
    log_error "    in: ${dyn}"
    log_error "    The sourced value is exported, so the fallback can NEVER fire. Comment it out."
    rc=1
  fi

  # (b) per-run override: a Makefile recipe or a script passes VAR=<value> to a sub-make/command.
  ovr="$(grep -rlE "(MAKE\)[^#]*|make )[^#]*\b${v}=" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/scripts" 2>/dev/null \
          | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$ovr" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but it is passed as a PER-RUN OVERRIDE"
    log_error "    in: ${ovr}"
    log_error "    load_env sources .env.example AFTER the override is in the environment, so the"
    log_error "    override LOSES. Comment it out (document the default in the comment)."
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  log_info "check-env-clobber: OK — none of the ${checked} uncommented .env.example values shadows a dynamic fallback or a per-run override."
else
  log_error "check-env-clobber: .env.example has value(s) that silently defeat the code above."
  log_error "  Rule: a var read with a DYNAMIC fallback, or overridden per-run by a make target,"
  log_error "  MUST stay COMMENTED in .env.example — otherwise 'set -a' exports it and it wins."
fi
exit "$rc"
