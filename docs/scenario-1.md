# Scenario 1 — you install Harbor and ArgoCD

## What this is

You have a **Supervisor** endpoint, a login and a password. This runbook creates a vSphere Namespace
(or uses one you already have), installs Harbor and ArgoCD as Supervisor Services, creates a guest
VKS cluster, and runs an air-gapped CI/CD pipeline into it.

**What you end up with:** `git push` → Tekton builds → image to Harbor → tag written back → ArgoCD
syncs → the app serves the change. Two demo apps (Java and Go), proven by `make verify`.

> Background for when a step surprises you → [scenario-1-notes.md](scenario-1-notes.md).

## The whole sequence

Run these in this order. Every step is a command — nothing here needs the vCenter UI.

| | Step | You do |
|---|---|---|
| **0** | [Get the repo](#0-get-the-repo) | clone it, `cd` into it, create `.env` |
| **1** | [Jump box](#1-jump-box) | install the toolchain; set 8 values in `.env` |
| **1b** | [vSphere Namespace](#1b-the-vsphere-namespace) | `make vsphere-namespace`; set 6 values |
| **2** | [Harbor](#2-harbor) | `make install-harbor-service`; set 2 values, then DNS |
| **3** | [ArgoCD](#3-argocd) | `make install-argocd-service`, get the CA, log in; set 4 values |
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

### Put the toolchain on YOUR shell's PATH

`make` finds these tools by itself, so every `make …` below works right now. The commands that are
**not** `make` — `kubectl`, `vcf`, `argocd`, starting in 1b — run in *your* shell, which cannot see
them yet: `make deps` installs into `~/.local/bin` and a `mise` tree, and neither is on a fresh
box's PATH. Skipping this gives you `kubectl: command not found` at the very next step.

```bash
make shell-init                        # permanent — detects your shell and edits the right file
export PATH="$HOME/.local/bin:$PATH"   # this shell, right now (shell-init applies to NEW ones)
```

`make shell-init` works out whether you are on bash, zsh, fish or ksh and writes to *that* shell's
rc file — you are not asked to choose. It is idempotent, and it refuses rather than guessing if it
cannot identify your shell. On an OS that ships no `~/.bash_profile` or `~/.profile` (PhotonOS is
one) it also creates `~/.bash_profile`, because a **login** bash never reads `~/.bashrc` by itself —
without that, an SSH session keeps saying `command not found` no matter what is in `~/.bashrc`.

**Expect:** in a **new** shell, `kubectl version --client` answers (and `vcf version`, after
`make install-vcf-clis`). Verified on PhotonOS and Ubuntu, for bash and zsh.

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

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VCENTER_HOST` | `vcsa.env1.lab.test` | your vCenter FQDN from Step 0 — **not** the Supervisor IP |
| `VCENTER_USERNAME` | `administrator@vsphere.local` | the same SSO login as Step 1 |
| `VCENTER_PASSWORD` | *your value* | the same password as Step 1 |
| `VKS_STORAGE_POLICY` | `wcp-vmfs` (single-host VMFS)<br>`vsan-default-storage-policy` (vSAN) | **Per-lab, not a constant** — those two are what real labs measured. **Already have a namespace? `make vsphere-namespace` prints the policy it uses, by name** — no kubeconfig needed. Otherwise vCenter → **Policies and Profiles → VM Storage Policies**; if you set it wrong the create stops and lists every available policy. |
| `VKS_VM_CLASSES` | `best-effort-small best-effort-medium` | space-separated; `best-effort-small` alone is enough. Defaults to the example, and the names are **sent to vCenter unchecked** — a class that does not exist fails with an HTTP code that does not mention VM classes. |
| `VKS_CLUSTER_COMPUTE` | *(leave unset)* | **only if** vCenter has **more than one** cluster. Steps 2 and 3 need it too, not just this one. |

⚠️ **`make vsphere-namespace` will not modify a namespace that already exists** — it prints what is
attached and changes nothing. So if the check below finds a missing storage policy or VM class, fix
it in vCenter (or delete and recreate the namespace); re-running with a corrected `.env` is a no-op.

```bash
make vsphere-namespace
```

**Expect:** `created vSphere Namespace '<name>' …` then `namespace '<name>' is RUNNING`.
It is idempotent — run it against a namespace that already exists and it prints what is attached
and changes nothing.

Do not add a content library; guest-cluster node images do not come from one.

No permission to create namespaces? Ask your vSphere admin for one, with a storage policy and a
VM class attached.

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

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `HARBOR_URL` | `harbor.env1.lab.test` | **you choose it.** It must be a name your real DNS can answer — the guest cluster's nodes resolve it. **Bare host — no `https://`, no trailing slash.** |
| `HARBOR_STORAGE_CLASS` | `wcp-vmfs` (single-host VMFS)<br>`vsan-default-storage-policy` (vSAN) | `kubectl get storageclass` against the Supervisor. No access yet? vCenter → your Namespace → **Storage** tab, then lowercase the policy name and replace spaces with `-`. |
| `HARBOR_USERNAME` | `admin` | **Only if you SKIPPED the install.** The install below generates this and publishes it for you; a Harbor you did not install has published nothing. See *Where to get them* below. |
| `HARBOR_PASSWORD` | *your value* | Same — **only if you skipped the install.** MEASURED: without these two, `make harbor-robot` stops with *"set HARBOR_USERNAME in .env to the Harbor ADMIN"*, `make env-check` reports `HARBOR_USERNAME` missing, and `make env-validate` reports *"Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)"*. |

**Where to get them when you skipped the install.** A Harbor deployed as a Supervisor Service
**generates** its admin password at install time — it is *not* the vendor default `Harbor12345`,
which is rejected `401`. In order of preference:

1. **On the box that installed it**, `make creds-show` prints it, and it is in that box's
   `.env.state`. This is the usual case when the same team ran Step 2 earlier.
2. **Ask the platform team** for an account with push+pull on your projects. A **system-level
   robot** is better than `admin` — see Step 7, which needs system-admin to mint one itself.
3. **Reset it** in Harbor's UI (*Administration → Users → admin → Change Password*) if you own it
   and nobody has the value.

Check the value before going further — it is two commands and it saves you a failure four steps
later:

```bash
printf 'user = "%s:%s"\n' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > /tmp/h.cfg   # keeps it out of argv
curl -sk -o /dev/null -w '%{http_code}\n' -K /tmp/h.cfg "https://${HARBOR_URL}/api/v2.0/users/current"; rm -f /tmp/h.cfg
```

**Expect:** `200`. A `401` means the credential is wrong — that is exactly what `make env-validate`
reports at Step 9, and finding it here costs seconds instead of a failed install.

`VCENTER_HOST` / `VCENTER_USERNAME` / `VCENTER_PASSWORD` are already set from Step 1b.

**Skipped 1b because you already had a namespace?** If your vCenter has **more than one cluster**,
set `VKS_CLUSTER_COMPUTE` (1b's table) as well — this step and Step 3 both resolve the cluster and
stop with *"could not resolve the vSphere cluster moid"* without it.

```bash
make install-harbor-service
```

**Expect:** `7 secrets generated, 0 placeholders left`, then `install issued for
harbor.tanzu.vmware.com`. It registers the service, installs it with an NGINX LoadBalancer, and
**generates every one of Harbor's seven required secrets** — including the admin password, which
otherwise ships as the published default `Harbor12345`. Nothing is hand-edited and nothing is
pasted into a browser. `HARBOR_USERNAME` and `HARBOR_PASSWORD` are written to the state overlay
for you. Re-running is safe: an already-registered service is detected and skipped.

**Then point DNS at it.** Read the ingress IP in vCenter (**Workload Management → Supervisor
Services → Harbor**), or with `kubectl` **once you have finished Step 3** — nothing before Step 3
has written a Supervisor kubeconfig:

```bash
make show-dns-records      # prints the exact A records, with their live LoadBalancer IPs
```

It reads the IPs out of the cluster so you do not have to hunt for them. It deliberately does
**not** create the records: every site's DNS is different, and a tool that guessed would be wrong
everywhere.

`/etc/hosts` is **not** enough — the guest cluster's nodes must resolve it too (see notes).
This is the one part of this step nobody can automate for you: it is your DNS.

**Expect:** Harbor's UI answers at `https://<your FQDN>/`. *(~10 min)*

**→ set in `./.env`:**

<details><summary>Optional — both default to working values (<code>cicd</code> / <code>apps</code>). Open only to rename them, or if you are a project-admin rather than a system-admin.</summary>

| key | default | example | how to get the value |
|---|---|---|---|
| `HARBOR_INFRA_PROJECT` | `cicd` | `cicd` | **you choose** — the Harbor project for pipeline images |
| `HARBOR_APP_PROJECT` | `apps` | `apps` | **you choose** — the Harbor project for app images. **Project-admin rather than system-admin?** Set this **equal to `HARBOR_INFRA_PROJECT`** — Step 7's robot can only be scoped to projects you administer. |

</details>

`HARBOR_USERNAME` (`admin`) and `HARBOR_PASSWORD` were **generated and published for you** by
`make install-harbor-service` — you do not set them, and the admin password is not the vendor
default. Read them back any time with `make creds-show`.

---

## 3. ArgoCD

The GitOps engine, running on the Supervisor.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html)

> **Already have ArgoCD?** Check: `kubectl get argocd -A`, or vCenter → Workload Management →
> **Supervisor Services**. If it is there, skip sub-steps 1 and 2 — you still need **3.3** (the
> Supervisor CA), **3.4** (log in) and the `.env` table at the end.

1. **Pick the namespace the INSTANCE goes in.** `ARGOCD_NAMESPACE` is where the ArgoCD you log into
   ends up, and it is often **not** the namespace the guest cluster lives in. For a separate one,
   create it exactly as in [1b](#1b-the-vsphere-namespace) (`make vsphere-namespace` with
   `VKS_NAMESPACE` pointed at it).

   ⚠️ **You must set it in `.env` either way.** Only *this* step falls back to `VKS_NAMESPACE`;
   `make fetch-argocd-kubeconfig` (Step 8), `make verify` (Step 9) and `make uninstall-all`
   (Step 12) have **no fallback** and stop with `ARGOCD_NAMESPACE must be set`. `make env-check`
   does **not** catch it, so the first symptom is Step 8 failing.

2. Install the service and its instance:

   ```bash
   make install-argocd-service
   ```

   **Expect:** `install issued for argocd-service.vsphere.vmware.com`, then — once the operator
   publishes its CRD — `ArgoCD instance argocd-1 requested in namespace <ns>`. It waits for the CRD
   rather than racing it, and asks the operator which versions it supports instead of hardcoding
   one. Re-running is safe. If you have no Supervisor kubeconfig yet it installs the service, tells
   you so, and stops before the instance — run it again after 3.4.

3. **Get the Supervisor's CA.** You need it to log in without disabling TLS verification. It comes
   from **vCenter**, not the Supervisor (the Supervisor serves only its leaf certificate):

   ```bash
   cd vks-airgap-cicd            # from Step 0
   make fetch-supervisor-ca
   ```

   It downloads vCenter's trusted roots, picks the one whose subject matches the issuer your
   Supervisor actually presents (a vCenter with several roots offers several candidates), refuses
   to install one that does not verify the live endpoint, and prints the SHA-256 fingerprint.

   **Confirm that fingerprint with your platform team over a channel that is NOT this connection.**
   The download is deliberately unverified TLS — you are fetching a trust anchor and then
   authenticating it out of band by its fingerprint; the fingerprint is what authenticates it,
   not the transport.

   > A **rebuilt** lab mints a new CA at the same address, so a stale file looks valid and is not.
   > That is why this refuses rather than overwriting blindly — and why `make vks-login` fails with
   > *"the CA at … does NOT verify"* until you re-run it.

4. **Log in.** `make` reads `.env` for you; an interactive shell does not, so load it first:

   ```bash
   cd vks-airgap-cicd            # from Step 0
   set -a; . ./.env; set +a          # loads SUPERVISOR_HOST, VKS_CONTEXT_NAME, VKS_NAMESPACE

   export VCF_CLI_VSPHERE_PASSWORD='<your SSO password>'   # else it prompts; see the note below

   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --ca-certificate ./secrets/supervisor-ca.crt \
       --username "$VKS_USERNAME" --type kubernetes --auth-type basic
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"      # note the <ctx>:<ns> colon form
   ```

   ⚠️ **`--username` is not optional in practice.** Without it `vcf` stops and asks
   `? Provide Username:`, and in anything non-interactive (a script, a container, a piped shell)
   that is an immediate `[x] : EOF` — measured on a clean Ubuntu container against a live
   Supervisor. `$VKS_USERNAME` is already loaded by the `set -a; . ./.env` line above, and
   `make vks-login` passes exactly these flags for you.

   The **password** is read from `VCF_CLI_VSPHERE_PASSWORD`; without it you get a prompt. Do **not**
   use `vcf config set env.VCF_CLI_VSPHERE_PASSWORD` — it writes your SSO password in plaintext to
   `~/.config/vcf/config.yaml`, outside this repo and outside every secret scan, and it survives
   every teardown here.

   `vcf context use` can print an error about a "system Harbor registry" **and still have
   worked** — judge it by the next command, not its exit code.

5. **Did 3.2 stop before the instance** because there was no kubeconfig yet? Run it again now —
   it is idempotent and will create the instance this time:

   ```bash
   make install-argocd-service
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
| `ARGOCD_NAMESPACE` | `lab` | the namespace your ArgoCD **instance** runs in. **Discover it — do not assume:** `kubectl get argocd -A` (on one real lab this was `lab`, not the namespace named in 3.1). Steps 8, 9 and 12 have no fallback for it. |
| `VKS_AUTH_METHOD` | `vcf` | **set this to `vcf` now.** It selects how you log in, and `vcf` is the Supervisor login this step is doing. Step 4 changes it to `kubeconfig`. |

<details><summary>Optional — both have working defaults. Skip unless yours differ.</summary>

| key | default | example | how to get the value |
|---|---|---|---|
| `ARGOCD_SERVER` | *(unset — probes skip)* | `192.168.101.131` | the `argocd-server` EXTERNAL-IP from 3.6. Only used for display and reachability probes; nothing requires it. |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | `./secrets/supervisor-ca.crt` | the file 3.3 created — the default is already that path, so set it only if you moved it. |

</details>

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
| `VKS_K8S_VERSION` | `v1.34.8+vmware.1-vkr.1` | `kubectl get kubernetesreleases` → pick one that is **Ready AND Compatible**, and paste its **full** name. This is a **prefix selector**, not an exact match: admission accepts any prefix that matches at least one release and rewrites it — so a bare `v1.34` is *accepted* and **floats** to whatever matches later, which an air-gap repo must not do. It fails only when **nothing** matches the prefix; a value that was fine on a previous lab can therefore stop matching after a rebuild. You do not have to get this right by inspection: `make vks-cluster-create` server-side dry-runs it first and prints vCenter's own rejection, which names `k8sVersionPrefix`. |

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

**Already exists?** It stops rather than overwriting — Harbor shows a robot's secret **once**, so
an existing one cannot be re-read and re-creating it would hand you a credential that does not
work. That happens on a re-run, or when someone else already ran this against the same Harbor.
Either reuse the existing `./secrets/harbor-robot.env`, or delete the robot in Harbor
(**Administration → Robot Accounts**) and run it again.

**→ set in `./.env`:** copy the two lines from `./secrets/harbor-robot.env` over the existing
`HARBOR_USERNAME` / `HARBOR_PASSWORD`.

---

## 8. The Supervisor kubeconfig ArgoCD needs

`make gitops` talks to **both** clusters: ArgoCD on the Supervisor, your apps in the guest.

**→ set in `./.env` first** (both commands below read these):

| key | example | how to get the value |
|---|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` | the file the next command writes. **Set it explicitly.** The command writes that path either way — but `make gitops` and `make verify` will not *read* it unless this key is set, and silently use your **guest** kubeconfig instead. The file existing is therefore not a sign it is being used. |
| `ARGOCD_DEST_CLUSTER_NAME` | `vks-guest` | the name your guest cluster is registered under: `argocd cluster list`. **Required whenever ArgoCD's registered API URL for your guest differs from your kubeconfig's — including when only ONE cluster is registered** (that mismatch is common). Symptom: `make install-all` stops with `AMBIGUOUS deploy destination`. Left unset with a mismatch, a run once deployed into another cluster and reported `Synced/Healthy` throughout — it was healthy, in the wrong place. |

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

Then **check the routes actually work**, before you trust the URLs in Step 11:

```bash
make verify-ingress           # each *.vks.local host must reach ITS OWN backend
```

**Expect:** one `OK` per host — `gitea`, `tekton`, and each app. It sends `Host: <name>.vks.local`
to the ingress LoadBalancer IP directly, so **it needs no DNS and no `/etc/hosts` entry** — and it
asserts a per-host body marker, not just a 200, because a mis-wired route returns 200 from the
*wrong* backend. If a host fails here, the URL Step 11 prints for it will not work either, and this
tells you which one and why. *(~1 min)*

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
