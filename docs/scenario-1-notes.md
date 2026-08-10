# Scenario 1 — notes, caveats and field observations

The runbook ([scenario-1.md](scenario-1.md)) tells you what to run. This file tells you **why a step
is shaped the way it is**, and what goes wrong when it is not. Nothing here is needed to complete a
normal install — read a section when a step surprises you, or before you "simplify" one.

Every claim is graded: **measured** (observed on a real lab or reproduced locally), **lab-verified**
(seen on a 9.1 Supervisor), or **field note** (seen once, cause not isolated).

---

## Step 1 — jump box

**Your SSO domain is a parameter, not a constant.** *(measured, two labs)* One 9.1 lab uses
`vsphere.local`, another `wld.sso` — the built-in default. Neither is "the" value, which is why
`make vks-login` **warns** when it applies the default instead of accepting it silently. Read yours
from vCenter → **Administration → Single Sign On → Users and Groups**, *Domain* dropdown. Guessing
does not fail cleanly: a plausible-but-wrong principal takes your real password at an interactive
prompt and then fails somewhere else.

**⛔ Never `vcf config set env.VCF_CLI_VSPHERE_PASSWORD …`.** It writes the password **plaintext** to
`~/.config/vcf/config.yaml` — outside the repo, invisible to gitleaks, and it survives every
teardown. Use the interactive prompt, or `export VCF_CLI_VSPHERE_PASSWORD` for the session.

**A stale KinD overlay redirects everything.** `.env.state` is sourced *after* `.env`, so a leftover
from a local run silently points the whole flow at a kind cluster. `make state-show`, then
`make kind-down`. It is archived rather than deleted when it belongs to a different cluster — it may
hold that cluster's generated passwords.

---

## Step 2 — Harbor

**The storage-class name is the policy name normalized**, not the string the vSphere Client shows:
the policy *"vSAN Default Storage Policy"* is the class `vsan-default-storage-policy`. Lowercase it,
replace spaces with `-`, and re-check with `kubectl get storageclass` as soon as Step 3 gives you
Supervisor access. Pasting the UI string verbatim is **not** a loud failure — quoted, it is written
straight through, and no PVC ever binds, because it is not a valid Kubernetes object name.

**Check the data-values file still has both expose keys before editing it.** *(measured, v2.14.3)*
`yq '.k = v'` **creates** a missing key, so if the vendor renames the expose toggles, setting them
appends two dead top-level keys, leaves the real one untouched, and ships a Harbor with **no
reachable ingress and no error** — every downstream check still green. `sed` has the mirror failure:
it silently changes nothing.

```bash
yq -e 'has("enableNginxLoadBalancer") and has("enableContourHttpProxy")' "$src" >/dev/null \
  || { echo "This data-values file does not carry BOTH expose keys at the top level."; false; }
```

Use `false`, not `exit 1` — pasted into your shell, `exit` closes it.

Three known limits of that precondition, so you can judge a red honestly *(reproduced against yq
v4.53.3 on synthetic files)*: it reads only the **top level**, so a file that *nests* the toggles
fails it though the file is fine; on a **multi-document** file it passes if *any* document carries
both keys; and it checks a key's **presence**, not the literal `key: false` the `sed` matches — so
`enableNginxLoadBalancer: "false"` passes the guard while the substitution silently no-ops.

**Confirm the edit landed** — the four `sed` expressions change **eight** lines, because
`insert-storage-class-name-here` occurs five times (registry, jobservice, database, redis, trivy)
and the other three targets occur once each:

```bash
diff "$src" ./secrets/harbor-values.yaml    # expect 8 changed lines (1+1+1+5)
```

**The `:?` guards in the `sed` are load-bearing.** Without them an unset variable substitutes
**empty**, the pattern still matches, and you write a `hostname:` key with nothing after it — a
Harbor that installs cleanly and is unreachable.

**DNS, not `/etc/hosts`.** Every kubelet on the guest cluster pulls from `$HARBOR_URL` and cannot see
the jump box's hosts file. With only a hosts entry, `make mirror` succeeds and every workload
`ImagePullBackOff`s later. **No DNS?** Use Harbor's LB IP as `HARBOR_URL` — but the certificate must
then carry an **IP SAN**, because Go rejects a DNS-only certificate on an IP URL even when the CA is
trusted.

**`HARBOR_URL` is a bare host.** A leading `https://` yields `https://https://…` and
`curl: (6) Could not resolve host: https`. The setup strips and warns, but every other consumer would
be reading your wrong value.

---

## Step 3 — ArgoCD, and the `vcf` CLI

**`--ca-certificate` and `--insecure-skip-tls-verify` are an enforced exclusive pair.**
*(measured 2026-08-04)* Passing both fails with `[x] : … [ca-certificate insecure-skip-tls-verify]
were all set`. Pick one.

**Do not plan on the insecure flag.** *(field note, seen once, cause not isolated)* On one lab the
run still died with an x509 error after passing it. Two rival explanations before you blame the flag:
`vcf context use` on the very next line carries **no TLS flag at all** and must still reach the
Supervisor, and a context left over from a previous lab brings its own TLS material with it. Get the
CA — that path is known to work, and a password is submitted over this connection either way.

**`vcf context create` refuses a duplicate context name**, and its store
(`~/.config/vcf/config.yaml`) lives outside this repo and outside every teardown — so it survives a
lab rebuild and then blocks you while pointing at a dead endpoint:

```bash
vcf context delete "$VKS_CONTEXT_NAME" -y --skip-delete-kubeconfig-context 2>/dev/null || true
```

`make vks-login` does this for you.

**`vcf context create` writes its contexts into `$KUBECONFIG`** and repoints that file's
current-context at the Supervisor. If `$KUBECONFIG` is your *guest* kubeconfig, every later
`kubectl` — and `make platform` / `make gitops` — silently targets the **Supervisor**. Point
`KUBECONFIG` at a Supervisor-only file when you run `vcf context create` and `vcf context use`:

```bash
KUBECONFIG=./secrets/supervisor.kubeconfig vcf context create …
```

`make fetch-argocd-kubeconfig` does exactly this.

**`vcf context use` can exit non-zero after succeeding.** It prints `Successfully activated context
…` and then fails plugin discovery against a "system Harbor registry" a Supervisor only has if one
is registered as such. Judge it by the artifact (`kubectl … get ns`), not by the exit status. No env
var or flag suppresses it.

**Two forms of `vcf context create`.** The positional-name, bare-endpoint form is the one
**lab-verified** on a 9.1 Supervisor. `make vks-login` additionally passes `--username` and
`--type kubernetes`, which is **not** lab-verified — if either flag is rejected, the positional form
is known-good. Confirm with `vcf context create --help`. *(vSphere 8: `kubectl vsphere login
--server $SUPERVISOR_HOST`.)*

---

## Step 4 — the guest cluster

**`spec.topology.version` is a PREFIX selector, not an exact version.** Admission resolves and
**rewrites** it to a concrete TKr. A guard asserting your `.env` version must equal the running one
would block a working configuration.

**Do not recreate a cluster under a name you just deleted.** *(measured, four incarnations)* The new
cluster advertises the **previous** incarnation's control-plane VIP — `spec.controlPlaneEndpoint.host`
lags by exactly one allocation — and then never converges, because CAPI dials an address nothing
serves. It does not self-heal.

| | advertised | its load balancer |
|---|---|---|
| 1st (fresh lab) | .134 | **.134** — agreed, Ready in 3m45s |
| 2nd, same name | .134 | .136 — never converged in 25 min |
| 3rd, same name | .136 | .137 — never converged |
| 4th, same name | .137 | .138 — predicted from the pattern, then confirmed |
| **5th, a NEW name** | **.139** | **.139** — agreed, Ready, walk completed |

`make vks-cluster-status` reports this directly (`endpoint : *** DIVERGENT ***`, naming both
addresses). The remedy that was measured to work is **a different cluster name**.

**`.status.phase == Provisioned` is not readiness**, and neither is a bare `condition == True`.
Conditions carry `observedGeneration`, and during a topology change `metadata.generation` advances
first — so a `True` from generation N-1 is readable while generation N is mid-reconcile. CAPI also
mints the kubeconfig Secret **before** nodes join, so you can hold a working-looking kubeconfig for a
cluster with zero nodes. `make vks-cluster-status` gates on the conditions **and** the Ready node
count.

---

## Step 6 — Harbor's CA

**Route A (the Harbor UI) needs only a Harbor login.** Route B needs Kubernetes access to the
Supervisor **and an admin-level grant** — see below. Prefer A.

**🔴 Route B's `get secret harbor-ca-key-pair` also returns the CA's private signing key.**
*(measured)* It is type `kubernetes.io/tls` with keys `ca.crt` / `tls.crt` / `tls.key`, and `tls.crt`
is byte-identical to `ca.crt` (self-signed, CA:TRUE). Kubernetes RBAC has no field-level read, so
whoever can run that command can **mint a certificate for anything** every `HARBOR_CA_FILE` consumer
(crane, podman, Kaniko) trusts. That is an admin-level grant, not a read-only one.

**Four things are load-bearing in Route B**, and the naive one-liner gets them all wrong —
**truncating a working CA to 0 bytes at rc=0** *(measured, twice)*. `make harbor-ca-from-cluster`
bakes them in:

1. **Select the namespace by label**, not `kubectl get ns | grep harbor`. Zero matches yields an
   empty namespace and kubectl silently runs against `default`; two or more (a tenant namespace
   called `my-harbor-apps`, a second Harbor) feeds it a multi-line value. Neither is detected.
2. **`--kubeconfig ./secrets/supervisor.kubeconfig` is required.** Harbor runs on the **Supervisor**,
   but `.env` sets `KUBECONFIG` to the **guest** cluster, which has no harbor namespace at all.
   *(measured)* Ambient kubectl gives `Error from server (NotFound)` with rc=0, so a redirect would
   truncate your working CA to 0 bytes.
3. **Never redirect straight into `$HARBOR_CA_FILE`.** A jsonpath miss on an existing secret yields
   rc=0 and empty output; `base64 -d` on empty yields rc=0 and a 0-byte file; the whole pipeline
   under `set -euo pipefail` is rc=0. A renamed key, a different Harbor version, or the wrong cluster
   **replaces a good CA and reports success**. Stage through `mktemp`, validate, then `mv`.
4. **`chmod 0644` before the `mv`.** `mktemp` creates 0600 and `mv` preserves the mode, so without it
   the recipe deterministically produces a **0600 trust anchor** — while a CA is public material every
   consumer must read whatever uid it runs as. A 0600 anchor fails with an error naming *trust*, not
   permissions. Do the chmod on the temp file so the final step stays an atomic rename.

**Verify either way — a file that exists is not a trust anchor that works:**

```bash
openssl s_client -connect "$HARBOR_URL:443" -servername "$HARBOR_URL" </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/leaf.pem
openssl verify -CAfile "$HARBOR_CA_FILE" /tmp/leaf.pem                       # must print: OK
curl -sS --cacert "$HARBOR_CA_FILE" -o /dev/null -w '%{http_code}\n' \
  "https://$HARBOR_URL/api/v2.0/systeminfo"                                  # must print: 200
```

**Ask for the CA's SHA-256 out of band first** — by a channel that is *not* this connection. Without
it, `make fetch-harbor-ca` is trust-on-first-use, and it says so.

---

## Step 8 — the Supervisor kubeconfig

**`ARGOCD_KUBECONFIG` unset is a catastrophic default.** It falls back to the **guest** kubeconfig, so
`make gitops` would look for ArgoCD in the wrong cluster. Set it explicitly.

**Discover `ARGOCD_NAMESPACE`, do not assume it.** The built-in default (`argocd`) and the runbook's
suggested `argocd-instance-1` are both guesses about *your* lab.

---

## Step 9 — install

**`make gitops` refuses to guess a destination.** If ArgoCD has registered clusters but none matches
your guest by name or API URL, it stops rather than deploying into whichever one happens to be there.
*(measured)* Before that guard existed, a shared ArgoCD with exactly one registration — the lab's own
cluster — was adopted silently, and both Applications deployed **into the lab's cluster** for 18
minutes while reporting Synced/Healthy, because they genuinely were, in the wrong place.

If your guest is simply not registered yet, run `make argocd-register-guest` (admin-only: it creates a
cluster-admin ServiceAccount in your guest and a Secret in the ArgoCD namespace). If you cannot
register it, ask your platform team and then set `ARGOCD_DEST_CLUSTER_NAME`.

---

## Step 11 — Istio

Broadcom routes with the **Kubernetes Gateway API**, and Istio's ingress gateway is **off by
default**. On a real lab Istio is a guest-cluster **Standard Package** you attach to, not something
you install — `INGRESS_CONTROLLER=istio-existing`.

**Istio has no credentials.** No login, no bearer token, no admin API; access is kubectl RBAC. The
only credential-shaped object is a TLS Secret named by `Gateway.tls.credentialName`, which lives in
the gateway's namespace — so you *request* it.

**The gateway's `istio:` selector label defaults to the helm RELEASE NAME**, so a platform-installed
mesh is **not** labelled `ingressgateway`. It must be discovered. A non-matching selector is accepted
by the API server with no error and binds nothing → connection refused; a VirtualService naming the
Gateway by bare name from another namespace resolves namespace-locally → 404.

---

## Step 12 — teardown

**It deletes only what carries our ownership label**, never by name, never with `--all`, and it
refuses an unlabelled object rather than guessing. On a real lab `ARGOCD_NAMESPACE` and
`VKS_NAMESPACE` are often the **same** namespace, which also holds the ArgoCD instance itself and
other tenants' objects — and our Applications carry `prune: true`, so deleting one by name would
cascade-delete its workloads **in the destination cluster**.

**Harbor is deliberately manual.** Harbor refuses to delete a project that still holds repositories,
and that refusal is the only thing standing between a stale project and someone else's images.
Forcing it is the one shortcut that could destroy a shared registry.

**"Nothing was deleted" is reported as UNPROVEN, not clean** — it is indistinguishable from "my label
selector matched nothing". If a read fails, the teardown says `CANNOT READ` and counts the object as
*not done*, rather than claiming it was absent.

---

## Timings — what these numbers do not cover

**The mirror ran WARM.** 34 of 44 images were already in `bundle/images`, against a Harbor that
already held them, so `crane` skipped most blob uploads. A first run on an empty Harbor with a cold
cache is bounded by your bandwidth, not by the box, and is not represented in that table at all.

**`mirror-verify` is the one row a warmer run would not improve** — it re-fetches every blob rather
than skipping. It scales with the image count (44 here) and your Harbor's throughput.
`MIRROR_VERIFY_FAST=1` trades layer verification for speed.

**Two rows carry warmth the table cannot show.** The cluster's 3 m 45 s assumes the Supervisor
already has the TKr image cached — a first-ever cluster from a cold content library is a different
number. And `static-check` assumes a populated `~/.m2` and a current trivy DB.

**Provisioning is the variable row, not the mirror.** Run 2's cluster took ~6 min against run 1's
3 m 45 s because it provisioned beside the lab's own cluster, while `install-all` got *faster*
(10 m 26 s → 8 m 14 s) as Harbor warmed. The mirror gets monotonically warmer; the host gets busier.

## A Supervisor Service stuck in `REMOVING` (or `CONFIGURING`)

Re-issuing the uninstall does nothing, and vCenter refuses to deregister with
`400 ... still installed`. Check Kubernetes first — if the namespace and pods are already
gone, the workload really is removed and only **vCenter's record** is stuck:

```bash
kubectl get ns | grep '^svc-'                 # the service's namespace, if any
make wcp-status                               # is Workload Management healthy?
```

MEASURED on a real lab: ArgoCD's uninstall left Carvel's `kapp` reporting
`Timed out waiting after 15m0s for resources: endpoints/... namespace: svc-argocd-service-...`
— endpoints in a namespace Kubernetes had **already deleted**. Nothing on the Supervisor side
was left to delete, so the delete could never observe completion and the record never advanced.

Restarting Workload Management makes its reconciler re-evaluate:

```bash
make wcp-restart          # waits until wcp is STARTED/HEALTHY again
```

**If that does not clear it, check for a `deletionTimestamp` before assuming "slow".** MEASURED:
the uninstall reported a kapp timeout *waiting for resources to be deleted* while Kubernetes had
**no deletionTimestamp on any of them** and the Deployment had been Running for 22 h — vCenter
was waiting for a deletion it never issued, which is indistinguishable from slowness until you
look:

```bash
kubectl -n <the svc-* namespace> get deploy,svc,endpointslice,pod
kubectl get ns <the svc-* namespace> -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
```

Nothing there and no timestamp = the platform is stuck, not busy. The break-glass deletes the
workload the platform is waiting on, so its own reconcile can finish:

```bash
make list-supervisor-services      # what vCenter knows, and the SERVICE=<id> to pass
make unwedge-supervisor-service SERVICE=argocd-service.vsphere.vmware.com CONFIRM=yes
```

### Removing Harbor or ArgoCD again

`make uninstall-all` removes what this repo deploys INTO a cluster; it does not touch the
Supervisor Services scenario-1 installs in Steps 2 and 3. Those come out with:

```bash
make list-supervisor-services
make uninstall-supervisor-service SERVICE=harbor.tanzu.vmware.com CONFIRM=yes
```

**Uninstall and deregister are DIFFERENT, and everyone learns this once.** `uninstall` removes the
WORKLOAD and its data; the service stays REGISTERED and still shows `ACTIVATED` in the listing.
`deregister` removes the DEFINITION from vCenter's catalogue:

```bash
make deregister-supervisor-service SERVICE=harbor.tanzu.vmware.com CONFIRM=yes
```

The platform enforces the order — deactivate, delete every version, then deregister — and refuses
to deregister while a workload exists (`400 ... because it has ...`), so uninstall first. To get
the service back afterwards, `make install-harbor-service` / `install-argocd-service` re-register
from the `.yml` for you.

MEASURED on a real lab: uninstall took **40 s** (ArgoCD) and **80 s** (Harbor); deregister was
immediate for both.

⚠️ It **destroys the service's data** — for Harbor every project and image, for ArgoCD every
Application — and a Supervisor Service is **shared**: it goes for every tenant on that
Supervisor, not just your namespace.

Its wait budget is **1800 s by default, deliberately**: the platform drives the uninstall with
Carvel `kapp`, which retries in **15-minute rounds**, so anything under two rounds expires
mid-round and reports failure whether or not it is progressing. It prints the platform's own
message whenever it CHANGES — a changing message means it is grinding forward, an unchanging one
across rounds means wedged.

### When nothing clears it — the full escalation ladder, and where it ends

MEASURED 2026-08-09 against one wedged ArgoCD service, over ~90 minutes. Every rung was
refused **by the platform**, not by our tooling. Recorded so nobody re-walks it:

| attempt | platform's answer |
|---|---|
| `services-uninstall` x4 | accepted, never completes |
| `make wcp-restart` | service healthy again, record unchanged |
| delete the workload objects it waits on | namespace emptied, record unchanged |
| install | **400** — "already exists" |
| update (PUT the spec) | **204 accepted** — but nothing reconciled |
| deregister / delete-version | **400** — "still installed" |
| delete the `svc-*` namespace | **denied by admission webhook**, for every user incl. vCenter admin |
| reset the Supervisor control-plane VM | **403 Forbidden** — it is a protected system VM |

**A timing trap that makes all four uninstalls look identical:** the lab tool waits **600 s**
while `kapp` retries in **15-minute (900 s) rounds**, so it *always* reports failure before a
round can finish — whether or not anything is progressing. Judge by the message CHANGING
(`endpoints` -> `endpointslice` means it is advancing), not by the tool's verdict.

**Where it ends:** a service in this state cannot be installed, updated, removed or deregistered,
and the Supervisor cannot be restarted to clear it. The remaining remedy is rebuilding the
Supervisor. Worth knowing before spending an hour on the ladder.

**Where a service id comes from:** vCenter DERIVES it from the service-definition YAML's
content, so it is dotted (`harbor.tanzu.vmware.com`) and *not* the dash-only catalogue key
(`harbor`). You cannot invent it — read it from `make list-supervisor-services`, or from
`?action=checkContent`, which returns it before anything is registered.

It **refuses** unless vCenter reports the service mid-delete (otherwise it would delete a healthy
service's operator), **discovers** the namespace rather than taking a pasted one (the suffix is
random per install), and prints what it will delete first. It does **not** delete the namespace:
the Supervisor's own webhook refuses that for every user including vCenter admin — *"Principal
administrator ... is not associated with namespace"* — and the platform removes it once its
reconcile completes.

**Blast radius:** this is Workload Management for the **whole vCenter** — every Supervisor and
tenant loses provisioning, service install/uninstall and namespace management for the duration.
**Running workloads are unaffected**: guest clusters, pods and LoadBalancers keep serving.
A stuck `REMOVING` may need another reconcile cycle afterwards, and `kapp` waits in 15-minute
rounds — so give it that long before concluding the restart did not help.

`make wcp-start` and `make wcp-stop` exist for the rare case you want the service down
deliberately. `wcp-stop` requires `CONFIRM=yes` because, unlike a restart, it stays down for
every tenant until someone runs `wcp-start`.

## `kubectl` suddenly says `Unauthorized` — your Supervisor token expired

```text
error: You must be logged in to the server (Unauthorized)
```

The Supervisor kubeconfig `make vks-login` writes carries a **time-limited token**, and Steps 5,
6, 8 and 9 all use it well after Step 3. Take a long enough break — or have anything restart
vCenter's Workload Management — and it stops working mid-runbook. Nothing is broken and nothing
is lost:

```bash
make vks-login          # re-issues the token into the same kubeconfig
```

Our own scripts name this cause for you (`classify_kube_failure`). The bare message above is
what you get from a **raw `kubectl`** — the ones this runbook has you run by hand in 1b, 2.6,
3.6 and 8.
