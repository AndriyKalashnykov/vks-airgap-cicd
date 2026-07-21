#!/usr/bin/env bash
# lint.sh — shellcheck the scripts, yamllint the manifests, hadolint the Dockerfile.
# Best-effort per tool: a missing tool is warned-and-skipped; a PRESENT tool that
# finds problems fails the run (so CI is honest about what it actually checked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0

echo "== shellcheck (scripts/*.sh + repo-root *.sh) =="
if require_gate_tool shellcheck; then
  # Exclude nothing; lib/os.sh is sourced so give it shell=bash via its directive.
  # Include repo-root *.sh (e.g. bootstrap-jumpbox.sh) — not just scripts/.
  # PARALLEL FOR THE PASS, SERIAL FOR THE REPORT. shellcheck was MEASURED at 37.3s of lint's 38.5s
  # (97%) — it is CPU-bound, not fork-bound: `-x` re-parses lib/os.sh for each of 126 scripts, so
  # the existing single xargs batch was already optimal shape and simply slow. Fanning it across
  # cores measures 10.3s on 24 cores — and, because the objection is always "but CI has 2 vCPUs",
  # MEASURED there too: `-P 2 -n 4` is 19.3s vs 35.7s serial, still 1.85x faster. The red path costs
  # both passes (24-core 45.5s, 2-vCPU 55.0s); the static-check job sets no timeout-minutes.
  # `-n` is load-bearing: `-P N` WITHOUT it runs a single batch and buys nothing (measured 35.1s).
  #
  # ⚠️ DO NOT print from the parallel run. `xargs -P` gives every concurrent shellcheck the SAME
  # stdout, and writes above PIPE_BUF (4096 B) interleave MID-LINE. MEASURED: at ~21.8 KB per
  # invocation, 20/20 runs spliced (e.g. "echo $undefinedvar46e to prevent globbing and word
  # splitting."); below PIPE_BUF, 0/20. The threshold is ~a dozen findings — i.e. it garbles exactly
  # when the gate fires and somebody needs to read it. BOTH obvious mitigations are REFUTED, do not
  # re-try them: `-f gcc` still garbled 20/20 (one finding per line does not make the WRITE atomic),
  # and `stdbuf -oL` is a no-op because shellcheck is Haskell and GHC does its own buffering.
  # So: discard parallel output, and on failure re-run SERIALLY to produce an unspliced report.
  # Green costs 10s; red costs 10s + 37s once, which is the right trade for a legible diagnostic.
  #
  # rc propagation is unaffected: xargs returns 123 when a child exits 1-125, serial AND parallel.
  # Batching does NOT hide findings — `-x` resolves `# shellcheck source=` from the FILESYSTEM, not
  # from batch membership (proven with an SC1091 control, not by diffing two empty outputs).
  # nproc is present on bare photon:5.0, but degrade rather than die: an empty -P is a hard xargs
  # error, and `set -e` does not fire on a failed substitution in argument position.
  _sc_files() { find "$REPO_ROOT/scripts" -name '*.sh' -print0; \
                find "$REPO_ROOT" -maxdepth 1 -name '*.sh' -print0; }
  # >/dev/null, NOT >/dev/null 2>&1: splicing is a STDOUT problem (the findings), while xargs's own
  # failure — "invalid number for -P", a usage error — is a single small write on STDERR. Discard
  # the first, KEEP the second, or the diagnostic below can only guess at the cause.
  # CAPPED AT 8, and the cap is MEASURED, not superstition: on a 24-thread box `-P $(nproc)` is
  # SLOWER than `-P 8` in wall time and burns ~4x the CPU (interleaved A/B, 6 pairs: -P 8 ~6.5s,
  # -P 24 ~9.9s; sweep P=4 11.1s, P=8 7.25s, P=16 9.5s, P=24 10.7s — a peak then decay). It is a
  # no-op on CI by construction, since min(nproc,8) == nproc on a 4-vCPU runner, so it cannot
  # regress the runner while it stops `make static-check` saturating a developer box — which this
  # repo cares about, because heavy jobs run concurrently make any failure unattributable.
  # It also bounds the cgroup case: `nproc` reports HOST cores under `--cpus` (measured: 24 inside
  # `--cpus=2`), since it reads sched_getaffinity, which sees cpuset but not cpu.max.
  # `if`, NOT `[ … ] && _p=8`: as a standalone statement that returns NON-ZERO whenever the cap
  # does not apply (i.e. on every 4-vCPU CI runner), and this file runs `set -euo pipefail`.
  _p="$(nproc 2>/dev/null || echo 4)"
  if [ "$_p" -gt 8 ]; then _p=8; fi
  if ! _sc_files | xargs -0 -P "$_p" -n 4 shellcheck -x >/dev/null; then
    log_warn "the parallel shellcheck pass exited non-zero — re-running serially to find out why (parallel output interleaves, so it cannot be printed)"
    # The SERIAL pass is AUTHORITATIVE for what is wrong. The parallel pass can go non-zero for a
    # reason that is not a finding — a bad -P (empty nproc), an xargs usage error, or pipefail on
    # the producer — and then printing "shellcheck found issues" above a report containing NOTHING
    # is precisely the "gate that cannot say why it failed" this file already warns about for
    # yamllint. Still fail (something IS broken), but say WHICH thing.
    if _sc_files | xargs -0 shellcheck -x; then
      log_error "the PARALLEL shellcheck pass failed but the SERIAL pass found nothing. The scripts are clean — the parallel invocation itself is broken (suspect nproc/-P/xargs). Failing so this cannot hide as a silent 4x slowdown."
    fi
    rc=1
  fi
else
  log_warn "shellcheck not installed — skipped"
fi

echo "== yamllint (manifests) =="
if require_gate_tool yamllint; then
  # Relaxed: line-length off (manifests are wide); comma/colon spacing off
  # (we column-align inline maps for readability).
  # NOTE: stderr is NOT silenced. It used to be (`2>/dev/null`), and when a listed
  # directory stopped existing, yamllint failed with its reason hidden — the gate printed
  # "findings above" with nothing above. A gate that cannot say why it failed is a bug.
  yamllint -d "{extends: relaxed, rules: {line-length: disable, commas: disable, colons: disable}}" \
    "$REPO_ROOT/k8s" "$REPO_ROOT/deploy" || rc=1
else
  log_warn "yamllint not installed — skipped"
fi

echo "== hadolint (EVERY app's Dockerfile*, from apps/registry.tsv) =="
if require_gate_tool hadolint; then
  # Every app, not one hardcoded path: this glob used to name the Java app, which meant the Go
  # app's Dockerfile was never linted at all. The glob covers the runtime Dockerfile AND any
  # Dockerfile.builder (the air-gapped Maven builder) — both must be lint-clean.
  # shellcheck source=scripts/lib/apps.sh
  . "${SCRIPT_DIR}/lib/apps.sh"
  found=0
  while read -r _app; do
    [ -n "$_app" ] || continue
    for df in "${REPO_ROOT}/$(app_src "$_app")"/Dockerfile*; do
      [ -f "$df" ] || continue
      found=$((found + 1))
      hadolint "$df" || rc=1
    done
  done <<EOF
$(app_names)
EOF
  # Print the denominator: a gate that cannot say how many Dockerfiles it linted cannot be trusted.
  # (if/else, NOT `A && B || C` — that runs C when A is true and B fails: SC2015.)
  if [ "$found" -gt 0 ]; then
    log_info "hadolint: linted ${found} Dockerfile(s)"
  else
    log_warn "no app Dockerfiles found — skipped"
  fi
else
  log_warn "hadolint not installed — skipped"
fi

echo "== hadolint (jumpbox/Dockerfile.*) =="
if require_gate_tool hadolint; then
  for df in "$REPO_ROOT"/jumpbox/Dockerfile.*; do
    [ -f "$df" ] && { hadolint "$df" || rc=1; }
  done
else
  log_warn "hadolint not installed — skipped"
fi

echo "== exec bit (scripts/*.sh must be executable) =="
# A script the Makefile / CI invokes as `./scripts/NN-foo.sh` and that was committed
# mode 100644 fails at RUN time with `Permission denied` (exit 126) — never at lint or
# build time, so it ships green and only breaks the e2e. Files created by an editor/tool
# default to 0644, so this is easy to do and invisible until it bites.
# scripts/lib/*.sh are SOURCED, never executed, so they are exempt (0644 is correct).
_nonexec=0
while IFS= read -r f; do
  [ -x "$f" ] && continue
  log_error "not executable (Makefile/CI runs it directly): ${f#"$REPO_ROOT"/}  -> chmod +x"
  _nonexec=1
done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f | sort)
[ "$_nonexec" -eq 0 ] || rc=1

if [ "$rc" -eq 0 ]; then log_info "lint: OK"; else log_error "lint: findings above"; fi
exit "$rc"
