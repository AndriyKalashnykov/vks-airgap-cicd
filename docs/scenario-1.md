# Scenario 1 — you install Harbor and ArgoCD

## What this is

You have a **Supervisor** endpoint, a login and a password. This runbook installs Harbor and ArgoCD
as Supervisor Services, creates a guest VKS cluster, and runs an air-gapped CI/CD pipeline into it.

**What you end up with:** `git push` → Tekton builds → image to Harbor → tag written back → ArgoCD
syncs → the app serves the change. Two demo apps (Java and Go), proven by `make verify`.

**Topology — two clusters, two kubeconfigs.** Harbor and ArgoCD run on the **Supervisor**. Gitea,
Tekton and your apps run in the **guest cluster**.

**Your jump box must reach the internet and the lab.** Internet-only? Use
[the sneakernet flow](sneakernet.md) instead — it replaces Step 9.

> **Why a step is shaped the way it is** → [scenario-1-notes.md](scenario-1-notes.md). You do not
> need it for a normal install. Read it when a step surprises you, or before you simplify one.

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

**Where they go:**

| Artifact | Put it |
|---|---|
| CLI + Plugins + `argocd` CLI | one folder, e.g. `~/Downloads/vcf` → set `VCF_CLI_SRC_DIR` |
| ArgoCD Service + Harbor YAMLs | nowhere — you upload them in the browser (Steps 2–3) |

*arm64: the VCF `argocd` is amd64-only — use the upstream one from `make deps`.
[Details](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives).*

**From your lab, before you start:** the Supervisor IP, your SSO username and domain, and the
password. The password never goes in `.env` — you type it at a prompt.

---

## 1. Jump box

**Run:**

```bash
make env-init                                          # a blank .env from .env.example
make deps                                              # toolchain: kubectl, helm, crane, tkn…
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf  # the licensed vcf CLI + plugins
make check-tools                                       # what you have, what is missing
```

**Expect:** `check-tools` lists no missing **required** CLI. *(~5 min, mostly downloads)*

**Then set in `.env`** (the keys are already there, commented):

| key | value |
|---|---|
| `SUPERVISOR_HOST` | Supervisor IP — vCenter → Workload Management → Supervisors. Bare host, no scheme. |
| `VKS_CONTEXT_NAME` | a name you choose for the `vcf` context, e.g. `sup` |
| `VKS_NAMESPACE` | the vSphere Namespace for your guest cluster |
| `VKS_CLUSTER_NAME` | the guest cluster you will create |
| `VKS_SSO_DOMAIN` | your SSO domain — vCenter → Administration → Single Sign On → Users and Groups, *Domain* |

---

## 2. Harbor (browser)

**Goal:** the registry every image comes from.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)

**Do:**

1. Give Harbor an ingress — an **NGINX LB** or **Contour** (install Contour first if you pick it).
2. Supervisor Management → Services → Add New Service → upload the Harbor manifest
   (`supervisor-service-harbor-legacy-*.yml` for a disconnected Supervisor).
3. Decide two values that are **yours**:

   | | what it is | how to find it |
   |---|---|---|
   | `HARBOR_FQDN` | the name Harbor serves, and the name **guest nodes must resolve** | you choose it — real DNS must answer it |
   | `HARBOR_STORAGE_CLASS` | the storage class Harbor's PVCs bind to | `kubectl get storageclass` against the Supervisor, or the Namespace's **Storage** tab |

4. Edit the data-values file:

   ```bash
   src=~/Downloads/vcf/supervisor-service-harbor-data-values-v2.14.3.yml
   HARBOR_FQDN='<the name you chose>'
   HARBOR_STORAGE_CLASS='<from the table above>'

   cp "$src" harbor-values.yaml
   sed -i \
     -e "s/hostname: yourdomain.com/hostname: ${HARBOR_FQDN:?}/" \
     -e 's/enableNginxLoadBalancer: false/enableNginxLoadBalancer: true/' \
     -e "s/insert-storage-class-name-here/${HARBOR_STORAGE_CLASS:?}/" \
     -e 's/enableContourHttpProxy: true/enableContourHttpProxy: false/' \
     harbor-values.yaml

   diff "$src" harbor-values.yaml     # expect exactly 4 changed lines
   ```

   Then replace **every `[Required]` secret by hand**, each one distinct: `harborAdminPassword`
   (ships the known default `Harbor12345`), `secretKey` (16 chars), `core.xsrfKey` (32 chars),
   `database.password`, `core.secret`, `jobservice.secret`, `registry.secret`. Leave
   `tls.crt`/`tls.key`/`ca.crt` empty. Do not touch `tlsCertificate.tlsSecretLabels`.

5. Supervisor Management → Services → Harbor → Manage Service → paste `harbor-values.yaml` → Finish.
6. Create a **real DNS record** for `HARBOR_FQDN` pointing at the ingress IP
   (`kubectl get svc -n <harbor-ns>` against the Supervisor). Not `/etc/hosts` — see the notes.

**Expect:** Harbor's UI answers at your FQDN. *(~10 min)*

**→ `.env`:**

| key | value |
|---|---|
| `HARBOR_URL` | your `HARBOR_FQDN` — bare host, no scheme, no trailing slash |
| `HARBOR_USERNAME` / `HARBOR_PASSWORD` | `admin` and your `harborAdminPassword` |
| `HARBOR_CA_FILE` | `./secrets/harbor-ca.crt` (fetched in Step 6) |
| `HARBOR_INFRA_PROJECT` / `HARBOR_APP_PROJECT` | `cicd` / `apps` |

---

## 3. ArgoCD (Supervisor)

**Goal:** the GitOps engine, on the Supervisor.
[Broadcom docs](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html)

**Do:**

1. Install the **ArgoCD Operator** Service — same upload flow as Harbor.
2. Create a vSphere Namespace for the instance, e.g. `argocd-instance-1`, with VM + storage classes.
3. **Run:**

   ```bash
   set -a; . ./.env; set +a          # make sources .env; your shell does not

   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --ca-certificate ./secrets/supervisor-ca.crt --auth-type basic
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"      # note the <ctx>:<ns> colon form
   ```

   *No CA yet? See the notes — do not reach for `--insecure-skip-tls-verify` first.*

4. Apply the instance CR (`kubectl explain argocd.spec.version` lists supported versions):

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: argocd-instance-1 }
   spec: { version: <supported-version> }
   ```

5. **Run:**

   ```bash
   kubectl get svc -n argocd-instance-1        # argocd-server → EXTERNAL-IP
   kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d
   argocd login <LB-IP>
   argocd account update-password
   ```

**Expect:** `argocd-server` has an EXTERNAL-IP and you can log in. *(~10 min)*

**→ `.env`:**

| key | value |
|---|---|
| `ARGOCD_NAMESPACE` | `argocd-instance-1` — the namespace the instance runs in |
| `ARGOCD_SERVER` | the `argocd-server` LB IP |
| `ARGOCD_TRACK_BRANCH` | `main` |

---

## 4. Guest cluster

**Goal:** where Gitea, Tekton and your apps run. You need cluster-admin on it.
*Already have one? Skip to "Export its kubeconfig".*

**Run:**

```bash
make vks-cluster-create      # applies the Cluster; provisioning is asynchronous
make vks-cluster-status      # waits, then reports
```

**Expect:** `vks-cluster-status` ends with every expected node `Ready` and
`endpoint : AGREE`. *(**4–6 min**)*

⚠️ **Do not reuse a cluster name you just deleted** — it never converges. Use a new name. See the
notes for the measurement.

Set the topology in `.env` first if the defaults do not suit: `VKS_CLUSTERCLASS`, `VKS_K8S_VERSION`,
`VKS_VM_CLASS`, `VKS_STORAGE_CLASS`, `VKS_WORKER_COUNT`.

### Export its kubeconfig

```bash
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file ./secrets/vks.kubeconfig
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
```

**Expect:** nodes listed.

**→ `.env`:**

| key | value |
|---|---|
| `KUBECONFIG` | `./secrets/vks.kubeconfig` |
| `VKS_CONTEXT` | the context name **inside that file** — `kubectl --kubeconfig ./secrets/vks.kubeconfig config get-contexts` |
| `VKS_AUTH_METHOD` | `kubeconfig` |
| `GITEA_ADMIN_PASSWORD` | you choose it |

---

## 5. Preflight

**Goal:** catch what would otherwise kill the run *after* a 20-minute mirror.

```bash
make vks-login
make lab-preflight
make psa-check
```

**Expect:** `LAB PREFLIGHT OK`. `psa-check` says **`PSA UNPROVEN`** on a bare cluster — that is the
expected answer, not a failure. *(~1 min)*

---

## 6. Harbor's CA

**Goal:** `crane` on the jump box and Kaniko in-cluster must trust Harbor's self-signed certificate.

**Pick one route:**

| | Run | Needs |
|---|---|---|
| **A — the Harbor UI (prefer this)** | Harbor → project → Registry Certificate → download `ca.crt` → save as `$HARBOR_CA_FILE` | a Harbor login only |
| **B — from the cluster** | `make harbor-ca-from-cluster` | Supervisor access **and an admin-level grant** — see the notes |

Ask whoever runs Harbor for the CA's SHA-256 out of band, then:

```bash
make fetch-harbor-ca HARBOR_CA_SHA256='<digest>'
```

**Expect:** `$HARBOR_CA_FILE` exists, is `0644`, and its SHA-256 matches. *(<1 min)*

---

## 7. Harbor robot (recommended)

```bash
make harbor-robot        # → secrets/harbor-robot.env (0600); copy its two lines into .env
```

**Expect:** a `robot$vks-cicd` scoped to `cicd` + `apps`. Needs project-admin. *(<1 min)*

---

## 8. The Supervisor kubeconfig ArgoCD needs

**Goal:** `make gitops` talks to **both** clusters.

**→ `.env` first:**

| key | value |
|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` — **unset, it defaults to the guest kubeconfig and gitops looks in the wrong cluster** |
| `VKS_CA_CERT_FILE` | `./secrets/supervisor-ca.crt` (preferred) — or `VKS_INSECURE_SKIP_TLS_VERIFY=true` |
| `ARGOCD_NAMESPACE` | the namespace your ArgoCD instance runs in — **discover it, do not assume** |

```bash
make fetch-argocd-kubeconfig     # prompts for your password
make argocd-preflight            # CLI vs server versions; can ArgoCD reach your cluster?
```

**Expect:** `PREFLIGHT OK`. If it says your guest cluster is not registered, run
`make argocd-register-guest`. *(~2 min)*

The version that matters is your Supervisor's **running ArgoCD server**, not the `argocd` CLI on
your jump box. `make argocd-version` prints CLI, running server and this repo's pin side by side —
read-only, exits 0, works with no cluster.

---

## 9. Validate, then install

```bash
make env-populate     # mint the Gitea secret; discover anything you left blank
make env-check        # every required value set? (fast, no network)
make env-validate     # does KUBECONFIG reach the cluster, does Harbor authenticate?

make install-all      # preflight → mirror → builder → platform → gitops
make verify           # push a marked change and watch it reach the running app
```

**Expect:** `env-validate` reports Harbor reachable **and authenticated**; `install-all` completes;
`make verify` exits **0** for every app. *(**install-all 8–10 min**, **verify 3–4 min**)*

---

## 10. Access the UIs

```bash
make creds-show
```

**Expect:** every URL and login for this context — Harbor, ArgoCD, Gitea, Tekton, and one row per
app. Values are labelled **DISCOVERED** or **STORED**, so you can tell live from remembered.

No ingress yet? Port-forward:

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000
kubectl -n <app> port-forward svc/<app> 18080:80
```

---

## 11. Ingress (optional)

**Goal:** reach the UIs at `*.vks.local` instead of port-forwarding.

```bash
make istio-preflight
```

| It says | You run |
|---|---|
| **NO Istio detected** | `make install-ingress` — installs Istio from your Harbor |
| **Istio already here** | `make install-ingress INGRESS_CONTROLLER=istio-existing` — attaches routes only, installs nothing |

On a real lab Istio is usually already there as a Standard Package — attach, do not install.
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

Measured 2026-08-08 on a real 9.1 lab. Hardware: i9-14900KF (24C/32T), 188 GiB, NVMe — **running the
nested lab on the same box**, so every number is under self-contention.

⚠️ **The mirror ran WARM** (34 of 44 images already cached, against a Harbor that already held them).
A first run on an empty Harbor is bounded by your bandwidth and is not represented here.

| Step | Command | Measured |
|---|---|---|
| 5 | `make preflight` | 2 s |
| 9 | `make env-check`, `make env-validate` | <1 s each |
| 4 | `make vks-cluster-create` | <1 s — it applies and returns |
| 4 | cluster → all nodes `Ready` | **3 m 45 s** |
| 6 | `make harbor-ca-from-cluster` | <1 s |
| 9 | `make install-all` | **10 m 26 s** (warm) |
| ↳ | `mirror-pull` / `mirror-push` / `mirror-verify` | 22 s / 2 m 38 s / 5 m 46 s |
| ↳ | `builder-image` + `platform` + `gitops` | ≈1 m 40 s |
| 9 | `make verify` (2 apps, sequential) | **3 m 6 s** |
| 12 | `make lab-down` | 1 m 12 s |

`mirror-verify` is the one row a warmer run would **not** improve — it re-fetches every blob.
`MIRROR_VERIFY_FAST=1` trades layer verification for speed.

**A second full run, same box, same day** — the two disagree in both directions, so budget from the
range, not from one number:

| | run 1 | run 2 | why |
|---|---|---|---|
| cluster → Ready | 3 m 45 s | **≈ 6 m** | run 2 provisioned beside the lab's own cluster |
| `make install-all` | 10 m 26 s | **8 m 14 s** | Harbor warmer still |
| `make verify` | 3 m 6 s | **3 m 27 s** | |
| `make lab-down` | 1 m 12 s | 1 m 12 s | identical |

**Provisioning is the variable row, not the mirror** — the mirror gets monotonically warmer while the
host gets busier.
