#!/usr/bin/env bash
# Istio ABSENCE may only be claimed when the cluster ANSWERED.
#
# B484/F1. Both reads in 48-istio-preflight.sh discarded rc and stderr, and `!` turns a FAILED read
# into "not present" -- so a Forbidden tenant or an unreachable cluster produced
# "NO Istio detected on this cluster." and exit 0.
#
# That string is not cosmetic: walk-doc.sh:84 greps it EXACTLY and returns `install`, and the install
# path helm-installs a SECOND istiod over the platform's (46-install-istio.sh:182) and relabels
# istio-system's PSA (46-install-istio.sh:167) -- cross-tenant destructive, as 48's own comment says.
#
# The live trigger is the TENANT: both reads are CLUSTER-SCOPED, and docs/scenario-2.md runs
# `make istio-preflight` with NO upstream gate (scenario-1 is protected only because lab-preflight
# dies on UNREACHABLE first).
#
# BOTH DIRECTIONS: a fix that never claims absence would pass the tenant case and destroy the
# genuine-absence path that KinD and a fresh cluster rely on.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
fail=0

mk() { # $1=dir $2=mode
  mkdir -p "$1/bin"
  case "$2" in
    forbidden) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *"get crd virtualservices"*) echo 'Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io is forbidden: User "t" cannot get resource "customresourcedefinitions" at the cluster scope' >&2; exit 1 ;;
  *"get deploy -A"*) echo 'Error from server (Forbidden): deployments.apps is forbidden: User "t" cannot list resource "deployments" at the cluster scope' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
    ;;
    dead) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *) echo 'Unable to connect to the server: dial tcp 127.0.0.1:1: connect: connection refused' >&2; exit 1 ;;
esac
EOF
    ;;
    crdabsent) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# The CRD read is DEFINITIVE (server NotFound about that exact CRD) while the deploy read fails.
# A symmetric ladder turned this into a hard block -- but the CRD settles absence on its own, and
# installing Istio is the whole point on such a cluster.
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *"get crd virtualservices"*) echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "virtualservices.networking.istio.io" not found' >&2; exit 1 ;;
  *"get deploy -A"*) echo 'Error from server (Forbidden): deployments.apps is forbidden' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
    ;;
    deploy404) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# REAL kubectl 1.36.4 against a 404 endpoint. It carries the SERVER prefix AND the word
# "deployments", so a token test on `deployments` called it ABSENT off a read that FAILED.
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *"get crd virtualservices"*) echo 'Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io is forbidden' >&2; exit 1 ;;
  *"get deploy -A"*) echo 'Error from server (NotFound): Unable to find "apps/v1, Resource=deployments" that match label selector "app=istiod", field selector "": the server could not find the requested resource' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
    ;;
    staleconf) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# REAL kubectl 1.36.4 output for a dangling `current-context` -- the commonest kubeconfig fault.
# It contains the phrase "not found" and is NOT about the resource. The pre-fix substring test
# classified BOTH reads as `absent` here and emitted the walk-doc.sh install anchor.
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *) echo 'Error in configuration: context was not found for specified context: ghost' >&2; exit 1 ;;
esac
EOF
    ;;
    http404) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# An endpoint answering HTTP 404 (a proxy, a wrong port). Also contains the phrase.
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *) echo 'Error from server (NotFound): the server could not find the requested resource' >&2; exit 1 ;;
esac
EOF
    ;;
    onesided) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# The HIGH: one read UNKNOWN (CRD forbidden -- cluster-scoped, denied to a tenant) while the
# other legitimately matches nothing (an istiod not labelled app=istiod). Neither says absent.
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *"get crd virtualservices"*) echo 'Error from server (Forbidden): customresourcedefinitions.apiextensions.k8s.io is forbidden' >&2; exit 1 ;;
  *"get deploy -A"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
    ;;
    absent) cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"version -o json"*|*"config current-context"*) echo ctx; exit 0 ;;
  *"get crd virtualservices"*) echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "virtualservices.networking.istio.io" not found' >&2; exit 1 ;;
  *"get deploy -A"*) exit 0 ;;   # answered, zero matches
  *) exit 0 ;;
esac
EOF
    ;;
  esac
  chmod +x "$1/bin/kubectl"
}

RC=0
run() { local d out; d="$(mktemp -d)"; mk "$d" "$1"
  out="$(PATH="$d/bin:$PATH" SKIP_DOTENV=1 VKS_STATE_FILE="$d/none" timeout 90 scripts/48-istio-preflight.sh 2>&1)"
  RC=$?
  rm -rf "$d"
  # ⚠️ the CALLER wraps this in $( ), which is a SUBSHELL — so RC set here is invisible to it.
  # Hand the rc back through the OUTPUT instead, on a line the caller strips.
  printf '%s\n__RC__=%s\n' "$out" "$RC"; }
_out_of() { printf '%s' "$1" | grep -v '^__RC__='; }
_rc_of()  { printf '%s' "$1" | sed -n 's/^__RC__=//p' | tail -1; }

# The harness must fail CLOSED. An unparseable rc made `[ "$rc" -eq 0 ]` error, and with `set -e`
# off the `if` took the ELSE branch -- so a broken harness reported PASS.
ck_rc() { case "${1:-}" in ""|*[!0-9]*) echo "    FAIL    harness: unparseable rc '${1:-}'"; fail=1 ;; esac; }

echo "  case 1: FORBIDDEN tenant — must NOT claim absence, must NOT exit 0"
raw="$(run forbidden)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    FAIL    emits the harness anchor 'NO Istio detected' -> walk-doc.sh runs the INSTALL variant"; fail=1
else echo "    ok      does not emit 'NO Istio detected'"; fi
if [ "$rc" -eq 0 ]; then echo "    FAIL    exit 0 -> callers proceed"; fail=1; else echo "    ok      non-zero exit ($rc)"; fi
if printf '%s' "$out" | grep -qF 'could not determine whether Istio is present'; then
  echo "    ok      says it could not determine"
else echo "    FAIL    no could-not-determine message"; fail=1; fi

echo "  case 2: UNREACHABLE cluster — same"
raw="$(run dead)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then echo "    FAIL    claims absence on an unreachable cluster"; fail=1
else echo "    ok      does not claim absence"; fi
if [ "$rc" -ne 0 ]; then echo "    ok      non-zero exit ($rc)"; else echo "    FAIL    exit 0"; fail=1; fi

echo "  case 3: GENUINE absence (cluster ANSWERED: NotFound + zero deploys) — must still work"
raw="$(run absent)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    ok      still reports absence when the cluster answered"
else echo "    FAIL    genuine absence no longer detected -- the fix broke KinD"; fail=1; fi
if [ "$rc" -eq 0 ]; then echo "    ok      exit 0, as callers expect"; else echo "    FAIL    exit $rc on genuine absence"; fail=1; fi


echo "  case 4: STALE kubeconfig (dangling current-context) -- 'not found' that is NOT about Istio"
raw="$(run staleconf)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"; ck_rc "$rc"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    FAIL    emits the install anchor on a CLIENT-SIDE config error"; fail=1
else echo "    ok      does not claim absence"; fi
if printf '%s' "$out" | grep -qF 'could not determine whether Istio is present'; then
  echo "    ok      says it could not determine"
else echo "    FAIL    no could-not-determine message"; fail=1; fi

echo "  case 5: an endpoint answering HTTP 404 -- also carries the phrase"
raw="$(run http404)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"; ck_rc "$rc"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    FAIL    emits the install anchor on a server 404"; fail=1
else echo "    ok      does not claim absence"; fi

echo "  case 6: ONE-SIDED unknown (CRD forbidden + deploy legitimately empty)"
raw="$(run onesided)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"; ck_rc "$rc"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    FAIL    an UNKNOWN read was spent as evidence of absence"; fail=1
else echo "    ok      one unknown read poisons the absence claim"; fi


echo "  case 7: DEFINITIVE crd-absent + a FAILED deploy read -- must still report absence"
raw="$(run crdabsent)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"; ck_rc "$rc"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    ok      the CRD read settles it; a failed partner does not veto a definitive answer"
else echo "    FAIL    a definitive crd=absent was overridden by a failed partner read"; fail=1; fi
if [ "$rc" -eq 0 ]; then echo "    ok      exit 0"; else echo "    FAIL    exit $rc — hard block on a cluster where Istio is genuinely absent"; fail=1; fi

echo "  case 8: a 404 whose text CONTAINS 'deployments' -- the token must not vouch for it"
raw="$(run deploy404)"; out="$(_out_of "$raw")"; rc="$(_rc_of "$raw")"; ck_rc "$rc"
if printf '%s' "$out" | grep -qF 'NO Istio detected'; then
  echo "    FAIL    claimed absence off a FAILED list read (the 'deployments' token matched a 404)"; fail=1
else echo "    ok      a failed list read is never absence"; fi

[ "$fail" -eq 0 ] || { echo "test-istio-preflight-absence: FAILED"; exit 1; }
echo "test-istio-preflight-absence: OK"
