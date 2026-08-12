# The guest cluster's control-plane VIP — why a REUSED name never converges

**What it affects:** every `make vks-cluster-create` (scenario-1 §6).
**What we do:** use a cluster name **that has never been used in that vSphere Namespace**, and fail
fast when the advertised endpoint disagrees with the LoadBalancer.

> **The trap this page exists for.** A guest cluster created under a name that was used before comes
> up `phase: Provisioned` with a healthy control-plane VM and a healthy LoadBalancer, and then never
> becomes Ready. `ControlPlaneInitialized` stays `False` forever and the wait burns its **full**
> budget (measured: **1807 s**) before saying anything. Nothing in the symptom names the cause: the
> VM is fine, the LB is fine, and the only wrong thing is the *address the Cluster advertises*.

## The mechanism

CAPV writes `Cluster.spec.controlPlaneEndpoint` from `VirtualMachineService.status.loadBalancer`,
and on a reused name it can read the **previous incarnation's** VirtualMachineService — an object
that is still `Get`-able while it terminates. Having written a value once, it never revisits it.

| Fact | Value | Confidence |
|---|---|---|
| The endpoint is written **before** the LB that owns it exists | Cluster endpoint at `04:32:17`; the `VirtualMachineService` at `04:32:21` — a 4-second lead, so the value cannot have been read from that object | lab-verified [src: cmd="kubectl -n cicd get cluster cicd-gc1 virtualmachineservice cicd-gc1 -o jsonpath='{.metadata.creationTimestamp}'" out="cluster 2026-08-12T04:32:17Z / vmservice 2026-08-12T04:32:21Z" date=2026-08-12] |
| The wrong value is the **previous incarnation's** LB IP | five incarnations of one name: #1 agreed and went Ready in 3m45s; #2–#5 each advertised the prior LB and never converged | lab-verified [src: code:scripts/26-vks-cluster-status.sh:119-122] |
| Upstream calls this adopting a **stale VirtualMachineService**, and it is Broadcom-authored | CAPV PR #3881, merged 2026-03-16 | primary-sourced [src: url=https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/pull/3881 date=2026-08-12 quote="a newly created cluster could 'adopt' a stale VirtualMachineService left over from a previous cluster with the same name"] |
| A **second**, still-unfixed defect is why it cannot self-heal | CAPV #2872 — the reconciler skips endpoint reconciliation once the field is set, and marks the LB condition ready without re-checking | primary-sourced [src: url=https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/issues/2872 date=2026-08-12 quote="Skipping control plane endpoint reconciliation"] |
| The timing separates a stale read from a real allocation | reused name: VMService created → endpoint found in **0.27 s** (faster than any real allocation). Fresh name: **19.3 s**, matching the real assignment | lab-verified [src: cmd="kubectl -n svc-tkg-6ta08 logs deploy/capv-controller-manager \| grep -E 'Found API endpoint\|VirtualMachineService was not found'" out="gc1 0.27s vs gc2 19.3s" date=2026-08-12] |
| `spec.controlPlaneEndpoint` is **not** CRD-immutable; it is a controller ratchet | no `x-kubernetes-validations` on the field in any served version; CAPI only fills it when unset | primary-sourced [src: url=https://github.com/kubernetes-sigs/cluster-api/issues/9228 date=2026-08-12 quote="Once a Cluster instance is set"] |

## The fix, and two that look better and are refuted

| Remedy | Verdict | Confidence |
|---|---|---|
| **A name never used in that namespace** | **SHIP.** Same lab, same minute, no rebuild: the reused name never converged while a fresh name agreed on its first read and reached `Available=True` in ~11 min | lab-verified [src: cmd="kubectl -n cicd get cluster" out="cicd-gc1 Available=False after 53m; cicd-gc2 Available=True after 11m" date=2026-08-12] |
| **Fail fast on divergence** | **SHIP** as the guard — it converts a 30-minute silent wait into ~60 s | lab-verified [src: code:scripts/25-vks-cluster-create.sh:124-171] |
| Pre-set `spec.controlPlaneEndpoint` | **REFUTED for VKS.** A pre-set endpoint makes CAPV return *before* creating the VirtualMachineService, and `builtin-generic-v3.6.0` ships **no kube-vip** to serve the address instead — so nothing would answer | primary-sourced [src: url=https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/main/controllers/vmware/vspherecluster_reconciler.go date=2026-08-12 quote="if !clusterCtx.Cluster.Spec.ControlPlaneEndpoint.IsZero"] |
| Repair the endpoint in place | **REFUTED.** kubeadm bakes the endpoint into the apiserver certificate SANs, so correcting it breaks TLS: the real LB serves a cert that does not name it | lab-verified [src: cmd="curl --cacert <cluster CA> https://192.168.101.140:6443/version" out="SSL: no alternative certificate subject name matches target host name '192.168.101.140'" date=2026-08-12] |
| Delete and recreate under the **same** name | **REFUTED** — reproduced four times running | lab-verified [src: code:scripts/26-vks-cluster-status.sh:119-122] |
| Wait for IPAM reclaim | weak: the pool publishes only an allocated **count**, not per-IP state, and allocation is monotonic so the freed IP is not reused anyway | lab-verified [src: cmd="kubectl get ippools.netoperator.vmware.com -A -o yaml" out="status publishes an allocated COUNT only; no per-IP state" date=2026-08-12] |
| Upgrade past the bug | the guard exists on CAPV `main` and is absent in `release-1.15`; this lab runs `v1.15.2+vmware.3` | primary-sourced [src: cmd="kubectl -n svc-tkg-6ta08 logs deploy/capv-controller-manager \| grep -m1 Version:" out="v1.15.2+vmware.3" date=2026-08-12] |
| Broadcom KB coverage of this exact symptom | **none found** across 16 release-note documents and ~15 KB phrasings; the closest, KB 425565, prescribes a unique new name for an adjacent class | NOT-ESTABLISHED [src: NOT-ESTABLISHED tried="Supervisor 9.1/9.0 + VKS 3.3-3.7 release notes, KB 425565/384871/390201/407628, CAPI and vm-operator issue trackers"] |

> ⚠️ **A confound in our own A/B, stated rather than buried.** The two clusters differed in *both*
> name-freshness **and** TKr version (`v1.35.5` vs `v1.34.8`), so that pair alone is not a
> single-variable control. What makes name-reuse the operative variable is the prior history of
> **four incarnations of one name** on this lab, of which only the one whose name was new converged.

## Detecting it portably

Identify the control-plane LoadBalancer by the **ownership chain**, never by name — the bare-cluster-name
convention is a CAPV version detail:

```text
Cluster.spec.infrastructureRef.name  ->  VSphereCluster
  -> the VirtualMachineService whose ownerReferences[].kind == "VSphereCluster" and .name == that
     -> .status.loadBalancer.ingress[0].ip
```

Read the **port from the Cluster** rather than assuming 6443, and decline to judge unless exactly one
candidate matches. `make vks-cluster-status` does both.

## Related: finding installed Supervisor Services

| Fact | Value | Confidence |
|---|---|---|
| `supervisorservices` and `serviceinstallconfigs` are unusable for this | the first returns `No resources found` with services installed and serving; the second is Forbidden even to `sso:Administrator@vsphere.local` | lab-verified [src: cmd="kubectl get supervisorservices -A; kubectl get serviceinstallconfigs -A" out="No resources found; Error from server (Forbidden)" date=2026-08-12] |
| The portable discriminator is the **namespace label** | `appplatform.vmware.com/serviceId` — needs only `list namespaces`, which a tenant has | lab-verified [src: cmd="kubectl get ns -l appplatform.vmware.com/serviceId -o custom-columns=NS:.metadata.name,ID:.metadata.labels" out="svc-harbor-fkee0 harbor / svc-argocd-service-imb6j argocd-service" date=2026-08-12] |
| It is **not exhaustive** | `svc-tmc-c9` carries no `serviceId` label — a service installed outside AppPlatform is invisible to it | lab-verified [src: cmd="kubectl get ns svc-tmc-c9 --show-labels" out="no appplatform.vmware.com/serviceId label" date=2026-08-12] |
