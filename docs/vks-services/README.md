# VKS services — Harbor, ArgoCD, Istio

What VMware/Broadcom actually ships on **VCF 9 / vSphere Kubernetes Service (VKS)**, how it is
installed and configured, how *this repo* consumes it, and what is still unverified.

These pages are a **living record**, not a one-off write-up. Each one carries a
**Provenance & confidence** table so a reader can tell a primary-sourced fact from an inference —
and so the next person (or a lab run) can upgrade a row from *inferred* to *lab-verified* instead
of re-deriving it.

| Service | Where it runs | Who installs it | Page |
|---|---|---|---|
| **Harbor** | **Supervisor** (a vSphere Namespace) | the platform team, as a **Supervisor Service** | [`harbor.md`](harbor.md) |
| **ArgoCD** | **Supervisor** (a vSphere Namespace) | the platform team, as a **Supervisor Service** | [`argocd.md`](argocd.md) |
| **Istio** | the **GUEST / workload cluster** | the cluster owner, as a **VKS Standard Package** | [`istio.md`](istio.md) |

That split is the single most load-bearing fact on this page, and it drives everything else:

- Harbor and ArgoCD live **beside** your workload cluster, not in it. So you *discover* their
  endpoints and *request* credentials — and ArgoCD must be told how to reach your guest cluster
  (see the cross-cluster registration in [`argocd.md`](argocd.md)).
- Istio lives **in** your guest cluster, but you very likely did **not** install it (it is a
  package the cluster owner adds). So you *discover* the mesh and *attach* routes to it — there
  are no "Istio credentials" to fetch (see [`istio.md`](istio.md)).

## Topology

![VKS topology — Supervisor services vs the guest cluster](../diagrams/out/vks-topology.png)

## How this repo consumes each one

| | Real VKS lab | This repo's KinD stand-in |
|---|---|---|
| **Harbor** | already installed → **discover** the endpoint, **request** a robot account (`make harbor-robot` if you are a project admin) | we install it (`make install-harbor`), self-signed TLS on an LB IP |
| **ArgoCD** | already installed **on the Supervisor** → **discover** it, and **register** the guest cluster as a destination (`make argocd-register-guest`, admin-only) | we install it (`make install-argocd`) in the same cluster; registration is skipped |
| **Istio** | already installed **in the guest cluster** → **attach** (`INGRESS_CONTROLLER=istio-existing`), install nothing | we helm-install it (`INGRESS_CONTROLLER=istio`) to have something to attach to |

Everything the repo *does* install (Gitea, Tekton, the app) is ours in both worlds.

## Reading the provenance tables

| Grade | Means |
|---|---|
| **lab-verified** | observed on a real VCF/VKS 9.1 lab |
| **KinD-verified** | proven empirically here, on the local stand-in — generic-Kubernetes/Istio mechanics that hold regardless of who installed the thing |
| **9.1-doc** | stated by a Broadcom page that genuinely served 9.1 content |
| **9.0-doc (inferred for 9.1)** | from Broadcom docs — but the **9.1 URLs 301-redirect to the 9.0 tree** (verified live, 2026-07-12), so it is 9.0 content read as 9.1 |
| **community** | a blog/field source, dated |
| **UNVERIFIED** | plausible, no source. Never act on it without checking. |

> **The redirect matters.** Broadcom's 9.1 documentation URLs return `301 Moved Permanently` to the
> 9.0 tree. Anything below tagged *9.0-doc (inferred for 9.1)* is therefore an **inference about
> 9.1** — most likely correct, but version strings especially should be re-checked on a real lab.
> A prior session's claim here was first asserted, then wrongly retracted as "unverified", then
> confirmed against primary sources. Grade the row; don't trust the memory.

## Updating these pages

When a lab run confirms (or refutes) something:

1. Change the row's **confidence grade**, and cite what you observed (a command + its output).
2. If a fact turns out to be **wrong**, correct it *in place* and leave a one-line note saying so —
   a silently-fixed fact is how the same wrong belief gets re-derived next time.
3. If it changes what the repo should *do*, open the change alongside the doc edit, and say which
   `make` target now covers it.
