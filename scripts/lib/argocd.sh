#!/usr/bin/env bash
# scripts/lib/argocd.sh — the two-cluster facts about ArgoCD, as PURE functions.
#
# ArgoCD is a VCF Supervisor Service: on a real lab it runs in a DIFFERENT cluster from the workload.
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
  elif [ "$count" = 1 ];    then printf '%s' "$only_s";    return 0
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
