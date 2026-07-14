# Sneakernet — when the jump box cannot reach Harbor

**For:** a jump box that has **internet but no route to the Harbor / cluster network**. You pull the images
on the outside, carry them across the gap on physical media, and push them in from a machine on the inside.

> **You probably do not need this.** If your jump box reaches **both** the internet and Harbor (*dual-homed*),
> run `make mirror` and stop reading. There is no mode switch — sneakernet is simply *which commands you run*.

| your jump box | what you run |
|---|---|
| reaches the internet **and** Harbor (**dual-homed**) | `make mirror` — pulls and pushes in one go |
| reaches the internet **only** (**sneakernet**) | the two-box flow below |

---

## What you carry, and what the inside box must already have

**Carry three things** (all three, or the trip is wasted):

| | what | size |
|---|---|---|
| **1.** the bundle | `vks-airgap-cicd-bundle-<date>.tar` — the OCI image cache, the install manifests, **and `crane`** | ~11 GB |
| **2.** its checksum | the `.sha256` written beside it. **`bundle-load` refuses to run without it** — this archive crossed removable media, which is precisely where a silent bit-flip happens | a few bytes |
| **3.** this git repo | the scripts and manifests the inside box runs | a few MB |

> ⚠️ **A FAT32 stick cannot hold a file larger than 4 GiB, and this bundle is ~11 GB.** That is the single
> likeliest way a real carry fails, and it fails at *copy* time. Use exFAT, ext4, XFS or NTFS — or
> `split -b 3G` it and `cat` it back on the far side. `make bundle` warns you.

**The bundle carries `crane`, and only `crane`.** The inside box cannot download it — that is the point of an
air gap — and it is the mirror engine. `make bundle` refuses to build a bundle without it (and refuses to
stage a `mise` shim masquerading as it); `make bundle-load` installs it to `~/.local/bin` and **runs it** to
prove it works on that box.

**But the mirror is not the whole install.** Be honest about what the inside box needs *pre-provisioned*:

| step on the inside box | needs |
|---|---|
| `bundle-load` → `mirror-push` → `mirror-verify` | `tar`, `curl`, `sha256sum` (on every Linux) **+ `crane` (carried in the bundle)** |
| `make platform` / `gitops` / `install-ingress` (the **full** install) | `kubectl`, `helm`, `jq`, `envsubst` — **NOT in the bundle**. Pre-provision them, or run the install from a box that has them. `46-install-istio.sh` also fetches its chart from `istio-release.storage.googleapis.com`, which an air-gapped box cannot reach — use `INGRESS_CONTROLLER=istio-existing` (attach to a mesh the platform team installed) or vendor the chart. |

---

## Why the bundle is a plain `.tar` and not compressed

Because **compression buys ~1% and can strand you on the far side.**

- The payload is **already-compressed OCI layer blobs**. Measured on the real cache: gzip reaches **99.2%
  of raw** — while costing *minutes* of single-threaded CPU on an 11 GB bundle.
- **The compressor is a cross-box contract, and the outside box picks it.** The inside box has to *decode*
  it, and it cannot install anything to do so. **Photon's `tar` is toybox, which has no `--zstd` option at
  all** — installing the `zstd` binary does not help — and `zstd` ships on neither a bare `photon:5.0` nor a
  bare `ubuntu:26.04`.

A plain `.tar` needs **no compressor binary and no tar flag**, so it works on toybox, busybox, GNU tar and
bsdtar alike. It deletes the failure class rather than relocating it.

`BUNDLE_COMPRESSOR=gzip` is a safe opt-in (verified working on every far-side OS we test). `zstd` is not —
use it only if you know that box's tar supports it. Either way `bundle-load` **probes tar's real capability**
and refuses with an actionable message instead of dying inside `tar`.

---

## The flow

### On the OUTSIDE box (internet, no Harbor)

```bash
make deps            # toolchain (this box has internet)
make mirror-pull     # pull every image in images/images.txt into ./bundle
make bundle          # tar it up — stages crane + the arch stamp into the bundle
```

**Expect:** `staged crane into the bundle (12M, <version>, x86_64, static)`, then
`bundle ready: ./vks-airgap-cicd-bundle-<date>.tar (<size>)` and a `.sha256` beside it.

**Interrupted?** Re-run `make mirror-pull` — it **resumes**. Every digest-pinned image already fully pulled
is skipped (a `.mirror-ok` marker written only on a *complete* pull), so a dropped connection or a CDN reset
costs you only the images that had not finished.

**Architecture matters.** The bundle stamps the arch it was cut on (the carried `crane`'s, and the
`MIRROR_ARCH` the images were pulled for — **default `amd64`**). If the inside box or the target cluster is
`arm64`, set `MIRROR_ARCH=arm64` **before** `mirror-pull`; otherwise `bundle-load` refuses the bundle rather
than letting you discover it as `exec format error` inside Kubernetes, three steps and one air gap later.

### Carry it

Copy the tarball, its `.sha256`, and the git repo. `make bundle-load` verifies the checksum for you and
**will not proceed without it**.

### On the INSIDE box (Harbor, no internet)

```bash
make bundle-load BUNDLE_TARBALL=/media/…/vks-airgap-cicd-bundle-<date>.tar
make mirror-push     # push every image into Harbor
make mirror-verify   # PROVE it: crane fetches every blob back out of Harbor
```

**Expect:** `verifying checksum` → `installed the carried crane -> ~/.local/bin/crane (<version>)` →
`✓ mirror-verify: N images intact in Harbor`.

> **`mirror-verify` is not a formality.** A push you have not fetched back is not a mirror: an OCI push asks
> the registry `HEAD <blob>` and **skips the upload if the registry says it already has it**. A registry that
> answers "yes" for a blob it cannot actually serve turns your entire mirror into a no-op that **exits 0**.
> That has happened in this repo. `mirror-verify` is the only thing that can see it.

---

## `MIRROR_FORCE_PULL=1` — when you actually want it

The pull is **cached**: a digest-pinned image already in `./bundle` is reused instead of re-downloaded. That
is safe by construction — a digest is content-addressable, so a cached blob at that digest *is* the right blob
— and **tag-based refs are always re-pulled**, so a moving tag can never be served stale.

So you rarely need to force. Use `MIRROR_FORCE_PULL=1 make mirror-pull` when:

- you **do not trust the cache** — someone edited `./bundle` by hand, a disk filled mid-write, the box was
  restored from a snapshot;
- you are cutting a bundle for a **hand-off you cannot re-do**, and want every byte fetched fresh before a
  one-way trip;
- you are **debugging a mirror problem** and want the cache eliminated as a variable.

Not for "just in case": it re-downloads ~11 GB for no benefit.

Related knobs (all commented in `.env.example`): `MIRROR_RETRIES` (per-image retries on CDN resets, default
5), `MIRROR_ARCH` (default `amd64` — see above), `MIRROR_NO_PRUNE=1`, `BUNDLE_COMPRESSOR`.

---

## How this is tested

`make e2e-sneakernet` runs the **real two-box flow** on KinD — and it runs it **on both far-side OSes by
default** (`SNEAKERNET_OS = photon ubuntu`), because the far side is exactly where they diverge:

- the host plays the outside box (`mirror-pull` → `bundle`);
- **only the tarball** is carried into a **fresh jump-box container** playing the inside box
  (`bundle-load` → `mirror-push` → `mirror-verify`);
- **each OS leg gets a fresh, EMPTY Harbor** — otherwise the second leg would push into a registry that
  already has every blob, `crane` would `HEAD`-skip all 36 uploads, and the leg would be a green no-op.

The fidelity is *enforced*, not asserted: the inside box asserts `./bundle` is **empty** before loading (so
the images can only have come from the tarball), asserts `crane` is **not already installed** (so the
toolchain must have been carried), and ends in `mirror-verify`, which fetches every blob back out of Harbor.

A Photon-only matrix is what let a real bug ship: the host emitted a `.tar.zst` that an **Ubuntu** air-gap box
cannot open, and the Photon leg passed because that image happens to have GNU tar. A matrix that only ever
runs one leg is decoration.
