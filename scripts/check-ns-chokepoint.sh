#!/usr/bin/env bash
# check-ns-chokepoint.sh — no NEW namespace-creating call may appear outside the chokepoint.
#
# WHAT IT GUARDS. `ensure_namespace` (scripts/lib/psa.sh) is the ONLY place a namespace we own gets
# its PSA level and its istio-injection=disabled label. A namespace created by any other path gets
# neither, is INVISIBLE on KinD (which enforces no PSA), and has its pods REJECTED on a real VKS
# guest, where `restricted` is the default.
#
# WHY A FOURTH GATE, when check-namespace-labelled.sh already has three assertions. Measured: append
# `run kubectl <create> <namespace> foo-system` to an installer and all three stay GREEN **with
# byte-identical counts** — the derived cross-check only sees namespaces created VIA ensure_namespace,
# and psa-check iterates NS_SPEC and never asks the cluster what it actually has. So a new installer
# creating a namespace by any bypassing path is invisible to every existing check. That is this
# repo's own "a gate green at the SAME COUNT is blind to it", and it is what this gate closes.
#
# ⚠️ COVERAGE IS 4 OF THE 10 KNOWN MECHANISMS, AND THE LIST IS OPEN. Say it plainly rather than imply
# closure:
#   COVERED    M1 a literal kubectl invocation; M2 the same via a wrapper (ka/kg/hub/guest/run);
#              M5 the helm create-ns flag; M7 the ArgoCD create-ns syncOption.
#   INVISIBLE  M4 an upstream manifest we apply and M6 a chart shipping its own Namespace — BOTH live
#              in bundle/, which is gitignored (`git ls-files bundle/` = 0), so a gate scanning there
#              passes vacuously. Out of scope BY CONSTRUCTION, not by oversight.
#   UNDETECTABLE STATICALLY  M9 `envsubst | kubectl apply -f -` and M10 a heredoc apply: whether the
#              rendered document contains a Namespace cannot be known without rendering it.
#   NOT A BYPASS  M3 an in-tree `kind: Namespace` (zero on the tree) and M8 ensure_namespace itself.
# An adversary broke a best-faith version of this gate in ten minutes with TWO forms outside all ten
# (a runtime-generated manifest written to /tmp then applied, and a verb held in a variable). Both are
# still missed. The corpus of bypass forms is OPEN; treat a future miss as expected, not as scandal.
#
# THE COMMENT POLARITY IS THE OPPOSITE OF check-namespace-labelled's, deliberately. That gate must NOT
# strip comments, because a commented-out `ensure_namespace` means the call is GONE — the defect it
# hunts. This gate hunts a call that must NOT EXIST, so a commented-out one is genuinely harmless.
# Stripping comment LINES takes the hit count from 25 to 10 with zero false negatives (measured).
# The test is on the FIRST non-space character, not `${line%%#*}`, which would false-negative on
# `${#HITS[@]}`, `${v#pfx}` and a URL fragment.
#
# THE PATTERNS ARE COMPOSED AT RUNTIME so this file never contains the literals it hunts. A gate that
# is a script in the tree it scans must not contain the form it looks for — otherwise it flags itself,
# and the reflex fix (excluding the file by name) blinds it to every future real finding here.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

_CRE="$(printf 'cre%s' 'ate')"
_NSW="$(printf 'name%s' 'space')"
_WRAPPERS='kubectl|ka|kg|hub|guest|run'
PAT_CALL="(${_WRAPPERS})[[:space:]].*${_CRE}[[:space:]]+(${_NSW}|ns)([[:space:]]|\"|\$)"
PAT_HELM="--${_CRE}-${_NSW}"
PAT_ARGO="$(printf 'C%sN%s=true' 'reate' 'amespace')"

# ALLOWED: <path>|<expected hit count>|<why>. Keyed by COUNT, not by line number, because line
# numbers rot on the first edit above them — and because a count forces a decision when a NEW hit
# appears in an already-allowed file, which keying by filename alone would wave through.
ALLOWED='scripts/lib/psa.sh|1|THE CHOKEPOINT ITSELF — this is the call every other site must route through
scripts/06-install-harbor.sh|1|the helm create-ns flag, immediately preceded by ensure_namespace for the same ns
scripts/46-install-istio.sh|2|the helm create-ns flag for the mesh namespaces, labelled via psa_label_namespace (NOT ensure_namespace: stamping istio-injection=disabled on the platform mesh is exactly what we must never do)
scripts/90-e2e-istio-existing.sh|4|e2e fixtures: two namespaces are left DELIBERATELY BARE so the injection probe has a negative control, plus the platform-mesh helm installs
scripts/e2e-cross-cluster.sh|1|the wrapper form, for the cross-cluster e2e ArgoCD ns — a throwaway hub cluster, not an owned workload namespace
k8s/argocd/application.yaml|1|the ArgoCD create-ns syncOption: the app namespace is ALSO created by ensure_namespace in 70-configure-argocd.sh, which is what labels it'

# PURE BUILTINS, no forks. This ran `printf | sed | cut` (3 processes) per LINE; across the corpus
# that alone measured 26.1s of the gate's 61.3s. `${1%%[![:space:]]*}` is the leading whitespace,
# so `${1#...}` strips it. Verdicts are identical (7617 comment lines, both forms).
is_comment_line() { local s=${1#"${1%%[![:space:]]*}"}; case $s in '#'*) return 0 ;; *) return 1 ;; esac; }

scanned=0; hits=0; flagged=0
declare -A FILE_HITS=()

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    is_comment_line "$line" && continue
    # Builtins, not `printf | grep` — this forked THREE processes per line and was 61% of the whole
    # static-check span (62s here, plus ~119s more because test-gate-vacuity runs this gate twice).
    # The `=~` RHS MUST stay UNQUOTED: a quoted RHS is compared as a LITERAL, which silently matches
    # nothing and would make this gate a vacuous green. The -qF cases are fixed strings, so they use
    # a glob with a QUOTED var (literal) — the opposite rule. Differential-oracled against the grep
    # form: 0 divergences over 19,796 real lines of this repo's scripts/ + k8s/, plus 0 over
    # 16 crafted cases (tabs, CRLF, whitespace-only, `%`, backslashes). Both numbers were
    # measured HERE; an earlier revision quoted a corpus size taken from a review and never
    # verified locally — a code comment must not assert a borrowed measurement as fact.
    if [[ $line =~ $PAT_CALL ]] \
    || [[ $line == *"$PAT_HELM"* ]] \
    || [[ $line == *"$PAT_ARGO"* ]]; then
      n=$((n + 1))
    fi
  done < "$f"
  [ "$n" -gt 0 ] && { FILE_HITS["$f"]=$n; hits=$((hits + n)); }
done <<EOF
$(git ls-files 'scripts/*.sh' 'k8s/*.yaml' 'k8s/*.yml' 2>/dev/null)
EOF

[ "$scanned" -gt 0 ] || die "check-ns-chokepoint: scanned 0 files — the pathspec is broken and a green here would mean nothing."

# SELF-TEST: this file must contribute ZERO hits. If it ever does, the composition above has been
# undone and the gate is flagging itself — at which point someone will "fix" it by excluding this
# file, which blinds it to every future real finding in it.
[ "${FILE_HITS["scripts/$(basename "${BASH_SOURCE[0]}")"]:-0}" -eq 0 ] \
  || die "check-ns-chokepoint: this gate matched ITSELF — the runtime-composed patterns have been replaced by literals. Re-compose them; do NOT exclude this file."

# --- reconcile the allowlist in BOTH directions --------------------------------------------------
allowed_entries=0
while IFS='|' read -r path want _why; do
  [ -n "${path:-}" ] || continue
  allowed_entries=$((allowed_entries + 1))
  got="${FILE_HITS[$path]:-0}"
  if [ "$got" -ne "$want" ]; then
    if [ "$got" -eq 0 ]; then
      log_error "  ${path}: allowed for ${want} hit(s) but has NONE — the call was removed or moved. Delete the entry; a dead entry documents a call site that no longer exists."
    else
      log_error "  ${path}: allowed for ${want} hit(s) but found ${got} — a namespace-creating call was ADDED or REMOVED here. Route it through ensure_namespace, or update the count WITH a reason."
    fi
    flagged=$((flagged + 1))
  fi
  unset "FILE_HITS[$path]"
done <<EOF
$ALLOWED
EOF

# whatever remains was never declared
for f in "${!FILE_HITS[@]}"; do
  log_error "  ${f}: ${FILE_HITS[$f]} namespace-creating call(s) OUTSIDE the chokepoint and not declared."
  log_error "      ensure_namespace (scripts/lib/psa.sh) is the ONLY place a namespace we own gets its"
  log_error "      PSA level and its istio-injection=disabled label. KinD enforces no PSA, so a namespace"
  log_error "      missing both is INVISIBLE locally and has its pods REJECTED on a real VKS guest."
  log_error "      Route it through ensure_namespace, or add an entry to ALLOWED with a reason."
  flagged=$((flagged + 1))
done

if [ "$flagged" -gt 0 ]; then
  log_error "check-ns-chokepoint: FAILED — ${flagged} file(s) disagree with the allowlist (scanned ${scanned}, ${hits} hit(s), ${allowed_entries} allowed entries)."
  exit 1
fi
log_info "check-ns-chokepoint: OK — ${hits} namespace-creating call(s) across ${scanned} scanned file(s), all ${allowed_entries} declared with a reason. Covers 4 of 10 known mechanisms; bundle/ (gitignored) and render-time applies are out of scope BY CONSTRUCTION — see the header."
