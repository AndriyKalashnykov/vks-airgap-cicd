# Prerequisites — the manual path

<br>

> **This page provisions the INTERNET-side (dual-homed) jump box** — every step here needs the
> internet (`git clone`, `curl mise.run`, `make deps`). A **fully air-gapped box cannot run
> `make deps`**: provision its toolchain by hand from your internal package mirror and deliver the
> rest via the carried bundle — see [Sneakernet](sneakernet.md).

Everything else (mise, `make deps`, the toolchain) runs from a clone of this repo, so first
get **git + SSH + make** working on a fresh box. Do this once, manually.

**Ubuntu:**

```bash
sudo apt-get update
sudo apt-get install -y git openssh-client ca-certificates curl make
```

**Photon OS:**

```bash
# Refresh the package cache FIRST. A stale tdnf cache is the #1 cause of a broken TLS stack
# on a long-lived Photon box: `tdnf install git` UPGRADES openssl-libs, and a partial or
# mismatched upgrade then breaks HTTPS/SSH — git clone fails with an SSL error. Cleaning the
# cache and installing a consistent TLS set up front avoids it.
sudo tdnf clean all && sudo tdnf makecache
sudo tdnf install -y ca-certificates openssl curl git openssh-clients make tar
```

**If `git clone` (or `make deps`) still fails with an SSL / TLS / certificate error on Photon
OS**, that is the stale-cache openssl mismatch — refresh and reinstall the TLS stack, then
retry the clone:

```bash
sudo tdnf clean all && sudo tdnf makecache
sudo tdnf reinstall -y ca-certificates openssl openssl-libs curl curl-libs
```

**Configure your git identity** (both OSes; used for local commits — the in-cluster pipeline
commits under its own identity):

```bash
git config --global user.name  "VKS Developer"
git config --global user.email "vks.developer@sample.corp.com"
```

**Create an SSH key and add it to GitHub** (for `git@github.com:` clones):

```bash
ssh-keygen -t ed25519 -C "vks.developer@sample.corp.com" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub     # add this line at GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com         # expect: "Hi <user>! You've successfully authenticated…"
```

**Clone the repo, then install mise** and let the Makefile pull the rest of the toolchain:

```bash
# SSH (needs the key above added to your GitHub account)…
git clone git@github.com:AndriyKalashnykov/vks-airgap-cicd.git
# …or HTTPS (this repo is public — no key needed) — use ONE of these two:
# git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
cd vks-airgap-cicd

curl -fsSL https://mise.run | sh           # installs mise to ~/.local/bin (it PRINTS an
                                           # activation hint; it does NOT edit your shell profile)
export PATH="$HOME/.local/bin:$PATH"       # put the mise BINARY on PATH for THIS shell
make deps                                  # installs the full jump-box toolchain (mise tools +
                                           # scripts/00-install-prereqs.sh); it also sets up rootless
                                           # podman for the builder-image build (its rootless
                                           # prerequisites for your OS + podman's search-registries —
                                           # `make deps` installs them; `make engine-check` reports what
                                           # your box needs and the sudo cost)
eval "$(mise activate bash)"               # NOW put the mise-MANAGED tools (kubectl, helm, yq,
                                           # crane, …) on PATH — only takes effect AFTER `make deps`
                                           # installed them.  zsh: eval "$(mise activate zsh)"
echo 'eval "$(mise activate bash)"' >> ~/.bashrc   # …and for every future shell
                                           # (zsh: append `eval "$(mise activate zsh)"` to ~/.zshrc)
make check-tools                           # verify every REQUIRED CLI is now on PATH
                                           #
                                           # Prefer docker? `make deps CONTAINER_ENGINE=docker` installs
                                           # docker (and NOTHING of podman) + its rootless prerequisites
                                           # WHERE the distro provides them — on Ubuntu 24.04 there is no
                                           # distro rootless helper, so docker there is rootful-only (one
                                           # sudo per registry). `make engine-check` (read-only) tells you
                                           # which box you are on. Run `make trust-harbor` LATER — once
                                           # Harbor exists and HARBOR_URL/HARBOR_PASSWORD are in .env.
```

---

[← back to the README](../README.md)
