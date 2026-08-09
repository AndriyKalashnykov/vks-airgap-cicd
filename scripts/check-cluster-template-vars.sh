#!/usr/bin/env bash
# scripts/check-cluster-template-vars.sh — every ${VAR} in k8s/vks/cluster.yaml must be BOUND by
# scripts/25-vks-cluster-create.sh before it renders the template.
#
# WHY THIS EXISTS. 25-vks-cluster-create.sh used to check this AT RUNTIME, in python3, by walking
# template and render in lockstep looking for a substitution that came out empty. That check was
# retired for two measured reasons (both recorded at the removal site):
#
#   - It could not fire from operator input. Every variable is bound `:?` or `:-`, and both treat an
#     empty value as unset, so no `.env` a human can write reaches it. The ONLY state it detected was
#     template drift — a ${VAR} added to the YAML that the script never binds — which is a
#     commit-time defect.
#   - python3 is absent on a Photon jump box, so the check itself killed `make vks-cluster-create`
#     with rc 127 on a supported OS (MEASURED 2026-08-09 on bare photon:5.0 against a real 9.1 lab).
#
# So the assertion moved here: offline, no runtime dependency, and it fails the commit that
# introduces the drift rather than a lab run twenty minutes in.
#
# WHAT IT IS NOT. It does not check that a bound variable has a SENSIBLE value — `:-` defaults are
# the script's business. It checks BINDING ONLY: is every name the template interpolates one the
# script is guaranteed to have exported?
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TPL="${CLUSTER_TEMPLATE:-${REPO_ROOT}/k8s/vks/cluster.yaml}"
GEN="${CLUSTER_SCRIPT:-${REPO_ROOT}/scripts/25-vks-cluster-create.sh}"

for f in "$TPL" "$GEN"; do
  [ -f "$f" ] || { echo "check-cluster-template-vars: FAIL — missing $f"; exit 1; }
done

# Names the template interpolates. `${VAR}` only — the renderer is envsubst with an allowlist, so a
# bare $VAR is not substituted and must not be counted.
#
# ⚠️ SKIP FULL-LINE COMMENTS FIRST. This gate's own first run flagged `VAR`, which comes from the
# template's HEADER COMMENT explaining that `${VAR}` inside a flow mapping is a YAML syntax error.
# A gate that reads the documentation of the thing it checks reports a defect that does not exist,
# and the natural "fix" is to delete the explanation — so the comment strip is load-bearing.
# shellcheck disable=SC2016  # the ${...} here is the LITERAL text being matched/stripped, not an expansion
mapfile -t WANTED < <(
  sed -e 's/^[[:space:]]*#.*$//' "$TPL" \
    | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}' | sort -u
)

# A name is BOUND when the generator exports it before rendering. Match the export form, not a bare
# mention: a name that only appears in a comment or a log line is not bound.
#   export VAR="${VAR:-default}"   |   export VAR="${VAR:?msg}"
is_bound() { grep -qE "^[[:space:]]*export[[:space:]]+$1=" "$GEN"; }

missing=(); n=0
for v in "${WANTED[@]}"; do
  n=$((n + 1))
  is_bound "$v" || missing+=("$v")
done

[ "$n" -gt 0 ] || { echo "check-cluster-template-vars: FAIL — found ZERO \${VAR} in $(basename "$TPL"); the template or this gate's matcher is broken, and an empty set would pass vacuously"; exit 1; }

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-cluster-template-vars: FAIL — $(basename "$TPL") interpolates ${#missing[@]} variable(s) that $(basename "$GEN") never exports:"
  printf '    %s\n' "${missing[@]}"
  echo "  envsubst renders an unbound variable as EMPTY, and admission accepts an empty scalar"
  echo "  (an empty 'replicas' is not the cluster you asked for). Bind it in $(basename "$GEN")"
  echo "  with :- (a default) or :? (required), beside the others."
  exit 1
fi

echo "check-cluster-template-vars: OK — all $n \${VAR} in $(basename "$TPL") are bound by $(basename "$GEN")"
