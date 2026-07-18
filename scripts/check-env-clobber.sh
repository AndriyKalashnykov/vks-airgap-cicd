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

# (c) SELECTOR VARS — a var that chooses WHICH SYSTEM you are talking to (which cluster, which
# registry, which trust anchor). KUBECONFIG was UNCOMMENTED, so `make <target> KUBECONFIG=/other` was
# silently ignored and you ran against the default cluster believing you had switched.
#
# THERE ARE NOW **TWO** VALID WAYS TO BE SAFE, and the gate must accept both — or it lies:
#   1. COMMENT it here (the default is applied in code), OR
#   2. be SNAPSHOT-PROTECTED: load_env captures the caller's explicit value BEFORE sourcing and
#      RESTORES it after, so the override wins even though this file carries a default. That is what
#      makes `HARBOR_URL=<other> make mirror` work. (Since B13 HARBOR_URL is COMMENTED in .env.example —
#      provided by discovery/.env.state (KinD) or the operator's .env (lab); unset -> a `:?` guard fires
#      with guidance. The snapshot-protection still guards an explicit override.)
#
# So the invariant is: EVERY selector is commented OR in load_env's snapshot list. Nothing else passes.
#
# THE PROTECTED LIST IS DERIVED FROM lib/os.sh, NOT COPIED. A second hand-typed list is exactly the
# enumerated-list rot this repo keeps getting bitten by: it would drift the first time someone adds a
# selector to load_env and not here, and the gate would then reject a variable that is, in fact, safe.
SELECTORS='KUBECONFIG|ARGOCD_KUBECONFIG|GUEST_KUBECONFIG|VKS_CONTEXT|ARGOCD_SERVER|ARGOCD_AUTH_TOKEN|ARGOCD_DEST_SERVER|ARGOCD_DEST_CLUSTER_NAME|ARGOCD_NAMESPACE|HARBOR_URL|HARBOR_CA_FILE'

# Read the snapshot list out of load_env itself: `for _sel in A B C ...; do`
PROTECTED="$(sed -n 's/^[[:space:]]*for _sel in \(.*\); do$/\1/p' "${REPO_ROOT}/scripts/lib/os.sh" | head -1)"
[ -n "$PROTECTED" ] || die "cannot find load_env's selector snapshot list in lib/os.sh (did it move?) —
  refusing to guess: this gate would then either pass everything or reject safe variables."
log_info "load_env snapshot-protects: ${PROTECTED}"

is_protected() { case " $PROTECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

rc=0
checked=0
for v in "${UNCOMMENTED[@]}"; do
  [[ "$v" =~ ^(${EXEMPT})$ ]] && continue
  checked=$((checked + 1))

  # (c) a SELECTOR var pinned uncommented -> the override loses, UNLESS load_env restores it.
  if [[ "$v" =~ ^(${SELECTORS})$ ]]; then
    if is_protected "$v"; then
      log_info "  ok  '${v}' is uncommented but SNAPSHOT-PROTECTED by load_env — a per-run override survives"
    else
      log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but it SELECTS WHICH CLUSTER/SYSTEM you talk to,"
      log_error "    and load_env does NOT snapshot-protect it. load_env sources this file with 'set -a' AFTER a"
      log_error "    per-run override is in the environment, so 'make <target> ${v}=...' is SILENTLY IGNORED —"
      log_error "    you would run against the default while believing you had switched."
      log_error "    Fix: comment it out (default in code), or add it to load_env's selector snapshot list."
      rc=1
    fi
  fi

  # (a) DYNAMIC fallback in any script: ${VAR:-$(...)} or ${VAR:-${OTHER}}
  dyn="$(grep -rlE "\\\$\{${v}:-\\\$[({]" "${REPO_ROOT}/scripts" 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$dyn" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but the code reads it with a DYNAMIC fallback"
    log_error "    in: ${dyn}"
    log_error "    The sourced value is exported, so the fallback can NEVER fire. Comment it out."
    rc=1
  fi

  # (b) per-run override — TWO forms, and the second one is how ARGOCD_SERVER got through.
  #
  #   b1. a sub-make / make invocation:      $(MAKE) foo VAR=x     |  make foo VAR=x
  #   b2. an ENV-PREFIX invocation:          VAR=x ./scripts/y.sh  |  VAR="$x" \  (continued)
  #                                                                    other-script.sh
  #
  # This check used to detect ONLY b1. But b2 is how the harnesses actually drive things —
  # 91-e2e-tenant-mechanism.sh passes ARGOCD_SERVER="$argocd_lb" \ as an env prefix to
  # 70-configure-argocd.sh — so an uncommented ARGOCD_SERVER in .env.example was invisible to this
  # gate while silently defeating that very override. The e2e still went green, against a hostname
  # only the author's box resolved. A gate that reasons about one invocation form is a gate that
  # misses every other one.
  #
  # b2 patterns (deliberately NOT matching a plain `VAR=value` assignment on its own):
  #   ^ VAR=<val> <command>     an assignment followed by a command on the same line
  #   ^ VAR=<val> \             an assignment ending in a line-continuation (an env-prefix block)
  ovr="$(grep -rlE "(MAKE\)[^#]*|make )[^#]*\b${v}=" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/scripts" 2>/dev/null \
          | xargs -r -n1 basename | tr '\n' ' ')"
  # The VALUE must be consumed properly or a quoted value CONTAINING SPACES looks like
  # `VAR=x command`. First draft did exactly that and false-flagged
  #     VCF_CLI_VERSION="${VCF_CLI_VERSION:?set VCF_CLI_VERSION in .env.example (e.g. ...)}"
  # which is a plain assignment, not an override. So: value = "quoted" | 'quoted' | bare-no-space,
  # and only THEN a following command token (or a line-continuation) makes it an env prefix.
  ovr2="$(grep -rlE "^[[:space:]]*${v}=(\"[^\"]*\"|'[^']*'|[^[:space:]\"']+)([[:space:]]+[^[:space:]=#]|[[:space:]]*\\\\$)" \
            "${REPO_ROOT}/scripts" 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  [ -n "$ovr2" ] && ovr="${ovr}${ovr2}"
  # SNAPSHOT-PROTECTED vars are exempt from (b) for the same reason as (c): load_env restores the
  # caller's explicit value AFTER sourcing, so a per-run override DOES win. Without this, the gate
  # false-flags HARBOR_URL and cites `os.sh` as the evidence — where the only match is load_env's OWN
  # restore line (`export "$k=$val"` reconstructing `HARBOR_URL=...`). A gate that flags the mechanism
  # that makes the variable safe is a gate arguing with itself, and the only way to satisfy it would be
  # to DELETE the protection.
  if [ -n "$ovr" ] && is_protected "$v"; then
    log_info "  ok  '${v}' is passed as a per-run override AND snapshot-protected by load_env — the override wins"
    ovr=""
  fi
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
