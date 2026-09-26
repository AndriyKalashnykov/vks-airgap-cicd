# Tested platforms, in detail

The summary table is in the [README](../README.md#tested-platforms). This page keeps the detail behind it.

**Lab targets.** The lab-backed, non-KinD targets were run against a live VKS lab (guest cluster
on Kubernetes v1.36.2), serially, one box at a time, at commit `0440796`. The macOS
row reached the lab **through a test harness**, [`scripts/mac-lab-tunnel.sh`](../scripts/mac-lab-tunnel.sh):
per-IP SSH reverse forwards, with the lab's names in the Mac's `/etc/hosts`. So it does not test real DNS,
the routing between a jump box and the lab, or the source address the lab sees.

| Class | Linux | macOS (via tunnel harness) |
|-------|-------|----------------------------|
| Read-only (28: `preflight`, `env-validate`, `creds-show`, `mirror-verify`, `verify-ingress`, …) | 28/28 PASS | 28/28 PASS |
| Idempotent installers, in scenario order (34, ending with `verify` and `install-all`) | 32/34 PASS; 2 refused as designed on this lab (below) | 30/34 PASS with `BUILD_EMULATE=1`; the same 2 refused as on Linux, plus 2 Linux-only (below) |
| Not run by design on a shared lab (24) | — | — |
| KinD, sneakernet and Linux test harnesses (28) | not in this table | out of scope on macOS |

- **After the macOS run, Linux re-verified the lab** (the Mac's builds replace the same Harbor tags the
  guest pulls): `verify` passed end to end for every app, from git push to the live page.
- **How the counts reconcile:** `creds` is an alias of `creds-show`; `creds-renew` ran once before the
  run (it spends one SSO attempt); `mirror-pull` and `mirror-push` are exercised inside `mirror`.
- **`mirror-verify` coverage depends on the local bundle:** in the read-only pass the Mac had never run
  `mirror-pull`, so it checked 17 images and skipped the provenance check (it says so). After `mirror`,
  both boxes verified the same 31 images intact.
- **Refused as designed:** `fetch-harbor-ca`, because this lab's Harbor serves only its leaf certificate
  and there is no CA on the wire to fetch. `fetch-argocd-ca`, because `ARGOCD_SERVER` is an IP and the
  certificate carries only names ([B486](../BACKLOG.md)).
- **Linux-only for now (macOS):** `trust-harbor` and `engine-trust-check` refuse on macOS, because the
  engine trusts registries inside its VM, which this repo does not configure. Pushes to Harbor use
  `crane` and do not need it ([B735](../BACKLOG.md)). On the Mac the images were built `linux/amd64`
  under emulation (Rosetta), and `install-all` took about 25 minutes.
- **Not run by design:** destructive or whole-vCenter targets (`wcp-restart`, `vcenter-repair`,
  `uninstall-*`, `vks-cluster-delete`, `mirror-verify-red-test`, …); targets that install a Supervisor
  Service or mint a new credential (`install-harbor-service`, `install-argocd-service`, `harbor-robot`,
  `harbor-admin-password`, `harbor-ca-from-cluster`); `env-init` / `env-populate`, which rewrite `.env`; and targets that switch
  the lab's ingress (`install-traefik`, `attach-istio`, `verify-ingress-both`).

**What this does and does not cover.** `static-check` is the full offline gate: lint, manifest
validation, security scans and every script unit test. It needs no lab. CI runs it on a schedule or a manual dispatch; a
pull request runs only a faster subset — see [CI/CD](ci-cd.md). The lab-backed targets are in
the **Lab targets** table above.

- Tools pinned in [`.mise.toml`](../.mise.toml) (kubectl, crane, helm, linters…) are not listed; the
  commit in each row pins them. On macOS, `crane` is built from source with Go ≥ 1.27 so it can trust
  Harbor's CA ([B735](../BACKLOG.md)).
- **macOS:** use `gmake` (Homebrew GNU make). Apple's `/usr/bin/make` 3.81 is refused. Building the
  images on Apple silicon needs `BUILD_EMULATE=1` and Rosetta for the podman machine — see
  [Scenario 1](scenario-1.md). The `gmake` bootstrap is in
  [Common bootstrap](common-bootstrap.md).
- **KinD on macOS: in progress** ([B740](../BACKLOG.md)). The sneakernet flow stays out of scope there;
  `make bundle` refuses to run on macOS.
