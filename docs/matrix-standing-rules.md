# Walkthrough-matrix standing rules

The rules the six-row certifying matrix runs under. They existed only in chat and in backlog row
B176; both times they were asked for they were delivered as a message that scrolls away.

**What the matrix is:** six rows walking `docs/scenario-1.md` and `docs/scenario-2.md` end to end as
an end user would, on throwaway Photon and Ubuntu VMs, against a freshly cut lab.

| row | OS | scenario | cell |
|---|---|---|---|
| 1 | ubuntu | scenario-1 | NOTHING exists |
| 2 | photon | scenario-1 | EVERYTHING exists |
| 3 | photon | scenario-1 | NOTHING exists |
| 4 | ubuntu | scenario-1 | EVERYTHING exists |
| 5 | photon | scenario-2 | (cut A) |
| 6 | ubuntu | scenario-2 | (cut B) |

Scenario-2 has **two** rows, not four: its premise is that Harbor and ArgoCD already exist, so there
is no NOTHING cell to walk. `2x2x2` is a category error — see B43 and B108.

## A. Scope

1. Cut a **NEW** lab; run **all six** rows.
2. All six green **from the first go** — a fresh matrix over the **final** tree, passing on its
   **first** pass. Every fix resets that clock.
3. Report times in **EST/EDT**.
4. **Arm it with this, and confirm it armed.** `VCF_CLI_SRC_DIR` (the licensed VCF CLI archives) is
   **DERIVED from `WALK_REPO`'s `.env`** by `walk-matrix.sh` when unset — wired 2026-08-23, because
   requiring it by hand made a mis-armed run indistinguishable from a launched one: the refusal is
   **two log lines**, which reads as "running" to anyone who does not check the length.

   ```sh
   # `make -C` and not `cd`: the target lives in nested-vsphere-lab, NOT in this repo, and naming
   # the repo in the command is what stops it reading as a target you could run here.
   WALK_REPO=$HOME/projects/vks-airgap-cicd \
   WALK_OUT_ROOT=$HOME/walk-evidence \
   make -C ~/projects/nested-vsphere-lab walk-matrix > /tmp/matrix.log 2>&1 &
   sleep 90 && wc -l /tmp/matrix.log     # hundreds = armed. single digits = refused —
                                         # read the LAST line; _die emits 3, not 1.
   ```

   `WALK_OUT_ROOT` is still explicit and load-bearing: its default is `/tmp/walk`, and a reboot
   destroys the certification the matrix exists to produce (lab-repo B454). It is **not** derived,
   because unlike the CLI path it is not a fact about the repo.

## B. Reading the documents

1. Read **both** scenario documents **whole**, as an end user.
2. Navigate only by what the documents say — not by repo knowledge the reader does not have.
3. Verify **every** fact, including ones a document asserts about itself.

## C. Executing

1. Line by line.
2. Observe **full and real** output. Not an exit code, not a grepped fragment.
3. **No verdict before the falsifying command.** Read, measure, then report.
3a. ⚠️ **AND DISPATCHING AN ADVERSARY ROUND IS A VERDICT-GENERATING ACT — rule 3 above is written
    about REPORTING, and that is the hole.** If the system the code touches is REACHABLE, run the
    code against it BEFORE sending it to a round. Measurement collapses the hypothesis space a
    review would otherwise explore.
    **MEASURED 2026-08-22:** a `walk-matrix.sh` change went through **four** rounds and ~35 findings
    without ever running against the live lab — which was up the whole session, and had been used
    that same morning to measure the very certificate under discussion. Rounds 2–4 argued about
    **IP-SAN arms and wildcard SANs this estate does not have**. One run of the real function
    settled it: `SUPPLY_RC=0`, the DNS-SAN arm fired, and the admin-password POST minted a real
    token over the pinned connection. The rounds were not wasted — they caught three log lines
    asserting things the code did not do — but the ORDER cost three rounds on configurations that
    cannot occur.
    Practically: extract and run the **whole function**, not a lifted fragment (a fragment cannot
    prove the path the product takes); stub the minimum; use a throwaway `OUT_DIR`; pair every
    "it works" with a **control that must FAIL** (`--cacert` giving rc=0 means nothing until the
    same request without it gives rc=60); and state what the run did NOT cover.
4. `.env` **fresh** from `.env.example`, via the document's own lifecycle targets.
5. After every lab cut, verify `make creds-show` / lab `make creds` endpoints and credentials by
    **authenticating**, and drive the web UI in **Chrome** where an HTTP probe is not proof a human
    can log in.
6. **Verify credentials AFTER the matrix completes, not during it.** A run reinstalls Harbor
    between cells, so the live lab is mid-mutation while rows walk. Run 6 printed **five distinct**
    Harbor credentials (the NOTHING cell mints a per-row robot account; the EVERYTHING cell uses
    `admin`), so "the credential" does not exist for a lab-state that is still moving. During a run
    the authoritative evidence is **in-walk**: a mirror push of 24 images cannot happen without a
    successful Harbor auth, and `argocd-auth-check` issues a real session token.
7. **Drive the browser under a throwaway `HOME`.** Chrome on Linux reads NSS from `$HOME/.pki/nssdb`,
    so a `mktemp -d` HOME gives it a throwaway trust store and the operator's own is never opened.
    Adding or removing a CA in the operator's trust store is a **security setting that belongs to
    them**, not to the agent — prove the outcome, then hand them the command.

## D. Reading the result

1. Cite the **per-invocation** `VERDICT-<runid>.txt`. Never a fixed path — a previous run wrote that
    one too.
2. Read each row's `WALK DONE` / `DOCUMENT` lines **and** the `N of 6 designed rows` denominator.
3. Never judge by the exit code or by a completion notification.
4. **"It has not advanced" is measured on the log's TAIL and its mtime — never on a marker whose
    cadence you have not read.** Run 6: a `[N/24]` progress marker logs only on *pull completion*, so
    a row that pushed blobs for 13 minutes looked stalled while it was perfectly healthy. It finished
    GREEN, and on that false reading a correct diagnosis was nearly revised.
4a. ⚠️ **AND THAT INSTRUMENT IS STILL INSUFFICIENT — THE HOST LOG LAGS THE BOX BY MINUTES, because a
    walk's output is ssh'd from a NON-TTY and the far side BLOCK-BUFFERS it.** Rule 4 tells you to use
    the tail *and* the mtime. Run 8, row 2, measured: the log's mtime age was **555s** and its size was
    frozen at **95,299 bytes** — both of rule 4's signals said stalled — while a read-only `ps` on the
    walk box showed **three different `crane validate` invocations inside 40 seconds**. The log then
    flushed and its age dropped to 31s. Nothing was wrong; the pipe was simply holding ~9 minutes of
    output. For scale: the same row's healthy baseline was a **15s** maximum inter-image gap, so the
    false signal was 35x the real one — comfortably enough to look fatal.
    **So liveness is read from the ARTIFACT ON THE BOX, never from the host log** (this repo's own
    "detect by ARTIFACT, not by a proxy" rule, applied to the walk):

    ```sh
    K=/var/tmp/vks-walkbox/id_ed25519; IP=<vm ip from FINAL<N>.log>
    O=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -i "$K")
    timeout 20 ssh -n "${O[@]}" "vks@${IP}" 'ps -eo etime,args | grep -E "^ *[0-9:]+ (crane|kubectl|helm|make) " | head -3'
    ```

    Sample it **twice**, ~20s apart. Two *different* commands is progress, full stop. The identical
    command with a growing `etime` is **not** a hang by itself — ⚠️ **that sharper-sounding rule was
    WRONG and was corrected the same day.** A composite step legitimately runs for many minutes:
    measured, `make verify` alone took 3m15s and 2m57s in the two scenario-1 rows and **6m16s** in a
    scenario-2 row that finished GREEN. So the identical command is a hang only once its `etime`
    exceeds **that step's own baseline**, which you get from a previous row's log.
    ⚠️ **AND THE BASELINE MUST COME FROM THE SAME SCENARIO.** Run 8 row 5 (scenario-2) sat at 5m42s
    on `make verify`. Against the scenario-1 rows that reads as **1.7x slow** and invites a wrong
    diagnosis; against run 6's scenario-2 row — same OS, same step, GREEN — it is comfortably
    normal. The scenarios are different code paths; comparing across them is the wrong comparator,
    and it is the easy mistake because the scenario-1 numbers are the ones in front of you.
    `-n` is load-bearing (it stops ssh eating the caller's stdin), and this is READ-ONLY — never run
    anything on the box that writes, per H.
    (This is also the argument for the per-run output directory: a previous run's row log IS the
    baseline, and a flat layout clobbers it.)
    **A hang here is unbounded**, which is why the distinction matters: `walk-doc.sh` has no timeout of
    any kind, `walk-matrix.sh`'s timeouts cover only its kubectl/openssl probes, and
    `mirror_retry` (`scripts/lib/mirror.sh:89`) retries a command that *returns* — a wedged
    `crane pull` never returns, so nothing in the stack will ever end it.
5. **`MATRIX FAILED` means failed** — even when every row printed `WALK DONE`. That is the harness's
    wording for *did not complete successfully*, not a claim that a row never ran.

## E. Implications run BOTH ways

1. A fix to a script or `.env` obliges a check of the **documents**.
2. A fix to a document obliges a check of the **scripts and Makefile targets**.
3. Both directions, every time. A doc that disagrees with you misleads; a script that disagrees with
    you **overwrites** you.

## F. Security

1. Secrets **never in argv** — `curl -K` config files under `umask 077`, `--data @-` on stdin, or
    env-by-name.
2. The vCenter SSO account **locks out permanently after 3 failed attempts**. Never brute, never
    retry a failed auth blind.
3. Do **not** type passwords into web login forms.
4. `harbor-robot.env`, `gitea-ci-token` and `webhook-token` are **never** blanket-deleted. Walk logs
    carry live credentials, so `/tmp/walk` and every per-run directory stay `0700`.

## G. Process

1. **Rule Zero** — adversary-review the **design**, before implementing. Dispatch with
    `isolation: "worktree"`, and either schema-forced (`Workflow`) or synchronous; a fire-and-forget
    background agent has measured 0/7 delivery against 39/39 for schema-forced.
2. Commit and push roughly every 30 minutes — **except** while a matrix is armed or running, when
    the freeze in §H takes precedence.
3. **A batch prepared during a freeze goes STALE — re-read every row against what landed since,
    before committing.** Run 6: a 14-row backlog batch drafted under the freeze carried two rows whose
    conclusions adversary rounds had refuted hours later. Committing it unread would have published
    refuted findings under a "validated batch" label — and that label is exactly what stops the next
    reader from checking.
4. Run `env -u GOROOT make static-check` locally before every merge. A PR runs only
    `static-check-pr`, which omits `sec` (gitleaks, trivy-fs, trivy-config) and the wall-clock tests;
    the full target runs per-PR only on the weekly schedule.
5. **Run `make app-verify` locally before every merge that touches `apps/**`.** As of 2026-08-23 the
    app builds (`app-test`, `check-ui-contract`, `trivy-fs`) are deliberately OUT of both CI gates: they build all
    six toolchains — java, go, node, python, rust, dotnet — for a repo whose subject is the AIR-GAP
    PIPELINE, not the apps. The apps are really tested by Tekton, in their own builder images, which
    is the thing being demonstrated.
    This is DISCIPLINE, not a gate, and the exposure is measured: 19 of the last 200 commits touch
    `apps/**` and **10 of those are Renovate**, which auto-merges on green. So a dependency bump that
    breaks a test can land unless someone runs this. Nothing enforces it but the person merging.
    `trivy-fs` moved here too, so **the app-artefact CVE scan no longer runs in CI at all** — CI keeps
    only the scans that need no build (gitleaks, prose-secrets, trivy-config on the manifests).

## H. During a run

1. **Never edit a script the matrix is executing.** bash reads a script incrementally, so rewriting
    one mid-run yields `unexpected EOF` that reads as a product bug. This includes
    `nested-vsphere-lab`'s own step scripts — the cut-B rebuild invokes that repo's `lab` target
    mid-matrix. (It lives in **nested-vsphere-lab**, not here; this repo has no such target.)
2. **The tree is frozen while the matrix is armed or running.** `walk-matrix.sh` refuses a
    `WALK_REPO` that is dirty or ahead of `origin/main`, and every row ships `git archive HEAD` at
    **row** time — so a branch blocks the launch and a mid-run merge splits the run across two
    commits. (`git archive` reads the commit, so an uncommitted working-tree edit is harmless; being
    *ahead* is not.)
3. **One matrix at a time.** Two concurrent runs against the same lab make any failure
    unattributable.
4. **Kill by process group**, not by PID — killing a driver by PID orphans its children, and an
    orphaned lab-rebuild (nested-vsphere-lab's `lab` target) will rebuild the lab underneath you.
5. Run multi-statement shell blocks under `bash`, not the login shell. The agent's shell is zsh,
    where an unmatched glob **aborts** the command and `read -a` leaves variables empty — producing
    confident false negatives.

## Notes

- The rule count in B176 was **24**; writing them out yields **34** numbered items, because several
  of its groups bundle more than one obligation into a sentence. The content is the same.
- The during-a-run rules are the ones most often violated under time pressure, and each has a recorded incident
  behind it.
