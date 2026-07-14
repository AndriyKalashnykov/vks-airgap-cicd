# Sneakernet — two boxes, one carried bundle

**Use this when no single box reaches both the internet and Harbor.** One box pulls the images, you carry
them across on media, the other box pushes them in.

If one box reaches **both**, stop: run `make mirror`. Sneakernet is not a mode, it is just which commands
you run on which box.

| | box A — **outside** | box B — **inside** |
|---|---|---|
| reaches | the internet | Harbor + the cluster |
| does | `mirror-pull` → `builder-build` → `bundle` | `bundle-load` → `mirror-push` → `builder-push` → `mirror-verify` → the install |

*(Mechanism and the measurements behind these choices: [`docs/decisions/sneakernet.md`](decisions/sneakernet.md).)*

---

## Step 0 — set up box A (outside)

**For:** it needs the full toolchain, and it is the only box that can download one.

```bash
git clone <this repo> && cd vks-airgap-cicd
make deps
```

**Expect:** `make deps` completes. This is the ordinary jump-box bootstrap — nothing sneakernet-specific.

## Step 0b — set up box B (inside)

**For:** `make deps` **cannot run here** — it downloads mise, crane and kubectl from the internet. Box B is
provisioned by hand, once, before anything is carried.

**Copy the repo onto it** (tar/scp/the same stick — **not** `git clone`; there is no internet).

**It must already have** — these are on any Linux base, and none of them can be fetched later:

| for | needs |
|---|---|
| the **mirror** (`bundle-load` → `mirror-push` → `builder-push` → `mirror-verify`) | `bash` (4+), `tar`, `curl`, `sha256sum`, `make`, `awk`/`sed`/`grep`. **`crane` is carried in the bundle** — do not install it. No container engine, no `jq`, no `kubectl`. |
| the **install** (`platform`, `gitops`, `install-ingress`, `verify`) | additionally `kubectl`, `helm`, `jq`, `yq`, `envsubst`, `git`, `openssl` |

**Expect:** `make preflight` on box B lists no missing tools. Run it **before** you carry 11 GB across a
room — it is the cheapest failure available.

**Its `.env` must carry:** `HARBOR_URL`, `HARBOR_USERNAME`, `HARBOR_PASSWORD`, and either `HARBOR_CA_FILE`
(carry the CA) or `HARBOR_INSECURE=1`.

---

## Step 1 — pull and build, on box A

```bash
make mirror-pull      # every image in images/images.txt → ./bundle
make builder-build    # the offline Maven builder → ./bundle/builders/ (needs Maven Central; NOT Harbor)
make bundle           # → vks-airgap-cicd-bundle-<date>.tar  + its .sha256
```

**Expect:** `staged crane into the bundle (…, static)`, then `bundle ready: …tar (11G)` and a `.sha256`
beside it.

`mirror-pull` **resumes** — re-run it after a dropped connection and it skips what already completed.

> **`builder-build` is not optional for the Java app.** Its Maven dependencies are baked into an image on
> the internet side, because the in-cluster Kaniko build cannot reach Maven Central. Box B cannot build it
> (no internet) and box A cannot push it (no Harbor) — so it is **carried in the bundle** and pushed on
> the far side by `make builder-push`.

## Step 2 — carry

Copy **the tarball, its `.sha256`, and the repo**. All three, on the same media.

> **A FAT32 stick cannot hold a file over 4 GiB, and this bundle is ~11 GB.** Use exFAT/ext4/XFS/NTFS, or
> `split -b 3G` and `cat` it back. `make bundle` warns you.

## Step 3 — push, on box B

```bash
make bundle-load BUNDLE_TARBALL=/media/…/vks-airgap-cicd-bundle-<date>.tar
make mirror-push      # every mirrored image → Harbor
make builder-push     # the carried Maven builder → Harbor
make mirror-verify    # PROVE it: crane fetches every blob back out of Harbor
```

**Expect:** `verifying checksum` → `installed the carried crane -> ~/.local/bin/crane` →
`✓ mirror-verify: N images intact in Harbor`.

> **Do not skip `mirror-verify`.** An OCI push asks the registry `HEAD <blob>` and **skips the upload if
> the registry says it already has it** — so a registry that lies turns your whole mirror into a no-op that
> **exits 0**. That has happened here. Verify by *fetching*, never by the pusher's exit code.

## Step 4 — install, on box B

```bash
make platform gitops                       # Gitea + Tekton, then the ArgoCD Application
make install-ingress INGRESS_CONTROLLER=traefik   # or istio-existing — see below
make verify
```

**Do NOT run `make install-all` on box B** — it starts with `mirror`, which needs the internet, and its
`preflight` requires the full toolchain. Run the steps above instead.

**Ingress:** the default (`istio`) **installs from an internet Helm repo and cannot run here.** On box B use:

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
(`SNEAKERNET_OS = photon ubuntu`): the host plays box A, and **only the tarball** crosses into a fresh
jump-box container playing box B. Each OS leg gets a **fresh, empty Harbor**, so its push is a real push
and not a `HEAD`-skip no-op. Box B asserts `./bundle` is empty and that `crane` is **not** already
installed before loading — so the images and the toolchain can only have come from the carried bundle.
