# Decision — is docker supportable as an alternative to podman?

**Status:** ACCEPTED & MEASURED · 2026-07-14
**Verdict (scoped, and the scope is the point):**
**On a developer/CI host — yes, docker works, and rootless docker matches podman exactly.**
**On a JUMP BOX — no, not today: `make deps` does not install docker at all.**

> ## The finding that actually answers the question
>
> **`scripts/00-install-prereqs.sh` installs podman only. There is no `pkg_install docker` anywhere, on
> either OS** — and the rootless deps it does install (`uidmap`, `passt`, `slirp4netns`) are **gated on
> `have podman`**. This is not an oversight: `scripts/test-container-engine.sh:83-85` asserts it as an
> invariant — *"a jump box that ran `make deps` has podman and NOT docker … Docker belongs ONLY to the
> KinD stand-in and the local test harnesses"* — and there is a **gate enforcing it**.
>
> So docker on a jump box is **not "untested"; it is UNSUPPORTED BY OUR BOOTSTRAP.** An operator who
> follows the README onto a fresh Photon/Ubuntu box and sets `CONTAINER_ENGINE=docker` has no docker to
> run.
>
> **Decision (owner, 2026-07-14): make it supported — option (B).** The real work is an **engine-aware
> bootstrap** (`00-install-prereqs.sh` learns to install docker + its rootless extras per OS), plus a
> `make` target that CHECKS the docker prerequisites and one that INSTALLS them, plus a test that asserts
> it. The jump-box engine matrix then becomes the **test of that bootstrap change** — which is the only
> thing it can prove that the host legs below did not. **Tracked as its own task; not done here.**
>
> Everything below is therefore a **host** result. It proves the *mechanism*. It does not prove the
> *jump box*, and it must not be quoted as if it did.

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

### Two facts that are routinely gotten wrong

1. **`certs.d` MERGES with the host system store — it does not replace it.** (moby `loadTLSConfig` seeds
   `RootCAs` from `x509.SystemCertPool()` and *appends*.) So **a missing `ca.crt` does NOT mean docker will
   fail**: an operator who ran `update-ca-certificates` already has a working docker. Never gate on the
   *file's existence*; gate on a real TLS handshake. (A guard that inferred failure from the missing file
   was shipped here once and **retracted** — it would have hard-blocked working operators.)
2. **A `certs.d` drop-in needs NO daemon restart** — it is read **per request**. *Measured:* the `pull`
   succeeded immediately after the CA was installed. (The **system store** is the opposite: Go caches the
   pool once per process, so *that* route does need a restart. This asymmetry is why we use `certs.d`.)

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
   SAN is rejected **even with a trusted CA**, and Go 1.17 removed the escape hatch — for that failure,
   installing the CA cannot possibly help.)

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
