# Decision — sneakernet: bundle format, carried toolchain, and the builder split

Mechanism and measurements behind [`docs/sneakernet.md`](../sneakernet.md). The runbook states the choice
and the command; this states *why*, so it does not have to.

## 1. The bundle is an UNCOMPRESSED `.tar`

The producer used to pick the compressor from its own capabilities (`if have zstd; then --zstd; else
--gzip`). That is a **contract imposed on a machine that gets no vote** and, air-gapped, cannot install a
decoder.

Measured:

| | |
|---|---|
| compression gain | **~1%** — the payload is already-compressed OCI layer blobs (gzip reached 99.2% of raw on the real cache), for *minutes* of single-threaded CPU on ~12 GB |
| `zstd` on a bare `photon:5.0` / `ubuntu:26.04` | **absent** |
| Photon's `tar` | **toybox** — has **no `--zstd` option at all**, so installing the zstd binary does not help (`tar: Unknown option 'zstd'`) |
| plain `.tar` on toybox / busybox / GNU / bsdtar | **works** — no compressor binary, no tar flag |

So the answer was not "pick a universal compressor" but **stop compressing**: it deletes the failure class
instead of relocating it. `BUNDLE_COMPRESSOR=gzip|zstd` remain opt-in; `20-bundle-load.sh` probes tar's
**real capability** (a one-byte archive) rather than a binary's presence, and its error names the fix on
the *other* box — the only action the far side can take.

The capability probe itself must be portable: the first draft used `tar -T -` (GNU-only), so it reported
gzip unsupported on toybox — which supports it. A probe that uses a non-portable idiom to test for
portability is self-defeating.

## 2. The bundle carries `crane`

The air-gap box cannot download the mirror engine. The bundle used to carry **nothing** while CLAUDE.md
claimed otherwise, and the e2e hid it by letting its "air-gap" box run `make deps` over the internet — a
green test proving the opposite of its name.

`command -v crane` is **not** sufficient to stage it: under mise's *shims* activation it resolves to a
symlink to the **94 MB, dynamically-linked `mise` binary**, and `install` dereferences it — so we would
carry mise, renamed `crane`, discoverable only on a box that cannot fix it. `11-bundle.sh` therefore
`readlink`s it, **runs the copy**, and requires a **static ELF**.

The bundle also stamps the arch (crane's, and the `MIRROR_ARCH` the images were pulled for);
`20-bundle-load.sh` refuses a mismatch rather than letting it surface as `Exec format error` after the
carry. The checksum is **mandatory on both sides** — an archive crossing removable media is the one place
a silent bit-flip is plausible, and it used to be silently optional at both ends.

## 3. The builder is BUILT outside and PUSHED inside

`make builder-image` needed **both networks at once**: Maven Central (to bake `~/.m2`) *and* Harbor (its
base ref, a pre-build login probe, and the push). On a sneakernet split **neither box can run it** — box A
has no Harbor, box B has no Maven Central — so the mirror completed and the offline Java build could not
be produced. The e2e could not see it: its air-gap box only did `bundle-load → mirror-push → mirror-verify`,
and the builder was built by the dual-homed *host*.

Split:

| | box | network | how |
|---|---|---|---|
| `make builder-build` | A | Maven Central only | base pinned **by digest from `bundle/images.lock`** — byte-identical to the mirrored base, so no Harbor is needed and builder↔mirror alignment holds *by construction* (`images.txt` pins maven by tag, so a naive public pull could legitimately differ) |
| `make builder-push` | B | Harbor only | `crane push bundle/builders/<app>` — the destination ref is computed from `HARBOR_URL` **on box B**, which is the only box that knows it |
| `make builder-image` | dual-homed | both | unchanged: build + push |

The builder is **not** added to `images/images.txt`. It has no upstream to pull or track, `mirror-pull`
would try to pull a ref that does not exist, `_mirror_repo_path` would double the project path, and —
decisively — `mirror_prune_cache` `rm -rf`s any cache dir not in the collected keep-set, so the next
`mirror-pull` would **delete it**. It lives in `bundle/builders/`, carried for free by the existing tar.

## 4. What is still NOT air-gap-clean

Stated, not hidden:

- **`install-all` cannot run on box B** — it begins with `mirror` (internet), and its `preflight`
  (`03-check-tools.sh`) requires the full toolchain. The runbook lists the steps to run instead.
- **`INGRESS_CONTROLLER=istio` (the default) cannot install air-gapped** — `46-install-istio.sh` does
  `helm repo add istio-release.storage.googleapis.com`. **`traefik` is fully air-gap-clean today** (image
  from Harbor, manifests in-repo) and `istio-existing` needs no install at all. Vendoring the Istio chart
  into `bundle/charts/` is the fix; it is not done.
- **`install-harbor` / `install-argocd` fetch from the internet** (goharbor helm repo; the ArgoCD
  install.yaml from raw.githubusercontent). These are the **KinD stand-in** paths — on a real lab both are
  Supervisor Services — but an operator running them on box B would fail.
- **Repo↔bundle drift is unguarded**: box B reads *its* copy of `images/images.txt`, while the cache dirs
  were named from box A's. A Renovate bump between cutting and carrying yields `cache missing for <image>`
  with nothing pointing at the cause. Stamping the repo commit into the bundle would close it.
