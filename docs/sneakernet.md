# Sneakernet — two boxes, one carried bundle

**Use this when no single box reaches both the internet and Harbor.** The **staging box** pulls the
images, you carry them across on media, the **jump box** pushes them in.

If one box reaches **both**, stop: run `make mirror`. Sneakernet is not a mode, it is just which commands
you run on which box.

<p align="center"><a href="diagrams/out/sneakernet.png"><img src="diagrams/out/sneakernet.png" alt="Sneakernet — the staging box reaches the internet but not Harbor; the jump box reaches Harbor and the cluster but not the internet; the bundle (images + the toolchain) is carried between them on physical media — click to enlarge" width="960"></a></p>

| | **staging box** | **jump box** |
|---|---|---|
| reaches the internet | ✅ | ❌ |
| reaches Harbor + the cluster | ❌ | ✅ |
| does | `mirror-pull` → `builder-build` → `bundle` | `bundle-load` → `mirror-push` → `builder-push` → `mirror-verify` → the install |
| needs a `.env` | no — it never talks to Harbor | yes — `HARBOR_*` + `KUBECONFIG` |

*(Mechanism and the measurements behind these choices: [`docs/decisions/sneakernet.md`](decisions/sneakernet.md).)*

---

## Step 0 — set up the staging box

**For:** it needs the full toolchain, and it is the only box that can download one.

```bash
git clone <this repo> && cd vks-airgap-cicd
make deps
```

**Expect:** `make deps` completes. This is the ordinary jump-box bootstrap — nothing sneakernet-specific.

## Step 0b — set up the jump box

**For:** `make deps` **cannot run here** — it downloads. The jump box is provisioned by hand, once, before
anything is carried.

**Copy the repo onto it** (tar/scp/the same stick — **not** `git clone`; there is no internet).

**What it needs, and where each thing comes from:**

| | comes from | what |
|---|---|---|
| **the bundle carries it** — do NOT install these | `make bundle-load` puts them on `~/.local/bin` | `crane`, `kubectl`, `helm`, `jq`, `yq` (static binaries) |
| **you must provision it** — the bundle cannot carry it | your lab's **internal package mirror** | `bash` (4+), `tar`, `curl`, `sha256sum`, `make`, `git`, `openssl`, `envsubst` (gettext), `awk` (gawk), `sed`, `grep` |

The second row is OS packages, not static binaries, so they cannot ride in the tarball. **Do not assume
your base has them** — measured on the bare images:

| | already there | **missing — install these** |
|---|---|---|
| `photon:5.0` | bash, tar, gzip, find, curl, sha256sum, sed, grep | **make, gawk, git, openssl, gettext** (`envsubst`) |
| `ubuntu:26.04` | bash, tar, gzip, find, awk, sed, grep, sha256sum | **make, git, openssl, gettext-base, curl** |

> **`awk` is the one that bites.** Photon does not ship it, and it is not optional: `lib/apps.sh` reads
> `apps/registry.tsv` with it (**every** per-app loop) and `mirror-verify` does its digest lookup with it.
> A box without it passes every other check and then dies at `mirror-verify`.

No container engine is needed on the jump box: `crane` pushes images, and the Maven builder is carried
pre-built.

**Expect:** `make check-tools` on the jump box lists no missing tools. Run it **before** you carry 12 GB
across a room — it is the cheapest failure available.

**Its `.env` must carry:** `HARBOR_URL`, `HARBOR_USERNAME`, `HARBOR_PASSWORD`, and either `HARBOR_CA_FILE`
(carry the CA) or `HARBOR_INSECURE=1`.

> **If the jump box already has its own `kubectl`/`helm`, `bundle-load` KEEPS it** and says so, rather
> than shadowing it with the carried one — your lab's kubectl is probably pinned to your cluster's
> version, and silently overriding it is a version-skew bug we would have handed you. Force ours with
> `BUNDLE_TOOLS_FORCE=1` if the box's copy is broken or the wrong arch.

---

## Step 1 — pull and build, on the staging box

```bash
make mirror-pull      # every image in images/images.txt → ./bundle
make builder-build    # the offline Maven builder → ./bundle/builders/ (needs Maven Central; NOT Harbor)
make bundle           # → vks-airgap-cicd-bundle-<date>.tar  + its .sha256
```

**Expect:** `staged crane / kubectl / helm / jq / yq` (each `static`), then `toolchain staged (…)`,
`bundle ready: …tar (12G)`, and a `.sha256` beside it.

`mirror-pull` **resumes** — re-run it after a dropped connection and it skips what already completed.

> **`builder-build` is not optional for the Java app.** Its Maven dependencies are baked into an image on
> the internet side, because the in-cluster Kaniko build cannot reach Maven Central. Box B cannot build it
> (no internet) and the staging box cannot push it (no Harbor) — so it is **carried in the bundle** and
> pushed on the far side by `make builder-push`.

## Step 2 — carry

Copy **the tarball, its `.sha256`, and the repo**. All three, on the same media.

> **A FAT32 stick cannot hold a file over 4 GiB, and this bundle is ~11 GB.** Use exFAT/ext4/XFS/NTFS, or
> `split -b 3G` and `cat` it back. `make bundle` warns you.

## Step 3 — push, on the jump box

```bash
make bundle-load BUNDLE_TARBALL=/media/…/vks-airgap-cicd-bundle-<date>.tar
make mirror-push      # every mirrored image → Harbor
make builder-push     # the carried Maven builder → Harbor
make mirror-verify    # PROVE it: crane fetches every blob back out of Harbor
```

**Expect:** `verifying checksum` → `installed crane -> ~/.local/bin/crane` (and the same for any of
`kubectl`/`helm`/`jq`/`yq` this box did not already have) → `carried toolchain: N installed, M already
present and kept` → `✓ mirror-verify: N images intact in Harbor`.

> **Do not skip `mirror-verify`.** An OCI push asks the registry `HEAD <blob>` and **skips the upload if
> the registry says it already has it** — so a registry that lies turns your whole mirror into a no-op that
> **exits 0**. That has happened here. Verify by *fetching*, never by the pusher's exit code.

## Step 4 — install, on the jump box

```bash
make platform gitops                       # Gitea + Tekton, then the ArgoCD Application
make install-ingress INGRESS_CONTROLLER=traefik   # or istio-existing — see below
make verify
```

**Do NOT run `make install-all` on the jump box** — it starts with `mirror`, which needs the internet.
Run the steps above instead.

**Ingress:** the default (`istio`) **installs from an internet Helm repo and cannot run here.** On the
jump box use:

| | works air-gapped? |
|---|---|
| `INGRESS_CONTROLLER=traefik` | ✅ — image comes from Harbor, manifests are in the repo |
| `INGRESS_CONTROLLER=istio-existing` | ✅ — attaches to a mesh the platform team already installed |
| `INGRESS_CONTROLLER=istio` (default) | ❌ — `helm repo add istio-release.storage.googleapis.com` |

---

## `MIRROR_FORCE_PULL=1` — when

The pull is cached, and that is safe by construction: digest-pinned images are content-addressed, and
tag-based refs are always re-pulled. Force it only when you **distrust the cache** (hand-edited, a disk
filled mid-write, a restored snapshot), when you are cutting a bundle for a **hand-off you cannot re-do**,
or when you are **debugging the mirror** and want the cache out of the picture. Otherwise it re-downloads
11 GB for nothing.

## How this is tested

`make e2e-sneakernet` runs the real two-box flow on KinD, on **both** far-side OSes by default
(`SNEAKERNET_OS = photon ubuntu`): the host plays the staging box, and **only the tarball** crosses into a
fresh container playing the jump box. Each OS leg gets a **fresh, empty Harbor**, so its push is a real
push and not a `HEAD`-skip no-op. The jump box asserts `./bundle` is empty and that `crane` is **not**
already installed before loading — so the images can only have come from the carried bundle.

`make airgap-toolchain-test` proves the **toolchain** half, which `e2e-sneakernet` cannot: its jump-box
image runs `make deps` at build time, so it already has `kubectl`/`helm`/`jq`/`yq` and could never notice
if the bundle failed to carry them. The toolchain test uses a **genuinely bare** box
(`jumpbox/Dockerfile.airgap` — OS packages only) with **`--network none`**, asserts all five tools are
**absent first** (a pre-provisioned box proves nothing), and then that each one is installed **and
executes**, on both Photon and Ubuntu.
