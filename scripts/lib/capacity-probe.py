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

UNITS = {"Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "K": 1000, "M": 1000**2, "G": 1000**3}
MI = 1024**2
# Tolerations our installs declare. Empty today; a node's NoSchedule/NoExecute taint therefore
# excludes it. Populate this (not a node-name allowlist) if an install ever tolerates a taint.
TOLERATIONS: list = []


def as_bytes(v: str) -> int:
    if not v:
        return 0
    for suffix, mult in UNITS.items():
        if v.endswith(suffix):
            return int(float(v[: -len(suffix)]) * mult)
    try:
        return int(v)
    except ValueError:
        return 0


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
        nodes[node]["req"] += sum(
            as_bytes((c.get("resources", {}).get("requests") or {}).get("memory", ""))
            for c in obj["spec"].get("containers", [])
        )

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


if __name__ == "__main__":
    sys.exit(main())
