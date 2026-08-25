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
#                       ⚠️ THAT REASON WAS INCOMPLETE, and the gap was real. The capture lives in
#                       ONE script; every OTHER consumer was still clobbered. MEASURED 2026-08-04:
#                       after `make install-ingress INGRESS_CONTROLLER=istio-existing` (§11, a
#                       supported action) published it to .env.state, 96-verify-gateway-image.sh —
#                       which has no such capture — could no longer be overridden, so
#                       test-gateway-image ran in foreign-mesh mode and `make static-check` was
#                       permanently RED (6 of 7 cases wanted rc=1, got 0; with an empty overlay the
#                       same gate is rc=0, 7/7). FIXED GLOBALLY: it is now in load_env's selector
#                       snapshot list, so an explicit override survives for EVERY consumer. This
#                       exemption is therefore belt-and-braces now, not the mechanism.
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
# THE PROTECTED LIST IS DERIVED FROM lib/os.sh, NOT COPIED (see PROTECTED below). ⚠️ THIS COMMENT SAT
# DIRECTLY ABOVE THE HAND-TYPED `SELECTORS` AND READ AS IF IT DESCRIBED IT. It does not, and SELECTORS
# HAD ALREADY DRIFTED: MEASURED 2026-08-05, load_env's list gained VKS_CA_SHA256 / HARBOR_CA_SHA256 /
# ARGOCD_CA_SHA256 the same day and this line had ZERO of them. The arm below is
# `if [[ "$v" =~ ^(${SELECTORS})$ ]]`, so a variable in os.sh but absent HERE is never recognized as a
# selector and its check NEVER RUNS — the gate FAILS OPEN, silently, in the direction nobody looks.
#
# ⚠️⚠️ DO NOT "FIX" THIS BY DERIVING SELECTORS FROM PROTECTED. An adversary prescribed exactly that and
# it would make the gate VACUOUS: the check is "is a SELECTOR **and** is NOT protected", so if the two
# lists are the same set by construction, `is_protected` is always true and the error branch becomes
# UNREACHABLE. The two must stay INDEPENDENT — SELECTORS is our JUDGEMENT about which variables select a
# system, PROTECTED is the MECHANISM that actually survives a per-run override. The gate's whole value is
# the gap between them.
#
# So: keep SELECTORS hand-curated, and ASSERT that it never falls behind the mechanism (below).
# VKS_CLUSTER_NAME / VKS_NAMESPACE added 2026-08-08: they name WHICH cluster, in WHICH vSphere
# Namespace, so they are selectors by this file's own definition. MEASURED before protecting them:
# with VKS_CLUSTER_NAME set in .env (the documented place), `make vks-cluster-create
# VKS_CLUSTER_NAME=other` silently targeted the .env value — and, if that cluster existed, printed
# "ALREADY EXISTS" while the operator believed they had created a different one.
# HARBOR_INSECURE / ARGOCD_INSECURE / MIRROR_VERIFY_FAST added 2026-08-18. They are NOT "which system"
# selectors on this file's own definition — they are SECURITY-POSTURE toggles — and they are here anyway,
# because the drift assertion below is a SUBSET test against load_env's mechanism and they now live in it.
# That is the honest reading: SELECTORS is "what a per-run override must be able to win", and a security
# posture qualifies more strongly than a hostname does. MEASURED before protecting them, via `.env.state`
# (a THIRD channel this gate cannot read, since it scans the COMMITTED .env.example): caller 0 + overlay 1
# -> 1 for all three, while the already-protected HARBOR_URL survived — the control proving the probe was
# not simply clobbering everything. See test-insecure-toggle-snapshot.sh.
# An optional single OR double quote, for the boolean-toggle arm's default. Hoisted because
# '"'"' inside an already-single-quoted grep pattern is unreadable at the call site.
_TOGQ='["'"'"']?'
SELECTORS='ISTIO_INSTALL_METHOD|SUPERVISOR_HOST|VCENTER_HOST|KUBECONFIG|VKS_AUTH_METHOD|INGRESS_CONTROLLER|ARGOCD_KUBECONFIG|VKS_SUPERVISOR_KUBECONFIG|VKS_CONTEXT|VKS_CLUSTER_NAME|VKS_NAMESPACE|ARGOCD_SERVER|ARGOCD_AUTH_TOKEN|ARGOCD_DEST_SERVER|ARGOCD_DEST_CLUSTER_NAME|ARGOCD_NAMESPACE|HARBOR_URL|HARBOR_USERNAME|HARBOR_PASSWORD|HARBOR_CA_FILE|VKS_CA_CERT_FILE|ARGOCD_CA_FILE|VKS_CA_SHA256|VCENTER_CA_SHA256|HARBOR_CA_SHA256|ARGOCD_CA_SHA256|VCF_CLI_SRC_DIR|HARBOR_INSECURE|ARGOCD_INSECURE|MIRROR_VERIFY_FAST|ARGOCD_ADMIN_PASSWORD|GITEA_ADMIN_PASSWORD|VCENTER_CA_FILE|VCENTER_INSECURE|VKS_INSECURE_SKIP_TLS_VERIFY'

# Read the snapshot list out of load_env itself: `for _sel in A B C ...; do`
PROTECTED="$(sed -n 's/^[[:space:]]*for _sel in \(.*\); do$/\1/p' "${REPO_ROOT}/scripts/lib/os.sh" | head -1)"
[ -n "$PROTECTED" ] || die "cannot find load_env's selector snapshot list in lib/os.sh (did it move?) —
  refusing to guess: this gate would then either pass everything or reject safe variables."
log_info "load_env snapshot-protects: ${PROTECTED}"

# ⚠️ THE DRIFT ASSERTION. PROTECTED must be a SUBSET of SELECTORS: anything load_env bothers to snapshot
# is, by that act, a selector — so if it is not in our recognizer, its clobber check never runs and this
# gate reports OK over an unchecked variable. This is the failure that already happened (see above), and
# it is invisible because the missing case simply does not execute. Deliberately NOT the reverse subset:
# SELECTORS may legitimately name something load_env does not protect — that is precisely the defect the
# gate exists to report, not an inconsistency to assert away.
_drift=""
for _p in $PROTECTED; do
  [[ "$_p" =~ ^(${SELECTORS})$ ]] || _drift="${_drift} ${_p}"
done
[ -z "$_drift" ] || die "SELECTORS has FALLEN BEHIND load_env's snapshot list — this gate would silently
  skip:${_drift}
  Add them to SELECTORS in this file. Do NOT derive SELECTORS from PROTECTED to make this go away:
  the check is 'is a selector AND is not protected', so identical lists make the error branch
  unreachable and the gate vacuous."

is_protected() { case " $PROTECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ⚠️ MUST-PROTECT: variables whose ONLY documented override form is an env PREFIX in a script's own
# usage line. They ship COMMENTED in .env.example, so the uncommented-value loop below can NEVER
# reach them -- this gate is otherwise blind to them in BOTH directions, and the drift assertion
# above is one-directional (removing one SHRINKS PROTECTED, which stays a subset, so it stays green).
#
# WHY THIS EXISTS (2026-08-10): VCF_CLI_SRC_DIR was missing from load_env's snapshot, so
# `VCF_CLI_SRC_DIR=<dir> scripts/01-install-vcf-clis.sh` -- the form that script's usage line
# documents -- was silently defeated by .env, and the installer resolved the WRONG artifacts. The
# only thing that detected it was test-vcf-cli-resolve, which drives the installer with exactly that
# env prefix; that test has since (correctly) been made hermetic with SKIP_DOTENV=1, which removes
# it as a detector. This assertion is its replacement. RED-proof: delete VCF_CLI_SRC_DIR from
# load_env's `for _sel in ...` list and confirm this dies.
MUST_PROTECT="VCF_CLI_SRC_DIR"          # space-separated; grows as more env-prefix overrides appear
for _must in $MUST_PROTECT; do
  is_protected "$_must" || die "'${_must}' is documented as an env-prefix override (VAR=<x> scripts/...)
  but load_env does NOT snapshot-protect it, so .env silently WINS and the override is inert.
  Add it to the 'for _sel in ...' list in lib/os.sh (and to SELECTORS above)."
done

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

  # (a) DYNAMIC fallback in any script: ${VAR:-$(...)}, ${VAR:-${OTHER}} or ${VAR:-$BARE}
  #
  # WIDENED 2026-08-23 to accept a BARE `$NAME` after `:-`. The class was `[({]` only, so the
  # spelling `${VAR:-$OTHER_VAR}` -- no brace, no paren -- was INVISIBLE. That is not theoretical:
  # it is the spelling I reached for first when single-sourcing BUILDER_IMAGE_TAG's default, and
  # this gate returned "OK -- none of the 55 uncommented values shadows a dynamic fallback" while
  # BUILDER_IMAGE_TAG sat UNCOMMENTED in .env.example with exactly such a fallback. Written braced,
  # the gate would have gone RED immediately and prescribed the correct remedy (comment it out).
  # A gate blind to the most natural spelling of the defect it hunts is a gate that passes by not
  # looking -- and it had already let one live instance through.
  dyn="$(grep -rlE "\\\$\{${v}:-\\\$[({A-Za-z_]" "${REPO_ROOT}/scripts" 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$dyn" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but the code reads it with a DYNAMIC fallback"
    log_error "    in: ${dyn}"
    log_error "    The sourced value is exported, so the fallback can NEVER fire. Comment it out."
    rc=1
  fi

  # (a2) the IMPERATIVE dynamic fallback: `if [ -z "${VAR:-}" ]; then VAR=<computed>; fi`.
  #
  # (a) matches only the EXPANSION form `${VAR:-$(...)}`. A guard-then-assign is the SAME defect — a
  # sourced value makes the branch unreachable, so the computed default can never fire — but it is
  # invisible to (a)'s regex. Found VACUOUS 2026-07-22: VKS_NAMESPACE (discovered from `vcf context
  # list`) and VKS_USERNAME (defaulted) are both written this way, and the gate passed with BOTH
  # uncommented while two comments in the tree claimed it covered them.
  #
  # grep -F: the pattern is a literal, so nothing here needs regex escaping (the previous attempt at
  # an ERE for this shape is exactly where a stray \{ would have silently matched nothing).
  imp="$(grep -rlF -- "[ -z \"\${${v}:-}\" ]" "${REPO_ROOT}/scripts" 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$imp" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, but the code applies a default via an"
    log_error "    'if [ -z \"\${${v}:-}\" ]' guard in: ${imp}"
    log_error "    The sourced value is exported, so that branch is UNREACHABLE and the computed"
    log_error "    default/discovery can never run. Comment it out."
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

  # (d) BOOLEAN TOGGLE — read anywhere as ${V:-0|1|true|false}.
  #
  # WHY A FOURTH ARM. Arms (a)/(a2)/(b) key on a DYNAMIC fallback or an override INVOCATION, and a
  # security toggle usually has neither: it is read as a STATIC `${V:-0}` and switched by an env
  # prefix. MEASURED by uncommenting each of the repo's nine documented-as-commented weakening
  # toggles in isolation against this gate BEFORE this arm existed:
  #     SHOW_SECRETS  ARGOCD_REGISTER_INSECURE  ALLOW_PUBLIC_CHARTS
  #     ENGINE_SKIP_CA_RED  BUNDLE_SKIP_STATIC_CHECK          -> rc=0, ALL FIVE MISSED
  #     HARBOR_INSECURE  ARGOCD_INSECURE  SKIP_DOTENV
  #     VKS_INSECURE_SKIP_TLS_VERIFY                          -> rc=1, caught INCIDENTALLY
  # The four that were caught are caught by accident of invocation shape, not by design — e.g.
  # VKS_INSECURE_SKIP_TLS_VERIFY fires arm (b2) only because 31-fetch-argocd-kubeconfig.sh happens
  # to contain an env-prefix line. ENGINE_SKIP_CA_RED's own comment in .env.example states the
  # hazard verbatim ("would CLOBBER a per-run ... and, worse, silently disable the check for
  # everyone") and was unenforced.
  #
  # WHY THIS SHAPE AND NOT THE OBVIOUS ONE. "Flag every uncommented var read as ${V:-<literal>}"
  # was MEASURED at 32 of 57 flagged, 31 of them ordinary defaulting (GITEA_NAMESPACE, PSA_LEVEL_*,
  # ISTIO_VERSION ...) -> 97% false-RED. The static-fallback shape is the NORMAL shape and does not
  # discriminate. Narrowing the default to a BOOLEAN LITERAL measures 0 of 54 on the pristine file
  # while still firing on 8 of the 9 toggles (the 9th reads `is_true "${V:-}"`, already caught by
  # (b2)). DERIVED, so it does not rot as toggles are added — which is the whole point, since the
  # five misses above are exactly enumerated-list rot in its live form.
  #
  # ⚠️ THE REMEDY IS "COMMENT IT OUT", AND DELIBERATELY NOT "add it to load_env's snapshot list".
  # ⚠️ CORRECTED 2026-08-18: that sentence used to end "and would silently disable this arm". That
  # half is FALSE and it is the dangerous half — it would scare the next session off a safe change,
  # or stop them measuring. Settled by source-read AND by an idea round that ran it: the protected
  # branch at :156 only LOGS, it does not `continue`, so execution falls through and this arm still
  # fires (measured rc=1 with the var both snapshot-listed and armed uncommented). What the snapshot
  # DOES do is print an `ok ... SNAPSHOT-PROTECTED ... a per-run override survives` line DIRECTLY
  # ABOVE the error, about the very line that armed the leak — a legibility regression, not an
  # enforcement one. Suppress that `ok` when the same var is also flagged here, if you add these.
  # The rest of this paragraph stands and is the reason the remedy is still "comment it out": load_env's
  # loop is `if [ -n "${!_sel:-}" ]` — it restores a value the CALLER already set. The threat here
  # is the INVERSE: the caller sets NOTHING and the FILE arms the flag. Measured with .env.example
  # carrying SHOW_SECRETS=1 and the caller unset, the effective value is '1' with the snapshot and
  # '1' without it — zero discrimination — while `is_protected` would then print an `ok ... a
  # per-run override survives` line over the very line that armed the leak. The correct pattern for
  # a security toggle is creds.sh's: read it from the PRE-load_env environment and honour only that.
  #
  # KNOWN, DISCLOSED SCOPE: a toggle written ${V:-no} / ${V:-off} / [ "$V" = yes ] is MISSED. The
  # rot direction is a false NEGATIVE, not a false RED, so adding literals here is cheap.
  # ALSO MISSED, both measured to be ZERO occurrences today so neither is a live gap:
  #   * `${V:=0}` (assign-default) — not in the alternation below;
  #   * any toggle consumed OUTSIDE `$REPO_ROOT/scripts` + `Makefile` — .github/workflows/,
  #     jumpbox/ and k8s/ are not scanned. Named here because "0 today" is not "0 forever".
  #
  # ⚠️ TWO SHAPES ADDED 2026-08-18 after an adversary round measured them MISSED, and I reproduced
  # both with ${V:-0} as the working control (CAUGHT / MISSED / MISSED):
  #     ${V:-0}    CAUGHT   the control — proves the probe reaches the arm
  #     ${V-0}     MISSED   the NO-COLON form. Legal bash, and it differs only for the empty
  #                         string, so it is a shape someone writes without thinking about it.
  #     ${V:-"0"}  MISSED   the QUOTED default. Pure style; identical semantics.
  # Both are now matched. $_TOGQ is an optional single-or-double quote, hoisted out because the
  # nested quoting is unreadable inline.
  #
  # ⚠️ AND THE 56 IN THE PARAGRAPH ABOVE HAD ROTTED: the gate reports 54 uncommented values today.
  # An adversary read 56 out of THIS COMMENT and reported my brief as wrong, when the comment was
  # the stale artifact. Corrected in place — a number in prose is a claim with a date.
  # ⚠️ THIRD SHAPE ADDED 2026-08-21 (B196/F9): `is_true "${V:-}"` - an EMPTY default, so the
  # boolean-literal alternation cannot match it. It is the shape VKS_INSECURE_SKIP_TLS_VERIFY uses,
  # i.e. the repo's single most dangerous toggle (a credential is submitted over the very connection
  # it stops verifying), and until now this gate caught it ONLY INCIDENTALLY - via arm (b2), and only
  # because 31-fetch-argocd-kubeconfig.sh happens to contain an env-prefix line. Rewording that die,
  # which the prefix-only migration REQUIRES, would have made the gate go SILENTLY BLIND on it: the
  # migration commit would have disabled its own guard. MEASURED 1 of 1 repo-wide, so it adds no
  # sibling churn and cannot re-introduce the 97% false-RED of the naive static-fallback shape.
  tog="$( { grep -rlE '\$\{'"${v}"'(:-|-)'"$_TOGQ"'(0|1|true|false)'"$_TOGQ"'\}' "${REPO_ROOT}/scripts" "${REPO_ROOT}/Makefile" 2>/dev/null || true
            grep -rlE 'is_true[[:space:]]+"?\$\{'"${v}"':-\}"?' "${REPO_ROOT}/scripts" "${REPO_ROOT}/Makefile" 2>/dev/null || true
          } | sort -u \
            | xargs -r -n1 basename | tr '\n' ' ')"
  if [ -n "$tog" ]; then
    log_error "CLOBBER: '${v}' is UNCOMMENTED in .env.example, and it is a BOOLEAN TOGGLE"
    log_error "    read as \${${v}:-<default>} in: ${tog}"
    log_error "    load_env sources .env.example with 'set -a' AFTER the caller's environment is"
    log_error "    established, so this line becomes the EFFECTIVE value for every run — including"
    log_error "    runs where nobody asked for it. For a toggle that WEAKENS something, that is a"
    log_error "    permanent, invisible change of default."
    log_error "    Fix: COMMENT IT OUT and document the default in the comment. Do NOT add it to"
    log_error "    load_env's snapshot list — that restores only a value the CALLER set, so it is a"
    log_error "    measured no-op here and would make this gate assert safety over the armed line."
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  [ "$checked" -gt 0 ] || die "check-env-clobber: examined 0 uncommented .env.example value(s) — the gate has gone BLIND."
  log_info "check-env-clobber: OK — none of the ${checked} uncommented .env.example values shadows a dynamic fallback or a per-run override."
else
  log_error "check-env-clobber: .env.example has value(s) that silently defeat the code above."
  log_error "  Rule: a var read with a DYNAMIC fallback, or overridden per-run by a make target,"
  log_error "  MUST stay COMMENTED in .env.example — otherwise 'set -a' exports it and it wins."
fi
exit "$rc"
