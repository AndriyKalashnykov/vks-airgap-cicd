#!/usr/bin/env bash
# doc-walk.sh — execute docs/scenario-1.md LITERALLY, in a brand-new standalone container.
#
# Every command below is copied verbatim from the document (the extractor at /tmp/extract-doc-cmds.py
# lists all 77). Nothing is paraphrased, nothing is "helpfully" reordered, and no command the doc
# does not contain is run — except the OS-package line the doc gives per-distro and the .env edit the
# doc describes in a TABLE rather than a code block.
#
# WALK_OS      photon | ubuntu
# WALK_EXISTS  0 = namespace/Harbor/ArgoCD do NOT exist (create them)
#              1 = they already exist (the "already installed" branch)
#
# It counts failures and exits on the count, so the harness cannot report a pass over a red walk.
set -u

# docs/scenario-1.md §0: "Prefix with `sudo` if you are not root." A container runs as root; a real
# jump-box VM does not, so the driver must honour the doc's own instruction rather than assume root.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
HOMEDIR="${HOME:-/root}"
WALK_OS="${WALK_OS:-photon}"
WALK_EXISTS="${WALK_EXISTS:-0}"
FAILED=0
STEP=0

step() {   # step "<doc section>" "<the command, verbatim>"
  STEP=$((STEP + 1))
  printf '\n\033[1m=== [%02d] %s\033[0m\n$ %s\n' "$STEP" "$1" "$2"
  local t0 rc
  t0=$(date +%s)
  bash -c "$2"
  rc=$?
  printf '\033[1m--- [%02d] rc=%d (%ds)\033[0m\n' "$STEP" "$rc" "$(( $(date +%s) - t0 ))"
  [ "$rc" -eq 0 ] || FAILED=$((FAILED + 1))
  return 0
}

setenv() {  # setenv "<doc section>" KEY=VAL ...
  printf '\n\033[36m### %s: operator sets in ./.env: %s\033[0m\n' "$1" "${*:2}"
  shift; for kv in "$@"; do printf '%s\n' "$kv" >> .env; done
}

note() { printf '\n\033[36m### %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 0. Get the repo
if [ "$WALK_OS" = ubuntu ]; then
  step "0. Get the repo" "$SUDO apt-get update && $SUDO apt-get install -y --no-install-recommends git make curl ca-certificates"
else
# curl MUST be in the SAME transaction as git: tdnf pulls git from photon-updates linked against
# a newer libcurl while the image keeps curl-libs 8.0.1, and git-remote-https then dies with
# `undefined symbol: curl_global_trace`. MEASURED on a fresh Photon 5.0 GCE image 2026-08-11.
  step "0. Get the repo" "$SUDO tdnf install -y git make curl curl-libs ca-certificates"
fi
cd "$HOMEDIR" || exit 1
step "0. Get the repo" "git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git"
cd "$HOMEDIR/vks-airgap-cicd" || { echo "CLONE FAILED — cannot continue"; exit 99; }
step "0. Get the repo" "pwd"
step "0. Get the repo" "make env-init"

# The doc gives these as a TABLE ("set in ./.env before you run the commands below"), not a block.
# This is the operator editing .env. VCF_CLI_VSPHERE_PASSWORD arrives by env-var NAME, never argv.
note "operator edits ./.env with the Step-1 table AND the Step-1b table values"
{
  # Step 1's table (docs/scenario-1.md:125-137)
  echo "VCF_CLI_SRC_DIR=/vcf"
  echo "SUPERVISOR_HOST=${SUPERVISOR_HOST}"
  echo "VKS_CONTEXT_NAME=${VKS_CONTEXT_NAME}"
  echo "VKS_NAMESPACE=${VKS_NAMESPACE}"
  echo "VKS_CLUSTER_NAME=${VKS_CLUSTER_NAME}"
  echo "VKS_USERNAME=${VKS_USERNAME}"
  echo "VKS_SSO_DOMAIN=${VKS_SSO_DOMAIN}"
  # Step 1b's OWN table (docs/scenario-1.md:167-174), which a reader following the doc linearly
  # fills in before running `make vsphere-namespace`. The first version of this driver wrote only
  # Step 1's table and then reported the resulting `VCENTER_HOST is not set` as a DOC defect. It was
  # a HARNESS defect: the doc documents all four, immediately above the command that needs them.
  echo "VCENTER_HOST=${VCENTER_HOST}"
  echo "VCENTER_USERNAME=${VCENTER_USERNAME}"
  echo "VCENTER_PASSWORD=${VCENTER_PASSWORD}"
  echo "VKS_STORAGE_POLICY=${VKS_STORAGE_POLICY:-}"
} >> .env
grep -E '^(VCF_CLI_SRC_DIR|SUPERVISOR_HOST|VKS_)' .env | sed 's/^/  /'

# ---------------------------------------------------------------- 1. Jump box
step "1. Jump box" "make deps"
step "1. Jump box" "make install-vcf-clis"
step "1. Jump box" "make check-tools"
step "1. Jump box" "make shell-init"
# docs/scenario-1.md §1, the line right below `make shell-init`. step() runs each command in a new
# non-interactive, non-login bash, which reads NEITHER ~/.bashrc (interactive-only) NOR ~/.profile
# (login-only) — so without this the walk cannot model the operator's one continuous shell, and
# every raw kubectl/vcf command below false-fails with rc=127.
note "1: operator runs the doc's second PATH line in THIS shell"
export PATH="$HOME/.local/bin:$PATH"
printf '  PATH now begins: %s\n' "${PATH%%:*}"

# ---------------------------------------------------------------- 1b. The vSphere Namespace
if [ "$WALK_EXISTS" = 1 ]; then
  note "2: the namespace ALREADY EXISTS — the doc says put its name in VKS_NAMESPACE and check it"
else
  step "2. vSphere Namespace" "make vsphere-namespace"
fi

# ---------------------------------------------------------------- 3. Log in to the Supervisor
# The doc puts this BEFORE Harbor (reordered 2026-08-11): everything after it reads
# ./secrets/supervisor.kubeconfig, so doing it first removes three forward references and the
# "run make install-argocd-service twice" workaround.
step "3. Log in" "make fetch-supervisor-ca"
step "3. Log in" "set -a; . ./.env; set +a; vcf context create \"\$VKS_CONTEXT_NAME\" --endpoint \"\$SUPERVISOR_HOST\" --ca-certificate ./secrets/supervisor-ca.crt --username \"\$VKS_USERNAME\" --type kubernetes --auth-type basic"
# DIAGNOSTIC (not in the doc): when `vcf context use <ctx>:<ns>` says "not found", the first thing
# an operator needs is what contexts DO exist. If the doc's colon form is wrong, this shows it.
step "5. ArgoCD (diag)" "vcf context list"
step "3. Log in" "set -a; . ./.env; set +a; vcf context use \"\$VKS_CONTEXT_NAME:\$VKS_NAMESPACE\""
if [ "$WALK_EXISTS" = 1 ]; then
  note "5: ArgoCD ALREADY EXISTS — the doc says find its namespace and set the 4 values"
else
  step "3. Log in" "make install-argocd-service"
fi
# §3.6, verbatim. ARGOCD_NAMESPACE is DISCOVERED, not assumed — §3's table: "Discover it — do not
# assume: kubectl get argocd -A".
step "3. Log in" "export KUBECONFIG=./secrets/supervisor.kubeconfig; kubectl get argocd -A"
step "3. Log in" "export KUBECONFIG=./secrets/supervisor.kubeconfig; kubectl get svc -n \"\$ARGOCD_NAMESPACE\" | head -5"
step "3. Log in" "export KUBECONFIG=./secrets/supervisor.kubeconfig; kubectl get secret -n \"\$ARGOCD_NAMESPACE\" argocd-initial-admin-secret -o jsonpath='{.data.password}' >/dev/null && echo 'initial admin secret present'"
step "3. Log in" "make vks-login"
step "3. Log in" "export KUBECONFIG=./secrets/supervisor.kubeconfig; kubectl -n \"\$VKS_NAMESPACE\" get storagepolicyquotas"
step "3. Log in" "export KUBECONFIG=./secrets/supervisor.kubeconfig; kubectl -n \"\$VKS_NAMESPACE\" get virtualmachineclass"

# ---------------------------------------------------------------- 4. Harbor
setenv "4. Harbor" "HARBOR_URL=${HARBOR_URL}" "HARBOR_STORAGE_CLASS=${HARBOR_STORAGE_CLASS}"
# §2's table, the two rows marked "only if you SKIPPED the install" — this walk takes that branch.
if [ "$WALK_EXISTS" = 1 ]; then
  setenv "4. Harbor" "HARBOR_USERNAME=${HARBOR_USERNAME:-admin}" "HARBOR_PASSWORD=${HARBOR_PASSWORD:-}"
fi
if [ "$WALK_EXISTS" = 1 ]; then
  note "4: Harbor ALREADY EXISTS — the doc says set HARBOR_URL and skip the install"
else
  step "4. Harbor" "make install-harbor-service"
fi
step "4. Harbor" "make show-dns-records"

# ---------------------------------------------------------------- 3. ArgoCD
# §3's table is ARGOCD_NAMESPACE + VKS_AUTH_METHOD. On the EXISTS branch the doc tells the reader
# to find ArgoCD's namespace and set it; MEASURED on this lab it is the vSphere namespace (`cicd`),
# NOT the svc-argocd-service-* package namespace — argocd-server's LB lives in `cicd`.
setenv "5. ArgoCD" "VKS_AUTH_METHOD=${VKS_AUTH_METHOD:-vcf}" "ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE:-}"


# ---------------------------------------------------------------- 4. Guest cluster
setenv "6. Guest cluster" "VKS_VM_CLASS=${VKS_VM_CLASS:-best-effort-small}" "VKS_STORAGE_CLASS=${VKS_STORAGE_CLASS:-wcp-vmfs}" "VKS_CONTROL_PLANE_COUNT=${VKS_CONTROL_PLANE_COUNT:-1}" "VKS_NODE_COUNT=${VKS_NODE_COUNT:-2}"
if [ "${WALK_SKIP_CLUSTER:-$WALK_EXISTS}" = 1 ]; then
  note "6: guest cluster ALREADY EXISTS — skipping create, reading its status"
else
  step "6. Guest cluster" "make vks-cluster-create"
fi
step "6. Guest cluster" "make vks-cluster-status"
step "6. Guest cluster" "make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=${WALK_CLUSTER_WAIT:-1800}"
setenv "6. Guest cluster" "KUBECONFIG=./secrets/${VKS_CLUSTER_NAME}.kubeconfig" "VKS_AUTH_METHOD=kubeconfig"
step "6. Guest cluster" "set -a; . ./.env; set +a; kubectl --kubeconfig \"./secrets/\${VKS_CLUSTER_NAME}.kubeconfig\" get nodes -o wide"

# ---------------------------------------------------------------- 5. Preflight
step "7. Preflight" "make vks-login"
step "7. Preflight" "make lab-preflight"
step "7. Preflight" "make psa-check"

# ---------------------------------------------------------------- 6. Harbor's CA
step "8. Harbor CA" "set -a; . ./.env; set +a; curl -sk \"https://\${HARBOR_URL}/api/v2.0/systeminfo/getcert\" > ./secrets/harbor-ca.crt"
step "8. Harbor CA" "chmod 0644 ./secrets/harbor-ca.crt"
step "8. Harbor CA" "openssl x509 -in ./secrets/harbor-ca.crt -noout -subject"
step "8. Harbor CA" "sha256sum ./secrets/harbor-ca.crt"

# ---------------------------------------------------------------- 7. Harbor robot
step "9. Harbor robot" "make harbor-robot"
step "9. Harbor robot" "cat ./secrets/harbor-robot.env"

# ---------------------------------------------------------------- 8. Supervisor kubeconfig for ArgoCD
# §8's table. The doc is explicit that BOTH must be set: without ARGOCD_KUBECONFIG, gitops/verify
# "silently use your guest kubeconfig instead"; without ARGOCD_DEST_CLUSTER_NAME a run once
# "deployed into another cluster and reported Synced/Healthy throughout".
setenv "10. ArgoCD kubeconfig" "ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig" "ARGOCD_DEST_CLUSTER_NAME=${ARGOCD_DEST_CLUSTER_NAME:-}"
step "10. ArgoCD kubeconfig" "make fetch-argocd-kubeconfig"
step "10. ArgoCD kubeconfig" "make argocd-preflight"
step "10. ArgoCD kubeconfig" "make argocd-register-guest"

# ---------------------------------------------------------------- 9. Validate, then install
step "11. Install" "make env-populate"
step "11. Install" "make env-check"
step "11. Install" "make env-validate"
step "11. Install" "make install-all"
step "11. Install" "make verify"

# ---------------------------------------------------------------- 10. Ingress
step "12. Ingress" "make istio-preflight"
if [ "$WALK_EXISTS" = 1 ]; then
  step "12. Ingress" "make install-ingress INGRESS_CONTROLLER=istio-existing"
else
  step "12. Ingress" "make install-ingress"
fi

step "12. Ingress" "make verify-ingress"

# ---------------------------------------------------------------- 11. Access the UIs
step "13. Access the UIs" "make creds-show"

printf '\n\033[1m======== WALK DONE os=%s exists=%s steps=%d failed_steps=%d ========\033[0m\n' \
  "$WALK_OS" "$WALK_EXISTS" "$STEP" "$FAILED"
exit "$FAILED"
