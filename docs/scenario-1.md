# VKS — Scenario 1: you install Harbor & ArgoCD

You have a **Supervisor** endpoint, a login, and a password. You install **Harbor** and **ArgoCD**
as **Supervisor Services**, provision a **guest VKS cluster**, and run the pipeline into it. The jump
box is dual-homed (internet + lab).

> **Topology.** Harbor + ArgoCD run on the **Supervisor**; Gitea, Tekton and your app run in the
> **guest cluster**. Different clusters, different kubeconfigs. Istio is a guest-cluster package, not
> a Supervisor Service (Step 11).

**Auth, in one sentence:** you use the `vcf` CLI to build the lab (Steps 3–4 and 8) and to export a
guest kubeconfig; the pipeline then runs against that kubeconfig (`VKS_AUTH_METHOD=kubeconfig`). Both
surfaces are needed and that is intentional.

**Versions here are illustrative.** The one that matters is your Supervisor's **running ArgoCD
server**, not the `argocd` CLI or this repo's KinD pin. `make argocd-version` prints all three (exits
0, no cluster needed); `make argocd-preflight` (Step 8) adds the server number once the cluster is up.

## Downloads (each needs your Broadcom entitlement)

| Artifact | Version | |
|---|---|---|
| **VCF Consumption CLI** — the Linux `_AMD64`/`_ARM64` archive for your jump box | **9.1.0.0400** | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true) |
| **VCF Consumption CLI Plugins** — the Linux `_AMD64`/`_ARM64` bundle | **9.1.0.0400** | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true) |
| **ArgoCD Service** — the `-legacy` manifest + the amd64 `argocd` CLI (`v3.0.19-vcf`) | **1.1.0** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN) |
| **Harbor** — the `-legacy` manifest + its data-values file | **2.14.3** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN) |

**Where each goes:**

- **CLI + Plugins + the `argocd` CLI** → one folder (e.g. `~/Downloads/vcf`); set **`VCF_CLI_SRC_DIR=<folder>`** — `make install-vcf-clis` reads it and picks your OS/arch (§1). *(arm64: the VCF `argocd` is amd64-only — use the upstream one from `make deps`; [details](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives).)*
- **ArgoCD Service + Harbor** are Supervisor-Service YAMLs — uploaded in **§2**/**§3**, not via the installer.

## 1. Jump box

**Goal:** the toolchain, the licensed `vcf` CLI, and a blank `.env`. Step 3 uses `vcf`, so install it now.

```bash
make env-init                                         # a blank .env from .env.example
make deps                                             # mise toolchain (kind, crane, tkn, kubectl, helm…)
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf # the licensed argocd-vcf + vcf + plugins (sudo-free)
make check-tools                                      # what you have, what is missing
```

> Don't have the archives yet? See [Acquiring the licensed VCF CLI archives](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives) — portal source, the per-arch manifest, and the arm64 argocd fallback.

**Result:** `check-tools` lists no missing **required** CLI.

**Then edit `.env`** — these keys already exist there (commented, from `.env.example`); uncomment and set:

| key | value |
|---|---|
| `SUPERVISOR_HOST` | Supervisor Control Plane IP (vCenter → Workload Management → Supervisors). Bare host, no scheme. |
| `VKS_CONTEXT_NAME` | a name you choose for the `vcf` context, e.g. `sup` — passed positionally in Steps 3–4. |
| `VKS_NAMESPACE` | the **workload** vSphere Namespace where you create the guest cluster (Step 4). |
| `VKS_CLUSTER_NAME` | the guest cluster you create in Step 4. |
| `VKS_USERNAME` | *optional* — defaults to `administrator@wld.sso` (announced at login). Set it if your SSO domain differs, e.g. `administrator@vsphere.local`. |

> The Supervisor **password is never in `.env`** — you enter it at the `vcf context create` prompt
> (Step 3), or `export VCF_CLI_VSPHERE_PASSWORD` for the session. ⛔ **Never `vcf config set
> env.VCF_CLI_VSPHERE_PASSWORD …`** — it writes the password **plaintext** to
> `~/.config/vcf/config.yaml`, outside the repo, invisible to gitleaks, and it survives teardown.

**Ran the local KinD flow on this box before?** `make state-show` then `make kind-down` — a stale
overlay is sourced after `.env` and would silently redirect everything at a kind cluster. (It is
archived, not deleted, if it belongs to a *different* cluster — it may hold that cluster's passwords.)

## 2. Harbor — a Supervisor Service (browser)

**Goal:** the registry every image is pulled from. Browser work — not scriptable.
[Broadcom: Installing and configuring Harbor and Contour](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html).

1. **Expose it** — Harbor needs an LB/ingress. Pick an **NGINX LB** or **Contour** (a Supervisor
   Service; install it *before* Harbor).
2. **Register:** Supervisor Management → Services → Add New Service → upload the Harbor manifest — `supervisor-service-harbor-legacy-*.yml` for a disconnected/air-gapped Supervisor (or the `-depot` variant if it reaches the Broadcom depot).
3. **Edit the data-values file** (placeholders verified against **v2.14.3**; a later version may rename
   keys, and `sed` silently changes nothing on a non-match — re-check if your version differs):

   ```bash
   cp ~/Downloads/vcf/supervisor-service-harbor-data-values-v2.14.3.yml harbor-values.yaml
   sed -i \
     -e 's/hostname: yourdomain.com/hostname: harbor.vcf.lab/' \
     -e 's/enableNginxLoadBalancer: false/enableNginxLoadBalancer: true/' \
     -e 's/enableContourHttpProxy: true/enableContourHttpProxy: false/' \
     -e 's/insert-storage-class-name-here/vsan-default-storage-policy/' \
     harbor-values.yaml
   # the two LB toggles are mutually exclusive; set BOTH false for a plain Ingress instead.
   ```

   Then replace **every `[Required]` secret by hand** (make them distinct): `harborAdminPassword`
   (ships the known default `Harbor12345`) · `secretKey` (**16 chars**) · `core.xsrfKey` (**32 chars**)
   · and `database.password`, `core.secret`, `jobservice.secret`, `registry.secret`. Leave
   `tls.crt`/`tls.key`/`ca.crt` empty (cert-manager self-issues); do **not** touch
   `tlsCertificate.tlsSecretLabels` (`managed-by: vmware-vRegistry`, required for VKS trust).
4. **Apply (browser):** Supervisor Management → Services → Harbor → Actions → Manage Service → pick
   version + Supervisor → paste `harbor-values.yaml` → Finish.
5. **Map the FQDN with real DNS** the **guest cluster's nodes** can resolve — `kubectl get svc -n
   <harbor-ns>` for the ingress IP, then create the record.

> **DNS, not `/etc/hosts`.** Every kubelet on the guest cluster pulls from `$HARBOR_URL` and cannot
> see the jump box's hosts file. With only a hosts entry, `make mirror` succeeds and every workload
> `ImagePullBackOff`s later. **No DNS?** Use Harbor's **LB IP** as `HARBOR_URL` — but the cert must
> then carry an **IP SAN** (Go rejects a DNS-only cert on an IP URL even when the CA is trusted).

**Result:** Harbor's UI answers at your FQDN. (That the guest nodes can *resolve and trust* it is
proven later, by Step 9's `make verify` pulling the app image into the guest.)

**→ `.env`:**

| key | value |
|---|---|
| `HARBOR_URL` | the hostname you set — no scheme, no trailing slash |
| `HARBOR_USERNAME` | `admin` (or a robot — Step 7) |
| `HARBOR_PASSWORD` | your `harborAdminPassword` — `.env` only, never argv |
| `HARBOR_CA_FILE` | `./secrets/harbor-ca.crt` (fetched in Step 6) |
| `HARBOR_INFRA_PROJECT` / `HARBOR_APP_PROJECT` | `cicd` / `apps` |

## 3. ArgoCD — Operator + instance (Supervisor, `kubectl`)

**Goal:** the GitOps engine, running **on the Supervisor**.
[Broadcom: Install Argo CD Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html).

1. Install the **ArgoCD Operator** Service — same flow as Harbor (upload `supervisor-service-argocd-legacy-*.yml` for a disconnected/air-gapped Supervisor, or the `-depot` variant if it reaches the Broadcom depot).
2. Create a **vSphere Namespace** for the instance (e.g. `argocd-instance-1`) with VM + storage classes.
3. **Load `.env` into your shell** so the raw `$VAR` commands in this step and Step 4 resolve —
   `make` sources `.env` for you, an interactive shell does **not**. Re-run after any `.env` edit:

   ```bash
   set -a; . ./.env; set +a
   ```

4. **Authenticate to the Supervisor** (interactive password prompt; nothing secret on argv):

   ```bash
   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --insecure-skip-tls-verify --auth-type basic
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"     # note the <ctx>:<ns> COLON form
   ```

   > ⚠️ **TWO FORMS.** The form above is the one **lab-verified** on a 9.1 Supervisor (positional
   > name, bare endpoint). The repo's `make vks-login` additionally passes `--username`+`--type
   > kubernetes`, which is **not** lab-verified — if either flag is rejected, the form above is
   > known-good; confirm with `vcf context create --help`. (vSphere 8: `kubectl vsphere login
   > --server $SUPERVISOR_HOST`.)

5. **Pick a supported version and apply the CR** (`kubectl explain argocd.spec.version` lists what
   your operator supports):

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: argocd-instance-1 }
   spec: { version: <supported-version> }
   ```

6. **Get its LB IP + admin password, and log in:**

   ```bash
   kubectl get svc -n argocd-instance-1                     # argocd-server → EXTERNAL-IP
   kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d
   argocd login <LB-IP>                                     # accept the self-signed cert
   argocd account update-password
   ```

**Result:** `argocd-server` has an EXTERNAL-IP and you can log in.

**→ `.env`:**

| key | value |
|---|---|
| `ARGOCD_NAMESPACE` | `argocd-instance-1` — the vSphere Namespace the instance runs in |
| `ARGOCD_SERVER` | the `argocd-server` LB IP |
| `ARGOCD_TRACK_BRANCH` | `main` |
| `ARGOCD_CA_FILE` | *optional* — `./secrets/argocd-ca.crt` (`make fetch-argocd-ca`) |

## 4. Guest VKS cluster

**Goal:** where Gitea, Tekton and your app run. You need **cluster-admin** on it.

Create a vSphere Namespace, provision a VKS cluster in it, then export its kubeconfig:

```bash
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"    # Step 3 left the context on the ArgoCD ns; switch it
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file ./secrets/vks.kubeconfig
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
```

> ⚠️ **UNVERIFIED-COMMAND** — `vcf cluster kubeconfig get` is the doc-inferred 9.1 form; confirm with
> `--help` if it errors. Also: **`-n` means different things across `vcf` subcommands** (`vcf package`
> → a guest-cluster namespace; `vcf addon` → the vSphere Namespace) — never copy one's `-n` into another.

**Result:** nodes listed.

**→ `.env`:**

| key | value |
|---|---|
| `KUBECONFIG` | `./secrets/vks.kubeconfig` |
| `VKS_CONTEXT` | the context name inside that kubeconfig |
| `VKS_AUTH_METHOD` | `kubeconfig` — the pipeline runs against the kubeconfig you just exported |
| `GITEA_ADMIN_PASSWORD` | you choose it — Gitea is ours to install |

## 5. Preflight — will this cluster accept our install?

**Goal:** catch the four things that each kill the run *after* a 20-minute mirror.

```bash
make vks-login       # validates KUBECONFIG + context
make lab-preflight   # CRD-create · a DEFAULT StorageClass · a working LoadBalancer provider
make psa-check       # (see below)
```

**Result:** `lab-preflight` → **`LAB PREFLIGHT OK`**; `psa-check` → **`PSA UNPROVEN`** — which is the
**correct** answer now, not a pass.

> **PSA.** VKS enforces the `restricted` Pod Security Standard by default (VKr v1.26+), which rejects
> our Kaniko build pods unless their namespaces are labelled `baseline`. Our installers apply the
> measured labels — but none of our namespaces exist yet, so `psa-check` has nothing to measure. It
> proves itself only **after `make platform`** (Step 9), where it is wired into `make preflight`.

## 6. Harbor's CA

**Goal:** Harbor is self-signed; `crane` (jump box) and Kaniko (in-cluster) must trust it.

```bash
make fetch-harbor-ca      # HARBOR_URL → HARBOR_CA_FILE
```

**Result:** `VERIFIED: the file we wrote actually validates <host>'s certificate` — it keeps the
issuer from the presented chain and `openssl verify`s the leaf, deleting the file and dying if that
fails. `make mirror` and `make platform` then wire it into `SSL_CERT_FILE` and the in-cluster
`harbor-ca` ConfigMap for you. (Publicly-trusted cert? Leave `HARBOR_CA_FILE` empty.)

> **Manual alternative:** Harbor UI → project → Registry Certificate downloads `ca.crt`; save it as
> `HARBOR_CA_FILE` and strip any trailing `<CR>` (it breaks the PEM parse).

<details><summary><b>If Harbor is on a DIFFERENT Supervisor, or its project is PRIVATE</b></summary>

Same-Supervisor guest clusters auto-trust Harbor's cert. Otherwise add the CA to the Cluster spec
`trust.additionalTrustedCAs`, **double**-base64 encoded: `base64 -w0 harbor-ca.crt | base64 -w0`
([William Lam](https://williamlam.com/2024/06/using-a-vsphere-kubernetes-service-vks-cluster-with-a-private-container-registry.html); verify on your 9.1 lab — not reproducible on KinD).
</details>

## 7. A least-privilege Harbor robot (recommended)

**Goal:** CI pushes with a scoped credential instead of `admin`.

```bash
make harbor-robot     # → secrets/harbor-robot.env (0600, never printed); copy its two lines into .env
```

**Result:** a `robot$vks-cicd` account scoped to the `cicd` + `apps` projects. `make harbor-robot`
(and `make mirror`) create those projects if you may — public by default (`HARBOR_PUBLIC_PROJECTS=false`
for private). `make gitops` creates the `harbor-pull` secret in each app namespace either way, and
`make check-pull-secret-alignment` gates that the Deployment asks for the secret the flow creates.

## 8. The Supervisor kubeconfig ArgoCD needs

**Goal:** `make gitops` talks to **both** clusters — ArgoCD on the Supervisor, your app in the guest.
Step 4 gave you the guest one; this gives you the Supervisor one.

**→ `.env` FIRST** (both commands below consume these):

| key | value |
|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` — where `fetch-argocd-kubeconfig` writes; `make gitops` reads it. **Unset, it defaults to the *guest* kubeconfig → `gitops` deploys onto the Supervisor.** |
| `VKS_INSECURE_SKIP_TLS_VERIFY` | `true` — or set `VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt` (preferred). `fetch-argocd-kubeconfig` **dies** without one. |

```bash
make fetch-argocd-kubeconfig    # interactive: prompts for your password
make argocd-preflight           # CLI vs SERVER versions + can ArgoCD actually deploy to your cluster?
```

**Result:** `$ARGOCD_KUBECONFIG` is written, and `argocd-preflight` prints **`PREFLIGHT OK`** and
**`ArgoCD is OFF-CLUSTER (the real-lab shape)`** — the line that proves the two-cluster topology was
detected.

## 9. Validate `.env`, then install

**Goal:** catch a wrong value in seconds, not 20 minutes into the mirror.

```bash
make env-populate   # mint the Gitea secret; discover any endpoint you left blank
make env-check      # presence gate — every required value set? (fast, no network)
make env-validate   # validity gate — does KUBECONFIG reach the cluster, does Harbor authenticate?
```

**Result:** `env-check` → all required present; `env-validate` → Harbor reachable **and authenticated
over HTTPS with your CA** (the honest check on Step 6 — a bad CA fails here, not inside Kaniko later).

**One fork — can this jump box reach BOTH the internet and Harbor?** `make install-all` runs
`make mirror`, which pulls from the internet and pushes to Harbor in one command.

| your jump box | what you run |
|---|---|
| reaches the internet **and** Harbor (**dual-homed**) | `make install-all` below |
| reaches the **internet only** | **[the sneakernet flow](sneakernet.md)** — two boxes; it replaces `install-all`. Do not come back here. |

> **Lab has internet everywhere (guest cluster too)?** Scenario 1 runs **unchanged** — Harbor is
> still the pipeline's registry and the mirror still runs; the air gap is simply **not exercised**.
> `make verify-gateway-image` (Step 11) still proves the mirror was actually used.
> *(inferred-from-code; not lab-verified.)*

```bash
make install-all   # preflight → mirror → mirror-verify → builder-image → vks-login → platform → gitops
make psa-check     # NOW it measures — expect `PSA OK — … (N measured)`, not `PSA UNPROVEN`
make verify        # push a marked change → Tekton → Harbor → ArgoCD → the live app serves it
```

**Result:** `make verify` exits **0** — the app serves the new version. `make gitops` **registers
your guest cluster** as an ArgoCD destination and points the `Application` at it; it never installs a
second ArgoCD and never deploys onto the Supervisor.

> **Real-lab caveats.** If ArgoCD reaches your guest by a VIP that differs from your kubeconfig's
> server URL, `make gitops` stops rather than guess — set `ARGOCD_DEST_CLUSTER_NAME=<the name ArgoCD
> registered>` and re-run. And run `make mirror` **alone** (it mutates a shared cluster + registry, so
> parallel work makes any failure unattributable); it ends in `mirror-verify` — an unverified push is
> not a mirror.

## 10. Access the UIs

**Goal:** every URL and login for this context, without re-typing a value you already set.

```bash
make creds-show
```

**Result:** a table of Harbor, ArgoCD, Gitea, the Tekton dashboard **and one row per app** (generated
from `apps/registry.tsv`, so it lists every app the repo ships), plus the exact `/etc/hosts` line for
the ingress hosts. Prefer port-forward?

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000
kubectl -n <app> port-forward svc/<app> 18080:80     # <app>: any name in apps/registry.tsv
```

## 11. Ingress (optional)

**Goal:** reach Gitea, Tekton and the app at `*.vks.local` instead of port-forwarding.

You own this cluster, so unless you installed Istio yourself it has none (Istio is *available* as a
VKS package — available is not installed). **Ask the cluster:**

```bash
make istio-preflight     # read-only; on a fresh cluster: "NO Istio detected → INSTALL it"
```

| It says | You run |
|---|---|
| **NO Istio detected** (normal) | `make install-ingress` — installs Istio (control plane + one gateway LB) from **your Harbor**, and `make verify-gateway-image` proves it by reading each running Istio image. Worth it on a dual-homed box, where a silently-ignored `--set global.hub` (helm accepts an unknown key, rc=0) would otherwise leave the air gap unproven. `INGRESS_CONTROLLER=traefik` for a lighter option. |
| **Istio already here** | `make install-ingress INGRESS_CONTROLLER=istio-existing` — installs nothing, attaches routes only. |

Add the printed `INGRESS_LB_IP` to `/etc/hosts` (see [Access the UIs](access-uis.md)).
`make install-ingress` is a **demo ingress**, not the Broadcom-supported mesh, and needs **no internet
once `make mirror` has run** — `mirror-pull` carries the Istio charts into `bundle/charts`:

| `bundle/charts` state | behaviour |
|---|---|
| charts carried | installs from them, **no network** |
| bundle exists, no charts | **dies** — re-cut with `make mirror-pull && make bundle` (it will not silently reach the internet) |
| no bundle | fetches from `istio-release.storage.googleapis.com` (needs internet, says so) |

<details><summary><b>Alternative: install the VKS Istio package, then attach (VKS-faithful — NOT validated by us)</b></summary>

Transcribed from Broadcom's **9.0** docs — **never run verbatim on a 9.1 lab.** Two CLI surfaces
exist; check `vcf addon available list` first.

- **Legacy package CLI:** `vcf package repository add …` → `vcf package available get
  istio.kubernetes.vmware.com -n tkg-system` → `… --default-values-file-output istio-data-values.yaml`
  → `kubectl create ns istio-installed` → `vcf package install istio -p istio.kubernetes.vmware.com -v
  <ver> --values-file istio-data-values.yaml -n istio-installed`. Here `-n` = a **guest-cluster** ns.
- **Add-on CLI** (9.1 / VKS 3.7+): `vcf addon install create istio --cluster-name <cluster> …`. Here
  `-n` = the **vSphere Namespace** — opposite meaning; do not copy the flag across.

⚠️ **UNVERIFIED and load-bearing:** the package's own istiod/proxy images come from Broadcom's
registry, which an air-gapped guest cannot reach; this repo does not mirror or repoint them. The
package's shared ingress gateway is **off by default** (correct — `istio-existing` routes with the
Kubernetes Gateway API and lets Istio provision the proxy + LB), which needs the Gateway API CRDs
present (`kubectl get crd httproutes.gateway.networking.k8s.io`). See
[the decision record](decisions/istio-via-vks-package.md) for why we do not install this way.
</details>

## Preconditions, in one place

- **cluster-admin** on the guest cluster (we create namespaces and install Tekton CRDs).
- A **default StorageClass** (Gitea's PVC) and a working **LoadBalancer** provider.
- **Network reach from the jump box:** the internet, the **Supervisor** API, the **guest** API, and **Harbor**.
- **ArgoCD must be able to clone Gitea.** ArgoCD is on the Supervisor, so `gitea-http.gitea.svc` does
  not resolve there — Gitea gets its **own LoadBalancer** and `make install-gitea` publishes
  `GITEA_ARGOCD_URL`. The ingress hostname is not usable for this. `make gitops` refuses a repoURL
  ArgoCD cannot reach.
- **No stale state overlay** at the start (Step 1).

---

[← back to the README](../README.md)
