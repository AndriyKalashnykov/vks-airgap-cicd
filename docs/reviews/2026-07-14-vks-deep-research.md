# VKS 9.1 deep research — 2026-07-14

Five load-bearing questions we BUILD against. Each researched from primary sources, then handed to a
second adversary tasked with REFUTING it (fetch the URL yourself; is it really 9.1; is the quote real).

Every source records `url_requested` AND `url_landed`, so a redirect cannot launder 9.0 content as 9.1.


---

## [NINE_ZERO_DOC_READ_AS_9_1] On VMware VKS (TKr/VKr v1.26+): is the Pod Security Standard "restricted" ENFORCED by default on non-system namespaces of a guest cluster, and which system namespaces are exempt? Is the repo right to label its `ci` namespace (Kaniko runs as root) and the Istio gateway namespace (proxy sets no seccompProfile) as `baseline`?

CONFIRMED, in both directions. The repo's belief is correct, and its `baseline` labels are not over-privileging — they are the minimum sufficient level and are exactly what prevents admission rejection.

1) ENFORCEMENT — TRUE. Broadcom, verbatim: "VKr releases v1.26 and later have the PSA mode enforce set to restricted for non-system namespaces." (v1.25 was transitional: warn/audit only, no enforcement.) Every VKr shipped with VCF 9.x is far past 1.26, so this is unconditionally in force on the target lab.

2) EXEMPT NAMESPACES — exactly the three the repo names, and no others: "Some system pods running in the kube-system, tkg-system, and vmware-system-cloud-provider namespaces require elevated privileges. These namespaces are excluded from pod security." Broadcom adds that PSA on system namespaces cannot be changed. Every namespace this repo creates (gitea, tekton-pipelines, ci, the app namespaces, the ingress/Istio namespaces) is NOT exempt.

3) THE LOAD-BEARING MECHANISM (this is what decides whether psa-check is sound). PSA has NO namespace-exemption mechanism via labels — `exemptions.namespaces` exists ONLY in a cluster-wide AdmissionConfiguration/PodSecurityConfiguration. So the mere existence of an exempt list proves the default is applied CLUSTER-WIDE, not by labelling namespaces one at a time. Corroborated empirically: on TKr 1.26+ the kube-apiserver carries `/etc/kubernetes/extra-config/admission-control-config.yaml`, and a NEWLY CREATED, UNLABELLED namespace rejects non-compliant pods out of the box ("nothing will want to run out of the box when you deploy a new pod on a TKr v1.26+ cluster"). Therefore `49-psa-check.sh`'s core assumption — `eff="${cur:-restricted}"`, i.e. "an UNLABELLED namespace falls back to the VKS default restricted" — is CORRECT. This is the most important confirmation in the report: a version of this repo that merely ran `kubectl create namespace` and moved on would have had its pods rejected at admission on the real lab, silently, with KinD green throughout.

4) BASELINE IS THE RIGHT LEVEL, AND IT IS THE MINIMUM (not over-privileging). Upstream Pod Security Standards: `restricted` REQUIRES runAsNonRoot=true, seccompProfile RuntimeDefault|Localhost, and allowPrivilegeEscalation=false. `baseline` requires NONE of those three (it only forbids seccomp explicitly set to `Unconfined`). So:
   - Kaniko runs as root ⇒ `restricted` rejects it (runAsNonRoot != true). `baseline` admits it. There is no PSS level between the two ⇒ `PSA_LEVEL_CI=baseline` is the MINIMUM sufficient level, not a loosening.
   - The Istio-provisioned gateway proxy sets no seccompProfile ⇒ `restricted` rejects it. `baseline` admits it ⇒ `PSA_LEVEL_INGRESS=baseline` is likewise minimal.
   Not theory: Broadcom's own KB 385064 shows VMware's OWN Contour/Envoy package being rejected on a vSphere Kubernetes cluster with `violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false`, fixed by relabelling the namespace. That is precisely the failure this repo is defending against, happening to VMware's own software.

5) ONE NUANCE (changes no label). The cluster-wide default is CONFIGURABLE by the cluster owner via the `podSecurityStandard` ClusterClass variable (v1beta1 API, vSphere 8u3+; fields deactivated/enforce/audit/warn/deny plus `exemptions.namespaces` — namespace exemptions only). So on a lab you do NOT own, "unlabelled ⇒ restricted" is a *default*, not a guarantee. This cuts in the repo's favour twice: (a) psa-check's assumption errs SAFE — if the real default were looser, psa-check is merely pessimistic and can never go falsely green; and (b) `lib/psa.sh`'s choice to label explicitly even where `restricted` is already the default is correct precisely because it refuses to depend on a cluster-wide default someone else controls.

VERDICT: no change required. The belief is right, the exempt list is right, the `baseline` choices are minimal and necessary, and the psa-check fallback is sound. The only thing ASSUMED rather than measured is the cluster-wide default itself — and it is cheaply measurable as a tenant.

**Would settle it:** Run this on a REAL VKS guest cluster. It is TENANT-runnable (needs only namespace-create plus pod-create RBAC) and creates nothing durable — the pod is a server-side dry-run:

  # 1. Does an UNLABELLED namespace inherit `restricted`?  (the psa-check assumption)
  kubectl create namespace psa-probe
  kubectl get ns psa-probe -o jsonpath='{.metadata.labels}'; echo
  #   EXPECT: NO pod-security.kubernetes.io/* labels at all — VKS does not label it; the default
  #   comes from the apiserver's cluster-wide PodSecurityConfiguration, which is invisible here.

  # 2. Is that default `restricted`, and does it REJECT a root pod?
  kubectl -n psa-probe run probe --image=busybox --restart=Never --dry-run=server \
    --overrides='{"spec":{"containers":[{"name":"probe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
  #   EXPECT REJECTION: Error from server (Forbidden): pods "probe" is forbidden: violates
  #   PodSecurity "restricted:latest": allowPrivilegeEscalation != false, runAsNonRoot != true,
  #   seccompProfile ... must be RuntimeDefault or Localhost
  #   If it is instead ADMITTED, the cluster default is NOT restricted (a platform team changed
  #   podSecurityStandard). Our explicit labels still hold; only psa-check's pessimism changes.

  # 3. Does `baseline` admit it — i.e. are PSA_LEVEL_CI / PSA_LEVEL_INGRESS sufficient?
  kubectl label --overwrite ns psa-probe pod-security.kubernetes.io/enforce=baseline
  kubectl -n psa-probe run probe --image=busybox --restart=Never --dry-run=server \
    --overrides='{"spec":{"containers":[{"name":"probe","image":"busybox","securityContext":{"runAsUser":0}}]}}'
  #   EXPECT: "pod/probe created (server dry run)"  == baseline admits root. Confirms ci + ingress.

  kubectl delete namespace psa-probe

  # 4. Confirm the exempt set on THIS cluster:
  for ns in kube-system tkg-system vmware-system-cloud-provider; do
    kubectl get ns "$ns" -o jsonpath="{.metadata.name}{'\t'}{.metadata.labels}{'\n'}" 2>/dev/null
  done
  #   Exemptions live in the apiserver config, NOT in labels, so expect NO pod-security labels on
  #   them — their exemption is invisible from the namespace object. The definitive read needs
  #   control-plane (cluster-ADMIN/SSH) access:
  #       cat /etc/kubernetes/extra-config/admission-control-config.yaml
  #   which prints the PodSecurityConfiguration defaults + exemptions.namespaces verbatim.

PAGE STILL TO OBTAIN: a genuinely 9.1-scoped PSA page. It appears NOT to exist — the 9.1 tree publishes release notes but not the PSA page, and the 9-1 PSA URL returns HTTP 404 while every reachable vendor page 301s into the 9-0 tree. Steps 1–4 above are therefore the ONLY way to raise this finding from 9.0-doc-read-as-9.1 to lab-verified.

### Sources

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/configure-psa-for-tkr-1-25-and-later.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/configure-psa-for-tkr-1-25-and-later.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > VKr releases v1.26 and later have the PSA mode enforce set to restricted for non-system namespaces. || VKr v1.25 have PSA modes warn and audit set to restricted for non-system namespaces. || Some system pods running in the kube-system, tkg-system, and vmware-system-cloud-provider namespaces require elevated privileges. These namespaces are excluded from pod security. || The PSA controller enforces pod security at the Kubernetes namespace level. You use namespace labels to define the PSA modes and levels. || kubectl label --overwrite ns default pod-security.kubernetes.io/enforce=baseline  [301 

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/configure-psa-for-tkr-1-25-and-later.html`
  landed: `HTTP 404 Not Found — no 9-1 version of this page exists at this path`  (retrieved 2026-07-14)
  > The server returned HTTP 404 Not Found. — NOTE: a 9-1 doc tree DOES exist (e.g. .../vcf-service-administration-and-development/9-1/release-notes/vks-release-notes.html), but the PSA page is NOT published under it. So there is no 9.1-specific PSA page to read at all, and nothing surfaced in the 9.1 release notes changes the PSA default or the exempt list. This 404 is the direct evidence for the NINE_ZERO_DOC_READ_AS_9_1 grade.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/security-for-tkg-service-clusters.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/security-for-tkg-service-clusters.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > Starting with vSphere Kubernetes release v1.25, VKS clusters have the Pods Security Admission controller (PSA) enabled by default. [Page title: 'Security for VKS Clusters'. Version banner: vSphere Supervisor 9.0 Services and Standalone Components. 301 REDIRECT 'latest' -> 9-0: 9.0 content read as 9.1.]

- requested: `https://developer.broadcom.com/xapis/vmware-vsphere-kubernetes-service/latest/variable-docs.html`
  landed: `https://developer.broadcom.com/xapis/vmware-vsphere-kubernetes-service/latest/variable-docs.html`  (retrieved 2026-07-14)
  > podSecurityStandard: audit / auditVersion / deactivated / enforce / enforceVersion / warn / warnVersion / exemptions.namespaces ([]string — 'Namespaces where standards are ignored'). enforce/audit/warn each one of "", privileged, baseline, restricted. — The page does NOT document default values for enforce/audit/warn and lists no default exempt-namespace set. This is the cluster-OWNER override knob, not the source of the shipped default; its existence is why 'unlabelled => restricted' is a default and not a guarantee on a cluster you do not own.

- requested: `https://kubernetes.io/docs/concepts/security/pod-security-standards/`
  landed: `https://kubernetes.io/docs/concepts/security/pod-security-standards/`  (retrieved 2026-07-14)
  > RESTRICTED — 'Containers must be required to run as non-root users.' Allowed Values: true. 'Seccomp profile must be set to RuntimeDefault or Localhost.' Privilege Escalation allowed values: false. || BASELINE — Seccomp: 'Seccomp profile must not be explicitly set to Unconfined.' Allowed values: Undefined/nil, RuntimeDefault, Localhost. Baseline does NOT require runAsNonRoot and does NOT require seccompProfile=RuntimeDefault. [This is the upstream fact that makes `baseline` the MINIMUM level admitting root-running Kaniko and a proxy with no seccompProfile — i.e. the repo is not over-privileging

- requested: `https://knowledge.broadcom.com/external/article/385064/vsphere-kubernetes-cluster-pods-running.html`
  landed: `https://knowledge.broadcom.com/external/article/385064/vsphere-kubernetes-cluster-pods-running.html`  (retrieved 2026-07-14)
  > Broadcom KB 385064: Envoy DaemonSet pods fail to start on a vSphere Kubernetes cluster — 'violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false'. Resolution: 'Add a label to the envoy namespace to bypass the PodSecurity rule'; 'It is best practice to define the PodSecurity appropriately to allow contour, envoy and cert-manager pods to deploy according to your security needs.' — VMware's OWN package rejected by the restricted default; the identical failure mode to our Kaniko / Istio-proxy pods.

- requested: `https://saravanansubbiah.in/vmware/k8s/tanzu-pod-security/`
  landed: `https://saravanansubbiah.in/vmware/k8s/tanzu-pod-security/`  (retrieved 2026-07-14)
  > COMMUNITY (empirical, real cluster): after upgrade to v1.26.5, pods in UNLABELLED namespaces are rejected while labelled namespaces continue running — 'pod creation failed because it violates PodSecurity restricted:latest'. The cluster-wide default lives in the kube-apiserver admission config at /etc/kubernetes/extra-config/admission-control-config.yaml on the control-plane nodes and applies with NO manual configuration — 'this is the default setting with TKR 1.26 based clusters'. Fix: kubectl label --overwrite ns ns1 pod-security.kubernetes.io/enforce=baseline. [This is the evidence that a NE

- requested: `https://blog.ukotic.net/2024/05/29/tanzu-pod-security-admission-psa/`
  landed: `https://blog.ukotic.net/2024/05/29/tanzu-pod-security-admission-psa/`  (retrieved 2026-07-14)
  > COMMUNITY: 'From Tanzu Kubernetes release v1.26 and onwards, the default security mode changed to enforce with the pod standard set to restricted.' ... 'basically, nothing will want to run out of the box when you deploy a new pod on a TKr v1.26+ cluster.' Observed error: violates PodSecurity 'restricted:latest': allowPrivilegeEscalation != false ... runAsNonRoot != true ... seccompProfile (pod or container must set securityContext.seccompProfile.type to 'RuntimeDefault' or 'Localhost').


---

## [NINE_ZERO_DOC_READ_AS_9_1] On VMware VKS 9.1: (1) Is ArgoCD a Supervisor Service (running on the Supervisor, not the guest cluster)? (2) Confirm server pin 2.14.15+vmware.1-vks.1 and CLI 3.0.19-vcf from primary sources. (3) Can a TENANT kubectl into the ArgoCD instance's namespace? (4) Is cluster registration (argocd cluster add / the Cluster secret) genuinely admin-only?

FOUR ANSWERS, and one of them overturns a claim we ship.

=== 0. THE REDIRECT TRAP IS WORSE THAN WE RECORDED (measured with curl, not inferred) ===
Our note says "9.1 URLs 301-redirect to the 9.0 tree." That is NOT the mechanism. Measured:
  • .../vcf-service-administration-and-development/9-1/.../install-argo-cd-service.html  -> 404, ZERO redirects.
  • .../vsphere-supervisor-services-and-standalone-components/latest/.../install-argo-cd-service.html -> 301 -> .../vcf-service-administration-and-development/9-0/... (200)
So: THERE IS NO 9.1 EDITION OF THE ARGOCD SERVICE DOCS AT ALL. What exists is a `latest` alias that 301s into the **9-0** tree. That is more dangerous than a 9.1->9.0 redirect, because `latest` carries no version signal — a reader (and every search-engine hit) lands on 9.0 content with nothing on the page saying "9.0". A newer home exists at .../vcf-consumption/latest/argo-cd/... (200, no redirect) but it is ALSO unversioned: its <title> is just "Argo CD Service", and explicit /9-0/ and /9-1/ URLs under it both 404.
=> EVERY VMware fact below is 9.0-content-read-as-9.1. Not one of them can be graded 9.1 today.

=== 1. TOPOLOGY: CONFIRMED (9.0 doc) ===
"You deploy the VMware Argo CD Operator on the Supervisor and then install an Argo CD instance in a vSphere Namespace so that you can use to manage workloads in vSphere Namespaces and VKS clusters."
The CR is namespaced into a vSphere Namespace (`namespace: argocd-instance-1`), and the registration walkthrough deploys to the guest by `--dest-server https://192.16.0.204:6443` — i.e. ArgoCD is NOT in the guest. Our topology claim, and the `kubernetes.default.svc` trap it exists to prevent, are correct.

=== 2. VERSIONS: SERVER CONFIRMED, CLI *NOT* ESTABLISHED ===
SERVER — confirmed verbatim. The doc's minimal CR is exactly:
    kind: ArgoCD
    spec:
      version: 2.14.15+vmware.1-vks.1
BUT with a caveat we do not currently state: the CR reference calls this "the ArgoCD carvel package version that is bundled with the ArgoCD Supervisor Service" and says "Check the vSphere Supervisor release notes to get the version that is supported for each ArgoCD Supervisor Service release." It is a PER-RELEASE value, not a constant — and the GA announcement cites 2.14.13, not 2.14.15. So `2.14.15+vmware.1-vks.1` is *the 9.0 doc's example*, not a fixed pin. Treat it as "a 2.x line", never as a literal to assert.
CLI — NOT ESTABLISHED from any vendor page. Broadcom says only: "Download the Argo CD Operator YAML definition and the customized Argo CD CLI from the Broadcom support portal." No vendor page states 3.0.19, or any CLI version number. Our `v3.0.19+d67e6eb90-vcf` remains LAB-VERIFIED-ONLY (our own binary) — which is exactly how argocd.md:22 already grades it. Keep it that way; do not promote it. The 2.x-server / 3.x-CLI skew is real and unexplained by any doc.

=== 3. TENANT KUBECTL INTO THE ARGOCD NAMESPACE: NOT ESTABLISHED (but the mechanism is now clear) ===
No Broadcom page addresses it. The mechanism, from the vSphere Namespace permission model: permissions are granted PER vSPHERE NAMESPACE ("Can view" / "Can edit" / "Owner", each on a named namespace). The ArgoCD instance lives in its OWN vSphere Namespace (e.g. `argocd-instance-1`). So a tenant can kubectl there IF AND ONLY IF an admin grants them a permission on THAT namespace — it is in no way implied by holding edit on their own namespace. Default answer: NO. This is a config choice, not a product law, and it needs a lab to settle.

=== 4. IS REGISTRATION ADMIN-ONLY? YES — BUT BOTH REASONS WE SHIP ARE WRONG. THIS IS THE FINDING. ===

(4a) argocd.md:42 says: "ArgoCD's `clusters` is a **global** RBAC resource — only applications/applicationsets/logs/exec are grantable through a tenant AppProject role."
    ** THIS IS FALSE. ** Refuted by ArgoCD's own source:
        util/rbac/rbac.go:
            var ProjectScoped = map[string]bool{
                ResourceApplications: true, ResourceApplicationSets: true,
                ResourceLogs: true, ResourceExec: true,
                ResourceClusters: true,        // <-- clusters IS project-scopeable
                ResourceRepositories: true,
            }
        types.go:2748 (AppProject role policy validation):
            "project resource must be: 'applications', 'applicationsets', 'repositories', 'exec', 'logs' or 'clusters'"
    An AppProject role CAN carry a `clusters` policy. We were misled by ArgoCD's DOCS, whose "Application-Specific Policy" section lists only applications/applicationsets/logs/exec — the docs are INCOMPLETE relative to the code (a textbook "prefer the tool's own runtime/source over its prose docs" case). It was graded "research (adversarially verified)"; it was neither.

(4b) argocd.md:43 says: "Kubernetes privilege-escalation prevention only permits a caller who already holds cluster-admin there."
    The K8s rule is real ("A user can only create or update a RoleBinding or ClusterRoleBinding if they already have ... permission to grant ... all of the permissions referenced by the binding"), and `argocd cluster add` does mint a cluster-admin SA ("installs a ServiceAccount (argocd-manager) into the kube-system namespace ... and binds the service account to an admin-level ClusterRole").
    ** BUT ON VKS THAT GATE IS VACUOUS FOR THE TENANT. ** Broadcom KB 424897: a vSphere Namespace "Can edit" user is "Automatically granted the `cluster-admin` role for all VKS clusters in that vSphere Namespace." A normal VKS tenant ALREADY HOLDS cluster-admin on their own guest cluster, so they CAN create argocd-manager + the ClusterRoleBinding there. The escalation check does not stop them.

(4c) SO WHAT IS THE REAL GATE? The SUPERVISOR SIDE.
    The `Cluster` Secret (argocd.argoproj.io/secret-type: cluster) must be written into the ARGOCD INSTANCE'S vSphere Namespace on the Supervisor — a DIFFERENT vSphere Namespace on which the tenant has no permission (permissions are per-namespace, see #3). Equivalently, via the ArgoCD API, the tenant needs `clusters, create` — which IS grantable in an AppProject role, but only an ArgoCD admin can grant it (and the object regex scopes it to `<project>/*`).
    => CONCLUSION UNCHANGED (a tenant cannot self-register today, so `ARGOCD_MECHANISM=request` and the "request it from the platform team" runbook stay correct). REASONING REPLACED. And there is a live consequence: because `clusters` IS project-scopeable, a platform team COULD deliberately enable tenant self-registration by granting `clusters, create` on the tenant's AppProject plus a path to write the Secret. We have been telling ourselves that is impossible. It is not.

### What we would change

TWO CORRECTIONS TO SHIP, one of them a genuine refutation of a claim we assert with a confidence grade it never earned.

1) docs/vks-services/argocd.md:42 — REWRITE (currently FALSE).
   Ships: "ArgoCD's `clusters` is a **global** RBAC resource — only `applications`/`applicationsets`/`logs`/`exec` are grantable through a tenant AppProject role | research (adversarially verified)".
   ArgoCD's source says the opposite: `util/rbac/rbac.go`'s `ProjectScoped` map contains `ResourceClusters: true`, and `types.go:2748` validates AppProject role policies against exactly {applications, applicationsets, repositories, exec, logs, clusters}. We took ArgoCD's *docs* ("Application-Specific Policy" lists 4 resources) as an exhaustive list; it is not, and it never claims to be. The grade "research (adversarially verified)" is the worst part — it was neither.

2) docs/vks-services/argocd.md:43 — REWRITE (true in general, VACUOUS on VKS).
   Ships: "Kubernetes privilege-escalation prevention only permits a caller who *already* holds cluster-admin there | KinD-verified".
   Broadcom KB 424897: a vSphere Namespace "Can edit" user is "Automatically granted the cluster-admin role for all VKS clusters in that vSphere Namespace." The VKS tenant ALREADY HOLDS cluster-admin on their own guest cluster — so this gate does not stop them minting argocd-manager. Our "KinD-verified" grade is precisely the trap the repo warns about: KinD cannot show this, because KinD has no vSphere Namespace permission model. It verified a mechanism that VKS renders moot.

   REPLACEMENT REASON (the real gate): the `Cluster` Secret must be written into the ArgoCD instance's vSphere Namespace ON THE SUPERVISOR — a different vSphere Namespace the tenant holds no permission on (vSphere Namespace permissions are strictly per-namespace). Via the API, the tenant needs `clusters, create`, which only an ArgoCD admin can grant.

   CONCLUSION SURVIVES: registration is still admin-gated, so `ARGOCD_MECHANISM=request`, `scripts/71-argocd-register-guest.sh` and the "request it from the platform team" runbook text are all still CORRECT and need no code change. Only the WHY is wrong — and a wrong why is what misleads the next reader (and it is load-bearing here, because it forecloses a real design option).

3) NEW, ACTIONABLE: because `clusters` IS project-scopeable, tenant self-registration is NOT impossible — a platform team can grant `clusters, create` on the tenant's AppProject. Worth a line in argocd.md as the "ask your platform team for THIS policy" escalation, instead of the current flat "a tenant cannot self-service it".

4) docs/vks-services/argocd.md:21 — SOFTEN. `2.14.15+vmware.1-vks.1` is the 9.0 doc's EXAMPLE, not a fixed pin: the CR reference says the version is per-Supervisor-release ("Check the vSphere Supervisor release notes"), and the GA blog cites 2.14.13. Assert "a 2.x line", not the literal. Line 22 (CLI, "lab-verified") is graded correctly — NO vendor page states any CLI version; keep it lab-only.

5) CLAUDE.md / the provenance convention — SHARPEN THE TRAP ITSELF. We record "Broadcom 9.1 URLs 301-redirect to the 9.0 tree". Measured today, the mechanism is different and worse: the 9-1 URL **404s** (no 9.1 edition of the ArgoCD docs exists), and it is **`/latest/` that 301s into `/9-0/`**. Plus the newer `vcf-consumption/latest/argo-cd/` book carries NO version label at all. So the grade "9.0-doc-inferred-for-9.1" is right, but the detection rule we wrote down would not fire — an agent requesting `latest` (the natural thing, and what every search hit gives) gets 9.0 content with zero version signal and no 9.1 URL to compare against.

**Would settle it:** THREE LAB COMMANDS, in priority order. All are read-only.

(A) THE TWO VERSIONS — settles claim 2 in 30 seconds, and it is the only way to get the CLI number (no vendor page states one):
    # SERVER (on the Supervisor, in the ArgoCD instance's vSphere Namespace):
    kubectl -n <argocd-instance-ns> get argocd -o jsonpath='{.items[*].spec.version}{"\n"}'
    kubectl -n <argocd-instance-ns> get deploy argocd-server \
      -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
    kubectl explain argocd.spec.version          # the operator's supported set
    # CLI (the binary from the Broadcom portal):
    argocd version --client
    -> Expect server 2.14.x+vmware.1-vks.N (the exact patch is release-dependent — do NOT expect 2.14.15
       specifically) and a CLI carrying a `-vcf` suffix. If the CLI really is 3.0.19 against a 2.14 server,
       that is a major-generation skew worth recording explicitly.

(B) THE TENANT'S REACH INTO THE ARGOCD NAMESPACE — settles claim 3 (currently NOT ESTABLISHED; no doc addresses it).
    As the TENANT SSO user, against the SUPERVISOR kubeconfig (NOT the guest):
    kubectl auth can-i --list -n <argocd-instance-ns>
    kubectl auth can-i create secret -n <argocd-instance-ns>     # THE decisive one — this is the Cluster Secret
    kubectl auth can-i get argocd  -n <argocd-instance-ns>
    -> Expect a blanket "no" unless an admin granted the tenant a permission on THAT vSphere Namespace.
       `create secret` == no is what makes registration admin-only. If it says YES, our whole
       "tenant must request registration" model is wrong and 71-argocd-register-guest.sh's premise changes.

(C) THE REFUTATION, CONFIRMED ON A REAL ARGOCD — settles claim 4a empirically (already primary-sourced from
    ArgoCD's code, but this is the ground truth on the *shipped 2.14.x* server, which is older than master):
    # As an ArgoCD admin, try to put a clusters policy in an AppProject role.
    # If argocd.md:42 were true this MUST be rejected; per the source it must be ACCEPTED.
    kubectl -n <argocd-instance-ns> patch appproject <proj> --type=merge -p '{"spec":{"roles":[{
      "name":"tenant","policies":["p, proj:<proj>:tenant, clusters, get, <proj>/*, allow"]}]}}'
    -> ACCEPTED  => our line 42 is false on the shipped server too; rewrite it (and consider offering the
                    platform team a `clusters, create` grant as the documented tenant-enablement path).
    -> REJECTED with "project resource must be: ..." => 2.14.x predates the change; then line 42 is true
                    FOR OUR PINNED SERVER and must be re-scoped to say so, with the version, rather than
                    stated as a timeless fact about ArgoCD.
    (Cheap offline pre-check while waiting for a lab:
       git -c advice.detachedHead=false clone -q --depth 1 --branch v2.14.15 \
         https://github.com/argoproj/argo-cd /tmp/acd && grep -n -A8 'ProjectScoped = map' /tmp/acd/util/rbac/rbac.go
     — that tells you whether ResourceClusters was already in the map on the 2.14 line.)

PAGE TO OBTAIN (not on the public web): the vSphere Supervisor RELEASE NOTES for the ArgoCD Supervisor Service
release actually installed on the lab. The CR reference explicitly defers the version to it ("Check the
vSphere Supervisor release notes to get the version that is supported for each ArgoCD Supervisor Service
release"), and that is the ONLY authoritative statement of the server pin for a given install.

### Sources

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html`
  landed: `HTTP 404 — 0 redirects; page does not exist`  (retrieved 2026-07-14)
  > (404 Not Found — there is NO 9.1 edition of the Argo CD Supervisor Service install page. This is the evidence that '9.1 docs' for this feature do not exist at all, rather than merely redirecting.)

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service/install-argo-cd-service.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > You deploy the VMware Argo CD Operator on the Supervisor and then install an Argo CD instance in a vSphere Namespace so that you can use to manage workloads in vSphere Namespaces and VKS clusters. || apiVersion: argocd-service.vsphere.vmware.com/v1alpha1 / kind: ArgoCD / metadata: name: argocd-1, namespace: argocd-instance-1 / spec: version: 2.14.15+vmware.1-vks.1 || Download the Argo CD Operator YAML definition and the customized Argo CD CLI from the Broadcom support portal.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/using-argo-cd-service.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > You can now deploy Argo CD as a Supervisor Service to provide declarative GitOps continuous delivery to your workloads running on vSphere Namespaces and VKS clusters.  [301 Moved Permanently observed in the open: 'latest' -> '9-0'. The page states NO argocd CLI version and NO 'vcf suffix' verification sentence.]

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/argo-cd/using-argocd-to-manage-resources-on-the-supervisor.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/argo-cd/using-argocd-to-manage-resources-on-the-supervisor.html`  (retrieved 2026-07-14)
  > Prerequisites: Install the Argo CD Operator on the Supervisor, deploy an Argo CD instance, and Argo CD CLI. || argocd cluster add ArgoCD-vks-demo-admin@ArgoCD-vks-demo --kubeconfig vks.kubeconfig || ServiceAccount 'argocd-manager' created in namespace 'kube-system'; ClusterRole 'argocd-manager-role' created; ClusterRoleBinding 'argocd-manager-role-binding' created; Created bearer token secret for ServiceAccount 'argocd-manager' || This will create a service account 'argocd-manager' on the cluster ... with full cluster level privileges. || argocd app create guestbook ... --dest-server https://1

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/argo-cd/argocd-custom-resrouce-reference.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/argo-cd/argocd-custom-resrouce-reference.html`  (retrieved 2026-07-14)
  > spec.version  string  The ArgoCD carvel package version that is bundled with the ArgoCD Supervisor Service. || Check the vSphere Supervisor release notes to get the version that is supported for each ArgoCD Supervisor Service release.  [=> the server version is PER-RELEASE, not a constant. No default value, no enumerated list, and NO argocd CLI version anywhere on the page. Page states no VCF version number at all.]

- requested: `https://knowledge.broadcom.com/external/article/424897/vsphere-namespace-permissions-for-vks.html`
  landed: `https://knowledge.broadcom.com/external/article/424897/vsphere-namespace-permissions-for-vks.html`  (retrieved 2026-07-14)
  > Can edit — Supervisor: 'Full control to create, edit, and delete VKS clusters within the target vSphere Namespace via the Supervisor context.' VKS Cluster level: users are 'Automatically granted the cluster-admin role for all VKS clusters in that vSphere Namespace.' || Can view — VKS Cluster level: 'The user has no access inside the VKS clusters.'  [Permissions are scoped PER vSphere Namespace. THIS IS THE LOAD-BEARING REFUTATION of our reason #2: a VKS tenant with 'edit' ALREADY HAS cluster-admin on their own guest cluster, so the Kubernetes privilege-escalation gate does NOT stop them creati

- requested: `https://raw.githubusercontent.com/argoproj/argo-cd/master/util/rbac/rbac.go`
  landed: `https://raw.githubusercontent.com/argoproj/argo-cd/master/util/rbac/rbac.go`  (retrieved 2026-07-14)
  > var ProjectScoped = map[string]bool{
	ResourceApplications:    true,
	ResourceApplicationSets: true,
	ResourceLogs:            true,
	ResourceExec:            true,
	ResourceClusters:        true,
	ResourceRepositories:    true,
}   [PRIMARY SOURCE, ArgoCD's own code: 'clusters' IS project-scopeable. This REFUTES docs/vks-services/argocd.md:42.]

- requested: `https://raw.githubusercontent.com/argoproj/argo-cd/master/pkg/apis/application/v1alpha1/types.go`
  landed: `https://raw.githubusercontent.com/argoproj/argo-cd/master/pkg/apis/application/v1alpha1/types.go`  (retrieved 2026-07-14)
  > func validatePolicy(proj string, role string, policy string) error { ... if !rbac.ProjectScoped[resource] { return status.Errorf(codes.InvalidArgument, "invalid policy rule '%s': project resource must be: 'applications', 'applicationsets', 'repositories', 'exec', 'logs' or 'clusters', not '%s'", policy, resource) }   [line ~2748 — the AppProject role policy validator EXPLICITLY ACCEPTS 'clusters'.]

- requested: `https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/`
  landed: `https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/`  (retrieved 2026-07-14)
  > ### Application-Specific Policy — Some policy only have meaning within an application. It is the case with the following resources: applications, applicationsets, logs, exec. While they can be set in the global configuration, they can also be configured in AppProject's roles.   [THIS IS THE SENTENCE THAT MISLED US. It lists 4 resources and is silent on 'clusters'/'repositories' — but the CODE (above) accepts 6. The docs are INCOMPLETE relative to the implementation; they never actually say clusters is un-grantable.]

- requested: `https://argo-cd.readthedocs.io/en/stable/getting_started/`
  landed: `https://argo-cd.readthedocs.io/en/stable/getting_started/`  (retrieved 2026-07-14)
  > The above command installs a ServiceAccount (argocd-manager), into the kube-system namespace of that kubectl context, and binds the service account to an admin-level ClusterRole. || The rules of the argocd-manager-role role can be modified such that it only has create, update, patch, delete privileges to a limited set of namespaces, groups, kinds. However get, list, watch privileges are required at the cluster-scope for Argo CD to function.

- requested: `https://kubernetes.io/docs/reference/access-authn-authz/rbac/`
  landed: `https://kubernetes.io/docs/reference/access-authn-authz/rbac/`  (retrieved 2026-07-14)
  > A user can only create or update a RoleBinding or ClusterRoleBinding if they already have: [1] Permission to create/update the binding object itself, AND [2] Permission to grant (via a role or cluster role) all of the permissions referenced by the binding. ... grant them the `bind` verb on the referenced Role or ClusterRole.   [The rule is REAL — but see KB 424897: on VKS the tenant already holds cluster-admin on their own guest cluster, so this gate does not bind them.]


---

## [PRIMARY_SOURCED_9_1] Does a VMware VKS 9.1 GUEST (workload) cluster ship the Kubernetes Gateway API CRDs (gateway.networking.k8s.io) by default — or must we install them ourselves (as this repo's istio_ensure_gwapi_crds does, pinned v1.5.1)? If it does NOT ship them, our Gateway-API route path degrades to classic Istio, which needs the shared ingress gateway that the VKS Istio package ships DISABLED by default.

YES — a VKS 9.1 guest/workload cluster SHIPS THE GATEWAY API CRDs BY DEFAULT. The feared degradation does not happen, and the repo's central worry ("the Gateway-API path is a KinD artefact that will not exist on a real lab") is REFUTED by primary 9.1 sources.

THE MECHANISM (this is the part that matters, and it is not the Istio add-on):
1. `gateway-api` is a COMPONENT OF THE VKr — the VMware Kubernetes release that IS the guest cluster image. Broadcom's VKr Release Notes (a 9-1 URL, 200, zero redirects) list it per VKr with an explicit version:
     VKr 1.36.1 -> gateway-api 1.5.1     <-- EXACTLY our pin
     VKr 1.35.5 / 1.35.2 / 1.35.0 -> gateway-api 1.4.0
     VKr 1.34.8 -> gateway-api 1.3.0
2. HOW it gets into the cluster, and it CHANGED at 9.1. Per the VKS 3.7 Release Notes (also a 9-1 URL, 200, zero redirects):
   - BEFORE VKr 1.36: Gateway API was in the cluster's `ClusterBootstrap` **additionalPackages** list => installed into every guest cluster at bootstrap.
   - FROM VKS 3.7.0 / VKr 1.36: "VKS manages Gateway API as an add-on through the Add-on Management framework", and it is "no longer included in the ClusterBootstrap additionalPackages list". It is still VKS-MANAGED AND ON BY DEFAULT — the doc gives an explicit OPT-OUT: set `addon.addons.kubernetes.vmware.com/gateway-api: unmanaged` on the Cluster resource. An opt-out label is only meaningful if the default is opted-IN.
3. The Istio add-on is a RED HERRING. It does NOT ship the CRDs, and it does not need to — Broadcom's Istio Package Reference says: "Support for K8s Gateway APIs is limited by the DELIVERED gateway-api version FOR A GIVEN VKr." The VKr delivers them; the mesh consumes them. This is also why Broadcom can ship the shared ingress gateway disabled ("gateways.ingress.enabled ... the default value is false" — same page): they expect you to use the Gateway API, which auto-provisions its own gateway. Our gateway-api route path is not a workaround — it is BROADCOM'S RECOMMENDED PATH.

THE CONTRADICTION I HAD TO RESOLVE (two sources disagree; do not let the next session re-open this):
- VMware's own VCF blog (Andrechak, 2026-03-28) states flatly: "Gateway API CRDs are not included in the Istio add-on and must be installed separately on each workload cluster", and does `kubectl apply --server-side ... v1.4.0/standard-install.yaml`. This is the source that would have vindicated our fear.
- Bob Bauer (Medium, 2026-04-16, on VKS 3.6.0 / VKr v1.35.0 / Istio 1.28.2+vmware.1-vks.1) states: "Gateway API CRDs (Built-in): Newer VKS clusters include these by default."
RESOLUTION: Bauer is right, and the blog's FIRST CLAUSE is also right — it is the second clause that over-reaches. "Not included in the ISTIO ADD-ON" is TRUE (the add-on genuinely does not ship them). "Therefore you must install them on each workload cluster" is the non-sequitur: the VKr already did. Note the blog pins v1.4.0 — which is EXACTLY what VKr 1.35.x already delivers, so his `kubectl apply` was very likely a no-op/re-apply he never checked. A blog does not outrank the VKr component list and the VKS release notes. I also ruled out the other candidate installer: Avi's AKO (auto-installed in VKS) explicitly does NOT install them — "The GatewayClass, Gateway, and Route CRD definitions must be installed on the cluster before enabling the GatewayAPI feature in AKO." So the VKr is the only thing that puts them there, and it does.

BONUS — THE REDIRECT TRAP IS REAL BUT I FOUND IT IS THE WRONG SHAPE, AND THAT MATTERS:
I curled 7 vendor URLs. NOT ONE `/9-1/` URL 301'd to `/9-0/`. They return 200 (the page exists in the 9.1 tree) or 404 (the page was RENAMED — e.g. `vks-standard-packages-release-notes.html` 404s at 9-1 because 9.1 renamed Standard Packages to VKS Add-ons: `vks-addons-release-notes.html` is 200 at 9-1). The page that DID redirect was a `/latest/` URL: `.../vsphere-supervisor-services-and-standalone-components/latest/vmware-tkrs-release-notes.html` -> 1 redirect -> `.../vcf-service-administration-and-development/9-0/...`. So the mechanism is `latest` == the 9-0 TREE. Most search results hand you `/latest/` URLs — THOSE are the 9.0-read-as-9.1 trap. Hand-editing the version into the path to `/9-1/` is SAFE and is how I got the settling sources. This corrects the repo's standing belief that 9.1 URLs 301 to 9.0.

RESIDUAL RISK (real, and it is now the OPPOSITE risk from the one we feared): the danger is no longer "the CRDs are absent" — it is "the CRDs are PRESENT, VKS-MANAGED, AND ON A VERSION THE VKr CHOSE, NOT US." On VKr 1.35.x that is v1.4.0, not our v1.5.1.

### What we would change

THE HEADLINE: the standing BLOCKING finding in CLAUDE.md:713-727 ("ADVERSARY 2026-07-13 — the Gateway-API path is a KinD ARTEFACT ... on a real VKS guest cluster, if the CRDs are absent ... 47-attach-istio.sh dies") is REFUTED. Its premise ("nothing in this repo installs the Gateway API CRDs, and VKS may not either") is false: the VKr installs them. Retract that finding IN PLACE (record the arc — claim -> feared-wrong -> re-confirmed) rather than deleting it. Correspondingly docs/vks-services/istio.md:84 ("Works when the VKS package's shared gateway is OFF (the default)? -> Yes") is CORRECT and can be upgraded from KinD-verified to primary-sourced-for-9.1. Our preferred route API is also Broadcom's recommended one — that is WHY they ship the shared gateway disabled.

BUT THE RISK INVERTS, AND THIS IS THE ACTIONABLE PART. It is no longer "the CRDs are missing"; it is "they are PRESENT, VKS-MANAGED, and on the VKr's version, not ours."

1. scripts/lib/istio.sh:135-138 — the early-return (`kubectl get crd httproutes... -> "already present" -> return 0`) is the RIGHT behaviour on a real lab (defer to VKS), and by luck it is what we already do. But it is VERSION-BLIND: on VKr 1.35.x the cluster carries gateway-api **v1.4.0** while GATEWAY_API_VERSION=v1.5.1, and we would proceed silently. Make the early-return READ the CRD's `gateway.networking.k8s.io/bundle-version` annotation, log it, and WARN loudly on mismatch. Right now a v1.4.0 cluster is indistinguishable from a v1.5.1 one in our logs — the exact "present is not the claim" failure this repo keeps re-learning.

2. scripts/lib/istio.sh:167 — `kubectl apply --server-side --force-conflicts` is now a HAZARD, not a fallback. On a VKS cluster this would (a) require cluster-scoped CRD write, which a TENANT does not have, and (b) if run by an admin, STEAL FIELD OWNERSHIP from the VKS Add-on Manager and shove v1.5.1 onto a cluster whose add-on will reconcile it back to the VKr's version — a fight we lose, silently, and our post-condition at istio.sh:~183 (`bundle-version == $ver`) would pass at apply time and be reverted afterwards. Worse: gateway-api v1.5+ ships a `safe-upgrades` ValidatingAdmissionPolicy that DENIES installing CRDs OLDER than current — so pushing v1.5.1 onto a VKr-1.35 (v1.4.0) cluster can make the VKS add-on's own reconcile back to 1.4.0 be DENIED, i.e. we would BREAK a platform-managed add-on. GATE THIS: never apply CRDs when the cluster is VKS-managed (detect the Cluster's addon label / the CRD's existing field manager), and certainly never in INGRESS_CONTROLLER=istio-existing (attach/tenant) mode. Our own KinD path can keep installing them.

3. scripts/48-istio-preflight.sh:55-60 — the ABSENT branch's advice is now WRONG FOR A REAL LAB. On VKS, "Gateway API CRDs: ABSENT" does not mean "install them" and does not mean "fall back to classic". It means the platform team OPTED OUT of the VKS-managed add-on (`addon.addons.kubernetes.vmware.com/gateway-api: unmanaged` on the Cluster) or the cluster is on a pre-1.34 VKr. The actionable message is "ask the mesh/platform admin to re-enable the VKS gateway-api add-on" — not a kubectl apply the tenant cannot run. Also add the PRESENT branch's version to the report.

4. .env.example:473 (GATEWAY_API_VERSION=v1.5.1) + scripts/check-gwapi-istio-alignment.sh + Makefile:144 — the gate is correct FOR THE ISTIO WE INSTALL OURSELVES (KinD), but on a real lab BOTH the mesh (VKS Istio add-on 1.28.7 or 1.30.0) and the CRDs (VKr) are chosen by Broadcom and aligned by them. The gate must not be read as a claim about the lab. Document that. Happy coincidence worth recording: VKr **1.36.1 ships gateway-api 1.5.1**, exactly our pin — so a 9.1/VKr-1.36 lab is aligned with us out of the box; a VKr-1.35 lab is NOT (1.4.0).

5. renovate.json:168 — the "HOLD gateway-api at <v1.6.0" cap is now doubly justified and should say so: not only does Istio 1.30.2 vendor v1.5.1, but VKr 1.36.1 DELIVERS v1.5.1. Moving our pin past what the VKr ships would guarantee divergence from every real lab.

6. The air-gap win: we still WANT the CRD yaml in the bundle (10-mirror-pull.sh) for the KinD/self-installed path, but on a real air-gapped VKS lab the CRDs arrive with the VKr and need no mirroring at all. Note that in docs/sneakernet.md so nobody thinks the bundle is load-bearing for the lab.

**Would settle it:** ON A REAL VKS 9.1 GUEST CLUSTER, four commands — the first two settle the headline, the last two settle the version hazard:

  # 1. Are they there at all, and WHO owns them? (The field manager is the forgery-proof part —
  #    'present' is not the claim; 'VKS put them there' is.)
  kubectl get crd | grep gateway.networking.k8s.io
  kubectl get crd httproutes.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}{range .metadata.managedFields[*]}{.manager}{" "}{.operation}{"\n"}{end}'
  #    EXPECT: bundle-version v1.5.1 on VKr 1.36.1, or v1.4.0 on VKr 1.35.x.
  #    A manager like 'kapp'/'tanzu'/an addon controller == VKS-managed => our apply must NOT run.

  # 2. Which VKr is this cluster, and is the gateway-api add-on managed or opted out?
  kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.topology.version}{"\t"}{.metadata.labels}{"\n"}{end}'
  #    Look for  addon.addons.kubernetes.vmware.com/gateway-api: unmanaged  (opt-out => CRDs absent).

  # 3. Does Istio actually accept a Gateway (i.e. is the gateway-api route path live)?
  kubectl get gatewayclass istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'

  # 4. The version hazard, non-destructively:
  kubectl apply --server-side --dry-run=server -f gateway-api-v1.5.1/standard-install.yaml
  #    On a VKr-1.35 (v1.4.0) cluster this is the command that tells you whether we would be
  #    UPGRADING a platform-managed add-on. If it does not error, that is WORSE, not better.

PAGE STILL WORTH OBTAINING (I could not reach it; it 404s in the 9.1 tree because of the Standard-Package -> VKS-Add-on rename): the 9.1 "Istio Add-on Reference" successor to
.../9-0/.../standard-package-reference/istio-package-reference.html — to re-confirm, in the 9.1 tree, the "gateways.ingress.enabled default false" line I currently have only from the 9-0 page. Find it by browsing the 9.1 VKS Add-ons TOC (NOT via a /latest/ URL — /latest/ resolves to the 9-0 tree, which is the actual redirect trap).

### Sources

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vkr-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vkr-release-notes.html`  (retrieved 2026-07-14)
  > gateway-api is listed as a bundled component of each VKr, with a version per release: VKr 1.36.1 -> "gateway-api 1.5.1"; VKr 1.35.5 -> "gateway-api 1.4.0"; VKr 1.35.2 -> "gateway-api 1.4.0"; VKr 1.35.0 -> "gateway-api 1.4.0"; VKr 1.34.8 -> "gateway-api 1.3.0". Page product version: VMware Cloud Foundation Service Administration and Development 9.1.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-release-notes/vmware-tanzu-kubernetes-grid-service-37-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-release-notes/vmware-tanzu-kubernetes-grid-service-37-release-notes.html`  (retrieved 2026-07-14)
  > "Starting with VKS 3.7.0 and VKr 1.36, VKS manages Gateway API as an add-on through the Add-on Management framework." / "Gateway API is no longer included in the ClusterBootstrap additionalPackages list for VKS clusters running VKr 1.36 or later." / "you can persistently opt a VKS cluster out of VKS-managed Gateway API add-on by setting the following label on the Cluster resource: addon.addons.kubernetes.vmware.com/gateway-api: unmanaged". Page product version: VCF Service Administration and Development 9.1; VKS 3.7.0+v1.36.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html`
  landed: `HTTP 404 (no redirect) — the 9.1 tree has no 'standard-package-reference' path; 9.1 renamed Standard Packages to VKS Add-ons. Fell back to the 9-0 page below.`  (retrieved 2026-07-14)
  > [404] This is the RENAME, not a redirect: 'vcf package install' (Standard Package, 9.0) -> 'vcf addon install create' (VKS Add-on, 9.1). Recorded because a naive 9.1 fetch of this path silently fails rather than silently serving 9.0.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html`  (retrieved 2026-07-14)
  > "Support for K8s Gateway APIs is limited by the delivered gateway-api version for a given VKr." and "gateways.ingress.enabled is true in the data values, the default value is false." NOTE: this is the 9-0 tree, fetched DELIBERATELY because the 9-1 equivalent path 404s (renamed). Grade the ingress-gateway-default fact as 9.0-doc; the VKr-delivers-gateway-api fact is CORROBORATED by the two 9-1 sources above.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-addons-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-addons-release-notes.html`  (retrieved 2026-07-14)
  > VKS Istio add-on versions: 1.30.0+vmware.1-vks.1 and 1.28.7+vmware.1-vks.1. Known issue (3.6.0+20260320): "The VKS Istio add-on is currently incompatible with clusters provisioned using the Cilium CNI; installation will fail as a result of a known limitation in the current Cilium add-on version." The page does NOT claim the Istio add-on installs Gateway API CRDs. Page product version: 9.1.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/running-tkg-service-clusters/tkg-service-components.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/running-tkg-service-clusters/tkg-service-components.html`  (retrieved 2026-07-14)
  > NULL RESULT, recorded honestly: the 9.1 'VKS Components' page lists Authentication Webhook, CSI, CNI (Antrea default/Calico), Cloud Provider Plugin, Pinniped — and makes NO mention of the Gateway API. Ingress is mentioned only as "Cluster ingress - Third-party ingress controller ... such as Contour." So this page CANNOT be used to prove the CRDs ship; the VKr release notes can, and do.

- requested: `https://blogs.vmware.com/cloud-foundation/2026/03/28/ingress-nginx-to-gateway-api-istio-vks-migration/`
  landed: `https://blogs.vmware.com/cloud-foundation/2026/03/28/ingress-nginx-to-gateway-api-istio-vks-migration/`  (retrieved 2026-07-14)
  > THE CONTRADICTING SOURCE (VMware VCF blog, John Andrechak, 2026-03-28): "Gateway API CRDs are not included in the Istio add-on and must be installed separately on each workload cluster", with `kubectl apply --server-side -f .../gateway-api/releases/download/v1.4.0/standard-install.yaml` and "Istio 1.28/1.29 requires Gateway API CRDs v1.4.x. Installing v1.5.x causes istiod to crash due to API field mismatches." Also: "Istio VKS add-on ships with gateways.ingress.enabled: false" and "The key configuration change: set gateways.ingress.enabled: true in the Istio add-on YAML." Article names NO VCF/

- requested: `https://medium.com/@bob-bauer/istio-on-vmware-vks-single-cluster-install-a574a3c95bbb`
  landed: `https://medium.com/@bob-bauer/istio-on-vmware-vks-single-cluster-install-a574a3c95bbb`  (retrieved 2026-07-14)
  > COMMUNITY, and I graded it as such: "Gateway API CRDs (Built-in): Newer VKS clusters include these by default. These are required to expose applications using the modern Gateway and HTTPRoute objects rather than the legacy VirtualService." It is an UNVERIFIED prerequisites bullet — the author shows NO kubectl output proving presence. On VKS Service 3.6.0+1.35 / cluster v1.35.0+vmware.2 / Istio 1.28.2+vmware.1-vks.1, installed with `vcf package install istio -p istio.kubernetes.vmware.com -v 1.28.2+vmware.1-vks.1`, and his values set `ingress: enabled: false` with the comment "we are usiing Gat

- requested: `https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/avi-load-balancer/avi-kubernetes-operator/2-1/avi-kubernetes-operator-guide-2-1/gateway-api/gateway-api-v1.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-security-load-balancing/avi-load-balancer/avi-kubernetes-operator/2-1/avi-kubernetes-operator-guide-2-1/gateway-api/gateway-api-v1.html`  (retrieved 2026-07-14)
  > RULES OUT THE ALTERNATIVE INSTALLER. AKO (auto-installed in VKS when Avi is the LB) does NOT install the CRDs: "The GatewayClass, Gateway, and Route CRD definitions must be installed on the cluster before enabling the GatewayAPI feature in AKO." So AKO is not the thing putting them on the cluster — the VKr is.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/vmware-tkrs-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/vmware-tkrs-release-notes.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > THE REDIRECT TRAP, CAUGHT IN THE ACT — and it is NOT the shape the repo believes. A `/latest/` URL 301'd into the **9-0** tree (1 redirect). By contrast every `/9-1/` URL I curled returned 200 or 404, NEVER a redirect to 9-0. CONCLUSION: `latest` == 9.0 content. Search engines hand you `/latest/` URLs, which is how 9.0 gets read as 9.1. Hand-editing `/9-1/` into the path is safe and is how the settling sources above were obtained.


---

## [NINE_ZERO_DOC_READ_AS_9_1] On VMware VKS 9.1: is Istio installed on a GUEST cluster as a "Standard Package" (`vcf package install istio`) or has 9.1 renamed it to a "VKS Add-on" (`vcf addon install create`)? What is the exact CLI sequence (incl. `vcf package repository add` and the default-values-file flow)? Is its ingress gateway enabled or DISABLED by default? And for an AIR-GAPPED cluster: where do the add-on's OWN istiod/proxy images come from, and can they be mirrored/repointed?

METHOD NOTE: the deep-research skill's `Workflow` tool is not available in this environment, so I did the equivalent BY HAND with WebSearch + WebFetch (11 fetches, 5 searches, redirect-tracked). Saying so per instructions.

THE REDIRECT TRAP, MEASURED. Every Istio-specific Broadcom page exists ONLY under 9-0. Three distinct behaviours observed:
  (a) `.../9-1/.../installaing-and-using-istio/install-istio.html` -> **HTTP 404**. There is no 9.1 Istio install page.
  (b) `.../vsphere-supervisor-services-and-standalone-components/latest/...` -> **301 Moved Permanently -> .../vcf-service-administration-and-development/9-0/...** (observed 3x, on the Istio package reference, the private-Harbor page, and the package-repository page). This is the trap in its purest form: "latest" IS 9.0.
  (c) ONE genuine 9-1 page exists and does NOT redirect: the **VKS Add-ons Release Notes** (`.../9-1/release-notes/vks-addons-release-notes.html`). It is the only 9.1-grade evidence below; everything Istio-specific is 9.0 content.

(1) PACKAGING — IT IS A RENAME, AND IT IS REAL, BUT NO 9.1 ISTIO PAGE PROVES IT FOR ISTIO.
The genuine 9-1 page states verbatim: "Effective with the 3.7.0 release version, Broadcom has formally transitioned from the legacy 'Core' and 'Standard' package terminology to a unified VKS Add-ons framework." So on VCF 9.1 / VKS 3.7.0 the model IS "VKS Add-ons". It also names Istio's 9.1 version: **1.30.0+vmware.1-vks.1** (prev 1.28.7), and a hard limitation: "The VKS Istio add-on is currently incompatible with clusters provisioned using the Cilium CNI; installation will fail."
BUT: the underlying artifact is unchanged — it is still a Carvel package named `istio.kubernetes.vmware.com`, and the ONLY Istio install procedure Broadcom publishes anywhere is the 9.0 `vcf package install` one. `vcf addon install create istio` is NOT documented on any Broadcom page I could fetch. The `vcf addon` CLI itself IS primary-sourced (command reference), and a Broadcom NFS-client page shows the shape: `vcf addon install create nfs-client --cluster-name wl-calico -n test-ns --addon-release-name nfs-client.kubernetes.vmware.com.4.13.2-vmware.1-vks.1 --values-config-file nfs-client-data-values.yaml -y`. Both CLIs work; `vcf package` is explicitly labelled LEGACY.

(2) THE EXACT SEQUENCE.
`vcf package repository add` is **NOT required** on 9.1. Verbatim (9-0): "This procedure is required only when using the legacy package management system, and not required when using Add-on management to install standard packages." And: "VKS releases 3.5 and later include an embedded version of the standard package repository installed on all VKS clusters." (If you DO use the legacy path: `vcf package repository add standard-package-repo --url projects.packages.broadcom.com/vsphere/supervisor/packages/<date>/vks-standard-packages:v<ver> -n tkg-system`.)
Legacy/package path (9.0-doc, verbatim):
  1. `vcf package available get istio.kubernetes.vmware.com -n tkg-system`
  2. `vcf package available get istio.kubernetes.vmware.com/1.25.3+vmware.1-vks.1 --default-values-file-output istio-data-values.yaml -n tkg-system`
  3. `kubectl create ns istio-installed`
  4. `vcf package install istio -p istio.kubernetes.vmware.com -v 1.25.3+vmware.1-vks.1 --values-file istio-data-values.yaml -n istio-installed`

THE `-n` DIVERGENCE IS CONFIRMED AND IS A REAL LANDMINE:
  * `vcf package ... -n` = a namespace INSIDE the guest cluster (`tkg-system` to look up, `istio-installed` to install into). The 9-0 page is explicit.
  * `vcf addon install create ... -n/--namespace` = per the VCF CLI command reference, verbatim: "**Namespace for the workload cluster**" — i.e. the vSphere Namespace in which the cluster object lives (it pairs with `--cluster-name`; the CLI targets the Supervisor). NOTE HONESTLY: the reference does not spell out "vSphere Namespace" in so many words; that reading is an INFERENCE from `--cluster-name` + the Supervisor-side `vcf addon repository register/list/get/delete` subcommands. Do not copy a `-n` value between the two CLIs. Same flag, opposite meaning.

(3) INGRESS GATEWAY: **DISABLED BY DEFAULT — CONFIRMED.** Istio Package Reference, verbatim: `istio.gateways.ingress.enabled` default **false**; `istio.gateways.egress.enabled` default **false**. Our repo's existing claim is correct and survives. (Provenance: 9.0 content; the 9-1 page 404s.)

(4) AIR-GAP — THE ANSWER, AND IT IS NOT THE ONE WE ASSUMED.
Where the images come from: the Carvel imgpkg bundle at **`projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.7.0-20260618/vks-addons:3.7.0-20260618`** (9-1 release notes, verbatim). An air-gapped guest cluster cannot reach it.

CRITICAL NEGATIVE FINDING: **the Istio VKS package exposes NO image-registry / hub / repository key at all.** There is no `global.hub` equivalent in its data values. So the mechanism we use in `46-install-istio.sh` (helm `global.hub=<Harbor>`) has NO counterpart in the VKS add-on. Trying to "repoint the images" via the values file is not a thing.

The SUPPORTED mechanism is bundle RELOCATION, not repointing:
  a. Mirror the whole add-on/package repository bundle with imgpkg (9-0, verbatim):
     `imgpkg copy -b projects.packages.broadcom.com/vsphere/supervisor/packages/<ver>/vks-standard-packages:v<ver> --to-repo harbordomain.com/packages/repo --registry-ca-cert-path xxx/ca.crt`
     (or `--to-tar temp.tar` then `imgpkg copy --tar=temp.tar --to-repo ...` for a true sneakernet.)
  b. Point the repository at the private copy — Add-ons path (9-0, verbatim): "Update `spec.fetch.imgpkgBundle.imageURL` to use a URL with the private registry endpoint" on the `AddonRepositoryInstall` (kind `AddonRepositoryInstall`, apiVersion `addons.kubernetes.vmware.com/v1alpha1`, ns `vmware-system-vks-public`). Legacy path: the `--url` of `vcf package repository add`.
  c. Registry credentials: "Create secret with registry credential" (`kubectl create secret docker-registry`) in the cluster, propagated with `SecretExport`. The Istio reference adds, verbatim: "When running in an air-gapped environement, the credential to access the private registry is created in the VKS cluster before installing Istio package" — a Secret is then "automatically created in the Istio control plane (root) namespace" (and in the ingress/egress gateway namespaces if enabled). For sidecar/gateway INJECTION into app namespaces you must additionally set `istio.meshConfig.imagePullSecrets`.

WHY (a) IS SUFFICIENT — the part that answers "we neither mirror nor repoint those": Carvel relocation rewrites the refs for you. imgpkg air-gapped docs, verbatim: "The bundle, and all images referenced in the bundle, are copied to the destination registry" and "Note that the `.imgpkg/images.yml` file was updated with the destination registry locations of the images." imgpkg resolves each referenced image BY DIGEST **in the same repository as the bundle**. So relocating the vks-addons bundle into Harbor drags istiod/proxyv2 along and makes the package pull them from Harbor — WITHOUT any hub key. That is precisely why no hub key exists.

AND the 9-1 page tells you Broadcom expects exactly this, verbatim: "To ensure that existing customer deployment scripts, **air-gapped registry syncs**, and CI/CD pipelines continue to function without modification, the registry endpoint structure remains unchanged."

BOTTOM LINE FOR US: on a real air-gapped VKS lab, the mesh's own images are NOT our problem *provided we keep attaching* (`INGRESS_CONTROLLER=istio-existing`) — the platform team relocates the add-on bundle. If we ever needed to INSTALL Istio the VKS way on an air-gapped guest cluster, our crane-based mirror could not do it: it would require `imgpkg copy` of the vks-addons bundle (imgpkg is the tool we explicitly ruled out in `docs/decisions/` because it cannot reproduce per-image `registry/project/repo:tag`) — and here that "limitation" is exactly the required behaviour.

### What we would change

WHAT WE WOULD CHANGE:

1. docs/vks-services/istio.md:22 — the "Install (package CLI)" row is CORRECT but must be relabelled **LEGACY**. Broadcom states verbatim that `vcf package repository add` (and by extension the legacy package flow) is "required only when using the legacy package management system". On 9.1 (VKS 3.7.0) the model is VKS Add-ons. Our row implies it is THE way; it is the OLD way.

2. docs/vks-services/istio.md:23 — the "Install (VCF 9 addon CLI)" row is graded `community (VMware VCF blog)`. UPGRADE the framing: the `vcf addon` CLI, its flags, and the Add-ons transition are now PRIMARY-SOURCED (the VCF CLI command reference + a genuine, non-redirecting **9-1** release-notes page). BUT keep a caveat: Broadcom publishes NO `vcf addon install create istio` example — only an nfs-client one. The Istio-specific invocation remains inferred.

3. docs/vks-services/istio.md:23 — ADD THE `-n` LANDMINE. Our row shows `vcf addon install create istio --cluster-name $VKS_CLUSTER -y` with no `-n`. The reference says `-n, --namespace` = "Namespace for the workload cluster" (the vSphere Namespace, alongside `--cluster-name`) — the OPPOSITE of `vcf package`'s `-n istio-installed` (a guest-cluster namespace) on the line directly above it. Two adjacent rows in our own table use the same flag with opposite meanings and nothing says so.

4. docs/vks-services/istio.md:24 — versions are stale. Add 9.1's real string: **`1.30.0+vmware.1-vks.1`** (VKS add-ons 3.7.0+20260618), and note 1.28.7 as the prior. Grade: 9.1-page-sourced (this one is NOT a redirect).

5. docs/vks-services/istio.md:26 — **the air-gap row is WRONG BY OMISSION, and this is the highest-value correction.** It currently says only `meshConfig.imagePullSecrets`. That is the *injection* half. The load-bearing half is that **the Istio VKS package exposes NO hub/registry/imageRegistry key at all** — there is no `global.hub` equivalent, so the images CANNOT be repointed via the values file. The images live in the Carvel bundle at `projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.7.0-20260618/vks-addons:3.7.0-20260618`, and the ONLY supported air-gap mechanism is **relocating the whole bundle with `imgpkg copy --to-repo <harbor>`** and pointing `spec.fetch.imgpkgBundle.imageURL` (AddonRepositoryInstall) at the copy — Carvel then resolves istiod/proxyv2 BY DIGEST from the same repo. Rewrite the row to say relocation-not-repointing.

6. docs/vks-services/istio.md — ADD a NEW known limitation, currently absent from our doc entirely: **"The VKS Istio add-on is currently incompatible with clusters provisioned using the Cilium CNI; installation will fail."** (9.1 release notes, verbatim.) If the lab's guest cluster runs Cilium, the Istio add-on path is dead on arrival and our whole `istio-existing` attach premise collapses — worth a preflight check.

7. images/images.txt:57-60 — we mirror upstream `istio/pilot:1.30.2` + `istio/proxyv2:1.30.2` from docker.io. That is CORRECT for OUR helm install path (`scripts/46-install-istio.sh` uses `global.hub=$HARBOR/$PROJECT/istio`) and stays. But note it is NOT what a VKS Istio ADD-ON uses (VMware-built `1.30.0+vmware.1-vks.1`, relocated with the bundle). Our mirror inventory does not and need not cover the add-on's images — because we ATTACH (`scripts/47-attach-istio.sh`), so the mesh's images are the platform team's relocation problem. Worth stating explicitly in the doc so nobody "fixes" images.txt by adding VMware-built tags we cannot pull.

8. NEW STRUCTURAL FINDING for docs/decisions/ — our air-gap toolchain chose **crane** and explicitly RULED OUT imgpkg (because imgpkg relocates by digest into one `--to-repo` under forced `sha256-*.imgpkg` tags and cannot reproduce per-image `registry/project/repo:tag`). For the VKS add-on that "limitation" is precisely the REQUIRED behaviour. So: if we ever needed to INSTALL Istio the VKS way on an air-gapped guest cluster (rather than attach), **crane cannot do it and imgpkg is mandatory.** That is a real, currently-undocumented boundary of our mirror design.

9. scripts/47-attach-istio.sh:66 — the die message ("no istiod found — use INGRESS_CONTROLLER=istio to INSTALL Istio instead") is now known to be the right advice on a lab ONLY if the cluster is not Cilium-CNI and only because the add-on's shared ingress gateway is off by default (CONFIRMED false). No change needed; the confirmation strengthens it.

WHAT SURVIVES UNCHANGED: the ingress-gateway-DISABLED-by-default fact (`istio.gateways.ingress.enabled: false`) is CONFIRMED verbatim — our repo was right, and the entire `47-attach-istio.sh` Gateway-API-preferred design rests on it correctly.

**Would settle it:** ON A REAL VKS 9.1 LAB — five commands, in order, each settling one open item:

1. WHICH CLI THE LAB ACTUALLY HAS (settles package-vs-addon for THIS build):
   vcf addon --help ; vcf package --help ; vcf version
   Then: vcf addon repository list
   Expect (if 3.7.0): an add-on repository whose imageURL is projects.packages.broadcom.com/.../vks-addons:3.7.0-<date>

2. IS ISTIO OFFERED AS AN ADD-ON, AND AT WHAT VERSION (settles the 1.30.0+vmware.1-vks.1 string):
   vcf addon available list --cluster-name $VKS_CLUSTER -n $VSPHERE_NAMESPACE
   # legacy cross-check, run INSIDE the guest cluster:
   kubectl -n tkg-system get packages | grep istio

3. THE `-n` SEMANTICS (settles the landmine — the ONE thing I could not prove from docs):
   vcf addon install create istio --cluster-name $VKS_CLUSTER -n $VSPHERE_NAMESPACE --dry-run 2>&1 | head
   # then deliberately pass a GUEST namespace instead and confirm it errors:
   vcf addon install create istio --cluster-name $VKS_CLUSTER -n istio-installed --dry-run 2>&1 | head
   Expect: the vSphere-Namespace form resolves the cluster; the guest-namespace form fails to find it.

4. WHERE THE IMAGES ACTUALLY COME FROM (the critical air-gap question — this is the ground truth that beats every doc):
   kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   kubectl -n tkg-system get packages -o jsonpath='{range .items[?(@.spec.refName=="istio.kubernetes.vmware.com")]}{.spec.template.spec.fetch[0].imgpkgBundle.image}{"\n"}{end}'
   kubectl get addonrepositoryinstall -A -o jsonpath='{.items[*].spec.fetch.imgpkgBundle.imageURL}{"\n"}'
   Expect on an air-gapped lab: the istiod image host is the SITE'S HARBOR, not projects.packages.broadcom.com — which would CONFIRM that bundle relocation repoints the workload images (my central claim). If it still says projects.packages.broadcom.com, my relocation claim is REFUTED for VKS and there must be some other mechanism.

5. IS THE INGRESS GATEWAY REALLY OFF, AND ARE THE GATEWAY-API CRDs THERE (our repo's open UNVERIFIED):
   kubectl get ns istio-ingress ; kubectl -n istio-ingress get svc
   kubectl get crd httporoutes.gateway.networking.k8s.io 2>/dev/null || kubectl get crd | grep gateway.networking.k8s.io
   kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'

PAGE I COULD NOT OBTAIN (and would settle item 1-3 without a lab): a 9.1-tree Istio install page. It does not exist — `.../9-1/.../installaing-and-using-istio/install-istio.html` returns HTTP 404, and every other Istio URL either is 9-0 or 301-redirects to 9-0. If Broadcom publishes one, it supersedes everything above. Also worth obtaining: `vcf addon install create --help` output from a real 9.1 VCF CLI, which is the authoritative statement of the `-n` semantics that the web command-reference leaves ambiguous.

### Sources

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-addons-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vks-addons-release-notes.html`  (retrieved 2026-07-14)
  > Effective with the 3.7.0 release version, Broadcom has formally transitioned from the legacy 'Core' and 'Standard' package terminology to a unified VKS Add-ons framework. | Istio latest version in v3.7.0+20260618: 1.30.0+vmware.1-vks.1 (previous 1.28.7+vmware.1-vks.1). | The VKS Istio add-on is currently incompatible with clusters provisioned using the Cilium CNI; installation will fail as a result of a known limitation. | The 3.7.0-validated VKS Add-ons are hosted at the historical distribution path: projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.7.0-20260618/vks-ad

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/installing-standard-packages-on-tkg-cluster-using-tkr-for-vsphere-8-x/installaing-and-using-istio/install-istio.html`
  landed: `HTTP 404 NOT FOUND (no 9-1 Istio install page exists)`  (retrieved 2026-07-14)
  > The server returned HTTP 404 Not Found. — THIS IS ITSELF THE FINDING: there is no 9.1 Istio install page; the only Istio install procedure Broadcom publishes is the 9.0 one.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/installing-standard-packages-on-tkg-cluster-using-tkr-for-vsphere-8-x/installaing-and-using-istio/install-istio.html`
  landed: `https://access.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../installaing-and-using-istio/install-istio.html (host redirect only; VERSION STAYED 9-0)` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > vcf package available get istio.kubernetes.vmware.com -n tkg-system | vcf package available get istio.kubernetes.vmware.com/1.25.3+vmware.1-vks.1 --default-values-file-output istio-data-values.yaml -n tkg-system | kubectl create ns istio-installed | vcf package install istio -p istio.kubernetes.vmware.com -v 1.25.3+vmware.1-vks.1 --values-file istio-data-values.yaml -n istio-installed  [the -n flag specifies the target namespace INSIDE the guest cluster]. The documentation does not address private registries, air-gapped environments, or imagePullSecrets for Istio installation.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../standard-package-reference/istio-package-reference.html  [301 Moved Permanently — 'latest' IS 9.0]` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > istio.gateways.ingress.enabled: default value is false. istio.gateways.egress.enabled: default value is false. | 'When running in an air-gapped environement, the credential to access the private registry is created in the VKS cluster before installing Istio package.' | 'a Secret containing the registry credential is automatically created in the Istio control plane (root) namespace' | 'Enabling Istio sidecar or gateway injection requires a Secret with registry credential in the application's namespace, and its name must be specified in istio.meshConfig.imagePullSecrets.' | NEGATIVE FINDING: the

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/installing-standard-packages-on-tkg-cluster-using-tkr-for-vsphere-8-x/create-the-package-repository.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../create-the-package-repository.html  [301 Moved Permanently — 'latest' IS 9.0]` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > vcf package repository add REPOSITORY-NAME --url REPOSITORY-URL -n REPOSITORY-NAMESPACE | Sample: vcf package repository add standard-package-repo --url projects.packages.broadcom.com/vsphere/supervisor/packages/2025.8.19/vks-standard-packages:v2025.8.19 -n tkg-system | 'This procedure is required only when using the legacy package management system, and not required when using Add-on management to install standard packages.'

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/push-standard-packages-to-a-private-harbor-registry.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../push-standard-packages-to-a-private-harbor-registry.html  [301 Moved Permanently — 'latest' IS 9.0]` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > imgpkg copy --bundle projects.packages.broadcom.com/vsphere/supervisor/packages/2025.1.7/vks-standard-packages:v2025.1.7 --to-tar temp.tar  ;  imgpkg copy --tar=temp.tar --to-repo harbordomain.com/packages/repo --registry-ca-cert-path xxx/ca.crt  ;  (direct) imgpkg copy -b projects.packages.broadcom.com/vsphere/supervisor/packages/2025.1.7/vks-standard-packages:v2025.1.7 --to-repo harbordomain.com/packages/repo --registry-ca-cert-path xxx/ca.crt

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters/install-an-addon-repository.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../managing-add-ons-in-vks-clusters/install-an-addon-repository.html  [301 Moved Permanently — 'latest' IS 9.0]` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > 'Update spec.fetch.imgpkgBundle.imageURL to use a URL with the private registry endpoint.' | 'VKS releases 3.5 and later include an embedded version of the standard package repository installed on all VKS clusters.' | Default: projects.packages.broadcom.com/vsphere/supervisor/packages/2025.10.22/vks-standard-packages:3.5.0-20251022 | Istio listed among available add-ons at 1.27.1+vmware.1-vks.1 | 'Create secret with registry credential' via kubectl create secret docker-registry, then export across namespaces with SecretExport.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters/creating-and-updating-addonrepositoryinstalls/create-a-new-addonrepository-install-version-for-vks-37-and-later.html`
  landed: `https://access.broadcom.com/us/en/vmware-cis/vcf/vcf-consumption/latest/.../create-a-new-addonrepository-install-version-for-vks-37-and-later.html (host redirect; 'latest' retained)` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > apiVersion: addons.kubernetes.vmware.com/v1alpha1 / kind: AddonRepositoryInstall / metadata.namespace: vmware-system-vks-public | Default repo image: projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.7.0-20260618/vks-addons:3.7.0-20260618 | Private registry (air-gapped): update spec.fetch.imgpkgBundle.imageURL e.g. 'harbor.registry.com/standard-packages/packages/3.7.0-20260618/vks-addons:3.7.0-20260618'. Applies to VKS 3.7 and later. Registry trust is established separately via vSphere Client > Container Registries.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/building-your-cloud-applications/getting-started-with-the-tools-for-building-applications/installing-and-using-vcf-cli-v9/command-reference2/addon.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-9-0-and-later/9-0/.../command-reference2/addon.html`  (retrieved 2026-07-14)
  > vcf addon install create ADDON_NAME [flags] — --cluster-name 'Name for the workload cluster. Required.' ; -n, --namespace 'Namespace for the workload cluster' ; -f, --values-config-file ; -v, --version ; --addon-release-name ; -y, --yes. Subcommands: vcf addon repository register|list|get|delete.  [NOTE: the doc does NOT explicitly say whether -n is the vSphere Namespace or a guest-cluster namespace — 'Namespace for the workload cluster' is all it says.]

- requested: `https://carvel.dev/imgpkg/docs/v0.36.x/air-gapped-workflow/`
  landed: `https://carvel.dev/imgpkg/docs/v0.36.x/air-gapped-workflow/`  (retrieved 2026-07-14)
  > 'The bundle, and all images referenced in the bundle, are copied to the destination registry.' | 'Note that the .imgpkg/images.yml file was updated with the destination registry locations of the images.' | example rewritten ref: image: registry.corp.com/apps/simple-app-bundle@sha256:4c8b96d4... — i.e. after relocation the referenced images (istiod/proxyv2) resolve BY DIGEST from the SAME repository as the bundle, which is why no hub/registry key is needed or offered.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-add-ons-in-vks-clusters.html`
  landed: `https://www.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/.../managing-add-ons-in-vks-clusters.html (host redirect; version stayed 9-0)` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > 'You can update the AddonRepositoryInstall in order to use a different version of the standard packages repository ... or to use a private registry to support an air-gapped installation scenario.' Add-ons are 'a new mechanism for managing add-ons in VKS Clusters' from version 3.5, providing automatic package repository management. Istio is not named on this page.


---

## [PRIMARY_SOURCED_9_1] On VMware VKS/VCF 9.1: is Harbor a Supervisor Service? How does a GUEST workload cluster trust its CA — auto-injected on the same Supervisor, or must an operator wire it (containerd certs.d / a pull secret)? What endpoint shape does a tenant actually get, and can a tenant mint a robot account without admin?

FOUR ANSWERS. The CA one is the important one, and it corrected me mid-research — I was about to retract a repo claim that turns out to be TRUE (but for the wrong reason).

(1) HARBOR IS A SUPERVISOR SERVICE — YES, and it is now the ONLY Harbor.
Confirmed on a genuine 9-1 page that did NOT redirect (vSphere Supervisor Release Notes, 9-1): it discusses "Harbor Supervisor Service" and trusted versions "Harbor 2.12.4 and later". The same page states "Embedded Registry support" was REMOVED starting with vCenter 9.0.0.0, users advised to migrate to Harbor. Broadcom's own service catalog (vsphere-tmm) ships Harbor v2.12.4 / v2.13.1 / v2.14.2 / v2.14.3 as a Supervisor Service. So the legacy "embedded Harbor image registry" is gone; Harbor-as-a-Supervisor-Service is the replacement. NOTE: this is a SUPERVISOR SERVICE, not a guest-cluster package — the 9.1 "Standard Package -> VKS Add-on" rename (vcf package -> vcf addon) does NOT apply to it. Do not reach for `vcf addon` here.

(2) CA TRUST — CONDITIONAL AUTO-INJECTION. This is the headline, and the trigger is NOT "same Supervisor".
The auto-trust mechanism is REAL and PRIMARY-SOURCED, but it is keyed on the CERTIFICATE, not the Supervisor. Broadcom's own Harbor service README documents the data-value `tlsCertificate.tlsSecretLabels: {"managed-by": "vmware-vRegistry"}` verbatim as: "The certificate that vSphere Kubernetes Service uses to install the Harbor CA as a trusted root on vSphere Kubernetes Service clusters."

  - Harbor installed WITH a customized certificate whose TLS secret carries that label => VKS installs the Harbor CA as a trusted root on VKS clusters. AUTO-TRUST WORKS.
  - Harbor left on its DEFAULT auto-generated self-signed certificate (no `tlsCertificate` block => no label) => NO auto-trust. Guest clusters fail with `x509: certificate signed by unknown authority` / ErrImagePull, and the operator MUST wire the CA explicitly via the Cluster spec `trust.additionalTrustedCAs` — a Secret in the vSphere Namespace holding the CA in PEM, DOUBLE-base64-encoded (`base64 -w 0 ca.crt | base64 -w 0`; "If the contents are not double base64-encoded, the resulting PEM file cannot be processed"). Done at cluster CREATE, or by UPDATING an existing cluster.
  - THIRD, SILENT FAILURE MODE (Broadcom KB 440607): if the custom `tls.key` is ENCRYPTED, "Harbor is unable to decrypt the key", silently FALLS BACK to an auto-generated self-signed cert, and auto-trust quietly does not happen — you get x509 while the label still looks correct. A green-config/red-runtime trap of exactly this repo's house style.

  Both community sources are right; they describe different branches. virtualhippy (VCF 9 + VKS) says the CA is NOT automatically trusted and you need trust.additionalTrustedCAs — true for the default self-signed cert. Broadcom says VKS installs it as a trusted root — true for the labelled custom cert. The discriminator is the cert, and nobody states it plainly.

  There is NO containerd certs.d step and NO imagePullSecret step for CA TRUST on a real lab — certs.d is our KinD stand-in's substitute. (An imagePullSecret is still needed for AUTHN if the Harbor project is private; that is orthogonal to CA trust.)

(3) ENDPOINT SHAPE — an operator-chosen FQDN, shared, NOT per-tenant.
`hostname` is set by the admin in `harbor-data-values.yaml`: "The FQDN that you have designated to access the Harbor UI and for referencing the registry in client applications." A DNS record must map it to either the Envoy ingress IP (Contour) or the NGINX/LoadBalancer external IP — "enableNginxLoadBalancer and enableContourHttpProxy can't be true at the same time". Harbor runs in its own Supervisor namespace (svc-harbor-<id>). Broadcom notes VKS clusters, vSphere Pods AND the Supervisor must all resolve that FQDN to pull images. There is exactly ONE Harbor with ONE FQDN; a tenant does NOT get a derived or per-vSphere-Namespace endpoint.

(4) ROBOT ACCOUNTS — a tenant gets NOTHING in Harbor by default. It is a REQUEST, not an entitlement.
Upstream Harbor RBAC (primary): a PROJECT robot requires "an account that has at least project administrator privileges"; a SYSTEM robot requires system administrator. So project-scoped robots ARE self-serviceable by a project-admin without Harbor sysadmin.
BUT — the critical part — the Harbor Supervisor Service has NO vSphere-Namespace -> Harbor-project mapping and no SSO identity sync. The auto-mapping people remember ("a new Harbor project is created automatically for each supervisor namespace") was a feature of the EMBEDDED Registry Service, REMOVED in 9.0.0.0+. I found no primary source showing any identity integration for the Supervisor Service. So a VKS tenant has no automatic Harbor identity at all: they can mint a project robot ONLY if a Harbor admin has explicitly granted them project-admin on that project.

### What we would change

THE REPO'S CLAIM IS RIGHT BUT THE REASON IS WRONG — and the wrong reason is load-bearing, because our stand-in falls on the NO-auto-trust branch.

1) docs/vks-services/harbor.md:24-28 — the "Same-Supervisor auto-trust" callout ("A guest cluster created under the same Supervisor ... is reported to trust its CA automatically. Confidence: community"). DO NOT DELETE IT — auto-trust is real and now PRIMARY-SOURCED. But the trigger is NOT "same Supervisor"; it is "Harbor was installed with a CUSTOM certificate whose TLS secret carries tlsSecretLabels {managed-by: vmware-vRegistry}". Rewrite the trigger and add the two branches + the encrypted-key silent fallback. As written, an operator reads "same Supervisor => it just works", installs Harbor on its DEFAULT self-signed cert, and gets ErrImagePull/x509 with nothing in our docs explaining why. Same fix at harbor.md:62-63 and harbor.md:101, and in MEMORY.md ("same-Supervisor auto-trusts Harbor CA" — identical under-specification).

2) docs/vks-services/harbor.md:20 — `tlsSecretLabels {managed-by: vmware-vRegistry}` is graded "community". UPGRADE TO PRIMARY_SOURCED (Broadcom's own vsphere-tmm Harbor README states it verbatim). This line is not a footnote — it IS the auto-trust mechanism and should be the headline of the CA section.

3) docs/vks-services/harbor.md:33 — HARBOR_URL: "the FQDN you set, OR `kubectl get svc ... loadBalancer.ingress[0].ip`". THAT "OR" IS A BUG ON A REAL LAB. The real Harbor's cert SAN is the FQDN from harbor-data-values.yaml; dialling the LB IP gives an x509 SAN mismatch — and since Go 1.15 there is no CN fallback and no GODEBUG escape hatch (our own security.md says so). Our KinD Harbor mints SAN=IP, which is exactly why the IP path works locally and will NOT transfer. On a lab HARBOR_URL MUST be the FQDN, and DNS must resolve it (Broadcom: VKS clusters, vSphere Pods AND the Supervisor all need to resolve it). Mark the LB-IP form KinD-only.

4) docs/vks-services/harbor.md:36-39 — the robot claim ("a Harbor project-admin can self-service a robot") is CORRECT and now primary-sourced. Add the missing half: VKS grants a tenant NOTHING in Harbor. No vSphere-Namespace->Harbor-project mapping, no SSO sync — that auto-mapping belonged to the EMBEDDED registry, REMOVED in vCenter 9.0.0.0+. So project-admin must be EXPLICITLY granted by a Harbor admin; `make harbor-robot` is correctly gated, but the docs should say the GRANT itself is a request.

5) BUILD, not just document — the biggest stand-in/lab gap: nothing in the repo carries the `trust.additionalTrustedCAs` double-base64 path. Our entire CA story (harbor.md:44-56) is per-consumer containerd certs.d / SSL_CERT_FILE / --cert-dir. That is the KinD substitute and it DOES NOT EXIST on a VKS guest cluster — you do not own those nodes and cannot write /etc/containerd/certs.d on them. A real-lab install needs a `make lab-trust-harbor` that creates the Opaque Secret in the vSphere Namespace with the DOUBLE-base64 CA and emits the Cluster-spec trust stanza. Today a lab run would fail at first image pull with x509 and we have no target for it.

**Would settle it:** Three checks on a real 9.1 lab, in order. The first one alone decides which branch we are on.

1. WHICH CERT BRANCH IS THIS HARBOR ON? (decides whether auto-trust happens at all)
   kubectl get ns | grep svc-harbor
   kubectl -n <svc-harbor-ns> get secret -l managed-by=vmware-vRegistry
   # NON-EMPTY => custom cert, labelled => VKS auto-installs the Harbor CA as a trusted root. Auto-trust EXPECTED.
   # EMPTY     => default auto-generated self-signed cert => NO auto-trust. trust.additionalTrustedCAs is MANDATORY.
   # Then rule out the KB-440607 silent fallback (encrypted tls.key => Harbor silently self-signs DESPITE the label):
   kubectl -n <svc-harbor-ns> get secret harbor-tls -o jsonpath='{.data.tls\.key}' | base64 -d | head -1
   #   "-----BEGIN ENCRYPTED PRIVATE KEY-----" => the label lies; auto-trust will NOT happen.

2. DID THE CA ACTUALLY LAND ON A GUEST NODE? (verify the end result, not the label)
   # the only honest test is a real pull:
   kubectl run t --image=<HARBOR_FQDN>/<project>/<img>:<tag> --restart=Never
   kubectl describe pod t | grep -i x509
   #   x509 unknown authority => we are on the no-auto-trust branch, whatever any doc says.
   # Also confirm the endpoint shape bites as predicted — pull by LB IP instead of FQDN:
   #   expect a SAN mismatch, proving HARBOR_URL must be the FQDN on a lab (repo harbor.md:33).

3. WHAT DOES A TENANT ACTUALLY GET IN HARBOR? (settles the robot question)
   curl -u '<vsphere-namespace-user>' https://<HARBOR_FQDN>/api/v2.0/users/current
   #   401 => VKS grants the tenant NO Harbor identity at all (my expectation) => the robot is a REQUEST.
   curl -u '<user>' -X POST https://<HARBOR_FQDN>/api/v2.0/projects/<proj>/robots -d ...
   #   403 => not project-admin => `make harbor-robot` cannot work; the platform team must mint it.

PAGES I COULD NOT OBTAIN (stated, not glossed): the canonical "Install Harbor as a Supervisor Service" techdocs page is BROKEN — its advertised 'latest' URL 301s to a 9-0 URL that returns 404. And there is NO 9-1 version of the Harbor FQDN-mapping page (I requested the 9-1 path explicitly: 404). If anyone has Broadcom support-portal access, the authoritative artifact is the harbor-data-values-<ver>.yml shipped with the Harbor Supervisor Service download — it contains the tlsCertificate/tlsSecretLabels block and would settle check (1) OFFLINE, with no lab at all. That is the cheapest next step.

### Sources

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vsphere-supervisor-release-notes.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/release-notes/vmware-vsphere-supervisor-release-notes.html`  (retrieved 2026-07-14)
  > GENUINE 9-1 PAGE, NO REDIRECT. Harbor 2.12.4 and later are trusted versions; 'Harbor versions earlier than 2.12.4 with inline overlays show as untrusted'. 'Embedded Registry support' was removed starting with vCenter 9.0.0.0, with users advised to migrate to Harbor before upgrading.

- requested: `https://github.com/vsphere-tmm/Supervisor-Services/blob/main/harbor/README-v2.13.1.md`
  landed: `https://github.com/vsphere-tmm/Supervisor-Services/blob/main/harbor/README-v2.13.1.md`  (retrieved 2026-07-14)
  > BROADCOM'S OWN SERVICE CATALOG. tlsSecretLabels, required value {"managed-by": "vmware-vRegistry"}: 'The certificate that vSphere Kubernetes Service uses to install the Harbor CA as a trusted root on vSphere Kubernetes Service clusters.' hostname: 'The FQDN that you have designated to access the Harbor UI and for referencing the registry in client applications.' 'enableNginxLoadBalancer and enableContourHttpProxy can't be true at the same time.'

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > 301 'latest' -> 9-0 => 9.0 CONTENT READ AS 9.1. Clusters are configured with 'one or more self-signed CA certificates to serve private registry content over HTTPS'. You must 'configure the private registry certificate when you initially create the cluster, or you can update an existing cluster and provide the private registry certificate.' 'Download the Harbor Registry Certificate from the Harbor web interface at the Projects Repositories screen.'

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/using-the-versioned-clusterclass/v1beta1-example-cluster-with-additional-trusted-ca-certificates-for-ssl-tls.html`
  landed: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/provisioning-tkg-service-clusters/using-the-cluster-v1beta1-api/using-the-versioned-clusterclass/v1beta1-example-cluster-with-additional-trusted-ca-certificates-for-ssl-tls.html`  (retrieved 2026-07-14)
  > EXPLICITLY A 9-0 PAGE (no 9-1 equivalent found). 'The Cluster v1beta1 API provides the trust variable for provisioning a cluster with one or more additional trusted CA certificates.' 'Double base64-encoding is required. If the contents are not double base64-encoded, the resulting PEM file cannot be processed.' Command: base64 -w 0 ca.crt | base64 -w 0

- requested: `https://knowledge.broadcom.com/external/article/440607/harbor-image-pull-fails-with-x509-unknow.html`
  landed: `https://knowledge.broadcom.com/external/article/440607/harbor-image-pull-fails-with-x509-unknow.html`  (retrieved 2026-07-14)
  > BROADCOM KB. Symptom: 'Failed to pull image ...: x509: certificate signed by unknown authority'. Cause: 'The custom TLS private key (tls.key) defined in the Harbor values.yaml configuration is encrypted. Harbor is unable to decrypt the key, failing to load the intended corporate certificate.' It then 'falls back to an auto-generated, self-signed certificate' that 'Kubernetes worker nodes do not inherently trust', requiring manual intervention to establish trust across nodes. => THE SILENT-FALLBACK TRAP: the label can be present and auto-trust still not happen.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html`
  landed: `http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html -> then HTTP 404` ⚠️ **REDIRECTED**  (retrieved 2026-07-14)
  > REDIRECT + BROKEN. The canonical 'Install Harbor as a Supervisor Service' page 301s from 'latest' to a 9-0 URL that itself returns 404. The advertised canonical install page is currently UNREACHABLE. Content had to be sourced from the vsphere-tmm catalog README and the FQDN-mapping page instead.

- requested: `https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-supervisor-services/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour/map-the-harbor-fqdn-to-the-envoy-ingress-ip-address.html`
  landed: `HTTP 404 — no 9-1 version of this page exists. The 9-0 path resolves: .../9-0/using-supervisor-services/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour/map-the-harbor-fqdn-to-the-envoy-ingress-ip-address.html`  (retrieved 2026-07-14)
  > I REQUESTED THE 9-1 PATH EXPLICITLY AND GOT 404 => 9.0 CONTENT IS ALL THAT EXISTS. From the 9-0 page: 'create a DNS record that maps the Harbor FQDN to the ingress IP address used for external access.' Contour: retrieve the Envoy ingress IP; NGINX: use the external IP of the NGINX service. 'VKS clusters, vSphere Pods, and the Supervisor must resolve the Harbor FQDN to pull container images.'

- requested: `https://goharbor.io/docs/2.3.0/working-with-projects/project-configuration/create-robot-accounts/`
  landed: `https://goharbor.io/docs/2.3.0/working-with-projects/project-configuration/create-robot-accounts/`  (retrieved 2026-07-14)
  > UPSTREAM HARBOR, PRIMARY. PROJECT robot: 'Log in to the Harbor interface with an account that has at least project administrator privileges.' Contrast goharbor.io/docs/2.14.0/administration/robot-accounts/ — SYSTEM robot accounts require 'system administrator privileges'.

- requested: `https://virtualhippy.com/deploy-harbor-supervisor-service-vcf-9-vks/`
  landed: `https://virtualhippy.com/deploy-harbor-supervisor-service-vcf-9-vks/`  (retrieved 2026-07-14)
  > COMMUNITY, VCF 9 + VKS specifically. Harbor CA NOT automatically trusted by VKS clusters: 'when Harbor presents its HTTPS certificate, the cluster nodes need to trust the issuing CA. If they do not, image pulls typically fail' with x509 errors. Trust added via 'trust.additionalTrustedCAs' referencing a Secret. Endpoint is an FQDN e.g. harbor.vcf.lab with an external VIP. Recommends robot accounts + imagePullSecrets over personal credentials. => describes the DEFAULT-self-signed branch.

- requested: `https://williamlam.com/2025/08/quick-tip-configuring-vsphere-kubernetes-service-vks-cluster-with-self-signed-container-registry.html`
  landed: `https://williamlam.com/2025/08/quick-tip-configuring-vsphere-kubernetes-service-vks-cluster-with-self-signed-container-registry.html`  (retrieved 2026-07-14)
  > COMMUNITY (William Lam, 2025-08-12). For a self-signed registry the CA trust IS required: create an Opaque Secret in the vSphere Namespace holding the double-base64 CA ('base64 -w 0 ca.crt | base64 -w 0'), then reference it via the osConfiguration/Trust input when creating the VKS Cluster. Without it: 'tls: failed to verify certificate: x509: certificate signed by unknown authority'.

- requested: `https://blogs.vmware.com/cloud-foundation/2026/04/21/deploying-harbor-service-in-air-gapped-vmware-cloud-foundation-9-0/`
  landed: `https://blogs.vmware.com/cloud-foundation/2026/04/21/deploying-harbor-service-in-air-gapped-vmware-cloud-foundation-9-0/`  (retrieved 2026-07-14)
  > OFFICIAL VMware/Broadcom blog, 2026-04-21, VCF 9.0 (NOT 9.1). Air-gapped Harbor Supervisor Service needs a two-phase bootstrap: a Bitnami Harbor OVA VM as bootstrap registry, imgpkg-copy the Harbor service bundle to it, repoint the image URL in the Harbor supervisor service YAML. 'we can access the Harbor Supervisor Service UI using the FQDN provided in the data values yaml file'.

