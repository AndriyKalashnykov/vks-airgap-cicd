# VKS authentication (VCF 9 + Supervisor) — not needed for KinD

How `$KUBECONFIG` is produced. This is the same for **both** VKS scenarios — the mechanism does
not depend on whether you install Harbor/ArgoCD or inherit them, so it lives here once.

**What DOES differ per scenario is how many kubeconfigs you need**, and each scenario says so in its
own body:

| | guest / workload (`KUBECONFIG`) | ArgoCD cluster (`ARGOCD_KUBECONFIG`) |
|---|---|---|
| **Scenario 1** (you install ArgoCD) | yes — `make vks-login` | **yes** — `make fetch-argocd-kubeconfig`. ArgoCD is a Supervisor Service, so the Applications are created *there*, not in your guest cluster. |
| **Scenario 2** (tenant) | yes — `make vks-login` | only if you were granted access. Otherwise use the **tenant write path** (`ARGOCD_MECHANISM=api`), which goes through argocd-server and needs no Kubernetes RBAC in the ArgoCD namespace. |

<br>

`scripts/30-vks-login.sh` (`make vks-login`) is the single pluggable step that produces a
working `KUBECONFIG` and context; everything downstream is auth-agnostic. Select the method
with `VKS_AUTH_METHOD`:

| Method | Use it when | Inputs (`.env`) |
|--------|-------------|-----------------|
| `kubeconfig` (default) | You already have the lab's exported kubeconfig | `KUBECONFIG`, `VKS_CONTEXT` |
| `vcf` | Real VCF 9 lab, via the VCF Consumption CLI | `SUPERVISOR_HOST`, `VKS_USERNAME` (+ `VKS_SSO_DOMAIN`), `VKS_NAMESPACE`, `VKS_CLUSTER_NAME`, `VKS_CONTEXT_NAME`, `VKS_INSECURE_SKIP_TLS_VERIFY` |
| `vsphere` | Pre-9 Supervisor, via the kubectl-vsphere plugin (legacy) | `SUPERVISOR_HOST`, `VKS_NAMESPACE`, `VKS_CLUSTER_NAME`, `VKS_USERNAME`, `VKS_PASSWORD` |

**`vcf` method — the real VCF Consumption CLI flow.** `.env` inputs:

```bash
VKS_AUTH_METHOD=vcf
SUPERVISOR_HOST=<supervisor-IP-or-FQDN>   # no scheme; vCenter → Workload Management → Supervisors → Control Plane IP
VKS_USERNAME=administrator@WLD.SSO        # 'user@SSO.DOMAIN' (or set VKS_SSO_DOMAIN and give the bare user)
VKS_NAMESPACE=<vsphere-namespace>         # the <ns> in `vcf context use <name>:<ns>`
VKS_CLUSTER_NAME=<vks-cluster-name>       # the workload cluster to fetch the kubeconfig for
VKS_CONTEXT_NAME=sup66                    # the vcf context NAME you type at the create prompt
VKS_INSECURE_SKIP_TLS_VERIFY=true         # skip verifying the Supervisor's self-signed cert
```

`make vks-login` then runs (the context NAME is **positional**; the CLI prompts for the
**password**, so no secret ever touches argv):

```bash
vcf context create <VKS_CONTEXT_NAME> --endpoint <SUPERVISOR_HOST> \
    --username <user>@<SSO-DOMAIN> --type kubernetes --auth-type basic \
    [--insecure-skip-tls-verify]                     # bare host, NO scheme; password prompted
vcf context use <VKS_CONTEXT_NAME>:<VKS_NAMESPACE>   # <ns> discovered when unset — see below
vcf cluster kubeconfig get <VKS_CLUSTER_NAME> --export-file <KUBECONFIG>   # GUEST cluster only — see below
```

`VKS_NAMESPACE` is **optional**: when unset, the script lists the contexts the create above produced
and takes the single `<ctx>:<ns>` match, failing with every candidate printed if there is more than
one. `VKS_USERNAME` is also optional and defaults, announced in the log.

**Lab-verified 2026-07-22** on a real VCF 9.1 Supervisor (`10.1.8.132`). The first two commands
were run exactly as above and worked; `--username` was **omitted** and login still succeeded, so
it is optional when the CLI can resolve the user interactively:

```bash
vcf context create sup --endpoint 10.1.8.132 --insecure-skip-tls-verify --auth-type basic
vcf context use sup:<vsphere-namespace>
kubectl get nodes          # worked immediately — no `vcf cluster kubeconfig get` needed
```

**`vcf context use` alone produces a working kubectl context.** The third command,
`vcf cluster kubeconfig get`, is therefore **not** on the path to Supervisor-namespace access —
it is how you obtain the **guest/workload** cluster's kubeconfig, which is what
`VKS_AUTH_METHOD=vcf` ultimately wants. Do not read it as a prerequisite for `kubectl` to work.

The legacy `kubectl vsphere login --server
<ip> --vsphere-username <u> --tanzu-kubernetes-cluster-name <c> --tanzu-kubernetes-cluster-namespace
<ns> [--insecure-skip-tls-verify]` form (the `vsphere` method) is the **vSphere-with-Tanzu 7/8
fallback** — present only where the `vcf` CLI is unavailable.

If the workload cluster needs the kubectl-vsphere plugin, fetch it from the Supervisor:

```bash
wget --no-check-certificate https://<SUPERVISOR_HOST>/wcp/plugin/linux-amd64/vsphere-plugin.zip
```

> **Validation status — partial (2026-07-22).**
>
> **Verified on a real VCF 9.1 Supervisor**, in exactly this minimal form:
> `vcf context create <name> --endpoint <bare-host> --insecure-skip-tls-verify --auth-type basic`,
> then `vcf context use <ctx>:<ns>`, then a working `kubectl`. Positional context name, no scheme on
> the endpoint, `--username` **omitted and still successful**. Independently corroborated by a second
> automation of the same lab — see [lab-automation](lab-automation.md) §3.2.
>
> The script additionally sends `--username` and `--type kubernetes` (an explicit principal beats an
> interactively-resolved one, and Broadcom documents `--username` as applying to the `kubernetes`
> context type). **That pairing was not in the verified run** — if the CLI rejects either flag, the
> minimal form above is known-good and `30-vks-login.sh` prints it as the fallback.
>
> **Still unverified:** `vcf cluster kubeconfig get <cluster> --export-file …` (the guest-cluster
> half) has not been run here; and it is **not established** whether the `kubectl` reached above
> was the Supervisor or a guest cluster, nor under which account — which matters, because
> Scenario 2 is about what a *tenant* may do and listing nodes usually is not. Settle both with
> `kubectl config current-context` on the next lab visit; tracked in
> [the lab validation plan](lab-validation-plan.md).
>
> The login remains interactive for the password — no non-interactive/stdin mechanism is confirmed
> for `vcf context create`, so `30-vks-login.sh` still carries its `TODO(verify on a VKS
> cluster)`. A password never reaches argv either way. `kubeconfig` (bring the lab's exported
> kubeconfig) remains the simplest working method.

## Acquiring the licensed VCF CLI archives

`make install-vcf-clis` installs three Broadcom-**licensed**, operator-supplied artifacts a
real-lab jump box needs (the local KinD flow needs none of them). Download them yourself with your
entitlement, drop them **all in one folder**, and point `VCF_CLI_SRC_DIR` at it — the
air-gap-correct path (carry the folder in; no download client, token, or network at install time).
The installer auto-selects the archive matching this box's OS/arch and the pinned versions, so a
mixed folder (every arch, plus the multi-arch `…-Binaries-…` bundle) resolves deterministically.
Scenario 2's [Step 3b](scenario-2.md) has the full "just dump everything in there" walkthrough.

**What to download** — the version pins live in `.env.example`:

| Artifact | Filename shape | Arches |
|---|---|---|
| VCF Consumption CLI (`vcf`) | `VCF-Consumption-CLI-Linux_<ARCH>-<VCF_CLI_VERSION>.tar.gz`, or the multi-arch `…-Binaries-…` bundle | linux amd64 + arm64 |
| Plugin bundle | `VCF-Consumption-CLI-PluginBundle-Linux_<ARCH>-<VCF_PLUGINS_VERSION>.tar.gz` | linux amd64 + arm64 (Linux only) |
| VCF-flavored argocd | `argocd-cli-linux-<arch>-<ARGOCD_VCF_VERSION>.gz` | **amd64 only** (see below) |

**Where — the portal (9.1+ is entitled).** The 9.1 artifacts come from the
**[Broadcom support portal](https://support.broadcom.com)** (with your entitlement) or the
**Supervisor** (`https://<SUPERVISOR_HOST>/wcp/vcf-cli/…`). Broadcom's public artifactory
(`packages.broadcom.com/artifactory/vcf-distro/vcf-cli/`) serves the CLI only through **≤ 9.0.x**
and does not carry our pinned 9.1 (measured 2026-07-23), so there is no no-auth public download for
9.1 — use the portal, and keep `.env.example`'s pins in sync with what you place in the folder.

**arm64 jump box — the VCF-flavored argocd is amd64-only.** Broadcom ships `argocd-vcf` for
`linux-amd64` (and `darwin-amd64`), not `linux-arm64`, so on an arm64 box `make install-vcf-clis`
dies at `install-argocd-vcf` with "no argocd artifact for linux/arm64". Use the **upstream argocd
that `make deps` already installs** (arm64-native; Broadcom itself pairs a **3.x** argocd CLI with
the 2.14.x server, so a 3.x CLI is the intended generation — this specific upstream build against
the lab server is not lab-verified), and install the rest with `make install-vcf-cli` +
`make install-vcf-plugins` instead of `all`. The `vcf` CLI and plugin bundle are available for both
linux amd64 and arm64.

---

[← back to the README](../README.md)
