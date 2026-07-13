# Real VKS lab — Scenario 1: Harbor & ArgoCD need to be installed

<br>

> **You install Harbor + ArgoCD** (as VCF **Supervisor Services**), then run the pipeline.

This is the real target. You are given a **Supervisor** endpoint (IP), a login, and a password —
nothing else. **Harbor** and **ArgoCD** are **not** pre-provided: you install them as **VCF
Supervisor Services**, provision a **workload VKS cluster**, then install **Gitea** + **Tekton**
and wire the pipeline. Dual-homed: the jump box reaches both the internet and the lab (Supervisor
API + Harbor).

The order below installs the lab-side services first (Harbor, ArgoCD, workload cluster; mostly
the vSphere Client + `kubectl`), then wires this repo and runs the flow. Everything you need is
in this section — you do not have to read the other scenario.

**Downloads** (each needs your Broadcom entitlement):

- **VCF Consumption CLI** 9.1.0.0 —
  [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true)
- **VCF Consumption CLI Plugins** 9.1.0.0 —
  [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true)
- **ArgoCD Service** (search **vSphere Supervisor Services** → **ArgoCD Service**) —
  [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN)
- **Harbor** (search **vSphere Supervisor Services** → **Harbor**) —
  [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN)

Reference docs:
[Installing and Configuring Harbor as a VCF Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)
·
[Install the Argo CD Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html).

> **Doc-provenance note.** Broadcom's **9.1** ArgoCD/Harbor techdoc pages currently **301-redirect
> to the 9.0 tree**, so the version-specific facts below (the `2.14.15` ArgoCD server example, field
> names) are **9.0 content taken as authoritative-for-9.1** — an inference, not verified 9.1 ground
> truth. Confirm against the running lab (`kubectl explain argocd.spec.version`, the actual service
> YAML) before relying on an exact version.

## Install Harbor & ArgoCD as Supervisor Services

**A1 and A2 install ON the Supervisor** (each Service lands in its own vSphere Namespace),
**not** on a workload cluster — so they need **Supervisor** access, not the VKS kubeconfig you
fetch in A3. The `.env` prompts below are interleaved with the steps: set each value at the
step where it first becomes known, rather than all at once.

> **→ before you start, set the upfront vCenter vars in `.env`** (they drive the Supervisor login):
>
> ```bash
> SUPERVISOR_HOST=<supervisor-control-plane-IP>   # vCenter → Workload Management → Supervisors
> VKS_USERNAME=administrator@vsphere.local        # your vSphere SSO admin
> VKS_NAMESPACE=<vsphere-namespace>               # where you create the ArgoCD/workload resources
> VKS_CLUSTER_NAME=<vks-cluster-name>             # the workload cluster you provision in A3
> ```

**A1 — Install Harbor as a Supervisor Service** (vSphere Client — not scriptable):

1. **Ingress prereq:** install **Contour** first (Harbor's default ingress on VKS), or configure
   an NGINX-based load balancer for the Supervisor.
2. **Register the operator:** vSphere Client → **Supervisor Management → Services → Add New
   Service** → upload `harbor-service-<ver>.yml`.
3. **Configure `harbor-data-values-<ver>.yml`** — the key fields: `hostname` (the Harbor
   **FQDN**), `harborAdminPassword` (initial admin password, changeable later), `secretKey`
   (exactly 16 chars), `database.password`, `core.xsrfKey` (32 chars), the storage classes
   (registry/jobservice/database/redis/trivy — your storage-policy name, lowercased with dashes),
   and the ingress toggle (`enableContourHttpProxy: true` for Contour **or**
   `enableNginxLoadBalancer: true` for NGINX). Leave the `tlsCertificate` block alone unless you
   bring a custom cert — cert-manager auto-issues a self-signed one (keep the
   `managed-by: vmware-vRegistry` label; it is required for VKS trust).
4. **Deploy:** Harbor service card → **Actions → Manage Service** → pick version + target
   Supervisor → paste the edited `harbor-data-values` → **Finish**.
5. **Map the FQDN:** get the ingress IP (`kubectl get svc -n <harbor-ns>` for NGINX, or the
   Contour Envoy service IP), then add a DNS record — or a jump-box `/etc/hosts` entry — mapping
   the Harbor FQDN → that IP.

> **Fidelity bonus (real lab beats KinD here):** when Harbor and your VKS workload cluster run on
> the **same Supervisor**, the VKS clusters **automatically trust the Harbor registry
> certificate** — so the workload-node image pull "just works" without the per-node `certs.d`
> wiring the KinD stand-in uses.

With Harbor installed, record its access details before moving on to ArgoCD.

> **→ now (A1 done) set the Harbor values in `.env`** — the FQDN you set, or its discovered LB IP:
>
> ```bash
> HARBOR_URL=harbor.<lab-fqdn>          # the hostname you set; or:
> #   kubectl get svc -n <harbor-namespace> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
> HARBOR_USERNAME=admin                 # or a robot account (Step 4 / make harbor-robot)
> HARBOR_PASSWORD=<harborAdminPassword> # the A1 admin password; set in .env only, never on argv
> HARBOR_CA_FILE=./secrets/harbor-ca.crt   # Harbor's self-signed CA (saved in Step 2)
> HARBOR_INFRA_PROJECT=cicd             # CI/CD + base images
> HARBOR_APP_PROJECT=apps               # the built application image
> ```

**A2 — Install the ArgoCD Operator + an ArgoCD instance** (`kubectl`-driven):

1. **Install the ArgoCD Operator** service on the Supervisor (Supervisor Services, same flow as
   Harbor).
2. **Create a vSphere Namespace** for the instance (e.g. `argocd-instance-1`) with VM + storage
   classes.
3. **Authenticate to the Supervisor** with the VCF Consumption CLI (interactive — it prompts
   for the context name + password; no secret on argv), then activate the namespace:

   ```bash
   vcf context create --endpoint https://<supervisor-IP> --username <user>@<SSO-DOMAIN> \
       --insecure-skip-tls-verify --auth-type basic     # enter a context name (e.g. sup66) + password
   vcf context use <context-name>:<vsphere-namespace>   # note the <ctx>:<ns> COLON form
   ```

   On vSphere 8, use `kubectl vsphere login --server <IP>` instead. `make vks-login` with
   `VKS_AUTH_METHOD=vcf` runs this flow from `.env` (see the [VKS authentication](vks-authentication.md) section).
4. **Pick a supported version** with `kubectl explain argocd.spec.version`, then apply the CR:

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata:
     name: argocd-1
     namespace: argocd-instance-1
   spec:
     version: <supported-version>   # e.g. 2.14.15+vmware.1-vks.1
   ```

5. **Get its LoadBalancer IP:** `kubectl get svc -n argocd-instance-1` → the `argocd-server`
   EXTERNAL-IP (its **own** LB, self-signed TLS with no IP SAN — like the KinD stand-in).
6. **Get the admin password:**
   `kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
7. **Log in + rotate:** `argocd login <LB-IP>` (accept the self-signed cert) →
   `argocd account update-password`.

> **Version note:** the operator CR pins the ArgoCD **server** (the example is `2.14.15`, a 2.x
> line), while the shipped `argocd` **CLI** from the VCF download is `3.0.19-vcf` (3.x). Read the
> real supported server versions with `kubectl explain argocd.spec.version` on the lab; the KinD
> stand-in runs a 3.x server, so expect a possible server-generation delta.
>
> **Topology to verify on the lab:** `make gitops` applies an ArgoCD `Application` (via
> `kubectl`) into `ARGOCD_NAMESPACE` and targets the in-cluster destination
> `https://kubernetes.default.svc`. Confirm the ArgoCD instance can deploy into the workload
> namespace it watches — same cluster, or the workload cluster registered with ArgoCD. An
> off-cluster ArgoCD addressed **only** by URL + API is not what the scripts assume.
>
> **`make argocd-preflight`** automates both checks against your `KUBECONFIG` cluster — it
> prints the operator's supported server versions (`kubectl explain argocd.spec.version`), the
> running server image, the `argocd` CLI version, and a **TOPOLOGY OK / MISMATCH** verdict
> (is ArgoCD in this cluster, are any workload clusters registered, does the target namespace
> exist). Run it after Step 1 (kubeconfig in place), before `make gitops`.

With the ArgoCD instance up, record its endpoint and namespace.

> **→ now (A2 done) set the ArgoCD values in `.env`** — the argocd-server LB IP + where it runs:
>
> ```bash
> ARGOCD_NAMESPACE=argocd-instance-1    # the vSphere Namespace your A2 ArgoCD instance runs in
> ARGOCD_SERVER=<argocd-server-LB-IP>   # kubectl get svc -n argocd-instance-1 argocd-server \
> #                                       -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
> > ARGOCD_TRACK_BRANCH=main
> # ARGOCD_CA_FILE=./secrets/argocd-ca.crt   # ArgoCD's self-signed CA (Step 2, make fetch-argocd-ca)
> ```

**A3 — Provision the workload VKS cluster + get its kubeconfig.** Gitea, Tekton, and the demo app
run in a **guest VKS (Tanzu Kubernetes) cluster**, not on the Supervisor. Create a vSphere
Namespace, provision a VKS cluster in it, and obtain its kubeconfig (e.g. a `vcf`/`kubectl
vsphere` login to the guest cluster, or export it from VCF Automation). You need **cluster-admin**
on it — the flow creates namespaces (`gitea`, `ci`, `javawebapp`) and installs Tekton CRDs. Place the
kubeconfig at `$KUBECONFIG` (used at "Wire the repo & run the pipeline", Step 1 below).

> **→ now (A3 done) set the workload kubeconfig in `.env`** — the `vcf` CLI writes it for you:
>
> ```bash
> vcf cluster kubeconfig get $VKS_CLUSTER_NAME --export-file ./secrets/vks.kubeconfig
> #   (legacy 8.x: kubectl vsphere login --server $SUPERVISOR_HOST --vsphere-username $VKS_USERNAME \
> #      --tanzu-kubernetes-cluster-name $VKS_CLUSTER_NAME --tanzu-kubernetes-cluster-namespace $VKS_NAMESPACE)
> KUBECONFIG=./secrets/vks.kubeconfig      # then set this to the exported path
> VKS_CONTEXT=<context-name-in-that-kubeconfig>
> ```

### Wire the repo & run the pipeline

**Step 0 — remove any STALE KinD overlay.** `.env.kind` is sourced *after* `.env`, so a leftover
one from a local run would silently redirect everything at a kind cluster. Delete it **before you
start**:

```bash
make kind-down        # if you ran the local flow (also removes .env.kind)
rm -f .env.kind       # belt-and-suspenders
```

> **Do not delete it again later.** On a real lab `make install-gitea` (inside `make platform`)
> *writes* `.env.kind` to publish the Gitea **LoadBalancer** address it just discovered
> (`GITEA_ARGOCD_URL`) — the address ArgoCD's repo-server clones from. That file is how the value
> reaches `make gitops`, which runs as a separate process. Removing it between `make platform` and
> `make gitops` throws the address away, and `make gitops` will refuse to build a repoURL ArgoCD
> cannot reach. (The name is a leftover from when only the KinD flow discovered anything.)

**Step 1 — finish `.env`.** By now the interleaved "→ now set these in `.env`" callouts above
have filled the Harbor values (as you installed Harbor), the ArgoCD values (as you installed
ArgoCD), and `KUBECONFIG` / `VKS_CONTEXT` (when you provisioned the workload cluster). Only the
**Gitea password** (a login for the component **we** install) and the **VKS auth method** remain:

```bash
# --- Gitea (WE install it — you choose the password) ---
GITEA_ADMIN_PASSWORD=<choose-one>        # set in .env only

# --- VKS access method ---
VKS_AUTH_METHOD=kubeconfig               # simplest: use the KUBECONFIG you fetched in A3 as-is
```

For VKS auth, `kubeconfig` (the kubeconfig `vcf cluster kubeconfig get` wrote in A3) is the
simplest working method. To have `make vks-login` run the VCF Consumption CLI login itself, set
`VKS_AUTH_METHOD=vcf` and the `vcf` inputs (`SUPERVISOR_HOST` / `VKS_USERNAME` /
`VKS_NAMESPACE` / `VKS_CLUSTER_NAME` / `VKS_CONTEXT_NAME`) — see the
[VKS authentication](vks-authentication.md) section for the exact flow (written
to the verified shape but not yet lab-validated). For the legacy vSphere plugin, set
`VKS_AUTH_METHOD=vsphere` and `SUPERVISOR_HOST` / `VKS_NAMESPACE` / `VKS_CLUSTER_NAME` /
`VKS_USERNAME` / `VKS_PASSWORD`.

**Step 2 — save the Harbor CA certificate** to `./secrets/harbor-ca.crt` (the
`HARBOR_CA_FILE` path). If the lab handed you the cert, drop it there. Otherwise fetch it
from the running Harbor with **`make fetch-harbor-ca`** (reads `HARBOR_URL`, writes
`HARBOR_CA_FILE`), or by hand:

```bash
make fetch-harbor-ca                         # convenience: HARBOR_URL → HARBOR_CA_FILE
# …or the equivalent by hand:
mkdir -p secrets
openssl s_client -connect <harbor-host>:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > secrets/harbor-ca.crt
```

(Or download it from the Harbor UI → your project → **Registry Certificate**.) The CA is
consumed in **two** places, both handled for you: `make mirror` builds a **sudo-free** trust
bundle (`SSL_CERT_FILE` = the system CAs + your Harbor CA) so `crane` pushes over HTTPS
**without** touching the jump box's system trust store, and `make platform` creates an
in-cluster ConfigMap **`harbor-ca`** (key `ca.crt`) so Kaniko/Tekton trust it too. If Harbor
presents a publicly-trusted cert, leave `HARBOR_CA_FILE` empty.

For **ArgoCD**'s self-signed CA (only needed if you drive `argocd login` with verification, or
to trust its UI), fetch it the same way — set `ARGOCD_SERVER` to the A2 `argocd-server` LB IP and
run **`make fetch-argocd-ca`** (writes `ARGOCD_CA_FILE`). The pipeline wires ArgoCD via `kubectl`
(not the `argocd` CLI), so this is optional for the demo itself.

**Step 3 — install prereqs and log in to VKS:**

```bash
make deps         # kind, crane, tkn, argocd, kubectl, helm + the rest of the mise toolchain
make vks-login    # validates $KUBECONFIG + context against the lab cluster
```

**Step 3b — install the Broadcom VCF/VKS lab CLIs.** You need the **licensed** `argocd-vcf` +
`vcf` binaries if **either** applies (both are the normal real-lab case):

- you authenticate with `VKS_AUTH_METHOD=vcf` — `scripts/30-vks-login.sh` hard-requires `vcf`; or
- you need **`make fetch-argocd-kubeconfig`** (the Supervisor kubeconfig that lets `make gitops`
  register your guest cluster with the ArgoCD Supervisor Service) — it hard-requires `vcf` too.

They are only **optional** if you already hold a working workload-cluster kubeconfig
(`VKS_AUTH_METHOD=kubeconfig`) *and* your cluster is already registered with ArgoCD (Scenario 2,
where the platform team does it for you). The pipeline itself wires everything via `kubectl`. They install **sudo-free** to
`~/.local/bin`, and the installer picks the right archive for the jump box's **OS/arch**.

**Supply them as a folder.** Download the artifacts — however you have entitlement (the
[Broadcom support portal](https://support.broadcom.com) or an internal mirror) — on an
internet-connected box, drop them **all in one directory** (e.g. your browser's default
`~/Downloads/vcf`), and point `VCF_CLI_SRC_DIR` at it. This is the air-gap-correct path: carry
the folder in, no download client / token / network at install time.

**Just dump everything in there — the installer auto-selects.** You don't have to prune the
folder to this box's platform: it may hold every arch (`…-Linux_AMD64-…` + `…-Linux_ARM64-…`),
macOS builds, **and** the portal's multi-arch `…-Binaries-…` bundle, all at once. The installer
picks the archive matching **this jump box's OS/arch** and the **pinned versions** (from
`.env.example`) and ignores the rest — a mixed folder resolves deterministically, and if the
pinned version isn't present it errors clearly rather than ever installing a different version.

`VCF_CLI_SRC_DIR` is **required** — the installer does not guess where you dropped the files. Set
it on the command line, or uncomment it in `.env` (gitignored) so every `make` invocation picks
it up. The version pins in `.env.example` already match the current portal artifacts, so normally
you only set the folder:

```bash
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf   # argocd-vcf + vcf + vcf plugins
# or put it in .env once:  VCF_CLI_SRC_DIR=/home/you/Downloads/vcf   → then just `make install-vcf-clis`
# versions are pinned in .env.example (ARGOCD_VCF_VERSION / VCF_CLI_VERSION / VCF_PLUGINS_VERSION);
# keep them in sync with the artifacts you place in the folder.
```

**Packages this step needs** (`tar`, `gzip`/`gunzip`, `find`, `install`) — **`make deps`
already provides them** (`scripts/00-install-prereqs.sh` installs `tar`, `gzip`, `findutils`),
so if you ran the bootstrap you're covered. The installer also checks for them and errors
clearly if any is missing. On a minimal box where you skipped `make deps`:

- **Ubuntu:** present by default — nothing extra.
- **Photon OS:** `sudo tdnf install -y findutils` (`find` is not in Photon's base; its
  `gzip`/`tar` come from BusyBox-style **toybox**, which lacks `gzip -t` — the installer uses
  portable checks so it works there). `unzip` is **not** required — the artifacts are `.gz`/`.tar.gz`.

> **Fidelity vs a real lab.** The local KinD stand-in faithfully reproduces the lab's
> **self-signed-TLS + CA-trust** posture (Harbor HTTPS + ArgoCD self-signed TLS on their own
> LBs). Three things differ on a real VKS lab and must be verified there: the workload cluster
> trusts the Harbor CA **declaratively** via the Cluster spec `trust.additionalTrustedCAs`
> (not per-node `certs.d`); a **private** Harbor project needs a robot account +
> `imagePullSecret`; and the lab is **FQDN**-addressed. See
> [KinD TLS fidelity → Fidelity vs a real VCF/VKS 9.1 lab](decisions/kind-tls-fidelity.md).

When Harbor and the workload cluster are **not** on the same Supervisor (or the Harbor project is
**private**), the auto-trust does not apply and you must make the VKS cluster trust the Harbor CA
**declaratively**. Add the CA to the Cluster spec `trust.additionalTrustedCAs` — the value is the CA
PEM **encoded twice with base64** (VKS decodes one layer, then the node trust store decodes the
inner PEM):

```bash
# DOUBLE base64: the outer -w0 keeps it a single line for the Cluster YAML.
base64 -w 0 harbor-ca.crt | base64 -w 0
```

Reference: [William Lam — using a VKS cluster with a private container registry](https://williamlam.com/2024/06/using-a-vsphere-kubernetes-service-vks-cluster-with-a-private-container-registry.html).
(Verify the exact `trust.additionalTrustedCAs` shape against your VCF/VKS 9.1 lab — it is not
reproducible on the KinD stand-in.)

**Step 4 — Harbor projects + (recommended) a robot account.** `make mirror` (run in step 6)
creates the `cicd` and `apps` projects for you via Harbor's REST API if they don't exist
(needs push rights). It creates them **public** (`HARBOR_PUBLIC_PROJECTS=true`, the default),
so the cluster's containerd/kubelet *can* pull the app image anonymously. The image-pull
credential is created either way: `make gitops` puts a `harbor-pull` Secret in **every app's
namespace** and every app's Deployment references it — public projects just make it redundant.
(`make check-pull-secret-alignment` gates that the two agree; a mismatch is an ImagePullBackOff
that nothing else would catch.)

**If your lab mandates PRIVATE projects**, set `HARBOR_PUBLIC_PROJECTS=false` (so any project
`make mirror` auto-creates is private) or pre-create them private. Nothing else to do: `make gitops`
creates the image-pull secret (`harbor-pull`, from `HARBOR_USERNAME`/`HARBOR_PASSWORD`) in **every
app's namespace**, and each app's Deployment already references it. The pipeline's push secret
(`harbor-dockerconfig` in `ci`, step 5) authorizes **pushes only**, never the workload's pull —
they are two different credentials in two different namespaces, and `make check-pull-secret-alignment`
gates that the Deployment asks for the secret the flow actually creates.

For least-privilege CI, create a Harbor **robot account** (push/pull scoped to the two projects)
instead of using `admin`. **`make harbor-robot`** does it via Harbor's REST API — it creates
`robot$<HARBOR_ROBOT_NAME>` (default `vks-cicd`) and writes the name + one-time secret to a
gitignored `secrets/harbor-robot.env` (mode 0600, never printed):

```bash
make harbor-robot                                  # → secrets/harbor-robot.env
# then copy its two lines (HARBOR_USERNAME='robot$vks-cicd' / HARBOR_PASSWORD=…) into .env
```

Confirm the namespace your ArgoCD (A2) runs in / watches (for `ARGOCD_NAMESPACE`):

```bash
kubectl get pods -A | grep argocd-application-controller   # its namespace = ARGOCD_NAMESPACE
```

**Step 5 — verify (or create) the in-cluster registry secret.** The pipeline pushes the
built image to Harbor from inside the cluster, which needs a Docker-config secret.
`make platform` (its `configure-tekton` step, run in step 6) creates it for you as
**`harbor-dockerconfig`** in the `ci` namespace, from `HARBOR_USERNAME` / `HARBOR_PASSWORD`.
Check whether it already exists:

```bash
kubectl -n ci get secret harbor-dockerconfig
```

<br>

Keep the secret **off argv** — build the `config.json` on disk and load it from a file; kaniko
needs the key named literally `config.json`, not `.dockerconfigjson`:

```bash
umask 077
auth=$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0)
printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" > /tmp/harbor-config.json
kubectl -n ci create secret generic harbor-dockerconfig \
  --from-file=config.json=/tmp/harbor-config.json --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/harbor-config.json
```

The Kubernetes secret is built from your Harbor **login/password**; Harbor's **REST API** is
used only to create the *projects* (and, optionally, a robot account) — it does not create
this cluster secret.

**Step 6 — install everything and verify end-to-end:**

```bash
make install-all   # mirror → mirror-verify → builder-image → vks-login → platform → gitops
make verify        # push a marked change → Tekton → Harbor → ArgoCD → live app serves it
```

`install-all` deliberately does **not** install Harbor or ArgoCD — those you installed above as
Supervisor Services. It mirrors all images into that Harbor, builds + pushes the offline Maven
builder image, installs Gitea + Tekton, and creates the ArgoCD `Application`.

> **Cross-cluster ArgoCD deploy.** ArgoCD runs on the **Supervisor**, so it must be told where
> your **guest** workload cluster is. Set **`ARGOCD_KUBECONFIG`** (Supervisor access) in `.env`
> alongside `KUBECONFIG` (guest access); `make gitops` (invoked by `install-all`) then
> **auto-registers** the guest cluster as an ArgoCD destination via **`make
> argocd-register-guest`** and points the `Application` there — it does **not** install a second
> ArgoCD in the guest.
>
> **Get `ARGOCD_KUBECONFIG` with `make fetch-argocd-kubeconfig`.** ArgoCD runs on the **Supervisor**,
> so registration needs a *Supervisor* kubeconfig — not the workload one `make vks-login` gives you.
> The target creates a Supervisor VCF-CLI context, writes it to `$ARGOCD_KUBECONFIG`, and **proves**
> it reaches `argocd-server` before you go further. (It is interactive — the CLI prompts for your
> password.) See [`docs/vks-services/argocd.md`](vks-services/argocd.md). As the ArgoCD **admin** (you own the instance from A2), this
> auto-registration works out of the box. Leave `ARGOCD_KUBECONFIG` unset only if ArgoCD and the
> workload run in the same cluster.

**Step 7 — access the UIs.** Harbor and ArgoCD are the ones you installed above — use the FQDN /
LB IP + admin credentials you set there. For **Gitea** (which you installed) and the deployed
**app**, either front them with the ingress at `*.vks.local`, or `kubectl port-forward`
(`kubectl -n gitea port-forward svc/gitea-http 3000:3000`,
`kubectl -n javawebapp port-forward svc/javawebapp 18080:80`).

> **Ingress — the mesh ALREADY EXISTS here; attach to it, do not install one.** Istio ships on VKS
> as a **Standard Package** (`istio.kubernetes.vmware.com`) in the guest cluster. The bare
> `make install-ingress` defaults to `INGRESS_CONTROLLER=istio`, which would **helm-install a second
> istiod over the platform's mesh**. Instead:
>
> ```bash
> make istio-preflight                                     # read-only: is Istio here? what does it require of me?
> make install-ingress INGRESS_CONTROLLER=istio-existing   # installs NOTHING; attaches our routes only
> ```
>
> `istio-preflight` prints the exact `Gateway` selector the mesh requires, what your kubeconfig may
> actually do, and what (if anything) to request from the mesh admin. It also picks the route API:
> the **Kubernetes Gateway API** when Istio is an Accepted `GatewayClass` (Istio then
> auto-provisions the proxy *and* its LoadBalancer — nothing needed from the platform team), else
> the classic `Gateway`/`VirtualService` path. Add the printed `INGRESS_LB_IP` line to `/etc/hosts`
> (see [Access the UIs](../README.md#access-the-uis-urls-logins-passwords)).
>
> Only if the cluster genuinely has **no** mesh should you install one (`make install-ingress`, or
> `INGRESS_CONTROLLER=traefik` for the lighter option).
>
> **Run `make psa-check` before installing anything.** A VKS guest cluster enforces the
> `restricted` Pod Security Standard **by default** (VKr v1.26+), which **rejects** our Kaniko build
> pods and the Istio-provisioned gateway proxy unless their namespaces are labelled `baseline`. The
> installers apply the measured labels; `psa-check` proves the cluster will admit the workloads
> *before* you spend 20 minutes mirroring.

<br>

- **No STALE `.env.kind` when you start** (step 0) — it is sourced after `.env` and silently forces
  kind values.
- **You need `kubectl` access to the cluster ArgoCD RUNS in** (the Supervisor), because the
  scripts create the `Application` by `kubectl apply`-ing it into `ARGOCD_NAMESPACE` — **not**
  via the ArgoCD API. ArgoCD itself does **not** have to run in your workload cluster: the
  `Application`'s destination is `${ARGOCD_DEST_SERVER}` (`k8s/argocd/application.yaml`), which
  defaults to in-cluster and is pointed at your guest cluster by `make argocd-register-guest`
  (see Step 6). An ArgoCD reachable *only* by URL + API — with no kubeconfig — is not supported.
- **`ARGOCD_NAMESPACE` must match** where the lab's ArgoCD controller watches Applications
  (step 4).
- **ArgoCD must be able to CLONE Gitea from whatever cluster ArgoCD runs in.** In-cluster
  (KinD, ArgoCD-in-guest) that is `GITEA_INTERNAL_URL` (`http://gitea-http.gitea.svc:3000`).
  On a real lab ArgoCD is a **Supervisor Service** — a *different* cluster — and that name does
  not resolve there, so Gitea gets its **own LoadBalancer** and `make install-gitea` publishes
  `GITEA_ARGOCD_URL` (`http://<gitea-lb-ip>:3000`). The ingress hostname (`gitea.vks.local`) is
  **not** usable for this: it exists only in your `/etc/hosts`, and dialling the ingress IP sends
  `Host: <ip>`, which matches no vhost (404, not a clone). `make gitops` refuses to build an
  unreachable repoURL rather than let every Application fail silently.
- **cluster-admin** on the workload cluster is required — the flow creates namespaces
  (`gitea`, `ci`, `javawebapp`) and installs Tekton CRDs.
- **StorageClass:** Gitea uses a PVC (`GITEA_STORAGE_SIZE`, default `5Gi`). Ensure the
  cluster has a default StorageClass (or set one explicitly).
- **Harbor projects** `cicd` + `apps` must exist (auto-created by `make mirror` with push
  rights; otherwise create them first).
- **Network reach (dual-homed):** the jump box must reach the VKS API server and the lab
  Harbor.

---

[← back to the README](../README.md)
