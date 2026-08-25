#!/usr/bin/env bash
# Emit "<scenario>\t<KEY>" for every .env key the scenario documents name. One pair per line, sorted.
#
# WHY PER-SCENARIO AND NOT A UNION (B475). The union cannot express the one rule that matters.
# HARBOR_PASSWORD is named by scenario-2 and NOT by scenario-1, and the harness must EMIT it for
# scenario-2 (a tenant IS handed one -- that is scenario-2's premise) while REFUSING to emit it for
# scenario-1, where the document's §8.5 fetches it. Injecting it there skips the branch of
# 28-harbor-admin-password.sh that reads the installed password, which walk-matrix.sh records as
# never having been walked in any row, in any matrix, ever. A flat union makes those two cases
# arithmetically identical, so a gate built on it stays GREEN while that regression returns. An
# adversary proved exactly that against the first draft of this file.
#
# THE RULE, deliberately mechanical (a rule needing judgment rots like the hand-typed lists it
# replaces): within a markdown TABLE ROW, take every ALL-CAPS token inside a backtick span that is
# ALSO a key in .env.example.
#
# Three details are load-bearing, each fixing a MEASURED miss in the first draft:
#   - the row anchor allows LEADING WHITESPACE. 12 indented table rows exist across the two docs.
#   - tokens match INSIDE a span, not as the whole span, so a cell like
#     `make install-ingress INGRESS_CONTROLLER=istio-existing` yields INGRESS_CONTROLLER. It did not
#     before, and INGRESS_CONTROLLER and HARBOR_INSECURE were both missing from the set as a result.
#   - ANY cell, not just the leading one: scenario-1's tables carry keys in later columns.
#
# WALK-INCLUDE fragments are scanned too, resolved with the same sed walk-doc uses. Neither carries
# a table row today, but walk-matrix.sh's own comment cites the PR where a new include landed and
# would have killed every row.
set -euo pipefail
export LC_ALL=C   # sort/comm collation must not depend on the caller's locale.

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
DOCS_DIR="${REPO_ROOT}/docs"

[ -s "$ENV_EXAMPLE" ] || { echo "walk-env-keys: no .env.example at ${ENV_EXAMPLE}" >&2; exit 2; }

declared="$(grep -oE '^#? *[A-Z][A-Z0-9_]*=' "$ENV_EXAMPLE" 2>/dev/null | tr -d '#= ' | sort -u || true)"
[ -n "$declared" ] || { echo "walk-env-keys: .env.example declared ZERO keys -- refusing to emit an empty set" >&2; exit 2; }

for scen in scenario-1 scenario-2; do
  f="${DOCS_DIR}/${scen}.md"
  [ -s "$f" ] || { echo "walk-env-keys: missing ${f}" >&2; exit 2; }

  files=("$f")
  while IFS= read -r inc; do
    [ -n "$inc" ] || continue
    [ -s "${DOCS_DIR}/${inc}" ] || { echo "walk-env-keys: ${scen}.md walk-includes ${inc}, which is not in ${DOCS_DIR}" >&2; exit 2; }
    files+=("${DOCS_DIR}/${inc}")
  done <<< "$(sed -nE 's|^[[:space:]]*<!--[[:space:]]*walk-include:[[:space:]]*([^[:space:]]+)[[:space:]]*-->[[:space:]]*$|\1|p' "$f")"

  # shellcheck disable=SC2016  # the backticks in the ERE are LITERAL markdown code-span delimiters.
  mentioned="$(grep -hE '^[[:space:]]*\|' "${files[@]}" 2>/dev/null \
    | grep -oE '`[^`]*`' | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u || true)"
  [ -n "$mentioned" ] || { echo "walk-env-keys: ${scen}.md mentions ZERO ALL-CAPS tokens in tables -- refusing" >&2; exit 2; }

  keys="$(comm -12 <(printf '%s\n' "$declared") <(printf '%s\n' "$mentioned"))"
  [ -n "$keys" ] || { echo "walk-env-keys: ${scen}.md names ZERO .env keys -- the parse is broken, not the doc" >&2; exit 2; }
  while IFS= read -r k; do [ -n "$k" ] && printf '%s\t%s\n' "$scen" "$k"; done <<< "$keys"
done
