#!/usr/bin/env bash
# scripts/lib/argocd.sh — the two-cluster facts about ArgoCD, as PURE functions.
#
# ArgoCD is a Supervisor Service: on a real lab it runs in a DIFFERENT cluster from the workload.
# Two things follow, and BOTH were wrong in this repo until they were made explicit here:
#
#   1. WHERE the Applications/repo Secrets are created  -> the ArgoCD cluster, not the guest.
#   2. WHICH Gitea URL ArgoCD can actually clone        -> not a guest cluster-local Service DNS name,
#                                                          and not the ingress hostname either.
#
# They live in a library (not inline in 70-configure-argocd.sh) so they can be RED-tested offline,
# with nothing but two kubeconfig FILES — no cluster. `kubectl config view` reads the file; it never
# dials the API server. See scripts/test/test-argocd-lib.sh.
#
# shellcheck shell=bash

[ -n "${__VKS_ARGOCD_SH_LOADED:-}" ] && return 0
__VKS_ARGOCD_SH_LOADED=1

# The in-cluster destination — "the cluster ArgoCD itself runs in". Correct ONLY when ArgoCD and the
# workload share a cluster. When they do not, this means the SUPERVISOR.
# shellcheck disable=SC2034  # consumed by the scripts that source this library (70-configure-argocd.sh)
ARGOCD_INCLUSTER_SERVER='https://kubernetes.default.svc'

# The Harbor image-PULL Secret created in every app namespace by 70-configure-argocd.sh.
#
# A CONSTANT, deliberately not an env var: the same name is written in each app's
# deploy/<app>/deployment.yaml, and those manifests are the GitOps source of truth — ArgoCD applies
# them verbatim from the Gitea repo, so they are never envsubst-rendered and CANNOT follow an
# operator override. Making it settable would let the Secret and the Deployment disagree, and the
# only symptom would be ImagePullBackOff. `make check-pull-secret-alignment` gates the two.
# shellcheck disable=SC2034  # consumed by the scripts that source this library
HARBOR_PULL_SECRET='harbor-pull'

# The VKS ArgoCD operator CRD — a fixed string. It lives here (not inline in 23-argocd-preflight.sh) so
# argocd_print_versions() below is self-contained and can be reused by the read-only `make argocd-version`.
# shellcheck disable=SC2034  # consumed by argocd_print_versions() and the scripts that source this library
VKS_ARGOCD_CRD='argocds.argocd-service.vsphere.vmware.com'

# argocd_api_server <kubeconfig> — the API server URL a kubeconfig points at. Offline: reads the file.
argocd_api_server() {
  kubectl --kubeconfig "$1" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

# argocd_is_off_cluster <argocd-kubeconfig> <guest-kubeconfig> — exit 0 when ArgoCD runs in a
# DIFFERENT cluster from the workload.
#
# DERIVED from the two kubeconfigs, never remembered from a file. That is the whole point: the value
# that used to carry this fact (ARGOCD_DEST_SERVER) is published to `.env.kind` — a file `make
# kind-down` deletes and a fresh checkout has never had. Trusting it means that on a wiped overlay
# the in-cluster default silently returns, and `make gitops` creates a prune:true/selfHeal:true
# Application aimed at the ArgoCD cluster itself. On a real lab that is the Supervisor.
argocd_is_off_cluster() {
  local a g
  a="$(argocd_api_server "$1")"; g="$(argocd_api_server "$2")"
  [ -n "$a" ] || die "could not read the ArgoCD cluster's API server from $1"
  [ -n "$g" ] || die "could not read the guest cluster's API server from $2"
  [ "$a" != "$g" ]
}

# The go-template that lists the clusters registered with an ArgoCD, as `<name>\t<server>` lines.
#
# THE FIELD IS `data.name`, NOT `metadata.name`. An ArgoCD cluster Secret carries the cluster's real
# name in `data.name`; `metadata.name` is a prefixed object name (`cluster-<name>` — see
# 71-argocd-register-guest.sh, and ArgoCD's declarative-setup docs). Reading metadata.name made the
# by-NAME match DEAD: ARGOCD_DEST_CLUSTER_NAME=vks-guest could never equal `cluster-vks-guest`.
# That is the one tiebreak a shared-lab tenant actually needs, because the guest API URL ArgoCD dials
# often differs from the one in their kubeconfig (that is what GUEST_API_SERVER exists for), so the
# by-SERVER match misses and everything falls through to "AMBIGUOUS — refusing". It fails SAFE, but
# the operator's documented escape hatch was inert — and KinD can never show it (one registered
# cluster, so the single-cluster rule always wins).
#
# It lives here as a CONSTANT so the contract can be asserted offline (test-argocd-topology.sh);
# kubectl cannot render a go-template without an API server, so the expression itself is what we gate.
# shellcheck disable=SC2034,SC2016  # SC2034: used by sourcing scripts. SC2016: the {{...}} are
# GO-template expressions, not shell — single quotes are deliberate (they must NOT be expanded).
ARGOCD_CLUSTER_LIST_TEMPLATE='{{range .items}}{{.data.name | base64decode}}{{"\t"}}{{.data.server | base64decode}}{{"\n"}}{{end}}'

# argocd_pick_dest_server <guest_api> <dest_name> — choose WHICH registered ArgoCD cluster the app
# deploys to, reading `<name>\t<server>` lines (one per registered Cluster Secret) on STDIN.
# Prints the chosen server, or prints NOTHING (exit 1) if the choice is not unambiguous.
#
# WHY THIS EXISTS — it fixes a defect in the first version of this fix, which took `.items[0]`:
# on a SHARED ArgoCD (the real-lab TENANT case, where the platform team has registered MANY guest
# clusters) `.items[0]` is an ARBITRARY cluster. The Application is created with prune:true and
# selfHeal:true — so "arbitrary" means we could have deployed this tenant's app into ANOTHER
# TENANT'S CLUSTER, and then pruned whatever did not match. KinD can never show it (one cluster,
# one Secret, so items[0] is always right).
#
# The rule: match EXACTLY, or refuse. Never pick for the operator.
#   1. by NAME   — the destination the register step gave us (ARGOCD_DEST_CLUSTER_NAME)
#   2. by SERVER — the API URL of the very kubeconfig we are deploying with
#   3. exactly ONE registered cluster ⇒ unambiguous, take it
#   4. otherwise ⇒ FAIL. The caller must print the candidates and make the operator choose.
argocd_pick_dest_server() {
  local guest_api="${1:-}" dest_name="${2:-}" n s only_s="" count=0
  local by_name="" by_server=""
  # `|| [ -n "${n:-}" ]` is load-bearing: `read` returns non-zero on a final line with no trailing
  # newline, and a plain `while read` would SILENTLY DROP it. That is not academic — it is how the
  # single-registered-cluster case returned nothing and the multi-cluster case saw only the first
  # entry (i.e. it re-created the very "pick an arbitrary cluster" bug this function exists to kill).
  while IFS="$(printf '\t')" read -r n s || [ -n "${n:-}" ]; do
    [ -n "${s:-}" ] || continue
    count=$((count + 1)); only_s="$s"
    [ -n "$dest_name" ] && [ "$n" = "$dest_name" ] && by_name="$s"
    [ -n "$guest_api" ] && [ "$s" = "$guest_api" ] && by_server="$s"
  done
  if   [ -n "$by_name" ];   then printf '%s' "$by_name";   return 0
  elif [ -n "$by_server" ]; then printf '%s' "$by_server"; return 0
  # ⚠️ THE count==1 FALLBACK IS ONLY VALID WHEN WE DO NOT KNOW OUR OWN GUEST. It used to fire
  # unconditionally, and that is the "pick an arbitrary cluster" bug this function was written to
  # kill — merely narrowed to the single-cluster case, which is the NORMAL shape of a shared lab.
  #
  # MEASURED 2026-08-08 on a real 9.1 lab, and it deployed into someone else's cluster: our guest
  # was https://192.168.101.134:6443 (a cluster we had just created), the ArgoCD on the Supervisor
  # had exactly ONE registered cluster — the LAB's own lab-gc1 at https://192.168.101.132:6443 —
  # and with no name match and no server match this returned lab-gc1. 71-argocd-register-guest.sh
  # then logged "ALREADY registered — nothing to do", never registered our cluster, and the
  # Application deployed javawebapp INTO THE LAB'S CLUSTER. It reported Synced/Healthy the whole
  # time, because it was genuinely healthy — in the wrong place. Our own namespace stayed empty and
  # `make verify` failed with "ArgoCD did not roll a new image", naming nothing near the cause.
  #
  # When the caller HAS a guest_api, "no match" is the honest answer: it makes the caller register
  # the guest instead of adopting a stranger. The fallback survives only for the tenant who cannot
  # read a guest kubeconfig at all and passes an empty guest_api.
  elif [ "$count" = 1 ] && [ -z "$guest_api" ]; then printf '%s' "$only_s"; return 0
  fi
  return 1
}

# argocd_url_is_cluster_local <url> — exit 0 if the URL can only be resolved from INSIDE the cluster
# that hosts it (a Service DNS name, localhost, or a loopback address).
argocd_url_is_cluster_local() {
  printf '%s' "$1" | grep -qE '\.svc(\.cluster\.local)?(:[0-9]+)?(/|$)|//localhost|//127\.'
}

# argocd_assert_clonable_url <off_cluster:0|1> <url> [gitea-namespace] [ingress-host]
#
# Dies when an OFF-CLUSTER ArgoCD is asked to clone an address only the guest cluster can resolve.
# Without this, every Application fails with `dial tcp: lookup gitea-http.gitea.svc` — and, because
# an Application ArgoCD never reconciled has no status at all, it fails SILENTLY.
argocd_assert_clonable_url() {
  local off="$1" url="$2" ns="${3:-gitea}" host="${4:-gitea.vks.local}"
  [ "$off" = "1" ] || return 0
  argocd_url_is_cluster_local "$url" || return 0
  log_error "GITEA_ARGOCD_URL is a CLUSTER-LOCAL address: ${url}"
  log_error "  ArgoCD's repo-server runs in ANOTHER cluster and cannot resolve it — every"
  log_error "  Application would fail with 'dial tcp: lookup ...'."
  log_error "  Use Gitea's own LoadBalancer address (40-install-gitea.sh publishes it):"
  log_error "    kubectl -n ${ns} get svc gitea-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
  log_error "  The ingress hostname (${host}) is NOT usable here: it exists only in your /etc/hosts,"
  log_error "  and dialling the ingress IP sends 'Host: <ip>', which matches no vhost (404, not a clone)."
  die "set GITEA_ARGOCD_URL to an address the ArgoCD cluster can reach."
}

# ---------------------------------------------------------------------------
# gitea_clone_url — the ONE address ArgoCD's repo-server will clone from.
#
# It MUST have exactly one definition. It is consumed in two places that have to AGREE:
#   * 70-configure-argocd.sh  — builds the Application's repoURL
#   * an AppProject's sourceRepos — which must PERMIT that exact repoURL
# When they were derived separately, they drifted the moment one of them changed: the tenant e2e
# built its AppProject from GITEA_INTERNAL_URL while gitops used the live LB, and argocd-server
# rejected the Application with
#     "application repo http://<lb>:3000/... is not permitted in project 'tenant-a'"
# — an error about PERMISSIONS that was really about two copies of a URL.
#
# Resolution order (never read back a published GITEA_ARGOCD_URL — see 70 for why):
#   1. GITEA_ARGOCD_URL_OVERRIDE — the operator's explicit choice; nothing auto-publishes it.
#   2. Gitea's own LoadBalancer, resolved from the LIVE Service (the address an off-cluster
#      ArgoCD can actually reach).
#   3. GITEA_INTERNAL_URL — correct only when ArgoCD runs in this cluster.
# ---------------------------------------------------------------------------
gitea_clone_url() {
  local lb
  if [ -n "${GITEA_ARGOCD_URL_OVERRIDE:-}" ]; then
    printf '%s' "$GITEA_ARGOCD_URL_OVERRIDE"; return 0
  fi
  lb="$(kubectl -n "${GITEA_NAMESPACE:-gitea}" get svc gitea-http \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' \
          2>/dev/null || true)"
  if [ -n "$lb" ]; then
    printf 'http://%s:3000' "$lb"; return 0
  fi
  printf '%s' "${GITEA_INTERNAL_URL:-}"
}

# argocd_print_versions <argocd-kubeconfig> <namespace> [kubectl-timeout]
# READ-ONLY. Prints the ArgoCD CLI (client), the CLI≠server caveat, the operator/CRD info, the RUNNING
# server image (or a loud UNAVAILABLE), and this repo's pin. Self-contained — reads only its args +
# ARGOCD_VERSION + the VKS_ARGOCD_CRD constant, builds its OWN kubectl invocation (does NOT close over
# 23-argocd-preflight.sh's ka()), and NEVER exits (degrades gracefully with no cluster). Shared by
# `make argocd-preflight` (the gate) and the read-only `make argocd-version`.
#
# The server probe runs ONLY against a present, EXISTING kubeconfig FILE — so it can never fall through
# to kubectl's default resolution ($KUBECONFIG → ~/.kube/config) and print an UNRELATED cluster's server
# as "the version that matters". --request-timeout bounds a black-hole endpoint so a version peek can't hang.
argocd_print_versions() {
  local kc="${1:-}" ns="${2:-argocd}" to="${3:-3s}"
  if have argocd; then
    log_info "argocd CLI (client): $(argocd version --client --short 2>/dev/null || echo unknown)"
  else
    log_warn "argocd CLI not on PATH — it is REQUIRED on the tenant path (argocd-server is the only writer a tenant may have)."
  fi
  log_info "  NOTE: the CLI version is NOT the ArgoCD *server* version — the CLI and the server are versioned INDEPENDENTLY and a CLI is deliberately tolerant across a server range. The number that matters on your lab is the RUNNING server, below -- this line names no generation on purpose, because it was wrong for two years."
  if [ -z "$kc" ] || [ ! -f "$kc" ] || ! have kubectl; then
    local why
    if   [ -z "$kc" ];   then why="no kubeconfig set (KUBECONFIG / ARGOCD_KUBECONFIG)"
    elif [ ! -f "$kc" ]; then why="kubeconfig file not found: $kc"
    else                     why="kubectl not installed"
    fi
    log_warn "RUNNING server version: UNAVAILABLE — $why. On a real lab the RUNNING server is the number that matters; the CLI version and the KinD pin are NOT it."
    log_info "this repo's KinD pin: ARGOCD_VERSION=${ARGOCD_VERSION:-?}"
    return 0
  fi
  local ka=(kubectl --kubeconfig "$kc" --request-timeout="$to")
  if "${ka[@]}" get crd "$VKS_ARGOCD_CRD" >/dev/null 2>&1; then
    # NOT "supported versions" -- `kubectl explain` prints a PATTERN plus one QUOTED PROSE EXAMPLE, and
    # this repo measured that on a real Supervisor: 08-install-supervisor-service.sh:111-117 records
    # that the CRD carries NO enum and that a naive scrape returns the example WITH ITS TRAILING QUOTE.
    # The authoritative artifact is the Carvel PACKAGE the operator publishes (queried by
    # 08-install-argocd-service.sh:148), not this. Labelling prose as an enumeration is the same
    # class of error as the 2.x claims above: pointing the reader at something that cannot answer.
    log_info "VKS ArgoCD operator present. Version FIELD SCHEMA (a pattern + example, NOT an enumeration):"
    "${ka[@]}" explain argocd.spec.version 2>/dev/null | sed 's/^/    /' || true
    "${ka[@]}" get argocd -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VERSION:.spec.version' 2>/dev/null | sed 's/^/    /' || true
  else
    log_info "no VKS ArgoCD operator CRD on the ArgoCD cluster — upstream ArgoCD (the KinD stand-in), or you are a tenant who may not read CRDs."
  fi
  local img
  img="$("${ka[@]}" -n "$ns" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [ -n "$img" ]; then
    log_info "RUNNING argocd-server image: $img   <- THE version that matters on a real lab"
  else
    log_warn "RUNNING server version: UNAVAILABLE — no cluster reachable in ns/$ns (ArgoCD is elsewhere, you may not read it as a tenant, or your cluster is down). On a real lab THIS is the number that matters; the CLI version and the pin above are NOT it."
  fi
  log_info "this repo's KinD pin: ARGOCD_VERSION=${ARGOCD_VERSION:-?}"
}

# argocd_kubeconfig_stale_reason <recorded-path> <supervisor-path>
#
# Prints WHY a recorded ARGOCD_KUBECONFIG must be RE-PUBLISHED, or nothing if it should stand.
# Pure: reads two FILES via argocd_api_server(), never a cluster.
#
# Why it exists (B98): 30-vks-login.sh used to publish only when the value was EMPTY, so once any
# value reached .env/.env.state it never published again -- and a path naming a rebuilt lab's
# deleted kubeconfig survived forever. `is_placeholder` cannot help: MEASURED,
# is_placeholder '/nonexistent/stale-lab.kubeconfig' returns NOT-placeholder, so every
# non-destructive publisher in the repo preserves it too.
#
# ⚠️ IT REUSES argocd_api_server() RATHER THAN RE-TYPING THE JSONPATH, and that is load-bearing.
# The first version of this function wrote its own `{.clusters[0].cluster.server}` WITHOUT
# `--minify` -- the FIRST cluster in the file, not the one the current context resolves to. A real
# VKS kubeconfig always holds several (`vcf context create` writes Supervisor contexts INTO the
# existing file and repoints current-context). MEASURED 2026-08-13 on this repo's own
# secrets/cicd-gc4.kubeconfig: un-minified reports the GUEST (…137:6443) while kubectl actually
# dials the SUPERVISOR (…128:443). Both directions were reproduced -- a healthy file declared
# stale, AND a file whose current context is the guest declared healthy, which is the very B98
# failure this function exists to catch. 30-vks-login.sh:499 already records this incident once.
#
# THE PATH IS ABSOLUTIZED against REPO_ROOT first. 31-fetch-argocd-kubeconfig.sh tells operators to
# set a RELATIVE ./secrets/... path, and 30-vks-login.sh never cd's, so a bare `-s` test on a
# relative path answers differently depending on the caller's cwd -- and answering "stale" there
# would CLOBBER a perfectly good operator value. The old emptiness test was cwd-independent, so
# this hazard is one the existence test introduces.
#
# Deliberately conservative: on any UNREADABLE or unparseable file the server read comes back empty
# and this returns NOTHING (keep). A structurally-empty kubeconfig therefore survives here and
# fails later, loudly, at argocd_is_off_cluster's die -- which is the right place for it.
argocd_kubeconfig_stale_reason() {
  local recorded="${1:-}" sup="${2:-}" abs have want
  [ -n "$recorded" ] || { printf 'unset'; return 0; }
  abs="$recorded"
  case "$abs" in /*) : ;; *) abs="${REPO_ROOT:-.}/$abs" ;; esac
  [ -s "$abs" ] || { printf 'stale — %s does not exist (or is empty)' "$recorded"; return 0; }
  have="$(argocd_api_server "$abs")"
  want="$(argocd_api_server "$sup")"
  if [ -n "$have" ] && [ -n "$want" ] && [ "$have" != "$want" ]; then
    printf 'names %s, but this Supervisor is %s' "$have" "$want"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# AUTHENTICATING TO argocd-server, argv-safely. Lifted from 91-e2e-tenant-mechanism.sh:222-264 so
# the e2e and the operator-facing `make argocd-auth-check` cannot drift — B152 measured that NOTHING
# in the certification matrix ever authenticates to ArgoCD, so this was the one credential with no
# coverage anywhere, and F9 hid behind that gap for weeks.
#
# ⚠️ WHY NOT `argocd login`: it offers ONLY `--password <string>`, i.e. the secret in ARGV, which
# security.md forbids (/proc/<pid>/cmdline is world-readable; /proc/<pid>/environ is owner-only).
# MEASURED on argocd v3.0.19+d67e6eb90-vcf: `--password-stdin` does NOT exist (`unknown flag`), and
# it is absent from upstream's docs too — so there is no argv-safe non-interactive password form.
# The session API is the way: body on STDIN via `curl --data @-`, and the CLI driven afterwards by
# ARGOCD_AUTH_TOKEN, which it reads from the ENVIRONMENT.

# argocd_admin_password <kubeconfig> <namespace> — echo the ArgoCD admin password, or nothing.
# stdout is the RETURN VALUE; every diagnostic goes to stderr (os.sh's _log writes to >&2).
_argocd_pw_diag_path() { printf '%s' "${ARGOCD_PW_DIAG:-${TMPDIR:-/tmp}/.argocd-pw-diag.$(id -u)}"; }

# argocd_password_last — read back HOW the last argocd_admin_password call obtained its value.
# Prints "source=secret|env|none rc=N [reason=absent|unreadable|empty]". A FILE, not a global,
# because the caller uses pw="$(argocd_admin_password ...)" — a SUBSHELL, which a global cannot escape.
argocd_password_last() { cat "$(_argocd_pw_diag_path)" 2>/dev/null || true; }

argocd_admin_password() {
  local kc="$1" ns="$2" pw="" out="" rc=0 diag
  diag="$(_argocd_pw_diag_path)"
  # Clear FIRST. A surviving file from a previous run would let the caller name THIS run's cause
  # from the LAST run's evidence — a fresh instance of the very bug this module exists to fix.
  rm -f "$diag" 2>/dev/null || true

  # </dev/null is LOAD-BEARING, not hygiene. With a kubeconfig whose user has no credentials,
  # kubectl PROMPTS — writing "Please enter Username: " to STDOUT — and that text base64-decodes
  # to a few bytes of garbage, which [ -n "$pw" ] happily accepts. The caller then reports a 401
  # as "the credential was rejected" for a Secret it never read. Deny it a stdin and it cannot ask.
  #
  # ⚠️ STDERR GOES TO A FILE, NEVER TO STDOUT. An earlier version used `2>&1` "so the
  # NotFound/Forbidden text survives to be classified" — which merged the DIAGNOSTIC into the
  # PAYLOAD. MEASURED against real kubectl v1.36.3: one server `Warning:` response header (the
  # KEP-1693 mechanism ANY admission webhook or deprecated-API path emits) is concatenated in front
  # of the base64 on a SUCCESSFUL read, `base64 -d` emits partial garbage, `|| true` keeps it, and
  # the value is stamped `source=secret`. The caller then prints "the CREDENTIAL was rejected — the
  # address and the anchor are FINE" about a password that is CORRECT — sending the operator to
  # rotate a working credential, i.e. the exact failure this module exists to remove, reproduced by
  # its own fix. A 15-char password became 5 chars of garbage with kubectl exiting 0.
  local _errf _errtxt=""
  _errf="$(mktemp)" || { printf '%s' "${ARGOCD_ADMIN_PASSWORD:-}"; return 0; }
  out="$(kubectl --kubeconfig "$kc" -n "$ns" get secret argocd-initial-admin-secret \
           -o jsonpath='{.data.password}' </dev/null 2>"$_errf")" || rc=$?
  _errtxt="$(cat "$_errf" 2>/dev/null || true)"; rm -f "$_errf"

  if [ "$rc" -eq 0 ]; then
    case "$out" in
      # The payload must be PURE base64. Anything else means something that is not the secret
      # reached stdout, and a partial decode is worse than no decode: it yields a plausible-looking
      # wrong password that the caller then blames.
      ''|*[!A-Za-z0-9+/=]*) rc=1 ;;
      *) pw="$(printf '%s' "$out" | base64 -d 2>/dev/null || true)" ;;
    esac
  fi

  if [ -n "$pw" ]; then
    ( umask 077; printf 'source=secret rc=0\n' > "$diag" ) 2>/dev/null || true
  elif [ "$rc" -ne 0 ]; then
    # A READ FAILURE and an ABSENT SECRET are different facts with different remedies. Collapsing
    # them is what made the old message prescribe ARGOCD_ADMIN_PASSWORD to an operator whose
    # kubeconfig was simply broken — which would have "passed" the check on a fabricated password.
    # Classify on the DIAGNOSTIC ($_errtxt), never on the payload. And a missing NAMESPACE is NOT
    # an absent Secret: a bare *NotFound* match reported `namespaces "argocd" not found` as
    # "the Secret is ABSENT (the read SUCCEEDED)" — two false claims at once (the read did not
    # succeed; the Secret is not what is missing) — and then prescribed ARGOCD_ADMIN_PASSWORD, the
    # one remedy this check must never offer on an unread path. Highly reachable: ARGOCD_NAMESPACE
    # defaults to `argocd` while on a real VKS lab ArgoCD is a Supervisor Service elsewhere.
    case "$_errtxt" in
      *'namespaces "'*'" not found'*) printf 'source=none rc=%s reason=nons\n'       "$rc" > "$diag" ;;
      *NotFound*secret*|*'secrets "'*'" not found'*)
                                      printf 'source=none rc=%s reason=absent\n'     "$rc" > "$diag" ;;
      *)                              printf 'source=none rc=%s reason=unreadable\n' "$rc" > "$diag" ;;
    esac 2>/dev/null || true
    chmod 0600 "$diag" 2>/dev/null || true
  else
    ( umask 077; printf 'source=none rc=0 reason=empty\n' > "$diag" ) 2>/dev/null || true
  fi

  # The secret is DELETED once an admin rotates the password (upstream behaviour), so an operator
  # override is a legitimate second source, not a fallback for laziness.
  if [ -z "$pw" ] && [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
    pw="${ARGOCD_ADMIN_PASSWORD}"
    ( umask 077; printf 'source=env rc=0\n' > "$diag" ) 2>/dev/null || true
  fi
  printf '%s' "$pw"
}

# argocd_curl_tls_init — set ARGOCD_CURL_TLS (array) and ARGOCD_TLS_MODE from ARGOCD_CA_FILE.
#
# Prefer the CA; fall back to -k only when there is none, and say so LOUDLY. A SILENT --insecure is
# why an entire defect class hid: the trust-anchor path is the one that fails on a real lab, so a leg
# that quietly skips verification reports success about the half that was never exercised.
# An ARRAY, not a string, because a string would word-split a CA path containing a space.
# shellcheck disable=SC2034  # ARGOCD_TLS_MODE is consumed by the scripts that source this library
#                             (argocd-auth-check.sh prints it — the whole point is that a caller
#                             must be able to SAY whether this run verified or not).
argocd_curl_tls_init() {
  if [ -n "${ARGOCD_CA_FILE:-}" ] && [ -s "${ARGOCD_CA_FILE}" ]; then
    ARGOCD_CURL_TLS=(--cacert "${ARGOCD_CA_FILE}"); ARGOCD_TLS_MODE=verified
  else
    ARGOCD_CURL_TLS=(-k); ARGOCD_TLS_MODE=insecure
  fi
}

# argocd_session_token <server> <password> [resolve-host:port:addr] — echo a JWT, or nothing.
#
# The password reaches jq through the ENVIRONMENT and the JSON reaches curl on STDIN, so it is in
# NEITHER argv. ⚠️ Do NOT "simplify" the body to printf '{"password":"%s"}': printf does not escape
# JSON, so a password containing " or \ silently produces a CORRUPT body and a 400 that reads as a
# wrong credential. jq escapes it correctly. (I hand-rolled the printf form first; this is why it
# is not here.)
#
# ARGOCD_SESSION_SCHEME exists ONLY so the offline test can point this at a plain-HTTP stub — the
# curl-gate round's lesson that a check with no way to be tested against a failure class is how the
# failure class ships. It defaults to https and no caller sets it.
# ⚠️ IT USED TO DESTROY EVERY DISCRIMINATOR IT NEEDED, AND THAT MIS-DIRECTED A LIVE DIAGNOSIS
# (certification run row 1, 2026-08-17 — backlog B163). `2>/dev/null || true` plus
# `jq -r '.token // empty'` threw away BOTH curl's exit code AND the HTTP status, so an HTTP 401, an
# HTTP 503 from a LoadBalancer with no ready endpoints, a refused connection (rc 7) and a TLS reject
# all collapsed to the IDENTICAL empty token. The consumer then printed a CLOSED two-item hypothesis
# list ("the ADDRESS ... the ANCHOR") over a signal that cannot distinguish five causes — and on the
# run that mattered, NEITHER listed item was live. A reader followed the list to the wrong file.
#
# The token still goes to STDOUT ALONE, because callers use `tok="$(argocd_session_token ...)"` and
# ANY other stdout would be folded into the return value. The diagnostics therefore travel by FILE:
# a command substitution is a SUBSHELL, so a global assigned in here CANNOT reach the caller — that
# is a rule this repo already learned the hard way. Read them with `argocd_session_last`.
argocd_session_token() {
  # Clear FIRST — symmetric with argocd_admin_password. A write that FAILS (unwritable existing
  # file, full/RO TMPDIR) would otherwise leave the PREVIOUS run's pair to answer for this one.
  # MEASURED on this code: a planted `rc=0 http=200` + an unwritable file turned a genuine
  # CONNECTION REFUSED into "answered 200 but the body carried no token — a response-shape
  # change" — the exact stale-evidence bug this module exists to fix.
  rm -f "$(_argocd_session_diag_path)" 2>/dev/null || true
  local server="$1" pw="$2" resolve="${3:-}" out="" rv=() code="000" rc=0
  [ -n "$resolve" ] && rv=(--resolve "$resolve")
  out="$(ARGOCD_ADMIN_PW="$pw" jq -nc '{username:"admin", password:env.ARGOCD_ADMIN_PW}' \
    | curl -s -w '\n%{http_code}' "${ARGOCD_CURL_TLS[@]}" "${rv[@]}" \
        --max-time "${ARGOCD_SESSION_TIMEOUT:-20}" \
        -H 'Content-Type: application/json' --data @- \
        "${ARGOCD_SESSION_SCHEME:-https}://${server}/api/v1/session" 2>/dev/null)" || rc=$?
  # -w appends the code on its own LAST line; strip it back off before parsing the body.
  code="$(printf '%s' "$out" | tail -n1)"
  case "$code" in ''|*[!0-9]*) code="000" ;; esac
  out="$(printf '%s' "$out" | sed '$d')"
  ( umask 077; printf 'rc=%s http=%s\n' "$rc" "$code" > "$(_argocd_session_diag_path)" ) 2>/dev/null || true
  printf '%s' "$(printf '%s' "$out" | jq -r '.token // empty' 2>/dev/null || true)"
}

# Where argocd_session_token leaves its diagnostics. A FILE, not a global — see the ⚠️ above.
_argocd_session_diag_path() {
  printf '%s' "${ARGOCD_SESSION_DIAG:-${TMPDIR:-/tmp}/.argocd-session-diag.$(id -u)}"
}

# argocd_session_last — echo `rc=<n> http=<code>` from the most recent argocd_session_token call in
# this process tree, or `rc= http=` when there is none. Never fails; it is a diagnostic, not a gate.
argocd_session_last() {
  local f; f="$(_argocd_session_diag_path)"
  if [ -s "$f" ]; then cat "$f"; else printf 'rc= http=\n'; fi
}

# argocd_session_explain <rc> <http> — turn the pair into ONE named cause, or empty when the pair
# does not determine one. This is what replaces the closed two-item list: the check may only offer
# "next steps" for causes it has NOT already named.
argocd_session_explain() {
  local rc="${1:-}" code="${2:-}" pwsrc="${3:-}"
  # TRANSPORT IS TESTED FIRST, and the order is the fix. curl can emit a status line and THEN fail:
  # a server that sends 200 headers and stalls yields rc=28 http=200, which the status-first order
  # reported as "a response-shape change" — sending the reader to the API format for a TIMEOUT.
  # A preserved exit status outranks a status line that merely arrived before the failure.
  case "$rc" in
    7)  printf 'the CONNECTION WAS REFUSED (curl 7) — nothing is listening yet. Neither the address nor the anchor was consulted'; return 0 ;;
    6)  printf 'the HOST DID NOT RESOLVE (curl 6) — a DNS fault, not TLS'; return 0 ;;
    60) printf 'TLS VERIFICATION FAILED (curl 60) — THIS is the address-or-anchor case'; return 0 ;;
    35) printf 'the TLS HANDSHAKE FAILED (curl 35) — a protocol/cipher fault, not a name or a CA'; return 0 ;;
    # 52/56 are the documented K1.5 symptom — the LoadBalancer has an IP but its proxy is not wired
    # yet, so the peer accepts the connection and drops it. Omitting them sent exactly this failure
    # to the ADDRESS/ANCHOR candidate list, which is the defect this module exists to remove.
    52|56) printf 'the connection was RESET or closed by the peer with no reply (curl %s) — a half-wired LoadBalancer, NOT a name or a CA. This is the documented K1.5 race' "$rc"; return 0 ;;
    28) printf 'the request TIMED OUT (curl 28) — the peer accepted nothing in time'; return 0 ;;
  esac
  case "$code" in
    401|403)
      # A 401 only means "the credential was rejected" if a credential was actually READ. With an
      # unreadable Secret the check can hold a garbage value and would otherwise exonerate the two
      # things it never tested.
      case "$pwsrc" in
        secret|env) printf 'the CREDENTIAL was rejected by argocd-server (HTTP %s) — the address and the anchor are FINE' "$code" ;;
        *)          printf 'argocd-server answered HTTP %s, but the password did NOT come from a known source (%s) — do NOT read this as "the credential is wrong"; establish where the password came from first' "$code" "${pwsrc:-unknown}" ;;
      esac
      return 0 ;;
    502|503|504) printf 'argocd-server did NOT serve the request (HTTP %s) — reachable, but no ready backend yet. This is the LoadBalancer race, not a credential or trust fault' "$code"; return 0 ;;
    200) printf 'argocd-server answered 200 but the body carried no token — a response-shape change, not an address/anchor fault'; return 0 ;;
    ''|000) : ;;
    # Any other status still settles the two things the candidate list would have asked about:
    # the server answered, so the name resolved and the anchor verified.
    *) printf 'argocd-server ANSWERED (HTTP %s), so the ADDRESS and the ANCHOR are both FINE — but the reply carried no token' "$code"; return 0 ;;
  esac
  return 1
}


# argocd_await_revision <app> — wait for an Application to report a fetched revision, and
# DISTINGUISH the ways that can fail. Lives here, not inline in 70-configure-argocd.sh, so a
# test can drive it with a stub `ka`: the diagnostic it replaced survived precisely because it
# was buried mid-script where nothing could exercise it.
argocd_await_revision() {
  local app="$1" _rd_err="" _ce_err="" _an_err="" _rd_rc=0 _ce_rc=0 _an_rc=0 rev="" _attempts _cond
  local _ns="${ARGOCD_NAMESPACE:-<unset>}" _api="${ARGOCD_API:-<unknown>}"
  local _kc="${ARGOCD_KUBECONFIG:-${KUBECONFIG:-<unset>}}"
  local _url="${GITEA_ARGOCD_URL:-<unset>}" _org="${GITEA_ORG:-<unset>}"
  local _pre_rev="" _pre_rec="" _rec="" _tried=0 _fresh=0 _rec_rc=0 _cerr="" _sst=""
  local _ff_err="" _ff_state=unknown

  # Validate BEFORE the `:-` default, or an EMPTY value silently takes the default and the guard's
  # own '' arm is unreachable — while empty was the OLD code's actual trigger (`seq 1 ""` = zero
  # iterations). Measured: the guard advertised protection for the one input it could not see.
  case "${ARGOCD_REPO_TIMEOUT_SECONDS-180}" in
    ''|*[!0-9]*|0) die "ARGOCD_REPO_TIMEOUT_SECONDS must be a positive integer (got '${ARGOCD_REPO_TIMEOUT_SECONDS-}')" ;;
  esac
  _attempts="${ARGOCD_REPO_TIMEOUT_SECONDS:-180}"

  _rd_err="$(mktemp)" || die "could not create a temp file for kubectl's stderr (TMPDIR=${TMPDIR:-/tmp} full or read-only?)"
  _ce_err="$(mktemp)" || { rm -f "$_rd_err"; die "could not create a temp file (TMPDIR=${TMPDIR:-/tmp})"; }
  _an_err="$(mktemp)" || { rm -f "$_rd_err" "$_ce_err"; die "could not create a temp file (TMPDIR=${TMPDIR:-/tmp})"; }
  _ff_err="$(mktemp)" || { rm -f "$_rd_err" "$_ce_err" "$_an_err"; die "could not create a temp file (TMPDIR=${TMPDIR:-/tmp})"; }
  # EXIT as well as RETURN: `die` is `exit 1` (lib/os.sh), and a RETURN trap does NOT fire on exit —
  # measured, the temp files survived. The previous comment claimed RETURN "covers every exit path
  # including the die's", which was false.
  # RETURN ONLY. `trap ... EXIT` here REPLACED the caller's EXIT trap — bash has ONE per shell —
  # so 70-configure-argocd.sh's WORK_DIR cleanup silently stopped running and every successful
  # `make gitops` leaked a mktemp -d plus its own captures, ending with an unbound-variable error
  # because the trap body referenced locals that were out of scope by then. MEASURED. `die` is
  # `exit 1`, which a RETURN trap does not catch, so each die does its own rm -f explicitly.
  trap 'rm -f "$_rd_err" "$_ce_err" "$_an_err" "$_ff_err"' RETURN
  _await_cleanup() { rm -f "$_rd_err" "$_ce_err" "$_an_err" "$_ff_err" 2>/dev/null || true; }

  _await_read() {
    _rd_rc=0
    rev="$(ka -n "$_ns" get application "$app" -o jsonpath='{.status.sync.revision}' 2>"$_rd_err")" || _rd_rc=$?
  }
  # Capture rc like the other reads. With `2>/dev/null || true` a silently-FAILED pre-read set
  # _pre_rec="" and then ANY value "advanced" — measured printing an eight-month-old timestamp as a
  # fresh reconcile. An unreadable value is UNKNOWN, never "".
  _await_reconciled() {
    _rec_rc=0
    _rec="$(ka -n "$_ns" get application "$app" -o jsonpath='{.status.reconciledAt}' 2>"$_ce_err")" || _rec_rc=$?
  }
  # THE FETCH-SUCCESS SIGNAL. reconciledAt answers "did it reconcile"; this answers "did the FETCH
  # succeed", and only the two together mean anything — see the block above the loop.
  # ⚠️ THIS SETS A NAMED STATE AND ALWAYS RETURNS 0 — it does NOT encode the verdict in its exit
  # code, and that is load-bearing, not style. This file has NO `set` line of its own: it inherits
  # the caller, and scripts/70-configure-argocd.sh:21 is `set -euo pipefail`, so `set -e` is LIVE.
  # A tri-state-by-exit-code predicate called BARE (`f; st=$?`) would trip `set -e` on the arm that
  # returns non-zero — which for "fetch OK" is the HEALTHY path, so the run would die on the first
  # iteration of a good gitops flow, silently. MEASURED under real `set -euo pipefail`.
  #
  # The previous form read both signals with `2>/dev/null || true`, so a silently-FAILED read gave
  # two empty strings, the predicate was FALSE, `! _await_fetch_failed` was TRUE, and the freshness
  # gate PASSED — a false green inside the gate that exists to prevent false greens. REPRODUCED
  # against the real function with a Forbidden-returning stub: it printed "the repo is reachable
  # NOW" and exited 0. So the reads capture rc per command, and an unreadable signal is `unknown`,
  # never silently "not failed". (Same lesson as _await_reconciled 15 lines up, which already had it.)
  #
  # `unknown` is a NAME, not the exit code 2, deliberately: a future `if _await_fetch_state; then`
  # would map rc=2 to the else-arm and restore exactly this false green, whereas an unset/misspelled
  # name errors loudly under `set -u`. Out-params are also this function's own convention
  # (_rd_rc/_rec_rc/_ce_rc).
  _await_fetch_state() {                      # sets _ff_state=ok|failed|unknown; ALWAYS returns 0
    local r1=0 r2=0
    _cerr="$(ka -n "$_ns" get application "$app" \
      -o jsonpath='{range .status.conditions[?(@.type=="ComparisonError")]}{.message}{end}' 2>"$_ff_err")" || r1=$?
    _sst="$(ka -n "$_ns" get application "$app" -o jsonpath='{.status.sync.status}' 2>"$_ff_err")" || r2=$?
    if   [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ];       then _ff_state=unknown
    elif [ -n "$_cerr" ] || [ "$_sst" = Unknown ]; then _ff_state=failed
    else                                                _ff_state=ok
    fi
    return 0
  }
  _await_read_failed() {
    log_error "could not READ Application '${app}' — this says NOTHING about whether the repo is reachable."
    log_error "  namespace : ${_ns}   API server: ${_api}"
    log_error "  kubeconfig: ${_kc}"
    log_error "  kubectl said:"
    sed 's/^/    /' "$_rd_err" >&2 2>/dev/null || true
  }

  _await_read
  if [ "$_rd_rc" -ne 0 ]; then
    _await_read_failed
    _await_cleanup; die "cannot read Applications in '${_ns}' — check the namespace, the kubeconfig, and whether the Application CRD is served there."
  fi
  # ⚠️ PRESENCE IS NOT FRESHNESS, AND THIS IS THE WHOLE POINT OF THE CHECK. Both apply paths are
  # UPSERT, so `.status.sync.revision` PERSISTS across runs. An earlier version removed a
  # short-circuit but kept testing PRESENCE, so it still exited 0 printing "the repo is reachable"
  # with a STALE revision and GITEA_ARGOCD_URL pointed at a host that does not exist — MEASURED,
  # zero repo contact. `.env.example` calls this "the gate that proves ArgoCD's repo-server can
  # reach GITEA_ARGOCD_URL — a wrong URL used to sync green forever", so presence cannot satisfy it.
  # We therefore record what was there BEFORE and demand evidence of a NEW reconcile.
  _pre_rev="$rev"; _await_reconciled; _pre_rec="$_rec"

  # THE REFRESH IS A GATE, NOT FIRE-AND-FORGET. It used to be `>/dev/null 2>&1 || true` — the one
  # call whose failure makes everything after it meaningless. MEASURED: with a get-but-not-patch
  # tenant RBAC (the scenario-2 shape) the annotate returned Forbidden, the run printed
  # "re-probing anyway (a stale revision is not proof)" — an affirmative falsehood — and then
  # declared the repo reachable, rc=0, never mentioning the refusal.
  _an_rc=0
  ka -n "$_ns" annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>"$_an_err" || _an_rc=$?
  if [ "$_an_rc" -ne 0 ]; then
    log_error "could not force a refresh of Application '${app}' — so NOTHING below can prove the repo is reachable."
    log_error "  namespace: ${_ns}   API server: ${_api}"
    log_error "  kubectl said:"
    sed 's/^/    /' "$_an_err" >&2 2>/dev/null || true
    log_error "  A tenant with get-but-not-patch on applications hits exactly this; it is an RBAC fault, not a repo fault."
    _await_cleanup; die "cannot refresh Application '${app}' — refusing to report a reachability result we did not obtain."
  fi

  # Wait for a NEW reconcile: reconciledAt must ADVANCE past what it was before the refresh. That is
  # the evidence a fetch actually happened; a revision that merely EXISTS proves only that some
  # earlier run succeeded. (The ideal oracle is the SHA this flow just pushed, but the seeding step
  # does not publish it to this script — recorded so the better fix is not re-derived from scratch.)
  while [ "$_tried" -lt "$_attempts" ]; do
    _tried=$(( _tried + 1 ))
    sleep 1
    _await_read
    if [ "$_rd_rc" -ne 0 ]; then
      log_error "the read of Application '${app}' started FAILING mid-wait (it succeeded moments ago):"
      _await_read_failed
      _await_cleanup; die "lost access to Applications in '${_ns}' while waiting — not a repo fault."
    fi
    _await_reconciled
    # ⚠️ reconciledAt ADVANCING IS NOT PROOF OF A FETCH, and the reason is that WE forced the
    # refresh. In argo-cd v3.5.1 (our pin) ANY refresh annotation selects
    # CompareWithLatestForceResolve — "Level 3" — which sets noRevisionCache=true, and
    # state.go:700-712 gates BOTH `return nil, ErrCompareStateRepo` short-circuits on
    # `&& !noRevisionCache` (its own comment: "and it's not a Level 3 comparison"). So a repo error
    # FALLS THROUGH, appcontroller.go:1973-1974 sets ReconciledAt = now, and state.go:653-655 has
    # ALREADY set syncStatus.Revision to the TARGET REVISION — the branch name — before any fetch.
    # MEASURED: against `this-host-does-not-exist.invalid` this check printed "re-reconciled ...
    # reports revision main — the repo is reachable NOW", rc=0. For a LEVEL-2 (timer) refresh the
    # oracle would be sound; our own forced refresh switches the protection off.
    # So freshness needs BOTH: it reconciled (reconciledAt advanced) AND the fetch succeeded
    # (no ComparisonError, sync.status != Unknown). Neither alone is sufficient.
    _await_fetch_state
    if [ -n "$rev" ] && [ "$_rec_rc" -eq 0 ] && [ -n "$_rec" ] && [ "$_rec" != "$_pre_rec" ] \
       && [ "$_ff_state" = ok ]; then _fresh=1; break; fi
  done

  if [ "$_fresh" -ne 1 ]; then
    # DISTINGUISH the two failures. Resetting _rec inside the loop destroyed exactly the value
    # needed to tell them apart, so a STALE revision was reported as an EMPTY one — the wrong
    # diagnosis, in the check whose entire purpose is not to give the wrong diagnosis.
    # RECOMPUTE rather than reuse the loop's value: this helper re-reads, so a stale _ff_state
    # would report a signal from a previous iteration.
    _await_fetch_state
    if [ "$_ff_state" = unknown ]; then
      # A READ FAULT IS NOT EVIDENCE ABOUT THE REPO. This arm deliberately precedes the others: an
      # unreadable signal masks the "did NOT re-reconcile" diagnosis, which is correct — we cannot
      # claim an Application state we failed to read. Nothing here mentions the repo.
      log_error "could not READ the fetch signal for Application '${app}' (${_tried} attempts) —"
      log_error "  so this run obtained NO evidence either way about the repo. kubectl said:"
      sed 's/^/    /' "$_ff_err" >&2 2>/dev/null || true
    elif [ "$_rec_rc" -ne 0 ]; then
      # Same class, one line away, and it was unreported: _rec_rc was captured but never surfaced,
      # so a FAILED reconciledAt read was mislabelled "reconciledAt never advanced past <none>" —
      # an Application-state claim manufactured from a read fault.
      log_error "could not READ reconciledAt for Application '${app}' (${_tried} attempts) —"
      log_error "  that is a READ fault, not evidence the Application failed to reconcile. kubectl said:"
      sed 's/^/    /' "$_ce_err" >&2 2>/dev/null || true
    elif [ "$_ff_state" = failed ]; then
      log_error "Application '${app}' RECONCILED but the FETCH FAILED (${_tried} attempts)."
      log_error "  sync.status=${_sst:-<none>}   ComparisonError: ${_cerr:-<none>}"
      log_error "  reconciledAt DID advance, which on a forced refresh proves only that a comparison ran —"
      log_error "  argo-cd disables its repo-error short-circuit for a forced (Level 3) refresh, so the"
      log_error "  timestamp advances even when the repo could not be read. THIS is the fetch signal."
    elif [ -n "$rev" ]; then
      log_error "Application '${app}' did NOT re-reconcile after a forced refresh (${_tried} attempts)."
      log_error "  It still carries revision ${_pre_rev} from an EARLIER run, and reconciledAt never advanced"
      log_error "  past ${_pre_rec:-<none>} — so this run obtained NO evidence the repo is reachable now."
    else
      log_error "Application '${app}' reported an EMPTY revision on all ${_tried} attempts."
      log_error "  The reads SUCCEEDED, so this is the Application's real state — not an access fault."
    fi
    log_error "  namespace: ${_ns}   API server: ${_api}"
    log_error "  Its own conditions:"
    _ce_rc=0
    _cond="$(ka -n "$_ns" get application "$app" \
      -o jsonpath='{range .status.conditions[*]}    [{.type}] {.message}{"\n"}{end}' 2>"$_ce_err")" || _ce_rc=$?
    if [ "$_ce_rc" -ne 0 ]; then
      log_error "    could not read the conditions — a READ fault, not evidence about the repo. kubectl said:"
      sed 's/^/      /' "$_ce_err" >&2 2>/dev/null || true
    elif [ -n "$_cond" ]; then
      printf '%s\n' "$_cond" >&2
    else
      log_error "    (none — the Application reports NO conditions, so it is not complaining about the repo either)"
    fi
    # ⚠️ ONLY offer the repo-server probe when we actually READ the Application's state. On a READ
    # fault we do not know whether it reconciled, let alone whether the repo is implicated, so
    # sending the operator to curl Gitea is the same misdirection this whole check exists to stop —
    # and it would be the ONE line in the read-fault arm that names the repo.
    if [ "$_ff_state" != unknown ] && [ "$_rec_rc" -eq 0 ]; then
      log_error "  A repo it cannot clone is ONE candidate; confirm it rather than assume it, from the repo-server itself:"
      log_error "    kubectl -n ${_ns} exec deploy/argocd-repo-server -c repo-server -- \\"
      log_error "      curl -s -o /dev/null -w '%{http_code}\\n' '${_url}/${_org}/${app}-deploy.git/info/refs?service=git-upload-pack'"
      log_error "    200 => the repo IS reachable and the cause is elsewhere; anything else => GITEA_ARGOCD_URL is the fault."
    fi
    _await_cleanup; die "ArgoCD produced no FRESH fetch — refusing to report success."
  fi
  log_info "  ${app}: ArgoCD re-reconciled after a forced refresh (reconciledAt ${_pre_rec:-<none>} -> ${_rec}) and reports revision ${rev} — the repo is reachable NOW"
}

# ---------------------------------------------------------------------------
# argocd_app_fetch_verdict — did ArgoCD ACTUALLY fetch this app's repo, just now?
#
# The TENANT (MECH=api) counterpart to argocd_await_revision. It lives here, not inline in
# 70-configure-argocd.sh, for the reason stated at the top of that function: a diagnostic buried
# mid-script is one nothing can exercise, and this branch has never executed in ANY recorded walk
# run (measured: 0 hits across the 158 logs in /tmp/walk), so a test is the ONLY thing that will
# ever have exercised it before a lab does.
#
# WHY NOT `argocd app wait --sync`, which is what this replaces. With `--sync` alone the CLI's
# predicate reduces to `sync.status == Synced` (v3.0.19 checkResourceStatus: healthCheckPassed
# initialises true and no case matches; `operational := !watch.operation` is true), and it requests
# NO refresh (`waitOnApplicationStatus`: `refresh := false`). Both apply paths UPSERT, so `Synced`
# PERSISTS. Inside argo-cd's repo-error grace period — `defaultAppResyncPeriod + jitter` = 120+60 =
# 180s — appcontroller.go returns `processNext` on ErrCompareStateRepo and persists NOTHING, so
# `sync.status` stays `Synced` and `reconciledAt` stays frozen: the wait returns in under a second
# and reports success having made no repo contact. `make gitops` runs inside that window.
#
# ⚠️ WHAT THIS DOES **NOT** FIX, because it never happened: an idea round measured that a WRONG
# repo URL cannot "sync green forever" — a changed URL makes the controller take
# `!currentSourceEqualsSyncedSource(app)` -> CompareWithLatestForceResolve (Level 3) ->
# `noRevisionCache=true`, which DISABLES that short-circuit, so the error falls through and the wait
# correctly fails. A day-old outage is likewise `Unknown` once the 180s grace expires. The gap this
# closes is ONLY the spec-identical re-run inside the window.
#
#   --refresh, NOT --hard-refresh: ANY refresh selects Level 3, so soft already kills the
#     short-circuit and re-resolves the revision remotely. Hard additionally issues a per-app
#     GetAppDetails{NoCache:true} whose failure is only log.Warnf'ed server-side — more cost, no
#     more proof.
#   NO reconciledAt comparison: `Get` with `Refresh` BLOCKS until the controller clears the refresh
#     annotation, and that annotation is deleted in the SAME patch that persists the new status
#     (persistReconciliationStatus). The returned JSON is therefore structurally post-reconcile —
#     there is nothing to poll and no pre-reading to compare against.
#   `timeout` is MANDATORY: `argocd app get` has NO --timeout flag (v3.0.19 offers only
#     --output/--show-operation/--refresh/--hard-refresh) and the server-side wait exits only on
#     ctx.Done(), so a missing/booting controller HANGS it. This repo documents that state.
#   RBAC: this needs `applications, get` ONLY — no action/, no override, no update — and RefreshApp
#     patches the annotation with argocd-server's OWN ServiceAccount, so it needs zero tenant
#     Kubernetes RBAC. It works precisely where argocd_await_revision's `ka annotate` is Forbidden.
#
# Sets, and ALWAYS returns 0 (an out-param, not an exit code: this file has no `set` line of its own
# and inherits `set -euo pipefail` from its caller, so a non-zero return from a bare call would trip
# errexit — measured on the sibling _await_fetch_state):
#   _afv_state = ok | repo | notrepo | unknown | cli | parse
#   _afv_msg   = the ComparisonError message, when there is one
#   _afv_err   = path to the CLI's stderr capture (caller classifies + removes it)
argocd_app_fetch_verdict() {
  local app="$1" _rc=0 _json="" _tmo="${ARGOCD_REPO_TIMEOUT_SECONDS:-180}"
  _afv_state=unknown; _afv_msg=""
  _afv_err="$(mktemp)" || { _afv_state=cli; _afv_msg="could not create a temp file (TMPDIR=${TMPDIR:-/tmp})"; return 0; }

  _json="$(timeout "$_tmo" argocd app get "$app" --refresh -o json 2>"$_afv_err")" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    # 124 is timeout(1)'s own code. Name it, because "the controller is not running" and "the CLI
    # was rejected" have different remedies and the caller's transport classifier sees only stderr.
    [ "$_rc" -eq 124 ] && _afv_msg="argocd app get did not return within ${_tmo}s (no --timeout flag exists; a missing or booting application-controller hangs it)"
    _afv_state=cli
    return 0
  fi

  # jq's rc is CAPTURED, never `|| true`. With `|| true` a missing jq yields an empty string, the
  # prefix test finds nothing, and this function would AFFIRM that the repo is fine — a positive
  # claim manufactured by an absent tool. That is the recorded gitea_hook_ids incident (lib/os.sh),
  # one file over, and it would be strictly worse than the hedge this replaces.
  local _cerr _sst _jrc=0
  _cerr="$(printf '%s' "$_json" | jq -r '[.status.conditions[]? | select(.type=="ComparisonError") | .message] | join("; ")')" || _jrc=$?
  _sst="$(printf '%s' "$_json" | jq -r '.status.sync.status // ""')" || _jrc=$?
  if [ "$_jrc" -ne 0 ]; then
    _afv_state=parse
    _afv_msg="could not parse argocd's JSON (is jq present and did the CLI emit JSON?)"
    return 0
  fi

  # PREFIX, not the condition TYPE. ComparisonError is appended by argo-cd at ELEVEN call sites
  # covering SEVEN causes, and only ONE is the repo: state.go's `"Failed to load target state: "`
  # (GetRepoObjs). Another — `"Failed to load live state: "` — is the DESTINATION CLUSTER, which on
  # this very path is a registered guest reached by a bearer token, i.e. a first-class candidate.
  # Matching the bare type would blame Gitea for an expired guest credential: the B137/B172 class.
  if [ -n "$_cerr" ]; then
    _afv_msg="$_cerr"
    case "$_cerr" in
      "Failed to load target state: "*) _afv_state=repo ;;
      *)                                _afv_state=notrepo ;;
    esac
  elif [ "$_sst" = Unknown ]; then
    # Unknown with NO condition: the controller never produced a comparison at all (an
    # InvalidSpecError, or an Application it has not yet touched). A third remedy again.
    _afv_state=unknown; _afv_msg="sync.status=Unknown with no ComparisonError — the controller has not judged this Application"
  else
    _afv_state=ok; _afv_msg="$_sst"
  fi
  return 0
}
