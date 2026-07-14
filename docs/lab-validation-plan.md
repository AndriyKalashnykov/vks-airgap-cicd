# VKS lab run — the validation plan (Scenario 1)

<br>
**This is a validation plan, not a runbook.** The runbook is [Scenario 1](scenario-1.md) — follow it.
This rides alongside it and, at each point, tells you **what to capture**. Every step settles a claim
this repo currently **cannot verify** without a lab.

## Rules — these change what you type

1. **Run the `install-all` stages SEPARATELY, never as one command.** `make install-all` is a 30–40 min
   monolith; run `mirror` → `platform` → `gitops` as separate targets so two claims can be probed *at
   the moment they become observable* and **before** the step that depends on them (steps 17 and 20).
2. **Start every command block with `set -a; . ./.env; set +a`.** In a bare shell `$HARBOR_URL`,
   `$ARGOCD_NAMESPACE` etc. are **EMPTY** (scripts materialise them via `load_env`), and an empty var
   in an `envsubst` render silently yields `namespace:` blank.
3. **Never hardcode ArgoCD's workload names** — discover by label
   (`-l app.kubernetes.io/part-of=argocd`) and record the real ones. If they are not `argocd-server`,
   that is **our bug**, not your lab.
4. **Capture the tool's raw output, never your verdict** — `--help` blocks, `describe` Events, image
   tags, cert SANs. We compute the conclusions.
5. **A step marked `UNVERIFIED-COMMAND` has never been run by us.** If it errors, **send us the
   `--help` output** and use the fallback. Do not fight our guess.

**Cost:** steps 1–14 are cheap (minutes each, read-only) and settle 7 of the 8 headline claims.
**Step 16 (`make mirror`) is the only slow one** (~20–40 min, ~34 images) and **must run alone**.
Steps 19–24 are minutes each.

<details><summary><b>Why the plan is ordered this way</b> (background — skip unless a step looks wrong)</summary>

- **Walk the runbook, don't bypass it.** Scenario 1 makes you install Harbor + ArgoCD as Supervisor
  Services and provision the cluster anyway — so every divergence between our doc and the vSphere
  Client you actually see is free evidence about the least-verified prose we ship. A plan that starts
  at *"assume `./secrets/vks.kubeconfig` exists"* throws that away.
- **We ship TWO CONTRADICTORY forms of `vcf context create`** (`30-vks-login.sh:70` uses an interactive
  name with `--auth-type basic`; `31-fetch-argocd-kubeconfig.sh:63` uses a positional name with
  `--type k8s` and `--ca-certificate`). At most one is right, **neither has ever run**, and this repo has shipped a
  fabricated `vcf` command before — hence rule 5 and the `--help` dump in step 3.
- **Why the stages must be split** (rule 1): **Harbor CA auto-trust** (graded *community*) is
  observable right after `mirror` and **before** `platform`, which pulls Gitea *from* Harbor — if
  auto-trust is false, `platform` ImagePullBackOffs and the remedy rolls your worker nodes.
  **Supervisor → guest LoadBalancer reachability** is the one claim KinD structurally cannot settle;
  it becomes observable the moment `platform` gives Gitea an LB, and we probe it **before** `gitops`
  on the exact port (3000) and protocol ArgoCD will use — from inside the real repo-server pod, with
  `git ls-remote` (**git** is in that image; `curl`/`wget` are **not**, and a curl-based probe would
  report "not found" and have us tear up the architecture over a missing binary).
- This plan was adversarially reviewed: three drafts attacked for wasted steps, fabricated commands,
  and anything that could damage your lab, then adjudicated into one.

</details>

## What this is for — and what we do with your evidence

**The problem:** this repo works end-to-end on KinD, and **KinD is not VKS**. A large set of facts we
ship are graded *9.0-doc-inferred*, *community*, or **UNVERIFIED** — including the two the whole design
rests on (ArgoCD lives on the Supervisor; the Supervisor can reach a guest LoadBalancer). **We have
never seen a lab.** Everything we would otherwise do is a guess with a confident tone.

**What your run buys:** every step below is one claim. Each piece of evidence you send back does **one
of three things** to this repo, and each step says which:

| Your evidence | What we do with it |
|---|---|
| **Confirms** the claim | we **upgrade its grade** to `lab-verified` in `docs/vks-services/*.md` — and stop hedging in the docs |
| **Refutes** it | we **fix the code or the doc**, that day, and tell you what changed |
| **Shows a command we invented** | we **rewrite the script** from your `--help` output — this is why the `vcf` steps exist |

**We compute the verdicts, not you.** Send raw output. A paraphrased error is a lost finding, and a
summarised `--help` is a rewritten script we get wrong twice.

## How to read a step

| Field | Means |
|---|---|
| **Why** | the claim it settles. If a step has no claim, it would not be here. |
| **Who needs it** | **YOU** = it blocks your install; a FAIL means stop. **US** = it costs you minutes and only we learn from it. **BOTH** = a FAIL blocks you *and* changes the repo. |
| **Where** | which box you type on, and **which cluster the commands hit**. Everything runs from the **jump box** (that is where the repo, `make`, and the CLIs live) — except the vSphere Client work, which is your browser. |
| **Run** | copy-paste. `⚠️ UNVERIFIED` = we have never run this command; if it errors, **send us the `--help` and use the fallback**. |
| **Expect** | what you should see. This tells you it worked **without asking us**. |
| **Send back** | the artifact, raw. Never your verdict — we compute those. |

**Everything lands in `/tmp/*.log`.** Step 15 tars it up and is a **hard stop**: send it before the mirror.

## Phase 1 — read-only, ~1 hour. STOP at step 15

### 1. Does the runbook's first command work on a lab jump box? · CHEAP

**Why:** `make check-tools` has never run on a lab. Scenario 1 claims four `.env` vars are all you need here.
**Where:** jump box. Touches no cluster.
**Who needs it:** BOTH — a missing CLI blocks you; a prereq gap is our doc bug.
**We then:** fix any prereq the runbook never told you to install, and add the missing var to the doc's upfront list.

```bash
git clone <this-repo> && cd vks-airgap-cicd
make env-init
make check-tools 2>&1 | tee /tmp/01-check-tools.log; echo "EXIT=$?"
# then set ONLY these four in .env:
#   SUPERVISOR_HOST / VKS_USERNAME / VKS_NAMESPACE / VKS_CLUSTER_NAME
```

**Expect:** a table of required-vs-optional CLIs, and those four vars are enough to continue.
**Send back:** the check-tools table + exit code — **and whether you had to hunt in `.env.example` for a fifth var.**

### 2. Are our VCF CLI version pins real? · CHEAP

**Why:** `ARGOCD_VCF_VERSION` / `VCF_CLI_VERSION` / `VCF_PLUGINS_VERSION` are guesses; the OS/arch archive resolver has never seen a real download folder.
**Where:** jump box. Touches no cluster (reads the folder you downloaded).
**Who needs it:** BOTH — you need the `vcf` binary for everything below.
**We then:** re-pin `ARGOCD_VCF_VERSION` / `VCF_CLI_VERSION` / `VCF_PLUGINS_VERSION` from your filenames, and add them as fixtures to `test-vcf-cli-resolve.sh` so the resolver is tested against a real folder.

```bash
make deps
ls -1 <folder with the Broadcom archives you downloaded>
make install-vcf-clis VCF_CLI_SRC_DIR=<that folder> 2>&1 | tee /tmp/02-install-vcf-clis.log; echo "EXIT=$?"
```

**Expect:** it picks the right archive for your OS/arch and installs into `~/.local/bin` (no sudo).
**Send back:** the **full `ls -1`** (the filenames encode version/OS/arch — we re-pin from them) and the installer log.

### 3. What is the REAL argv of the `vcf` CLI? · CHEAP — the highest-value 60 seconds in the run

**Why:** we ship **two contradictory forms** of `vcf context create`. At most one is right; **neither has ever run**, and this repo has shipped a fabricated `vcf` command before.
**Where:** jump box. `--help` only — contacts nothing.
**Who needs it:** **US** — and it protects you from fighting our fiction in steps 6, 7, 9, 13.
**We then:** rewrite `30-vks-login.sh` and `31-fetch-argocd-kubeconfig.sh` to the **real** argv, and fix every `# how:` line in `.env.example` that is currently a guess. **Any flag we ship that is absent from your `--help` is a fabrication we delete.**

```bash
vcf version || vcf --version || true    # NEVER a bare `vcf` — it can block on stdin and hold a session
vcf --help
vcf context --help
vcf context create --help
vcf context use --help
vcf cluster kubeconfig get --help
vcf package --help 2>&1 | head -40
vcf addon   --help 2>&1 | head -40
```

**Expect:** nothing to "pass" — this is pure evidence.
**Send back:** **every `--help` block VERBATIM.** Do not summarise; the flag lists ARE the deliverable. If a subcommand does not exist, paste the error — that is also an answer.

### 4. Install Harbor as a Supervisor Service · YOUR OWN vSPHERE WORK (~30–60 min)

**Why:** our whole §A1 is 9.0-doc-inferred prose nobody has executed (Contour first? the `harbor-data-values` field set? the 16/32-char key limits?).
**Where:** **vSphere Client** (your browser) for the install; jump box → **Supervisor** for the one `kubectl`.
**Who needs it:** BOTH — you need Harbor; we need to know where our doc lied.
**We then:** correct §A1's field list from the template you paste, and upgrade `docs/vks-services/harbor.md`'s install facts to `lab-verified`.

Follow **[Scenario 1 §A1](scenario-1.md)** in the vSphere Client. Then:

```bash
kubectl get svc -A | grep -iE 'harbor|envoy|contour'   # which Service carries the ingress IP
```

**Expect:** Harbor reachable at the FQDN you chose (add the DNS record or `/etc/hosts` entry).
**Send back:** the `harbor-data-values` template **the portal actually shipped** (redact secrets) so we can diff it against our field list · any validation-error text · which Service holds the ingress IP.

### 5. Does Harbor's cert match, and are we a Harbor sysadmin? · CHEAP, READ-ONLY

**Why:** if the SAN doesn't cover `HARBOR_URL`, **every later `crane` push fails TLS**. `sysadmin_flag` decides whether `make harbor-robot` can mint one robot spanning both projects.
**Where:** jump box → **Harbor's API** over HTTPS. No cluster.
**Who needs it:** BOTH.
**We then:** if the SAN doesn't cover `HARBOR_URL`, the doc must tell operators **which name to use** — a real bug. If `sysadmin_flag:false`, our robot-minting must degrade to per-project robots on a VMware Harbor.

```bash
# .env first: HARBOR_URL / HARBOR_USERNAME / HARBOR_PASSWORD / HARBOR_CA_FILE=./secrets/harbor-ca.crt
#             HARBOR_INFRA_PROJECT=cicd / HARBOR_APP_PROJECT=apps
set -a; . ./.env; set +a
make fetch-harbor-ca
openssl x509 -in secrets/harbor-ca.crt -noout -subject -issuer -ext subjectAltName
curl -sS --cacert secrets/harbor-ca.crt https://$HARBOR_URL/api/v2.0/systeminfo | head -c 400; echo
curl -sS --cacert secrets/harbor-ca.crt -u "$HARBOR_USERNAME" https://$HARBOR_URL/api/v2.0/users/current | head -c 400; echo
```

**Expect:** the SAN **covers `HARBOR_URL`**; `systeminfo` returns JSON.
**Send back:** cert SUBJECT + ISSUER + **SAN** · the `systeminfo` JSON · `users/current` — specifically **`sysadmin_flag`**.

### 6. Install ArgoCD, and tell us what it's really called · YOUR OWN WORK + CHEAP PROBES

**Why:** our scripts **hardcode `argocd-server`**. An operator-managed instance may name it `<CR>-server` — in which case that is a real bug. We also pin a 2.x server example while shipping a 3.x CLI.
**Where:** **vSphere Client** for the Service + Namespace; jump box → **Supervisor** for every probe.
**Who needs it:** BOTH.
**We then:** if the deployments are `<CR>-server` rather than `argocd-server`, we make our scripts **discover by label** — today they hardcode the name, and it would present to you as *"the Supervisor kubeconfig doesn't work"*. If the running server is 2.x, we pin our KinD stand-in to the lab's line.

Follow **[Scenario 1 §A2](scenario-1.md)** steps 1–2, then:

```bash
# ⚠️ UNVERIFIED — use exactly what step 3's --help showed:
vcf context create --endpoint https://$SUPERVISOR_HOST --username $VKS_USERNAME \
    --insecure-skip-tls-verify --auth-type basic
vcf context use <context-name>:<argocd-vsphere-namespace>
vcf context list
# apply the ArgoCD CR from the doc, then:
kubectl get crd | grep -i argocd
kubectl explain argocd.spec.version
kubectl -n <argocd-ns> get deploy -l app.kubernetes.io/part-of=argocd \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
argocd version --client --short
```

**Expect:** the CR reconciles and `argocd-server` gets a LoadBalancer IP.
**Send back:** the full `explain argocd.spec.version` list · **the real deployment NAMES + IMAGE TAGS** (ground truth for the server generation) · the admin-secret's real name · whether the `vcf` flags were accepted as printed.

### 7. Export the guest cluster's kubeconfig · YOUR OWN WORK + ⚠️ UNVERIFIED

**Why:** `vcf cluster kubeconfig get --export-file` is a doc-inferred flag shape.
**Where:** jump box → **Supervisor** (the `vcf` CLI), writing a file locally; then jump box → **guest**.
**Who needs it:** BOTH — you need the kubeconfig; we need to know if the flag is real.
**We then:** correct the `--export-file` command in `scenario-1.md` **and** in `.env.example`'s `# how:` line — exactly the kind of fabricated command our `check-how-provenance` gate exists to prevent.

```bash
set -a; . ./.env; set +a
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file ./secrets/vks.kubeconfig
#   ⚠️ if this errors: send us `vcf cluster kubeconfig get --help`, then get the kubeconfig
#      however you normally do and place it at ./secrets/vks.kubeconfig. THE FAILURE IS THE FINDING.
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
# then in .env:  KUBECONFIG=./secrets/vks.kubeconfig  and  VKS_CONTEXT=<context name>
```

**Expect:** nodes listed.
**Send back:** whether `--export-file` is real · the node list.

### 8. Is ArgoCD really on the SUPERVISOR, not your guest cluster? · CHEAP, READ-ONLY

**Why:** **the foundation of the whole design.** `ARGOCD_KUBECONFIG`, `argocd-register-guest`, and the refusal to deploy in-cluster all rest on it. Never seen.
**Where:** jump box → **BOTH clusters** (that is the whole point — one command set per kubeconfig).
**Who needs it:** **BOTH — and a FAIL means STOP.**
**We then:** upgrade the two-cluster premise to `lab-verified` — **or**, if it is false, **delete the entire cross-cluster machinery** (`ARGOCD_KUBECONFIG`, `argocd-register-guest`, the in-cluster refusal) as dead weight and make `make gitops` take the in-cluster path. Either way we re-aim the doc's `ARGOCD_NAMESPACE`-discovery command, which today runs against the **guest**, where ArgoCD does not exist.

```bash
set -a; . ./.env; set +a
# the GUEST:
kubectl --kubeconfig ./secrets/vks.kubeconfig config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
kubectl --kubeconfig ./secrets/vks.kubeconfig get deploy,sts,svc -A | grep -iE 'argocd|harbor' \
  || echo 'NONE in the guest — this is the EXPECTED answer'
# the SUPERVISOR (the context from step 6):
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
kubectl get ns
```

**Expect:** **two different API-server URLs**; ArgoCD + Harbor on the **Supervisor**; **nothing ArgoCD-shaped in the guest**.
**Send back:** both API URLs (note the subnets — they pre-answer step 19) · where ArgoCD/Harbor actually run.

> **If ArgoCD IS in the guest, or the URLs are the same — STOP AND REPORT.** The cross-cluster machinery is dead weight and everything downstream answers the wrong question.

### 9. Produce `$ARGOCD_KUBECONFIG` · CHEAP · ⚠️ UNVERIFIED

**Why:** the artifact the whole cross-cluster design consumes. Its script carries the *second* contradictory `vcf` shape **and** an undocumented requirement: it FATALs unless `VKS_CA_CERT_FILE` or `VKS_INSECURE_SKIP_TLS_VERIFY=1` is set — **which the doc never tells you**.
**Where:** jump box → **Supervisor**. Writes one file under `./secrets/`.
**Who needs it:** BOTH.
**We then:** document the `VKS_CA_CERT_FILE` requirement the runbook never mentions, and — if the CLI writes to `~/.kube/config` instead — make the script extract the context rather than trust the flag.

```bash
cp -n ~/.kube/config ~/.kube/config.bak 2>/dev/null || true   # the CLI may write here — back it up
cp -n ./secrets/vks.kubeconfig ./secrets/vks.kubeconfig.bak
# .env: ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig ; ARGOCD_NAMESPACE=<the A2 vSphere Namespace>
#       and EITHER VKS_CA_CERT_FILE=<supervisor CA> OR VKS_INSECURE_SKIP_TLS_VERIFY=1
make fetch-argocd-kubeconfig 2>&1 | tee /tmp/09-fetch-argocd-kc.log; echo "EXIT=$?"
#   ⚠️ if it errors on a flag: just COPY the Supervisor kubeconfig you already have to
#      ./secrets/argocd.kubeconfig. We only need the FILE — the script is a convenience.
ls -l ./secrets/argocd.kubeconfig ~/.kube/config ./secrets/vks.kubeconfig
KUBECONFIG=./secrets/argocd.kubeconfig kubectl -n $ARGOCD_NAMESPACE get deploy -l app.kubernetes.io/part-of=argocd
```

**Expect:** the file lands where you asked (**not** in `~/.kube/config`), and ArgoCD's deployments are visible through it.
**Send back:** the log (success **or** the exact failure — both are results) · the `ls -l` (did it clobber anything?).

### 10. Will the guest cluster actually accept our install? · CHEAP, READ-ONLY

**Why:** four preconditions the runbook *lists* but gives no command for. **No default StorageClass → Gitea hangs. No CRD rights → Tekton can't install. No LoadBalancer → `make gitops` can never work.**
**Where:** jump box → **guest cluster**.
**Who needs it:** **YOU — each FAIL is a STOP.**
**We then:** turn these four into a real preflight check with actionable errors, instead of a bulleted list in the runbook with no command behind it.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl auth can-i '*' '*' --all-namespaces
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io
kubectl get storageclass
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
```

**Expect:** all `yes` · **one StorageClass marked `(default)`** · LoadBalancer Services with real EXTERNAL-IPs.
**Send back:** every `can-i` answer · the StorageClass list · the LB Services **with their subnet** (compare to step 8's Supervisor URL — it pre-answers step 19).

### 11. May we write Applications into the ArgoCD namespace, and does our manifest survive? · CHEAP, READ-ONLY

**Why:** Scenario 1's default path is `kubectl` into the Supervisor. Never demonstrated. And our Application manifest has only ever met an upstream 3.x KinD ArgoCD.
**Where:** jump box → **Supervisor** (the ArgoCD vSphere Namespace).
**Who needs it:** BOTH.
**We then:** if `can-i` is **no**, we make `ARGOCD_MECHANISM=api` the **documented default** for Scenario 1 (it needs no Kubernetes RBAC there). If the dry-run rejects a field, we fix `k8s/argocd/application.yaml` **before** you install anything.

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
kubectl --kubeconfig $KC auth can-i create applications.argoproj.io -n $ARGOCD_NAMESPACE
kubectl --kubeconfig $KC auth can-i create appprojects.argoproj.io  -n $ARGOCD_NAMESPACE
# does our manifest survive THIS server? --dry-run=server runs full admission, persists NOTHING.
export ARGOCD_PROJECT=default APP_NAME=probe APP_NAMESPACE=probe ARGOCD_TRACK_BRANCH=main \
       DEPLOY_REPO_CLONE_URL=http://example.invalid/x.git \
       ARGOCD_DEST_KEY=server ARGOCD_DEST_VALUE=https://kubernetes.default.svc
envsubst < k8s/argocd/application.yaml > /tmp/probe-app.yaml
grep -nE 'namespace:|project:' /tmp/probe-app.yaml     # sanity: NO blank values
kubectl --kubeconfig $KC apply --dry-run=server -f /tmp/probe-app.yaml
```

**Expect:** `can-i create applications` = **yes**, and the dry-run is **accepted**.
**Send back:** the three `can-i` answers · the dry-run output **including WARNINGS** (the warnings are frequently the finding).

> **`can-i` = no even for the vSphere admin?** Then kubectl-into-the-Supervisor is impossible and `ARGOCD_MECHANISM=api` is the only path — a design finding you got in 30 seconds instead of after a 30-minute install.

### 12. Does this cluster really enforce PSA `restricted`? · CHEAP, READ-ONLY

**Why:** our root Kaniko build pods get **rejected** unless we label namespaces `baseline`. KinD enforces nothing, so this has **never been observed**. `make psa-check` **cannot** settle it pre-install (it skips namespaces that don't exist and would print "OK" having measured zero pods).
**Where:** jump box → **guest cluster**. Creates one throwaway namespace, deletes it.
**Who needs it:** BOTH.
**We then:** confirm `PSA_LEVEL_CI` / `PSA_LEVEL_INGRESS=baseline` are load-bearing — or, if the cluster accepts a root pod unlabelled, **re-grade our PSA claim as overstated**. If even `baseline` is rejected, `ci` needs `privileged` (or Kaniko must go) — a `.env.example` change we make **before** you mirror.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl create namespace psa-probe
kubectl get ns psa-probe --show-labels
# a ROOT pod (the Kaniko shape). --dry-run=server: admission evaluates, nothing is scheduled.
kubectl -n psa-probe run rootprobe --image=busybox --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"rootprobe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
kubectl label ns psa-probe pod-security.kubernetes.io/enforce=baseline --overwrite
kubectl -n psa-probe run rootprobe --image=busybox --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"rootprobe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
kubectl delete namespace psa-probe
```

**Expect:** **REJECTED** before the label, **ACCEPTED** after. That RED→GREEN pair is the whole point.
**Send back:** both dry-run outputs **verbatim**, and `--show-labels` on the fresh namespace.

### 13. Istio — and the Gateway-API question · CHEAP, READ-ONLY

**Why:** our README asserts Broadcom routes with the **Kubernetes Gateway API**. That decides whether a tenant can just deploy, or must **ask the mesh admin** for a gateway. It also decides whether the KinD e2e proves anything at all.
**Where:** jump box → **guest cluster** (Istio is a *guest*-cluster package, not a Supervisor Service).
**Who needs it:** **US, badly** — this is the biggest open risk in the repo.
**We then:** if the Gateway-API CRDs are **absent**, our README's central tenant claim is **wrong** — we rewrite it and build an `ISTIO_SHARED_GATEWAY` flow where the tenant must request a gateway. **We also learn whether our KinD e2e proves anything at all**: on KinD those CRDs are installed by cloud-provider-kind, not by us, so the path we advertise as verified may not exist on a lab.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
# ⚠️ UNVERIFIED (the vcf forms) — if BOTH error, send us the --help from step 3. Do not guess.
vcf package available list -A 2>&1 | grep -i istio || vcf addon list --cluster-name "$VKS_CLUSTER_NAME" 2>&1 | grep -i istio
kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# is there any shared gateway? (a Service on port 15021 with a spec.selector.istio key)
kubectl get svc -A -o json | jq -r '.items[] | select(any(.spec.ports[]?; .port==15021)) | "\(.metadata.namespace)/\(.metadata.name) selector.istio=\(.spec.selector.istio)"'
# THE QUESTION:
kubectl get crd | grep gateway.networking.k8s.io
kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'; echo
make istio-preflight 2>&1 | tee /tmp/13-istio-preflight.log
```

**Expect:** most likely **Istio is not installed at all** (it is a package *you* install) — that is a legitimate answer, and it means (b) and (c) cannot be settled until you install it.
**Send back:** the package/addon listing **with exact name + version strings** · the Gateway-API CRD list · the GatewayClass Accepted status · the 15021 result (**empty = the shared gateway really is off**) · the istio-preflight log.

> **If the Gateway-API CRDs are ABSENT**, the gateway-api path is impossible here — and combined with the shared gateway being off, **a tenant is blocked** and must request a gateway from the mesh admin. That forces a README rewrite. It is the answer we most need.

### 14. Does `make preflight` actually pass on a real lab? · CHEAP

**Why:** it is the composite gate `make install-all` runs **first**. It once **died on every real-lab first run** by blocking on a value that only exists *later*. Fixed; never verified.
**Where:** jump box. `env-validate` dials the cluster + Harbor; nothing is written.
**Who needs it:** BOTH.
**We then:** every var `env-check` demands that the runbook never mentioned becomes a documented step. If preflight blocks on a later-discovered value, the ordering regression is back and we fix it that day.

```bash
set -a; . ./.env; set +a
make env-check    2>&1 | tee /tmp/14-env-check.log;    echo "EXIT=$?"
make env-validate 2>&1 | tee /tmp/14-env-validate.log; echo "EXIT=$?"
make preflight    2>&1 | tee /tmp/14-preflight.log;    echo "EXIT=$?"
```

**Expect:** `preflight` **EXIT=0**, and `argocd-preflight` prints **TOPOLOGY OK** (agreeing with step 8).
**Send back:** all three logs + exit codes — **and any var `env-check` demands that the runbook never told you to set** (a known suspect: `VKS_CA_CERT_FILE`).

> **If preflight blocks on a value that only exists later — STOP AND REPORT. Do not work around it.** The ordering regression is back.

### 15. 🛑 THE GATE — STOP HERE AND SEND US EVERYTHING

**Why:** steps 1–14 cost you an hour, almost all of it work you had to do anyway. They settle the topology, the `vcf` argv, ArgoCD's version and our write rights, PSA, Istio, Harbor's cert, and every guest precondition. **Step 16 costs 30–40 minutes and can only be spent once.**
**Where:** jump box. Nothing runs — you are packaging logs.
**Who needs it:** BOTH. A design error found here costs us one email. Found at step 20, it costs your afternoon.
**We then:** read every artifact, **re-grade each claim** in `docs/vks-services/*.md`, fix whatever your evidence refutes, and **send you back a revised Phase 2** — or tell you the design is confirmed and to proceed. You get a written answer before you spend the 40 minutes.

```bash
tar czf /tmp/phase1-evidence.tgz /tmp/*.log /tmp/probe-app.yaml 2>/dev/null; ls -l /tmp/phase1-evidence.tgz
```

**Expect:** nothing runs. This is a pause.
**Send back:** the tarball **plus the inline pastes** listed in each step above. **Do not summarise, do not paraphrase an error, do not omit warnings.** You send artifacts; we compute verdicts.

## Phase 2 — the expensive half. Only after we reply

### 16. The mirror · SLOW (~20–40 min, ~34 images) — the only long step

**Why:** does `crane` push over real self-signed HTTPS with our sudo-free trust bundle, and can `make harbor-robot` mint a least-privilege robot on a VMware-built Harbor?
**Where:** jump box → **Harbor** (a lot of pushing). **Run it alone on that box.**
**Who needs it:** BOTH.
**We then:** upgrade the air-gap mirror path to `lab-verified` against a real VMware Harbor. A 403 from `harbor-robot` means our sysadmin detection is wrong on the VMware build — we fix the fallback.

⚠️ **RUN IT ALONE.** Not because concurrency corrupts blobs — that was a **misdiagnosis** (corrected 2026-07-13: the mirror was destroyed by our own Harbor install rolling an `emptyDir` registry, while a surviving Redis descriptor cache made the re-push a silent no-op, with **zero** concurrent load). Run it alone because a shared cluster + registry makes any failure unattributable. `make mirror` now ends in `mirror-verify`.

```bash
set -a; . ./.env; set +a
make harbor-robot 2>&1 | tee /tmp/16-harbor-robot.log; echo "EXIT=$?"
ls -l secrets/harbor-robot.env      # 0600, never printed
# copy its two lines into .env, then:
make mirror        2>&1 | tee /tmp/16-mirror.log;        echo "EXIT=$?"
make mirror-verify 2>&1 | tee /tmp/16-mirror-verify.log; echo "EXIT=$?"
```

**Expect:** ~34 images pushed, `mirror-verify` clean. A TLS failure shows up **in the first minute**.
**Send back:** the robot log (system-level, project-scoped, or 403?) and the robot **NAME** (never the secret) · the mirror log's first 40 lines + tail · the verify result.

**Creates:** the `cicd` + `apps` Harbor projects and a robot account (additive; deletable from the Harbor UI).

### 17. Does the guest cluster auto-trust Harbor's cert? · CHEAP — MUST RUN BEFORE step 18

**Why:** we claim a same-Supervisor VKS cluster **auto-trusts** the Harbor cert with no per-node wiring (graded *community*). KinD cannot show it. **If it is false, the next step ImagePullBackOffs** and the remedy rolls your worker nodes.
**Where:** jump box → **guest cluster**. Schedules one real pod in the guest (then deletes it).
**Who needs it:** **YOU — this is why it runs before `make platform`.**
**We then:** upgrade `harbor.md`'s auto-trust claim from *community* to `lab-verified` — **or**, on x509, **promote `trust.additionalTrustedCAs` from a footnote to a required step** in the runbook. If the Cluster CR has no `trust` field at all, we are documenting a field that does not exist and must correct it.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl create ns trust-probe 2>/dev/null || true
kubectl label ns trust-probe pod-security.kubernetes.io/enforce=baseline --overwrite  # so PSA can't masquerade as TLS
kubectl -n trust-probe run harbor-trust-probe \
  --image=$HARBOR_URL/$HARBOR_INFRA_PROJECT/eclipse-temurin:$TEMURIN_JRE_TAG --restart=Never --command -- sleep 5
sleep 45
kubectl -n trust-probe describe pod harbor-trust-probe | tail -25
kubectl delete ns trust-probe
```

**Expect — the Events section is the answer, and the three outcomes mean different things:**

| Event | Means |
|---|---|
| `Successfully pulled image` | **auto-trust CONFIRMED** |
| `x509: certificate signed by unknown authority` | **NO auto-trust** — apply `trust.additionalTrustedCAs` to the Cluster CR **before step 18** |
| `unauthorized` / `401` | a **credential** problem, not a CA one — set `HARBOR_PUBLIC_PROJECTS` or add the pull secret and re-probe |

**Send back:** the pod STATUS and the **Events** section, verbatim.

### 18. Builder image + Gitea + Tekton · MEDIUM (~5–10 min)

**Why:** the first real workloads on a PSA-enforcing cluster — and the step that gives Gitea its **own LoadBalancer** (step 19 needs that VIP).
**Where:** jump box builds + pushes the builder image → **Harbor**; `make platform` installs into the **guest cluster**.
**Who needs it:** YOU.
**We then:** fix whichever of the four failure shapes you hit (Harbor trust · PSA labels · StorageClass · Tekton RBAC) — each maps to a specific default we ship.

```bash
set -a; . ./.env; set +a
make builder-image 2>&1 | tee /tmp/18-builder.log;  echo "EXIT=$?"
make platform      2>&1 | tee /tmp/18-platform.log; echo "EXIT=$?"
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl -n gitea get pod,svc,pvc
kubectl get ns gitea ci --show-labels
```

**Expect:** Tekton's CRDs install · Gitea's PVC **binds** · `gitea-http` gets an **EXTERNAL-IP** (write it down).
**Send back:** both logs + exit codes · the Gitea pod/Service/PVC state · the PSA labels our installers applied.

### 19. 🎯 Can the Supervisor reach a guest LoadBalancer VIP? · CHEAP — THE ONE KinD CANNOT SETTLE

**Why:** ArgoCD's repo-server runs on the **Supervisor** and must clone from Gitea's **guest** LB VIP on port 3000. Our whole clone-URL design assumes yes. **If no, `make gitops` can never work.**
**Where:** jump box → **Supervisor**, but the probe itself runs **INSIDE the ArgoCD repo-server POD** (`kubectl exec`). That is the point: only that pod can answer whether *it* can reach the guest VIP.
**Who needs it:** **BOTH — the single most valuable negative result the lab can produce.**
**We then:** upgrade the clone-URL design to `lab-verified` — **or**, if it cannot route, **redesign git hosting entirely** (Gitea must live where the Supervisor can reach it) and make `GITEA_ARGOCD_URL_OVERRIDE` mandatory rather than an escape hatch. This is the single most valuable thing your lab can tell us.

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
VIP=$(kubectl --kubeconfig ./secrets/vks.kubeconfig -n ${GITEA_NAMESPACE:-gitea} get svc gitea-http \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo "gitea LB VIP = $VIP"
RS=$(kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get deploy -l app.kubernetes.io/component=repo-server -o name | head -1)
# the REAL protocol, from the REAL pod. git IS in that image; curl and wget are NOT.
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE exec $RS -- \
  git ls-remote http://$VIP:3000/vks/javawebapp-deploy.git 2>&1 | head -5
```

**Expect:** a ref listing — **or any git/HTTP-level error** (`401`, `404`, `repository not found`). Those all mean it **REACHED** Gitea, which is all we need.
**Send back:** the VIP · the repo-server's real name · the `git ls-remote` output verbatim.

> **`Connection timed out` / `Could not resolve host` / `Failed to connect` ⇒ the Supervisor CANNOT route to guest LB VIPs. STOP AND REPORT.** Do not push on to step 20. `GITEA_ARGOCD_URL_OVERRIDE` becomes mandatory rather than an escape hatch.

### 20. GitOps wiring — and the proof the clone happened · CHEAP

**Why:** `.status.sync.revision` is set **only after repo-server actually fetched**. It is proof, not a proxy.
**Where:** jump box → **Supervisor** (creates the Application) **and → guest** (registers it as the destination).
**Who needs it:** BOTH.
**We then:** a non-empty `REV` upgrades the two-cluster GitOps design to `lab-verified`. A destination/AppProject rejection in the conditions is the thing step 11's dry-run **structurally cannot** catch — we fix the manifest from your capture.

⚠️ **This step makes a durable, security-relevant change to your lab.** `make argocd-register-guest` mints an `argocd-manager` ServiceAccount + a **cluster-admin ClusterRoleBinding** + a **non-expiring token** in your guest cluster's `kube-system`. Opt out with `ARGOCD_REGISTER=never`. **Teardown is step 24.**

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get secret -l argocd.argoproj.io/secret-type=cluster   # what exists BEFORE
make gitops 2>&1 | tee /tmp/20-gitops.log; echo "EXIT=$?"
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get application \
  -o custom-columns='NAME:.metadata.name,REV:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Expect:** **`REV` is a real git SHA**, not empty.
**Send back:** the Application table · every Application **condition message** · the pre-existing cluster secrets.

### 21. 🏁 THE SYSTEM · MEDIUM (~5–10 min)

**Why:** `git push → Tekton → Kaniko → Harbor → tag write-back → ArgoCD sync (Supervisor→guest) → the app serves the change`. Every step above settles a component; **this settles the whole thing.**
**Where:** jump box drives it; the work happens in the **guest cluster** (Tekton) and **Harbor**, and ArgoCD syncs from the **Supervisor**.
**Who needs it:** **BOTH. This is the deliverable.**
**We then:** EXIT=0 retroactively upgrades a dozen inferred facts to `lab-verified`, and the demo is **proven on real infrastructure** — which is the entire point of the repo.

```bash
set -a; . ./.env; set +a
make verify 2>&1 | tee /tmp/21-verify.log; echo "EXIT=$?"
# on failure, the diagnosis is one of exactly three shapes:
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl -n ci get taskrun,pipelinerun
kubectl -n ci describe pod -l tekton.dev/pipelineRun | tail -30
```

**Expect:** **EXIT=0** — the air-gapped VKS CI/CD demo works on real infrastructure.
**Send back:** the verify log. **On failure**, the failing pod's **Events**: `violates PodSecurity "restricted"` = PSA · `x509`/`ImagePullBackOff` = Harbor trust · a named URL = the clone path.

### 22. Are our PSA levels right against REAL pods? · CHEAP, READ-ONLY

**Why:** `psa-check` measures the minimum admissible level per namespace. It says in its own source that it must be run on a real VKS cluster. It never has.
**Where:** jump box → **guest cluster**. Read-only (server-side dry-run).
**Who needs it:** US.
**We then:** fix any `PSA_LEVEL_*` default your table proves wrong, and finally answer the open question of whether the VMware-built Istio proxy sets a `seccompProfile`.

```bash
set -a; . ./.env; set +a
make psa-check 2>&1 | tee /tmp/22-psa-check.log; echo "EXIT=$?"
```

**Expect:** EXIT=0 — every namespace we create is labelled at a level the real cluster admits.
**Send back:** the whole table **and every `why not restricted:` line** (that is ground truth for the Istio-proxy seccompProfile question).

### 23. Can a tenant attach to a mesh they don't own? · CHEAP

**Why:** the tenant-facing headline — and the **second half of the Gateway-API question**. Plus: does the auto-provisioned gateway proxy pull `proxyv2` from **Harbor** (air-gap) or from the internet?
**Where:** jump box → **guest cluster**.
**Who needs it:** **US** — it is the README's load-bearing claim.
**We then:** confirm the README's tenant claim — **or**, if the proxy pulls from `docker.io`/`gcr.io`, we must **mirror and override the auto-provisioned gateway's image**, because it will not pull on an air-gapped cluster. That is a real gap in the design, and only a lab can show it.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
make istio-preflight 2>&1 | tee /tmp/23-istio-preflight.log
make install-ingress INGRESS_CONTROLLER=istio-existing 2>&1 | tee /tmp/23-attach.log; echo "EXIT=$?"
#   ⚠️ ONLY this mode if a mesh YOU DID NOT INSTALL is present. If step 13 found no mesh, then
#      `make install-ingress` (our own istio) or INGRESS_CONTROLLER=traefik is correct and safe.
#      NEVER run the bare `make install-ingress` against a mesh you did not install — it would
#      helm-install a SECOND istiod over it.
kubectl -n ${ISTIO_GWAPI_NAMESPACE:-vks-ingress} get pod -l gateway.networking.k8s.io/gateway-name \
  -o jsonpath='{.items[0].status.containerStatuses[0].image}'; echo
# add the printed INGRESS_LB_IP to /etc/hosts, then:
make verify-ingress 2>&1 | tee /tmp/23-verify-ingress.log; echo "EXIT=$?"
```

**Expect:** the attach **installs nothing** and the URLs serve.
**Send back:** which route API it chose (gateway-api or classic) · **the running proxy pod's IMAGE** — is the host our Harbor, or `docker.io`/`gcr.io`? · verify-ingress per host.

> **A proxy image pointing at docker.io/gcr.io ⇒ the auto-provisioned gateway will NOT pull on an air-gapped cluster.** We would have to mirror and override it — a real gap in the design.

### 24. Give you your lab back · OPTIONAL, CHEAP

**Why:** nothing above is auto-cleaned, and **step 20 left a durable cluster-admin credential**.
**Where:** jump box → **guest cluster** and **Supervisor** (deletes only what this run created).
**Who needs it:** YOU.
**We then:** nothing — this one is purely for you.

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
# the ArgoCD registration credential from step 20:
kubectl -n kube-system delete clusterrolebinding argocd-manager-role-binding 2>/dev/null || true
kubectl -n kube-system delete sa argocd-manager 2>/dev/null || true
kubectl -n kube-system delete secret -l kubernetes.io/service-account.name=argocd-manager 2>/dev/null || true
kubectl --kubeconfig ./secrets/argocd.kubeconfig -n $ARGOCD_NAMESPACE delete secret -l argocd.argoproj.io/secret-type=cluster
# our workloads (leave them if you want the demo alive):
kubectl --kubeconfig ./secrets/argocd.kubeconfig -n $ARGOCD_NAMESPACE delete application --all
kubectl delete ns gitea ci tekton-pipelines ${ISTIO_GWAPI_NAMESPACE:-vks-ingress} javawebapp gowebapp 2>/dev/null || true
# Harbor: delete the robot + the cicd/apps projects from the Harbor UI if you want them gone.
# DO NOT run `make kind-down` on this box — it is the LOCAL teardown and removes files under ./secrets.
```

**Expect:** the ClusterRoleBinding and the cluster Secret are gone.
**Send back:** nothing. Just confirm.

**Does NOT touch** Harbor, ArgoCD, Contour, the Istio package, or your cluster itself.

## Stop and come back to us if…

- **Step 15 is a HARD gate.** Do not start the mirror until we have confirmed the design survives your Phase-1 evidence.
- **Any `vcf` command errors** — send the `--help` output. Do not fight our guess. We ship two contradictory forms of `vcf context create`, neither has ever run, and this repo has shipped a fabricated `vcf` command before.
- **Step 8** finds ArgoCD in the guest, or **step 19** cannot reach the VIP. Both invalidate the design; everything after them answers the wrong question.
