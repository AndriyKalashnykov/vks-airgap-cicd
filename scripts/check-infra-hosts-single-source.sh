#!/usr/bin/env bash
# check-infra-hosts-single-source.sh — no script may hand-enumerate the ingress INFRA hostnames.
#
# WHY (B528, measured 2026-09-05). Seven sites built the /etc/hosts hint, the "then browse:" line,
# the mesh-admin request and the rendered-route check by writing GITEA_HOST and TEKTON_DASHBOARD_HOST
# out longhand. Adding headlamp updated the MANIFESTS but none of those seven lists — so the ingress
# routed headlamp.vks.local correctly while every operator-facing line omitted it. The operator
# pastes a hosts line with no headlamp entry, the UI does not resolve, and it reads as "headlamp is
# broken" when it is installed, routed and serving. Classic enumerated-list rot: the list and the
# thing it describes drift, silently, and only a human eyeballing the output ever notices.
#
# THE ONE SOURCE is ingress_infra_hosts() / ingress_infra_urls() in scripts/lib/apps.sh. Adding a
# fourth infra UI is one line there.
#
# ⚠️ THIS GATE MUST NOT MATCH ITSELF. The forbidden pattern is COMPOSED at runtime (never written
# out as a literal), so this file contributes zero hits to its own scan — asserted by the
# self-check at the end, which is the only one of the three layers that is not silent when it fails.
# Do NOT "fix" a self-hit by excluding this file: that blinds the gate to every future finding in it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"

# Composed, so the literal pair never appears in this file.
_G="$(printf 'GITEA%sHOST' '_')"
_T="$(printf 'TEKTON%sDASHBOARD%sHOST' '_' '_')"
# ⚠️ The optional `(:-[^}]*)?` is LOAD-BEARING and was added after this gate reported OK over a
# 9th site (creds.sh:642) that wrote ${GITEA_HOST:-gitea.vks.local}. A bare-${VAR} pattern is
# blind to the defaulted form, which is the form a REPORT uses — i.e. exactly the operator-
# facing line this gate exists to protect. Measured: 116 files scanned, 0 hits, 1 real miss.
PAT="\\\$\\{${_G}(:-[^}]*)?\\}[^\"']*\\\$\\{${_T}(:-[^}]*)?\\}"

# The ONE place allowed to name them, plus the docs/templates that legitimately do.
ALLOW_FILE="scripts/lib/apps.sh"

cd "$REPO_ROOT"
files="$(git ls-files 'scripts/*.sh' | grep -v '^scripts/test-' | grep -v '^scripts/check-' || true)"
n=0; hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$((n + 1))
  [ "$f" = "$ALLOW_FILE" ] && continue
  # Strip comments: a comment naming both vars is documentation, not an enumeration.
  # EXEMPT, with a reason: an envsubst allowlist is a list of VARIABLE NAMES, not a list of
  # hostnames — it MUST name every var it substitutes or the manifest renders a literal ${VAR}
  # and Istio's webhook rejects the apply (measured 2026-09-05). It is not an operator-facing
  # enumeration and adding a host there is REQUIRED, not rot. Matched narrowly (the line must
  # mention envsubst or be an *_ALLOWLIST assignment) so an ordinary hosts line beside one is
  # still caught.
  m="$(sed 's/^[[:space:]]*#.*//' "$f" \
       | grep -vE 'envsubst|^[[:space:]]*[A-Z_]*ALLOWLIST=' \
       | grep -nE "$PAT" || true)"
  if [ -n "$m" ]; then
    hits=$((hits + 1))
    log_error "${f}: hand-enumerates the infra hostnames instead of calling ingress_infra_hosts()"
    printf '%s\n' "$m" | sed 's/^/      /'
  fi
done <<EOF
$files
EOF

# SELF-CHECK (the layer that is not silent). If this file ever contains the literal pair, the
# composition above has been replaced and the gate is scanning for something it also contains.
self="$(sed 's/^[[:space:]]*#.*//' "scripts/$(basename "${BASH_SOURCE[0]}")" | grep -cE "$PAT" || true)"
if [ "${self:-0}" -ne 0 ]; then
  log_error "this gate MATCHES ITSELF (${self} hit(s)) — the runtime-composed pattern has been"
  log_error "  replaced by a literal. Re-compose it; do NOT exclude this file from the scan."
  exit 1
fi

if [ "$hits" -ne 0 ]; then
  log_error "check-infra-hosts-single-source: FAILED — ${hits} file(s) of ${n} scanned."
  log_error "  Use: \$(ingress_infra_hosts)   or   \$(ingress_infra_urls)   from scripts/lib/apps.sh"
  exit 1
fi
log_info "check-infra-hosts-single-source: OK — scanned ${n} script(s); only ${ALLOW_FILE} names them."
