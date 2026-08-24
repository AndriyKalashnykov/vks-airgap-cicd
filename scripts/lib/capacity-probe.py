#!/usr/bin/env python3
"""Read a cluster's schedulable memory headroom. Called by lib/capacity.sh.

A SEPARATE FILE on purpose: the first draft embedded this in `python3 -c '...'` inside the shell
library and broke THREE times on nested quoting -- an apostrophe in a comment ("istio's") closed the
shell string, and \" escapes inside an f-string are a Python syntax error. Each break made the check
FAIL OPEN (it logged "could not read the cluster - skipping" and returned 0), which is the worst
failure a gate can have and was only caught because the RED arm was run. No embedding, no class.

stdin: `kubectl get nodes,pods -A -o json`
argv:  <needed-Mi>
stdout line 1: "<fits 0|1> <best-free-Mi> <n-candidate-nodes> <n-excluded>"
stdout rest:   one human line per node
exit:  0 ok, 3 unreadable input
"""
import json
import sys

# Ti/Pi/Ei and their decimal siblings are legal k8s quantities. Omitting them made as_bytes()
# return 0, whose DIRECTION differs by side and is dangerous on one of them: a POD request read as
# 0 under-counts usage -> more apparent free -> FALSE GREEN. A node allocatable read as 0 -> FALSE
# RED. Neither is reachable on today's clusters (all container requests are Mi, all allocatables
# Ki) but a node with round Ti allocatable serialises as Ti.
UNITS = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4, "Pi": 1024**5, "Ei": 1024**6,
         "K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4, "P": 1000**5, "E": 1000**6}
MI = 1024**2
# Tolerations our installs declare. Empty today; a node's NoSchedule/NoExecute taint therefore
# excludes it. Populate this (not a node-name allowlist) if an install ever tolerates a taint.
# The istiod chart DECLARES a toleration, so an empty list here is not merely conservative -- it
# excludes a node istiod can actually use, under-counting candidates and producing a false RED at
# the margin. Measured from `helm template bundle/charts/istiod-1.30.3.tgz` under the install's own
# --set args. No node currently carries this taint, so it is latent, not active.
TOLERATIONS: list = [{"key": "cni.istio.io/not-ready", "operator": "Exists"}]


def as_bytes(v: str) -> int:
    """Bytes for a k8s quantity. RAISES on anything it cannot parse -- returning 0 for an
    unrecognised form is a FALSE GREEN when the value is a pod request (less usage -> more
    apparent free). The caller must decide to skip; this must never silently count zero."""
    if not v:
        return 0
    # Longest suffix first, so "Mi" is never matched as "M" (and "Ei" not as "E").
    for suffix in sorted(UNITS, key=len, reverse=True):
        if v.endswith(suffix):
            return int(float(v[: -len(suffix)]) * UNITS[suffix])
    return int(float(v))    # bare = bytes; float() so 1e9 parses. ValueError propagates by design.


def tolerated(taint: dict) -> bool:
    for tol in TOLERATIONS:
        if tol.get("operator") == "Exists" and not tol.get("key"):
            return True
        if tol.get("key") == taint.get("key"):
            return True
    return False


def main() -> int:
    need_mi = int(sys.argv[1])
    try:
        doc = json.load(sys.stdin)
    except Exception:
        return 3

    nodes = {}
    for obj in doc.get("items", []):
        if obj.get("kind") != "Node":
            continue
        spec, status = obj.get("spec", {}), obj.get("status", {})
        blockers = [
            t for t in (spec.get("taints") or [])
            if t.get("effect") in ("NoSchedule", "NoExecute") and not tolerated(t)
        ]
        if spec.get("unschedulable"):
            blockers.append({"key": "cordoned"})
        if not any(c.get("type") == "Ready" and c.get("status") == "True"
                   for c in status.get("conditions", [])):
            blockers.append({"key": "NotReady"})
        nodes[obj["metadata"]["name"]] = {
            "alloc": as_bytes(status.get("allocatable", {}).get("memory", "")),
            "blockers": blockers,
            "req": 0,
        }

    # Every scheduled, non-terminal pod is charged -- INCLUDING one we may be replacing. istiod is
    # RollingUpdate with maxUnavailable 25% of 1 -> 0, so the new pod is created BEFORE the old is
    # removed: the peak needs room for both. Excluding the incumbent models a steady state that does
    # not occur during an upgrade.
    for obj in doc.get("items", []):
        if obj.get("kind") != "Pod":
            continue
        node = obj.get("spec", {}).get("nodeName")
        if node not in nodes:
            continue  # unscheduled pods hold no node memory
        if obj.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        # The scheduler charges max(sum(containers), max(initContainer)) + spec.overhead -- init
        # containers run BEFORE the app ones, so a large init peak reserves that much. Measured
        # delta on this cluster today: 0Mi (52 of 96 pods carry inits; only 1 declares a memory
        # request), so this is latent -- one Tekton or app change makes it active.
        spec = obj["spec"]
        mem = lambda c: as_bytes((c.get("resources", {}).get("requests") or {}).get("memory", ""))
        run = sum(mem(c) for c in spec.get("containers", []))
        ini = max([mem(c) for c in spec.get("initContainers", [])] or [0])
        over = as_bytes((spec.get("overhead") or {}).get("memory", ""))
        nodes[node]["req"] += max(run, ini) + over

    free = {n: v["alloc"] - v["req"] for n, v in nodes.items() if not v["blockers"]}
    best = max(free.values()) if free else 0
    print("%d %d %d %d" % (1 if best >= need_mi * MI else 0, best // MI, len(free), len(nodes) - len(free)))
    for name, v in sorted(nodes.items()):
        why = ""
        if v["blockers"]:
            why = "  NOT A CANDIDATE: " + ",".join(b.get("key", b.get("effect", "?")) for b in v["blockers"])
        print("  %-30s alloc %5dMi  used %5dMi  free %5dMi%s"
              % (name[-30:], v["alloc"] // MI, v["req"] // MI, (v["alloc"] - v["req"]) // MI, why))
    return 0


def to_mi() -> int:
    """`--to-mi`: read a k8s quantity on stdin, print integer Mi (rounded UP), rc 0.
    rc 1 on anything unparseable. ONE parser serves the shell side and the node arithmetic -- the
    shell had its own, which refused `1.5Gi` and `512Ki` (both legal) and silently disabled the
    whole check by making the render come back empty."""
    q = sys.stdin.read().strip()
    # A BARE integer is a legal k8s quantity meaning BYTES, so as_bytes() must keep accepting it --
    # the API server serialises node/pod values that way. But this mode reads an OPERATOR KNOB or a
    # CHART value, where a bare number is a ~10^6x under-reservation typo and never intentional
    # (every chart-rendered value carries a suffix). Refuse it HERE, not in as_bytes.
    if q.isdigit():
        return 1
    try:
        b = as_bytes(q)
    except ValueError:
        return 1
    if b <= 0:
        return 1
    print(-(-b // MI))   # ceil: round UP so the fit check stays conservative
    return 0


if __name__ == "__main__":
    if "--to-mi" in sys.argv:
        sys.exit(to_mi())
    sys.exit(main())
