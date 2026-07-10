# KinD TLS fidelity — mimic VCF/VKS 9.1 self-signed TLS for Harbor + ArgoCD

**Status:** PROPOSED (awaiting review; implement after approval)
**Date:** 2026-07-10

## Problem

The local KinD stand-in currently presents the **opposite** TLS posture to a real
VCF/VKS 9.1 lab, so a green `make e2e-kind` does **not** exercise the self-signed-TLS +
CA-trust path the lab actually requires:

| Component | KinD today | Real VKS 9.1 lab |
|-----------|-----------|------------------|
| **Harbor** | plain **HTTP** LB; containerd `skip_verify = true`; Kaniko `--skip-tls-verify` | **HTTPS/443**, self-signed cert (cert-manager), clients trust its CA |
| **ArgoCD** | patched `server.insecure=true` (plain HTTP) | **self-signed TLS/443** (`server.insecure` is *not* the default), reached by LB IP with `--insecure` |

The whole point of the KinD path is to predict lab behavior. Today it hides exactly the
class of failure most likely on a real air-gapped lab: a self-signed registry cert that
every consumer (jump-box `crane`, node `containerd`, in-cluster Kaniko) must trust.

**Goal:** make KinD mimic the lab's cert posture *exactly*, so "works on KinD" means
"the CA-trust wiring works" — not "TLS was skipped".

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
  server `--insecure` / `server.insecure` = "serve **no** TLS" (what KinD wrongly does today).
- Sources: [VMware Argo CD Operator install](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html),
  [vSphere Supervisor 9.1 release notes](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vsphere-supervisor-release-notes.html),
  [Argo CD upstream TLS docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/).

**Honesty note:** the 9.1-exact cert internals are not published field-by-field (9.1 docs
are redirect-gated; field detail is the 8.0 package reference + 9.0 pages, behaviorally
identical for Harbor/ArgoCD). Both models rest on the cert-manager-self-signed default +
upstream defaults. A given lab *may* have been handed a custom/CA-signed instance — the
design below trusts a **CA we control**, which covers both (a self-signed leaf under our CA
is the faithful default; a lab-CA-signed cert is the same trust mechanism, different issuer).

## Design — mimic on KinD (exact per-file changes)

Only **Harbor** and **ArgoCD** are VKS-provided, so only they change. Gitea, Tekton, the
Tekton Dashboard and the webui app are *ours* — they stay HTTP behind the `*.vks.local`
ingress (no VKS cert contract on them).

### Cert minting (both)

Generate a **self-signed CA + leaf cert** with `openssl` (deterministic, no extra
cert-manager dependency in the KinD stack — same *end state* as cert-manager's self-signed
default; noted as a deliberate simplification). One CA, leaf SANs cover the FQDN **and** the
LB IP. New helper: `scripts/lib/tls.sh` (`gen_selfsigned_ca_cert <cn> <san-dns> <san-ip> <out-dir>`).

### Harbor → self-signed HTTPS + CA trust

Endpoint becomes the FQDN **`harbor.vks.local`** (cert SAN = `DNS:harbor.vks.local` +
`IP:<LB_IP>`), matching the lab's FQDN-with-SAN model.

- **`scripts/06-install-harbor.sh`:**
  - after the LB IP is assigned, mint the CA+leaf (SAN = `harbor.vks.local` + LB IP), write
    the CA to `HARBOR_CA_FILE` (`secrets/harbor-ca.crt`), create the Harbor TLS secret.
  - install Harbor with `expose.tls.enabled=true`, `expose.tls.certSource=secret`,
    `externalURL=https://harbor.vks.local`.
  - wire each node's containerd from `skip_verify` to **`server = "https://harbor.vks.local"`**
    with a **`ca = ".../ca.crt"`** line in `/etc/containerd/certs.d/harbor.vks.local/hosts.toml`,
    and add `LB_IP harbor.vks.local` to each node's `/etc/hosts`.
  - patch **CoreDNS** (a `hosts` block: `LB_IP harbor.vks.local`) so in-cluster pods (Kaniko,
    the webui Deployment) resolve the FQDN → the Harbor LB IP.
  - `.env.kind`: `HARBOR_URL=harbor.vks.local`, **`HARBOR_INSECURE=0`**,
    `HARBOR_CA_FILE=secrets/harbor-ca.crt` (was `HARBOR_INSECURE=1` + LB-IP URL).
- **`tekton/tasks/kaniko-build.yaml`:** drop `--skip-tls-verify --insecure`; mount the
  `harbor-ca` ConfigMap to `/kaniko/ssl/certs/additional-ca-cert-bundle.crt` (Kaniko appends it
  to its trust bundle).
- **`make platform` (`60-configure-tekton.sh`)** already creates the `harbor-ca` ConfigMap
  from `HARBOR_CA_FILE` — in KinD it was empty; now it's populated, so no new code, it just
  starts carrying a real CA.
- **Jump box:** `make mirror` / `make vks-login` already `trust_ca` the CA into the system
  store (for `crane` push over HTTPS) — again already in the lab flow, now exercised in KinD.
- **Alignment:** image refs switch from the raw LB IP to `harbor.vks.local` (the
  `check-image-alignment` gate and `HARBOR_URL` consumers already parameterize on `HARBOR_URL`,
  so this is a value change, not new drift).

### ArgoCD → self-signed TLS via its own LoadBalancer

- **`scripts/07-install-argocd.sh`:** remove the `server.insecure=true` patch; leave upstream
  TLS on (self-signed cert on 443). Expose `argocd-server` as **`type: LoadBalancer`**
  (cloud-provider-kind assigns an IP — the KinD analog of the VKS L4 LB). Optionally install an
  `argocd-server-tls` secret from our CA with SAN = the LB IP + `argocd.vks.local` for a stable
  cert (still self-signed under our CA — a superset of the VKS default).
- **Ingress:** remove the `argocd` VirtualService/route from `k8s/istio/gateway.yaml`,
  `k8s/traefik/ingress.yaml`, and the `${ARGOCD_HOST}`/`${ARGOCD_NAMESPACE}` allowlist entries
  in `46-install-istio.sh` / `45-install-traefik.sh`. VKS does **not** front ArgoCD behind the
  shared ingress — it's its own LB. (This also resolves the `argocd.vks.local` conflation the
  README just documented.)
- **`scripts/creds.sh`:** ArgoCD URL becomes `https://<argocd LB IP>` (self-signed) instead of
  `http://argocd.vks.local`; note `--insecure` for the CLI. `argocd-password.sh` unchanged.

### Verify / verify-ingress

- **`scripts/99-verify.sh`:** the pipeline mechanics are in-cluster (unaffected). The webui
  page check via the ingress (`app.vks.local`, HTTP) is unaffected. No Harbor HTTPS curl is on
  the critical path, but add a `crane manifest`/`curl --cacert` smoke against Harbor to prove
  the CA trust end-to-end.
- **`scripts/98-verify-ingress.sh`:** drop the `argocd.vks.local` route-check (ArgoCD no longer
  behind the ingress); keep gitea/app/tekton. Add an ArgoCD-over-its-LB-IP TLS reachability
  check (`curl -k https://<ip>` or `argocd version --server <ip> --insecure`).

## What stays the same

- **Gitea / Tekton Dashboard / webui app** — ours; HTTP behind the `*.vks.local` ingress.
- The **pipeline flow** (git push → Tekton → Harbor → write-back → ArgoCD → app) is unchanged;
  only the *transport* to Harbor (HTTP→HTTPS+CA) and ArgoCD's UI TLS change.
- `cloud-provider-kind` LoadBalancers, the mirror engine (`crane`), the offline builder.

## Validation plan

Clean `make e2e-kind` with **no concurrent load** (registry corruption lesson). It must prove:

1. `make mirror` — `crane` pushes to `https://harbor.vks.local` over TLS, trusting the CA from
   the jump-box store (no `--insecure`).
2. Kaniko `build` — pulls the builder/runtime base **and** pushes the app image to
   `https://harbor.vks.local` over TLS, trusting the CA via the mounted ConfigMap (no
   `--skip-tls-verify`).
3. containerd — the webui Deployment pulls `harbor.vks.local/apps/webui:<sha>` over TLS with
   the node `certs.d` CA.
4. ArgoCD — reachable over self-signed TLS on its LB IP; the GitOps sync still rolls the image.
5. `make verify` + `make verify-ingress` green; a demo walk over the TLS Harbor.

A failure at any layer is exactly the lab-predictive signal we want (a missing CA-trust hop).

## Docs to update (ALL `*.md` + diagrams)

- **README.md:** the Access-the-UIs table (Harbor is now HTTPS+self-signed in **both** KinD
  and lab; ArgoCD is its own-LB self-signed TLS in both — the KinD-vs-lab gap shrinks to
  "we mint the cert locally"); the "Try it locally" Harbor-plain-HTTP prose; the demo-table
  Harbor/ArgoCD rows; step 6.
- **CLAUDE.md:** the architecture bullets ("Harbor as an HTTP LoadBalancer" → HTTPS+CA;
  "server.insecure local convenience" → self-signed TLS); the backlog.
- **Diagrams** (`docs/diagrams/*.puml`): any HTTP/insecure edge labels → HTTPS; re-render +
  `diagrams-check`.

## Risks / notes

- **CoreDNS hosts patch** is the one genuinely new mechanism (so in-cluster pods resolve the
  Harbor FQDN → its LB IP). Low-risk (a `hosts` plugin block), reversible.
- **openssl vs cert-manager:** we mint with openssl for determinism; a `cert-manager +
  self-signed ClusterIssuer` variant would mimic the *minting mechanism* too, at the cost of
  adding cert-manager to the KinD stack. End-state cert posture is identical. Decision:
  openssl now; revisit cert-manager only if we want to test cert *rotation*.
- **Scope:** Harbor + ArgoCD only (the VKS-provided pair). One PR, staged internally
  (Harbor first, then ArgoCD, then docs), validated by one clean `e2e-kind`.
