# Decision — is docker supportable as an alternative to podman?

**Status:** ACCEPTED & MEASURED · updated 2026-07-14 (option B implemented)
**Verdict:** **Yes — docker is now SUPPORTED on a jump box, on both OSes, and it is opt-in.**
**podman remains the DEFAULT, and it remains the only engine that is sudo-free on every box.**

> ## What was actually wrong (and it was not "docker is untested")
>
> `scripts/00-install-prereqs.sh` installed **podman only** — there was no `pkg_install docker` anywhere,
> on either OS — and `scripts/test-container-engine.sh` asserted that as an **invariant**. So docker on a
> jump box was **not "untested"; it was UNSUPPORTED BY OUR OWN BOOTSTRAP.** An operator who followed the
> README onto a fresh Photon/Ubuntu box and set `CONTAINER_ENGINE=docker` had **no docker to run**. Every
> "docker works" measurement we had was taken on the developer's laptop — i.e. **scoped to the wrong
> machine**.
>
> **Now (option B, implemented):** the bootstrap is engine-aware. `CONTAINER_ENGINE=docker` installs
> docker + its rootless prerequisites; `CONTAINER_ENGINE` unset installs podman and **zero** docker
> packages. The package list lives in `engine_packages()` — a **pure function** — precisely so the gate can
> **execute** it and assert the list in both directions, offline. That matters: the old gate scanned for
> docker *invocations* at a command position and was **structurally blind to a docker dependency**
> (`pkg_install docker` matches none of its patterns — proven), so an engine-aware bootstrap would have
> started putting a docker daemon on **every** jump box under a **green** gate.
>
> **The invariant survives, and is now enforceable:** docker is never *required*. It appears only because
> the operator asked for it by name.

## THE FACT THAT CHANGES THE UBUNTU STORY (ran-it, 2026-07-14)

Ubuntu's `docker.io` is version **29.1.3 on both 24.04 and 26.04** — but only **26.04's deb actually ships
the rootless helper**:

| | `docker.io` | `dockerd-rootless.sh` in the deb? | rootless docker from distro repos? |
|---|---|---|---|
| **Photon 5** | 29.5.3 (`docker` + `docker-rootless` + `rootlesskit`) | **yes — `/usr/bin`, ON PATH** | ✅ **Photon is the EASY OS** |
| **Ubuntu 26.04** | 29.1.3 | **yes** — but hidden in `/usr/share/docker.io/contrib/` (OFF PATH; `make deps` symlinks it) | ✅ |
| **Ubuntu 24.04** | 29.1.3 | **NO — zero rootless files** | ❌ rootful only |

Two consequences, and both are stated in the operator's face rather than discovered on the lab:

- **Photon is the easier OS for rootless docker**, which inverts the usual assumption.
- **On Ubuntu 24.04 there is no distro path to rootless docker.** Getting it means adding
  `download.docker.com` + a GPG key (`docker-ce-rootless-extras`) — on a real corporate jump box that is a
  **proxy-allowlist / security-review item an admin may simply refuse**. **We do not add a third-party apt
  repo to someone else's jump box.** So there, docker is **rootful-only = a sudo per registry**, and
  `make deps` / `make engine-check` say exactly that. `make bootstrap-engine-test` asserts we disclose it
  (and asserts we did **not** add the repo).

---

## The verdict, in one table

Every row below was **measured**, on a real KinD Harbor (`172.18.0.3`, self-signed TLS, `SAN=IP`), by
`make engine-trust-check` / `make engine-trust-check-rootless`. Each leg does the engine's **entire**
registry-TLS surface: `login → pull from Harbor → build → push → pull back`.

| Engine | Works? | How the CA is trusted | **Needs root?** |
|---|---|---|---|
| **podman** (the default) | ✅ | `--cert-dir` — passed **per command** | **No — ever** |
| **docker, rootless** | ✅ | `~/.config/docker/certs.d/<host>/ca.crt` | **No** |
| **docker, rootful** | ✅ | `/etc/docker/certs.d/<host>/ca.crt` | **YES — one `sudo` per Harbor** |

**So the real question was never "does docker work" — it is "which docker".** Rootless docker matches
podman's ergonomics exactly. Rootful docker works, but bills you a password prompt for every new registry.

---

## Why the answer differs per engine (the mechanism, not folklore)

- **podman is daemonless.** There is no privileged process to teach, so TLS trust is handed to the
  *command* (`--cert-dir`). It never touches `/etc`, so it is **sudo-free by construction** — not by
  configuration. This is the reason it is the default.
- **docker is a daemon**, and the daemon reads its CA from a path decided by **how the daemon runs**:
  - **rootful** → `/etc/docker/certs.d/<host>/ca.crt` — **root-owned**. The `docker` **group grants access
    to the SOCKET, not write access to `/etc`** — so this `sudo` cannot be engineered away. It can only be
    measured and disclosed.
  - **rootless** → `$HOME/.config/docker/certs.d/<host>/ca.crt` — your own home directory. No root.

### Three facts that are routinely gotten wrong

1. **`certs.d` MERGES with the host system store — it does not replace it.** (moby `loadTLSConfig` seeds
   `RootCAs` from `x509.SystemCertPool()` and *appends*.) So **a missing `ca.crt` does NOT mean docker will
   fail**: an operator who ran `update-ca-certificates` already has a working docker. Never gate on the
   *file's existence*; gate on a real TLS handshake. (A guard that inferred failure from the missing file
   was shipped here once and **retracted** — it would have hard-blocked working operators.)
2. **A `certs.d` drop-in needs NO daemon restart** — it is read **per request**. *Measured:* the `pull`
   succeeded immediately after the CA was installed. (The **system store** is the opposite: Go caches the
   pool once per process — `crypto/x509` `sync.Once`, upstream `moby/moby#39869` — so *that* route does
   need a `systemctl restart docker`. This asymmetry is why we use `certs.d`.)
3. **`DOCKER_CERT_PATH` is NOT a registry CA — and podman's identically-named setting IS one.** This is the
   single most-confused knob in the ecosystem, because the same name means opposite things:
   - **docker's `DOCKER_CERT_PATH`** configures **CLI↔daemon socket TLS**. It has nothing to do with
     trusting a registry. Neither does `DOCKER_CONFIG` / `docker --config`, which only relocates
     `config.json` (auth). Reaching for either to fix a registry-trust error is a dead end.
   - **podman/skopeo's `DockerCertPath`** genuinely **is** a registry cert dir (the `--cert-dir` we use).

   Two smaller traps in the same directory: **any `*.crt` in `certs.d/<host>/` is loaded as a CA** (not
   just a file literally named `ca.crt`), while a **`*.cert` is a CLIENT cert and errors without its
   matching `*.key`. And no CA drop-in ever enables plain HTTP** — that needs `insecure-registries` in
   `daemon.json` plus a daemon reload, which is why `HARBOR_INSECURE=1` is podman-only.

---

## What this cost us to find out (the preconditions, measured)

- **Rootless docker needs packages that Ubuntu's apt silently drops.** `uidmap` (`newuidmap`),
  `slirp4netns`/`rootlesskit`, `fuse-overlayfs`, plus an `/etc/subuid` entry. Ubuntu omits several of
  these under `--no-install-recommends` — a trap this repo has already hit once.
- **Rootless docker in a container needs `--security-opt apparmor=rootlesskit`** — and I got this wrong
  first time, which is worth recording because the wrong version is so plausible.

  `docker:dind-rootless` fails to start on an AppArmor-restricting host (Ubuntu 23.10+, which sets
  `kernel.apparmor_restrict_unprivileged_userns=1`):

  ```text
  [rootlesskit:parent] error: failed to start the child: fork/exec /proc/self/exe: operation not permitted
  ```

  **The mechanism:** Ubuntu grants the `userns` permission through an AppArmor profile attached **by host
  path** (`/etc/apparmor.d/rootlesskit` → `/usr/bin/rootlesskit`). Inside a container that binary is a
  *different file*, the profile does not attach, the process is **`unconfined`** — and `unconfined` is
  **exactly what `restrict=1` denies**. Which is why `--security-opt apparmor=unconfined` makes it
  **worse**, not better, and why `--privileged` does not help either.

  **`--security-opt apparmor=rootlesskit` attaches the profile BY NAME and it works** (verified:
  `AppArmorProfile=rootlesskit`, `Daemon has completed initialization`, `API listen on
  /run/user/1000/docker.sock`, `id -u` inside = 1000). The profile carries `flags=(unconfined)` **plus
  `userns,`** — it grants zero capabilities, changes no uid, and therefore **cannot fake rootlessness**.

  I first wrote *"dind-rootless is impossible on a modern Ubuntu host"* into this document. **That was
  false** — I had simply never tried the one flag that matched the mechanism. Guard the flag on
  `[ -f /etc/apparmor.d/rootlesskit ]`: on a host without the profile, `docker run` errors outright.

  We still measured rootless docker **natively on the host**, which is the *stronger* test regardless: a
  real uid, a real rootlesskit, no outer privilege to borrow.

---

## What we had to FIX to make this true

Docker was not merely untested — it was **unwired**:

1. **`scripts/lib/engine.sh` (new).** The CA wiring was **podman-only** (`15-build-push-builder.sh` gated
   `--cert-dir` on `[ "$ENGINE" = podman ]`), so with `CONTAINER_ENGINE=docker` **we installed nothing**.
   Docker now gets its CA at the correct `certs.d` path for its mode, and **every escalation is counted**.
2. **`scripts/05-kind-up.sh` — the hardcoded socket.** `cloud-provider-kind` was mounted
   `-v /var/run/docker.sock:...`. **Rootless docker has no such file** (its socket is
   `$XDG_RUNTIME_DIR/docker.sock`), so docker would have created an **empty directory** there, CPK would
   have found no daemon, and **no LoadBalancer would ever have got an IP** — surfacing as *"Harbor
   LoadBalancer did not get an external IP"*, an error pointing nowhere near a socket path. The socket is
   now **derived** from `DOCKER_HOST`/`XDG_RUNTIME_DIR`.
3. **The login probe now branches on the REAL error.** It used to discard stderr and branch on the *engine
   name*, so a wrong password, an unwired LoadBalancer, a dead daemon and a **missing IP SAN** all printed
   *"install the CA"* — advice that is wrong in four of five cases. (Since Go 1.15 a leaf with no matching
   SAN is rejected **even with a trusted CA**, and Go 1.17 removed the `GODEBUG=x509ignoreCN=0` escape
   hatch — for that failure, installing the CA cannot possibly help. For a registry addressed by **IP**
   the SAN must be an **IP SAN**, not a DNS SAN: Harbor's own published `v3.ext` sample shows only `DNS.n`
   entries, which is why this recurs — `goharbor/harbor#19994`.)

---

## What this does NOT claim

Read this before quoting the verdict:

- **Nothing about a real lab's Harbor.** Ours is a bare **IP** with `SAN=IP` and **admin** credentials. A
  lab is an **FQDN, possibly with a port** (→ `certs.d/<host>:<port>/`, a naming rule this repo has
  **never exercised**), a **corporate CA that may already be in the system store** (in which case docker
  needs no `certs.d` at all), and a **scoped robot** rather than admin. **We proved the mechanism, not the
  lab.**
- **`HARBOR_INSECURE=1` is PODMAN-ONLY**, and it tests **no trust at all** (it skips TLS). Docker would
  need an `insecure-registries` entry in `daemon.json` plus a daemon reload (root). It is excluded from
  the matrix, not counted in it.
- **`make e2e-kind` requires DOCKER regardless of `CONTAINER_ENGINE`** — kind's node containers are docker
  containers. The honest inverse of *"podman is the default"* is: **a podman-only box cannot run the local
  KinD e2e.** This is the thing most likely to bite a reader of the engine docs.
- **Not proven on the jump-box images.** Rootless docker was measured on the *host*. Photon **does**
  package docker (29.5.3, updates repo), so a Photon/Ubuntu leg is *possible* — it is simply not run.
- **The authz gap.** `login` proves TLS trust **and authentication** — **not authorization**. A **pull-only
  Harbor robot logs in perfectly and 403s at the push**, twenty minutes later, at the end of a build.
  Nothing in this repo currently mints a pull-only robot, so that failure's RED cannot yet be produced —
  and **a gate whose RED has never been demonstrated is not a gate.**

---

## Recommendation

**Keep podman as the default.** It is sudo-free by construction, needs no daemon, and honours
`HARBOR_INSECURE=1`.

**Docker is fully supported**, with this guidance:

- **Rootless docker: use it freely.** Identical ergonomics to podman — no root, ever.
- **Rootful docker: expect one `sudo` per registry.** And note the KinD LB IP **changes on every
  `kind-up`**, so that is a prompt **per cluster**, plus an accumulating litter of dead
  `certs.d/172.18.0.x/` directories.

Verify your own box at any time:

```bash
make engine-trust-check                      # your default engine
make engine-trust-check CONTAINER_ENGINE=docker
make engine-trust-check-rootless             # the rootless-docker leg
```

Each prints its **precondition row** — engine, mode, CA method, and whether it needed `sudo`. **That row
is the claim.** Anything broader is a lie.

---

## Appendix — how the harness itself lied, and what fixed it

The first real run of `engine-trust-check` printed **`sudo=NO`** for the rootful leg **while the operator
was typing a sudo password**. Cause:

```bash
CA_METHOD="$(engine_trust_ca …)"     # command substitution == SUBSHELL
```

The escalation counter was incremented **inside the subshell** and died with it. A global cannot cross a
subshell; a **file** can — so the counter is now a file, and it is RED-proven (`1`, was `0`).

This matters beyond the bug: **the `sudo` column IS the deliverable of this document.** A harness that
reports "sudo-free" for a path that just prompted for a password is worse than no harness — and it is
exactly the class of failure (*something reported success without doing the work*) that this whole
codebase now assumes by default.
