# Prerequisites — the manual path

<br>

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

curl https://mise.run | sh                 # installs mise to ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"       # put mise on PATH for THIS shell (the installer also
                                           # adds `mise activate` to your profile for new shells)
make deps                                  # installs the full jump-box toolchain (mise tools +
                                           # scripts/00-install-prereqs.sh); it also sets up rootless
                                           # podman for the builder-image build — crun + registries on
                                           # Photon, uidmap + slirp4netns on Ubuntu
```

---

[← back to the README](../README.md)
