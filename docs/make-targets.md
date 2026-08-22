# Make targets

<br>

`make help` prints the full list, grouped, straight from the Makefile — **that is the source of
truth, and it is the exhaustive one.**

⚠️ **This page is a CURATED SUBSET, not a complete catalogue.** It used to call itself "the
catalogue", which implied a completeness it did not have: a 2026-08-21 content audit measured **48
of 125** operator-facing targets absent (a naive count that also includes the `check-*` gates puts it
at 130 of 224 — either way, large). It is curated on purpose — the value here is the *context* around
the targets an operator actually reaches for, not a second copy of `make help` that drifts every time
a target lands.

**So: if a target is not here, that means nothing about whether it exists.** Run `make help`.

**A gate (`make check-doc-target-coverage`) fails CI if an operator-invocable target appears in no
document at all** — note the floor it measures: *somewhere*, not *here*. It cannot see this page's
coverage, which is why the gap grew unnoticed.

| Group | Target | Purpose |
|-------|--------|---------|
| Prereqs | `deps` | Install the jump-box toolchain (mise tools incl. **kind**, crane, kubectl, helm + tkn/argocd) |
| Env | `env-init` / `env-populate` / `env-check` / `env-validate` | `.env` lifecycle: copy from `.env.example` → GENERATE the secrets we can + DISCOVER cluster values (and print what only you can provide) → presence gate → validity gate (format + KUBECONFIG/Harbor auth) |
| Env | `creds-show` (alias `creds`) / `argocd-password` | Print the access URLs + logins / the ArgoCD admin password. `creds-show` **and `argocd-password` both mask passwords when stdout is not a terminal** (a redirect, a pipe, a CI capture or the walk harness must not silently harvest them); `SHOW_SECRETS=1 make creds-show` forces the reveal. `creds-show` reads `argocd-password` through a command substitution and passes `--raw` for that one internal call, which is the only path that still emits plaintext off a terminal |
| Prereqs | `install-vcf-clis` | Install the Broadcom VCF/VKS lab CLIs (argocd-vcf + vcf + plugins), sudo-free — lab-only, licensed artifacts from a folder (`VCF_CLI_SRC_DIR`) |
| Mirror | `mirror` / `mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | Pull images → Harbor (dual-homed), or the sneakernet phases |
| Mirror | `builder-image` | Build + push the deps-baked offline Maven builder image |
| Install | `vks-login` / `platform` / `gitops` / `install-all` | Auth to VKS; install Gitea+Tekton; wire ArgoCD; or all of it |
| Install | `fetch-harbor-ca` | Fetch a self-signed lab Harbor's CA cert → `HARBOR_CA_FILE` (VKS-lab convenience) |
| KinD e2e | `e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify). Runs with **`.env` ignored** (`E2E_SKIP_DOTENV`) so a local run reproduces a **fresh** box — see below |
| KinD e2e | `e2e-kind-both` | Both SSL modes: secure self-signed TLS, then insecure plain-HTTP |
| KinD e2e | `e2e-kind-istio-existing` | Attach mode: a "platform team" installs Istio under foreign naming; we attach and install nothing (+ both RED tests, both route APIs) |
| KinD e2e | `e2e-kind-cross-cluster` | Two KinD clusters: a HUB ArgoCD registers a GUEST cluster and syncs an app into it (the Supervisor→guest topology (as on VKS)) |
| KinD e2e | `e2e-sneakernet` | Two-BOX sneakernet: bundle on the host, carry **only** the tarball into a FRESH jump-box container, reconstruct → push → integrity-verify |
| KinD e2e | `kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps (`install-istio` / `attach-istio` / `install-traefik` pick the controller) |
| Preflight | `check-tools` / `psa-check` | Required-vs-optional CLIs + versions / would a real VKS cluster (PSA `restricted` by default) even ADMIT our pods? |
| Istio | `istio-preflight` / `attach-istio` / `e2e-kind-istio-existing` | Read-only mesh discovery + what to ask the mesh admin for / attach to an Istio we did not install / its KinD regression test |
| Verify | `verify` | End-to-end smoke test on a LIVE cluster |
| Verify | `verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| Verify | `jumpbox` / `jumpbox-both` | Validate the README bootstrap on a real jump-box container — `JUMPBOX_OS=photon`\|`ubuntu`, or both (needs the KinD cluster up) |
| App dev | `app-test` / `app-build` / `app-run` | Spring Boot app tests / jar / local run |
| Gates | `ci` / `static-check` / `docs-lint` | Composite offline gate; code gate; docs gate |
| Gates | `lint` / `validate` / `test-scripts` | Shell/YAML/Dockerfile lint · manifest schema validation · offline script-logic unit tests |
| Gates | `check-image-alignment` / `check-toolchain-alignment` / `check-java-alignment` | A version that lives in >1 file must agree everywhere (image tags ↔ `images/images.txt`; kubectl pin; Java major) |
| Gates | `check-env` / `check-env-coverage` / `check-env-clobber` / `check-how-provenance` | `.env.example` is the source of truth: it exists · every var the scripts read is documented · **no uncommented value silently defeats a dynamic fallback or a per-run override** · every `# how:` command is runnable or provenance-tagged |
| Gates | `check-readme-scenarios` / `check-tools` / `psa-check` | Every scenario answers every decision in its own section · required-vs-optional CLIs · would a real VKS cluster (PSA `restricted`) admit our pods? |
| Security | `sec` / `secrets` / `trivy-fs` / `trivy-config` | gitleaks + trivy fs (app deps) / config (manifests) |
| Sneakernet | `builder-build` / `builder-push` | The offline Maven builder, **split** for two boxes: build it on the internet box (into the bundle), push the carried tarball into Harbor from the air-gapped one. `builder-image` = both, for a dual-homed box. See [Sneakernet](sneakernet.md) |
| Sneakernet | `e2e-sneakernet-both` | The sneakernet OS matrix explicitly (`e2e-sneakernet` already runs Photon **and** Ubuntu by default) |
| Prereqs | `deps-mise` / `deps-prereqs` | The two halves of `make deps` — the mise toolchain, and the OS packages + engine. Re-run one when only that half failed |
| Prereqs | `install-vcf-cli` / `install-vcf-plugins` / `install-argocd-vcf` | The three pieces of `make install-vcf-clis`, when you only need one |
| Env | `state-stamp` | Stamp the state overlay with the cluster it belongs to (`make state-show` says whose it is) |
| Env | `check-ports` | Fail early if the local app-dev port is already taken, instead of a confusing bind error |
| Platform | `install-gitea` / `install-tekton` / `seed-gitea` / `configure-tekton` | The steps inside `make platform` — re-run one after a partial failure |
| GitOps | `configure-argocd` | The step inside `make gitops` that writes the `Application` |
| KinD e2e | `e2e-kind-tenant` | The **tenant** path: an ArgoCD `Application` created with ZERO Kubernetes RBAC in the ArgoCD namespace, through `argocd-server` — the mechanism [Scenario 2](scenario-2.md) depends on |
| Jump box | `jumpbox-image` / `bootstrap-test` | Build one jump-box test image · run the REAL bootstrap on **bare** Photon/Ubuntu images (nothing pre-installed) |
| Security | `secrets-scan` / `prose-secrets` | The working-tree secret scan · credentials written in **prose** in `*.md` (which pattern scanners miss) |
| Housekeeping | `clean` | Remove build artifacts (the image cache and the bundle stay — they are expensive) |
| Diagrams | `diagrams` / `diagrams-check` / `vendor-diagrams` | Render PNGs / byte-diff drift gate / re-vendor C4-PlantUML |

## Real-lab and verification helpers

Added 2026-08-21 — these were absent while being among the most reached-for on a real lab.

| Group | Target | Purpose |
|-------|--------|---------|
| Mirror | `harbor-auth-check` | Fails in **seconds** on a Harbor credential that cannot push, instead of after the ~20-minute pull. `mirror` **depends** on it; `mirror-pull` deliberately does **not** — the sneakernet internet box runs that one with no Harbor at all. `install-all` was already gated this way via `preflight`. Read-only. Returns 0 when there is nothing to probe, so it is a fast-fail for the configured-but-stale case, not a completeness gate |
| Mirror | `mirror-verify` | Blob-integrity gate: `crane validate` fetches and digests every layer, and cross-checks Harbor against `images.lock`. Read-only, safe to interrupt. `mirror` **depends** on it — a push you have not verified is not a mirror |
| Preflight | `argocd-preflight` | ArgoCD version + topology + write-mechanism + AppProject + Gitea reachability, two-cluster aware; non-zero on a blocking finding |
| Trust | `vks-trust-probe` | LIVE, read-only: does this guest cluster trust our Harbor, and by what mechanism? Compares the CA fingerprint and forces a real pull. States in its own output what a green does **not** prove |
| Harbor | `harbor-robot` | Mint the least-privilege robot the pipeline runs as (needs Harbor project-admin; a tenant requests it instead) |
| ArgoCD | `argocd-register-guest` | Register the guest cluster as an ArgoCD destination — the Supervisor-hosted ArgoCD cannot deploy into it otherwise |
| Verify | `verify-gateway-image` | LIVE: every running Istio container image came from OUR Harbor. Catches a silently-ignored `global.hub` override, which helm accepts with rc=0 |
| Verify | `verify-ingress-rendered` | Asserts the ingress routes were **rendered** where app backends deliberately do not exist — a 503 proves a route matched, a 404 would mean it was never rendered |

---

## Testing a target CLEANLY — the dev host is not a clean box

A long-lived dev host carries state a fresh operator does not have: an installed toolchain, a `.env`, and
— the one that bites — a **stale kubeconfig** left by an old cluster. A target that "works here" can still
fail for everyone else, and a target that *fails* here (dialling a dead `127.0.0.1:<port>`) can be
perfectly fine. So the clean test for anything an operator runs on a jump box is a **fresh jump-box
container**, not this machine.

### `make labbox` — the same clean-box check, against the REAL lab

`make jumpbox` points at the KinD stand-in and **cannot reach a real VKS lab**. `make labbox` is the
same harness with `JUMPBOX_TARGET=lab`: a clean **Photon** container on **host networking**, using the
Supervisor kubeconfig `make vks-login` wrote. Run it whenever scenario-1's Step 0/1 changes — a walk on
the machine that wrote the doc is green partly for reasons the doc never mentions (a warm `mise`, a
populated `~/.config/vcf`, a `.env` from a previous lab).

```bash
make vks-login            # writes ./secrets/supervisor.kubeconfig, which labbox mounts
make labbox
```

## `make walkbox` — the WHOLE runbook, on a throwaway VM

`jumpbox`/`labbox` validate the **bootstrap** in a container. They cannot run the whole runbook:
`install-all` → `builder-image` does a `podman build`, and a container has no subuid range to map
uids into (measured: `insufficient UIDs or GIDs available in user namespace`, `/etc/subuid` empty).
On a VM that same step prints `builder images pushed + verified: 1`.

```bash
make walkbox            # build a throwaway VM, run docs/scenario-1.md on it end to end (~40 min)
make walkbox-down       # destroy it
```

- **It refuses any domain it did not create.** Every destructive verb is gated on a
  `vks-walkbox-managed` marker in the domain XML — `virsh destroy` is a forced power-cut and this
  libvirt connection also hosts the lab's nested ESXi.
- **Its lab address is DERIVED from the lab's `input.yaml` ranges**, never hardcoded. A prototype
  that hardcoded one sat inside the live `workload_node` pool, one address ahead of the allocator.
- `WALKBOX_SUDO` selects the sudo posture. The default is faster and re-hides the very class the
  VM exists to expose; the other setting makes sudo ask, which is what a real jump box does.
- **Nothing lands in `$HOME`** — images live in `/var/tmp/walkbox-<user>`, so no ACL and no pool.

Three design points, each measured — see `CLAUDE.md` for the evidence:

- **`--network host`, never `--add-host`.** Pinned host entries rot on every reinstall, and a hosts
  entry is precisely what `make show-dns-records` says is "not enough".
- **Photon only.** No post-bootstrap scenario-1 script branches on OS; `make jumpbox-matrix` already
  covers the OS × engine matrix where those differences actually live.
- **It cannot see `$HOME`-persisted state.** The `vcf` CLI's store survives a lab rebuild and can block
  `vcf context create` against a dead endpoint; a throwaway container has a fresh `$HOME` every run.

```bash
# 1. Build a bare jump-box image for the OS you care about.
make jumpbox-image JUMPBOX_OS=photon          # or JUMPBOX_OS=ubuntu

# 2. BARE leg — no cluster, no kubeconfig. This is the "version-curious / first-run" operator.
docker run --rm -v "$(git rev-parse --show-toplevel)":/src:ro <image> \
  bash -c 'cd /src && make deps && make <target>'

# 3. JOINED leg — against a live KinD cluster. Use the --internal kubeconfig: the host-facing one
#    points at 127.0.0.1:<random>, which resolves to nothing inside the container.
kind get kubeconfig --internal > /tmp/kubeconfig.internal
docker run --rm --network kind -v "$(git rev-parse --show-toplevel)":/src:ro \
  -v /tmp/kubeconfig.internal:/tmp/kc:ro -e KUBECONFIG=/tmp/kc <image> \
  bash -c 'cd /src && make deps && make <target>'
```

Run **both** legs: the bare one proves the target degrades honestly with nothing configured; the joined one
proves the positive path. `make bootstrap-test` does this for the bootstrap itself on literally bare images.

---

[← back to the README](../README.md)
