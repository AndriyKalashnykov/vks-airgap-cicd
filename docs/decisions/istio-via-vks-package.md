# Installing Istio as the VKS Standard Package (Carvel) — proposed, REFUTED

**Status:** REJECTED — do not implement. The direction is right; the *mode* is not.
**Date:** 2026-07-22
**Answers:** the "Broadcom-packaging question" left open by
[istio-on-vks.md](istio-on-vks.md).

## The question

We install Istio with upstream Helm charts and `--set global.hub=<Harbor>`
(`INGRESS_CONTROLLER=istio`). Broadcom ships Istio as a **VKS Standard Package**
(`istio.kubernetes.vmware.com`) installed through Carvel/kapp-controller. A third-party
automation of the same lab does exactly that, declaratively, through Argo CD
(`warroyo/vks-argocd-examples//istio/source/istio.yml:119-134` — see
[lab-automation.md](../lab-automation.md) §4):

```yaml
spec:
  packageRef:
    refName: istio.kubernetes.vmware.com
    versionSelection: { constraints: 1.25.3+vmware.1-vks.2, prereleases: {} }
  serviceAccountName: carvel-sa
  values: [ { secretRef: { name: istio-values } } ]
```

Should Scenario 1 install Istio "the VMware way" — as the packaged, version-certified artifact
rather than an upstream chart? Proposed as a fourth mode, `INGRESS_CONTROLLER=istio-vks-package`.

## Decision

**No.** Do not build the mode. **Yes** to the underlying intent — the VMware way for Scenario 1
is the **vendor's own install path**, run by the cluster owner, after which our existing
`INGRESS_CONTROLLER=istio-existing` attach mode takes over. Same destination, zero new code.

## Why — the decisive argument

The mode's addressable environment is nearly empty. To run it, an operator needs **all** of:

- a real VKS guest cluster (kapp-controller **and** the VKS `PackageRepository`) — our KinD
  stand-in has neither;
- **cluster-admin** on that cluster;
- Istio *not* already installed;
- and a wish to install it.

In precisely that cell, Broadcom already ships a documented one-liner:

```bash
vcf package repository add vks-standard --url <read-it-off-the-lab> -n tkg-system
vcf package install istio -p istio.kubernetes.vmware.com -v <version> --values-file istio-data-values.yaml
```

after which `INGRESS_CONTROLLER=istio-existing` — already shipped, already regression-tested by
`make e2e-kind-istio-existing`, already documented — handles the rest. The proposed mode would
reimplement a vendor CLI call as a bespoke, untestable, air-gap-hostile fourth mode in order to
reach a state the existing third mode already handles.

**This argument stands even if every engineering objection below were solved**, which is what
makes it decisive rather than merely discouraging.

## Supporting constraints

Each was examined; none alone would have been fatal, and all of them point the same way.

### 1. imgpkg relocation is an addressing-model mismatch, not a missing flag

The `PackageRepository` fetches an **imgpkg bundle**
(`vks-standard-repo/source/repo.yml:1-9`), not a plain image. imgpkg relocation works by
co-locating **every referenced image, by digest, in ONE repository** — the bundle's own — and
rewriting `.imgpkg/images.yml` accordingly. Our mirror is the opposite shape: **one repository
per image, addressed by tag** (`scripts/lib/mirror.sh:60-66`).

Consequences:

- `make mirror-verify` reconciles `images.lock` digests per *named* image. A relocated bundle is
  N untagged manifests in one repository path — it could not verify it. A push we have not
  verified is not a mirror, which is exactly why `mirror` depends on `mirror-verify`.
- `mirror_platform_arg` (`scripts/lib/mirror.sh:76-80`) defaults to a **single-arch** copy, which
  **changes the digest**. imgpkg's locality lookup is digest-exact, so a single-arch copy would
  fail to resolve and kapp-controller would fall back to the absolute public path — an air-gap
  break at *install* time, not at mirror time.
- `imgpkg copy --to-tar/--from-tar` would be a **second sneakernet bundle** parallel to
  `make bundle`, doubling the surface area of the most fragile subsystem we have.

`imgpkg` itself is a static Go binary of the same class as `crane`/`kubectl`/`helm`, which
`scripts/11-bundle.sh` already stages, so *installability* is not the objection — the addressing
model is.

### 2. The package registry is entitled

`projects.packages.broadcom.com` requires Broadcom credentials. Every source in
`images/images.txt` today is anonymous-pullable. This would add a credential requirement to the
internet-side box and place licensed vendor content into our Harbor.

### 3. No KinD coverage, and the tempting partial gate is forbidden

KinD has no kapp-controller and no `tkg-system`, so the mode could not be exercised by
`make e2e-kind`. The obvious workaround — install upstream kapp-controller into KinD and author
a fake `Package` CR — is **forbidden by our own testing rules**: the VMware package cannot be
obtained (entitled registry, VMware-built content), so the gate would exercise Carvel's
reconciler against a mock *of the thing under test* and go green forever while proving nothing.

### 4. No tenant path — the right conclusion, for a reason worth stating correctly

The reference implementation grants `carvel-sa` a cluster-wide
`apiGroups: ['*'] resources: ['*'] verbs: ['*']` ClusterRole
(`package-rbac/source/rbac.yml:14-41`). It is tempting to cite that as the bar — but it is that
lab's shortcut, not a Broadcom requirement, and citing it invites the next reader to spend a day
golfing the ClusterRole down.

The real reason is one level deeper: `PackageInstall` is namespaced and its ServiceAccount bounds
what the package may create, but **Istio's own resources are cluster-scoped** — CRDs,
ClusterRoles, the mutating webhook configuration, the `istio-system` / `istio-ingress`
namespaces, and the CNI DaemonSet's hostPath. No namespace-scoped ServiceAccount suffices *for
Istio specifically*. There is no tenant-usable package-install path; Scenario 2 stays attach.

## What was extracted instead

The evidence was worth more than the mode. All of it landed as documentation:

- **`istioCNI.enabled` defaults to `true`** — corrected in
  [vks-services/istio.md](../vks-services/istio.md). This applies to `istio-existing` too, not
  only to the rejected mode.
- **A real VKS values file enables an egress gateway as well as an ingress one**, which may make
  our gateway discovery ambiguous. Recorded as the highest-priority lab step in
  [lab-validation-plan.md](../lab-validation-plan.md) — it is the only item here that touches
  shipping code.
- **The values schema** of a mesh we might attach to, so an operator can ask a mesh admin precise
  questions.
- **`tkg-system`** confirmed as the `PackageRepository` namespace, and a third observed
  repository-URL shape — so the URL must be read off the lab, never copied.

## Open, and deliberately ungraded

**kapp-controller's presence on a VKS guest cluster** is load-bearing for this whole question and
has no graded row anywhere in our docs. It is almost certainly true — packages are *the* install
mechanism on VKS — but "almost certainly" is not a grade. Settle it with
`kubectl api-resources | grep packaging.carvel.dev` on the next lab visit.

## How this was decided

Proposed after reading a third-party automation of the same lab, then put to an adversarial
review **before any code was written** (RULE ZERO trigger 2). The reviewer's shell was denied, so
its findings are source-read and cited rather than measured; the two claims this document leans on
most — the `carvel-sa` ClusterRole and the values file's egress block — were re-verified by hand
against the fetched files.

The idea-first round is the reason this cost a document instead of a subsystem.

---

[← back to the README](../../README.md)
