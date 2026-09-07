#!/usr/bin/env bash
# ⚠️ THE UNDERSCORE IN THE FILENAME IS LOAD-BEARING. `check-lib-sourcing.sh` matches libs with
# `lib/[a-z_]+\.sh` — NO HYPHEN — so a `harbor-probe.sh` is INVISIBLE to it: the gate reported
# "calls harbor_assert_mirrored() but never sources lib/harbor-probe.sh" for six files that plainly
# did source it. Every other lib in this directory is `[a-z_]+`, so the gate is enforcing a
# convention rather than being wrong. Do not rename this with a hyphen.
# harbor_probe.sh — "is there anything in this Harbor?", answered WITHOUT a credential (B527).
#
# WHY THIS IS NOT IN lib/harbor.sh. That library's FIRST LINES are `: "${HARBOR_USERNAME:?}"` and
# `: "${HARBOR_PASSWORD:?}"` — hard dies. MEASURED: `40/41/45/46/49-install-*.sh` contain ZERO
# references to it or to those variables; they pull ANONYMOUSLY from a public project (Harbor
# projects are created `"public": ${HARBOR_PUBLIC_PROJECTS:-true}`), which is exactly why
# `46-install-istio.sh` creates no imagePullSecret. Sourcing lib/harbor.sh here would add a
# MANDATORY credential to five installers that today need none, and under RULE ZERO-B a tenant
# handed a public URL and no credential is a normal state — the check written to help them would
# block the install outright.
#
# WHY NOT REUSE 23-mirror-verify.sh, which the backlog row preferred. Its `_verify_class` orders
# `*UNAUTHORIZED:*` -> AUTH BEFORE `*NOT_FOUND:*` -> ABSENT, and a missing PROJECT answers
# `UNAUTHORIZED: project <x> not found`. So it would classify AUTH and die with "Harbor REJECTED the
# credential ... Do NOT re-mirror" — reproducing the incident's first wrong diagnosis verbatim and
# forbidding `make mirror`, which is what actually fixed it. It is also inventory-wide and costs
# 5m46s (docs/scenario-1.md:1159), because `crane validate --remote` fetches every layer blob.
#
# THE MEASURED INCIDENT (2026-09-05): the lab was rebuilt, Harbor came back empty, the `cicd` project
# did not exist, and `istiod` died `ImagePullBackOff / 401`. That read as an auth failure and was
# diagnosed as one TWICE. This probe answers the question that was actually being asked.
#
# COST, measured on the live lab 2026-09-07, anonymous:
#     GET /api/v2.0/projects?name=cicd            -> 200, 30 ms
#     GET /api/v2.0/projects?name=nosuchproject   -> 200 [], 15 ms
# Against `crane validate --remote` at 7.04 s / 139.8 MiB for ONE image.

# harbor_project_state <project> -> prints `present` | `absent` | `inconclusive`
#
# ⚠️ THREE VERDICTS, NEVER TWO. A **private** project also returns `[]` to an anonymous caller, so
# without a credential `[]` cannot distinguish "not there" from "not visible to me". Reporting that
# as ABSENT would tell a tenant to run `make mirror` against a Harbor that is fine. So: decisive
# only when we HAVE a credential; otherwise `inconclusive`, which never blocks.
harbor_project_state() {
  local _p="${1:?harbor_project_state: project name required}" _sch _body _rc _cfg=""
  _sch="$([ "${HARBOR_INSECURE:-0}" = 1 ] && printf 'http' || printf 'https')"
  local _args=(-sS --max-time "${HARBOR_PROBE_TIMEOUT_SECONDS:-10}")
  [ "${HARBOR_INSECURE:-0}" = 1 ] || _args+=(-k)   # self-signed lab CA; this is a READ of public metadata

  # Credentials are OPTIONAL. When present they make `[]` decisive. Never in argv — a -K config
  # file under umask 077, the same discipline lib/harbor.sh uses.
  if [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
    _cfg="$(mktemp)"; ( umask 077; printf 'user = "%s:%s"\n' \
      "$(esc_curlk "$HARBOR_USERNAME")" "$(esc_curlk "$HARBOR_PASSWORD")" > "$_cfg" )
    _args+=(-K "$_cfg")
  fi
  _body="$(curl "${_args[@]}" "${_sch}://${HARBOR_URL:?}/api/v2.0/projects?name=${_p}" 2>/dev/null)"; _rc=$?
  [ -n "$_cfg" ] && rm -f "$_cfg"

  # An unreachable Harbor is NOT an empty one. `lab-preflight` owns reachability; here it is
  # inconclusive, because reporting `absent` for a network problem names the wrong cause.
  [ "$_rc" -eq 0 ] || { printf 'inconclusive'; return 0; }

  case "$_body" in
    '[]'|'') [ -n "$_cfg" ] && printf 'absent' || printf 'inconclusive' ;;
    *"\"name\":\"${_p}\""*)
      # `repo_count: 0` is the SECOND half of the measured incident state — the project exists and
      # holds nothing, which a per-image probe would report as one missing image out of many.
      case "$_body" in *'"repo_count":0'*) printf 'empty' ;; *) printf 'present' ;; esac ;;
    *) printf 'inconclusive' ;;
  esac
}

# harbor_assert_mirrored <project> <what-is-installing> — die with the RIGHT cause, or warn loudly.
#
# Shaped after `capacity_assert_fits` (lib/capacity.sh): an escape hatch, and every unknown is a
# LOUD SKIP that says it is not a pass.
harbor_assert_mirrored() {
  local _p="${1:-}" _what="${2:-this install}" _state
  [ "${HARBOR_IMAGE_PREFLIGHT:-1}" = 0 ] && { log_warn "harbor: image preflight disabled (HARBOR_IMAGE_PREFLIGHT=0)"; return 0; }
  [ -n "${HARBOR_URL:-}" ] || { log_warn "harbor: HARBOR_URL is unset — mirror check SKIPPED (not a pass)"; return 0; }
  # ⚠️ SKIP, do NOT `:?`. Call sites used to pass `"${HARBOR_INFRA_PROJECT:?}"`, which turns an
  # unset var into a hard die AT MY LINE. In 49-install-headlamp.sh that line is 49 lines ABOVE the
  # first `mirror_target_ref` — the code that genuinely needs the variable and dies with a message
  # naming what it was resolving. So the preflight would have PRE-EMPTED a better error with a bare
  # "parameter null or not set". A check added to improve a diagnostic must not degrade one.
  [ -n "$_p" ] || { log_warn "harbor: no Harbor project name given — mirror check SKIPPED (not a pass)"; return 0; }

  _state="$(harbor_project_state "$_p")"
  case "$_state" in
    present) log_info "harbor: project '${_p}' exists and holds repositories" ;;
    empty|absent)
      log_error "harbor: project '${_p}' on ${HARBOR_URL} is ${_state^^}."
      log_error "  ${_what} is about to pull its images from there, so it would fail with an"
      log_error "  ImagePullBackOff and a 401 — which is the registry AUTH CHALLENGE, not a"
      log_error "  credential problem, and reads as one. Nothing has been mirrored to this Harbor."
      die "  Run: make mirror        (then re-run this install)" ;;
    *)
      log_warn "harbor: could not determine whether '${_p}' holds images — SKIPPED (not a pass)."
      log_warn "  A private project answers an anonymous query exactly like a missing one, so this"
      log_warn "  is deliberately not treated as absent. Set HARBOR_USERNAME/HARBOR_PASSWORD in"
      log_warn "  .env to make it decisive, or ask your platform team whether the mirror has run." ;;
  esac
}
