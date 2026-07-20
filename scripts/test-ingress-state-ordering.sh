#!/usr/bin/env bash
# test-ingress-state-ordering.sh — INGRESS_CONTROLLER and INGRESS_LB_IP are ONE FACT: the same script
# must publish both, ADJACENTLY, with the controller last.
#
# THE BUG THIS PINS (found 2026-07-19 by an adversary reviewing an unrelated idea).
# 44-install-ingress.sh used to `state_set` the controller and THEN `exec` the installer, while each
# installer publishes the IP at its very end. An install dying in between left .env.state carrying the
# NEW controller beside the PREVIOUS controller's IP; a standalone `make verify-ingress` then PASSED
# while printing "reachable through the <new> ingress at <old controller's IP>". The UIs genuinely
# were reachable, so nothing looked broken — only the label lied.
# It also closed a hole nobody had noticed: `make install-istio` / `install-traefik` / `attach-istio`
# invoke 45/46/47 DIRECTLY, bypassing the dispatcher, so under the old code those three entry points
# never published the controller AT ALL.
#
# 🔴 THIS TEST'S FIRST VERSION WAS TOO WEAK, AND AN ADVERSARY PROVED IT WITH THREE MUTATIONS THAT ALL
# STAYED GREEN. Each assertion below exists because one of them slipped through:
#   C. the publish MOVED to the top of the installer (before helm/routes/LB-wait) — byte-for-byte the
#      same defect, one file instead of across `exec`. Presence-only checking cannot see it.
#      -> now: LINE NUMBERS are compared, controller must be at-or-just-after the IP.
#   D. a FOURTH publisher (`52-install-nginx.sh`) publishing only the IP — invisible, because the file
#      list was HAND-TYPED, so the denominator could never grow.
#      -> now: the list is DERIVED from whoever publishes the IP.
#   E. a CONDITIONAL publish (`if [ "$FLAG" = 1 ]; then <publish>; fi`) — `^[[:space:]]*` permits
#      exactly that indentation. Still accepted; see RESIDUAL.
#
# COMPOSED PATTERNS: the strings this gate hunts are assembled at runtime, so this file never contains
# them at a command position and cannot flag itself — and the reflex fix (excluding this file) would
# blind it to every future real finding here.
#
# RESIDUAL, stated rather than hidden: a publish wrapped in a conditional still passes (mutation E);
# and `state_set` writes one key per call with no atomic multi-key form in lib/state.sh, so a crash
# BETWEEN the two calls still splits the pair — but the window shrinks from the whole install
# (helm + routes + LB wait, minutes) to two adjacent calls with no I/O between them. The IP-first
# order is the safer half: a half-write leaves the CORRECT IP with a stale label, not the original bug.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

fail=0; checked=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

SS="$(printf 'state_%s' 'set')"          # composed: this file must never contain the literal it hunts
IPV="INGRESS_LB_$(printf 'IP')"
CTLV="INGRESS_$(printf 'CONTROLLER')"
pub_re() { printf '^[[:space:]]*%s[[:space:]]+%s\\b' "$SS" "$1"; }

# --- 1. DERIVE the corpus: whoever publishes the IP is an installer, by definition. -----------
# Hand-typing the list is what let a fourth publisher hide (mutation D).
mapfile -t INSTALLERS < <(grep -rlE "$(pub_re "$IPV")" scripts/ 2>/dev/null | grep -v '/test-' | sort)
[ "${#INSTALLERS[@]}" -gt 0 ] \
  || die "derived ZERO ${IPV} publishers — the pattern or the layout moved and this gate is BLIND"

# --- 2. The dispatcher must publish NEITHER: it cannot know the IP, so it must not claim the pair.
checked=$((checked + 1))
if grep -qE "$(pub_re "$CTLV")" scripts/44-install-ingress.sh; then
  bad "44-install-ingress.sh publishes ${CTLV} before exec'ing the installer — a failed install then leaves the NEW controller beside the OLD ip"
else
  ok "44-install-ingress.sh publishes neither half"
fi

# --- 3. Each derived installer publishes BOTH, with the controller AT-OR-JUST-AFTER the IP. ----
for f in "${INSTALLERS[@]}"; do
  checked=$((checked + 1))
  ip_line="$(grep -nE "$(pub_re "$IPV")"  "$f" | head -1 | cut -d: -f1)"
  ct_line="$(grep -nE "$(pub_re "$CTLV")" "$f" | head -1 | cut -d: -f1)"
  b="$(basename "$f")"
  if [ -z "$ct_line" ]; then
    bad "${b} publishes ${IPV} but NOT ${CTLV} — the pair is split again"
    continue
  fi
  delta=$(( ct_line - ip_line ))
  # Adjacency is the ORDERING assertion: presence alone cannot tell a publish at the END of the
  # installer from one at the TOP, and the one at the top IS the bug (mutation C).
  if [ "$delta" -ge 0 ] && [ "$delta" -le 4 ]; then
    ok "${b} publishes BOTH, adjacently (${IPV}:${ip_line} -> ${CTLV}:${ct_line})"
  else
    bad "${b} publishes ${CTLV} at line ${ct_line} but ${IPV} at line ${ip_line} (delta ${delta}) — they must be adjacent and the controller LAST, or a mid-install failure splits them"
  fi
done

# --- 4. No installer or lib may READ the controller. -------------------------------------------
# This became load-bearing with the fix: ${CTLV} is NOT in load_env's selector-snapshot list, so a
# child's own load_env re-sources .env.state and CLOBBERS an exported override with the PERSISTED
# value. Safe today only because nothing reads it — pin that, or the next reader silently gets the
# PREVIOUS controller while executing the new mode.
checked=$((checked + 1))
readers="$(grep -nE "\\\$\\{?${CTLV}" "${INSTALLERS[@]}" scripts/lib/istio.sh 2>/dev/null || true)"
if [ -n "$readers" ]; then
  bad "an installer/lib EXPANDS ${CTLV} — it may hold the PREVIOUS controller (load_env re-sources .env.state over the export). Use the mode literal instead:"
  printf '        %s\n' "$readers"
else
  ok "no installer/lib expands ${CTLV} (so the load_env clobber cannot bite)"
fi

# Denominator on the ITEM count, reconciled against the DERIVED corpus — not a hand-typed constant.
want=$(( 1 + ${#INSTALLERS[@]} + 1 ))
[ "$checked" -eq "$want" ] \
  || die "ran ${checked} checks but derived ${#INSTALLERS[@]} installer(s) (expected ${want}) — the gate lost track of its own corpus"

[ "$fail" -eq 0 ] || { log_error "ingress state ordering: FAILED"; exit 1; }
log_info "ingress state ordering: OK — ${checked} checks over ${#INSTALLERS[@]} DERIVED installer(s): $(printf '%s ' "${INSTALLERS[@]##*/}")"
