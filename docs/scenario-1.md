# Scenario 1 — you install Harbor and ArgoCD

## What this is

You have a **Supervisor** endpoint, a login and a password. This runbook creates a vSphere Namespace
(or uses one you already have), installs Harbor and ArgoCD as Supervisor Services, creates a guest
VKS cluster, and runs an air-gapped CI/CD pipeline into it.

**What you end up with:** `git push` → Tekton builds → image to Harbor → tag written back → ArgoCD
syncs → the app serves the change. Two demo apps (Java and Go), proven by `make verify`.

> Background for when a step surprises you → [scenario-1-notes.md](scenario-1-notes.md).

## The whole sequence

Run these in this order. Steps 1b, 2 and 3 are browser work; everything else is a command.

| | Step | You do |
|---|---|---|
| **0** | [Get the repo](#0-get-the-repo) | clone it, `cd` into it, create `.env` |
| **1** | [Jump box](#1-jump-box) | install the toolchain; set 8 values in `.env` |
| **1b** | [vSphere Namespace](#1b-the-vsphere-namespace) | browser: create it, attach storage + a VM class |
| **2** | [Harbor](#2-harbor) | browser: install it; set 5 values |
| **3** | [ArgoCD](#3-argocd) | browser + CLI: install it, get the CA, log in; set 4 values |
| **4** | [Guest cluster](#4-guest-cluster) | create it; set 1 value, then 3 more after it is up |
| **5** | [Preflight](#5-preflight) | check the cluster will accept the install |
| **6** | [Harbor's CA](#6-harbors-ca) | fetch it |
| **7** | [Harbor robot](#7-harbor-robot-recommended) | create it; replace 2 values |
| **8** | [ArgoCD's kubeconfig](#8-the-supervisor-kubeconfig-argocd-needs) | fetch it; set 2 values |
| **9** | [Install](#9-validate-then-install) | `make install-all`, then `make verify` |
| **10** | [Ingress](#10-ingress-optional) | optional: reach the UIs at `*.vks.local` |
| **11** | [Access the UIs](#11-access-the-uis) | `make creds-show` |
| **12** | [Uninstall](#12-uninstall) | `make uninstall-all` |

**Everything you configure goes in ONE file: `.env`, at the root of the repo.** Each step has a
table of the keys it needs, with an example and where the value comes from.

**Jump box:** Ubuntu or Photon OS, reaching both the internet and the lab. It must resolve the
vCenter FQDN. **Harbor's FQDN must be in real DNS** — the guest nodes resolve it, so `/etc/hosts`
is not enough. The `*.vks.local` names are `/etc/hosts`-only.
Internet-only? Use [the sneakernet flow](sneakernet.md) instead; it replaces Step 9.

---

## 0. Get the repo

Everything below runs **from the repo root**. Nothing works from another directory.

A stock Ubuntu or Photon box has neither `git` nor `make`. Ubuntu has no `curl` either, and
`make deps` needs it. Install them first.

```bash
# Ubuntu / Debian
apt-get update && apt-get install -y --no-install-recommends git make curl ca-certificates
# Photon OS 5
tdnf install -y git make
```

Prefix with `sudo` if you are not root.

```bash
git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
cd vks-airgap-cicd
pwd                            # sanity check: should end in /vks-airgap-cicd
make env-init                  # creates ./.env from the template .env.example
```

**Expect:** `./.env` exists. It is the one file you edit for the rest of this runbook; each step
below lists the keys it needs before the commands that read them.

**Collect these from your lab before Step 1** — you paste them into `.env`:

| What | Example | Where to find it |
|---|---|---|
| Supervisor IP | `192.168.101.128` | vCenter → Workload Management → Supervisors → *Control Plane Node IP* |
| vCenter FQDN | `vcsa.env1.lab.test` | the address you log into vCenter with (Step 3 needs it for the CA). **Your jump box must resolve it** — check: `getent hosts vcsa.env1.lab.test` |
| your SSO user | `administrator@vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups |
| your SSO domain | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups, the *Domain* dropdown |
| your SSO password | — | for that login — you put it in `.env` in Step 1 |

### Download the Broadcom artifacts

All of these are **entitled** downloads — you need a Broadcom account with a vSphere
Foundation entitlement. Get them now: Steps 1-3 read them off disk and will not tell
you to fetch them. Versions move; match yours to what your entitlement offers.

| file | from | put it in |
|---|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-9.1.0.0400.25509669.tar.gz` | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540529) | `VCF_CLI_SRC_DIR` (you set it in Step 1) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.0400.25509793.tar.gz` | [Plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540672) | `VCF_CLI_SRC_DIR` |
| the amd64 `argocd` CLI | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | `VCF_CLI_SRC_DIR` |
| `supervisor-service-argocd-legacy-1.1.0-25100889.yml` | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | anywhere — you upload it in vCenter in Step 3 |
| `supervisor-service-harbor-legacy-v2.14.3+vmware.2-vks.1-25292931.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | anywhere — you upload it in vCenter in Step 2 |
| `supervisor-service-harbor-data-values-v2.14.3.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | `~/Downloads/vcf` |

The example throughout this runbook uses `~/Downloads/vcf` for all of them.

⚠️ **Take the `-legacy` service files.** The non-legacy ones install "successfully" and
then die at reconcile, because a Supervisor without a Software Depot cannot fetch what
they reference.

⚠️ **Take only the `Linux_AMD64` rows** (uppercase). The un-suffixed `-Binaries-`,
`-PluginBundle-` and `-OCI-` archives are multi-platform supersets the installer will
not use.

**Istio is not on this list.** Step 10 installs it *from your own Harbor*, or attaches to
the one your Supervisor already has — nothing to download.

**Portal gotchas, all of which fail silently:**

- **Tick "I agree to the Terms and Conditions"** or the download icons do nothing. On the
  VCF CLI pages the checkbox stays **inert until you open both Terms links first**, and the
  gate is **per page** — ticking it on one page does not carry to the next.
- **Patch builds appear only once you open a group.** The parent page lists `9.1.0.0` alone.
- **A `release=` in the URL is ignored** — use the on-page selector.

---

## 1. Jump box

Install the toolchain and the licensed CLIs.

**→ set in `./.env` before you run the commands below.** `VCF_CLI_SRC_DIR` is read by
`make install-vcf-clis` in this step — without it that command **fails**. The rest are read from Step 3 onward.

| key | example | how to get the value |
|---|---|---|
| `VCF_CLI_SRC_DIR` | `/home/you/Downloads/vcf` | the folder you put the two Broadcom archives in |
| `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → Control Plane Node IP. **Bare host — no `https://`, no trailing slash.** |
| `VKS_CONTEXT_NAME` | `vks-cicd` | **you invent this** — a short label for the `vcf` login context |
| `VKS_NAMESPACE` | `lab` | the vSphere Namespace the cluster goes in. **Create it first — see 1b below.** |
| `VKS_CLUSTER_NAME` | `cicd-gc1` | **you invent this** — the guest cluster Step 4 creates. Must not be a name you deleted recently (see notes). |
| `VKS_USERNAME` | `administrator@vsphere.local` | your vCenter SSO login |
| `VCF_CLI_VSPHERE_PASSWORD` | *your value* | the password for that login |
| `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups → *Domain* |

Now run:

```bash
cd vks-airgap-cicd            # the repo you cloned in Step 0
make deps                     # toolchain: kubectl, helm, crane, tkn, jq, yq…
make install-vcf-clis         # reads VCF_CLI_SRC_DIR, which you set above
make check-tools              # what you have, what is missing
```

**Expect:** `check-tools` prints `all REQUIRED tools present.` *(~5 min, mostly downloads)*

---

## 1b. The vSphere Namespace

Your cluster goes in a vSphere Namespace. Use your own — not one shared with other workloads,
because teardown deletes **by name** and this repo's app names are generic.

### If you already have one

Put its name in `VKS_NAMESPACE`, then go to Step 2 — but come back to *Check it before Step 4*
below once you have finished Step 3.

### If you don't — create it

Do this **now, before Step 3** — the login in Step 3 activates a context at this namespace and
fails if it does not exist yet.

**vCenter → Workload Management → Namespaces → Create Namespace.** Pick your Supervisor, name it.
Then, in the namespace you just created:

1. **Storage** → *Add Storage* → pick a storage policy — `wcp-vmfs`, or
   `vsan-default-storage-policy` on vSAN.
2. **VM Service** → *Add VM Class* → pick at least one — `best-effort-small` is enough.

Do not add a content library; guest-cluster node images do not come from one.

No permission to create namespaces? Ask your vSphere admin for one, with those two things attached.

### Check it before Step 4

Run this **after Step 3** — that is where `make vks-login` writes the Supervisor kubeconfig this
check reads. **Both must print something.**

```bash
cd vks-airgap-cicd
export KUBECONFIG=./secrets/supervisor.kubeconfig
kubectl -n "$VKS_NAMESPACE" get storagepolicyquotas
kubectl -n "$VKS_NAMESPACE" get virtualmachineclass
```

| result | what to do |
|---|---|
| both list something | you are ready for Step 4 |
| `storagepolicyquotas` empty | go back and add the storage policy |
| `virtualmachineclass` empty | go back and add the VM class |

A namespace missing either still accepts the cluster in Step 4, then never finishes provisioning it.

---

## 2. Harbor

The registry every image comes from.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)

> **Already have Harbor?** Many labs ship it. Check first — vCenter → Workload Management →
> **Supervisor Services**, or `kubectl get ns | grep harbor`. If it is there, **skip the install
> below** and go straight to the `.env` table at the end of this step; you need its FQDN and an
> account, not a second installation.

1. Give Harbor an **NGINX LoadBalancer** (`enableNginxLoadBalancer: true`, set in 2.4 below).
   Contour is not covered by this runbook.
2. vCenter → Workload Management → Supervisor Services → **Add New Service** → upload
   `supervisor-service-harbor-legacy-*.yml` (use the `-legacy` file for a disconnected Supervisor).
3. Decide two values:

   | | example | how to get it |
   |---|---|---|
   | Harbor's FQDN | `harbor.env1.lab.test` | **you choose it.** It must be a name your real DNS can answer, because the guest cluster's nodes resolve it — see 2.6 below. |
   | Harbor's storage class | `wcp-vmfs` (single-host VMFS)<br>`vsan-default-storage-policy` (vSAN) | `kubectl get storageclass` against the Supervisor. No access yet? vCenter → your Namespace → **Storage** tab, then lowercase the policy name and replace spaces with `-`. |

4. Edit the data-values file you downloaded:

   ```bash
   cd vks-airgap-cicd            # from Step 0
   src=~/Downloads/vcf/supervisor-service-harbor-data-values-v2.14.3.yml
   HARBOR_FQDN='harbor.env1.lab.test'      # <- your value from the table above
   HARBOR_STORAGE_CLASS='wcp-vmfs'         # <- your value from the table above

   cp "$src" harbor-values.yaml
   sed -i \
     -e "s/hostname: yourdomain.com/hostname: ${HARBOR_FQDN:?}/" \
     -e 's/enableNginxLoadBalancer: false/enableNginxLoadBalancer: true/' \
     -e "s/insert-storage-class-name-here/${HARBOR_STORAGE_CLASS:?}/" \
     -e 's/enableContourHttpProxy: true/enableContourHttpProxy: false/' \
     harbor-values.yaml

   diff "$src" harbor-values.yaml          # expect exactly 4 changed lines
   ```

   Then open `harbor-values.yaml` and replace **every `[Required]` secret** with a distinct value of
   your own: `harborAdminPassword` (ships the known default `Harbor12345` — change it),
   `secretKey` (exactly 16 chars), `core.xsrfKey` (exactly 32 chars), `database.password`,
   `core.secret`, `jobservice.secret`, `registry.secret`.
   Leave `tls.crt` / `tls.key` / `ca.crt` empty. Do not touch `tlsCertificate.tlsSecretLabels`.

5. Supervisor Services → Harbor → **Manage Service** → paste `harbor-values.yaml` → Finish.
6. Get the ingress IP and create a **real DNS A record** for your FQDN:

   Read it in vCenter (**Workload Management → Supervisor Services → Harbor**), or with `kubectl`
   **once you have finished Step 3** — nothing before Step 3 has written a Supervisor kubeconfig:

   ```bash
   kubectl --kubeconfig ./secrets/supervisor.kubeconfig get svc -A | grep -i harbor
   # take the EXTERNAL-IP and create   harbor.env1.lab.test -> that IP   in your DNS
   ```

   `/etc/hosts` is **not** enough — the guest cluster's nodes must resolve it too (see notes).

**Expect:** Harbor's UI answers at `https://<your FQDN>/`. *(~10 min)*

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `HARBOR_URL` | `harbor.env1.lab.test` | the FQDN you chose. **Bare host — no `https://`, no trailing slash.** |
| `HARBOR_USERNAME` | `admin` | Harbor's built-in admin (Step 7 replaces it with a robot) |
| `HARBOR_PASSWORD` | *your value* | the `harborAdminPassword` you set in `harbor-values.yaml` above |
| `HARBOR_INFRA_PROJECT` | `cicd` | **you choose** — the Harbor project for pipeline images |
| `HARBOR_APP_PROJECT` | `apps` | **you choose** — the Harbor project for app images |

---

## 3. ArgoCD

The GitOps engine, running on the Supervisor.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html)

> **Already have ArgoCD?** Check: `kubectl get argocd -A`, or vCenter → Workload Management →
> **Supervisor Services**. If it is there, skip sub-steps 1, 2 and 5 — you still need **3.3** (the
> Supervisor CA), **3.4** (log in) and the `.env` table at the end.

1. Supervisor Services → **Add New Service** → upload `supervisor-service-argocd-legacy-*.yml`.
2. Create a vSphere Namespace for the instance — **same procedure as [1b](#1b-the-vsphere-namespace)**
   (storage policy + VM class). It can be the one from 1b or a separate one; note which, because
   `ARGOCD_NAMESPACE` below is the namespace the **instance** ends up in, and they are often not the
   same.

3. **Get the Supervisor's CA.** You need it to log in without disabling TLS verification. It comes
   from **vCenter**, not the Supervisor (the Supervisor serves only its leaf certificate):

   ```bash
   cd vks-airgap-cicd            # from Step 0
   VCENTER=vcsa.env1.lab.test          # <- YOUR vCenter FQDN, NOT the Supervisor IP

   # -k is deliberate: you are FETCHING a trust anchor that you then authenticate OUT OF BAND by
   # its SHA-256 fingerprint. The fingerprint authenticates it, not the transport.
   curl -sk -o /tmp/vmca.zip "https://${VCENTER}/certs/download.zip"
   unzip -j -o /tmp/vmca.zip 'certs/lin/*.0' -d ./secrets/vmca/

   # A vCenter with more than one trusted root yields SEVERAL files — do NOT blind-copy.
   # Print the subjects and take the one whose CN matches the issuer your Supervisor presents:
   for f in ./secrets/vmca/*.0; do echo "$f"; openssl x509 -in "$f" -noout -subject; done
   printf '' | openssl s_client -connect "${SUPERVISOR_HOST}:443" 2>/dev/null \
     | openssl x509 -noout -issuer            # <- match this

   cp ./secrets/vmca/<the-matching-file>.0 ./secrets/supervisor-ca.crt
   chmod 0644 ./secrets/supervisor-ca.crt
   openssl x509 -in ./secrets/supervisor-ca.crt -noout -fingerprint -sha256
   # ^ confirm that fingerprint with your platform team over a channel that is NOT this connection
   ```

4. **Log in.** `make` reads `.env` for you; an interactive shell does not, so load it first:

   ```bash
   cd vks-airgap-cicd            # from Step 0
   set -a; . ./.env; set +a          # loads SUPERVISOR_HOST, VKS_CONTEXT_NAME, VKS_NAMESPACE

   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --ca-certificate ./secrets/supervisor-ca.crt --auth-type basic
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"      # note the <ctx>:<ns> colon form
   ```

   `vcf context use` can print an error about a "system Harbor registry" **and still have
   worked** — judge it by the next command, not its exit code.

5. Apply the instance CR. `kubectl explain argocd.spec.version` lists what your operator supports:

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: <the namespace from 3.2> }
   spec: { version: <a supported version> }
   ```

6. Get its address, then read the initial admin login that ArgoCD generated.

   ```bash
   kubectl get svc -n <that namespace>                     # argocd-server -> EXTERNAL-IP
   kubectl get secret -n <that namespace> argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo
   argocd login <EXTERNAL-IP>
   argocd account update-password
   ```

**Expect:** `argocd-server` has an EXTERNAL-IP and you can log in. *(~10 min)*

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `ARGOCD_NAMESPACE` | `lab` | the namespace your ArgoCD **instance** runs in. **Discover it — do not assume:** `kubectl get argocd -A` (on one real lab this was `lab`, not the `argocd-instance-1` from 3.2) |
| `ARGOCD_SERVER` | `192.168.101.131` | the `argocd-server` EXTERNAL-IP from 3.6 |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | the file you created in 3.3 above |
| `VKS_AUTH_METHOD` | `vcf` | **set this to `vcf` now.** It selects how you log in, and `vcf` is the Supervisor login this step is doing. Step 4 changes it to `kubeconfig`. |

Log in, which writes the Supervisor kubeconfig every later step reads:

```bash
cd vks-airgap-cicd
make vks-login                # writes ./secrets/supervisor.kubeconfig
```

**Expect:** `./secrets/supervisor.kubeconfig` exists. Step 1b's namespace check and Step 4 both need it.

---

## 4. Guest cluster

Where Gitea, Tekton and your apps run. You need cluster-admin on it.
*Already have a cluster? Skip to "Get its kubeconfig" below.*

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VKS_K8S_VERSION` | `v1.32.10+vmware.1-fips` | `kubectl get kubernetesreleases` — one that is both Ready and Compatible |

<details><summary>Optional — the cluster's shape. Skip unless you want to change it.</summary>

| key | default | example | how to get the value |
|---|---|---|---|
| `VKS_CLUSTERCLASS` | `builtin-generic-v3.6.0` | `builtin-generic-v3.6.0` | `kubectl get clusterclass -A` — the newest Ready one |
| `VKS_VM_CLASS` | `best-effort-small` | `best-effort-small` | `kubectl get virtualmachineclass` |
| `VKS_STORAGE_CLASS` | `wcp-vmfs` | `wcp-vmfs` | `kubectl get storageclass` |
| `VKS_CONTROL_PLANE_COUNT` | `1` | `1` | how many control-plane nodes |
| `VKS_NODE_COUNT` | `2` | `2` | how many workers. One is too small for the platform. |

</details>

```bash
cd vks-airgap-cicd            # from Step 0
make vks-cluster-create                                # applies the Cluster; provisioning is async
make vks-cluster-status                                # reports ONCE — read `endpoint :` now
make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800  # then wait for every node Ready
```

**Read the `endpoint :` line from the first command before starting the wait.** `AGREE` or
`NOT YET KNOWABLE` → carry on. `*** DIVERGENT ***` → stop and follow what it prints; the waiting
form will not show it for 30 minutes.

**Expect:** the waiting command reprints a table every 15 s, then exits `0` with every node
`Ready`. *(**4–6 min**)* A non-zero exit is not a pass — do not continue to Step 5.

⚠️ **Do not reuse a cluster name you deleted recently** — it never converges. Pick a new one. See
the notes for the measurement.

### Get its kubeconfig

**If that command exited `0`, it already wrote one** — at `./secrets/<VKS_CLUSTER_NAME>.kubeconfig`,
read straight from the cluster's own Secret.

⚠️ The file existing is not proof the cluster is ready — the Secret is minted before the nodes
join, and no later check tests for workers. Only the `0` exit above means both. Use it:

```bash
cd vks-airgap-cicd            # from Step 0
set -a; . ./.env; set +a
kubectl --kubeconfig "./secrets/${VKS_CLUSTER_NAME}.kubeconfig" get nodes -o wide
```

**Expect:** your nodes listed, all `Ready`.

<details><summary>No Supervisor access (the Scenario-2 tenant)? Ask the <code>vcf</code> CLI instead</summary>

```bash
cd vks-airgap-cicd            # from Step 0
set -a; . ./.env; set +a
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file "./secrets/${VKS_CLUSTER_NAME}.kubeconfig"
```

MEASURED 2026-08-09: on one 9.1 lab this failed with `Error: failed to get pinniped-info from
management cluster` while the Secret route above worked. If you hit that and you *do* have a
Supervisor kubeconfig, use the Secret route — it is the same credential.
</details>

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `KUBECONFIG` | `./secrets/cicd-gc1.kubeconfig` | `./secrets/<your VKS_CLUSTER_NAME>.kubeconfig` — the file above |
| `VKS_CONTEXT` | `cicd-gc1-admin@cicd-gc1` | `kubectl --kubeconfig ./secrets/<cluster>.kubeconfig config get-contexts -o name` |
| `VKS_AUTH_METHOD` | `kubeconfig` | **change it back from `vcf`** (Step 3 set that for the Supervisor login). From here on the pipeline runs against the guest-cluster kubeconfig above. |

---

## 5. Preflight

Catches what would otherwise kill the run *after* a 20-minute mirror.

```bash
cd vks-airgap-cicd            # from Step 0
make vks-login                # now checks the GUEST kubeconfig (Step 4 set VKS_AUTH_METHOD=kubeconfig)
make lab-preflight
make psa-check
```

**Expect:** `LAB PREFLIGHT OK`. `PSA UNPROVEN` on a bare cluster is expected, not a failure. *(~1 min)*

---

## 6. Harbor's CA

Harbor uses a self-signed certificate. Save its CA so the jump box and the cluster trust it.
Harbor publishes it — no login needed:

```bash
cd vks-airgap-cicd            # from Step 0
set -a; . ./.env; set +a
curl -sk "https://${HARBOR_URL}/api/v2.0/systeminfo/getcert" > ./secrets/harbor-ca.crt
chmod 0644 ./secrets/harbor-ca.crt
openssl x509 -in ./secrets/harbor-ca.crt -noout -subject     # expect: CN = Harbor CA
```

If that last command errors instead of printing a subject, this Harbor does not publish its CA
there — use one of the alternatives below.

Then **check it against a digest you got from whoever runs Harbor**, over some other channel —
`-k` above means you fetched it over a connection you could not yet verify:

```bash
sha256sum ./secrets/harbor-ca.crt
```

**Expect:** the file exists, is `0644`, its subject is a CA, and the digest matches. *(<1 min)*

<details><summary>Alternatives if that endpoint is unavailable</summary>

- Harbor's UI: your project → **Registry Certificate** → download `ca.crt`.
- From the cluster, if you have Supervisor access:

  ```bash
  cd vks-airgap-cicd            # from Step 0
  make harbor-ca-from-cluster
  ```

`make fetch-harbor-ca` only works when Harbor's certificate is self-signed. If Harbor presents a
certificate issued by a separate CA — the usual case — the CA is not on the connection and that
command will tell you so and stop.

</details>

---

## 7. Harbor robot (recommended)

CI pushes with a scoped credential instead of `admin`.

```bash
cd vks-airgap-cicd            # from Step 0
make harbor-robot            # writes ./secrets/harbor-robot.env (mode 0600)
cat ./secrets/harbor-robot.env
```

**Expect:** a `robot$vks-cicd` account scoped to your two projects. Needs project-admin. *(<1 min)*

**→ set in `./.env`:** copy the two lines from `./secrets/harbor-robot.env` over the existing
`HARBOR_USERNAME` / `HARBOR_PASSWORD`.

---

## 8. The Supervisor kubeconfig ArgoCD needs

`make gitops` talks to **both** clusters: ArgoCD on the Supervisor, your apps in the guest.

**→ set in `./.env` first** (both commands below read these):

| key | example | how to get the value |
|---|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` | the file the next command writes. **Set it explicitly** — left unset it falls back to your *guest* kubeconfig, and `make gitops` then looks for ArgoCD in the wrong cluster. |
| `ARGOCD_DEST_CLUSTER_NAME` | `vks-guest` | the name your guest cluster is registered under: `argocd cluster list`. **Required if more than one cluster is registered** — otherwise the next command stops with `AMBIGUOUS destination` rather than risk deploying into another tenant's cluster. |

```bash
cd vks-airgap-cicd            # from Step 0
make fetch-argocd-kubeconfig
make argocd-preflight           # CLI vs running-server versions; can ArgoCD reach your cluster?
```

**Expect:** `PREFLIGHT OK`. If it says your guest cluster is not registered:

```bash
make argocd-register-guest      # admin-only; creates an SA in your guest + a Secret in ArgoCD's ns
```

`make argocd-version` prints the CLI, the **running server** and this repo's pin. The running
server is the one that matters. *(~2 min)*

---

## 9. Validate, then install

```bash
cd vks-airgap-cicd            # from Step 0
make env-populate     # generates Gitea's admin password; discovers anything you left blank
make env-check        # every required value set? (fast, no network)
make env-validate     # does KUBECONFIG reach the cluster? does Harbor authenticate?

make install-all      # preflight -> mirror -> builder -> platform -> gitops
make verify           # pushes a marked change and follows it to the running app
```

**Expect:** `env-validate` reports Harbor reachable **and authenticated**; `install-all` completes;
`make verify` exits **0** for every app. *(**install-all 8–10 min**, **verify 3–4 min**)*

---

## 10. Ingress (optional)

Reach the UIs at `*.vks.local` instead of port-forwarding.

```bash
cd vks-airgap-cicd            # from Step 0
make istio-preflight
```

| It says | You run |
|---|---|
| **NO Istio detected** | `make install-ingress` — installs Istio from your Harbor |
| **Istio already here** | `make install-ingress INGRESS_CONTROLLER=istio-existing` — attaches routes only, installs nothing |

On a real lab Istio is usually already present as a Standard Package — attach, do not install.
*(~5 min)*

---

## 11. Access the UIs

```bash
cd vks-airgap-cicd            # from Step 0
make creds-show
```

**Expect:** every URL and login — Harbor, ArgoCD, Gitea, Tekton, one row per app. Each value is
labelled **DISCOVERED** (read live) or **STORED** (remembered).

Skipped Step 10? The `*.vks.local` URLs will not resolve — reach a service directly instead:

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000     # then http://localhost:3000
kubectl -n javawebapp port-forward svc/javawebapp 18080:80 # then http://localhost:18080
```

---

## 12. Uninstall

Removes what this runbook installed. It does not touch the vSphere lab.

```bash
cd vks-airgap-cicd            # from Step 0
make uninstall-all CONFIRM=<your VKS_CLUSTER_NAME>
```

**Expect:** it deletes only objects carrying our ownership label, and **prints what it left alone**.
*(~1 min)*

**It will not** delete the Harbor projects/robot, `secrets/`, or `/etc/hosts` — it prints those
commands for you to run. A failed read is reported `CANNOT READ` and counted as not done.

---

## Timings

Two runs on a 9.1 lab (i9-14900KF / 188 GiB) hosting the nested lab on the same box, so these are
under self-contention. Where the runs disagree, both are shown.
[Conditions](scenario-1-notes.md#timings--what-these-numbers-do-not-cover).

| Step | Command | Run 1 | Run 2 |
|---|---|---|---|
| 4 | `make vks-cluster-create` | <1 s | <1 s |
| 4 | cluster → all nodes `Ready` | **3 m 45 s** | **≈ 6 m** |
| 5 | `make preflight` | 2 s | 2 s |
| 6 | `make harbor-ca-from-cluster` | <1 s | <1 s |
| 9 | `make env-check`, `make env-validate` | <1 s each | <1 s each |
| 9 | `make install-all` | **10 m 26 s** | **8 m 14 s** |
| ↳ | `mirror-pull` / `mirror-push` / `mirror-verify` | 22 s / 2 m 38 s / 5 m 46 s | — |
| ↳ | `builder-image` + `platform` + `gitops` | ≈1 m 40 s | — |
| 9 | `make verify` (2 apps) | **3 m 6 s** | **3 m 27 s** |
| 12 | `make uninstall-all` | 1 m 12 s | 1 m 12 s |

From a **bare Photon jump box** (fresh box, nothing cached — so the mirror pulls every image), the
same lab, measured start to `End-to-end verified`:

| | |
|---|---|
| Step 0–1 install `git`/`make`, clone, `make deps`, install the CLIs | ≈ 2 m 30 s |
| Step 4 cluster created → every node `Ready` | **8 m 49 s** |
| Step 9 `make install-all` + `make verify` | **10 m 08 s** |
| **whole run, clone → verified** | **21 m 31 s** |
