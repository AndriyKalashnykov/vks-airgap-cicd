#!/usr/bin/env bash
# A tenant who is FORBIDDEN to list a cluster-scoped resource must get UNKNOWN, never a PROBLEM
# that asserts something about the cluster.
#
# B471/F-c4. `24-lab-preflight.sh` discarded kubectl's stderr on two checks and then judged the
# EMPTY result, so a namespace-scoped tenant -- the DEFAULT posture per CLAUDE.md RULE ZERO-B --
# was told "no StorageClass at all -- Gitea's PVC can never bind". That is a claim about the
# CLUSTER derived from a question nobody answered, and it sends the operator to fix a thing that is
# not broken. MEASURED before the fix: default_sc=[] n_sc=[0] -> that PROBLEM.
#
# The file already had the right answer -- `unk()`, whose own comment says a check "must not assert
# a permissions verdict nobody obtained" -- and applied it to 1 of its 4 checks.
#
# BOTH DIRECTIONS, because a fix that silences the false PROBLEM by never judging anything would
# pass the first case and destroy the check. The admin case is the one that proves it still works.
#
# Hermetic: a fake `kubectl` on PATH, no cluster, no network, no `.env` (SKIP_DOTENV=1).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
mk_kubectl() {  # $1 = dir, $2 = forbidden|admin
  mkdir -p "$1/bin"
  if [ "$2" = forbidden ]; then
    cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"version -o json"*) exit 0 ;;
  *"config current-context"*) echo tenant-ctx; exit 0 ;;
  *"auth can-i"*) echo yes; exit 0 ;;
  *storageclass*) echo 'Error from server (Forbidden): storageclasses.storage.k8s.io is forbidden: User "t" cannot list resource "storageclasses" in API group "storage.k8s.io" at the cluster scope' >&2; exit 1 ;;
  *"get svc -A"*)  echo 'Error from server (Forbidden): services is forbidden: User "t" cannot list resource "services" in API group "" at the cluster scope' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
  else
    cat > "$1/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"version -o json"*) exit 0 ;;
  *"config current-context"*) echo admin-ctx; exit 0 ;;
  *"auth can-i"*) echo yes; exit 0 ;;
  *"get storageclass -o jsonpath"*) printf 'standard '; exit 0 ;;
  *storageclass*) printf 'standard  rancher.io/local-path  Delete  WaitForFirstConsumer  false  1d\n'; exit 0 ;;
  *"get svc -A"*)
      case "$*" in *jsonpath*) printf 'gitea/gitea-http\t10.0.0.5\n'; exit 0 ;; esac
      printf 'gitea gitea-http LoadBalancer 10.0.0.5\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  fi
  chmod +x "$1/bin/kubectl"
}

run_case() {  # $1 = forbidden|admin
  local d out
  d="$(mktemp -d)"; mk_kubectl "$d" "$1"
  out="$(PATH="$d/bin:$PATH" SKIP_DOTENV=1 timeout 120 scripts/24-lab-preflight.sh 2>&1)"
  rm -rf "$d"
  printf '%s' "$out"
}

echo "  case 1: a FORBIDDEN tenant"
out="$(run_case forbidden)"
for want in 'UNKNOWN  cannot LIST StorageClasses' 'UNKNOWN  cannot LIST Services cluster-wide'; do
  if printf '%s' "$out" | grep -qF "$want"; then
    echo "    ok      reports: ${want}"
  else
    echo "    FAIL    expected UNKNOWN, got none: ${want}"; fail=1
  fi
done
# The whole point: the OLD false PROBLEM must be gone.
if printf '%s' "$out" | grep -qF 'no StorageClass at all'; then
  echo "    FAIL    still emits the FALSE PROBLEM 'no StorageClass at all' for a Forbidden tenant"; fail=1
else
  echo "    ok      the false PROBLEM 'no StorageClass at all' is NOT emitted"
fi

echo "  case 2: an ADMIN who CAN list (the control -- a fix that never judges would pass case 1)"
out="$(run_case admin)"
if printf '%s' "$out" | grep -qE 'LAB PREFLIGHT OK'; then
  echo "    ok      still reaches LAB PREFLIGHT OK"
else
  echo "    FAIL    the admin path no longer passes -- the fix broke the working case"; fail=1
fi
if printf '%s' "$out" | grep -qF 'UNKNOWN  cannot LIST'; then
  echo "    FAIL    false-UNKNOWN on an admin who CAN list"; fail=1
else
  echo "    ok      no false-UNKNOWN for an admin"
fi

[ "$fail" -eq 0 ] || { echo "test-lab-preflight-forbidden: FAILED"; exit 1; }
echo "test-lab-preflight-forbidden: OK"
