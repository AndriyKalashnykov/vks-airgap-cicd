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

## Before you start — read this once

**Where you run everything.** Clone this repo on the jump box and run **every command in this
runbook from the repo root**. Nothing here works from another directory.

```bash
git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
cd vks-airgap-cicd            # every command below assumes you are here
pwd                           # sanity: .../vks-airgap-cicd
```

**What `.env` is.** A single file at the repo root — `vks-airgap-cicd/.env` — holding every value
you configure. `make env-init` creates it from the committed template `.env.example`. Every key in
this runbook goes in **that** file; `make` reads it automatically, and paths like
`./secrets/harbor-ca.crt` are relative to the repo root.

```bash
make env-init                 # creates ./.env (backs up any existing one to .env.bak)
${EDITOR:-vi} .env            # this is the file every "→ set in .env" table below means
```

**Jump-box OS.** **Ubuntu** or **VMware Photon OS** — those are the two the tooling detects and
installs packages for (`apt` / `tdnf`). Anything else is unsupported and `make deps` will say so.

**Network.** The jump box must reach **both** the internet and the lab. Internet-only? Use
[the sneakernet flow](sneakernet.md) instead — it replaces Step 9.

**Example values.** Every table below has an *Example* column showing what a real 9.1 lab used.
They are illustrations, not defaults — yours will differ. Copy the **shape**, not the value.

## Time

About **35–50 minutes** of hands-on work, plus waiting. Measured on a real 9.1 lab (see
[Timings](#timings) for the full table and a second run):

| | |
|---|---|
| Steps 1–3 (browser + uploads) | ~20–30 min, one-time |
| Guest cluster becomes Ready | **4–6 min** |
| `make install-all` | **8–10 min** |
| `make verify` | **3–4 min** |
| `make lab-down` | **~1 min** |

## Requirements

**Downloads** — each needs your Broadcom entitlement:

| Artifact | Version | |
|---|---|---|
| **VCF Consumption CLI** — the Linux `_AMD64`/`_ARM64` archive | 9.1.0.0400 | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true) |
| **VCF Consumption CLI Plugins** — the Linux bundle | 9.1.0.0400 | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true) |
| **ArgoCD Service** — the `-legacy` manifest + the `argocd` CLI | 1.1.0 | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN) |
| **Harbor** — the `-legacy` manifest + its data-values file | 2.14.3 | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN) |

**Where to put each download:**

| Artifact | Where | What you do with it |
|---|---|---|
| VCF CLI + Plugins + the `argocd` CLI | any one folder on the jump box, e.g. `~/Downloads/vcf` | put the path in **`.env`** as `VCF_CLI_SRC_DIR=/home/you/Downloads/vcf`, then `make install-vcf-clis` reads it |
| ArgoCD Service YAML + Harbor YAML + Harbor data-values | leave them where they downloaded | you **upload** them in a browser (Steps 2–3); nothing on the jump box reads them |

*arm64: the VCF `argocd` is amd64-only — use the upstream one from `make deps`.
[Details](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives).*

**Collect from your lab before you start** — you will paste these into `.env` in Step 1:

| What | Example | Where to find it |
|---|---|---|
| Supervisor IP | `192.168.101.128` | vCenter → Workload Management → Supervisors → *Control Plane Node IP* |
| vCenter FQDN | `vcsa.env1.lab.test` | the address you log into vCenter with (needed in Step 3 for the CA) |
| your SSO user | `administrator@vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups |
| your SSO domain | `vsphere.local` | same screen, the *Domain* dropdown |
| the password | — | **never goes in `.env`** — you type it at a prompt in Step 3 |

---

## 1. Jump box

Install the toolchain and the licensed CLIs.

```bash
cd ~/vks-airgap-cicd          # or wherever you cloned it
make deps                     # toolchain: kubectl, helm, crane, tkn, jq, yq…
make install-vcf-clis         # reads VCF_CLI_SRC_DIR from .env
make check-tools              # what you have, what is missing
```

**Expect:** `check-tools` prints `all REQUIRED tools present.` *(~5 min, mostly downloads)*

**→ set in `./.env`:**

| key | example | how to get the value |
|---|---|---|
| `VCF_CLI_SRC_DIR` | `/home/you/Downloads/vcf` | the folder you put the two Broadcom archives in |
| `SUPERVISOR_HOST` | `192.168.101.128` | vCenter → Workload Management → Supervisors → Control Plane Node IP. **Bare host — no `https://`, no trailing slash.** |
| `VKS_CONTEXT_NAME` | `vks-cicd` | **you invent this** — a short label for the `vcf` login context |
| `VKS_NAMESPACE` | `lab` | the vSphere Namespace you will create the cluster in (vCenter → Workload Management → Namespaces) |
| `VKS_CLUSTER_NAME` | `cicd-gc1` | **you invent this** — the guest cluster Step 4 creates. Must not be a name you deleted recently (see notes). |
| `VKS_USERNAME` | `administrator@vsphere.local` | your vCenter SSO login |
| `VKS_SSO_DOMAIN` | `vsphere.local` | vCenter → Administration → Single Sign On → Users and Groups → *Domain* |

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
   cd ~/vks-airgap-cicd
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
2. Create a vSphere Namespace for the instance (with VM class + storage class assigned).

3. **Get the Supervisor's CA.** You need it to log in without disabling TLS verification. It comes
   from **vCenter**, not the Supervisor (the Supervisor serves only its leaf certificate):

   ```bash
   cd ~/vks-airgap-cicd
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
   cd ~/vks-airgap-cicd
   set -a; . ./.env; set +a          # loads SUPERVISOR_HOST, VKS_CONTEXT_NAME, VKS_NAMESPACE

   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --ca-certificate ./secrets/supervisor-ca.crt --auth-type basic
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"      # note the <ctx>:<ns> colon form
   ```

   It prompts for your password. `vcf context use` can print an error about a "system Harbor
   registry" **and still have worked** — judge it by the next command, not its exit code.

5. Apply the instance CR. `kubectl explain argocd.spec.version` lists what your operator supports:

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: <the namespace from step 2> }
   spec: { version: <a supported version> }
   ```

6. Get its address and first password:

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

---

## 4. Guest cluster

Where Gitea, Tekton and your apps run. You need cluster-admin on it.
*Already have a cluster? Skip to "Export its kubeconfig".*

```bash
cd ~/vks-airgap-cicd
make vks-cluster-create      # applies the Cluster; provisioning is asynchronous
make vks-cluster-status      # waits, then reports
```

**Expect:** every node `Ready`, and `endpoint : AGREE`. *(**4–6 min**)*

⚠️ **Do not reuse a cluster name you deleted recently** — it never converges. Pick a new one. See
the notes for the measurement.

**→ optionally set in `./.env`** (defaults suit most labs):

| key | example | how to get the value |
|---|---|---|
| `VKS_CLUSTERCLASS` | `builtin-generic-v3.6.0` | `kubectl get clusterclass -A` on the Supervisor — take the newest Ready one |
| `VKS_K8S_VERSION` | `v1.32.10+vmware.1-fips` | `kubectl get kubernetesreleases` — one that is both Ready and Compatible |
| `VKS_VM_CLASS` | `best-effort-small` | `kubectl get virtualmachineclass` |
| `VKS_STORAGE_CLASS` | `wcp-vmfs` | `kubectl get storageclass` |
| `VKS_WORKER_COUNT` | `2` | how many workers you want |

### Get its kubeconfig

**`make vks-cluster-status` already wrote one** — at `./secrets/<VKS_CLUSTER_NAME>.kubeconfig`, read
straight from the cluster's own Secret. Use it:

```bash
cd ~/vks-airgap-cicd
set -a; . ./.env; set +a
kubectl --kubeconfig "./secrets/${VKS_CLUSTER_NAME}.kubeconfig" get nodes -o wide
```

**Expect:** your nodes listed, all `Ready`.

<details><summary>No Supervisor access (the Scenario-2 tenant)? Ask the <code>vcf</code> CLI instead</summary>

```bash
cd ~/vks-airgap-cicd
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
| `VKS_AUTH_METHOD` | `kubeconfig` | leave as-is — the pipeline runs against the file above |
| `GITEA_ADMIN_PASSWORD` | *your value* | **you choose it** — Gitea is installed by this repo, so you set its admin password |

---

## 5. Preflight

Catches what would otherwise kill the run *after* a 20-minute mirror.

```bash
cd ~/vks-airgap-cicd
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
cd ~/vks-airgap-cicd
make harbor-ca-from-cluster
```

**Verify it either way** — ask whoever runs Harbor for the CA's SHA-256 first, over a channel that
is not this connection:

```bash
cd ~/vks-airgap-cicd
make fetch-harbor-ca HARBOR_CA_SHA256='<the digest they gave you>'
```

**Expect:** `./secrets/harbor-ca.crt` exists, is `0644`, and its SHA-256 matches. *(<1 min)*

---

## 7. Harbor robot (recommended)

CI pushes with a scoped credential instead of `admin`.

```bash
cd ~/vks-airgap-cicd
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
cd ~/vks-airgap-cicd
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
cd ~/vks-airgap-cicd
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
cd ~/vks-airgap-cicd
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
cd ~/vks-airgap-cicd
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
