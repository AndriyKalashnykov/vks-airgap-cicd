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
    --insecure-skip-tls-verify --auth-type basic     # bare host, NO scheme; password prompted
vcf context use <VKS_CONTEXT_NAME>:<VKS_NAMESPACE>   # note the <ctx>:<ns> COLON form
vcf cluster kubeconfig get <VKS_CLUSTER_NAME> --export-file <KUBECONFIG>   # GUEST cluster only — see below
```

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
> **Verified on a real VCF 9.1 Supervisor:** `vcf context create <name> --endpoint <bare-host>
> --insecure-skip-tls-verify --auth-type basic`, then `vcf context use <ctx>:<ns>`, then a
> working `kubectl`. Positional context name, no scheme on the endpoint, `--username` optional.
> Independently corroborated by a second automation of the same lab — see
> [lab-automation](lab-automation.md) §3.2.
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

---

[← back to the README](../README.md)
