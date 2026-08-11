
## walk harness: it tests a NEW doc against PUBLISHED code (found 2026-08-11)

`walk-matrix.sh` scp's `docs/scenario-1.md` from the local checkout, but block [03] of that doc
runs `git clone https://github.com/.../vks-airgap-cicd.git`, so the VM builds against whatever is
on origin. Doc and code therefore come from DIFFERENT commits, and a fix that touches both fails:

    === [11] 4. Harbor
        $ make harbor-reachable
        make: *** No rule to make target 'harbor-reachable'.  Stop.
    --- [11] rc=2 (0s)

The doc said `make harbor-reachable` (local commit d7dec50); the clone was origin/main, which has
no such target. The harness was RIGHT and the setup was inconsistent.

`walk-doc.sh` already carries the knob: `WALK_SKIP_CLONE=1` neutralizes the clone block. The fix is
for the driver to ship `git archive HEAD` of the local repo and set it, so the doc and the code are
the SAME commit by construction. `git archive` also excludes every gitignored operator-local file
(.env, secrets/), which a plain rsync would carry.

Trade-off to state where it lands: shipping the tree stops exercising the documented `git clone`
step. Keep an opt-out (clone the published repo) for the pre-release check.

NOT APPLIED YET: walk-matrix.sh was mid-run when this was found, and bash reads a script
incrementally, so editing it would have corrupted the running matrix.
