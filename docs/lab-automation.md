# `NiranEC77/lab-automation` — how the other VKS lab automation works

A reference for a **different** automation of the same VCF/VKS lab this repo targets, so a future
session does not have to re-derive it. Read it when you want to know how someone else solved
Scenario 1 / Scenario 2, what is worth borrowing, and what is not.

> **⚠️ Read this first, or you will draw the wrong conclusion.** That stack is **internet-sourced
> end to end**. Every Argo CD `repoURL` is `github.com`; the CLIs come from
> `releases/download`; the PowerCLI SDK from PSGallery; the attach fling from `ghcr.io`;
> Terraform from `apt.releases.hashicorp.com`; the Carvel package repository from
> `projects.packages.broadcom.com`. **There is no air gap anywhere in it.** It is not a
> competing solution to our problem — this repo exists *because of* a constraint that one does
> not have. Almost everything below is "interesting, and unavailable to us" for exactly that
> reason.

**How to read the citations below — they span THREE repositories.** A bare path resolves against
`NiranEC77/lab-automation` at commit **`86fadb6`** (13 files, ~100 KB; Shell + PowerShell +
Python). Paths from its two dependencies are cited with a leading marker and were read at `main`,
so those line numbers may drift:

| Prefix in a citation | Repository | Read at |
|---|---|---|
| `setup-lab.sh`, `ctx-lib.sh`, `vcfa-token.py`, `install-supervisor-services.ps1`, `supervisor-services/…`, `README.md` | `NiranEC77/lab-automation` | **`86fadb6`** |
| `argo-e2e/…`, `modules/…` | `warroyo/vcfa-terraform-examples` | `main` |
| `cluster-bootstrap/…`, `istio/…`, `package-rbac/…`, `vks-standard-repo/…` | `warroyo/vks-argocd-examples` | `main` |

Resolving one at the pin (note `?ref=` — quote the URL, `?` is a zsh glob character):

```bash
gh api -H "Accept: application/vnd.github.raw" \
  "repos/NiranEC77/lab-automation/contents/ctx-lib.sh?ref=86fadb6"
```

---

## 1. What it is

A one-command bootstrap that turns a clean Ubuntu desktop into a working VCF / vSphere-with-Tanzu
lab. Two modes (`setup-lab.sh:24-32`): `prep` stops before `terraform apply`; `deploy` runs
everything. It picks one of three hard-coded lab environments (`ctx-lib.sh:11-56`) — note that
its `9.1` / `ss` environment is Supervisor endpoint `10.1.8.132`, org `Acme-East-A`
(`ctx-lib.sh:37-48`), the same lab our own VKS notes were verified against.

**What it is not:** a CI/CD demo. There is no pipeline, no image mirroring, no registry
interaction. Its Argo CD deploys a sample app from GitHub.

## 2. The flow

```text
setup-lab.sh (prep | deploy)
  ├─ installs CLIs (vcf, argocd, kubectl, terraform, pwsh + PowerCLI)
  ├─ downloads a password-protected Box bundle  → the Supervisor Service package YAMLs
  ├─ configure-supervisor.ps1                   → control-plane size MEDIUM
  ├─ install-supervisor-services.ps1  × N       → VKS, Argo CD, Argo CD Attach, Secret Store,
  │                                                Harbor, LCI, Management Proxy
  ├─ vcfa-token.py                              → a VCFA refresh token
  └─ terraform apply (warroyo/vcfa-terraform-examples//argo-e2e)
        ├─ supervisor namespace
        ├─ Argo CD instance (an operator CR)
        ├─ VKS guest cluster
        ├─ registers that cluster with Argo CD   (labels it type=vks)
        └─ an ApplicationSet bootstraps every labelled cluster
             from warroyo/vks-argocd-examples
```

The service list is data, not code — `supervisor-services/services.yaml:1-32`, one row per
service with `enabled:` and an optional `exclude_envs:` / `config:`. Parsed by an inline Python
heredoc at `setup-lab.sh:352-369`.

## 3. Authentication and authorization

This is the part worth reading closely, because it is where their model and ours differ most.

### 3.1 Getting a VCFA API token — `vcfa-token.py`

A three-leg OAuth exchange, all against a **hard-coded** FQDN (`vcfa-token.py:5`, a second source
of truth against Terraform's `vcfa_url`), with **TLS verification disabled** (`:3`, `:15`):

| Leg | Call | Yields |
|---|---|---|
| 1 | `POST /cloudapi/1.0.0/sessions`, basic auth as `<user>@<tenant>`, `Accept: application/json;version=40.0` (`:17-18`) | a JWT in the **`x-vmware-vcloud-access-token` response header** (`:19`) |
| 2 | `POST /oauth/tenant/<tenant>/register` `{"client_name": "lab-setup"}` (`:24-27`) | a `client_id` (`:32`) |
| 3 | `POST /oauth/tenant/<tenant>/token`, `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`, `assertion=<jwt>`, `client_id`, `scope=openid offline_access` (`:34-37`) | a **refresh token** (`:39`) |

That refresh token becomes `VCF_CLI_VCFA_API_TOKEN` and Terraform's `vcfa_refresh_token`.

The **flow** is sound and reusable. The **handling** is not: the user password is passed as
`argv[2]` (`ctx-lib.sh:77`), and the resulting long-lived token is written to a Desktop file
(`ctx-lib.sh:88`) and `sed`-ed into `~/.zshrc` (`ctx-lib.sh:92-96`) — persistent credential
state outside any repository, invisible to `gitleaks` and to any tracked-path gate.

### 3.2 VCF CLI contexts

Three contexts get created. The **Supervisor** one (`setup-lab.sh:308-313`):

```bash
vcf context create supervisor-ctx --endpoint "$SUPERVISOR_ENDPOINT" \
  --username administrator@wld.sso --insecure-skip-tls-verify -t kubernetes --auth-type basic
```

and the **VCFA** one (`ctx-lib.sh:126-131`), which documents three flags our own runbook does
not cover — and puts a long-lived token on the command line:

```bash
vcf context create vcfa --endpoint "$VCFA_ENDPOINT" \
  --api-token "$VCF_CLI_VCFA_API_TOKEN" --tenant-name "$VCFA_ORG" --ca-certificate "$VCFA_CERT_PATH"
```

Two facts we can use: the context **name is positional** in both, and the endpoint is a **bare
host with no scheme**. Both match what `make vks-login` already does — see
[VKS authentication](vks-authentication.md). The cert chain is harvested with
`openssl s_client -showcerts` (`ctx-lib.sh:121-122`).

### 3.3 Guest-cluster access — `configure_cluster_context` (`ctx-lib.sh:136-224`)

The real sequence, in order:

1. find the namespace sub-context by grepping `vcf context list` for a **hard-coded** namespace,
   then `head -1` (`ctx-lib.sh:141`) — an arbitrary pick if more than one matches;
2. `vcf context use <ctx>:<ns>` (`:152`);
3. a readiness loop, up to 30 × 30 s, whose **exit condition is `vcf cluster kubeconfig get`
   succeeding** (`:159-168`);
4. `sleep 60` (`:176-177`);
5. `vcf cluster register-vcfa-jwt-authenticator <cluster>`, 3 attempts (`:181-189`);
6. `vcf cluster kubeconfig get <cluster>` again, this time merging into `~/.kube/config` (`:198`).

> **Do not read step 4-5 as an architecture.** The word "Pinniped" appears in this repository
> **only inside the `echo` on line 176**. Nothing anywhere touches a `JWTAuthenticator` CR, a
> Concierge, or any `pinniped-*` object. And because step 3's exit condition is step 6's command,
> `vcf cluster kubeconfig get` demonstrably **succeeds before** the authenticator is registered —
> so registration is not a prerequisite for obtaining a kubeconfig. What is genuinely borrowable
> here is the **operational shape**: two poll loops, a settle delay, and every `vcf` call wrapped
> in `timeout` + `yes |` because the CLI prompts.

### 3.4 How Argo CD reaches a cluster — three distinct patterns

They never run `argocd cluster add`. They write the cluster Secret directly, and there are
**three** different shapes, which is more than our own notes record.

**(a) The guest cluster — mTLS from the CAPI admin kubeconfig.**
`modules/argo-attach-cluster/main.tf:1-33` builds a `config` blob selected by a `token_auth`
flag. **`token_auth` defaults to `false`** (`modules/argo-attach-cluster/variables.tf:15-18`)
**and `argo-e2e/main.tf:44-52` never passes it** — so the shipped path is the mTLS branch:
`caData` / `certData` / `keyData` lifted out of the `<cluster>-kubeconfig` Secret
(`modules/vks-cluster/main.tf:108-118`), i.e. a **client certificate**. The same file sets
`certificateRotation.renewalDaysBeforeExpiry = 15` (`:47-49`).

That is worth stating plainly: **this is the expiring-credential shape**, the one
`argoproj/argo-cd#13175` describes. They are living with it, not solving it.

**(b) The Supervisor namespace registering *itself*.**
`modules/argocd-attach-sv-namespace/main.tf` creates a ServiceAccount (`:13-18`), a **legacy
`kubernetes.io/service-account-token` Secret** with `wait_for_service_account_token = true`
(`:20-30`) — a durable, non-expiring token — a RoleBinding (`:33-55`), and a cluster Secret
(`:58-74`) whose `server` is `https://kubernetes.default.svc.cluster.local:443`.

It is invoked from `modules/argocd-instance/main.tf:32-36` with `namespace == argocd_namespace`,
so **both ends are the same namespace**. This is not remote attachment — it is Argo CD
registering the namespace it already runs in, over the in-cluster loopback. That is why its
`tlsClientConfig.insecure = true` is harmless here, and it is also why the pattern does **not**
transfer unmodified to a remote guest: for a remote cluster you would need the guest's CA, which
this shape sidesteps. Note too that it sets `namespaces` (scoping the destination) but **not**
`clusterResources`, which the guest-cluster variant does set.

**(c) An Application CR living in the Supervisor namespace.**
`argo-e2e/main.tf:58-108` creates an `argoproj.io/v1alpha1 Application` **in the supervisor
namespace**, with `destination.server` read straight out of the guest kubeconfig (`:94-97`).
Combined with (b), the model is: *the Argo CD instance's vSphere Namespace is its own tenancy
boundary, and Applications live there as ordinary custom resources.*

**The 1→N link.** `argo-e2e/main.tf:49-51` stamps `labels = { type = "vks" }` on the cluster
Secret; `cluster-bootstrap/application.yml:8-12` is an `ApplicationSet` whose **cluster
generator** selects `matchLabels: {type: vks}` and templates one bootstrap Application per
matching cluster, kustomize-patching `/spec/destination/name` to the cluster's name. Register a
cluster, and it gets bootstrapped. That is the cleanest idea in the whole stack.

### 3.5 Argo CD admin credential

`modules/argocd-instance/main.tf:38-51` overwrites the `argocd-secret` `admin.password` field
with `bcrypt(var.password)` plus `admin.passwordMtime`, `force = true`, guarded by
`count = var.password != "" ? 1 : 0`. Two defects worth knowing if you ever copy it:
`timestamp()` makes the resource a **perpetual diff** that rewrites the credential on every
apply, and Terraform's `bcrypt()` is documented as unsuitable for state for the same reason.
(A `locals` block reads `argocd-initial-admin-secret` as a fallback, but that local is **not
consumed** anywhere in that file.)

### 3.6 Secret Store — HashiCorp Vault

`modules/secret-store-vks-auth/main.tf` configures a Vault **Kubernetes auth backend** (`:4-19`,
with `disable_local_ca_jwt = true`), then a role (`:22-29`):

```hcl
bound_service_account_names      = ["*"]
bound_service_account_namespaces = ["*"]
token_policies                   = ["default", var.supervisor-namespace]
```

**Any** ServiceAccount in **any** namespace on that guest cluster can authenticate to Vault and
receive the supervisor-namespace policy. On a shared cluster that is a lateral-movement path.
The file's own comment concedes the design (`:21`). Record it as a pattern to avoid, not to copy.

### 3.7 Pod Security Admission is switched **off**

`modules/vks-cluster/main.tf:43-44` sets, in the cluster topology:

```hcl
"podSecurityStandard" = { "deactivated" = true }
```

Two consequences. First, **nothing in that stack is evidence about PSA `restricted`** — their
cluster-admin ServiceAccount, the Istio CNI DaemonSet, the gateway proxies and the Vault agent
injector all run with PSA disabled, so "it works for them" is not an argument in any of our open
PSA questions. Second, it names a **ClusterClass topology variable** none of our docs record;
verify the exact variable name against a real ClusterClass before relying on it.

## 4. Argo CD, Harbor, Istio — against what we do

### Argo CD

Installed as a Supervisor Service, then instantiated by an operator CR
(`modules/argocd-instance/main.tf:8-30`):

```hcl
"apiVersion" = "argocd-service.vsphere.vmware.com/v1alpha1"
"kind"       = "ArgoCD"
"spec"       = { "applicationSet" = { "enabled": true }, "version" = var.argocd_version }
```

`argo-e2e` sets that version to `3.0.19+vmware.1-vks.1`. See
[the Argo CD service card](vks-services/argocd.md) for what that does and does not tell us — in
short, `spec.version` is an operator-selectable **Carvel package** version, so a single observed
value is an example, not *the* pin.

The `wait` block at `:24-29` keys on `status.conditions[2].reason` — a **positional index into a
conditions array**, with the author's own comment admitting the status field is unreliable. Cite
only as an anti-pattern.

### Harbor

Installed as a Supervisor Service (`supervisor-services/services.yaml:25-28`) with a config file
supplying its FQDN, an admin credential and a storage class — **and then never used again**. No
robot account, no CA trust wiring, no mirroring, no pull. Nothing in the automation
authenticates to it.

Note the package YAMLs themselves are **not in the repository**: at `86fadb6` the only files
under `supervisor-services/` are `services.yaml` and `argo-attach.yaml`. Everything else arrives
in a password-protected Box bundle (`setup-lab.sh:181-219`), so the catalogue is unreviewable
from the repo alone.

So there is nothing to borrow *about Harbor*. There is something to borrow about the
**mechanism** that installs it — see §5.

### Istio

Absent from `services.yaml`, and `setup-lab.sh:401-405` selects a bootstrap path of either
`./cluster-bootstrap/basic` or `./cluster-bootstrap/fieldlabs-9.1` — and neither installs it
(`basic` is observability + repo; `fieldlabs-9.1` is repo only). **So the shipped lab runs no
service mesh.**

But the upstream content repo ships an Istio overlay, and it is the most interesting artifact
found: `vks-argocd-examples//istio/source/istio.yml:119-134` installs the **VKS Standard
Package** as a Carvel `PackageInstall`, driven by Argo CD:

```yaml
spec:
  packageRef:
    refName: istio.kubernetes.vmware.com
    versionSelection: { constraints: 1.25.3+vmware.1-vks.2, prereleases: {} }
  serviceAccountName: carvel-sa
  values: [ { secretRef: { name: istio-values } } ]
```

with a `PackageRepository` in `tkg-system` (`vks-standard-repo/source/repo.yml:1-9`) and a
`carvel-sa` holding `apiGroups: ['*'] resources: ['*'] verbs: ['*']` cluster-wide
(`package-rbac/source/rbac.yml:14-41`).

This corroborates our own position that Istio is a guest-cluster Standard Package installed by
the cluster owner, and it exposes the values schema of a mesh we might attach to. Both are
recorded in [the Istio service card](vks-services/istio.md); the question of whether we should
adopt the package install path is settled in
[the decision record](decisions/istio-via-vks-package.md).

## 5. What is worth borrowing

Ranked, each with the constraint that limits it.

| # | Idea | Where | Survives our constraints? |
|---|---|---|---|
| 1 | **The service registry shape** — one row per service, `enabled:` + `exclude_envs:` + optional `config:`, iterated by a loop | `supervisor-services/services.yaml:1-32` | ✅ air-gap, ✅ tenant. Matches the registry-plus-loop doctrine we already use for `apps/registry.tsv` |
| 2 | **ApplicationSet cluster generator keyed on a label** — attach stamps `type=vks`, the generator bootstraps every match | `argo-e2e/main.tf:49-51` + `cluster-bootstrap/application.yml:8-12` | ✅ mechanically; needs an Argo CD we control. The cleanest 1→N idea in the stack |
| 3 | **The VCFA OAuth flow** (§3.1) | `vcfa-token.py` | ✅ the flow; ❌ the code — rewrite without TLS-off, the hard-coded FQDN and the `~/.zshrc` write |
| 4 | **The precheck/upgrade loop** — poll to `COMPATIBLE` before install, strip `^v` and `+build` before a semver compare | `install-supervisor-services.ps1:95-140`, `:249-267` | Pattern only. PowerCLI + PSGallery is not an air-gap toolchain |
| 5 | **The operational shape of guest-cluster login** — poll loops, settle delay, `timeout` + `yes \|` around a prompting CLI | `ctx-lib.sh:159-198` | ✅ — but see §3.3; borrow the shape, not the claimed mechanism |

### Deliberately not borrowed

- **The mTLS attach (§3.4a)** — it *is* the expiring-credential problem we already documented.
- **The Argo CD Attach fling** (`supervisor-services/argo-attach.yaml:14-24`) — a community
  `.fling.` package pulling a digest-pinned bundle from `ghcr.io`, installable only by a
  Supervisor admin, and whose reconciliation behaviour against a hand-written cluster Secret is
  unknown without unpacking the image. It also has no equivalent in our KinD stand-in, which has
  no Supervisor at all.
- **The Vault `*` / `*` role (§3.6).**
- **All of their credential handling** — see §6.

## 6. Credential handling — a scope difference, stated plainly

Their choices are deliberate lab conveniences, and this is a lab bootstrap, not a product. They
are listed here because a reader skimming for patterns will otherwise copy them.

- A single lab credential is hard-coded at `ctx-lib.sh:7` and reused for `sudo`, vCenter SSO,
  VCFA, Argo CD and Harbor; the same literal is published in the README's copy-paste
  quick-start (`README.md:10`).
- Credentials on the command line: the user password as `argv[2]` to a Python script
  (`ctx-lib.sh:77`), `-Password` to three PowerShell invocations (`setup-lab.sh:329`, `:341`,
  `:377`), and inline in a vCenter REST call (`setup-lab.sh:473`). A refresh token likewise
  (`ctx-lib.sh:128`).
- Long-lived credential state on disk: a Desktop file (`ctx-lib.sh:88`), `~/.zshrc`
  (`:92-96`), a second Desktop file (`setup-lab.sh:280-283`), and plaintext in
  `terraform.tfvars` (`setup-lab.sh:406-424`) and therefore in Terraform state.
- TLS verification disabled in at least six places: `vcfa-token.py:3` and `:15`,
  `--insecure-skip-tls-verify` (`setup-lab.sh:312`), `curl -k` (`:141`, `:473`),
  `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore`
  (`install-supervisor-services.ps1:158`), and `insecure = true` in the Argo CD cluster Secrets.

Our own rules forbid every one of these; see `rules/common/security.md`.

## 7. Confidence

| Claim | Grade |
|---|---|
| Every `file:line` in §1-§6 for `NiranEC77/lab-automation` | `source-read` at `86fadb6` — files fetched and read in full |
| Every `file:line` for `warroyo/vcfa-terraform-examples` and `warroyo/vks-argocd-examples` | `source-read` at `main` — line numbers may drift |
| "Pinniped appears only in an `echo`" (§3.3) | `source-read` — full-file read of `ctx-lib.sh` |
| "`token_auth` defaults false and is never passed" (§3.4a) | `source-read` — verified in `variables.tf` and `argo-e2e/main.tf` |
| "PSA is deactivated" (§3.7) | `source-read` — `modules/vks-cluster/main.tf:43-44` |
| The Argo CD Attach fling's reconciliation behaviour | **NOT-ESTABLISHED** — logic is inside an OCI bundle; not unpacked |
| Whether the VKS Istio package's gateway matches our discovery signature | **NOT-ESTABLISHED** — needs a lab; see `lab-validation-plan.md` |

---

[← back to the README](../README.md)
