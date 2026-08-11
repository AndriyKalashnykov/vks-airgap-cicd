#!/usr/bin/env bash
# walkbox.sh — run docs/scenario-1.md on a REAL VM, as a real non-root operator.
#
# WHY A VM. `make jumpbox`/`labbox` validate the BOOTSTRAP (deps, engine, reach) in a container and
# that is the right tool for those — cheap, and they cover the OS x engine matrix. They cannot run
# the WHOLE runbook. MEASURED 2026-08-11, walking scenario-1 in a container against the live lab:
#
#   install-all -> builder-image -> podman build INSIDE the container:
#     Error: creating build container: ... potentially insufficient UIDs or GIDs available in user
#     namespace (requested 0:42 for /etc/gshadow) ... lchown /etc/gshadow: invalid argument
#   /etc/subuid in the container: 0 lines.   On the host: 1 line.
#
# On the VM that same step printed `builder images pushed + verified: 1`.
#
# Three things only the VM exercises, each of which found a real defect the container hid:
#   * a NON-ROOT operator — the container is root, so every missing `sudo` is invisible.
#   * REAL NICs and DNS instead of the host's namespace.
#   * systemd — podman.socket, netplan, the units `make deps` installs.
#
# NOT a replacement for `make jumpbox-matrix`: that covers photon x ubuntu x podman x docker
# bootstrap in ~2 min a cell. This runs ONE full walk, ~40 min.
#
# ─── EVERY DESIGN CHOICE BELOW IS A FINDING FROM THE ADVERSARY ROUND (2026-08-11) ────────────────
# Read them before "simplifying" any of it; each one was measured on this host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

# ⚠️ NOT $HOME. /var/tmp is 1777, so libvirt's qemu uid reaches the images with NO ACL, no uid
# detection and nothing left behind in the operator's home. The first prototype used ~/vmimages plus
# `setfacl -m u:64055:x $HOME`, which is (a) unnecessary, (b) keyed on a uid that is DYNAMICALLY
# allocated on Debian and is `qemu` on RHEL, and (c) exactly the residue class patterns.md records:
# an operator-home permission change `git status` cannot see and no teardown thinks to remove.
# qemu:///session is NOT the alternative — measured: it sees ZERO networks, so it cannot attach to
# the lab bridges at all.
WALKBOX_DIR="${WALKBOX_DIR:-/var/tmp/walkbox-$(id -un)}"
WALKBOX_NAME="${WALKBOX_NAME:-vks-walkbox}"
WALKBOX_MARKER="vks-walkbox-managed"      # see walkbox_assert_ours
WALKBOX_MGMT_NET="${WALKBOX_MGMT_NET:-nested-mgmt}"
WALKBOX_LAB_NET="${WALKBOX_LAB_NET:-supwl}"
WALKBOX_MEM_GIB="${WALKBOX_MEM_GIB:-8}"
WALKBOX_VCPU="${WALKBOX_VCPU:-4}"
WALKBOX_USER="${WALKBOX_USER:-vks}"
WALKBOX_SSH_KEY="${WALKBOX_SSH_KEY:-${WALKBOX_DIR}/id_ed25519}"
WALKBOX_CLOUD_IMG="${WALKBOX_CLOUD_IMG:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
# WALKBOX_SUDO: nopasswd | prompt. See the block above walkbox_seed().
WALKBOX_SUDO="${WALKBOX_SUDO:-nopasswd}"
# Where the lab declares its address pools. The lab IP is DERIVED from this, never hardcoded.
WALKBOX_LAB_INPUT="${WALKBOX_LAB_INPUT:-${HOME}/projects/nested-vsphere-lab/input.yaml}"

_ssh() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
             -o BatchMode=yes -i "$WALKBOX_SSH_KEY" "${WALKBOX_USER}@${1}" "${@:2}"; }

# ── the destructive guard ───────────────────────────────────────────────────────────────────────
# `virsh destroy` is documented as "FORCEFULLY stop a given domain" — a power cut, no confirmation,
# no --yes. This runs on qemu:///system, which on a lab host ALSO carries the nested ESXi that hosts
# the entire Supervisor. A blocklist of known-real names rots the day someone adds a VM; a POSITIVE
# marker cannot. Nothing destructive runs unless the domain's own XML says we made it.
# ⚠️ HERESTRING, not `virsh dumpxml | grep -qF`. MEASURED 2026-08-11: `grep -q` exits at the first
# match — and the marker is near the TOP of a ~6.4 KB XML — so virsh takes SIGPIPE and `pipefail`
# promotes 141 to the pipeline status. On an idle box: 0/200 false negatives. Pinned to one core
# (`taskset -c 0`, the loaded-host analogue): 383/400 = 95.8%. It fails CLOSED, so it is safe — but
# it makes `walkbox-down` intermittently refuse a domain that DOES carry the marker, which reads as
# "the marker is broken" and collides with a real marker bug. A herestring spools to a temp file, so
# there is nothing to SIGPIPE.
walkbox_assert_ours() {
  local n="${1:?}"
  grep -qF "$WALKBOX_MARKER" <<< "$(virsh dumpxml "$n" 2>/dev/null)" \
    || die "domain '$n' does not carry the ${WALKBOX_MARKER} marker — REFUSING to touch it.
  walkbox only destroys domains it created. If you meant a different VM, that is the point of
  this guard: 'virsh destroy' is a forced power-cut and this connection also hosts the lab."
}

# ── the lab address, DERIVED ────────────────────────────────────────────────────────────────────
# MEASURED 2026-08-11: the first prototype hardcoded 192.168.101.60, which is INSIDE the lab's
# workload_node pool (input.yaml: {start: 192.168.101.32, count: 32} -> .32-.63) — and that pool was
# fully allocated, with the Supervisor already handing out .59. The next guest node would have taken
# .60, giving a duplicate IP between a Kubernetes node and this validator: the node flaps NotReady
# and NOTHING names walkbox. A validator must never damage what it validates.
#
# ⚠️ AN ARP/PING PROBE IS NOT A SUBSTITUTE. It tests LIVENESS, not ALLOCATION: an IP reserved for a
# node that is powered off (mid-upgrade, scaled to zero, failed) answers nothing and probes "free".
# Being OUTSIDE every declared range is the only check that holds. We probe as well, never instead.
walkbox_lab_ip() {
  [ -n "${WALKBOX_LAB_IP:-}" ] && { printf '%s' "$WALKBOX_LAB_IP"; return 0; }
  [ -s "$WALKBOX_LAB_INPUT" ] || die "cannot derive a lab IP: ${WALKBOX_LAB_INPUT} not readable.
  Set WALKBOX_LAB_IP=<addr>/24 explicitly — and check it is outside every range that file declares."
  # `|| true` on the assignment: without it, a python3 that is missing or raises makes the
  # substitution non-zero, `set -e` kills the script AT THIS LINE, and the `die` below — written for
  # exactly that case — NEVER RUNS. You get a bare non-zero with no message. (python3 here resolves
  # to a mise shim; lib/os.sh already records a `pick_port` -> `python3: command not found` incident.)
  local claimed; claimed="$(python3 - "$WALKBOX_LAB_INPUT" <<'PY' || true
import re, sys
# Deliberately regex, not a YAML parse: this file is another repo's contract and we read only the
# {start: A.B.C.D, count: N} shape. A missed range must fail CLOSED, so anything unparsed is ignored
# here and the caller then refuses every candidate rather than guessing.
claimed = set()
for m in re.finditer(r'start:\s*(\d+\.\d+\.\d+\.(\d+)),\s*count:\s*(\d+)', open(sys.argv[1]).read()):
    net = m.group(1).rsplit('.', 1)[0]
    if net != '192.168.101':
        continue
    lo = int(m.group(2))
    for o in range(lo, lo + int(m.group(3))):
        claimed.add(o)
print(' '.join(str(o) for o in sorted(claimed)))
PY
)"
  [ -n "$claimed" ] || die "parsed NO ranges from ${WALKBOX_LAB_INPUT} — refusing to pick an address blind"
  log_info "lab declares 192.168.101.{${claimed// /,}} — choosing outside that"
  # The bridge device name is NOT derivable from the network name: `supwl` -> `virbr-supwl`, but
  # `nested-mgmt` -> `virbr-nmgmt`. Ask libvirt instead of guessing; a wrong name makes `ip neigh`
  # error, `pipefail` fire, and the probe silently never run.
  local br; br="$(virsh net-dumpxml "$WALKBOX_LAB_NET" 2>/dev/null | grep -oE "bridge name='[^']+'" | cut -d"'" -f2 || true)"
  local o arp
  for o in $(seq 64 127); do
    case " $claimed " in *" $o "*) continue ;; esac
    # Herestring again (see walkbox_assert_ours): as a pipe this SIGPIPEs and the pipeline returns
    # 141, so `continue` is SKIPPED and an in-use address is ACCEPTED — measured 22/300 under load.
    # That direction is worse than the guard's: it hands out a duplicate IP.
    if [ -n "$br" ]; then
      arp="$(ip neigh show dev "$br" 2>/dev/null || true)"
      grep -qF "192.168.101.$o " <<< "$arp" && continue
    fi
    printf '192.168.101.%s/24' "$o"; return 0
  done
  die "no free address in 192.168.101.64-127 outside the declared ranges"
}

walkbox_prepare() {
  mkdir -p "$WALKBOX_DIR"; chmod 0755 "$WALKBOX_DIR"
  [ -f "${WALKBOX_SSH_KEY}.pub" ] || ssh-keygen -q -t ed25519 -N '' -f "$WALKBOX_SSH_KEY"
  if [ ! -s "${WALKBOX_DIR}/base.img" ]; then
    log_info "downloading the cloud image (once, ~600 MB): ${WALKBOX_CLOUD_IMG}"
    # --fail is load-bearing: MEASURED, a 404 without it gives curl_rc=0 and writes a 460-byte HTML
    # error page as "base.img", so `|| die` never fires and the VM fails much later, opaquely.
    curl --fail -sSL --max-time 1800 -o "${WALKBOX_DIR}/base.img" "$WALKBOX_CLOUD_IMG" \
      || die "cloud-image download failed (or the URL 404d): $WALKBOX_CLOUD_IMG"
  fi
  # libvirt's DYNAMIC OWNERSHIP chowns backing files to its own uid. Keeping the pristine download
  # separate from the per-run overlay means a re-run never has to re-download something it can no
  # longer read. MEASURED on the prototype: all 12 GB ended up libvirt-qemu:kvm.
  rm -f "${WALKBOX_DIR}/${WALKBOX_NAME}.qcow2"
  qemu-img create -f qcow2 -b "${WALKBOX_DIR}/base.img" -F qcow2 \
    "${WALKBOX_DIR}/${WALKBOX_NAME}.qcow2" 40G >/dev/null
  chmod 0644 "${WALKBOX_DIR}/${WALKBOX_NAME}.qcow2" "${WALKBOX_DIR}/base.img"
}

# WALKBOX_SUDO is an AXIS, not a constant, and this is the most counter-intuitive choice here.
# The VM's whole value is exposing what root hides — the walk driver died at Step 0 on the VM
# (`apt-get` bare, `cd /root`) precisely because the doc says "Prefix with sudo if you are not
# root" and a container never tests it. A NOPASSWD user re-hides the NEXT member of that class:
# `make deps` escalates via lib/os.sh's $SUDO, and on a box where sudo PROMPTS it stops dead with
# no warning. The permissive mode is the default because iterating is the common case; run the
# asking mode before believing a walk.
walkbox_seed() {
  local seed; seed="$(mktemp -d)"
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$WALKBOX_NAME" "$WALKBOX_NAME" > "$seed/meta-data"
  {
    printf '#cloud-config\nusers:\n  - name: %s\n' "$WALKBOX_USER"
    case "$WALKBOX_SUDO" in
      nopasswd) printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n' ;;
      prompt)   printf '    sudo: ALL=(ALL) ALL\n    lock_passwd: false\n    plain_text_passwd: %s\n' \
                       "${WALKBOX_SUDO_SECRET:?WALKBOX_SUDO=prompt needs WALKBOX_SUDO_SECRET}" ;;
      *) die "WALKBOX_SUDO must be nopasswd|prompt (got '$WALKBOX_SUDO')" ;;
    esac
    printf '    shell: /bin/bash\n    ssh_authorized_keys:\n      - %s\nssh_pwauth: false\n' \
           "$(cat "${WALKBOX_SSH_KEY}.pub")"
  } > "$seed/user-data"
  xorriso -as mkisofs -output "${WALKBOX_DIR}/${WALKBOX_NAME}-seed.iso" \
    -volid cidata -joliet -rock "$seed/user-data" "$seed/meta-data" >/dev/null 2>&1 \
    || die "could not build the cloud-init seed ISO"
  chmod 0644 "${WALKBOX_DIR}/${WALKBOX_NAME}-seed.iso"
  rm -rf "$seed"
}

walkbox_define() {
  if virsh dominfo "$WALKBOX_NAME" >/dev/null 2>&1; then
    walkbox_assert_ours "$WALKBOX_NAME"
    virsh destroy "$WALKBOX_NAME" >/dev/null 2>&1 || true
    virsh undefine "$WALKBOX_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$WALKBOX_NAME" >/dev/null 2>&1 || true
  fi
  local xml; xml="$(mktemp)"
  cat > "$xml" <<XML
<domain type='kvm'>
  <name>${WALKBOX_NAME}</name>
  <title>${WALKBOX_MARKER}</title>
  <description>Throwaway scenario-1 walk box. Safe to delete. Created by scripts/walkbox.sh.</description>
  <memory unit='GiB'>${WALKBOX_MEM_GIB}</memory>
  <vcpu>${WALKBOX_VCPU}</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${WALKBOX_DIR}/${WALKBOX_NAME}.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${WALKBOX_DIR}/${WALKBOX_NAME}-seed.iso'/>
      <target dev='sda' bus='sata'/><readonly/>
    </disk>
    <interface type='network'><source network='${WALKBOX_MGMT_NET}'/><model type='virtio'/></interface>
    <interface type='network'><source network='${WALKBOX_LAB_NET}'/><model type='virtio'/></interface>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
XML
  virsh define "$xml" >/dev/null || die "virsh define failed"
  rm -f "$xml"
  virsh start "$WALKBOX_NAME" >/dev/null || die "virsh start failed"
  log_info "${WALKBOX_NAME} started (marker: ${WALKBOX_MARKER})"
}

# virsh domifaddr reads DHCP LEASES. The lab network has no <dhcp> block at all, so only the mgmt
# NIC ever appears here — which is what we want, but it is one edit away from a forever-hang.
walkbox_wait_ip() {
  local ip="" i
  for i in $(seq 1 40); do
    ip="$(virsh domifaddr "$WALKBOX_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1 || true)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    sleep 10
  done
  die "${WALKBOX_NAME} never got an address on ${WALKBOX_MGMT_NET} in 400s — does that network have a DHCP range, and does this image run cloud-init?"
}

walkbox_wait_ssh() {
  local i
  for i in $(seq 1 30); do _ssh "$1" true 2>/dev/null && return 0; sleep 10; done
  die "cannot ssh ${WALKBOX_USER}@${1} — cloud-init may not have applied the key"
}

# The lab NIC is configured by RENDERING LOCALLY and copying, never by composing a heredoc inside an
# ssh command string. That construction is parsed by TWO shells (local, then sshd's `$SHELL -c`), so
# every $ and backtick is evaluated twice; `<<-` strips only TABS, which YAML forbids; and the whole
# body lands in argv. One file, one shell, no expansion.
walkbox_wire_lab_net() {
  local ip="$1" cidr="$2" nic tmp
  nic="$(_ssh "$ip" 'ls /sys/class/net | grep -E "^en" | tail -1')" || die "cannot enumerate NICs"
  [ -n "$nic" ] || die "no second NIC found on the guest"
  tmp="$(mktemp)"
  { printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      dhcp4: false\n      addresses: [%s]\n' "$nic" "$cidr"; } > "$tmp"
  _ssh "$ip" 'umask 077; sudo tee /etc/netplan/99-walkbox.yaml >/dev/null && sudo chmod 600 /etc/netplan/99-walkbox.yaml && sudo netplan apply' < "$tmp" >/dev/null \
    || die "could not configure ${nic} with ${cidr}"
  rm -f "$tmp"
  log_info "lab NIC ${nic} -> ${cidr}"
}

# Secrets travel on STDIN into a 0600 file, never in the ssh command string. MEASURED: a command
# string puts them in the LOCAL argv (visible to `ps` for the whole run) and again in the remote
# shell's; and a password containing ' or $ is silently MANGLED by the two quoting layers, so Harbor
# answers 401 and the operator is sent to fix a password that was correct.
# shellcheck disable=SC2016  # $HOME must expand on the GUEST. Expanding it here would write the
# secrets to the CONTROLLER's home instead of the VM's — the opposite of the intent.
walkbox_push_env() {
  local ip="$1" v
  # `if … fi`, NOT `[ -n … ] && printf`. MEASURED: when the LAST var is unset the loop's exit status
  # is that failed test, the { } group is the LHS of a pipe, `pipefail` promotes it, this function
  # returns 1, and main's bare call trips `set -e` — the walk dies BEFORE IT STARTS, with no message.
  # HARBOR_PASSWORD is a you-choose secret that is routinely unset, so this was reachable every run.
  { for v in VCF_CLI_VSPHERE_PASSWORD VCENTER_PASSWORD HARBOR_PASSWORD; do
      if [ -n "${!v:-}" ]; then printf '%s=%s\n' "$v" "${!v}"; fi
    done; } | _ssh "$ip" 'umask 077; cat > "$HOME/.walk-secrets"'
}

walkbox_down() {
  if virsh dominfo "$WALKBOX_NAME" >/dev/null 2>&1; then
    walkbox_assert_ours "$WALKBOX_NAME"
    virsh destroy "$WALKBOX_NAME" >/dev/null 2>&1 || true
    virsh undefine "$WALKBOX_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$WALKBOX_NAME" >/dev/null 2>&1 || true
    log_info "removed domain ${WALKBOX_NAME}"
  else
    log_info "no domain named ${WALKBOX_NAME}"
  fi
  rm -f "${WALKBOX_DIR}/${WALKBOX_NAME}.qcow2" "${WALKBOX_DIR}/${WALKBOX_NAME}-seed.iso" 2>/dev/null || true
  # PRINT WHAT WE KEPT. A teardown that silently leaves gigabytes behind is the residue class this
  # script was written to avoid; saying so is the difference between a cache and a leak.
  if [ -s "${WALKBOX_DIR}/base.img" ]; then
    log_info "KEPT (cache, delete by hand if you want the space):"
    log_info "  ${WALKBOX_DIR}/base.img  ($(du -h "${WALKBOX_DIR}/base.img" 2>/dev/null | cut -f1))"
    log_info "  ${WALKBOX_SSH_KEY}  (throwaway key for this harness only)"
  fi
  log_info "walkbox leaves NOTHING in \$HOME: no ACL, no storage pool, no known_hosts entry"
}

# ── the walk itself ─────────────────────────────────────────────────────────────────────────────
walkbox_run() {
  local ip="$1" driver="${WALKBOX_DRIVER:-${REPO_ROOT}/scripts/walk-scenario1.sh}"
  [ -s "$driver" ] || die "no walk driver at ${driver} (set WALKBOX_DRIVER)"
  scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
      -i "$WALKBOX_SSH_KEY" "$driver" "${WALKBOX_USER}@${ip}:/tmp/walk.sh" || die "could not copy the driver"
  if [ -n "${VCF_CLI_SRC_DIR:-}" ] && [ -d "$VCF_CLI_SRC_DIR" ]; then
    scp -qr -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -i "$WALKBOX_SSH_KEY" "$VCF_CLI_SRC_DIR" "${WALKBOX_USER}@${ip}:/tmp/vcf" || die "could not copy the VCF archives"
  fi
  walkbox_push_env "$ip"
  # NON-secret settings are fine in the command string; the secrets came over stdin above.
  # </dev/null so the driver cannot consume the ssh stdin it does not own.
  _ssh "$ip" "set -a; . \$HOME/.walk-secrets; set +a; rm -f \$HOME/.walk-secrets; \
      WALK_OS=${WALK_OS:-ubuntu} WALK_EXISTS=${WALK_EXISTS:-1} \
      SUPERVISOR_HOST='${SUPERVISOR_HOST:-}' VKS_CONTEXT_NAME='${VKS_CONTEXT_NAME:-}' \
      VKS_NAMESPACE='${VKS_NAMESPACE:-}' VKS_CLUSTER_NAME='${VKS_CLUSTER_NAME:-}' \
      VKS_USERNAME='${VKS_USERNAME:-}' VKS_SSO_DOMAIN='${VKS_SSO_DOMAIN:-}' \
      VKS_STORAGE_POLICY='${VKS_STORAGE_POLICY:-}' VKS_AUTH_METHOD='${VKS_AUTH_METHOD:-vcf}' \
      VCENTER_HOST='${VCENTER_HOST:-}' VCENTER_USERNAME='${VCENTER_USERNAME:-}' \
      HARBOR_URL='${HARBOR_URL:-}' HARBOR_STORAGE_CLASS='${HARBOR_STORAGE_CLASS:-}' \
      HARBOR_USERNAME='${HARBOR_USERNAME:-}' ARGOCD_NAMESPACE='${ARGOCD_NAMESPACE:-}' \
      ARGOCD_DEST_CLUSTER_NAME='${ARGOCD_DEST_CLUSTER_NAME:-}' VCF_CLI_SRC_DIR=/tmp/vcf \
      bash /tmp/walk.sh" </dev/null
}

main() {
  require_cmd virsh; require_cmd qemu-img; require_cmd xorriso; require_cmd ssh; require_cmd scp
  require_cmd python3   # walkbox_lab_ip parses the lab ranges with it
  case "${1:-up}" in
    down) walkbox_down; return 0 ;;
    up)   : ;;
    *)    die "usage: walkbox.sh [up|down]" ;;
  esac
  local cidr ip
  cidr="$(walkbox_lab_ip)"
  log_info "walkbox: ${WALKBOX_NAME}  dir=${WALKBOX_DIR}  lab=${cidr}  sudo=${WALKBOX_SUDO}"
  walkbox_prepare
  walkbox_seed
  walkbox_define
  ip="$(walkbox_wait_ip)"
  log_info "mgmt address: ${ip}"
  walkbox_wait_ssh "$ip"
  walkbox_wire_lab_net "$ip" "$cidr"
  walkbox_run "$ip"
}

main "$@"
