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
| **1** | [Jump box](#1-jump-box) | install the toolchain; set 8 values |
| **2** | [vSphere Namespace](#2-the-vsphere-namespace) | `make vsphere-namespace`; set 6 values |
| **3** | [Log in to the Supervisor](#3-log-in-to-the-supervisor) | `vcf context create`, `make vks-login` |
| **4** | [Harbor](#4-harbor) | `make install-harbor-service`; set 2 values, then DNS |
| **5** | [ArgoCD](#5-argocd) | `make install-argocd-service`, log in; set 2 values |
| **6** | [Guest cluster](#6-guest-cluster) | create it; set 1 value, then 3 more once it is up |
| **7** | [Preflight](#7-preflight) | check the cluster will accept the install |
| **8** | [Harbor's CA](#8-harbors-ca) | fetch it |
| **9** | [Harbor robot](#9-harbor-robot-recommended) | create it; replace 2 values |
| **10** | [ArgoCD's kubeconfig](#10-the-supervisor-kubeconfig-argocd-needs) | fetch it; set 2 values |
| **11** | [Install](#11-validate-then-install) | `make install-all`, then `make verify` |
| **12** | [Ingress](#12-ingress-optional) | optional: reach the UIs at `*.vks.local` |
| **13** | [Access the UIs](#13-access-the-uis) | `make creds-show` |
| **14** | [Uninstall](#14-uninstall) | `make uninstall-all` |

**Everything you configure goes in ONE file: `.env`, at the root of the repo.** Each step has a
table of the keys it needs, with an example and where the value comes from.

**Jump box:** Ubuntu or Photon OS, reaching both the internet and the lab. It must resolve the
vCenter FQDN. **Harbor's FQDN must be in real DNS** — the guest nodes resolve it, so `/etc/hosts`
is not enough. The `*.vks.local` names are `/etc/hosts`-only.
Internet-only? Use [the sneakernet flow](sneakernet.md) instead; it replaces Step 11.

---

## 0. Get the repo

Everything below runs **from the repo root**. Nothing works from another directory.

A stock Ubuntu or Photon box has neither `git` nor `make`. Ubuntu has no `curl` either, and
`make deps` needs it. Install them first.

```bash
# Ubuntu / Debian
apt-get update && apt-get install -y --no-install-recommends git make curl ca-certificates
# Photon OS 5
tdnf install -y git make curl curl-libs ca-certificates
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
Foundation entitlement. Get them now: Steps 1-5 read them off disk and will not tell
you to fetch them. Versions move; match yours to what your entitlement offers.

| file | from | put it in |
|---|---|---|
| `VCF-Consumption-CLI-Linux_AMD64-9.1.0.0400.25509669.tar.gz` | [VCF CLI](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540529) | `VCF_CLI_SRC_DIR` (you set it in Step 1) |
| `VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.0400.25509793.tar.gz` | [Plugins](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20vSphere%20Foundation%209&release=9.1.0.0&os=&servicePk=542815&language=EN&viewGroup=true&groupId=540672) | `VCF_CLI_SRC_DIR` |
| the amd64 `argocd` CLI | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | `VCF_CLI_SRC_DIR` |
| `supervisor-service-argocd-legacy-1.1.0-25100889.yml` | [ArgoCD](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=538499) | anywhere — you upload it in vCenter in Step 5 |
| `supervisor-service-harbor-legacy-v2.14.3+vmware.2-vks.1-25292931.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | anywhere — you upload it in vCenter in Step 4 |
| `supervisor-service-harbor-data-values-v2.14.3.yml` | [Harbor](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&servicePk=542081) | `~/Downloads/vcf` |

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
| `VCF_CLI_SRC_DIR` | `/home/you/Downloads/vcf` | the folder you put the two Broadcom archives in |
| `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → Control Plane Node IP. **Bare host — no `https://`, no trailing slash.** |
| `VKS_CONTEXT_NAME` | `vks-cicd` | **you invent this** — a short label for the `vcf` login context |
| `VKS_NAMESPACE` | `lab` | the vSphere Namespace the cluster goes in. **Create it first — Step 2.** |
| `VKS_CLUSTER_NAME` | `cicd-gc1` | **you invent this** — the guest cluster Step 6 creates. Must not be a name you deleted recently (see notes). |
| `VKS_USERNAME` | `administrator@vsphere.local` | your vCenter SSO login |
| `VCF_CLI_VSPHERE_PASSWORD` | *your value* | the password for that login |
| `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups → *Domain* |

Now run:

```bash
make deps                     # toolchain: kubectl, helm, crane, tkn, jq, yq…
make install-vcf-clis         # reads VCF_CLI_SRC_DIR, which you set above
make check-tools              # what you have, what is missing
```

**Expect:** `check-tools` prints `all REQUIRED tools present.` *(~5 min, mostly downloads)*

### Put the toolchain on YOUR shell's PATH

`make` finds these tools by itself, so every `make …` below works right now. The commands that are
**not** `make` — `kubectl`, `vcf`, `argocd` — run in *your* shell, which cannot see
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

## 2. The vSphere Namespace

Your cluster goes in a vSphere Namespace. Use your own — not one shared with other workloads,
because teardown deletes **by name** and this repo's app names are generic.

> **Already have one?** Put its name in `VKS_NAMESPACE` and go to Step 3 — nothing else here
> applies to you.

Step 3 activates a login context at this namespace and fails if it does not exist yet, so create it
now.

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VCENTER_HOST` | `vcsa.env1.lab.test` | your vCenter FQDN from Step 0 — **not** the Supervisor IP |
| `VCENTER_USERNAME` | `administrator@vsphere.local` | the same SSO login as Step 1 |
| `VCENTER_PASSWORD` | *your value* | the same password as Step 1 |
| `VKS_STORAGE_POLICY` | `wcp-vmfs` (single-host VMFS)<br>`vsan-default-storage-policy` (vSAN) | **Per-lab, not a constant** — those two are what real labs measured. **Already have a namespace? `make vsphere-namespace` prints the policy it uses, by name** — no kubeconfig needed. Otherwise vCenter → **Policies and Profiles → VM Storage Policies**; if you set it wrong the create stops and lists every available policy. |
| `VKS_VM_CLASSES` | `best-effort-small best-effort-medium` | space-separated; `best-effort-small` alone is enough. Defaults to the example, and the names are **sent to vCenter unchecked** — a class that does not exist fails with an HTTP code that does not mention VM classes. |
| `VKS_CLUSTER_COMPUTE` | *(leave unset)* | **only if** vCenter has **more than one** cluster. Steps 4 and 5 need it too, not just this one. |

⚠️ **It will not modify a namespace that already exists** — it prints what is attached and changes
nothing. So if a storage policy or VM class turns out to be missing, fix it in vCenter (or delete
and recreate the namespace); re-running with a corrected `.env` is a no-op.

```bash
make vsphere-namespace
```

**Expect:** `created vSphere Namespace '<name>' …` then `namespace '<name>' is RUNNING`.

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
| `VKS_CONTEXT_NAME` | `vks-cicd` | Step 1 (you invented it) |
| `VKS_USERNAME` | `administrator@vsphere.local` | Step 1 |
| `VKS_NAMESPACE` | `cicd` | Step 1, created in Step 2 |
| `VCF_CLI_VSPHERE_PASSWORD` | *your SSO password* | **exported below, never written to `.env`** |

```bash
make fetch-supervisor-ca
```

⚠️ **Confirm the printed SHA-256 with your platform team over another channel.** The download is
deliberately unverified TLS; the fingerprint is what authenticates it. A rebuilt lab mints a new CA
at the same address, so a stale file looks valid and is not.

```bash
set -a; . ./.env; set +a
export VCF_CLI_VSPHERE_PASSWORD='<your SSO password>'

vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
    --ca-certificate ./secrets/supervisor-ca.crt \
    --username "$VKS_USERNAME" --type kubernetes --auth-type basic
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"      # note the <ctx>:<ns> colon form

make vks-login                                          # writes ./secrets/supervisor.kubeconfig
```

⚠️ **`--username` is not optional.** Without it `vcf` asks `? Provide Username:` and dies
`[x] : EOF` in anything non-interactive.

⚠️ **Do not** use `vcf config set env.VCF_CLI_VSPHERE_PASSWORD` — it writes your SSO password in
plaintext to `~/.config/vcf/config.yaml`, outside this repo and every secret scan.

`vcf context use` can print a "system Harbor registry" error **and still have worked** — judge it by
the next command, not its exit code.

**Expect:** `./secrets/supervisor.kubeconfig` exists.

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
| `HARBOR_STORAGE_CLASS` | `wcp-vmfs` (VMFS)<br>`vsan-default-storage-policy` (vSAN) | `kubectl get storageclass` |

**Run:**

```bash
make install-harbor-service
make show-dns-records          # the exact A records to create, with their live LoadBalancer IPs
```

**Expect:** `7 secrets generated, 0 placeholders left`, then `install issued for
harbor.tanzu.vmware.com`. It registers the service, installs it behind an NGINX LoadBalancer and
generates all seven of Harbor required secrets — **including the admin password, which you do not
choose and which is not `Harbor12345`**. Read it back any time with `make creds-show`.

Now create those A records. `/etc/hosts` is **not** enough: the guest nodes must resolve the name
too. Harbor UI then answers at `https://<your FQDN>/`. *(~10 min)*

⚠️ If your vCenter has **more than one cluster**, set `VKS_CLUSTER_COMPUTE` as well, or this command
stops with *could not resolve the vSphere cluster moid*.

### If Harbor already exists

You still need its admin credential — `make install-all` authenticates with it.

```bash
export KUBECONFIG=./secrets/supervisor.kubeconfig
NS=$(kubectl get ns -o name | grep -oE 'svc-harbor-[a-z0-9]+' | head -1)
kubectl -n "$NS" get secret harbor-core-ver-1 -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d; echo
```

**Then set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `HARBOR_USERNAME` | `admin` | the Supervisor-installed Harbor uses `admin` |
| `HARBOR_PASSWORD` | *your value* | what the command above printed. **Not** `Harbor12345`. |

Prove it now, while you can still fix it cheaply:

```bash
printf 'user = "%s:%s"\n' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > /tmp/h.cfg
curl -sk -o /dev/null -w '%{http_code}\n' -K /tmp/h.cfg "https://${HARBOR_URL}/api/v2.0/users/current"; rm -f /tmp/h.cfg
```

**Expect:** `200`. A `401` means the credential is wrong — fix it here, or Step 11 stops with
`Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)`.

⚠️ If you leave `HARBOR_PASSWORD` unset, `make env-populate` in Step 11 **generates** one, and it
cannot possibly authenticate against a Harbor that already exists.

<details><summary>Optional — Harbor project names, both already work</summary>

| key | default | how to get the value |
|---|---|---|
| `HARBOR_INFRA_PROJECT` | `cicd` | **you choose** — the project for pipeline images |
| `HARBOR_APP_PROJECT` | `apps` | **you choose** — the project for app images. **Project-admin rather than system-admin?** Set this **equal to `HARBOR_INFRA_PROJECT`**; the robot account later can only be scoped to projects you administer. |

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
| `ARGOCD_NAMESPACE` | `cicd` | the vSphere Namespace the ArgoCD **instance** goes in. **Discover it, do not assume:** `kubectl get argocd -A`. ⚠️ Three later steps stop with `ARGOCD_NAMESPACE must be set`, and `make env-check` does **not** catch it. |
| `VKS_AUTH_METHOD` | `vcf` | leave it `vcf` here; the guest-cluster step changes it to `kubeconfig`. |

**Run:**

```bash
make install-argocd-service
```

**Expect:** `install issued for argocd-service.vsphere.vmware.com`, then `ArgoCD instance argocd-1
requested in namespace <ns>`.

**Then get its address and log in:**

```bash
kubectl get svc -n "$ARGOCD_NAMESPACE"                     # argocd-server -> EXTERNAL-IP
kubectl get secret -n "$ARGOCD_NAMESPACE" argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
argocd login <EXTERNAL-IP>
argocd account update-password
```

**Expect:** `argocd-server` has an EXTERNAL-IP and you can log in. *(~10 min)*

<details><summary>Optional — both already work</summary>

| key | default | how to get the value |
|---|---|---|
| `ARGOCD_SERVER` | *(unset — probes skip)* | the `argocd-server` EXTERNAL-IP. Display and probes only. |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` | what `make fetch-supervisor-ca` wrote. Set it only if you moved it. |

</details>

---

## 6. Guest cluster

Where Gitea, Tekton and your apps run. You need cluster-admin on it.

> **Already have a cluster?** Put its name in `VKS_CLUSTER_NAME`, skip the create command, and pick
> up at *Get its kubeconfig*.

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VKS_CLUSTER_NAME` | `cicd-gc1` | Step 1 (you invented it). **Never reuse a name you deleted recently** — it never converges. |
| `VKS_CONTEXT_NAME` | `vks-cicd` | Step 1 — read by the `vcf` fallback below |
| `VKS_NAMESPACE` | `cicd` | Step 1 — read by the `vcf` fallback below |
| `VKS_K8S_VERSION` | `v1.34.8+vmware.1-vkr.1` | `kubectl get kubernetesreleases` -> pick one that is **Ready AND Compatible** and paste its **full** name. It is a *prefix* selector, so a bare `v1.34` is accepted and then floats — an air-gap repo must not do that. `make vks-cluster-create` server-side dry-runs it first and prints vCenter own rejection. |

```bash
make vks-cluster-create                                # applies the Cluster; provisioning is async
make vks-cluster-status                                # reports ONCE — read `endpoint :` now
make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800  # then wait for every node Ready
```

**Read the `endpoint :` line from the first command before starting the wait.** `AGREE` or
`NOT YET KNOWABLE` → carry on. `*** DIVERGENT ***` → stop and follow what it prints; the waiting
form will not show it for 30 minutes.

**Expect:** the waiting command reprints a table every 15 s, then exits `0` with every node
`Ready`. *(**4–6 min**)* A non-zero exit is not a pass — do not continue to Step 7.

### Get its kubeconfig

**If that command exited `0`, it already wrote one** — at `./secrets/<VKS_CLUSTER_NAME>.kubeconfig`,
read straight from the cluster's own Secret.

⚠️ The file existing is not proof the cluster is ready — the Secret is minted before the nodes
join, and no later check tests for workers. Only the `0` exit above means both. Use it:

```bash
set -a; . ./.env; set +a
kubectl --kubeconfig "./secrets/${VKS_CLUSTER_NAME}.kubeconfig" get nodes -o wide
```

**Expect:** your nodes listed, all `Ready`.

**Now that the cluster exists, set in `./.env`:**

<details><summary>No Supervisor access (the Scenario-2 tenant)? Ask the <code>vcf</code> CLI instead</summary>

```bash
set -a; . ./.env; set +a
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file "./secrets/${VKS_CLUSTER_NAME}.kubeconfig"
```

MEASURED 2026-08-09: on one 9.1 lab this failed with `Error: failed to get pinniped-info from
management cluster` while the Secret route above worked. If you hit that and you *do* have a
Supervisor kubeconfig, use the Secret route — it is the same credential.
</details>

| key | example | how to get the value |
|---|---|---|
| `KUBECONFIG` | `./secrets/cicd-gc1.kubeconfig` | `./secrets/<your VKS_CLUSTER_NAME>.kubeconfig` — the file above |
| `VKS_CONTEXT` | `cicd-gc1-admin@cicd-gc1` | `kubectl --kubeconfig ./secrets/<cluster>.kubeconfig config get-contexts -o name` |
| `VKS_AUTH_METHOD` | `kubeconfig` | **change it back from `vcf`** (Step 3 set that for the Supervisor login). From here on the pipeline runs against the guest-cluster kubeconfig above. |

⚠️ **`make vks-login` now renews the GUEST kubeconfig.** The Supervisor one expires too, and Steps
10 and 14 need it — `kubectl` then says *"the server has asked for the client to provide
credentials"*. Renew it with:

```bash
set -a; . ./.env; set +a
export VCF_CLI_VSPHERE_PASSWORD='<your SSO password>'
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"
VKS_AUTH_METHOD=vcf make vks-login
```

**Expect:** `Supervisor context verified via ./secrets/supervisor.kubeconfig`.

<details><summary>Optional — the cluster's shape. Skip unless you want to change it.</summary>

| key | default | example | how to get the value |
|---|---|---|---|
| `VKS_CLUSTERCLASS` | `builtin-generic-v3.6.0` | `builtin-generic-v3.6.0` | `kubectl get clusterclass -A` — the newest Ready one |
| `VKS_VM_CLASS` | `best-effort-small` | `best-effort-small` | `kubectl get virtualmachineclass` |
| `VKS_STORAGE_CLASS` | `wcp-vmfs` | `wcp-vmfs` | `kubectl get storageclass` |
| `VKS_CONTROL_PLANE_COUNT` | `1` | `1` | how many control-plane nodes |
| `VKS_NODE_COUNT` | `2` | `2` | how many workers. One is too small for the platform. |

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

Harbor uses a self-signed certificate. Save its CA so the jump box and the cluster trust it.
Harbor publishes it, so no login is needed.

**The commands below read this — already in `./.env`:**

| key | example | set where |
|---|---|---|
| `HARBOR_URL` | `harbor.env1.lab.test` | Step 4 |

```bash
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
  make harbor-ca-from-cluster
  ```

Note `make fetch-harbor-ca` reads the CA off the live connection, so it works only when Harbor's
certificate is self-signed. If a separate CA issued it — the usual case — that command stops and
tells you so.

</details>

---

## 9. Harbor robot (recommended)

CI pushes with a scoped credential instead of `admin`. Needs project-admin.

**Run:**

```bash
make harbor-robot            # writes ./secrets/harbor-robot.env (mode 0600)
cat ./secrets/harbor-robot.env
```

**Expect:** a `robot$vks-cicd` account scoped to your two projects. *(<1 min)*

**Then set in `./.env`,** copying the two values it just printed:

| key | example | how to get the value |
|---|---|---|
| `HARBOR_USERNAME` | `robot$vks-cicd` | the `HARBOR_USERNAME` line of `./secrets/harbor-robot.env` — replaces `admin` |
| `HARBOR_PASSWORD` | *your value* | the `HARBOR_PASSWORD` line of the same file |

⚠️ **Already exists?** It stops rather than overwriting: Harbor shows a robot secret **once**, so an
existing one cannot be re-read and re-creating it would hand you a credential that does not work.
Reuse `./secrets/harbor-robot.env`, or delete the robot in Harbor (**Administration -> Robot
Accounts**) and run it again.

---

## 10. The Supervisor kubeconfig ArgoCD needs

`make gitops` talks to **both** clusters: ArgoCD on the Supervisor, your apps in the guest.

**Set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` | the file the next command writes. **Set it explicitly.** The command writes that path either way — but `make gitops` and `make verify` will not *read* it unless this key is set, and silently use your **guest** kubeconfig instead. The file existing is therefore not a sign it is being used. |
| `ARGOCD_DEST_CLUSTER_NAME` | `vks-guest` | the name your guest cluster is registered under: `argocd cluster list`. **Required whenever ArgoCD's registered API URL for your guest differs from your kubeconfig's — including when only ONE cluster is registered** (that mismatch is common). Symptom: `make install-all` stops with `AMBIGUOUS deploy destination`. Left unset with a mismatch, a run once deployed into another cluster and reported `Synced/Healthy` throughout — it was healthy, in the wrong place. |

```bash
make fetch-argocd-kubeconfig
make argocd-preflight           # CLI vs running-server versions; can ArgoCD reach your cluster?
```

**Expect:** `PREFLIGHT OK`. If it says your guest cluster is not registered:

```bash
make argocd-register-guest      # admin-only; creates an SA in your guest + a Secret in ArgoCD's ns
```

**Expect:** re-running `make argocd-preflight` now says `PREFLIGHT OK`. *(~2 min)*

`make argocd-version` prints the CLI version, the **running server** version and this repo's pin.
The running server is the one that matters.

---

## 11. Validate, then install

```bash
make env-populate     # generates Gitea's admin password; discovers anything you left blank
make env-check        # every required value set? (fast, no network)
make env-validate     # does KUBECONFIG reach the cluster? does Harbor authenticate?

make install-all      # preflight -> mirror -> builder -> platform -> gitops
make verify           # pushes a marked change and follows it to the running app
```

**Expect:** `env-validate` reports Harbor reachable **and authenticated**; `install-all` completes;
`make verify` exits **0** for every app. *(**install-all 8–10 min**, **verify 3–4 min**)*

---

## 12. Ingress (optional)

Reach the UIs at `*.vks.local` instead of port-forwarding.

```bash
make istio-preflight
```

| It says | You run |
|---|---|
| **NO Istio detected** | `make install-ingress` — installs Istio from your Harbor |
| **Istio already here** | `make install-ingress INGRESS_CONTROLLER=istio-existing` — attaches routes only, installs nothing |

On a real lab Istio is usually already present as a Standard Package — attach, do not install.
*(~5 min)*

Then **check the routes actually work**, before you rely on those hostnames:

```bash
make verify-ingress           # each *.vks.local host must reach ITS OWN backend
```

**Expect:** one `OK` per host — `gitea`, `tekton`, and each app. It sends `Host: <name>.vks.local`
to the ingress LoadBalancer IP directly, so **it needs no DNS and no `/etc/hosts` entry** — and it
asserts a per-host body marker, not just a 200, because a mis-wired route returns 200 from the
*wrong* backend. A host that fails here will not work in a browser either, and this names which one and why. *(~1 min)*

---

## 13. Access the UIs

```bash
make creds-show
```

**Expect:** every URL and login — Harbor, ArgoCD, Gitea, Tekton, one row per app. Each value is
labelled **DISCOVERED** (read live) or **STORED** (remembered).

Skipped Step 12? The `*.vks.local` URLs will not resolve — reach a service directly instead:

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000     # then http://localhost:3000
kubectl -n javawebapp port-forward svc/javawebapp 18080:80 # then http://localhost:18080
```

**Expect:** the UI answers on `localhost` at the port you forwarded.

---

## 14. Uninstall

Removes what this runbook installed. It does not touch the vSphere lab.

```bash
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
| 6 | `make vks-cluster-create` | <1 s | <1 s |
| 6 | cluster → all nodes `Ready` | **3 m 45 s** | **≈ 6 m** |
| 7 | `make lab-preflight` | 2 s | 2 s |
| 8 | `make harbor-ca-from-cluster` | <1 s | <1 s |
| 11 | `make env-check`, `make env-validate` | <1 s each | <1 s each |
| 11 | `make install-all` | **10 m 26 s** | **8 m 14 s** |
| ↳ | `mirror-pull` / `mirror-push` / `mirror-verify` | 22 s / 2 m 38 s / 5 m 46 s | — |
| ↳ | `builder-image` + `platform` + `gitops` | ≈1 m 40 s | — |
| 11 | `make verify` (2 apps) | **3 m 6 s** | **3 m 27 s** |
| 14 | `make uninstall-all` | 1 m 12 s | 1 m 12 s |

From a **bare Photon jump box** (fresh box, nothing cached — so the mirror pulls every image), the
same lab, measured start to `End-to-end verified`:

| | |
|---|---|
| Step 0–1 install `git`/`make`, clone, `make deps`, install the CLIs | ≈ 2 m 30 s |
| Step 6 cluster created → every node `Ready` | **8 m 49 s** |
| Step 11 `make install-all` + `make verify` | **10 m 08 s** |
| **whole run, clone → verified** | **21 m 31 s** |
