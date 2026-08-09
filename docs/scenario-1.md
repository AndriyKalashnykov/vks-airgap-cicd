# Scenario 1 — you install Harbor and ArgoCD

## What this is

You have a **Supervisor** endpoint, a login and a password. This runbook installs Harbor and ArgoCD
as Supervisor Services, creates a guest VKS cluster, and runs an air-gapped CI/CD pipeline into it.

**What you end up with:** `git push` → Tekton builds → image to Harbor → tag written back → ArgoCD
syncs → the app serves the change. Two demo apps (Java and Go), proven by `make verify`.

**Topology — two clusters, two kubeconfigs.** Harbor and ArgoCD run on the **Supervisor**. Gitea,
Tekton and your apps run in the **guest cluster**.

> **Why a step is shaped the way it is** → [scenario-1-notes.md](scenario-1-notes.md). You do not
> need it for a normal install. Read it when a step surprises you, or before you simplify one.

## The whole sequence

Run these in this order. Steps 2 and 3 are browser work; everything else is a command.

| | Step | You do |
|---|---|---|
| **0** | [Get the repo](#0-get-the-repo) | clone it, `cd` into it, create `.env` |
| **1** | [Jump box](#1-jump-box) | install the toolchain; fill in 7 values in `.env` |
| **1b** | [vSphere Namespace](#1b-the-vsphere-namespace) | browser: create it, attach storage + a VM class |
| **2** | [Harbor](#2-harbor-browser) | browser: install it; fill in 6 values |
| **3** | [ArgoCD](#3-argocd-supervisor) | browser + CLI: install it, get the CA, log in; fill in 4 values |
| **4** | [Guest cluster](#4-guest-cluster) | create it; fill in 4 values |
| **5** | [Preflight](#5-preflight) | check the cluster will accept the install |
| **6** | [Harbor's CA](#6-harbors-ca) | fetch it |
| **7** | [Harbor robot](#7-harbor-robot-recommended) | create it; replace 2 values |
| **8** | [ArgoCD's kubeconfig](#8-the-supervisor-kubeconfig-argocd-needs) | fetch it; fill in 3 values |
| **9** | [Install](#9-validate-then-install) | `make install-all`, then `make verify` |
| **10** | [Access the UIs](#10-access-the-uis) | `make creds-show` |
| **11** | [Ingress](#11-ingress-optional) | optional |
| **12** | [Remove it again](#12-removing-it-again) | `make lab-down` |

**Everything you configure goes in ONE file: `.env`, at the root of the repo you clone in Step 0.**
Each step ends with a table of the keys it sets, with an example and where the value comes from.

**Jump-box OS:** Ubuntu or VMware Photon OS — the two the tooling installs packages for
(`apt` / `tdnf`). The jump box must reach **both** the internet and the lab, and must resolve the
vCenter FQDN and Supervisor IP you collect in Step 0. Where each `.env` address has to resolve
differs — most are IPs this repo discovers for you, but **Harbor's FQDN must answer in your real
DNS, because the guest cluster's nodes resolve it too** (Step 2), and the `*.vks.local` names are
`/etc/hosts`-only and never resolve in DNS. Internet-only? Use
[the sneakernet flow](sneakernet.md) instead; it replaces Step 9.

---

## 0. Get the repo

Everything below runs **from the repo root**. Nothing works from another directory.

A stock Ubuntu or Photon box has **neither `git` nor `make`** (measured on `ubuntu:24.04` and
`photon:5.0`), so install them first.

```bash
# Ubuntu / Debian
apt-get update && apt-get install -y --no-install-recommends git make ca-certificates
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

> **Shortcut:** the repo ships a one-command bootstrap that installs those packages, clones the repo
> and runs Step 1's `make deps` for you — see
> [Bootstrap an unprovisioned jump box](../README.md#bootstrap-an-unprovisioned-jump-box-before-you-can-clone-this-repo)
> in the README. It does **not** create `.env`, so afterwards
> still run `cd vks-airgap-cicd && make env-init` and continue from Step 1's `make install-vcf-clis`.

**Expect:** `./.env` exists. Open it in your editor — it is the one file you edit for the rest of
this runbook, and every step below ends with a table of the keys it wants you to set in it.

**Collect these from your lab before Step 1** — you paste them into `.env`:

| What | Example | Where to find it |
|---|---|---|
| Supervisor IP | `192.168.101.128` | vCenter → Workload Management → Supervisors → *Control Plane Node IP* |
| vCenter FQDN | `vcsa.env1.lab.test` | the address you log into vCenter with (Step 3 needs it for the CA). **Your jump box must resolve it** — check: `getent hosts vcsa.env1.lab.test` |
| your SSO user | `administrator@vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups |
| your SSO domain | `vsphere.local` | same screen, the *Domain* dropdown |
| the password | — | **never goes in `.env`** — you type it at a prompt in Step 3 |

---

## 1. Jump box

Install the toolchain and the licensed CLIs.

**→ set in `./.env` before you run the commands below.** `VCF_CLI_SRC_DIR` is read by
`make install-vcf-clis` in this step — without it that command **fails**. The other six are read
from Step 3 onward; you collected four of them in Step 0, and you invent two.

| key | example | how to get the value |
|---|---|---|
| `VCF_CLI_SRC_DIR` | `/home/you/Downloads/vcf` | the folder you put the two Broadcom archives in |
| `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → Control Plane Node IP. **Bare host — no `https://`, no trailing slash.** |
| `VKS_CONTEXT_NAME` | `vks-cicd` | **you invent this** — a short label for the `vcf` login context |
| `VKS_NAMESPACE` | `lab` | the vSphere Namespace the cluster goes in. **Create it first — see 1b below.** |
| `VKS_CLUSTER_NAME` | `cicd-gc1` | **you invent this** — the guest cluster Step 4 creates. Must not be a name you deleted recently (see notes). |
| `VKS_USERNAME` | `administrator@vsphere.local` | your vCenter SSO login |
| `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups → *Domain* |

Your password has no key here — you type it at a prompt in Step 3.

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

Put its name in `VKS_NAMESPACE` and go to Step 2.

### If you don't — create it

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

Worth the 10 seconds: a namespace missing either still **accepts** the cluster in Step 4, then never
finishes provisioning it.

---

## 2. Harbor (browser)

The registry every image comes from.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)

1. Give Harbor an **NGINX LoadBalancer**. That is what step 4 below configures
   (`enableNginxLoadBalancer: true`) and the only path tested here. Harbor also supports Contour,
   but this runbook does not configure it and has not been run that way.
2. vCenter → Workload Management → Supervisor Services → **Add New Service** → upload
   `supervisor-service-harbor-legacy-*.yml` (use the `-legacy` file for a disconnected Supervisor).
3. Decide two values:

   | | example | how to get it |
   |---|---|---|
   | Harbor's FQDN | `harbor.env1.lab.test` | **you choose it.** It must be a name your real DNS can answer, because the guest cluster's nodes resolve it — see step 6 below. |
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
| `HARBOR_CA_FILE` | `./secrets/harbor-ca.crt` | the path Step 6 writes to — leave as-is |
| `HARBOR_INFRA_PROJECT` | `cicd` | **you choose** — the Harbor project for pipeline images |
| `HARBOR_APP_PROJECT` | `apps` | **you choose** — the Harbor project for app images |

---

## 3. ArgoCD (Supervisor)

The GitOps engine, running on the Supervisor.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html)

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

   It prompts for your password. `vcf context use` can print an error about a "system Harbor
   registry" **and still have worked** — judge it by the next command, not its exit code.

   > **The password is typed, never stored.** It has no `.env` key, and this repo will not read one.
   >
   > ⛔ **Do not run `vcf config set env.VCF_CLI_VSPHERE_PASSWORD …`.** It writes your SSO password in
   > **plaintext** to `~/.config/vcf/config.yaml` — outside this repo, outside every secret scan here,
   > and it survives every teardown in this runbook.
   >
   > If you need it non-interactively (re-runs, a long `make install-all` that may re-prompt on token
   > refresh), put it in the environment for the session only:
   >
   > ```bash
   > read -rs VCF_CLI_VSPHERE_PASSWORD; export VCF_CLI_VSPHERE_PASSWORD   # typed, not echoed
   > # ... run your steps ...
   > unset VCF_CLI_VSPHERE_PASSWORD
   > ```
   >
   > That keeps it off the command line and out of shell history, but **it is not secret from
   > yourself**: anything running as your user, and root, can read it with `ps eww`, and every
   > process the shell spawns inherits it. `unset` it when you are done.
   >
   > ⚠️ **Get it right the first time.** vCenter SSO locks an account after **5 failed attempts
   > within 3 minutes** by default (auto-unlocks after 5 minutes) — but that policy is configurable
   > and your lab may be stricter. Check yours before looping on a guess.

5. Apply the instance CR. `kubectl explain argocd.spec.version` lists what your operator supports:

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: <the namespace from step 2> }
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
| `ARGOCD_NAMESPACE` | `lab` | the namespace your ArgoCD **instance** runs in. **Discover it — do not assume:** `kubectl get argocd -A` (on one real lab this was `lab`, not the `argocd-instance-1` from step 2) |
| `ARGOCD_SERVER` | `192.168.101.131` | the `argocd-server` EXTERNAL-IP from step 6 |
| `ARGOCD_TRACK_BRANCH` | `main` | the branch ArgoCD follows in the deploy repos — leave as-is unless you renamed it |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | the file you created in step 3 above — leave as-is |
| `VKS_AUTH_METHOD` | `vcf` | **set this to `vcf` now.** It selects how you log in, and `vcf` is the Supervisor login this step is doing. Step 4 changes it to `kubeconfig`. |

⚠️ `VKS_AUTH_METHOD` defaults to `kubeconfig`, which means *"validate a workload-cluster kubeconfig I
already have"* — you don't have one yet. Leave it unset here and the next command fails with
`VKS_AUTH_METHOD=kubeconfig but ./secrets/vks.kubeconfig is empty`.

Finally, log in through the repo so it writes the Supervisor kubeconfig everything after this reads:

```bash
cd vks-airgap-cicd
make vks-login                # prompts for your password; writes ./secrets/supervisor.kubeconfig
```

**Expect:** `./secrets/supervisor.kubeconfig` exists. Step 1b's namespace check and Step 4 both need it.

---

## 4. Guest cluster

Where Gitea, Tekton and your apps run. You need cluster-admin on it.
*Already have a cluster? Skip to "Export its kubeconfig".*

**→ set in `./.env` before you run this.** Only `VKS_K8S_VERSION` is **required** — the command
aborts without it. The rest already have working defaults; set one only to override it.

| key | required? | example | how to get the value |
|---|---|---|---|
| `VKS_K8S_VERSION` | **yes** | `v1.32.10+vmware.1-fips` | `kubectl get kubernetesreleases` — one that is both Ready and Compatible |
| `VKS_CLUSTERCLASS` | no — defaults | `builtin-generic-v3.6.0` | `kubectl get clusterclass -A` on the Supervisor — the newest Ready one |
| `VKS_VM_CLASS` | no — defaults | `best-effort-small` | `kubectl get virtualmachineclass` |
| `VKS_STORAGE_CLASS` | no — defaults | `wcp-vmfs` | `kubectl get storageclass` |
| `VKS_CONTROL_PLANE_COUNT` | no — defaults to `1` | `1` | how many control-plane nodes |
| `VKS_NODE_COUNT` | no — defaults to `2` | `2` | how many workers. Leave it unset; `.env.example`'s commented `=1` is deliberately **not** the default, and one worker is too small for the platform. |

```bash
cd vks-airgap-cicd            # from Step 0
make vks-cluster-create                                # applies the Cluster; provisioning is async
make vks-cluster-status                                # reports ONCE — read `endpoint :` now
make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800  # then wait for every node Ready
```

**Run the plain one first, and read its `endpoint :` line before you start waiting.** That line is
where a doomed cluster announces itself, and the waiting form does not print it until it gives up —
so starting with the wait means 30 minutes of silence before you learn the cluster was never going
to converge. `endpoint : AGREE` (or `NOT YET KNOWABLE` on a brand-new one) means carry on;
`*** DIVERGENT ***` means stop and read what it prints.

**Expect:** the waiting command blocks and reprints a status table every 15 s, then exits `0` with
every node `Ready`. *(**4–6 min**)* On timeout it exits **non-zero** — that is not a pass, and you
must not continue to Step 5.

⚠️ **Do not reuse a cluster name you deleted recently** — it never converges. Pick a new one. See
the notes for the measurement.

### Get its kubeconfig

**If that command exited `0`, it already wrote one** — at `./secrets/<VKS_CLUSTER_NAME>.kubeconfig`,
read straight from the cluster's own Secret.

⚠️ **The file existing is not proof the cluster is ready.** The platform mints that Secret *before*
the nodes join, so a kubeconfig can exist for a cluster that cannot schedule anything — and the
later checks only test that the file is there and the control plane answers, not that you have
workers. Only the `0` exit above means both. Use it:

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
| `GITEA_ADMIN_PASSWORD` | *your value* | **you choose it** — Gitea is installed by this repo, so you set its admin password |

---

## 5. Preflight

Catches what would otherwise kill the run *after* a 20-minute mirror.

```bash
cd vks-airgap-cicd            # from Step 0
make vks-login
make lab-preflight
make psa-check
```

**Expect:** `LAB PREFLIGHT OK`. `psa-check` says `PSA UNPROVEN` on a bare cluster — that is the
expected answer, not a failure. *(~1 min)*

---

## 6. Harbor's CA

`crane` on the jump box and Kaniko in-cluster must trust Harbor's self-signed certificate.

**Route A — the Harbor UI (prefer this; needs only a Harbor login):**
Harbor → your project → **Registry Certificate** → download `ca.crt` → save it as
`./secrets/harbor-ca.crt`.

**Route B — from the cluster** (needs Supervisor access *and* an admin-level grant — see notes):

```bash
cd vks-airgap-cicd            # from Step 0
make harbor-ca-from-cluster
```

**Verify it either way** — ask whoever runs Harbor for the CA's SHA-256 first, over a channel that
is not this connection:

```bash
cd vks-airgap-cicd            # from Step 0
make fetch-harbor-ca HARBOR_CA_SHA256='<the digest they gave you>'
```

**Expect:** `./secrets/harbor-ca.crt` exists, is `0644`, and its SHA-256 matches. *(<1 min)*

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
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | already set in Step 3. If you skipped that, set `VKS_INSECURE_SKIP_TLS_VERIFY=true` instead — but the CA is preferred, because a password crosses this connection. |
| `ARGOCD_NAMESPACE` | `lab` | already set in Step 3 — confirm with `kubectl get argocd -A` |

```bash
cd vks-airgap-cicd            # from Step 0
make fetch-argocd-kubeconfig    # prompts for your password
make argocd-preflight           # CLI vs running-server versions; can ArgoCD reach your cluster?
```

**Expect:** `PREFLIGHT OK`. If it says your guest cluster is not registered:

```bash
make argocd-register-guest      # admin-only; creates an SA in your guest + a Secret in ArgoCD's ns
```

`make argocd-version` prints the `argocd` CLI, the **running server** and this repo's pin side by
side. The running server is the one that matters. *(~2 min)*

---

## 9. Validate, then install

```bash
cd vks-airgap-cicd            # from Step 0
make env-populate     # generates the Gitea secret; discovers anything you left blank
make env-check        # every required value set? (fast, no network)
make env-validate     # does KUBECONFIG reach the cluster? does Harbor authenticate?

make install-all      # preflight -> mirror -> builder -> platform -> gitops
make verify           # pushes a marked change and follows it to the running app
```

**Expect:** `env-validate` reports Harbor reachable **and authenticated**; `install-all` completes;
`make verify` exits **0** for every app. *(**install-all 8–10 min**, **verify 3–4 min**)*

---

## 10. Access the UIs

```bash
cd vks-airgap-cicd            # from Step 0
make creds-show
```

**Expect:** every URL and login — Harbor, ArgoCD, Gitea, Tekton, and one row per app. Values are
labelled **DISCOVERED** (read from the live cluster) or **STORED** (remembered), so you can tell
current from stale.

No ingress yet? Reach a service directly:

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000     # then http://localhost:3000
kubectl -n javawebapp port-forward svc/javawebapp 18080:80 # then http://localhost:18080
```

---

## 11. Ingress (optional)

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

## 12. Removing it again

```bash
make lab-down CONFIRM=<your VKS_CLUSTER_NAME>
```

**Expect:** it deletes only objects carrying our ownership label, and **prints what it left alone**.
*(~1 min)*

**It will not** delete the Harbor projects/robot (Harbor refuses to delete a project holding
repositories — forcing it could destroy a shared registry) or touch `secrets/` and `/etc/hosts`. It
prints the commands for those. If a read fails it reports `CANNOT READ` and counts the object as
**not done** — it never claims something was absent when it could not look.

---

## Timings

Measured 2026-08-08 on a real 9.1 lab, i9-14900KF / 188 GiB, **running the nested lab on the same
box** (so every number is under self-contention). Two full runs; where they disagree, both are
shown. Conditions and what they do not cover: [notes](scenario-1-notes.md#timings--what-these-numbers-do-not-cover).

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
| 12 | `make lab-down` | 1 m 12 s | 1 m 12 s |
