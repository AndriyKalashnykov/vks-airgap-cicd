# Common bootstrap — get the repo, get a shell that can run it

Both runbooks start here. `scenario-1.md` and `scenario-2.md` each **include** this file, so you
follow it in place; there is nothing to look up in the other scenario.

Everything after this runs **from the repo root**. Nothing works from another directory.

A stock box has neither `git` nor `make`, and `make deps` needs `curl`.

**Ubuntu / Debian:**

```bash
sudo apt-get update && sudo apt-get install -y --no-install-recommends git make curl ca-certificates
```

**Photon OS 5** — `openssh openssh-socket` are both required. Without them this box loses SSH
during the install and you cannot reconnect.

```bash
sudo tdnf install -y git make curl curl-libs ca-certificates openssh openssh-socket
```

Already root? Drop the `sudo`.

**macOS** — needs [Homebrew](https://brew.sh); no `sudo`. The scripts are GNU-flavoured, so this
installs the GNU tools too:

```bash
brew install git make curl bash coreutils gnu-sed findutils grep gawk gnu-tar flock gettext openssl@3 python
```

On macOS type **`gmake`** wherever this runbook says `make`, up to and including the two lines
under **"Put the toolchain on YOUR shell's PATH"** (`gmake shell-init`, then
`. "$(gmake -s shell-rc-file)"`). After the second one, `make` in this shell is GNU make. Apple's
`/usr/bin/make` is 3.81 and the Makefile refuses it.

```bash
git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
```

Already have the repo? Skip that one command — but still run the next block, which is what puts you
**in** the repo.

```bash
cd vks-airgap-cicd
pwd                            # sanity check: should end in /vks-airgap-cicd
make env-init                  # creates ./.env from the template .env.example
```

**Expect:** `./.env` exists. It is the one file you edit for the rest of this runbook; each step
below lists the keys it needs before the commands that read them.
