# Recovering a wedged lab reset

What to do when the lab reset (`make -C ~/projects/nested-vsphere-lab walk-reset CONFIRM=yes`)
refuses or hangs. Every sequence here was **measured on the lab on 2026-08-16**, in the order it actually happened —
each fix revealed the next blocker, which is why the order matters.

This is the *recovery* doc. Its siblings are [`lab-validation-plan.md`](lab-validation-plan.md)
(what to capture on a lab trip) and [`lab-automation.md`](lab-automation.md) (how a different
automation solves the same lab). Nothing here belongs in either.

## Two config facts you need before anything else

| what | where it actually is |
|---|---|
| the licensed VCF/VKS CLI archives (`VCF_CLI_SRC_DIR`) | **`~/Downloads/vcf`** — contains `argocd-cli-linux-amd64-<ver>-vcf.gz`, the Consumption CLI and the Plugin Bundle |
| the vCenter password (`VCENTER_PASSWORD`) | nested-vsphere-lab's gitignored **`secrets.env`**, as `VCSA_SSO_PASSWORD` |

```sh
# Source the credential without putting it in argv or printing it.
set -a; . /home/andriy/projects/nested-vsphere-lab/secrets.env; set +a
export VCENTER_PASSWORD="$VCSA_SSO_PASSWORD"
export KUBECONFIG="$HOME/.local/state/nested-lab/kubeconfig"
```

⚠️ **Guessing `VCF_CLI_SRC_DIR` costs a whole matrix row.** `walk-matrix.sh` asserts the variable
is SET, never that the directory EXISTS, so a wrong path builds a VM, creates the vSphere
Namespace, and fails ~20 minutes later at step 5 — reporting four red steps that name a missing
kubeconfig, a missing `vcf` binary and Harbor, none of which is the cause. Filed as B443 in
nested-vsphere-lab.

## Read the WHOLE cell, never one resource

The lab's `make creds` saying *"Harbor: not detected"* is **not** "the lab is clean". The matrix
checks four signals and refuses if any disagree with the row it is about to walk:

```sh
KC="$HOME/.local/state/nested-lab/kubeconfig"
KUBECONFIG="$KC" kubectl auth whoami >/dev/null || echo "AUTH FAILED — every probe below would read 0"
nss=$(KUBECONFIG="$KC" kubectl get ns -o name)
printf 'cicd=%s harbor=%s argocd=%s\n' \
  "$(grep -c 'namespace/cicd$' <<<"$nss")" \
  "$(grep -c 'svc-harbor-' <<<"$nss")" \
  "$(grep -c 'svc-argocd-service-' <<<"$nss")"
```

`0 0 0` is the NOTHING cell. I read Harbor alone once and concluded "clean" while ArgoCD and the
namespace were both still up; the matrix caught it and refused, which is the guard working.

Ignore `svc-cci-ns-*`, `svc-tkg-*`, `svc-tmc-*`, `svc-velero-*` — those are built-in Supervisor
services and must survive a reset.

## The three blockers, in the order they appear

### 1. The uninstall wedges on workload kapp is waiting for

Symptom, in the reset's own output:

```text
platform: Deleting kapp: Error: Timed out waiting after 15m0s for resources:
  - endpointslice/argocd-service-webhook-service-<hash>
```

The break-glass tool deletes exactly that workload. It refuses without `CONFIRM=yes` and prints
what it would delete first, so run it once to look:

```sh
make unwedge-supervisor-service SERVICE=argocd-service.vsphere.vmware.com
make unwedge-supervisor-service SERVICE=argocd-service.vsphere.vmware.com CONFIRM=yes
```

Measured: `deleted 3 object(s)` (one deployment, two Services — the Services own the endpointslice).

### 2. …then kapp moves to the CRD, and waits FOREVER

This one is caused *by* step 1, and the tool's closing advice ("re-issue the uninstall, kapp
retries in 15-minute rounds") **cannot** resolve it — measured, two full rounds, zero progress.
Deleting the workload removed the **controller**, and every CR whose finalizer needed that
controller is now unfinalizable:

```text
crd/applications.argoproj.io   Terminating   finalizer: customresourcecleanup.apiextensions.k8s.io
application/cicd/{gowebapp,javawebapp}       finalizer: resources-finalizer.argocd.argoproj.io
```

```sh
KUBECONFIG="$KC" kubectl get applications.argoproj.io -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,FIN:.metadata.finalizers,DEL:.metadata.deletionTimestamp
for a in gowebapp javawebapp; do
  KUBECONFIG="$KC" kubectl -n cicd patch application.argoproj.io "$a" \
    --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

The CRD disappeared in **under 8 seconds** after that. Filed as B114.

⚠️ Dropping a finalizer abandons whatever cleanup it represented. On a throwaway lab whose guest
cluster is already gone that is correct; on a real cluster it can orphan real resources. Look at
what the finalizer was for before you clear it.

### 3. …then the namespace delete refuses on orphaned PVCs

```text
[FAIL] refusing to delete 'cicd': it still holds persistentvolumeclaim=9
  Delete the guest cluster ('make guest-cluster-delete CONFIRM=<name>'), wait, then re-run.
```

The guard is right to refuse — namespace-first deletion is the documented cause of a stuck
Terminating state. **But its remedy can name something that does not exist.** Measured: there was
no guest cluster at all (`kubectl get cluster.cluster.x-k8s.io -A` → *No resources found*); the 9
PVCs were CNS volumes orphaned by clusters deleted hours earlier, spanning several incarnations.

Prove they are orphans before deleting — zero `ownerReferences` and no Cluster anywhere:

```sh
KUBECONFIG="$KC" kubectl -n cicd get pvc -o json \
  | jq -r '.items[] | "\(.metadata.name) owners=\(.metadata.ownerReferences // "NONE")"'
KUBECONFIG="$KC" kubectl get cluster.cluster.x-k8s.io -A
KUBECONFIG="$KC" kubectl -n cicd delete pvc --all --wait=false
```

Then re-run the reset; it reported the NOTHING cell with the platform services intact.

## Two process notes that cost real time today

- **The reset outlives a 10-minute foreground tool call.** Run it backgrounded, or it is
  TERMINATED mid-uninstall and you inherit a half-deleted service.
- **Killing it needs the process GROUP, and even that missed a child**: the inner
  `timeout … make uninstall-supervisor-service` had its own pgid and kept polling after the parent
  died. Check with `ps -eo pid,etime,args | grep uninstall-supervisor` and kill by explicit pid.
  Never `pkill -f` a pattern that also appears in your own command line — it self-matches and kills
  your shell (exit 143/144).
