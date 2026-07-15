# KinD TLS fidelity — mimic VCF/VKS 9.1 self-signed TLS for Harbor + ArgoCD

**Status:** ACCEPTED & LANDED (secure mode validated end-to-end; see Validation)
**Date:** 2026-07-10
**Branch:** `feat/kind-tls-fidelity`

## Problem

The local KinD stand-in originally presented the **opposite** TLS posture to a real
VCF/VKS 9.1 lab, so a green `make e2e-kind` did **not** exercise the self-signed-TLS +
CA-trust path the lab actually requires:

| Component | KinD (before) | Real VKS 9.1 lab |
|-----------|-----------|------------------|
| **Harbor** | plain **HTTP** LB; containerd `skip_verify = true`; Kaniko `--skip-tls-verify` | **HTTPS/443**, self-signed cert (cert-manager), clients trust its CA |
| **ArgoCD** | patched `server.insecure=true` (plain HTTP) | **self-signed TLS/443** (`server.insecure` is *not* the default), reached by LB IP with `--insecure` |

The whole point of the KinD path is to predict lab behavior. It hid exactly the class of
failure most likely on a real air-gapped lab: a self-signed registry cert that every
consumer (jump-box `crane`, node `containerd`, in-cluster Kaniko) must trust.

**Goal:** make KinD mimic the lab's cert posture **by default**, so "works on KinD" means
"the CA-trust wiring works" — not "TLS was skipped" — while keeping the current insecure
posture as an **optional, still-tested** fast-iteration path, and doing all of it
**sudo-free** (no root-owned system-trust-store changes, no `/etc/hosts` / DNS edits).

## Modes — secure by default, insecure optional (both tested)

KinD keeps **both** postures as a per-component toggle, defaulting to the faithful one:

- **`secure` (default)** — self-signed TLS + CA trust, mimics VCF/VKS 9.1. Driven by
  **`HARBOR_INSECURE=0`** (Harbor self-signed HTTPS) and **`ARGOCD_INSECURE=0`** (ArgoCD
  upstream self-signed TLS). This is the `.env.example` default.
- **`insecure` (optional)** — the original convenience posture: plain-HTTP Harbor
  (`HARBOR_INSECURE=1`) + `server.insecure` ArgoCD (`ARGOCD_INSECURE=1`). Retained verbatim
  for fast local iteration / debugging without cert wrangling.

`06-install-harbor.sh` and `07-install-argocd.sh` **branch** on these flags — the secure
branch is the new default, the insecure branch is the original code. `make e2e-kind` runs
`secure` by default; both modes are validated by a mode-override
(`make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1` runs the insecure matrix; see
Validation). Every downstream consumer (containerd wiring, Kaniko flags, `crane`, the
builder push, `verify`, `creds`) keys off the same flags so the two modes never half-mix.

## VCF/VKS 9.1 cert models (researched, cited)

### Harbor

- Deployed as a **Supervisor Service** (Contour + LoadBalancer); the old embedded
  vSphere Registry Service is **removed** in vCenter 9.0. This Supervisor-Service Harbor
  is the "VKS-provided" registry a lab hands you.
- **HTTPS on 443 only.** Default cert is **self-signed, minted by cert-manager** when the
  `tlsCertificate`/`tlsCertificateSecretName` fields are empty — a **per-instance
  self-signed CA**, *not* the vCenter VMCA.
- Exposed via a LoadBalancer VIP + FQDN; the cert **CN/SAN = the Harbor `hostname` FQDN**.
- Clients must trust Harbor's **`ca.crt`** (Harbor UI → *Administration → Configuration →
  Registry Root Certificate → Download*, or read the TLS secret). Without it:
  `x509: certificate signed by unknown authority`.
- Sources: [Harbor 2.13.x Supervisor package reference](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/harbor-components--configuration--data-values/harbor.html),
  [Install Harbor as a Supervisor Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html),
  [williamlam — VKS self-signed registry trust](https://williamlam.com/2025/08/quick-tip-configuring-vsphere-kubernetes-service-vks-cluster-with-self-signed-container-registry.html).

### ArgoCD

- **Supervisor Service** (Broadcom Argo CD Operator, GA 2025); provisions **stock upstream
  ArgoCD** — VKS 9.1 = **v2.14.13** (selectable via the `ArgoCD` CR `spec.version`).
- **Self-signed TLS on 443 by default.** Upstream `argocd-server` auto-generates a
  self-signed cert (persisted in `argocd-secret`); `server.insecure` (plain HTTP) is **not**
  the default. Overridable via an `argocd-server-tls` secret.
- Exposed via a **LoadBalancer** Service (ports 80 + 443); reached **by IP** with
  `argocd login <ip> --insecure` (client skips verification of the self-signed cert).
- Terminology trap: client `--insecure` = "don't *verify* the cert" (used against VKS);
  server `--insecure` / `server.insecure` = "serve **no** TLS" (what KinD wrongly did before).
- Sources: [VMware Argo CD Operator install](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html),
  [vSphere Supervisor 9.1 release notes](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vsphere-supervisor-release-notes.html),
  [Argo CD upstream TLS docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/).

**Honesty note:** the 9.1-exact cert internals are not published field-by-field (the cert pages
resolve only to the `/9-0/` tree; field detail is the 8.0 package reference + 9.0 pages, behaviorally
identical for Harbor/ArgoCD). Both models rest on the cert-manager-self-signed default +
upstream defaults. A given lab *may* have been handed a custom/CA-signed instance — the
design below trusts a **CA we control**, which covers both (a self-signed leaf under our CA
is the faithful default; a lab-CA-signed cert is the same trust mechanism, different issuer).

## Endpoint choice — the LoadBalancer IP (sudo-free), not an FQDN

The lab's cert SAN is the Harbor **FQDN**; an earlier sketch of this design mirrored that by
minting the cert for `harbor.vks.local` and wiring the name in via `/etc/hosts` (host),
CoreDNS `hosts` (in-cluster pods), and the system trust store (`update-ca-certificates`).
**That variant was superseded** because every one of those hops needs **sudo** (root-owned
`/etc/hosts`, CoreDNS ConfigMap edits, the system CA store) — which blocks unattended runs
and every operator without root.

The chosen design uses the **LoadBalancer IP** as the endpoint instead:

- The cloud-provider-kind LB IP is routable **from the host** AND **in-cluster** (both sit on
  the kind Docker network), so **no `/etc/hosts` / CoreDNS / DNS wiring is needed** — the one
  genuinely new mechanism the FQDN variant required is gone.
- The leaf cert's SAN is that **IP** (`IP:<lb-ip>`), and each consumer trusts our CA through
  its own per-tool mechanism (below) — **never the system store**. No sudo, anywhere.
- The FQDN-vs-IP SAN is **cosmetic fidelity**: what actually predicts lab behavior is the
  self-signed-TLS + explicit-CA-trust *posture* (the class of failure that bites on a real
  lab), and that is identical whether the SAN is an IP or a name. We don't pay the
  sudo/DNS friction for a cosmetic match.

## Design — mimic on KinD (exact per-file changes)

Only **Harbor** and **ArgoCD** are VKS-provided, so only they change. Gitea, Tekton, the
Tekton Dashboard and the javawebapp app are *ours* — they stay HTTP behind the `*.vks.local`
ingress (no VKS cert contract on them).

### Cert minting (`scripts/lib/tls.sh`)

Mint a **self-signed CA + leaf cert** with `openssl` (deterministic, no cert-manager
dependency in the KinD stack — same *end state* as cert-manager's self-signed default;
a deliberate simplification). Helpers:

- `gen_selfsigned_ca_cert <endpoint-ip-or-host> <out-dir> [ca-cn]` — writes `ca.crt`/`ca.key`
  (self-signed CA) + `tls.crt`/`tls.key` (leaf signed by that CA; CN + SAN = the endpoint).
  SAN is `IP:<addr>` when the endpoint looks like an IPv4 address, else `DNS:<host>`. The
  **CA is stable across runs** (kept if present, so already-distributed trust stays valid);
  the **leaf is always regenerated** so its SAN tracks the CURRENT LB IP (cloud-provider-kind
  may reassign it between cluster rebuilds). `umask 077` on all key material.
- `ca_bundle_with_system <ca-file> <out-bundle>` — builds a bundle = the system trust store
  **+** our CA, so a host tool pointed at it via `SSL_CERT_FILE` trusts **both** upstream
  (public) registries and our self-signed Harbor in one run, without touching the root-owned
  system store.

### Harbor → self-signed HTTPS on the LB IP + CA trust

Endpoint = the Harbor LoadBalancer **IP** (cert SAN = `IP:<lb-ip>`).

- **`scripts/06-install-harbor.sh`** (two-phase, because the LB IP — the cert SAN — isn't
  known until the Service is up):
  1. install Harbor with **TLS off** (`expose.tls.enabled=false`), poll for the LB IP;
  2. mint the CA + leaf (SAN=`IP:<lb-ip>`) into `secrets/harbor-tls/`, create the
     `harbor-tls` k8s TLS secret, `helm upgrade` to **HTTPS** (`expose.tls.certSource=secret`,
     `externalURL=https://<lb-ip>`).
  - wire **each kind node's** containerd: `/etc/containerd/certs.d/<lb-ip>/hosts.toml` with
    `server = "https://<lb-ip>"` **and an explicit `ca = ".../ca.crt"`** line, plus
    `docker cp` the CA into the node at that path (copying the CA into the node *system* store
    alone is NOT reliable for containerd's registry client — a known kind gotcha).
    `config_path=/etc/containerd/certs.d` is read per-pull, no restart.
  - readiness: poll `https://<lb-ip>/api/v2.0/health` with `--cacert ca.crt` (the LB-routable
    poll — an assigned IP isn't envoy-routable immediately).
  - `.env.kind`: `HARBOR_URL=<lb-ip>`, **`HARBOR_INSECURE=0`**,
    `HARBOR_CA_FILE=secrets/harbor-tls/ca.crt`. (insecure branch: `HARBOR_INSECURE=1`,
    `HARBOR_CA_FILE=''`, plain-HTTP `externalURL`, containerd `skip_verify`.)
- **`scripts/21-mirror-push.sh`:** in secure mode, `ca_bundle_with_system "$HARBOR_CA_FILE"`
  → `export SSL_CERT_FILE=<bundle>`; `crane` (go-containerregistry) honors `SSL_CERT_FILE`, so
  it pushes over TLS trusting our CA **and** still verifies upstream public registries — no
  `--insecure`, no system-store change, no sudo.
- **`scripts/15-build-push-builder.sh`:** the builder-image podman push points at the CA via
  **`--cert-dir <dir>`** (a clean dir holding only `ca.crt`, so podman doesn't mistake a stray
  `tls.*` for a client cert) — sudo-free.
- **`k8s/tekton/tasks/kaniko-build.yaml` + `make platform`:** Kaniko trusts the CA via the
  `harbor-ca` ConfigMap mounted at `/kaniko/ssl/certs/additional-ca-cert-bundle.crt`
  (Kaniko appends it to its trust bundle). `60-configure-tekton.sh` already creates that
  ConfigMap from `HARBOR_CA_FILE` — in KinD it was empty before; now it carries a real CA.

### ArgoCD → self-signed TLS on its OWN LoadBalancer

- **`scripts/07-install-argocd.sh`:** secure mode leaves upstream self-signed TLS on 443
  (what real VKS serves); insecure mode patches `server.insecure`. In **both** modes,
  `argocd-server` is exposed as its **own `type: LoadBalancer`** (the KinD analog of the VKS
  L4 LB), the IP is discovered and published as **`ARGOCD_LB_IP`** to `.env.kind`. ArgoCD is
  **not** fronted by the shared `*.vks.local` ingress — VKS gives it its own LB.
- **Ingress:** the `argocd` route was removed from `k8s/istio/gateway.yaml`,
  `k8s/traefik/ingress.yaml`, and the `${ARGOCD_HOST}`/`${ARGOCD_NAMESPACE}` allowlist entries
  in `46-install-istio.sh` / `45-install-traefik.sh`. `98-verify-ingress.sh` no longer
  route-checks `argocd.vks.local` (keeps gitea/app/tekton).
- **`scripts/creds.sh`:** ArgoCD URL = `https://<ARGOCD_LB_IP> (self-signed; --insecure)`
  when `ARGOCD_LB_IP` is set; Harbor scheme = `https` unless `HARBOR_INSECURE=1`.

## What stays the same

- **Gitea / Tekton Dashboard / javawebapp app** — ours; HTTP behind the `*.vks.local` ingress.
- The **pipeline flow** (git push → Tekton → Harbor → write-back → ArgoCD → app) is unchanged;
  only the *transport* to Harbor (HTTP→HTTPS+CA) and ArgoCD's UI TLS change.
- `cloud-provider-kind` LoadBalancers, the mirror engine (`crane`), the offline builder.

## Validation

Clean `make e2e-kind` with **no concurrent load** (registry-corruption lesson).

**`secure` mode — VALIDATED end-to-end green** (clean `make kind-down && make e2e-kind`,
2026-07-10), all sudo-free:

1. `make mirror` — **34 images crane-pushed** to `https://<lb-ip>` over TLS via `SSL_CERT_FILE`
   (no `--insecure`).
2. `make builder-image` — builder pushed to Harbor over TLS via podman `--cert-dir`.
3. Kaniko `build` — app image built + pushed to `https://<lb-ip>` over TLS via the mounted
   `additional-ca-cert-bundle` (no `--skip-tls-verify`).
4. containerd — the javawebapp Deployment pulled `<lb-ip>/apps/javawebapp:<sha>` over TLS with the node
   `certs.d` CA.
5. ArgoCD — reachable over self-signed TLS on its own LB IP; the GitOps sync rolled the image.
6. `make verify` (`End-to-end verified`) + `make verify-ingress` (`SUCCESS`) green.

**`insecure` mode — VALIDATED 2026-07-12** via
`make kind-down && make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1`, as part of the full e2e
permutation matrix. It genuinely ran the insecure branch (the install log states
`Harbor mode: INSECURE (plain HTTP LoadBalancer)` and `ArgoCD mode: INSECURE (server.insecure,
plain HTTP)` — the mode is read from the log, never inferred from a green exit) and reached the
real end state: the deployed page served the new marker, all three `*.vks.local` UIs 200 through
the ingress, `PSA OK`. Both modes must keep passing so neither branch rots; both are local-only
(e2e-kind is not a CI job).

A failure at any secure-mode layer is exactly the lab-predictive signal we want (a missing
CA-trust hop).

## Fidelity vs a real VCF/VKS 9.1 lab (readiness — researched + empirically fact-checked)

Two things ground this section: (a) primary-source research on how VCF/VKS 9.1 provides
Harbor + ArgoCD, and (b) **empirical version checks of the actual lab CLIs** the operator
holds (installed via `make install-vcf-clis`).

> **CORRECTION (2026-07-11) — read this before trusting the version claims below.**
> This section originally argued: "the 9.0 docs imply a 2.14.x ArgoCD, but the real 9.1 `argocd`
> CLI is 3.x, so our KinD ArgoCD is the *right generation*." **That inference was wrong.** A
> client/server tool's **CLI version is not its SERVER version**: the ArgoCD **server** is a **2.14.x**
> line (the 9.1 Supervisor RN cites **v2.14.13**; `2.14.15` was only the 9.0 doc's example), while the
> shipped **CLI** is `v3.0.19-vcf` (**3.x**). Both facts are true; they describe *different things*.
> Our KinD stand-in runs a **3.x server**, so a real server-generation delta DOES exist — it is a
> known fidelity gap, not a match. `make argocd-preflight` reports all three (CLI, running server
> image, `kubectl explain argocd.spec.version`) so this cannot be guessed at again.

**Ground-truth versions (verified):** lab `argocd` CLI = **`v3.0.19+d67e6eb90-vcf`** (built
2025-12-02); `vcf` (VCF Consumption CLI) = **`v9.1.0.0.25296329`** (GA, 2026-03-20). VKS 9.1
Harbor ≈ **2.14.3** (`_vmware` build); ArgoCD provisioned by the Broadcom Argo CD Operator
(GA Jul 2025), upstream 3.x-era in 9.1.

**What our KinD stand-in faithfully predicts (green KinD ⇒ likely-green lab):**

- **The self-signed-TLS + CA-trust transport** across all four consumers (crane `SSL_CERT_FILE`,
  podman `--cert-dir`, node containerd `certs.d ca=`, Kaniko `additional-ca-cert-bundle`) over
  real HTTPS/443. A missing-CA hop fails KinD exactly as it would fail the lab.
- **ArgoCD exposure/auth**: own LoadBalancer reached by IP, self-signed TLS on 443,
  `argocd login <ip> --insecure` (IP-SAN warning), admin from `argocd-initial-admin-secret` —
  all match VKS 9.1. **NOT the server generation**: KinD runs ArgoCD **3.x** while the lab's
  operator CR pins a **2.14.x** server (the 9.1 RN cites v2.14.13) — see the CORRECTION above.
- **The GitOps loop shape**: push → Tekton → Harbor → tag write-back → ArgoCD sync → app roll.

**What a green KinD run does NOT prove (residual lab risk — verify on the real lab):**

1. **The VKS workload-cluster CA-trust MECHANISM.** The lab does NOT hand-edit
   `certs.d/hosts.toml`. It trusts the Harbor CA declaratively via the Cluster (v1beta1) spec
   `variables: [{name: trust, value: {additionalTrustedCAs: [{name: …}]}}]`, backed by a
   **`<CLUSTER-NAME>-user-trusted-ca-secret`** in the vSphere Namespace holding the CA
   **double-base64-encoded** (`base64 -w0 ca.crt | base64 -w0`). The secret is **not watched**
   (CA rotation needs a new secret + a cluster-spec update). Our per-node `certs.d` reaches the
   same end state by a non-transferable route — the most likely real-lab failure (wrong
   encoding, wrong namespace, un-reapplied rotation) is invisible to KinD.
2. **Private projects / robot accounts.** We make Harbor projects public (anonymous pull). A
   private VKS Harbor project needs a **robot account + `imagePullSecret`** — a path we don't
   exercise.
3. **FQDN/DNS addressing.** The lab is FQDN-addressed (ExternalDNS + VIP, cert SAN=FQDN); we
   use the LB **IP** (SAN=IP) for the sudo-free reasons above. Fine for TLS, but any downstream
   assuming an IP-shaped `HARBOR_URL` would break on the FQDN lab — treat `HARBOR_URL` as opaque.
4. **Provisioning is operator/CR-driven, not manifest-driven.** The lab creates a Harbor
   Supervisor Service + an `argocd-service.vsphere.vmware.com/v1alpha1` `ArgoCD` CR
   (`enableLoadBalancer: true`, `spec.version: <3.x>+vmware.1-vks.1`) via the Broadcom operators;
   our `06`/`07` install helm/upstream to mimic the *runtime*, not the provisioning (correct —
   those scripts don't run against a real lab).

**Sources:** [Harbor as a Supervisor Service (TechDocs)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html),
[Air-gapped Harbor in VCF 9 (VCF blog)](https://blogs.vmware.com/cloud-foundation/2026/04/21/deploying-harbor-service-in-air-gapped-vmware-cloud-foundation-9-0/),
[Integrate TKG clusters with a private registry — the `trust.additionalTrustedCAs` path (TechDocs)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html),
[williamlam — VKS self-signed registry trust](https://williamlam.com/2025/08/quick-tip-configuring-vsphere-kubernetes-service-vks-cluster-with-self-signed-container-registry.html),
[Broadcom Argo CD Operator GA](https://blogs.vmware.com/cloud-foundation/2025/07/11/gitops-for-vcf-broadcom-argo-cd-operator-now-available/),
[Install the Argo CD Service (TechDocs)](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html).

**Actionable follow-ups (low-risk, tracked):** (T1) after the secure Harbor upgrade, assert the
CA served by Harbor's own `GET /api/v2.0/systeminfo/getcert` matches our minted CA (exercises the
real CA-retrieval path); (T2 — done here) document the `trust.additionalTrustedCAs` delta; (T3)
guard that no IP-shaped `HARBOR_URL` literal is hardcoded downstream (keep the FQDN swap safe);
(T4, optional) a `HARBOR_PUBLIC_PROJECTS=0` matrix exercising a robot account + `imagePullSecret`.

## Risks / notes

- **openssl vs cert-manager:** we mint with openssl for determinism; a `cert-manager +
  self-signed ClusterIssuer` variant would mimic the *minting mechanism* too, at the cost of
  adding cert-manager to the KinD stack. End-state cert posture is identical. Decision:
  openssl now; revisit cert-manager only if we want to test cert *rotation*.
- **LB IP churn:** the CA is stable but the leaf's SAN tracks the current LB IP (regenerated
  each run), so a cluster rebuild that reassigns the IP re-mints the leaf transparently.
- **Scope:** Harbor + ArgoCD only (the VKS-provided pair). One PR, staged internally
  (Harbor first, then ArgoCD, then docs), validated by one clean `e2e-kind`.
