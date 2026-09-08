# shellcheck shell=bash
# Proxmox VE backend for the VM boot tests. Sourced, never executed.
#
# Implements the same thirteen-function contract as lib-utm.sh (see the header
# there), so tests/vm-boot.sh, the expect drivers and the assertions are shared
# and only this file knows about the hypervisor.
#
# Why this backend exists: UTM on an arm64 Mac runs an x86_64 guest under TCG,
# which is why a full run there takes hours -- the install compiles GRUB from
# source under emulation. An x86_64 Proxmox node runs the same guest under KVM,
# so the identical suite becomes something you can run routinely rather than
# overnight.
#
# Configuration, all required except where noted:
#
#   PVE_HOST        node hostname or IP (API on :8006, and ssh for the console)
#   PVE_NODE        node name inside the cluster, e.g. pve1
#   PVE_TOKEN_FILE  file containing the single line
#                     Authorization: PVEAPIToken=USER@REALM!TOKENID=UUID
#                   passed to curl as -H @file so the secret never reaches argv
#   PVE_STORAGE     storage for VM disks       (default local-lvm)
#   PVE_DISK_CACHE  drive cache mode           (default writeback; see below --
#                   do NOT use none or directsync on BTRFS storage)
#   PVE_ISO_STORAGE storage holding the ISOs   (default local)
#   PVE_BRIDGE      network bridge             (default vmbr0)
#   PVE_SSH         ssh destination for the serial console (default root@$PVE_HOST)
#   PVE_VMID_BASE   first VMID this suite may use (default 9000)
#   PVE_INSECURE=1  skip TLS verification, for a node with a self-signed cert
#
# Two safety rails, because this talks to a machine that may host real VMs:
#
#   - Every VM lives in the VMID band [PVE_VMID_BASE, +PVE_VMID_SPAN) and is
#     tagged PVE_TAG. Destroy requires *both* to match, re-read from the live
#     config, or it refuses.
#   - Scope the API token to that band -- PVEVMAdmin on /vms/9000..9099 rather
#     than on /vms -- so a bug in this harness cannot reach a production VM
#     even if the checks below are wrong.

# Disk cache mode. writeback rather than the default, because it must not be a
# mode that uses O_DIRECT: Proxmox's own BTRFS documentation warns that "BTRFS
# will honor the O_DIRECT flag when opening files, meaning VMs should not use
# cache mode none, otherwise there will be checksum errors". `none` and
# `directsync` both use O_DIRECT, so both are out on a BTRFS-backed storage.
# writeback is safe on every storage type this suite might land on, and ZFS in
# the guest is crash-consistent, which is what the pull-a-disk phases rely on.
PVE_DISK_CACHE=${PVE_DISK_CACHE:-writeback}

PVE_STORAGE=${PVE_STORAGE:-local-lvm}
PVE_ISO_STORAGE=${PVE_ISO_STORAGE:-local}
PVE_BRIDGE=${PVE_BRIDGE:-vmbr0}
PVE_VMID_BASE=${PVE_VMID_BASE:-9000}
PVE_VMID_SPAN=${PVE_VMID_SPAN:-100}
PVE_TAG=${PVE_TAG:-ci-vmtest}

# Shared with lib-utm.sh: cleanup refuses to touch a name without this.
VM_PREFIX=${VM_PREFIX:-nixinst-test-}

# ------------------------------------------------------------------ plumbing --

_pve_api () { echo "https://${PVE_HOST}:8006/api2/json"; }

_pve_ssh () { echo "${PVE_SSH:-root@${PVE_HOST}}"; }

# curl with the token header and the flags every call wants. Callers add the
# method and the data.
_pve_curl () {
    local -a flags=(-sS --fail-with-body -H "@$PVE_TOKEN_FILE")
    [[ ${PVE_INSECURE-0} == 1 ]] && flags+=(-k)
    curl "${flags[@]}" "$@"
}

_pve_get  () { _pve_curl "$(_pve_api)/$1"; }
_pve_post () { local p=$1; shift; _pve_curl -X POST "$(_pve_api)/$p" "$@"; }
_pve_put  () { local p=$1; shift; _pve_curl -X PUT  "$(_pve_api)/$p" "$@"; }

# Most mutating calls return a UPID rather than doing the work inline. Waiting
# on it is the difference between a test that is sequential and one that races
# its own hypervisor.
_pve_wait_task () { # _pve_wait_task UPID [TIMEOUT]
    local upid=$1 timeout=${2:-600} waited=0 st ex
    [[ -n $upid && $upid != null ]] || return 0
    while (( waited < timeout )); do
        st=$(_pve_get "nodes/$PVE_NODE/tasks/$(_urlenc "$upid")/status" \
             | jq -r '.data.status // empty' 2>/dev/null)
        if [[ $st == stopped ]]; then
            ex=$(_pve_get "nodes/$PVE_NODE/tasks/$(_urlenc "$upid")/status" \
                 | jq -r '.data.exitstatus // empty' 2>/dev/null)
            [[ $ex == OK ]] && return 0
            echo "proxmox task failed: $ex" >&2
            return 1
        fi
        sleep 2; waited=$((waited+2))
    done
    echo "proxmox task did not finish in ${timeout}s: $upid" >&2
    return 1
}

_urlenc () { jq -rn --arg s "$1" '$s|@uri'; }

# Names map to VMIDs deterministically, so a resumed run finds the same VM
# without keeping state on the host.
_pve_vmid () { # _pve_vmid NAME -> VMID
    case ${1#"$VM_PREFIX"} in
        uefi) echo $(( PVE_VMID_BASE + 1 )) ;;
        bios) echo $(( PVE_VMID_BASE + 2 )) ;;
        *)    echo $(( PVE_VMID_BASE + 9 )) ;;
    esac
}

_pve_in_band () { # _pve_in_band VMID
    local v=$1
    [[ $v =~ ^[0-9]+$ ]] || return 1
    (( v >= PVE_VMID_BASE && v < PVE_VMID_BASE + PVE_VMID_SPAN ))
}

_pve_config () { _pve_get "nodes/$PVE_NODE/qemu/$1/config" | jq -r '.data'; }

# ------------------------------------------------------------------ contract --

utm_available () {
    [[ -n ${PVE_HOST-} && -n ${PVE_NODE-} && -n ${PVE_TOKEN_FILE-} ]] || return 1
    [[ -r $PVE_TOKEN_FILE ]] || return 1
    for c in curl jq ssh expect; do command -v "$c" >/dev/null || return 1; done
    _pve_get version >/dev/null 2>&1
}

# The API applies configuration the moment it accepts it, so the reload UTM
# needs has nothing to do here. Kept so the contract is uniform.
utm_reload () { :; }

vm_exists () { # vm_exists NAME
    local vmid; vmid=$(_pve_vmid "$1")
    _pve_get "nodes/$PVE_NODE/qemu/$vmid/status/current" >/dev/null 2>&1
}

vm_status () { # vm_status NAME -> running|stopped|absent
    local vmid; vmid=$(_pve_vmid "$1")
    _pve_get "nodes/$PVE_NODE/qemu/$vmid/status/current" 2>/dev/null \
        | jq -r '.data.status // "absent"'
}

vm_start () { # vm_start NAME
    local vmid; vmid=$(_pve_vmid "$1") upid
    [[ $(vm_status "$1") == running ]] && return 0
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/status/start" | jq -r '.data')
    _pve_wait_task "$upid" 120
}

vm_kill () { # vm_kill NAME
    local vmid; vmid=$(_pve_vmid "$1") upid
    [[ $(vm_status "$1") == stopped ]] && return 0
    # stop, not shutdown: this is the "pull the power" path, and a guest that
    # is mid-install has no reason to cooperate.
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/status/stop" \
           -d 'overrule-shutdown=1' | jq -r '.data')
    _pve_wait_task "$upid" 120 || true
    local waited=0
    while (( waited < 60 )); do
        [[ $(vm_status "$1") == stopped ]] && return 0
        sleep 2; waited=$((waited+2))
    done
    return 1
}

vm_wait_stopped () { # vm_wait_stopped NAME TIMEOUT
    local name=$1 timeout=${2:-300} waited=0
    while (( waited < timeout )); do
        [[ $(vm_status "$name") == stopped ]] && return 0
        sleep 5; waited=$((waited+5))
    done
    return 1
}

# Destroy refuses on anything whose live config does not carry the tag, and on
# anything outside the VMID band. Both are re-read from the node rather than
# assumed, because this is the one operation that cannot be undone.
vm_destroy () { # vm_destroy NAME
    local name=$1 vmid tags upid
    vmid=$(_pve_vmid "$name")
    _pve_in_band "$vmid" || { echo "refusing: $vmid outside the test band" >&2; return 1; }
    vm_exists "$name" || return 0
    tags=$(_pve_config "$vmid" | jq -r '.tags // ""')
    case ",$tags," in
        *",$PVE_TAG,"*) ;;
        *) echo "refusing to destroy $vmid: tag '$PVE_TAG' not present (tags=$tags)" >&2
           return 1 ;;
    esac
    vm_kill "$name" || true
    # purge strips backup/replication/HA entries; destroy-unreferenced-disks
    # sweeps the volumes the pull-a-disk phases deliberately leave as unused[n].
    upid=$(_pve_curl -X DELETE \
        "$(_pve_api)/nodes/$PVE_NODE/qemu/$vmid?purge=1&destroy-unreferenced-disks=1" \
        | jq -r '.data')
    _pve_wait_task "$upid" 300
}

vm_destroy_all () {
    local mode
    for mode in uefi bios; do vm_destroy "${VM_PREFIX}${mode}" || true; done
}

# --------------------------------------------------------------------- define --

# A disk's guest-visible name has to be predictable, because install-me.sh
# records /dev/disk/by-id/... into disk-layout.json and disk-layout.nix consumes
# it verbatim.
#
# wwn is the one to key on: /dev/disk/by-id/wwn-0x<16 hex> is a documented,
# fully predictable path with no vendor or product prefix. The serial is set as
# well because it is what a human reads in `lsblk -o SERIAL`, but the exact
# scsi-* path udev derives from it is generated guest-side and is not something
# Proxmox documents -- so it is not what the tests should depend on.
_pve_wwn ()    { printf '0x5000c50000ff%02d%02d' "${2:-0}" "$1"; }
_pve_serial () { printf 'ZFSTEST%s' "$1"; }

# vm_define NAME FIRMWARE NDISKS DISK_GB PORT BOOT_ISO REPO_ISO
#
# PORT is accepted and ignored: it is UTM's way of naming a serial console, and
# on Proxmox the console is a unix socket on the node keyed by VMID instead.
vm_define () {
    local name=$1 firmware=$2 ndisks=$3 disk_gb=$4 boot_iso=$6 repo_iso=$7
    local vmid; vmid=$(_pve_vmid "$name")
    local -a args=()
    local i upid

    _pve_in_band "$vmid" || { echo "refusing: $vmid outside the test band" >&2; return 1; }
    vm_exists "$name" && { vm_destroy "$name" || return 1; }

    args+=(-d "vmid=$vmid" -d "name=$name" -d "tags=$PVE_TAG")
    # ostype and a fixed machine type keep firmware the only variable between
    # the two cells. q35 is not required for OVMF; pinning one machine type for
    # both modes is what makes the comparison honest.
    args+=(-d ostype=l26 -d machine=q35)
    args+=(-d "cores=${VM_CORES:-4}" -d "memory=${VM_MEM_MB:-8192}")
    # cpu=host because the guest is the same architecture as the node, which is
    # the entire reason this backend is faster than UTM. balloon=0 because
    # ballooning is on by default and pvestatd reclaims memory on a schedule --
    # real variance in a timing-sensitive test.
    args+=(-d cpu=host -d balloon=0)
    args+=(-d scsihw=virtio-scsi-single)
    args+=(-d "net0=virtio,bridge=$PVE_BRIDGE")

    if [[ $firmware == uefi ]]; then
        # OVMF needs somewhere to keep its variables, and pre-enrolled-keys
        # must be 0: with Secure Boot on, the GRUB this repo installs is
        # unsigned and the firmware refuses it. efitype=4m is the current
        # format; 2m exists only for backward compatibility.
        args+=(-d bios=ovmf)
        args+=(--data-urlencode "efidisk0=$PVE_STORAGE:1,efitype=4m,pre-enrolled-keys=0")
    else
        args+=(-d bios=seabios)
    fi

    for (( i = 0; i < ndisks; i++ )); do
        args+=(--data-urlencode \
          "scsi$i=$PVE_STORAGE:$disk_gb,serial=$(_pve_serial "$i"),wwn=$(_pve_wwn "$i"),discard=on,iothread=1,cache=$PVE_DISK_CACHE")
    done

    # Two CD-ROMs on ide0 and ide2, the even indices. The odd ones map to
    # unit=1 on q35 and have a history of not working.
    args+=(--data-urlencode "ide0=$PVE_ISO_STORAGE:iso/$(basename "$boot_iso"),media=cdrom")
    args+=(--data-urlencode "ide2=$PVE_ISO_STORAGE:iso/$(basename "$repo_iso"),media=cdrom")
    args+=(--data-urlencode "boot=order=ide0")

    # serial0 plus vga=serial0 is what puts the console on a socket the harness
    # can reach. Without vga=serial0 the guest still has a serial port but the
    # firmware and bootloader talk to a VGA display nobody is watching.
    args+=(-d serial0=socket -d vga=serial0)

    upid=$(_pve_post "nodes/$PVE_NODE/qemu" "${args[@]}" | jq -r '.data')
    _pve_wait_task "$upid" 300
}

# ---------------------------------------------------------------------- disks --

# Which scsiN slot holds a given logical disk id (disk0, disk1, ... disk3).
_pve_slot () { echo "scsi${1#disk}"; }

# Detach without deleting: the config entry goes away and the volume survives
# as unused[n], which is exactly what pulling a disk out of a running mirror
# looks like. `unlink --force` would destroy the volume instead, and then the
# replace phase would have nothing to put back.
vm_remove_drive () { # vm_remove_drive NAME ID
    local name=$1 slot; slot=$(_pve_slot "$2")
    local vmid; vmid=$(_pve_vmid "$name")
    local upid
    _pve_config "$vmid" | jq -e --arg s "$slot" 'has($s)' >/dev/null || return 0
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/config" -d "delete=$slot" | jq -r '.data // empty')
    _pve_wait_task "$upid" 120
}

# Put a disk back. Idempotent, and it reattaches the *same* volume by finding it
# among the unused[n] entries rather than allocating a new one.
vm_readd_drive () { # vm_readd_drive NAME ID
    local name=$1 id=$2 slot; slot=$(_pve_slot "$id")
    local vmid; vmid=$(_pve_vmid "$name")
    local volid upid cfg
    cfg=$(_pve_config "$vmid")
    echo "$cfg" | jq -e --arg s "$slot" 'has($s)' >/dev/null && return 0
    volid=$(echo "$cfg" | jq -r 'to_entries
              | map(select(.key | startswith("unused")))
              | .[0].value // empty')
    [[ -n $volid ]] || { echo "no unused volume to reattach as $slot" >&2; return 1; }
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/config" \
        --data-urlencode "$slot=$volid,discard=on,iothread=1,cache=$PVE_DISK_CACHE" \
        | jq -r '.data // empty')
    _pve_wait_task "$upid" 120
}

# A genuinely new disk, so the replacement really is a different device with its
# own by-id name and the installer's "exclude disks already in the layout" logic
# is exercised for real.
vm_blank_drive () { # vm_blank_drive NAME ID SIZE_GB
    local name=$1 id=$2 size=$3 slot; slot=$(_pve_slot "$id")
    local vmid; vmid=$(_pve_vmid "$name")
    local n=${id#disk} upid
    _pve_config "$vmid" | jq -e --arg s "$slot" 'has($s)' >/dev/null && return 0
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/config" \
        --data-urlencode \
        "$slot=$PVE_STORAGE:$size,serial=$(_pve_serial "$n"),wwn=$(_pve_wwn "$n" 1),discard=on,iothread=1,cache=$PVE_DISK_CACHE" \
        | jq -r '.data // empty')
    _pve_wait_task "$upid" 300
}

# Eject both CDs and boot the disks, so the phase that claims to test the
# bootloader cannot quietly boot the installer's kernel again.
vm_boot_from_disk () { # vm_boot_from_disk NAME
    local name=$1 vmid upid
    vmid=$(_pve_vmid "$name")
    upid=$(_pve_post "nodes/$PVE_NODE/qemu/$vmid/config" \
        -d 'delete=ide0,ide2' \
        --data-urlencode "boot=order=scsi0;scsi1;scsi2;scsi3" | jq -r '.data // empty')
    _pve_wait_task "$upid" 120
}

# ------------------------------------------------------------------- console --

# The console is a unix socket QEMU creates at VM start and removes at stop, so
# its presence is the readiness signal -- the direct equivalent of waiting for
# UTM's TCP listener. Checked over ssh because the socket lives on the node.
#
# Deliberately does not connect: a socket chardev serves one client at a time,
# so a probe that opened it would be holding the console the driver needs. That
# exact mistake cost real time on the UTM side, where `nc -z` consumed the
# single client.
vm_serial_ready () { # vm_serial_ready NAME PORT TRIES
    local name=$1 tries=${3:-60} vmid
    vmid=$(_pve_vmid "$name")
    while (( tries-- > 0 )); do
        if ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$(_pve_ssh)" \
               "test -S /var/run/qemu-server/$vmid.serial0" 2>/dev/null; then
            # Export the connect command for the expect drivers. ssh -T and a
            # bare `socat -` keep it byte-clean: a remote pty would translate
            # \n to \r\n and corrupt the transcript.
            local dest; dest=$(_pve_ssh)
            VM_SERIAL_CMD="ssh -T -o BatchMode=yes $dest socat - UNIX-CONNECT:/var/run/qemu-server/$vmid.serial0"
            export VM_SERIAL_CMD
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------- isos --

# Push a locally built ISO to the node's ISO storage.
#
# The multipart shape is not negotiable and is easy to get subtly wrong: the
# file part must be named `filename`, the stored name comes from that part's own
# filename= attribute, and `content`/`checksum-algorithm`/`checksum` are
# consumed in an earlier parse phase than the file -- so they must be sent
# first or they are silently ignored.
pve_upload_iso () { # pve_upload_iso LOCAL_PATH
    local path=$1 sum
    sum=$(shasum -a 256 "$path" | cut -d' ' -f1)
    _pve_curl -X POST "$(_pve_api)/nodes/$PVE_NODE/storage/$PVE_ISO_STORAGE/upload" \
        -F content=iso \
        -F checksum-algorithm=sha256 -F "checksum=$sum" \
        -F "filename=@$path;filename=$(basename "$path")" \
        | jq -r '.data // empty' | { read -r upid || true; _pve_wait_task "${upid-}" 900; }
}

pve_iso_present () { # pve_iso_present BASENAME
    _pve_get "nodes/$PVE_NODE/storage/$PVE_ISO_STORAGE/content?content=iso" \
        | jq -e --arg f "$1" '.data | map(.volid) | any(endswith("/" + $f))' >/dev/null
}
