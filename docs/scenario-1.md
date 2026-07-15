# VKS — Scenario 1: you install Harbor & ArgoCD

You are given a **Supervisor** endpoint, a login, and a password. Nothing else. You install **Harbor**
and **ArgoCD** as **Supervisor Services**, provision a **workload (guest) VKS cluster**, then run
the pipeline into it. The jump box is dual-homed (internet + lab).

> **Topology — the thing to keep straight.** Harbor and ArgoCD run on the **Supervisor**. Gitea,
> Tekton and your app run in the **guest cluster**. They are **different clusters**, and several
> commands below need a kubeconfig for each. Istio is **not** a Supervisor Service — it is a
> guest-cluster package (see Step 7).

**Do not trust version numbers in this document.** Get the real ones from your cluster:
`make argocd-preflight`.

## Downloads (each needs your Broadcom entitlement)

| Artifact | |
|---|---|
| **VCF Consumption CLI** 9.1.0.0 | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true) |
| **VCF Consumption CLI Plugins** 9.1.0.0 | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true) |
| **ArgoCD Service** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN) |
| **Harbor** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN) |

Drop **all** the archives in one folder (e.g. `~/Downloads/vcf`) — the installer picks the right
OS/arch and ignores the rest.

## Step 0 — jump box

**For:** the toolchain, and the licensed `vcf` CLI. **A2 below uses `vcf`, so install it first.**

```bash
make env-init                                        # creates .env from .env.example
make deps                                            # mise toolchain (kind, crane, tkn, kubectl, helm…)
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf # the licensed argocd-vcf + vcf + plugins (sudo-free)
make check-tools                                     # what you have, what is missing
```

**Expect:** `check-tools` lists no missing **required** CLI.

**Then set these four in `.env`** (they drive the Supervisor login):

```bash
SUPERVISOR_HOST=<supervisor-control-plane-IP>   # vCenter → Workload Management → Supervisors
VKS_USERNAME=administrator@vsphere.local        # the Supervisor PASSWORD is NOT stored here — you enter it
                                                # INTERACTIVELY at `vcf context create` (step A2 below). Only the
                                                # VKS_AUTH_METHOD=vsphere fallback keeps VKS_PASSWORD in .env.
VKS_NAMESPACE=<vsphere-namespace>
VKS_CLUSTER_NAME=<the guest cluster you create in A3>
```

**Load `.env` into your shell** so the `$VAR` references in the raw commands below resolve (`.env` is
sourced automatically by `make` targets, but **not** by your interactive shell — re-run this whenever you
edit `.env`):

```bash
set -a; . ./.env; set +a
```

**Also — if you ever ran the local KinD flow on this box:** `make state-show` (whose state is this?)
then `make kind-down`. A stale overlay is sourced *after* `.env` and would silently redirect
everything at a kind cluster. It is deleted only if the KinD flow wrote it; a *different* cluster's
overlay is **archived, not deleted** — it may hold that cluster's only passwords.

## A1 — Harbor as a Supervisor Service · vSphere Client

**For:** the registry everything pulls from. **Not scriptable** — this is browser work.
**Broadcom's page:** [Installing and configuring Harbor and Contour](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html).

1. **Install Contour first** — it is itself a Supervisor Service and is Harbor's ingress **on the Supervisor**. (Or configure an NGINX LB for the Supervisor.)
2. **Supervisor Management → Services → Add New Service** → upload `harbor-service-<ver>.yml`.
3. **Edit `harbor-data-values-<ver>.yml`:** `hostname` (the Harbor **FQDN**) · `harborAdminPassword` · `secretKey` (**exactly 16 chars**) · `database.password` · `core.xsrfKey` (**32 chars**) · the five storage classes · and the ingress toggle (`enableContourHttpProxy: true`, or `enableNginxLoadBalancer: true`). **Leave `tlsCertificate` alone** — cert-manager self-issues, and the `managed-by: vmware-vRegistry` label is required for VKS trust.
4. **Actions → Manage Service** → pick version + Supervisor → paste the values → **Finish**.
5. **Map the FQDN — with a real DNS record. An `/etc/hosts` entry on the jump box is NOT an alternative.**
   `kubectl get svc -n <harbor-ns>` (or the Contour Envoy Service) → take the ingress IP → **create a DNS
   record that the GUEST CLUSTER'S NODES can resolve.**

   > **Why this is not a nit.** The jump box is not the only thing that pulls from Harbor — every
   > **kubelet/containerd on the guest cluster** pulls each workload image from `$HARBOR_URL`, and they
   > cannot see the jump box's `/etc/hosts`. With only a hosts entry, `make mirror` **succeeds** (the jump
   > box resolves it fine) and then every workload `ImagePullBackOff`s much later, at the far end of the
   > pipeline, with an error that points at the image, not at DNS.
   >
   > **No DNS available?** Then use Harbor's **LB IP as `HARBOR_URL`** — but the cert must then carry an
   > **IP SAN**, not just a DNS SAN. Since Go 1.15 a certificate with no matching SAN is rejected *even by
   > a client that trusts the CA*, and Go 1.17 removed the escape hatch — so a DNS-only cert on an IP URL
   > fails in crane, podman, containerd and Kaniko alike. (Our KinD stand-in mints `SAN=IP` for exactly
   > this reason.)

**Expect:** Harbor's UI answers at the FQDN you chose. (The other half — that the **guest cluster's nodes**
can resolve *and trust* this FQDN — is proven later, when Step 5's `make verify` pulls the app image from
Harbor into the guest; a bare `kubectl run` DNS probe would be rejected by the guest's `restricted` PSA, so
it is not a reliable check here.)

**→ now set in `.env`:**

```bash
HARBOR_URL=harbor.<lab-fqdn>             # the hostname you set (no scheme, no trailing slash)
HARBOR_USERNAME=admin                    # or a robot account — see Step 3
HARBOR_PASSWORD=<harborAdminPassword>    # .env only, never on argv
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # fetched in Step 2
HARBOR_INFRA_PROJECT=cicd
HARBOR_APP_PROJECT=apps
```

## A2 — ArgoCD Operator + an ArgoCD instance · `kubectl`

**Broadcom's page:** [Install Argo CD Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html).

**For:** the GitOps engine. It runs **on the Supervisor**, not in your guest cluster.

1. Install the **ArgoCD Operator** Service (same flow as Harbor).
2. Create a **vSphere Namespace** for the instance (e.g. `argocd-instance-1`) with VM + storage classes.
3. **Authenticate to the Supervisor** (interactive — it prompts for the password; no secret on argv):

   ```bash
   vcf context create --endpoint https://$SUPERVISOR_HOST --username $VKS_USERNAME \
       --insecure-skip-tls-verify --auth-type basic
   vcf context use <context-name>:$VKS_NAMESPACE      # <context-name> = what `vcf context create` produced; note the <ctx>:<ns> COLON form
   ```

   *(vSphere 8: `kubectl vsphere login --server $SUPERVISOR_HOST` instead.)*

   **→ record the context name** that `vcf context create` produced (see its output, or `vcf context list`)
   as `VKS_CONTEXT_NAME=<name>` in `.env` — A3's `vcf context use` and `make vks-login` both need it. It is
   **distinct** from `VKS_CONTEXT` (the *kubeconfig* context, set in A3). Full auth mechanism (the
   `VKS_CONTEXT_NAME`/`vcf` flow, and why Scenario 1 needs a second kubeconfig):
   [VKS authentication](vks-authentication.md).

4. **Pick a supported version, then apply the CR:**

   ```bash
   kubectl explain argocd.spec.version      # the versions YOUR operator supports
   ```

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata:
     name: argocd-1
     namespace: argocd-instance-1
   spec:
     version: <supported-version>
   ```

5. **Get its LB IP and admin password:**

   ```bash
   kubectl get svc -n argocd-instance-1                     # argocd-server → EXTERNAL-IP
   kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d
   argocd login <LB-IP>            # accept the self-signed cert
   argocd account update-password
   ```

**Expect:** `argocd-server` has an EXTERNAL-IP and you can log in.

**→ now set in `.env`:**

```bash
ARGOCD_NAMESPACE=argocd-instance-1     # the vSphere Namespace the instance runs in
ARGOCD_SERVER=<argocd-server-LB-IP>
ARGOCD_TRACK_BRANCH=main
# ARGOCD_CA_FILE=./secrets/argocd-ca.crt   # optional: make fetch-argocd-ca
```

## A3 — provision the guest VKS cluster

**For:** where Gitea, Tekton and your app actually run. You need **cluster-admin** on it.

Create a vSphere Namespace, provision a VKS cluster in it, then:

```bash
# SWITCH THE vcf CONTEXT TO THE WORKLOAD NAMESPACE FIRST. A2 left it pointed at the ArgoCD
# instance's vSphere Namespace, where this cluster does not exist — without this line the next
# command cannot see $VKS_CLUSTER_NAME and fails in a way that looks like the cluster is missing.
vcf context use $VKS_CONTEXT_NAME:$VKS_NAMESPACE

vcf cluster kubeconfig get $VKS_CLUSTER_NAME --export-file ./secrets/vks.kubeconfig
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
```

> `$VKS_CONTEXT_NAME` is the name you gave the context in A2. `scripts/30-vks-login.sh` **requires** it
> for `VKS_AUTH_METHOD=vcf`, so set it in `.env` alongside `$VKS_NAMESPACE` (the **workload** vSphere
> Namespace — *not* the ArgoCD one).
>
> ⚠️ **`-n` MEANS DIFFERENT THINGS IN DIFFERENT `vcf` SUBCOMMANDS.** In `vcf package` it is a
> **guest-cluster** namespace; in `vcf addon` it is the **vSphere Namespace** of the workload cluster.
> Same flag, opposite meaning — never copy one invocation's `-n` into the other.

**Expect:** nodes listed.

**→ now set in `.env`:**

```bash
KUBECONFIG=./secrets/vks.kubeconfig
VKS_CONTEXT=<context name from the kubeconfig>
VKS_AUTH_METHOD=kubeconfig         # simplest: use the kubeconfig you just exported
GITEA_ADMIN_PASSWORD=<choose one>  # Gitea is OURS to install — you pick the password
```

## Step 1 — will this cluster accept our install?

**For:** four preconditions that each kill the run later if missing. **Check them now, before you spend 20 minutes mirroring.**

```bash
make vks-login       # validates KUBECONFIG + context
make lab-preflight   # CRD-create · a DEFAULT StorageClass · a working LoadBalancer provider
make psa-check       # (see the caveat below)
```

**Expect:** `lab-preflight` printing **`LAB PREFLIGHT OK`** (it checks all three and names the real cause of
each failure — every one of them otherwise kills the run *after* the 20-minute mirror, with an error that
mentions none of this) · and `psa-check` printing
**`measured 0 namespace(s) … PSA UNPROVEN`** — which is the *correct* answer here, and is **not** a pass.

> **VKS enforces the `restricted` Pod Security Standard by default** (VKr v1.26+), which **rejects** our
> Kaniko build pods unless their namespaces are labelled `baseline`. Our installers apply the measured
> labels.
>
> **`psa-check` cannot prove that yet, and it will tell you so.** At this point none of our namespaces
> exist, so there is nothing to admit and nothing to measure — a green here would be true *before any of
> our code had run*, which is no evidence at all. The run that actually proves it is the one **after
> `make platform`** (Step 5), and `psa-check` is wired into `make preflight` there. Re-run it then and
> look for `PSA OK — … (N measured)`.

## Step 2 — Harbor's CA

**For:** Harbor is self-signed. `crane` (jump box) and Kaniko (in-cluster) both need to trust it.

```bash
make fetch-harbor-ca      # HARBOR_URL → HARBOR_CA_FILE
```

**Expect:** `secrets/harbor-ca.crt` exists and its SAN covers `HARBOR_URL`.

Both consumers are handled for you: `make mirror` builds a **sudo-free** trust bundle
(`SSL_CERT_FILE`), and `make platform` creates the in-cluster `harbor-ca` ConfigMap. If Harbor has a
publicly-trusted cert, leave `HARBOR_CA_FILE` empty.

<details><summary><b>If Harbor is on a DIFFERENT Supervisor, or its project is PRIVATE</b></summary>

A guest cluster on the **same** Supervisor auto-trusts Harbor's cert. Otherwise you must add the CA to
the Cluster spec `trust.additionalTrustedCAs` — **double**-base64 encoded:

```bash
base64 -w 0 harbor-ca.crt | base64 -w 0
```

([William Lam](https://williamlam.com/2024/06/using-a-vsphere-kubernetes-service-vks-cluster-with-a-private-container-registry.html). Verify the exact shape on your 9.1 lab — not reproducible on KinD.)
</details>

## Step 3 — a least-privilege Harbor robot (recommended)

**For:** CI pushes with a scoped credential instead of `admin`.

```bash
make harbor-robot     # → secrets/harbor-robot.env (0600, never printed)
# copy its two lines (HARBOR_USERNAME / HARBOR_PASSWORD) into .env
```

**Expect:** a `robot$vks-cicd` account scoped to the `cicd` + `apps` projects.

`make harbor-robot` (and `make mirror`) create those projects if you may — public by default. Private is fine too — set
`HARBOR_PUBLIC_PROJECTS=false`; `make gitops` creates the `harbor-pull` secret in every app namespace
either way, and `make check-pull-secret-alignment` gates that the Deployment asks for the secret the
flow actually creates.

## Step 4 — the Supervisor kubeconfig ArgoCD needs

**For:** `make gitops` must talk to **both** clusters — ArgoCD on the Supervisor, your app in the guest.
A3 gave you the guest one. This gives you the Supervisor one.

**→ set these in `.env` FIRST** — both `make` commands below consume them. Unset, `ARGOCD_KUBECONFIG`
defaults to the *guest* kubeconfig, so `argocd-preflight` mis-reports ArgoCD as in-cluster **and `make
gitops` (Step 5) would deploy to the Supervisor** — the wrong cluster. And `fetch-argocd-kubeconfig`
**dies** without a Supervisor-TLS setting:

```bash
ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig    # where fetch-argocd-kubeconfig writes; make gitops reads it
VKS_INSECURE_SKIP_TLS_VERIFY=true                # OR VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt (preferred)
```

(Re-source after editing `.env`: `set -a; . ./.env; set +a`.)

```bash
make fetch-argocd-kubeconfig    # interactive: prompts for your password
make argocd-preflight           # CLI vs SERVER versions + is ArgoCD even able to deploy to your cluster?
```

**Expect:** `$ARGOCD_KUBECONFIG` is written, and `argocd-preflight` prints **`PREFLIGHT OK`** and
**`ArgoCD is OFF-CLUSTER (the real-lab shape)`** — the line that actually proves the two-cluster topology
was detected. (It does *not* print "TOPOLOGY OK"; that string does not exist.)

> **Confirming `ARGOCD_NAMESPACE`:** it is the vSphere Namespace from **A2**. If you want to verify it,
> query the **Supervisor** — ArgoCD is **not** in your guest cluster, so a `kubectl get pods -A` against
> the guest kubeconfig finds nothing:
>
> ```bash
> kubectl --kubeconfig $ARGOCD_KUBECONFIG get pods -A | grep argocd-application-controller
> ```

## Step 5 — prove your `.env` works, THEN install

**For:** catching a wrong value in **seconds** instead of 20 minutes into the mirror. These three targets
exist for exactly this and the runbook used to skip them.

```bash
make env-populate   # DISCOVER what is discoverable (Harbor/ArgoCD endpoints) instead of re-typing it
make env-check      # presence gate: is every required value set? (fast, no network)
make env-validate   # validity gate: does KUBECONFIG reach the cluster, and does Harbor really authenticate?
```

**Expect:** `env-check` → *all required values present*; `env-validate` → Harbor reachable **and
authenticated over HTTPS with your CA**. `env-validate` is also the honest check on Step 2: if the CA you
fetched does not actually verify Harbor, it fails **here**, not inside Kaniko an hour later.

**First, one fork — can this jump box reach BOTH the internet and Harbor?** `make install-all` runs
`make mirror`, which pulls from the internet **and** pushes to Harbor **in the same command**. If your jump
box cannot do both, that command cannot work, and no amount of `.env` is going to fix it.

| your jump box | what you run |
|---|---|
| reaches the internet **and** Harbor (**dual-homed**) | `make install-all` below — nothing else to do |
| reaches the **internet only** | **[the sneakernet flow](sneakernet.md)** — two boxes: pull + build outside, carry, push + install inside. It replaces `install-all` (which starts with `mirror`); do **not** come back to it. |

**Then install:**

```bash
make install-all   # preflight → mirror → mirror-verify → builder-image → vks-login → platform → gitops
make psa-check     # NOW it can measure something — expect `PSA OK — … (N measured)`, not `PSA UNPROVEN`
make verify        # push a marked change → Tekton → Harbor → ArgoCD → the live app serves it
```

**Expect:** `make verify` exits **0** — the app serves the new version.

`make gitops` **registers your guest cluster** as an ArgoCD destination and points the `Application`
at it. It never installs a second ArgoCD, and never deploys onto the Supervisor.

> **Real-lab caveat:** if ArgoCD reaches your guest by a VIP that differs from your kubeconfig's server
> URL, `make gitops` cannot match the registered destination unambiguously — it **stops with a clear
> message** rather than guessing. Set `ARGOCD_DEST_CLUSTER_NAME=<the name ArgoCD registered the cluster
> under>` in `.env` and re-run.

⚠️ **`make mirror` must run alone** — not because concurrency corrupts anything (that was a
**misdiagnosis**, corrected 2026-07-13), but because the e2e mutates a shared cluster and registry, so
parallel work makes any failure unattributable. `make mirror` now ends in `mirror-verify`: a push you
have not verified is not a mirror.

## Step 6 — access the UIs

**For:** every URL and login for **this** context, without you re-typing a value you already set.

```bash
make creds-show
```

**Expect:** a table with Harbor, ArgoCD, Gitea, the Tekton dashboard, **and one row per app** — it is
generated from `apps/registry.tsv`, so it lists *every* app the repo ships (today `javawebapp` **and**
`gowebapp`), not just the one an example happened to name. It also prints the exact `/etc/hosts` line for
the ingress hosts.

Port-forward instead of the ingress if you prefer (works for any app in the registry):

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000
kubectl -n <app> port-forward svc/<app> 18080:80     # <app>: any name in apps/registry.tsv
```

## Step 7 — ingress (optional)

**For:** reaching Gitea, Tekton and the app at `*.vks.local` instead of port-forwarding.

**You own this cluster, so there is almost certainly NO mesh on it yet.** Istio is *available* on VKS
as a package (`istio.kubernetes.vmware.com`) — **available is not installed.** You provisioned this
cluster in A3; unless you installed Istio yourself, it has none.

**Ask the cluster, then do what it says:**

```bash
make istio-preflight     # read-only. On a fresh cluster: "NO Istio detected → INSTALL it"
```

| It says | You run |
|---|---|
| **NO Istio detected** (the normal case) | `make install-ingress` — installs Istio (control plane + one gateway LB). **Its images come from your Harbor**, so the cluster needs no internet. Or `INGRESS_CONTROLLER=traefik` for a lighter option. |
| **Istio is already here** (you or a template installed the VKS package) | `make install-ingress INGRESS_CONTROLLER=istio-existing` — installs **nothing**, attaches routes only. |

Then add the printed `INGRESS_LB_IP` to `/etc/hosts` (see [Access the UIs](access-uis.md)).

Two things to know about `make install-ingress` (the default):

- **It still needs internet on the jump box — for the Istio helm CHART** (`istio-release.storage.googleapis.com`).
  Fine on this dual-homed jump box; **not** on a fully air-gapped one. Its **images** come from your
  Harbor and its **Gateway API CRDs** come from the carried bundle, so those two are air-gap clean —
  the chart is the one remaining gap.
- It is a **demo ingress**, not the Broadcom-supported mesh.

<details><summary><b>Alternative: install the VKS Istio package, then attach (VKS-faithful — NOT validated by us)</b></summary>

Transcribed from Broadcom's **9.0** docs; **never run on a 9.1 lab**. Two CLI surfaces exist and we
have not established which one your lab presents — check with `vcf addon available list` first.

- **Legacy package CLI** (needs `vcf package repository add` first): `vcf package available get istio.kubernetes.vmware.com -n tkg-system` → `… --default-values-file-output istio-data-values.yaml` → `kubectl create ns istio-installed` → `vcf package install istio -p istio.kubernetes.vmware.com -v <ver> --values-file istio-data-values.yaml -n istio-installed`. Here `-n` is a **namespace in the guest cluster**.
- **Add-on CLI** (9.1 / VKS 3.7+): `vcf addon install create istio --cluster-name <cluster> …`. Here `-n` is the **vSphere Namespace of the workload cluster** — **the opposite meaning. Do not copy the flag across.**

⚠️ **UNVERIFIED and load-bearing:** on an air-gapped cluster the package's **own** istiod/proxy images
come from Broadcom's registry, which your guest cannot reach. This repo does **not** mirror or repoint
them. Settle that before choosing this path.

The package's shared ingress gateway is **off by default**, which is correct — `istio-existing` routes
with the **Kubernetes Gateway API** and lets Istio provision the proxy + LB itself. That needs the
Gateway API CRDs present (`kubectl get crd httproutes.gateway.networking.k8s.io`); if they are absent,
the attach falls back to the classic path and will fail, because the shared gateway is off.
</details>

## Preconditions, in one place

- **cluster-admin** on the guest cluster (we create namespaces and install Tekton CRDs).
- A **default StorageClass** (Gitea's PVC) and a working **LoadBalancer** provider.
- **Network reach from the jump box:** the internet, the **Supervisor** API, the **guest** API, and **Harbor**.
- **ArgoCD must be able to clone Gitea.** ArgoCD is on the Supervisor, so `gitea-http.gitea.svc` does not resolve there — Gitea gets its **own LoadBalancer** and `make install-gitea` publishes `GITEA_ARGOCD_URL`. The ingress hostname is **not** usable for this (it exists only in your `/etc/hosts`). `make gitops` refuses to build a repoURL ArgoCD cannot reach.
- **No stale state overlay** when you start (Step 0).

---

[← back to the README](../README.md)
