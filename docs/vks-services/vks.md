# VKS itself — `tkg.vsphere.vmware.com`

The other pages here describe services that run **beside** or **inside** your cluster. This one is
the service that **makes guest clusters exist at all**, and it is the one you are most likely to
have to upgrade by hand.

It is a **Core Supervisor Service**. That single fact drives everything below: vCenter manages it,
and the API refuses to create, activate, deactivate, delete or rename it.

---

## The version string IS the Kubernetes ceiling

```text
3.6.3-embedded+v1.35      <- the +v1.35 is the MAX Kubernetes minor this service supports
3.7.0+v1.36
3.7.1+v1.36
```

That suffix is not decoration. On a lab running `3.6.3-embedded+v1.35`, a 1.36 TKr is **published
but not usable**:

```text
v1.36.1---vmware.4-vkr.5    Ready=False  Compatible=False
v1.36.2---vmware.2-vkr.3    Ready=False  Compatible=False
```

Both flip to `True`/`True` the moment the service reaches a `+v1.36` version. So *"why can I not
create a 1.36 cluster?"* is almost always *"the VKS service is still on a `+v1.35` version"*, and no
amount of looking at the TKr will say so.

The same upgrade adds a ClusterClass: the list stops at `builtin-generic-v3.6.0` before, and gains
`builtin-generic-v3.7.0` after. Each class declares the range it supports —
`kubernetes.vmware.com/min-version-supported` / `max-version-supported` — so `v3.6.0` (max `v1.35`)
genuinely cannot carry a 1.36 cluster.

⚠️ **You do not have to choose the class.** The Supervisor's mutating webhook rewrites
`spec.topology.classRef.name` to the newest compatible one — even when the class you asked for is
already in range. `25-vks-cluster-create.sh` reads the stored value back after the apply and reports
it; that read, not what you set, is the ground truth.

---

## A fresh Supervisor ships ONE version, and it is not the newest

Only `3.6.3-embedded+v1.35` carries `registered_by_default: true`. Every other version is registered
**by hand**, and a rebuilt Supervisor loses that registration — so after any rebuild you are back on
the shipped version until you re-register.

---

## The two files, and the one that will waste your afternoon

Broadcom publishes **two YAMLs per version**, differing on exactly one line:

| file | its `image:` line | use it? |
|---|---|---|
| `vsphere-kubernetes-service-legacy-<ver>.yaml` | `projects.packages.broadcom.com/...` | **YES — always** |
| `vsphere-kubernetes-service-<ver>.yaml` | `depot.kube-system.svc/...` | only with a VCF Operations Software Depot |

`depot.kube-system.svc` is an **in-cluster** Service that a plain lab does not run. Register that
file and the Supervisor cannot resolve the image, so the version can never install.

Verify what you downloaded before uploading it — a checksum is the only thing that distinguishes the
artifact from a captive-portal login page:

```sh
cd <wherever you staged them> && sha256sum -c <<'EOF'
39fb99549b082dfaac4fe946876dc866d207b1704b92b4553a73a57c4e020d9b  vsphere-kubernetes-service-legacy-3.7.0+v1.36.yaml
0d162b3e9e02c545402c451884a6156f841d97d8aa2deb94439f54ec531077b3  vsphere-kubernetes-service-legacy-3.7.1+v1.36.yaml
EOF
```

---

## Upgrading it

### 1. Register the version — vCenter UI only

> Supervisor Management → **Services** → the **Kubernetes Service** card → **ACTIONS → Add New
> Version** → **UPLOAD** the `-legacy-` file → **FINISH**

⚠️ **This step cannot be automated.** VKS is a Core Service and the create API returns **HTTP 403**:
*"Core services are managed by vCenter, it's not allowed to create, activate, deactivate, delete or
update display name / description of a Core service."*

⚠️ Use **Add New Version**, not **Add New Service** — the latter is the 403 path.

**Expect** an amber *"The YAML content defines an existing Supervisor Service
(tkg.vsphere.vmware.com), which may prevent creating a Supervisor Service from the content."* That
warning is what adding a version to an existing service looks like. The card's *Active Versions*
count increments.

### 2. Install it on the Supervisor

> Supervisor Management → **Supervisors** → the row's **Services: View** → Configure → Supervisor
> Services → **INSTALLED** → **Kubernetes Service** → **MANAGE** → Configure / Validate / Review →
> **FINISH**

**Expect** `Signature Verification: Pass`, and — on any single-node control plane — a
`Compatibility Check: Warning` reading *"Upgrading the Supervisor Service on a single-node control
plane Supervisor can cause downtime of your workloads."* That warning is **normal and expected on a
successful upgrade**, so it does not tell you anything is wrong.

Everything after registration is ordinary API work (`PUT
/api/vcenter/namespace-management/clusters/<moid>/supervisor-services/<id>`), so whatever tooling
your platform team uses can drive it unattended.

**It does not touch running clusters.** A guest cluster keeps its own ClusterClass and Kubernetes
version across the upgrade; moving it is a separate, per-cluster rebase.

### 3. Verify the END RESULT, not the exit code

An HTTP 200 proves the request was accepted. These prove the upgrade did what you wanted:

```sh
make vks-login          # this repo, if you do not already have a Supervisor kubeconfig
export KUBECONFIG=./secrets/supervisor.kubeconfig

kubectl -n vmware-system-supervisor-services get pkgi svc-tkg.vsphere.vmware.com \
  -o jsonpath='{.spec.packageRef.versionSelection.constraints}  {.status.friendlyDescription}{"\n"}'
kubectl get tkr | grep 1.36                                          # want: True  True
kubectl -n vmware-system-vks-public get clusterclass | grep v3.7.0   # want: present
kubectl -n <your-ns> get cluster <your-cluster> \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'   # want: True
```

That last one matters because the compatible-release catalogue **changes** across the upgrade —
confirm the release your running cluster is on is still `Compatible`.

---

## When it fails, the error names the wrong thing

The upgrade request returns **HTTP 500** *"Supervisor Service (tkg.vsphere.vmware.com) version
(...) is not compatible. For more details, go to the precheck step..."* — which reads as a version
problem and is usually not one.

Open the **Validate** step of the Manage wizard. If `Signature Verification` is an **Error** naming
`depot.kube-system.svc ... no such host`, the **non-legacy** file was registered.

### Why re-uploading the legacy file does NOT fix it

There are **two stores**, and a re-upload only reaches the first:

| store | holds |
|---|---|
| vCenter's catalogue | the YAML bytes you upload |
| the **Supervisor's** Carvel `Package` (`vmware-system-supervisor-services`) | built **from those bytes at registration** — the YAML's `image:` line becomes its `imgpkgBundle.image` |

Registering a version that **already exists** does not rebuild the Package. So after
upload-depot → remove → upload-legacy, the catalogue is correct and the Supervisor's Package is
still a depot fossil. A `wcp` restart does not clear it either.

### Recovery

1. **ACTIONS → Manage Versions** → select the bad version → **DEACTIVATE VERSION**
   (*"Your running instances will not be impacted"*) → **DELETE**.
2. **Confirm the Package is gone** before re-registering — this is the step that decides whether the
   rest will work:

   ```sh
   kubectl -n vmware-system-supervisor-services get package tkg.vsphere.vmware.com.<ver> \
     -o jsonpath='{.spec.template.spec.fetch[0].imgpkgBundle.image}{"\n"}'
   ```

3. **ACTIONS → Add New Version** → upload the **`-legacy-`** file → FINISH.
4. Confirm the rebuilt Package now carries `projects.packages.broadcom.com/...`.

⚠️ **Prove the mechanism additively before you delete anything.** Registering a version that does
*not* yet exist builds its Package from the uploaded bytes — so if that Package comes out with a
`projects.packages.broadcom.com` image, you have proven registration works **and** identified the
other version as a fossil, with zero destructive action. Registering 3.7.0 is also a complete escape
route on its own: it is `+v1.36` too, so it unlocks Kubernetes 1.36 exactly as 3.7.1 does.

---

## Provenance & confidence

| Fact | Grade | Evidence |
|---|---|---|
| VKS is a **Core** Supervisor Service; the create API returns 403 | **lab-verified 2026-08-26** | the API's own message, quoted above |
| A fresh Supervisor registers only `3.6.3-embedded+v1.35` | **lab-verified 2026-08-26** | `registered_by_default: true` on that version, `false` on 3.7.0 and 3.7.1 |
| The `+v1.3x` suffix is the max Kubernetes minor | **lab-verified 2026-08-26** | both 1.36 TKrs `Compatible=False` on 3.6.3, `True` after the upgrade |
| Registration builds the Supervisor `Package` from the uploaded bytes | **lab-verified 2026-08-26** | registered 3.7.0 from the legacy file; its Package image came out `projects.packages.broadcom.com/...` |
| Re-registering an EXISTING version does not rebuild its Package | **lab-verified 2026-08-26** | catalogue held the legacy bytes (6830 B) while the Package still held the depot image |
| Deleting the version DOES remove the Supervisor Package | **lab-verified 2026-08-26** | it disappeared between the delete and the re-register |
| The upgrade leaves running guest clusters untouched | **lab-verified 2026-08-26** | the guest stayed on its own class and version, `Available=True AddonsReconciled=True`, across two hops |
| Admission rewrites `classRef` to the newest compatible class | **lab-verified 2026-08-26** | six server-side dry-runs; it rewrote even when the asked class was in range |
| `3.6.3 → 3.7.1` in ONE hop | **INFERRED — not run** | the package declares `source-version-upgrade-constraints: '>=3.4.0'`, which 3.6.3 satisfies. What was measured is the two-hop path |
| Whether the classRef rewrite also fires on UPDATE | **NOT ESTABLISHED** | deliberately untested — that dry-run would have targeted a live cluster |
