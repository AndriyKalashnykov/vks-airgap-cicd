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
| **0** | [Get the repo](#0-get-the-repo) | clone it, `cd` in, `make env-init` |
| **1** | [Jump box](#1-jump-box) | install the toolchain; fill in its table |
| **2** | [vSphere Namespace](#2-the-vsphere-namespace) | `make vsphere-namespace`; fill in its table |
| **3** | [Log in to the Supervisor](#3-log-in-to-the-supervisor) | `make vks-login` |
| **4** | [Harbor](#4-harbor) | `make install-harbor-service`; fill in its table, then DNS |
| **5** | [ArgoCD](#5-argocd) | `make install-argocd-service`, log in; `make argocd-address` writes the address |
| **6** | [Guest cluster](#6-guest-cluster) | create it; two commands write four values into `.env` for you |
| **7** | [Preflight](#7-preflight) | check the cluster will accept the install |
| **8** | [Harbor's CA](#8-harbors-ca) | fetch it |
| **8.5** | [Harbor's admin credential](#85-harbors-admin-credential) | only if Harbor was already there |
| **9** | [Harbor robot](#9-harbor-robot-recommended) | create it; it writes both values itself |
| **10** | [ArgoCD's kubeconfig](#10-the-supervisor-kubeconfig-argocd-needs) | fetch it; nothing to set |
| **11** | [Install](#11-validate-then-install) | `make install-all`, then `make verify` |
| **12** | [Ingress](#12-ingress-optional) | optional: reach the UIs at `*.vks.local` |
| **13** | [Access the UIs](#13-access-the-uis) | `make creds-show` |
| **14** | [Uninstall](#14-uninstall) | `make uninstall-all` |

**Everything YOU configure goes in ONE file: `.env`, at the root of the repo.** Each step has a
table of the keys it needs, with an example and where the value comes from. About **15** values are
genuinely yours to type; every other key in those tables has a default, or is written for you by the
command in that step.

Commands also DISCOVER values — LoadBalancer addresses, the guest kubeconfig, generated passwords —
and those land in **`.env.state`**, a separate file beside `.env`. You do not edit it, and it is
read last, so it wins over `.env`. If a value you expect is missing from `.env` after a step said it
published one, look there.

**Jump box:** Ubuntu or Photon OS, reaching both the internet and the lab. It must resolve the
vCenter FQDN. **Harbor's FQDN must be in real DNS** — the guest nodes resolve it, so `/etc/hosts`
is not enough. The `*.vks.local` names are `/etc/hosts`-only.
Internet-only? Use [the sneakernet flow](sneakernet.md) instead; it replaces Step 11.

---

## 0. Get the repo

<!-- walk-include: common-bootstrap.md -->

Follow [Common bootstrap](common-bootstrap.md) — install `git`/`make`/`curl`, clone, `cd` into the
repo, and `make env-init`. It is shared with Scenario 2 so there is exactly one copy to keep right.

**Collect these from your lab before Step 1** — write them down now; you enter them into `.env` in
Steps 1 and 2, where each one is listed with the exact `.env` key it goes in:

| What | `.env` key | Example | Where to find it |
|---|---|---|---|
| Supervisor IP | `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → *Control Plane Node IP*. **Bare host — no `https://`, no trailing slash.** |
| vCenter FQDN | `VCENTER_HOST` | `vcsa.env1.lab.test` | the address you log into vCenter with (Step 3 needs it for the CA). **Your jump box must resolve it** — check: `getent hosts vcsa.env1.lab.test` |
| your SSO user | `VKS_USERNAME` **and** `VCENTER_USERNAME` | `administrator@vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups. **Two keys, one value** — Steps 3 and 4/5 read different ones. |
| your SSO domain | `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups, the *Domain* dropdown. Needed only if `VKS_USERNAME` is bare (no `@`) or unset. |
| your SSO password | `VCF_CLI_VSPHERE_PASSWORD` **and** `VCENTER_PASSWORD` | — | for that login. **Two keys, one value**, and **both in single quotes** — see Step 1, where an unquoted password is silently mangled against an account that locks out after 3 attempts. |

### Download the Broadcom artifacts

All of these are **entitled** downloads — you need a Broadcom account with a vSphere
Foundation entitlement. Get them now: Steps 1-5 read them off disk and will not tell
you to fetch them. Versions move; match yours to what your entitlement offers.

⚠️ **Each link opens a page that looks EMPTY until you pick a release.** The *Release*
list on the page starts blank, and while it is blank the file table reads **"No data
found"** — which looks exactly like the artifact not existing. Pick your release first,
then the files appear. (If you are not signed in, the link takes you to Broadcom's
sign-in page before any of this.)

| file | from | put it in |
|---|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-9.1.0.0400.25509669.tar.gz` | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540529) | `VCF_CLI_SRC_DIR` (you set it in Step 1) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.0400.25509793.tar.gz` | [Plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540672) | `VCF_CLI_SRC_DIR` |
| the amd64 `argocd` CLI | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | `VCF_CLI_SRC_DIR` |
| `supervisor-service-argocd-legacy-1.1.0-25100889.yml` | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | `VCF_CLI_SRC_DIR` |
| `supervisor-service-harbor-legacy-v2.14.3+vmware.2-vks.1-25292931.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | `VCF_CLI_SRC_DIR` |
| `supervisor-service-harbor-data-values-v2.14.3.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | `VCF_CLI_SRC_DIR` |

All six go **directly in** `VCF_CLI_SRC_DIR` — not in a subdirectory. Every step that reads them
(Steps 1, 4 and 5) looks exactly one level deep and stops with *"no `…-*.yml` in `<dir>`"* otherwise.
The example throughout this runbook uses `~/Downloads/vcf` for all of them.

⚠️ **Take the `-legacy` service files.** The non-legacy ones install "successfully" and
then die at reconcile, because a Supervisor without a Software Depot cannot fetch what
they reference.

⚠️ **Take only the `Linux_AMD64` rows** (uppercase). The un-suffixed `-Binaries-`,
`-PluginBundle-` and `-OCI-` archives are multi-platform supersets the installer will
not use.

**Istio is not on this list.** Step 12 installs it *from your own Harbor*, or attaches to
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

**Set in `./.env`.** Only `VCF_CLI_SRC_DIR` is read *here* — without it `make install-vcf-clis`
fails. The rest are filled in now because Steps 2-6 read them, and each of those steps lists what
it uses.

| key | example | how to get the value |
|---|---|---|
| `VCF_CLI_SRC_DIR` | `~/Downloads/vcf` | the folder holding **all six** Step 0 downloads. |
| `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → Control Plane Node IP. **Bare host — no `https://`, no trailing slash.** |
| `VKS_CONTEXT_NAME` | `vks-cicd` | **you invent this** — a short label for the `vcf` login context |
| `VKS_NAMESPACE` | `cicd` | you name it here; **Step 2 creates it**. Pick a name nothing else owns — teardown deletes **by name**, and on a nested lab `lab` already belongs to the lab itself. |
| `VKS_CLUSTER_NAME` | `cicd-gc1` | **you invent this** — the guest cluster Step 6 creates. Must not be a name you deleted recently (see notes). |
| `VKS_USERNAME` | `administrator@vsphere.local` | your vCenter SSO login |
| `VKS_AUTH_METHOD` | `vcf` | **set it — do not leave it blank.** `vcf` logs in to the Supervisor; Step 6 switches it to `kubeconfig` for you. Left blank it silently becomes `kubeconfig`, and then `make env-check` goes **green** on a `.env` that is missing `SUPERVISOR_HOST` and `VKS_CONTEXT_NAME` too. |
| `VCF_CLI_VSPHERE_PASSWORD` | *your value* | the password for that login. **Single quotes — see below.** |
| `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups → *Domain* |

⚠️ **Passwords go in SINGLE quotes** — `VCF_CLI_VSPHERE_PASSWORD='your password'`, an embedded `'`
escaped as `'\''`. Bare, a `$` or space is silently mangled, so the value changes every run and each
retry burns one of **3 attempts before the account locks out permanently**. You see `HTTP 401` while
`.env` looks correct.

⚠️ **Put `VCF_CLI_SRC_DIR` in `./.env`, not on a command line.** Steps 4 and 5 silently fall back to
`~/Downloads/vcf`, so a one-shot value makes Step 4 search a directory you never used.

Now run:

```bash
make deps                     # toolchain: kubectl, helm, crane, tkn, jq, yq…
make install-vcf-clis         # reads VCF_CLI_SRC_DIR, which you set above
make check-tools              # what you have, what is missing
```

**Expect:** `check-tools` prints `all REQUIRED tools present.` *(~5 min, mostly downloads)*

### Put the toolchain on YOUR shell's PATH

Every `make …` below works already. The commands that are **not** `make` — `kubectl`, `vcf`,
`argocd` — run in *your* shell, which cannot see them yet.

```bash
make shell-init                      # future shells: appends to YOUR shell's rc file
. "$(make -s shell-rc-file)"         # THIS shell: re-reads that same file, whichever it is
```

**Two lines because they fix two different things.** The first one edits your shell's startup file,
which only affects shells you open *later*; the second re-reads it so the shell you are sitting in
picks it up now. Neither hardcodes `~/.bashrc` — `make shell-rc-file` prints the file for bash, zsh,
fish or ksh, which is the same resolver `shell-init` used to decide where to write.

**Expect:** `kubectl version --client` answers **in this shell** (and `vcf version`, after
`make install-vcf-clis`).

---

## 2. The vSphere Namespace

Your cluster goes in a vSphere Namespace. Use your own — not one shared with other workloads,
because teardown deletes **by name** and this repo's app names are generic.

> **Already have one?** Put its name in `VKS_NAMESPACE` and skip **only** `make vsphere-namespace`
> below. The key table and the vCenter trust anchor still apply to you: `VCENTER_HOST`,
> `VCENTER_USERNAME` and `VCENTER_PASSWORD` are hard-required — `make fetch-vcenter-ca` (below) and
> `make fetch-supervisor-ca` (Step 3) both die without `VCENTER_HOST`, and Steps 4 and 5 die without
> the other two. The anchor `make fetch-vcenter-ca` writes is also required by this step and by
> Steps 4 and 5. (`VKS_STORAGE_POLICY` and `VKS_VM_CLASSES` in the table below are read *only* by
> `make vsphere-namespace`, so those two you can leave alone.)

Step 3 activates a login context at this namespace and fails if it does not exist yet, so create it
now.

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VCENTER_HOST` | `vcsa.env1.lab.test` | your vCenter FQDN from Step 0 — **not** the Supervisor IP |
| `VCENTER_USERNAME` | `administrator@vsphere.local` | the same SSO login as Step 1 |
| `VCENTER_PASSWORD` | *your value* | the same password as Step 1 — **and in single quotes, for the same reason.** |
| `VKS_STORAGE_POLICY` | `wcp-vmfs` | vCenter → **Policies and Profiles → VM Storage Policies**. Already have a namespace? `make vsphere-namespace` prints the one it uses — no kubeconfig needed. |
| `VKS_VM_CLASSES` | `best-effort-small best-effort-medium` | space-separated; `best-effort-small` alone is enough. Defaults to the example, and the names are **sent to vCenter unchecked** — a class that does not exist fails with an HTTP code that does not mention VM classes. |
| `VKS_CLUSTER_COMPUTE` | *(leave unset)* | **only if** vCenter has **more than one** cluster. Steps 4 and 5 need it too, not just this one. |

⚠️ **`VKS_STORAGE_POLICY` is the policy NAME, not the storage class** — and you cannot convert one
to the other. Guess wrong and the create stops and lists every policy you actually have, which is
the fastest way to find the right one.

⚠️ **It will not modify a namespace that already exists** — it prints what is attached and changes
nothing. So if a storage policy or VM class turns out to be missing, fix it in vCenter (or delete
and recreate the namespace); re-running with a corrected `.env` is a no-op.

### First, give vCenter a trust anchor — this step, and Steps 4 and 5, refuse without one

Everything from here that talks to vCenter sends your **SSO administrator password**, so it will not
open that connection to a peer whose identity it has not verified. A lab vCenter serves a self-signed
certificate, so out of the box there is nothing to verify against and the command stops. One command
fixes it, and it needs no credentials:

```bash
make fetch-vcenter-ca
```

It downloads vCenter's own root bundle from `https://<VCENTER_HOST>/certs/download.zip` (the
*"Download trusted root CA certificates"* link on the vCenter landing page), picks the root that
actually **verifies** your vCenter — by performing a handshake, not by comparing subject names — and
writes it to `./secrets/vcenter-ca.pem`, where every later step finds it on its own.

**Expect:** `verified vCenter by handshake:` followed by **1** — then the file it wrote, its expiry,
and a **SHA-256 fingerprint**. A `0` there means none of vCenter's own roots verifies the name in
`VCENTER_HOST`, and the command tells you which of the two causes it is.

⚠️ **Confirm that fingerprint with your platform team over a channel that is not this connection.**
The anchor was pulled off the very wire it is meant to authenticate, so until you check the digest
against a second source, what you have is trust-on-first-use. The fingerprint authenticates it; the
transport it arrived over does not.

⚠️ **Do not reuse `./secrets/supervisor-ca.crt` for this.** It is a different CA — measured on a live
lab, it fails to verify vCenter (`rc=60`) while the root above succeeds. Nor should you reuse a
`vmca-root.pem` left over from an earlier lab: **every cut mints a new VMCA with a byte-identical
subject**, so a stale file looks correct and verifies nothing. `make fetch-vcenter-ca` is safe to
re-run after any re-cut and is the reliable way to get a current one.

If you have a reason to proceed without verifying — a throwaway lab you are about to destroy — you
can opt out for a single run, deliberately, per command:

```bash
VCENTER_INSECURE=1 make vsphere-namespace
```

Never do that on a lab you did not build yourself: it sends the SSO administrator password to a peer
whose identity has not been checked. Putting `VCENTER_INSECURE=1` in `.env` is worse still, because it
silently applies to every future run on that box.

```bash
make vsphere-namespace
```

**Expect:** on a fresh Supervisor, `created vSphere Namespace` then `is RUNNING`. If you already have one, `already exists` and it is **not rewritten** — that is the Step 1b branch, and it is fine.

Do not add a content library; guest-cluster node images do not come from one.

No permission to create namespaces? Ask your vSphere admin for one, with a storage policy and a
VM class attached.

---

## 3. Log in to the Supervisor

Everything from here reads `./secrets/supervisor.kubeconfig`: Harbor's generated password, the
LoadBalancer IPs, the ArgoCD instance. Do it now and those steps run in one pass.

**The commands below read these — all already in `./.env`:**

| key | example | set where |
|---|---|---|
| `SUPERVISOR_HOST` | `192.168.101.128` | Step 1 |
| `VCENTER_HOST` | `vcsa.env1.lab.test` | Step 1 |
| `VKS_CONTEXT_NAME` | `vks-cicd` | Step 1 (you invented it) |
| `VKS_USERNAME` | `administrator@vsphere.local` | Step 1 |
| `VKS_NAMESPACE` | `cicd` | Step 1, created in Step 2 |
| `VKS_AUTH_METHOD` | `vcf` | Step 1 — must be `vcf` here; Step 6 changes it |
| `VCF_CLI_VSPHERE_PASSWORD` | *your SSO password* | Step 1 |

```bash
make fetch-supervisor-ca
```

⚠️ **Confirm the printed SHA-256 with your platform team over another channel.** The download is
deliberately unverified TLS; the fingerprint is what authenticates it. A rebuilt lab mints a new CA
at the same address, so a stale file looks valid and is not.

```bash
set -a; . ./.env; set +a
make vks-login
```

**Expect:** `Supervisor context verified via` — and `./secrets/supervisor.kubeconfig` now exists.

⚠️ **Do not** use `vcf config set env.VCF_CLI_VSPHERE_PASSWORD` — it writes your SSO password in
plaintext to `~/.config/vcf/config.yaml`, outside this repo and every secret scan. `.env` is where
it belongs.

<details><summary>Driving the <code>vcf</code> CLI directly instead</summary>

`make vks-login` creates the context and activates it for you. If you would rather run the CLI:

```bash
vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
    --ca-certificate ./secrets/supervisor-ca.crt \
    --username "$VKS_USERNAME" --type kubernetes --auth-type basic
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"
```

`--username` is not optional — without it `vcf` asks `? Provide Username:` and dies `[x] : EOF` in
anything non-interactive. And `vcf context use` can print a `system Harbor registry` error **and
still have worked**: judge it by the next command, not its exit code. `make vks-login` already does.

</details>

Now confirm the namespace can actually hold a cluster. **Both must print something:**

```bash
export KUBECONFIG=./secrets/supervisor.kubeconfig
kubectl -n "$VKS_NAMESPACE" get storagepolicyquotas
kubectl -n "$VKS_NAMESPACE" get virtualmachineclass
```

**Expect:** both list something. An empty `storagepolicyquotas` means no storage policy attached;
an empty `virtualmachineclass` means no VM class. Fix either in vCenter before continuing — a
namespace missing one still *accepts* a cluster and then never finishes provisioning it.

---

## 4. Harbor

The registry every image comes from.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)

> **Already have Harbor?** Many labs ship it — check vCenter -> Workload Management -> **Supervisor
> Services**, or `kubectl get ns | grep harbor`. If it is there, skip the install command and open
> *Harbor already exists* at the end of this step.

**Set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `HARBOR_URL` | `harbor.env1.lab.test` | **you choose it** — but it must be a name your **real DNS** can answer, because the guest nodes resolve it. Bare host: no `https://`, no trailing slash. |
| `HARBOR_STORAGE_CLASS` | `wcp-vmfs` (VMFS)<br>`vsan-default-storage-policy` (vSAN) | **No default — you must set it, and it is the only key in this runbook you cannot read before Step 3.** Run `kubectl get storageclass` now that you have a kubeconfig. Unset, `make install-harbor-service` stops at once. |

**Run:**

```bash
make install-harbor-service
```

**Expect:** `7 secrets generated, 0 placeholders left`, then `install issued for harbor.tanzu.vmware.com`.
The admin password is **generated** — you do not choose it and it is not Harbor12345. Read it back
any time with `make creds-show`.

⚠️ If your vCenter has **more than one cluster**, set `VKS_CLUSTER_COMPUTE` as well, or this command
stops with *could not resolve the vSphere cluster moid*.

Harbor already installed on this Supervisor? Skip that one command — but still run the next block.
Its LoadBalancer address is what your DNS records point at, whoever installed it.

```bash
make show-dns-records DNS_RECORDS_WAIT_SECONDS=900   # waits for the LoadBalancer address, then prints the records
```

**Expect:** a HOSTNAME / IP / SOURCE table with at least one row, then `Create these as A records`.
If the LoadBalancer has no address yet this waits for it — up to 15 minutes with the value above.

**Now create the A records `make show-dns-records` just printed.** `/etc/hosts` is **not** enough —
the guest nodes must resolve the name too. **Reinstalling?** The LoadBalancer IP is new, so update
the record you already have.

Then confirm it — run this as soon as the record is in; it waits:

```bash
make harbor-reachable
```

**Expect:** `Harbor answers at` followed by your host. It prints `still waiting` every minute until
Harbor comes up — **measured at 7m25s** from `install issued` to first answer, and it waits up to
15 minutes. A non-zero exit means it never answered — **do not go on to Step 5**.

`NOTHING is serving there` means the record does not point at the address `make show-dns-records`
prints — the usual cause on a reinstall, where the old address is still in DNS.

### If Harbor already exists

You still need its admin credential — `make install-all` authenticates with it. **Step 8.5 gets it
for you**, right after the CA that lets it verify Harbor. Nothing to do here.

⚠️ Do not skip Step 8.5. If you leave `HARBOR_PASSWORD` unset, `make env-populate` in Step 11
**generates** one, and it cannot possibly authenticate against a Harbor that already exists.

<details><summary>Optional — Harbor project names, both already work</summary>

**→ set in `./.env`:** both keys ship UNCOMMENTED with a working default — edit the value in place.

| key | default | how to get the value |
|---|---|---|
| `HARBOR_INFRA_PROJECT` | `cicd` | **you choose** — the project for pipeline images |
| `HARBOR_APP_PROJECT` | `apps` | **you choose** — the project for app images. |

</details>

---

## 5. ArgoCD

The GitOps engine, running on the Supervisor.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html)

> **Already have ArgoCD?** `kubectl get argocd -A`. If it is there, skip the install command and go
> straight to *Get its address and log in*.

**Set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `ARGOCD_NAMESPACE` | `cicd` | the vSphere Namespace the ArgoCD **instance** goes in. **Do not skip it — see below.** |
| `VKS_AUTH_METHOD` | `vcf` | leave it `vcf` here; the guest-cluster step changes it to `kubeconfig`. |

⚠️ **Set `ARGOCD_NAMESPACE` explicitly.** Left blank it silently becomes `VKS_NAMESPACE` — no
error — and you find out three steps later, when `kubectl get deploy argocd-server` finds nothing.

**Run:**

```bash
make install-argocd-service
```

**Expect:** `install issued for argocd-service.vsphere.vmware.com`, then `ArgoCD instance argocd-1
requested in namespace <ns>`.

**Then get its address and log in:**

```bash
make argocd-address                 # waits for the address, writes ARGOCD_SERVER to ./.env
set -a; . ./.env; set +a            # so THIS shell has it
make argocd-password                # prints the initial admin password
argocd login "$ARGOCD_SERVER" --username admin --insecure
argocd account update-password
```

**Expect:** `wrote ARGOCD_SERVER=` and an address. *(~10 min — it waits, printing `still ...` each
minute.)*

`argocd login` **prompts** for the password, so paste what `make argocd-password` printed. Nothing
automates that step — it is the one command in this runbook no harness can run, because it reads the
password from a TTY and `argocd login` has no `--password-stdin` (its only non-interactive form puts
the secret in `argv`, which this repo forbids).

But the CREDENTIAL itself is now testable, which is the part that used to be unverified anywhere:

```bash
make argocd-auth-check   # read-only: does the admin credential authenticate, and did TLS verify?
```

**Expect:** `argocd-auth-check: OK`, with `a session token was ISSUED`. It also tells you which of the
two knobs is at fault when it fails — the **address** (an IP cannot verify: argocd-server's default
certificate carries DNS SANs only, no IP SAN) or the **anchor** (`ARGOCD_CA_FILE`). If you have not
run `make fetch-argocd-ca`, it passes on the credential and says plainly that it proved *nothing*
about trust — read that line rather than the word PASS.

⚠️ **Once you change it, keep it yourself.** `make argocd-password` and `make creds-show` read the
*generated* secret; the password you just chose is not written anywhere. After `argocd account
update-password` they can only show the initial one, or say they cannot read it — that is them
working, not failing. Put your new password in your password manager now.

A non-zero exit from `make argocd-address` says which of the two things is missing — the ArgoCD
**instance** (it never reconciled) or its **LoadBalancer address** — and they need different fixes.

<details><summary>Optional — both already work</summary>

**→ set in `./.env`:** uncomment the key and give it your value. Leave it commented to take the default.

| key | default | how to get the value |
|---|---|---|
| `ARGOCD_SERVER` | *(unset — probes skip)* | the `argocd-server` EXTERNAL-IP. Display and probes only. |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | what `make fetch-supervisor-ca` wrote. Set it only if you moved it. |

</details>

---

## 6. Guest cluster

Where Gitea, Tekton and your apps run. You need cluster-admin on it.

> **Already have a cluster?** Put its name in `VKS_CLUSTER_NAME` and skip `make vks-cluster-create`
> below. Everything after it still runs.

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VKS_CLUSTER_NAME` | `cicd-gc1` | you invented it when you filled in `.env`. **Never reuse a name you deleted recently** — it never converges. |
| `VKS_CONTEXT_NAME` | `vks-cicd` | the context name you chose — read by the `vcf` fallback below |
| `VKS_NAMESPACE` | `cicd` | your vSphere Namespace — read by the `vcf` fallback below |
| `VKS_K8S_VERSION` |  | **leave it empty** — `make vks-k8s-version` writes it for you, below. |
<!-- MAINTAINERS: the value cell MUST stay empty. The walk harness writes any literal it finds
     there into ./.env, which PINS this key -- and a pin makes the tool log "already pinned ...
     NOT overwriting it" and keep a version whose OSImage may not exist, so admission denies the
     cluster. -->

```bash
make vks-k8s-version           # resolve the TKr NOW — see the note below; do not skip this
make vks-cluster-create        # applies the Cluster; provisioning is async
```

**Expect:** a line naming `VKS_K8S_VERSION:` with a full release string such as
`v1.36.2+vmware.2-vkr.3`. You do **not** copy that value anywhere — `make vks-k8s-version` writes it
into `./.env` itself, and `make vks-cluster-create` on the next line reads it from there. If it says
`NOT overwriting it`, you pinned `VKS_K8S_VERSION` yourself earlier and it is respecting that; clear
the pin if you wanted the newest.

It picks the newest release that is Ready, Compatible, and has an OSImage for your node OS — and
writes the **full** name, because a bare `v1.34` is a prefix that floats.

⚠️ **Which MINOR you get is decided by the VKS service version, not by this command.** The service
version carries the ceiling in its own name — `3.6.3-embedded+v1.35` tops out at Kubernetes 1.35,
`3.7.1+v1.36` at 1.36 — and a release above that ceiling is published but reads `Compatible=False`,
so this command will not select it. Measured 2026-08-26: both 1.36 releases were `Ready=False
Compatible=False` on a `+v1.35` service and flipped to `True`/`True` the moment it reached `+v1.36`.
So if you expected a newer minor than you got, the thing to check is the service version, not the
release list — see [`vks-services/vks.md`](vks-services/vks.md).

Run the two together, in that order — on a freshly-built Supervisor the answer goes stale in
minutes. If the create is rejected with `Could not resolve KR/OSImage`, just run both lines again:
the release is real, its node image has not landed yet. That costs about a second, because the
create validates server-side before it applies anything.
[Why](scenario-1-notes.md#step-4--the-guest-cluster).

Already have a cluster? Skip **only** that command — the two below still have to run, and the second
is what writes the kubeconfig every later step needs.

```bash
make vks-cluster-status                                # reports ONCE — read `endpoint :` now
make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800  # then wait for every node Ready
```

**Read the `endpoint :` line from the first command before starting the wait.** `AGREE` or
`NOT YET KNOWABLE` → carry on. `*** DIVERGENT ***` → stop and follow what it prints; the waiting
form refuses immediately rather than spending 30 minutes to reach the same answer.

**Expect:** the waiting command reprints a table every 15 s, then prints `conditions hold AND every expected node is Ready` and exits `0` with every node
`Ready`. *(**4–9 min** — the Timings table's own runs span 3 m 45 s to 8 m 49 s; the command waits up to 30 min, so give it that before calling it stuck.)* A non-zero exit is not a pass — do not continue to the preflight.

### Get its kubeconfig

**If that command exited `0`, it already wrote one** — at `./secrets/<VKS_CLUSTER_NAME>.kubeconfig`,
read straight from the cluster's own Secret.

⚠️ The file existing is not proof the cluster is ready — the Secret is minted before the nodes
join, and no later check tests for workers. Only the `0` exit above means both. Use it:

```bash
set -a; . ./.env; set +a
kubectl --kubeconfig "./secrets/${VKS_CLUSTER_NAME}.kubeconfig" get nodes -o wide
```

**Expect:** your nodes listed, all `Ready`. *(Read this one yourself — the walk cannot check it. Ready is 5 characters and the checker drops literals shorter than 6, and no longer token in this output carries the readiness meaning: INTERNAL-IP, for instance, is printed whenever the node list is non-empty, so it would pass on a cluster where every node is NotReady.)*

Point everything after this at the guest cluster:

```bash
make use-guest-kubeconfig
set -a; . ./.env; set +a
```

**Expect:** `wrote to` — then `KUBECONFIG`, `VKS_CONTEXT` and `VKS_AUTH_METHOD=kubeconfig`.

⚠️ **`make vks-login` renews the GUEST kubeconfig.** The Supervisor one expires too, and Steps
10 and 14 need it — `kubectl` then says *"the server has asked for the client to provide
credentials"*. Renew it with:

```bash
set -a; . ./.env; set +a
VKS_AUTH_METHOD=vcf make vks-login
```

**Expect:** `Supervisor context verified via` — followed by the ABSOLUTE path to
`secrets/supervisor.kubeconfig`, not the `./` form you typed.

<details><summary>Optional — the cluster's shape. Skip unless you want to change it.</summary>

**You do not have to fill these in.** The values that depend on your estate — the storage policy
attached to your vSphere Namespace, and the ClusterClass — are discovered and written for you:
`make vks-cluster-create` runs `make vks-shape-set` first. Nothing to copy, nothing to look up.

To see what your Supervisor offers before then:

```bash
make vks-shape-show
```

`vks-shape-set` never overwrites a value you set yourself, and writes **nothing** when the answer is
ambiguous — it prints the choices instead, because a wrong value pinned in `.env` overrides the
default that would otherwise have worked.

The rest are yours to choose. **→ set in `./.env`:** uncomment the key and give it your value.

| key | default | what it is |
|---|---|---|
| `VKS_VM_CLASS` | `best-effort-small` | node size. `kubectl get virtualmachineclass` lists yours |
| `VKS_CONTROL_PLANE_COUNT` | `1` | how many control-plane nodes |
| `VKS_NODE_COUNT` | `2` | how many workers. One is too small for the platform. |

</details>

---

## 7. Preflight

Catches what would otherwise kill the run *after* a 20-minute mirror.

```bash
make vks-login                # now checks the GUEST kubeconfig (Step 6 set VKS_AUTH_METHOD=kubeconfig)
make lab-preflight
make psa-check
```

**Expect:** `LAB PREFLIGHT OK`. `PSA UNPROVEN` on a bare cluster is expected, not a failure. *(~1 min)*

---

## 8. Harbor's CA

Harbor's certificate is issued by a private CA (`CN = Harbor CA`), not by a public one, so nothing
trusts it yet. Save that CA so the jump box and the cluster do. Harbor publishes it on an
unauthenticated endpoint, so no login is needed.

**The commands below read this — already in `./.env`:**

| key | example | set where |
|---|---|---|
| `HARBOR_URL` | `harbor.env1.lab.test` | Step 4 |

```bash
set -a; . ./.env; set +a
tmp=$(mktemp -d)
code=$(curl -sk --max-time 20 -o "$tmp/ca.crt" -w '%{http_code}' \
  "https://${HARBOR_URL}/api/v2.0/systeminfo/getcert" || true)
if [ "${code:-000}" = 000 ]; then
  echo "nothing answered at ${HARBOR_URL} — check the A record (make show-dns-records)"
elif [ "$code" != 200 ]; then
  echo "Harbor answered (HTTP ${code}) but does not publish its CA there — use an alternative below"
else
  # HARBOR_URL is a BARE host (Step 4 says so), and `s_client -connect` needs host:PORT —
  # given a bare host it silently tries port 4433 and stalls until the kernel gives up (~2 min).
  hostport="$HARBOR_URL"; case "$hostport" in *:*) ;; *) hostport="${hostport}:443" ;; esac
  timeout 15 openssl s_client -connect "$hostport" -servername "${HARBOR_URL%%:*}" </dev/null 2>/dev/null \
    | openssl x509 > "$tmp/harbor.crt" 2>/dev/null
  if [ ! -s "$tmp/harbor.crt" ]; then
    echo "could not read ${hostport}'s certificate (no answer, or it timed out) — nothing was saved."
    echo "Harbor answered a moment ago, so this is NOT DNS and Harbor is NOT down."
    echo "Most likely a TLS-intercepting proxy (curl uses https_proxy, openssl does not):"
    echo "    env | grep -i _proxy"
    echo "or a stray '/' or space in HARBOR_URL."
  elif openssl verify -CAfile "$tmp/ca.crt" "$tmp/harbor.crt"; then
    install -m0644 "$tmp/ca.crt" ./secrets/harbor-ca.crt
  else
    echo "that file does not vouch for ${HARBOR_URL} — nothing was saved; use an alternative below"
  fi
fi
rm -rf "$tmp"
```

**Expect:** one line ending `harbor.crt: OK` — that is `openssl` confirming the downloaded file
really does vouch for this Harbor, and the CA is now saved. Any other message means **nothing was
saved**, and each one names which problem it hit. *(<1 min)*

If it prints *"nothing answered at"*, fix the A record before continuing. If it prints *"could not
read"*, Harbor answered but its certificate did not arrive — the message lists what to check. If it
prints *"that file does not vouch for"*, use one of the alternatives below.

Two details in there are load-bearing:

- It downloads to a scratch file, **not** straight to `./secrets/harbor-ca.crt`. If Harbor answers
  with an empty body, `curl` still succeeds, and writing directly would leave you a **zero-byte**
  file having **destroyed a good one you already had**.
- It then asks Harbor for its own certificate and requires the downloaded file to **vouch for it**.
  Checking only the name on the file is not enough: Harbor keeps its own separate certificate
  authority internally, and on some setups that is what this address hands out — same name, wrong
  file. It looks right, and then image pulls fail with `certificate signed by unknown authority`
  long after this step.

Then **check it against a digest you got from whoever runs Harbor**, over some other channel —
`-k` above means you fetched it over a connection you could not yet verify:

```bash
sha256sum ./secrets/harbor-ca.crt
```

**Expect:** one line — a 64-hex digest followed by `./secrets/harbor-ca.crt`. Compare that digest
with the one your platform team gave you; they must match. *(<1 min)*

The digest proves it is the file Harbor's operator meant you to have. One more check proves it is the
right file for **this** Harbor — a certificate left over from an earlier lab is still a perfectly
valid certificate, and a rebuilt lab issues a new one at the *same address*, so the old file keeps
looking fine until it fails:

```bash
make ca-status
```

**Expect:** `CA-STATUS: ALL-MATCH` — nothing else prints that. *(<1 min)*

Every other outcome names the file, the address and what to do, and exits non-zero. From here on
`make lab-preflight` repeats this check for you — but only once the cluster answers: the CA report
sits after that command's `kubectl` reachability gate, so on a lab that is **down** you get the
kubectl failure and not the CA verdict. `make ca-status` is the one that needs no cluster, which is
why the failure messages point at it. Run it directly whenever a lab has been rebuilt under you.

<details><summary>Alternatives if that endpoint is unavailable</summary>

- Harbor's UI: your project → **Registry Certificate** → download `ca.crt`.
- From the cluster, if you have Supervisor access:

  ```bash
  make harbor-ca-from-cluster
  ```

Note `make fetch-harbor-ca` takes the CA from the connection Harbor answers on, so it works only when
the **last** certificate Harbor sends is the one that **directly issued** Harbor's own — a
self-signed certificate, or a single private CA. If your site puts another certificate in between
(the usual corporate setup) it stops and tells you so: the certificate it took cannot verify Harbor's
leaf on its own. Get the CA from Harbor's UI or from your platform team instead.

</details>

---

## 8.5 Harbor's admin credential

Skip this if **you** installed Harbor in Step 4 — that already published its password. This is for a
Harbor that was already there.

```bash
make harbor-admin-password
```

**Expect:** `already authenticates` if the credential already in your .env works, otherwise `wrote HARBOR_USERNAME and HARBOR_PASSWORD to ./.env`.
Step 4 told you to leave `HARBOR_PASSWORD` unset, so on a Harbor that was already there the second
is the normal case. You see the first if you installed Harbor yourself in Step 4, or were handed a
working credential — it is left alone either way.

It reads the password out of the Harbor service's own secret and **proves it against Harbor before
writing anything**. It never replaces a credential that already works, so it is safe to re-run — and
safe to run after Step 9's robot **while that robot still works** (Harbor answers `403` for a
project-scoped robot, which counts as working). ⚠️ If the robot has since been revoked, rotated or
expired, Harbor answers `401`, this command falls through and writes the **admin** credential to
`./.env` — and your pipeline then runs as admin. Re-run `make harbor-robot` instead.

It is **here, not in Step 4**, because verifying needs Harbor's CA — which is what you just fetched.

If it stops, it names which of these it hit:

- `does NOT authenticate` **as the last line** — Harbor's password was changed after it was
  installed (Harbor only accepts that secret at its first start). Nothing is written. Ask whoever
  installed Harbor, or use a robot from Step 9. ⚠️ The same phrase also appears as a **warning
  mid-run** (`the HARBOR_PASSWORD currently in your .env does NOT authenticate - reading the
  installed one`) — that one is not a failure by itself, it is the command doing its job, and it
  usually succeeds two lines later. It is also printed when nothing was sent to Harbor at all (no
  CA, say), so it can equally precede a `could NOT check` stop. Read the LAST line before acting.
- `could NOT check` — a different thing: nothing was sent to Harbor at all. It says which
  precondition is missing.
- `no Supervisor kubeconfig` — run `make vks-login` (Step 3) first. Harbor's secret lives on the
  Supervisor, not in your guest cluster.
- `refusing to guess` — it found zero, or more than one, Harbor Supervisor Service and will not
  pick for you. `kubectl get ns -l <harbor label>` shows what it saw.
- `carries no HARBOR_ADMIN_PASSWORD` — the secret exists but not the key: this Harbor was not
  installed by the Supervisor Service, so its admin password is not knowable this way.

---

## 9. Harbor robot (recommended)

CI pushes with a scoped credential instead of `admin`. Needs project-admin.

**Run:**

```bash
make harbor-robot            # writes ./secrets/harbor-robot.env (mode 0600)
ls -l ./secrets/harbor-robot.env
```

**Expect:** `robot account 'robot$vks-cicd' created.`, then a `-rw-------` listing of the file. *(<1 min)*

It writes `HARBOR_USERNAME` and `HARBOR_PASSWORD` into `./.env` itself — nothing to copy. From here
the pipeline runs as the **robot**, not as admin.

⚠️ A robot cannot mint robots, so re-running `make harbor-robot` now stops and says so. To mint
another, restore the admin credential first with `make harbor-admin-password`.

⚠️ **Already exists?** It stops rather than overwriting: Harbor shows a robot secret **once**, so an
existing one cannot be re-read and re-creating it would hand you a credential that does not work.
**Which remedy applies depends on whether `./secrets/harbor-robot.env` is on THIS box** — the command
says which. If the file is here, reuse it. If it is not, the robot was minted somewhere else and
there is nothing to read back: get the secret from whoever created it, refresh it in the Harbor UI
(**Administration -> Robot Accounts -> Refresh Secret**), or delete the robot (**Administration -> Robot
Accounts**) and run it again.

---

## 10. The Supervisor kubeconfig ArgoCD needs

`make gitops` talks to **both** clusters: ArgoCD on the Supervisor, your apps in the guest.

**Nothing to set here** — Step 3 published `ARGOCD_KUBECONFIG` when you logged in.

```bash
make fetch-argocd-kubeconfig
make argocd-preflight           # CLI vs running-server versions; can ArgoCD reach your cluster?
```

**Expect:** `PREFLIGHT OK`. If it says your guest cluster is not registered:

```bash
make argocd-register-guest      # admin-only; creates an SA in your guest + a Secret in ArgoCD's ns
```

**Expect:** the guest ends up `registered` with this ArgoCD — either `registered as` followed by the
name and API server it just used, or, if it was already registered, a line saying so and
`nothing to do`. Both are success; the second is what you see on a re-run or on a cluster someone
else already registered. Then re-run
`make argocd-preflight` — it should now report PREFLIGHT OK, which is the assertion attached to
that command's own block above. *(~2 min)*

`argocd-preflight` also prints the deploy destination — every cluster registered with this ArgoCD,
and which one your guest resolves to. If it says **`resolves UNAMBIGUOUSLY`**, there is nothing to
set. If it reports more than one candidate, name the destination in `./.env` — the install refuses to
guess, because guessing once deployed into a different cluster and reported `Synced/Healthy` the
whole time. Either variable does it, and they are alternatives, not a pair:

| set this | to | when |
|---|---|---|
| `ARGOCD_DEST_CLUSTER_NAME` | one of the names `argocd-preflight` just listed | you can see the registered clusters — usually here |
| `ARGOCD_DEST_SERVER` | your guest cluster's API URL | you cannot list them; this is the tenant path Scenario 2 uses |

`70-configure-argocd.sh` accepts **either** (its guard is satisfied by one or the other), and its own
refusal message offers both.

`make argocd-version` prints the CLI version, the **running server** version and this repo's pin.
The running server is the one that matters.

---

## 11. Validate, then install

```bash
make env-populate     # generates Gitea's admin password; discovers anything you left blank
make env-check        # every required value set? (fast, no network)
make env-validate     # does KUBECONFIG reach the cluster? does Harbor authenticate?
```

**Expect:** `env-validate` reports Harbor reachable **and authenticated**.

**Do not go on until it does.** `install-all` cannot succeed on a credential `env-validate` has
rejected, and it takes 8–10 minutes to say so. Fix it here — the Harbor step tells you where the password
comes from.

```bash
make install-all      # preflight -> mirror -> mirror-verify -> builder-image -> vks-login -> platform -> gitops
make verify           # pushes a marked change and follows it to the running app
```

**Expect:** `install-all` completes; `make verify` exits **0** for every app.
*(**install-all 8–11 min** — the Timings table records 10 m 26 s — **verify 3–4 min**)*

`install-all` begins with `lab-preflight`, which stops in the first seconds on anything the lab is
missing. Most often: **no default StorageClass**. Fix it and re-run `install-all`:

```bash
kubectl get storageclass
```

**Expect:** a table headed `PROVISIONER`, with at least one class. If it is empty the pipeline
has nowhere to put Gitea's PVC and Step 11 will fail late instead of here.

Then mark one of them default — `<name>` is YOUR choice from the table above, which is why this
line is not runnable as written:

```bash
kubectl annotate sc <name> storageclass.kubernetes.io/is-default-class=true
```

---

## 12. Ingress (optional)

Reach the UIs at `*.vks.local` instead of port-forwarding.

```bash
make istio-preflight
```

**`istio-preflight` is read-only and it ends by naming the exact command to run next — run the one
it prints.** It has more outcomes than the two obvious ones, so do not guess from the cluster:

- `PREFLIGHT OK — 'make install-ingress INGRESS_CONTROLLER=istio-existing' …` — a mesh is already
  here. **Attach; do not install.** This is the normal case on a real lab, where Istio is a Standard
  Package the platform team owns.
- `NO Istio detected on this cluster.` — install it from your Harbor with `make install-ingress`.
- **Non-zero exit** — it names three values (`ISTIO_GATEWAY_NAMESPACE`, `_SERVICE`, `_LABEL`) to
  request from the mesh admin. That is the answer, not a failure: with them set, the attach command
  needs no read access at all.

**How long it takes varies more than anything else in this runbook, so do not use the clock to judge
it.** Attaching installs nothing — one read-only `helm status` — usually seconds. Installing runs three helm charts and two
readiness waits, each with its own deadline: a re-run against a warm cluster is ~10 seconds, a cold
install on a fresh one is minutes, and the ceiling is ~25. To lengthen a deadline set
`READY_TIMEOUT_SECONDS` — either on the `make` command line
(`make install-ingress READY_TIMEOUT_SECONDS=900`) or in `.env`.

⚠️ **Never run the bare `make install-ingress` against a mesh you did not install.** It helm-installs
a second istiod over the platform's, and before it gets far enough to fail it relabels the
`istio-system` namespace's Pod Security level — which breaks the platform's own pods on their next
restart, across tenants, with nothing naming you as the cause.

```bash
make install-ingress INGRESS_CONTROLLER=istio-existing   # a mesh is already here — attach only
```

**Expect:** `attaching to an Istio we did NOT install` — the attach path installs nothing, which
is the whole point of it.

```bash
make install-ingress                                     # NO Istio detected — install it
```

Then **check the routes actually work**, before you rely on those hostnames:

```bash
make verify-ingress           # each *.vks.local host must reach ITS OWN backend
```

**Expect:** one OK per host — gitea, tekton and each app — ending in `UI(s) reachable through the`.
It sends `Host: <name>.vks.local`
to the ingress LoadBalancer IP directly, so **it needs no DNS and no `/etc/hosts` entry** — and it
asserts a per-host body marker, not just a 200, because a mis-wired route returns 200 from the
*wrong* backend. A host that fails here will not work in a browser either, and this names which one and why. *(~1 min)*

---

## 13. Access the UIs

```bash
make creds-show
```

**Expect:** every URL and login — `Harbor`, `ArgoCD`, Gitea, `Tekton`, one row per app — above a `Lab access` section, and a provenance line reading `values below :` followed by `DISCOVERED` (an overlay stamped for the cluster you are talking to), `STORED` (an overlay NOT confirmed to belong to it), or a line naming `your .env`.
**Expect:** a `Lab access` section listing `vCenter`, `VKS / SSO` and `vcf CLI` — the values YOU supplied in `.env` — and a `guest node SSH` row whose password is read LIVE from the Supervisor, with the username `vmware-system-user`.
**Expect:** the `guest node SSH` row shows the secret name it read (a `-ssh-password` secret) when it succeeds, or a short token such as `<forbidden>` / `<no kubeconfig>` when it could not ask — never a blank that would read as *this cluster has none*.
**Expect:** a warning that vCenter SSO locks the account `PERMANENTLY after 3 failed attempts`, and that this report SHOWS these values and never authenticates with them.

The ArgoCD row is the exception if you changed that password in Step 5: it can only show the
generated one, or say it cannot read it. Yours is in your password manager.

Skipped the ingress step? The `*.vks.local` URLs will not resolve — reach a service directly instead:

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000                   # http://localhost:3000
kubectl -n tekton-pipelines port-forward svc/tekton-dashboard 9097:9097  # http://localhost:9097

# One per app, each on its own local port. Every app's Service is svc/<name> on port 80,
# in a namespace of the same name. Ask the registry which apps exist -- do NOT paste a
# list from a document, which goes stale the day an app is added:
awk -F'\t' '!/^#/ && NF>1 {print $1}' apps/registry.tsv
kubectl -n <app> port-forward svc/<app> 18080:80                        # http://localhost:18080
```

**Expect:** the UI answers on `localhost` at the port you forwarded.

---

## 14. Uninstall

Removes what this runbook installed. It does not touch the vSphere lab.

```bash
make uninstall-all CONFIRM=<your VKS_CLUSTER_NAME>
```

**Expect:** it deletes only objects carrying our ownership label, and **prints what it left alone**. *(Read this one yourself — the walk SKIPS this block on every row, by design: walk-doc.sh:122 refuses the uninstall command as "teardown - would destroy the lab mid-walk", and a skipped block never reaches the Expect check, so no literal here could ever be checked.)*
*(~1 min)*

**It will not** delete the Harbor projects/robot, `secrets/`, or `/etc/hosts` — it prints those
commands for you to run. A failed read is reported `CANNOT READ` and counted as not done.

---

## Timings

Two runs on a 9.1 lab (i9-14900KF / 188 GiB) hosting the nested lab on the same box, so these are
under self-contention. Where the runs disagree, both are shown.
[Conditions](scenario-1-notes.md#timings--what-these-numbers-do-not-cover).

⚠️ **These timings were taken when the repo shipped TWO apps.** It ships six now, and `mirror`,
`builder-image`, the pipeline and `make verify` all scale with that — so read these as a floor, not
a forecast.

| Step | Command | Run 1 | Run 2 |
|---|---|---|---|
| 6 | `make vks-cluster-create` | <1 s | <1 s |
| 6 | cluster → all nodes `Ready` | **3 m 45 s** | **≈ 6 m** |
| 7 | `make lab-preflight` | 2 s | 2 s |
| 8 | `make harbor-ca-from-cluster` | <1 s | <1 s |
| 11 | `make env-check`, `make env-validate` | <1 s each | <1 s each |
| 11 | `make install-all` | **10 m 26 s** | **8 m 14 s** |
| ↳ | `mirror-pull` / `mirror-push` / `mirror-verify` | 22 s / 2 m 38 s / 5 m 46 s | — |
| ↳ | `builder-image` + `platform` + `gitops` | ≈1 m 40 s | — |
| 11 | `make verify` | **3 m 6 s** | **3 m 27 s** |
| 14 | `make uninstall-all` | 1 m 12 s | 1 m 12 s |

From a **bare Photon jump box** (fresh box, nothing cached — so the mirror pulls every image), the
same lab, measured start to `End-to-end verified`:

| | |
|---|---|
| Step 0–1 install `git`/`make`, clone, `make deps`, install the CLIs | ≈ 2 m 30 s |
| Step 6 cluster created → every node `Ready` | **8 m 49 s** |
| Step 11 `make install-all` + `make verify` | **10 m 08 s** |
| **whole run, clone → verified** | **21 m 31 s** |
