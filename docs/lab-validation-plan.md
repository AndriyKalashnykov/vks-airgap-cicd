# VKS lab run — the validation plan (Scenario 1)

<br>
**Read this before you start.** It is not a runbook — it is a *validation* plan. Every step
settles a claim this repo currently **cannot verify**, and asks you to capture evidence we act on.
The runbook itself is [Scenario 1](scenario-1.md); this rides alongside it.

> **This plan was adversarially reviewed** — three drafts were attacked for wasted steps, fabricated
> commands, and anything that could damage your lab, then adjudicated into one. Where we have never run a
> command, it says **UNVERIFIED-COMMAND** and gives you a fallback. We would rather learn the real CLI
> shape than have you fight our guess.

## Why it is ordered this way

ORDERING PRINCIPLE. Three things drove this plan.

(1) **Walk the runbook, don't bypass it.** In Scenario 1 the operator MUST install Harbor + ArgoCD as Supervisor Services and provision the VKS cluster (docs/scenario-1.md A1/A2/A3). They have to do that anyway — so we ride it, and every divergence between the doc and the vSphere Client they actually see is free evidence about the least-verified prose we ship. A plan that starts at "assume ./secrets/vks.kubeconfig exists" throws that away.

(2) **Read-only before write, and NEVER trust our own command shapes.** Every step that touches the `vcf` CLI is marked **UNVERIFIED-COMMAND**: we ship TWO CONTRADICTORY forms of `vcf context create` (scripts/30-vks-login.sh:70-84 uses an interactive name + `--auth-type basic`; scripts/31-fetch-argocd-kubeconfig.sh:63-67 uses a positional name + `--type k8s` + `--ca-certificate`) — at most one can be right, neither has ever run, and this repo has shipped a fabricated `vcf` command before. So step 3 dumps `vcf … --help` VERBATIM **before** any `vcf` command is typed in anger, and every `vcf` step carries "if this errors, send us the --help output and use the fallback".

(3) **DO NOT run `make install-all` as one 30-40 minute monolith.** Its stages already exist as separate targets (Makefile:407), and running them separately is what lets us settle two claims at the exact moment they become observable and BEFORE the thing that depends on them:

- **Harbor CA auto-trust** (harbor.md:24-27, graded *community*) is observable right after `make mirror` and BEFORE `make platform` — which pulls Gitea FROM Harbor. If auto-trust is false, `platform` ImagePullBackOffs and the remedy (`trust.additionalTrustedCAs` on the Cluster CR) rolls their worker nodes. Probe it first.
- **Supervisor → guest LoadBalancer reachability** — the ONE claim KinD structurally cannot settle, and the premise of `gitea_clone_url()` (lib/argocd.sh:153-165). It becomes observable the moment `make platform` gives Gitea its own LB, and we probe it BEFORE `make gitops`, on the EXACT port (3000) and the EXACT protocol (git-over-HTTP) ArgoCD will use — from inside the real repo-server pod, with `git ls-remote` (git IS in that image; curl/wget are NOT — a probe using curl there would print "not found" and we would tear up the architecture on the strength of a missing binary).

Three cross-cutting rules the commands obey:

- **Every raw command block begins with `set -a; . ./.env; set +a`.** `$ARGOCD_NAMESPACE`, `$HARBOR_URL`, `$TEMURIN_JRE_TAG` etc. live in `.env` and are materialised inside scripts by `load_env` — in a bare interactive shell they are EMPTY, and an empty var in an `envsubst` render silently produces `namespace:` blank (this repo has been bitten by exactly that).
- **Never hardcode ArgoCD's workload names.** The VKS ArgoCD is operator-managed and may name things `<CR-name>-server` / `<CR-name>-repo-server`. We discover by LABEL (`-l app.kubernetes.io/part-of=argocd`) and capture the real names — if they differ from `argocd-server`, that is a bug in OUR scripts (31-fetch-argocd-kubeconfig.sh:77 hardcodes it), not a broken lab.
- **Capture the tool's own output, never a verdict.** `--help` blocks, `describe` Events, image tags, `explain` lists, cert SANs — raw. We compute the conclusions.

Honesty about cost: steps 1-14 are CHEAP (minutes each, all read-only or their-own-vSphere-work) and settle 7 of the 8 headline claims. Step 16 (`make mirror`) is the only SLOW one (~20-40 min, ~34 images) and must run ALONE. Steps 19-24 are minutes each.

## The steps

### 1. CHEAP. The runbook's entry point: does a fresh clone + `make env-init` + `make check-tools` actually work on a lab jump box? (docs/scenario-1.md:48-62 claims the four upfront vars are all you need at this point.) `check-tools` has never run on a lab

```bash
git clone <this-repo> && cd vks-airgap-cicd
make env-init                      # creates .env from .env.example (backs up any existing one)
make check-tools 2>&1 | tee /tmp/01-check-tools.log; echo "EXIT=$?"
# now edit .env and set ONLY the four vars the doc names at this point:
#   SUPERVISOR_HOST=<supervisor control-plane IP>
#   VKS_USERNAME=administrator@vsphere.local
#   VKS_NAMESPACE=<the vSphere Namespace you will use>
#   VKS_CLUSTER_NAME=<the VKS workload cluster you will create in A3>
```

**Capture:** the env-init output; the FULL check-tools table (required vs optional CLIs + versions) + exit code; and — the doc finding — whether those four vars were enough, or you had to go hunting in .env.example for a fifth.

**A PASS proves:** PASS = the runbook's first command works and check-tools tells you what is missing before anything else does.

**A FAIL disproves:** A CLI check-tools demands that the doc never told you to install = a prereq gap in docs/scenario-1.md. env-init clobbering an existing .env = a bug in the very first command we ship.

**Safe because:** Writes only ./.env in the repo (existing one backed up to .env.bak). check-tools is read-only. Touches no lab infrastructure.

### 2. CHEAP. Do the version pins in .env.example (ARGOCD_VCF_VERSION / VCF_CLI_VERSION / VCF_PLUGINS_VERSION) match the artifacts the Broadcom 9.1 portal actually serves, and does our OS/arch auto-select work on a real, unpruned download folder? (docs/scenario-1.md:277-283 promises exactly that; scripts/01-install-vcf-clis.sh has never seen a real archive.) This runs FIRST because every later `vcf` step needs the binary

```bash
make deps                                   # mise toolchain + tar/gzip/findutils the installer needs
ls -1 <the folder where you dropped the licensed Broadcom archives>
make install-vcf-clis VCF_CLI_SRC_DIR=<that folder> 2>&1 | tee /tmp/02-install-vcf-clis.log; echo "EXIT=$?"
```

**Capture:** the FULL `ls -1` (the filenames encode OS/arch/version — we need them verbatim); the whole installer log (which archive did it pick?).

**A PASS proves:** PASS = the pins are the real 9.1 artifact versions and the resolver picks the right archive from a mixed folder → upgrade those pins to lab-verified.

**A FAIL disproves:** 'pinned version not present' = the portal ships different versions → we re-pin from your captured filenames and add them as fixtures to scripts/test-vcf-cli-resolve.sh. A wrong-arch pick = a resolver bug.

**Safe because:** Installs sudo-free into ~/.local/bin. Reads a folder you already downloaded. No lab contact.

### 3. CHEAP, AND THE HIGHEST-VALUE 60 SECONDS IN THE RUN. **UNVERIFIED-COMMAND (all of it).** The REAL argv of the `vcf` CLI. We ship two CONTRADICTORY shapes of `vcf context create` (30-vks-login.sh: interactive name + `--auth-type basic`; 31-fetch-argocd-kubeconfig.sh: positional name + `--type k8s` + `--ca-certificate`). At most one is right. Also settles `vcf cluster kubeconfig get --export-file` (used in A3) and whether an Istio package/addon subcommand exists at all

```bash
vcf version || vcf --version || true      # do NOT run a bare `vcf` — it can block on stdin and hold a session
vcf --help
vcf context --help
vcf context create --help
vcf context use --help
vcf context list --help
vcf cluster --help
vcf cluster kubeconfig get --help
vcf package --help  2>&1 | head -40
vcf addon   --help  2>&1 | head -40
```

**Capture:** EVERY --help block VERBATIM. Do not summarise — the flag lists ARE the deliverable. If a subcommand does not exist, paste the exact error text; that is also an answer.

**A PASS proves:** We get the version-true argv: is the context name positional or prompted? do `--auth-type basic` / `--type k8s` / `--ca-certificate` exist? is there a NON-INTERACTIVE password mechanism (stdin/file — if so we adopt it; a password on argv stays forbidden)? does `vcf package install` exist (the Istio Standard-Package claim)?

**A FAIL disproves:** ANY flag we ship that is absent from --help is a FABRICATION. Send us the help output and we rewrite both scripts before you run steps 7/9. Do not fight our guess — we would rather learn the real shape.

**Safe because:** --help only. Contacts nothing, changes nothing. Never run a bare `vcf` with no arguments.

### 4. THEIR OWN vSPHERE WORK (unavoidable in Scenario 1; ~30-60 min). docs/scenario-1.md A1: Harbor as a Supervisor Service. Claims to settle: Contour must be installed FIRST (itself a Supervisor Service) as Harbor's ingress ON THE SUPERVISOR; the `harbor-data-values` field set we list is right (hostname FQDN, secretKey exactly 16 chars, core.xsrfKey 32, five storage classes, enableContourHttpProxy vs enableNginxLoadBalancer); leaving `tlsCertificate` alone makes cert-manager self-issue and the `managed-by: vmware-vRegistry` label is 'required for VKS trust'. ALL of this is 9.0-doc-inferred prose nobody has executed

```bash
# Follow docs/scenario-1.md §A1 in the vSphere Client. Report, per numbered sub-step:
#   1. Was Contour really required first? Did the Harbor service offer the NGINX option too?
#   2. Paste the harbor-data-values template the portal ACTUALLY shipped (redact secrets)
#      so we can diff it against the field list in our doc. Any REQUIRED field we omit?
#   3. Did the 16-char secretKey / 32-char xsrfKey constraints hold? (any validation error text)
# Then find the ingress IP:
kubectl get svc -A | grep -iE 'harbor|envoy|contour'
```

**Capture:** the real harbor-data-values field list; any validation errors; which Service carries the ingress IP; and the Harbor FQDN you chose + the /etc/hosts or DNS record you added.

**A PASS proves:** PASS = A1 is followable as written → the Harbor install facts in docs/vks-services/harbor.md upgrade to lab-verified.

**A FAIL disproves:** Any required field our doc omits, or a constraint that does not hold, is a doc defect we fix that day. If the `managed-by: vmware-vRegistry` label is applied for you (or is not load-bearing), we are overstating a community claim.

**Safe because:** Your own vSphere Client work, on your own lab. Nothing this repo runs.

### 5. CHEAP, READ-ONLY. Harbor's real addressing + our rights on it: is the endpoint FQDN- or IP-addressed and does the self-signed cert's SAN match HARBOR_URL (harbor.md:94-96 — decides whether our KinD SAN=IP stand-in is faithful)? Are we a Harbor SYSTEM admin (which decides whether `make harbor-robot` can mint a robot spanning BOTH mirror projects — scripts/lib/harbor.sh `harbor_is_sysadmin`)?

```bash
# Set in .env first: HARBOR_URL / HARBOR_USERNAME / HARBOR_PASSWORD / HARBOR_CA_FILE=./secrets/harbor-ca.crt
#                    HARBOR_INFRA_PROJECT=cicd / HARBOR_APP_PROJECT=apps
set -a; . ./.env; set +a
make fetch-harbor-ca
openssl x509 -in secrets/harbor-ca.crt -noout -subject -issuer -ext subjectAltName
curl -sS --cacert secrets/harbor-ca.crt https://$HARBOR_URL/api/v2.0/systeminfo | head -c 400; echo
curl -sS --cacert secrets/harbor-ca.crt -u "$HARBOR_USERNAME" https://$HARBOR_URL/api/v2.0/users/current | head -c 400; echo   # curl PROMPTS for the password — never on argv
```

**Capture:** the cert SUBJECT + ISSUER + SAN; the systeminfo JSON (its `harbor_version` is the real product version); the users/current JSON — specifically `sysadmin_flag`.

**A PASS proves:** PASS = `make fetch-harbor-ca` works against a real VMware-built Harbor and the SAN covers HARBOR_URL. `sysadmin_flag:true` ⇒ step 15's robot will span both projects.

**A FAIL disproves:** SAN mismatch ⇒ every later `crane`/curl against HARBOR_URL fails TLS: the doc must tell the operator WHICH name to use. `sysadmin_flag:false` ⇒ our sysadmin detection must degrade to per-project robots on a VMware Harbor.

**Safe because:** Read-only: one TLS handshake and two GETs. Mints nothing.

### 6. THEIR OWN WORK + CHEAP PROBES. docs/scenario-1.md A2: the ArgoCD Operator + an ArgoCD instance. Settles: the operator CRD's real group/name (23-argocd-preflight.sh expects `argocds.argocd-service.vsphere.vmware.com`); the SUPPORTED SERVER VERSIONS (our doc pins `2.14.15+vmware.1-vks.1`, a 2.x line, while the shipped CLI is 3.x and our KinD stand-in runs a 3.x SERVER); the admin-secret's real NAME (we say `argocd-initial-admin-secret`); and — load-bearing for our scripts — the REAL DEPLOYMENT NAMES (an operator-managed instance may name them `<CR>-server` / `<CR>-repo-server`, in which case our hardcoded `argocd-server` lookups are a BUG)

```bash
# Follow A2 steps 1-2 (register the operator Service; create the vSphere Namespace).
# A2 step 3 = the Supervisor login. **UNVERIFIED-COMMAND** — use exactly what step 3's --help showed:
vcf context create --endpoint https://$SUPERVISOR_HOST --username $VKS_USERNAME \
    --insecure-skip-tls-verify --auth-type basic     # ← if this errors, send us `vcf context create --help`
vcf context use <the-context-name>:<the-argocd-vsphere-namespace>
vcf context list
# A2 step 4: pick a version, apply the CR from the doc. Then:
kubectl get crd | grep -i argocd
kubectl explain argocd.spec.version
kubectl -n <argocd-vsphere-ns> get argocd -o yaml | sed -n '1,60p'      # the CR: its NAME and .spec.version
kubectl -n <argocd-vsphere-ns> get deploy,svc,secret -l app.kubernetes.io/part-of=argocd -o wide
kubectl -n <argocd-vsphere-ns> get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
argocd version --client --short
```

**Capture:** whether the doc's `vcf` flags were accepted AS PRINTED; the exact context names `vcf context list` shows (is the `<ctx>:<ns>` COLON form real?); the CRD name; the FULL `explain argocd.spec.version` list; the ArgoCD CR; **the REAL deployment names + their IMAGE TAGS** (ground truth for the server generation — never a doc); the admin-secret's real name; the argocd-server LB EXTERNAL-IP; the CLI version.

**A PASS proves:** PASS = A2 is followable, and we learn the true supported set + the true RUNNING server generation. If the deployments are named `argocd-server`/`argocd-repo-server`, our scripts' lookups are correct.

**A FAIL disproves:** A rejected flag ⇒ the doc's A2 snippet is wrong (rewrite from step 3's help). Differently-named deployments (`<CR>-server`) ⇒ 31-fetch-argocd-kubeconfig.sh:77 and 23-argocd-preflight.sh must discover by LABEL, not name — a real repo bug that would otherwise present as 'the Supervisor kubeconfig doesn't work'. A differently-named admin secret ⇒ our doc's command returns nothing. A 2.x running server ⇒ our KinD 3.x stand-in has a real fidelity gap and we pin KinD to the lab's line.

**Safe because:** Installs the ArgoCD instance YOU intend to install (this IS Scenario 1). All the probes are `get`/`explain`. Note: `--insecure-skip-tls-verify` is our doc's own suggestion — if your lab has a Supervisor CA, prefer it and set VKS_CA_CERT_FILE.

### 7. THEIR OWN WORK + **UNVERIFIED-COMMAND**. docs/scenario-1.md A3: provision the workload VKS cluster and export its kubeconfig with `vcf cluster kubeconfig get $VKS_CLUSTER_NAME --export-file ./secrets/vks.kubeconfig`. That exact flag shape is doc-inferred

```bash
set -a; . ./.env; set +a
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file ./secrets/vks.kubeconfig
#   ↑ if this errors: send us `vcf cluster kubeconfig get --help` (from step 3) and obtain the
#     kubeconfig however you normally do (vSphere UI / VCF Automation / kubectl vsphere login),
#     then place it at ./secrets/vks.kubeconfig. The FAILURE ITSELF is the finding — do not fight it.
kubectl --kubeconfig ./secrets/vks.kubeconfig config get-contexts
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
# then in .env:  KUBECONFIG=./secrets/vks.kubeconfig   and   VKS_CONTEXT=<the context name above>
```

**Capture:** whether `--export-file` is a real flag; the contexts table; the node list.

**A PASS proves:** PASS = the doc's A3 command is real and the guest kubeconfig lands where we ask.

**A FAIL disproves:** A wrong flag ⇒ we correct docs/scenario-1.md:181 and .env.example's `# how:` line from your capture (that line is exactly the kind of fabricated command `make check-how-provenance` exists to prevent).

**Safe because:** Writes ONE file under ./secrets/. Read-only against the cluster.

### 8. CHEAP, READ-ONLY. **TIER-0 CLAIM #1 — THE TOPOLOGY**, the foundation of the whole design: Harbor + ArgoCD are Supervisor Services on a DIFFERENT cluster from the guest (docs/vks-services/argocd.md:3-6; lib/argocd.sh:4-13,48). ARGOCD_KUBECONFIG, `argocd_is_off_cluster()`, `make argocd-register-guest` and the refusal of the in-cluster destination ALL rest on it. NEVER SEEN. Also settles the doc's Step-4 command (`kubectl get pods -A | grep argocd-application-controller`, scenario-1.md:360) which it offers as the way to find ARGOCD_NAMESPACE — run against the GUEST kubeconfig, where ArgoCD does not exist

```bash
set -a; . ./.env; set +a
# The GUEST:
kubectl --kubeconfig ./secrets/vks.kubeconfig config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
kubectl --kubeconfig ./secrets/vks.kubeconfig get ns
kubectl --kubeconfig ./secrets/vks.kubeconfig get deploy,sts,svc -A | grep -iE 'argocd|harbor' \
  || echo 'NONE in the guest — this is the EXPECTED answer'
# The SUPERVISOR (the context you activated in A2 / step 6):
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
kubectl get ns
```

**Capture:** the TWO API-server URLs (different? different subnets? — note them, they pre-answer the routability question); both namespace lists; where argocd-server + harbor actually run; and whether the doc's `grep argocd-application-controller` returns anything at all with the GUEST kubeconfig.

**A PASS proves:** PASS (URLs differ; ArgoCD/Harbor on the Supervisor; nothing ArgoCD-shaped in the guest) = the two-cluster premise is LAB-VERIFIED, `argocd_is_off_cluster()` will correctly return true, and the cross-cluster design is right.

**A FAIL disproves:** Same URL, or ArgoCD in the guest ⇒ the Supervisor-Service premise is FALSE for this lab: the whole cross-cluster machinery is dead weight and `make gitops` should take the in-cluster path. **STOP AND REPORT** — everything downstream would be answering the wrong question. Either way, the doc's ARGOCD_NAMESPACE-discovery command must be re-aimed at the SUPERVISOR kubeconfig.

**Safe because:** Pure `kubectl get` / `config view` on both clusters. Read-only.

### 9. CHEAP. **UNVERIFIED-COMMAND.** Produce `$ARGOCD_KUBECONFIG` — the artifact the entire cross-cluster design consumes (docs/scenario-1.md Step 6; scripts/31-fetch-argocd-kubeconfig.sh). It carries the SECOND, contradictory `vcf context create` shape AND an undocumented requirement: it FATALs unless VKS_CA_CERT_FILE or VKS_INSECURE_SKIP_TLS_VERIFY=1 is set — which the doc never tells you. It also assumes 'the VCF CLI respects KUBECONFIG for writing to alternate locations' (a 9.0 inference)

```bash
cp -n ~/.kube/config ~/.kube/config.bak 2>/dev/null || true      # the CLI may write there — back it up
cp -n ./secrets/vks.kubeconfig ./secrets/vks.kubeconfig.bak       # and this is the file it could clobber
# in .env: ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig ; ARGOCD_NAMESPACE=<the A2 vSphere Namespace>
#          and EITHER VKS_CA_CERT_FILE=<supervisor CA> OR VKS_INSECURE_SKIP_TLS_VERIFY=1
make fetch-argocd-kubeconfig 2>&1 | tee /tmp/09-fetch-argocd-kc.log; echo "EXIT=$?"
#   ↑ if it errors on a flag: send us the error + step 3's `vcf context create --help`, and just COPY
#     the Supervisor kubeconfig you already have (from A2) to ./secrets/argocd.kubeconfig. We only need
#     the FILE — the script is a convenience, not a requirement.
ls -l ./secrets/argocd.kubeconfig ~/.kube/config ./secrets/vks.kubeconfig
KUBECONFIG=./secrets/argocd.kubeconfig kubectl config get-contexts
KUBECONFIG=./secrets/argocd.kubeconfig kubectl -n $ARGOCD_NAMESPACE get deploy -l app.kubernetes.io/part-of=argocd
```

**Capture:** the full log (success OR the exact failure — both are results); the `ls -l` (did the kubeconfig land where we asked, or in ~/.kube/config? did vks.kubeconfig change size?); the contexts table (is `<ctx>:<ns>` real?); and the ArgoCD deployments visible through it.

**A PASS proves:** PASS = the KUBECONFIG-scoping trick works and the Supervisor kubeconfig genuinely reaches ArgoCD → docs/vks-services/argocd.md:104-127 upgrades from 9.0-inferred to lab-verified.

**A FAIL disproves:** Landing in ~/.kube/config ⇒ the script must extract/copy instead. A missing-CA fatal ⇒ the doc MUST tell operators to set VKS_CA_CERT_FILE / VKS_INSECURE_SKIP_TLS_VERIFY. `argocd-server` not visible but `<CR>-server` is ⇒ the script's hardcoded name check is the bug (step 6 already told us).

**Safe because:** Writes ONE file under ./secrets/. Both kubeconfigs backed up first — whether the CLI clobbers them is precisely one of the things we are testing.

### 10. CHEAP, READ-ONLY. The three preconditions docs/scenario-1.md:474-479 LISTS but gives no command for, plus the one that gates `make gitops`: **cluster-admin** on the guest, a **default StorageClass** (Gitea's PVC), a working **LoadBalancer** provider (no LB VIP ⇒ `gitea_clone_url()` can never produce a reachable repoURL ⇒ `make gitops` correctly REFUSES ⇒ the demo cannot run), and **CRD create rights** (Tekton installs cluster-scoped CRDs — the likeliest thing a locked-down lab refuses, and it would kill `make platform` half-way)

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl auth can-i '*' '*' --all-namespaces
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io
kubectl auth can-i create namespaces
kubectl get storageclass
kubectl get svc -A --field-selector spec.type=LoadBalancer -o wide
```

**Capture:** every can-i answer; the StorageClass list (is one marked `(default)`?); every existing LoadBalancer Service WITH its EXTERNAL-IP and the SUBNET (compare that subnet to the Supervisor API address from step 8 — it is the pre-answer to the routability question in step 20).

**A PASS proves:** All yes + a default StorageClass + LB VIPs in use = `make platform` will not be refused, Gitea's PVC will bind, and Gitea can get an off-cluster address.

**A FAIL disproves:** No default StorageClass ⇒ Gitea's PVC never binds and `make platform` hangs — **STOP**. No CRD rights ⇒ Tekton cannot be installed by this identity — **STOP** (get the grant, or the platform team pre-installs Tekton). No LoadBalancer provider at all ⇒ the clone-URL design must change entirely — **STOP**.

**Safe because:** `auth can-i` (the API server answers a question, creates nothing) + two `get`s.

### 11. CHEAP, READ-ONLY. **TIER-0 CLAIM #3** — may we even WRITE Applications into the ArgoCD vSphere Namespace? (70-configure-argocd.sh:88-137 MEASURES this rather than assuming; the measurement has never run.) Plus: is OUR Application manifest ACCEPTED by this (possibly 2.x) server inside a vSphere Namespace that may carry admission policy of its own? It has only ever been applied to an upstream 3.x KinD ArgoCD

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
kubectl --kubeconfig $KC auth can-i create applications.argoproj.io -n $ARGOCD_NAMESPACE
kubectl --kubeconfig $KC auth can-i create appprojects.argoproj.io  -n $ARGOCD_NAMESPACE
kubectl --kubeconfig $KC auth can-i create secrets                  -n $ARGOCD_NAMESPACE
# does our manifest survive THIS server + THIS namespace? --dry-run=server runs the full admission
# chain and persists NOTHING. Every var must be EXPORTED or envsubst renders it EMPTY.
export ARGOCD_PROJECT=default APP_NAME=probe APP_NAMESPACE=probe ARGOCD_TRACK_BRANCH=main \
       DEPLOY_REPO_CLONE_URL=http://example.invalid/x.git \
       ARGOCD_DEST_KEY=server ARGOCD_DEST_VALUE=https://kubernetes.default.svc
envsubst < k8s/argocd/application.yaml > /tmp/probe-app.yaml
grep -nE 'namespace:|project:' /tmp/probe-app.yaml         # sanity: NO blank values
kubectl --kubeconfig $KC apply --dry-run=server -f /tmp/probe-app.yaml
```

**Capture:** all three can-i answers; the rendered /tmp/probe-app.yaml; the dry-run output VERBATIM including any WARNINGS (the warnings are frequently the finding).

**A PASS proves:** `create applications` = yes ⇒ the kubectl mechanism (Scenario 1's default path) works inside a Supervisor vSphere Namespace — never before demonstrated. Dry-run accepted ⇒ our manifest's fields (finalizer, prune+selfHeal, CreateNamespace, ApplyOutOfSyncOnly, retry) survive this server version.

**A FAIL disproves:** can-i = no even for the vSphere ADMIN ⇒ kubectl-into-the-Supervisor is impossible and `ARGOCD_MECHANISM=api` (through argocd-server) is the ONLY path — a design-level finding we get in 30 seconds instead of at the end of a 30-minute install. A dry-run REJECTION names the exact field a 2.x server refuses ⇒ we fix k8s/argocd/application.yaml before you install anything. (Caveat we already know: this dry-run validates schema+admission only — an AppProject/destination rejection surfaces later, at reconcile; step 21 is the authoritative proof.)

**Safe because:** get / auth can-i / --dry-run=server. Nothing is persisted. The repoURL is deliberately unreachable.

### 12. CHEAP, READ-ONLY. **PSA — the RED/GREEN proof.** docs/vks-services/istio.md:106-118 and scripts/49-psa-check.sh:8-11 assert VKS enforces the `restricted` Pod Security Standard BY DEFAULT on every non-system namespace (VKr v1.26+), so our root Kaniko build pods and the Istio-provisioned gateway proxy are REJECTED unless we label their namespaces `baseline` (PSA_LEVEL_CI / PSA_LEVEL_INGRESS). KinD enforces NOTHING, so this has never been observed. NOTE: `make psa-check` CANNOT settle it pre-install — it SKIPS namespaces that do not exist (49:70) and would print 'PSA OK' having measured zero pods. Only this probe settles it

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl create namespace psa-probe
kubectl get ns psa-probe --show-labels          # does VKS stamp an enforce label, or is the default cluster-wide/invisible?
# a ROOT pod — the KANIKO shape (runAsUser:0, NOT privileged). --dry-run=server: admission evaluates, nothing is scheduled.
kubectl -n psa-probe run rootprobe --image=busybox --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"rootprobe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
# now apply OUR label and re-probe — does the rejection go away?
kubectl label ns psa-probe pod-security.kubernetes.io/enforce=baseline --overwrite
kubectl -n psa-probe run rootprobe --image=busybox --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"rootprobe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
kubectl delete namespace psa-probe
```

**Capture:** `--show-labels` on the FRESH namespace; BOTH dry-run outputs VERBATIM — the rejection text, then the acceptance.

**A PASS proves:** REJECTED before the label, ACCEPTED after = the RED-then-GREEN proof the whole PSA subsystem exists for. PSA_LEVEL_CI/PSA_LEVEL_INGRESS=baseline are load-bearing, not paranoia.

**A FAIL disproves:** ACCEPTED in an unlabelled namespace ⇒ this lab does NOT enforce `restricted` by default: our labels are harmless but istio.md:106 / 49-psa-check.sh:8 OVERSTATE a 9.0-doc claim and get re-graded. REJECTED even at `baseline` ⇒ `ci` needs `privileged` (or Kaniko must be replaced) — a real .env.example change, made BEFORE the mirror rather than watching the pipeline die. (No enforce label visible does NOT mean no enforcement — a cluster-wide AdmissionConfiguration default is invisible in labels; the dry-run is the authority.)

**Safe because:** ONE throwaway namespace, deleted. Both pod probes are `--dry-run=server` — nothing is ever scheduled. Zero effect on your workloads.

### 13. CHEAP, READ-ONLY. **ISTIO — and the GATEWAY-API question, which is load-bearing for the TENANT path.** Three sub-claims, all currently 9.0-doc/community-graded: (a) Istio is a GUEST-cluster Standard Package `istio.kubernetes.vmware.com` (istio.md:18-21); (b) its shared ingress gateway is OFF BY DEFAULT (istio.md:24) — so the classic Gateway/VirtualService path has nothing to bind to; (c) **DOES BROADCOM ROUTE WITH THE KUBERNETES GATEWAY API** (istio.md:27) — our README asserts this as fact, and it decides whether a tenant must ASK the mesh admin for a gateway/hostname (classic) or can just deploy (gateway-api: Istio auto-provisions the proxy AND its LB — scripts/lib/istio.sh:116-124)

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
# (a) is Istio offered as a package, and is it installed?   **UNVERIFIED-COMMAND** (the vcf forms)
vcf package available list -A 2>&1 | grep -i istio || vcf addon list --cluster-name "$VKS_CLUSTER_NAME" 2>&1 | grep -i istio
#   ↑ if BOTH error: send us `vcf package --help` / `vcf addon --help` (step 3) — do not guess.
kubectl get packages,packageinstalls -A 2>/dev/null | grep -i istio
kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# (b) is there ANY shared gateway? our signature: a Service exposing port 15021 with a spec.selector.istio key
kubectl get svc -A -o json | jq -r '.items[] | select(any(.spec.ports[]?; .port==15021)) | "\(.metadata.namespace)/\(.metadata.name) selector.istio=\(.spec.selector.istio) type=\(.spec.type)"'
# (c) THE GATEWAY-API QUESTION
kubectl get crd | grep gateway.networking.k8s.io
kubectl get gatewayclass -o wide
kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'; echo
make istio-preflight 2>&1 | tee /tmp/13-istio-preflight.log
```

**Capture:** the package/addon listing — the EXACT package name AND version strings (istio.md:20 only GUESSES `1.25.3+vmware.1-vks.1`); the RUNNING istiod image tag; the 15021 query result (EMPTY = the shared gateway really IS off); the Gateway-API CRD list; the GatewayClass table + its Accepted status; the full istio-preflight log (it prints what a tenant must request from the mesh admin).

**A PASS proves:** GatewayClass `istio` Accepted=True ⇒ (c) the Gateway-API path is available: `INGRESS_CONTROLLER=istio-existing` needs NOTHING from the mesh admin, and the README's claim stands. 15021 query EMPTY ⇒ (b) confirmed: the shared gateway is off by default. The package listing ⇒ (a) confirmed, with real version strings to re-pin.

**A FAIL disproves:** Gateway-API CRDs ABSENT or GatewayClass not Accepted ⇒ the gateway-api path is IMPOSSIBLE here; combined with (b) (no shared gateway to bind to) the TENANT is BLOCKED and must REQUEST a gateway from the mesh admin — the worst case, and it forces a README rewrite plus an ISTIO_SHARED_GATEWAY flow. **If Istio is NOT INSTALLED AT ALL** (the likely state of a freshly-provisioned guest cluster — it is a package YOU install), that is ALSO an answer: (b) and (c) cannot be settled until you install it. If you are willing, install the Istio package now (`vcf package install istio …`, per step 3's help) and re-run this step — that IS the fidelity test, and it is the only way to settle the Gateway-API claim.

**Safe because:** All `get`/`list`. `make istio-preflight` is read-only by construction (48:24). Installs nothing, applies nothing, touches nothing the platform owns.

### 14. CHEAP. Does `make preflight` — the composite gate `make install-all` runs FIRST (Makefile:247,407) — actually PASS on a real lab? It once DIED on every real-lab first run by blocking on `GITEA_ARGOCD_URL`, a value that only gets discovered LATER (inside `make platform`, which runs AFTER preflight). So the one command the runbook tells you to run failed before the mirror. Fixed; never verified. Also runs `make env-check` / `env-validate` — do the doc's interleaved '→ now set these in .env' callouts actually leave a COMPLETE .env?

```bash
set -a; . ./.env; set +a
make env-check    2>&1 | tee /tmp/14-env-check.log;    echo "EXIT=$?"
make env-validate 2>&1 | tee /tmp/14-env-validate.log; echo "EXIT=$?"
make preflight    2>&1 | tee /tmp/14-preflight.log;    echo "EXIT=$?"
```

**Capture:** all three logs + exit codes. Specifically: does `env-check` demand any var the doc's callouts never told you to set? Does `argocd-preflight` print TOPOLOGY OK (or MISMATCH)?

**A PASS proves:** preflight EXIT=0 ⇒ `make install-all` is actually REACHABLE on a real lab, and the two-cluster topology verdict agrees with step 8. env-check/validate green ⇒ the doc's interleaved callouts are complete and correctly ordered.

**A FAIL disproves:** preflight BLOCKING on a value that only exists later ⇒ the ordering regression is back — **STOP AND REPORT, do not work around it**. Every var env-check demands that the doc never mentioned is a HOLE in the runbook (a known suspect: VKS_CA_CERT_FILE, required by step 9's script and mentioned nowhere in the doc). NOTE: a green `psa-check` inside preflight proves NOTHING pre-install — it skips namespaces that don't exist yet; step 12 is the real PSA evidence.

**Safe because:** All three targets are read-only (env-validate dials the cluster + Harbor; auth via a curl config file, never argv).

### 15. **THE DECISION GATE — STOP HERE AND SEND US EVERYTHING.** Steps 1-14 are ~all read-only and cost you an hour at most (mostly your own vSphere work you had to do anyway). They settle the topology, the `vcf` argv, ArgoCD's version + our write rights + our manifest, PSA, Istio + the Gateway API, Harbor's cert + our rights, and every guest precondition. Before you spend 30-40 minutes on the mirror, we reconcile: is the design actually right?

```bash
# Nothing to run. Send us, RAW:
#   * every `vcf ... --help` block (step 3)
#   * the two API-server URLs + where ArgoCD/Harbor run (step 8)
#   * the ArgoCD CR, the real deployment NAMES + IMAGE TAGS, `explain argocd.spec.version` (step 6)
#   * the three `auth can-i` answers + the Application dry-run output (step 11)
#   * both PSA dry-run outputs (step 12)
#   * the GatewayClass/CRD/15021 captures + istio-preflight log (step 13)
#   * the Harbor cert SAN + users/current (step 5)
#   * preflight/env-check/env-validate logs + exit codes (step 14)
#   * the harbor-data-values field list (step 4) and every place the DOC was wrong
tar czf /tmp/phase1-evidence.tgz /tmp/*.log /tmp/probe-app.yaml 2>/dev/null; ls -l /tmp/phase1-evidence.tgz
```

**Capture:** the tarball PLUS the inline pastes. Do not summarise, do not paraphrase an error, do not omit warnings. Paste the artifacts — WE compute the verdicts.

**A PASS proves:** If it all holds, the architecture is confirmed on real infrastructure and the expensive half is worth your time.

**A FAIL disproves:** If the topology, the write mechanism, the manifest, or the LB/StorageClass preconditions come back wrong, we fix the repo and send you a revised Phase 2. Stopping here costs an hour; not stopping costs an afternoon spent mirroring toward a design that cannot work.

**Safe because:** It is a pause. Nothing runs. **Nothing has been written to your lab except the Supervisor Services you chose to install.**

### 16. SLOW (~20-40 min, ~34 images) — the only genuinely long step. Harbor projects + a least-privilege robot, then the mirror + its integrity verification. Exercises: `make harbor-robot` against a real VMware-built Harbor (does our `harbor_is_sysadmin` detection work? can the robot span both projects?), and `crane` pushing over real self-signed HTTPS via the sudo-free `SSL_CERT_FILE` trust bundle

```bash
set -a; . ./.env; set +a
make harbor-robot 2>&1 | tee /tmp/16-harbor-robot.log; echo "EXIT=$?"
ls -l secrets/harbor-robot.env      # 0600, never printed
# copy its two lines (HARBOR_USERNAME / HARBOR_PASSWORD) into .env, then — RUN THIS ALONE:
make mirror 2>&1 | tee /tmp/16-mirror.log; echo "EXIT=$?"
make mirror-verify 2>&1 | tee /tmp/16-mirror-verify.log; echo "EXIT=$?"
```

**Capture:** the harbor-robot log — did it mint a SYSTEM-level robot spanning both projects, a project-scoped one, or 403? — and the robot NAME (never the secret). The mirror log's first 40 lines (a TLS failure shows up immediately) and its tail; the mirror-verify result.

**A PASS proves:** PASS = the air-gap mirror works against a real lab Harbor over self-signed TLS with no system-trust-store change, and every pushed image is intact.

**A FAIL disproves:** A TLS failure in the first minute ⇒ HARBOR_URL does not match the cert SAN (step 5 already told us) or the CA bundle is wrong. A 403 from harbor-robot for the vSphere admin ⇒ our Harbor sysadmin detection is wrong on the VMware build (it once probed an endpoint removed in Harbor 2.13) — fall back to `admin` credentials and report.

**Safe because:** Creates the `cicd` + `apps` Harbor projects (public by default — HARBOR_PUBLIC_PROJECTS=true) and a robot account scoped to them (additive, deletable from the Harbor UI), and pushes ~34 images. **RUN IT ALONE** — no parallel docker/podman/registry work on that box: concurrent pushes corrupt Harbor's blob store and the only reliable recovery is rebuilding the registry.

### 17. CHEAP, AND IT MUST RUN BEFORE `make platform`. **The Harbor CA auto-trust claim** (docs/scenario-1.md:85-88 'Fidelity bonus'; harbor.md:24-27, graded *community*, 'verify on a lab'): does a same-Supervisor VKS cluster REALLY auto-trust the Harbor cert, with NO per-node wiring? KinD cannot show it (there we hand-wire every node's containerd, precisely because there is no Supervisor). We probe it NOW because the very next step (`make platform`) pulls Gitea FROM Harbor — if auto-trust is false, platform ImagePullBackOffs and the remedy (`trust.additionalTrustedCAs`) ROLLS YOUR WORKER NODES

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl create ns trust-probe 2>/dev/null || true
kubectl label ns trust-probe pod-security.kubernetes.io/enforce=baseline --overwrite   # so PSA can't masquerade as a TLS failure
kubectl -n trust-probe run harbor-trust-probe \
  --image=$HARBOR_URL/$HARBOR_INFRA_PROJECT/eclipse-temurin:$TEMURIN_JRE_TAG --restart=Never --command -- sleep 5
sleep 45
kubectl -n trust-probe get pod harbor-trust-probe -o wide
kubectl -n trust-probe describe pod harbor-trust-probe | tail -25
kubectl delete ns trust-probe
# and: does the guest Cluster CR already carry a trust block, and in what EXACT shape?
kubectl --kubeconfig ./secrets/argocd.kubeconfig -n $VKS_NAMESPACE get cluster $VKS_CLUSTER_NAME -o yaml \
  | grep -iA8 -E 'trust|additionalTrustedCA' || echo 'NO trust block in the Cluster CR'
```

**Capture:** the pod STATUS and the tail of `describe` — **the Events section is the answer, and the three outcomes mean different things**: `Successfully pulled image` = AUTO-TRUST CONFIRMED; `x509: certificate signed by unknown authority` = NO auto-trust; `unauthorized` / `401` = a CREDENTIAL problem (the project is private), which says NOTHING about the CA — in that case set HARBOR_PUBLIC_PROJECTS or add the pull secret and re-probe. Plus the Cluster CR trust block verbatim.

**A PASS proves:** 'Successfully pulled' with zero CA wiring ⇒ harbor.md:24-27 upgrades from *community* to lab-verified, and the KinD certs.d apparatus is confirmed as a stand-in-only substitute.

**A FAIL disproves:** x509 ⇒ there is NO auto-trust: docs/scenario-1.md:315-328 (the double-base64 `trust.additionalTrustedCAs` on the Cluster spec) is PROMOTED from a footnote to a REQUIRED step — apply it now, before `make platform`. If the Cluster CR has NO `trust` field at all, we document a field that does not exist in 9.1 and must correct it from your capture.

**Safe because:** One throwaway namespace + one pod that sleeps 5s, using an image you just mirrored; both deleted. Read-only against the Cluster CR.

### 18. MEDIUM (~5-10 min). The offline Maven builder image: built on the internet side with the full `~/.m2` pre-baked and pushed to Harbor via podman with `--cert-dir` (the sudo-free CA trust path). Then Gitea + Tekton in the guest — the first real workloads on a PSA-enforcing cluster, and the step that gives Gitea its own LoadBalancer

```bash
set -a; . ./.env; set +a
make builder-image 2>&1 | tee /tmp/18-builder.log; echo "EXIT=$?"
make platform      2>&1 | tee /tmp/18-platform.log; echo "EXIT=$?"   # install-gitea → seed-gitea → install-tekton → configure-tekton
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl -n gitea get pod,svc,pvc
kubectl -n ci get secret harbor-dockerconfig
kubectl get ns gitea ci --show-labels
```

**Capture:** both logs + exit codes; the Gitea pod/Service/PVC state (**note gitea-http's EXTERNAL-IP — step 20 needs it**); whether `harbor-dockerconfig` was created in `ci`; the PSA labels our installers applied.

**A PASS proves:** PASS = Tekton's cluster-scoped CRDs install, Gitea's PVC binds and gets an LB VIP, and our installers' PSA labels admit the workloads on a real VKS cluster.

**A FAIL disproves:** ImagePullBackOff on Gitea ⇒ the Harbor trust path (step 17 already told us which). A PSA rejection ⇒ our PSA_LEVEL_* defaults are wrong for this lab. PVC Pending ⇒ no default StorageClass (step 10 should have caught it). Tekton CRD Forbidden ⇒ RBAC (step 10).

**Safe because:** Creates the `gitea` / `ci` / `tekton-pipelines` namespaces and installs Tekton's CRDs in YOUR GUEST cluster. Installs NO Harbor and NO ArgoCD. Consumes one LoadBalancer VIP for Gitea.

### 19. CHEAP, AND THIS IS THE ONE KinD STRUCTURALLY CANNOT SETTLE. **Can ArgoCD's repo-server — running on the SUPERVISOR — actually CLONE from a GUEST-cluster LoadBalancer VIP on port 3000?** `gitea_clone_url()` (lib/argocd.sh:153-165) and `argocd_assert_clonable_url()` (:121-133) assume YES; if NO, `make gitops` can never work and the demo needs a different git-hosting design. We probe it on the EXACT port and the EXACT protocol, from INSIDE the real repo-server pod — using `git ls-remote`, because the repo-server image ships git but does NOT ship curl or wget (a curl-based probe there would print 'not found' and look like a routing failure)

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
# 1. the address ArgoCD will be told to clone from:
VIP=$(kubectl --kubeconfig ./secrets/vks.kubeconfig -n ${GITEA_NAMESPACE:-gitea} get svc gitea-http \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo "gitea LB VIP = $VIP"
# 2. find the repo-server BY LABEL (never by name — see step 6):
RS=$(kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get deploy -l app.kubernetes.io/component=repo-server -o name | head -1); echo "repo-server = $RS"
# 3. THE PROBE — git-over-HTTP, the real protocol, from the real pod:
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE exec $RS -- \
  git ls-remote http://$VIP:3000/vks/javawebapp-deploy.git 2>&1 | head -5
# FALLBACK if `exec` is Forbidden (that refusal is itself a finding — report it): use ArgoCD's own API,
# which IS repo-server dialling the URL:
#   argocd login $ARGOCD_SERVER
#   argocd repo add http://$VIP:3000/vks/javawebapp-deploy.git --username <gitea-user> --password-stdin
#   argocd repo list          # read the CONNECTION STATUS column
#   argocd repo rm  http://$VIP:3000/vks/javawebapp-deploy.git
```

**Capture:** the VIP; the repo-server deployment name (does it match our hardcoded `argocd-repo-server`?); and the `git ls-remote` output VERBATIM.

**A PASS proves:** A ref listing — or ANY git/HTTP-level error (401/404/'repository not found') — means the TCP+HTTP path REACHED Gitea: **routable**. That is all we need; the clone-URL design holds and `make gitops` will work.

**A FAIL disproves:** `Could not resolve host` / `Connection timed out` / `Failed to connect` ⇒ the Supervisor CANNOT route to guest LoadBalancer VIPs. **STOP AND REPORT.** `make gitops` cannot work as designed: Gitea must live somewhere the Supervisor CAN reach, and `GITEA_ARGOCD_URL_OVERRIDE` becomes mandatory rather than an escape hatch. This is the single most valuable negative result the lab can produce — do not push on to step 20.

**Safe because:** Read-only. A `kubectl exec` of `git ls-remote` inside an ALREADY-RUNNING pod — it changes nothing, installs nothing, and writes nothing. (The fallback's `argocd repo add` is undone by `argocd repo rm`.)

### 20. CHEAP. The GitOps wiring: `make gitops` creates the ArgoCD Application on the Supervisor, registers the guest cluster as its destination, and points the Application at it. Then the PROOF that the clone actually happened — `.status.sync.revision` is set ONLY after repo-server FETCHED

```bash
set -a; . ./.env; set +a
export KC=./secrets/argocd.kubeconfig
# BEFORE: see what destinations already exist, and pin ours EXPLICITLY (never let a 'there is exactly
# one registered cluster, take it' rule choose on a lab you did not build — the Application prunes).
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get secret -l argocd.argoproj.io/secret-type=cluster
make gitops 2>&1 | tee /tmp/20-gitops.log; echo "EXIT=$?"
# THE PROOF:
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get application \
  -o custom-columns='NAME:.metadata.name,REV:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl --kubeconfig $KC -n $ARGOCD_NAMESPACE get application javawebapp \
  -o jsonpath='{range .status.conditions[*]}[{.type}] {.message}{"\n"}{end}'
```

**Capture:** the pre-existing cluster secrets; the gitops log; the Application table — **is REV a real git SHA, or EMPTY?** — and every Application condition message.

**A PASS proves:** A NON-EMPTY `.status.sync.revision` is PROOF (not a proxy) that the Supervisor's repo-server cloned over the guest's LB VIP and that the destination resolved. The two-cluster GitOps design is lab-verified.

**A FAIL disproves:** EMPTY revision + `dial tcp <gitea-lb>:3000: i/o timeout` ⇒ step 19's probe was optimistic; the clone-URL design must change. A destination/AppProject rejection in the conditions ⇒ the thing step 11's dry-run structurally could NOT catch — capture it verbatim.

**Safe because:** **DISCLOSURE — this step makes a durable, security-relevant change to YOUR lab.** `make argocd-register-guest` (invoked by gitops) mints an `argocd-manager` ServiceAccount + a **cluster-admin ClusterRoleBinding** + a **non-expiring token Secret** in your GUEST cluster's `kube-system`, and writes a bearer-token Secret into the ArgoCD vSphere Namespace. Opt out with `ARGOCD_REGISTER=never` (then a platform admin registers the cluster for you). Teardown is in step 24. If your guest API's cert SAN does not cover the URL ArgoCD dials, `ARGOCD_REGISTER_INSECURE=1` is the escape hatch.

### 21. MEDIUM (~5-10 min). **THE SYSTEM.** `git push (Gitea) → Tekton test/build/Kaniko → Harbor → tag write-back → ArgoCD sync (Supervisor→guest) → the live app serves the change.` Every step above settles a component; this settles the whole — and it converts the PSA claim from a dry-run into a real observation (does a ROOT Kaniko pod actually RUN in the PSA-enforcing guest's `ci` namespace under our `baseline` label?)

```bash
set -a; . ./.env; set +a
make verify 2>&1 | tee /tmp/21-verify.log; echo "EXIT=$?"
# on failure, the diagnosis is one of exactly three shapes:
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
kubectl -n ci get taskrun,pipelinerun
kubectl -n ci describe pod -l tekton.dev/pipelineRun | tail -30
```

**Capture:** the full verify log + exit code. On failure: the PipelineRun/TaskRun status and the failing pod's EVENTS — a PSA rejection reads `violates PodSecurity "restricted"`; an image-pull failure reads x509/ImagePullBackOff; a clone failure names the URL.

**A PASS proves:** EXIT=0 = **the air-gapped VKS CI/CD demo WORKS on real infrastructure.** That is the deliverable, and it retroactively upgrades a dozen inferred facts to lab-verified.

**A FAIL disproves:** A PSA rejection on the Kaniko pod ⇒ `baseline` is insufficient here (needs `privileged`, or Kaniko must be replaced) — a real .env.example change. ImagePullBackOff ⇒ the Harbor trust/pull-secret path (steps 5/17 already told us which). A never-syncing Application ⇒ the clone path (steps 19/20).

**Safe because:** Pushes ONE marked commit to the Gitea WE installed, in your guest cluster, and waits for it to roll. Touches nothing pre-existing.

### 22. CHEAP, READ-ONLY. Are the PSA levels we SHIP sufficient against the cluster's REAL RUNNING pods? scripts/49-psa-check.sh MEASURES the minimum admissible level per namespace via a server-side dry-run label — and it says so itself (49:19-20: 'run it against a real VKS guest cluster to prove the levels we ship are sufficient there too'). It never has. Also answers an open question in istio.md:134-136: does the VMware-built Istio proxy set a seccompProfile?

```bash
set -a; . ./.env; set +a
make psa-check 2>&1 | tee /tmp/22-psa-check.log; echo "EXIT=$?"
```

**Capture:** the whole table (NAMESPACE / PODS / NEEDS(min) / ACTUAL / VERDICT) and every `why not restricted:` line.

**A PASS proves:** EXIT=0 ⇒ every namespace we create is labelled at a level the REAL cluster admits: the PSA subsystem is lab-verified and .env.example's PSA_LEVEL_* defaults are right.

**A FAIL disproves:** Any 'TOO STRICT — pods would be REJECTED' or 'UNLABELLED' row names the exact namespace AND the exact violating field ⇒ we fix that PSA_LEVEL_* default. The `why not restricted` lines are ground truth for the Istio-proxy seccompProfile question.

**Safe because:** Read-only. It uses `kubectl label --dry-run=server`, which makes the API server evaluate the EXISTING pods and return warnings WITHOUT changing any label.

### 23. CHEAP. **The tenant-facing headline, and the second half of the Gateway-API question.** Can `INGRESS_CONTROLLER=istio-existing` (47-attach-istio.sh) attach our routes to a mesh we do NOT own — installing NOTHING — and do the resulting URLs actually serve? And the air-gap sub-claim (istio.md:82): does the Istio-auto-provisioned gateway proxy inherit istiod's hub and therefore pull `proxyv2` from HARBOR?

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
make istio-preflight 2>&1 | tee /tmp/23-istio-preflight.log     # read-only; re-run now that the app namespaces exist
make install-ingress INGRESS_CONTROLLER=istio-existing 2>&1 | tee /tmp/23-attach.log; echo "EXIT=$?"
#   ↑ ONLY this mode if a mesh you did not install is present. If step 13 found NO mesh at all AND you
#     chose not to install the Istio package, then `make install-ingress` (our own istio) or
#     `INGRESS_CONTROLLER=traefik` is correct and safe — nothing to install over.
# what image did the AUTO-PROVISIONED proxy actually pull?
kubectl -n ${ISTIO_GWAPI_NAMESPACE:-vks-ingress} get pod -l gateway.networking.k8s.io/gateway-name \
  -o jsonpath='{.items[0].status.containerStatuses[0].image}'; echo
# add the printed INGRESS_LB_IP to /etc/hosts, then:
make verify-ingress 2>&1 | tee /tmp/23-verify-ingress.log; echo "EXIT=$?"
```

**Capture:** which route API the attach CHOSE (gateway-api or classic); whether it installed ANYTHING; the RUNNING proxy pod's IMAGE (a Harbor host, or docker.io/gcr.io?); verify-ingress per host.

**A PASS proves:** PASS via gateway-api ⇒ a tenant can route through a mesh they do not own with ZERO asks of the mesh admin — the README's load-bearing claim, lab-verified. A proxy image whose host is our HARBOR ⇒ the auto-provisioned gateway inherits istiod's hub and works in an air gap (istio.md:82 confirmed).

**A FAIL disproves:** A proxy image pointing at docker.io/gcr.io ⇒ the auto-provisioned gateway will NOT pull on an air-gapped cluster: we must mirror + override its image. istio.md:82 would be WRONG — a real gap in the design. An attach failure names exactly what the mesh admin must grant (istio-preflight printed the ask).

**Safe because:** `istio-preflight` is read-only by construction. `INGRESS_CONTROLLER=istio-existing` **installs NOTHING** — it applies routes only, in namespaces WE own (vks-ingress, gitea, tekton-pipelines, the app namespaces) and modifies nothing in istio-system or the platform's gateway namespace. **NEVER run the bare `make install-ingress` against a mesh you did not install** — its default (`istio`) would helm-install a SECOND istiod over it.

### 24. OPTIONAL, CHEAP. Give you your lab back. Nothing above is auto-cleaned, and step 20 in particular left a durable cluster-admin credential

```bash
set -a; . ./.env; set +a
export KUBECONFIG=$PWD/secrets/vks.kubeconfig
# the ArgoCD registration credential (step 20):
kubectl -n kube-system delete clusterrolebinding argocd-manager-role-binding 2>/dev/null || true
kubectl -n kube-system delete sa argocd-manager 2>/dev/null || true
kubectl -n kube-system delete secret -l kubernetes.io/service-account.name=argocd-manager 2>/dev/null || true
kubectl --kubeconfig ./secrets/argocd.kubeconfig -n $ARGOCD_NAMESPACE delete secret -l argocd.argoproj.io/secret-type=cluster
# our workloads (leave them if you want the demo alive):
kubectl --kubeconfig ./secrets/argocd.kubeconfig -n $ARGOCD_NAMESPACE delete application --all
kubectl delete ns gitea ci tekton-pipelines ${ISTIO_GWAPI_NAMESPACE:-vks-ingress} javawebapp gowebapp 2>/dev/null || true
# Harbor: delete the robot account + the cicd/apps projects from the Harbor UI if you want them gone.
# DO NOT run `make kind-down` on this box — it is the LOCAL teardown and it removes files under ./secrets.
```

**Capture:** nothing — just confirm the ClusterRoleBinding and the cluster Secret are gone.

**A PASS proves:** Your lab is back to (Supervisor Services + an empty workload cluster).

**A FAIL disproves:** n/a

**Safe because:** Deletes ONLY objects this run created. It does NOT touch Harbor, ArgoCD, Contour, the Istio package, or your cluster.

## STOP and come back to us if…

- **THE GATE AT STEP 15 IS HARD.** Do not start step 16 (the mirror) until you have sent us the read-only evidence and we have confirmed the design survives it. Steps 1-14 cost you about an hour, almost all of it work you had to do anyway; step 16 costs 30-40 minutes and can only be spent once. A design error found at step 15 costs us one email; found at step 20 it costs your afternoon.
- **STOP AND SEND US THE `--help` OUTPUT — do not fight our guess — the moment any `vcf` command errors.** We ship TWO CONTRADICTORY forms of `vcf context create` and neither has ever run; this repo has shipped a fabricated `vcf` command before. Every `vcf` step in this plan is marked UNVERIFIED-COMMAND and carries a fallback that does not need the CLI. We would much rather learn the real CLI shape from you than have you work around our fiction.
- **STOP if step 8 shows Harbor/ArgoCD are NOT on a cluster separate from the guest.** The entire two-cluster design (ARGOCD_KUBECONFIG, argocd-register-guest, the destination refusal) is premised on it. If it is false, everything downstream is answering the wrong question and we re-plan.
- **STOP if step 10 shows no default StorageClass, no LoadBalancer provider, or no rights to create CustomResourceDefinitions.** Gitea's PVC would never bind, Gitea could never get an off-cluster address, and Tekton could not install — `make platform` would fail slowly and confusingly.
- **STOP if step 11 shows you cannot create Applications in the ArgoCD namespace, or our Application manifest is REJECTED by the server-side dry-run.** The first means `ARGOCD_MECHANISM=api` is the only viable path; the second means we must fix `k8s/argocd/application.yaml` before you install anything.
- **STOP if step 14's `make preflight` BLOCKS on a value that only exists later in the flow.** That is a known regression (it once died on `GITEA_ARGOCD_URL`, which `make platform` only discovers afterwards) and it means the one command our runbook tells operators to run fails before the mirror. Do not work around it — report it.
- **STOP if step 17 shows `x509: certificate signed by unknown authority`** — do NOT proceed to `make platform`. There is no Harbor CA auto-trust on this lab, and you must first add the CA to the guest Cluster CR (`trust.additionalTrustedCAs`, double-base64 — docs/scenario-1.md:315-328). Applying that rolls your worker nodes; better to do it deliberately than to watch Gitea ImagePullBackOff.
- **STOP AND REPORT if step 19's probe times out** (`Connection timed out` / `Could not resolve host` from the repo-server). The Supervisor cannot route to guest LoadBalancer VIPs, `make gitops` cannot work as designed, and step 20 would only produce a slower version of the same failure. This is the single most valuable negative result the lab can give us — it changes the design.
- **NEVER run `make kind-down` on the lab jump box.** It is the LOCAL (KinD) teardown; it removes state under `./secrets/`, and the documented real-lab kubeconfig default IS `./secrets/vks.kubeconfig`. docs/scenario-1.md Step 0 still tells you to run it — that instruction is WRONG for a lab box and we are fixing it. Use `make state-show` (read-only) instead.
- **NEVER run the bare `make install-ingress`** on a cluster that already has a mesh — its default (`INGRESS_CONTROLLER=istio`) would helm-install a SECOND istiod over the platform's. Only `INGRESS_CONTROLLER=istio-existing` is permitted there (it installs nothing). If step 13 found NO mesh at all, installing one is fine.
- **Never run two registry-mutating operations at once.** `make mirror` (step 16) must run ALONE — no parallel builds, no second mirror, no concurrent docker/podman work on that box. Concurrent pushes corrupt Harbor's blob store and the only reliable recovery is rebuilding the registry.
- **Never run a bare `vcf` with no arguments.** An unknown CLI invoked bare can block on interactive input and hold a session — and the NEXT command then reports a phantom error you will misdiagnose as real state. Always use an explicit subcommand or `--help`.
- **Never put a password on a command line.** Every command here either prompts (`vcf context create`, `curl -u user`) or reads from a file. If a step seems to want a password inline, stop and ask us.
- **After the gate, a FAILING step is a RESULT, not a blocker** — capture its evidence verbatim and continue, unless a stop condition above applies. Steps 16-23 are ordered so an early failure does not cost us the later evidence.
- **REPORT BACK RAW.** Paste captured output verbatim — logs, `--help` blocks, `describe` Events, image tags, cert SANs, `explain` lists, `can-i` answers, and the actual `harbor-data-values` field list. Do not summarise, do not paraphrase an error, do not omit warnings: the warnings are frequently the finding. And keep a running note of **every place docs/scenario-1.md was wrong, mis-ordered, or incomplete** — that list is half the deliverable.

---

[← back to the README](../README.md)
