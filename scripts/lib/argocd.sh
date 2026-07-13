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
