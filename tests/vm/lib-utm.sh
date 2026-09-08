# shellcheck shell=bash
# Host-side UTM control for the VM boot tests. Sourced, never executed.
#
# UTM has two scripting surfaces and neither is sufficient alone:
#
#   - AppleScript `make new virtual machine` creates a VM and can size drives,
#     but it silently ignores `source:` on a removable drive, so it cannot
#     insert an ISO. (Verified: the CD device appears with ImageName unset.)
#   - The .utm bundle is just a directory holding a config.plist and a Data/
#     folder of disk images, which we can write completely.
#
# So we build the bundle ourselves and hand the finished thing to UTM. That
# also means a scenario can add, remove or blank a disk by rewriting the plist
# between runs, which is how the "pull a disk" tests work.
#
# Bundles live in UTM's Documents container because that is the only directory
# UTM scans; they are named with a fixed prefix so cleanup never touches a VM
# the operator created themselves.

UTM_APP=${UTM_APP:-/Applications/UTM.app}
UTM_BIN="$UTM_APP/Contents/MacOS/utmctl"
UTM_DOCS="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# Every VM this suite creates starts with this. Cleanup refuses to delete
# anything that does not.
VM_PREFIX=${VM_PREFIX:-nixinst-test-}

utm_available () {
    [[ $(uname -s) == Darwin ]] || return 1
    [[ -x $UTM_BIN ]] || return 1
    [[ -d $UTM_DOCS ]] || return 1
}

vm_bundle () { echo "$UTM_DOCS/$1.utm"; }

# ---------------------------------------------------------------- lifecycle --

# vm_exists NAME
vm_exists () { [[ -d $(vm_bundle "$1") ]]; }

# vm_status NAME -> started | stopped | paused | (empty if unknown)
vm_status () { "$UTM_BIN" status "$1" 2>/dev/null | tr -d '\r'; }

vm_start () { "$UTM_BIN" start "$1" >/dev/null 2>&1; }

# A guest that has run `poweroff` stops on its own; this is the hard kill for
# a guest that hung.
#
# It waits for the VM to actually reach `stopped`, and that wait is not
# optional: `utmctl start` on a VM that is still running is a silent no-op, so
# skipping it means the next phase attaches to the *previous* boot and reads a
# console that will never say anything. That failure looks exactly like a hung
# guest, which is a very expensive thing to debug at emulation speed.
vm_kill () {
    local name=$1 waited=0
    "$UTM_BIN" stop "$name" --force >/dev/null 2>&1 || true
    while [[ $(vm_status "$name") == started ]] && (( waited < 60 )); do
        sleep 2; waited=$((waited+2))
    done
    [[ $(vm_status "$name") != started ]] && return 0

    # utmctl talks to UTM over AppleEvents and both can wedge: a stuck VM
    # answers `stop --force` with OSStatus -1712 (event timed out) and stays
    # "started" forever, which would hang an unattended run. The QEMU process
    # is the ground truth, so go around UTM and kill it.
    pkill -9 -f "$(vm_bundle "$name")" 2>/dev/null || true
    waited=0
    while [[ $(vm_status "$name") == started ]] && (( waited < 30 )); do
        sleep 2; waited=$((waited+2))
    done
    [[ $(vm_status "$name") != started ]]
}

# vm_wait_stopped NAME TIMEOUT_S -> 0 if it stopped in time
vm_wait_stopped () {
    local name=$1 timeout=$2 waited=0
    while (( waited < timeout )); do
        [[ $(vm_status "$name") == started ]] || return 0
        sleep 5; waited=$((waited+5))
    done
    return 1
}

# UTM reads every bundle in its Documents folder at launch and then keeps the
# configuration in memory. Editing a config.plist behind its back therefore
# does nothing until it restarts -- verified the hard way: a VM kept booting
# with arguments that had already been removed from its plist.
#
# So this is not a convenience, it is the commit step. Every function that
# rewrites a bundle must be followed by utm_reload before the VM is started.
#
# (`import` is the other option and is worse: it copies the bundle and leaves a
# second VM with the same name registered.)
utm_reload () {
    # SIGTERM, not `osascript -e 'tell application "UTM" to quit'`.
    #
    # AppleScript has no timeout: if UTM is busy or wedged, osascript blocks
    # forever and no amount of bounding the loops below helps. That hung this
    # suite repeatedly -- the harness sat in utm_reload for tens of minutes
    # before a phase could even start its driver. Signals are bounded.
    pkill -x UTM 2>/dev/null || true
    local waited=0
    while pgrep -x UTM >/dev/null && (( waited < 20 )); do sleep 1; waited=$((waited+1)); done
    pgrep -x UTM >/dev/null && pkill -9 -x UTM 2>/dev/null
    sleep 1

    open -a UTM
    waited=0
    while ! "$UTM_BIN" list >/dev/null 2>&1 && (( waited < 60 )); do sleep 1; waited=$((waited+1)); done
    "$UTM_BIN" list >/dev/null 2>&1
}


# Deletes the bundle directly rather than via `utmctl delete`, so a typo in a
# name can never remove one of the operator's own VMs.
vm_destroy () {
    local name=$1
    [[ $name == "$VM_PREFIX"* ]] || { echo "refusing to destroy '$name': not a test VM" >&2; return 1; }
    vm_kill "$name"
    "$UTM_BIN" delete "$name" >/dev/null 2>&1 || true
    rm -rf -- "$(vm_bundle "$name")"
}

# Remove every VM this suite has ever made. Safe by construction: the prefix
# check in vm_destroy gates each one.
vm_destroy_all () {
    local b name
    for b in "$UTM_DOCS/$VM_PREFIX"*.utm; do
        [[ -d $b ]] || continue
        name=$(basename "$b" .utm)
        vm_destroy "$name"
    done
}

# ------------------------------------------------------------- bundle build --

# vm_define NAME FIRMWARE NDISKS DISK_GB SERIAL_PORT [BOOT_ISO] [REPO_ISO]
#
# Writes a complete .utm bundle. Disk images are sparse (mkfile -n), so an
# 8 GiB test disk costs kilobytes until the guest writes to it.
#
# FIRMWARE is uefi|bios and maps to QEMU.UEFIBoot, which is the only thing
# separating the two firmware paths this repo supports.
#
# BOOT_ISO should be the serial-enabled repack from lib-assets.sh, not the
# stock ISO: the stock one boots to a console nothing here can read.
vm_define () {
    local name=$1 firmware=$2 ndisks=$3 disk_gb=$4 serial_port=$5
    local boot_iso=${6-} repo_iso=${7-}
    local bundle; bundle=$(vm_bundle "$name")

    rm -rf -- "$bundle"
    mkdir -p "$bundle/Data"

    local uuid; uuid=$(uuidgen)
    local drives="[]" i id

    # Root mirror members. Named deterministically (disk0..diskN-1) so a
    # scenario can blank or drop a specific one later.
    for (( i=0; i<ndisks; i++ )); do
        id="disk$i"
        mkfile -n "${disk_gb}g" "$bundle/Data/$id.img"
        drives=$(jq --arg id "$id" '. + [{
            Identifier:       $id,
            ImageName:        ($id + ".img"),
            ImageType:        "Disk",
            Interface:        "NVMe",
            InterfaceVersion: 1,
            ReadOnly:         false
        }]' <<<"$drives")
    done

    # The installer ISO and the repo ISO ride as IDE CDs. IDE rather than NVMe
    # because SeaBIOS (the bios path) will not boot off NVMe.
    if [[ -n $boot_iso ]]; then
        cp "$boot_iso" "$bundle/Data/boot.iso"
        drives=$(jq '. + [{
            Identifier:       "bootcd",
            ImageName:        "boot.iso",
            ImageType:        "CD",
            Interface:        "IDE",
            InterfaceVersion: 1,
            ReadOnly:         true
        }]' <<<"$drives")
    fi
    if [[ -n $repo_iso ]]; then
        cp "$repo_iso" "$bundle/Data/repo.iso"
        drives=$(jq '. + [{
            Identifier:       "repocd",
            ImageName:        "repo.iso",
            ImageType:        "CD",
            Interface:        "IDE",
            InterfaceVersion: 1,
            ReadOnly:         true
        }]' <<<"$drives")
    fi

    vm_write_config "$name" "$uuid" "$firmware" "$serial_port" "$drives" "[]"
}

# vm_write_config NAME UUID FIRMWARE SERIAL_PORT DRIVES_JSON [QEMU_ARGS_JSON]
#
# Split out from vm_define because the disk-failure scenarios rewrite the drive
# list of an existing bundle without touching its images.
vm_write_config () {
    local name=$1 uuid=$2 firmware=$3 serial_port=$4 drives=$5 args=${6:-[]}
    local bundle; bundle=$(vm_bundle "$name")
    local uefi=true; [[ $firmware == uefi ]] || uefi=false

    # Hypervisor is false and must stay false: the guest is x86_64 and this is
    # an arm64 host, so QEMU runs in TCG. That is the whole reason this suite
    # is slow and opt-in.
    #
    # ForceMulticore stays off and CPUCount stays at 4 because that is the
    # configuration these tests have actually completed installs on. Whether
    # turning it on helps is UNMEASURED -- do not assume either way.
    #
    # If you do measure it, sample the right process the right way. `QEMUHelper`
    # is a wrapper and reads ~0% CPU; the emulator is `QEMULauncher`. And use
    # `top -l 2`, not `ps -o %cpu`, which on macOS is a decaying average since
    # process start -- it swings wildly and made a busy guest look idle, which
    # sent this investigation down a blind alley once already.
    #
    # Also note that long silences are normal, not stalls: `copying channel...`
    # and the closure copy print nothing for a long time while working.
    #
    # What did measurably help was giving the guest less to *build* (see
    # documentation.* in lib-assets.sh) rather than more cores to build on.
    jq -n \
        --arg name "$name" --arg uuid "$uuid" \
        --argjson uefi "$uefi" --argjson port "$serial_port" \
        --argjson drives "$drives" \
        --argjson args "$args" \
        --argjson mem "${VM_MEM_MB:-8192}" --argjson cores "${VM_CORES:-4}" '{
        Backend:              "QEMU",
        ConfigurationVersion: 4,
        Display:              [],
        Drive:                $drives,
        Information:          { IconCustom: false, Name: $name, UUID: $uuid },
        Input:                { MaximumUsbShare: 3, UsbBusSupport: "3.0", UsbSharing: false },
        Network:              [ { Hardware: "e1000", IsolateFromHost: false,
                                  MacAddress: "72:39:40:30:C0:1C", Mode: "Shared",
                                  PortForward: [] } ],
        QEMU:                 { AdditionalArguments: $args, BalloonDevice: false,
                                DebugLog: false, Hypervisor: false, PS2Controller: false,
                                RNGDevice: true, RTCLocalTime: false, TPMDevice: false,
                                TSO: false, UEFIBoot: $uefi },
        Serial:               [ { Mode: "TcpServer", Target: "Auto", TcpPort: $port } ],
        Sharing:              { ClipboardSharing: false, DirectoryShareMode: "None",
                                DirectoryShareReadOnly: true },
        Sound:                [],
        System:               { Architecture: "x86_64", CPU: "default", CPUCount: $cores,
                                CPUFlagsAdd: [], CPUFlagsRemove: [], ForceMulticore: false,
                                JITCacheSize: 0, MemorySize: $mem, Target: "q35" }
        }' > "$bundle/config.json"

    plutil -convert xml1 "$bundle/config.json" -o "$bundle/config.plist"
    rm -f "$bundle/config.json"
}

# Read the current drive list back out of a bundle, as JSON.
vm_drives () {
    local bundle; bundle=$(vm_bundle "$1")
    plutil -convert json -o - "$bundle/config.plist" | jq '.Drive'
}

vm_uuid () {
    local bundle; bundle=$(vm_bundle "$1")
    plutil -convert json -o - "$bundle/config.plist" | jq -r '.Information.UUID'
}

vm_firmware () {
    local bundle; bundle=$(vm_bundle "$1")
    if [[ $(plutil -convert json -o - "$bundle/config.plist" | jq -r '.QEMU.UEFIBoot') == true ]]
    then echo uefi; else echo bios; fi
}

vm_serial_port () {
    local bundle; bundle=$(vm_bundle "$1")
    plutil -convert json -o - "$bundle/config.plist" | jq -r '.Serial[0].TcpPort'
}

vm_qemu_args () {
    local bundle; bundle=$(vm_bundle "$1")
    plutil -convert json -o - "$bundle/config.plist" | jq -c '.QEMU.AdditionalArguments'
}

# Rewrite a bundle's drive list (and optionally its qemu args), keeping
# everything else -- uuid, firmware, serial port -- exactly as it was.
vm_rewrite () { # vm_rewrite NAME DRIVES_JSON [ARGS_JSON]
    local name=$1 drives=$2 args=${3-}
    [[ -n $args ]] || args=$(vm_qemu_args "$name")
    vm_write_config "$name" "$(vm_uuid "$name")" "$(vm_firmware "$name")" \
                    "$(vm_serial_port "$name")" "$drives" "$args"
}

# --------------------------------------------------------- disk manipulation --

# vm_remove_drive NAME IDENTIFIER
#
# Physically pulling a disk. The image file is left on disk so the same disk
# can be put back with vm_readd_drive.
vm_remove_drive () {
    local name=$1 id=$2 drives
    drives=$(vm_drives "$name" | jq --arg id "$id" 'map(select(.Identifier != $id))')
    vm_rewrite "$name" "$drives"
}

# vm_readd_drive NAME IDENTIFIER  -- put a previously removed disk back.
#
# Idempotent: any existing entry for this Identifier is dropped first. Without
# that, re-running a phase appends a second copy and QEMU refuses to start the
# VM at all -- "Duplicate ID 'drivedisk3' for drive" -- which presents as
# vm_start failing for no visible reason.
vm_readd_drive () {
    local name=$1 id=$2 drives
    drives=$(vm_drives "$name" | jq --arg id "$id" 'map(select(.Identifier != $id)) + [{
        Identifier: $id, ImageName: ($id + ".img"), ImageType: "Disk",
        Interface: "NVMe", InterfaceVersion: 1, ReadOnly: false }]')
    vm_rewrite "$name" "$drives"
}

# vm_blank_drive NAME IDENTIFIER DISK_GB
#
# A brand-new replacement disk in the same slot: same size, no partition table,
# no ZFS label.
vm_blank_drive () {
    local name=$1 id=$2 gb=$3 bundle
    bundle=$(vm_bundle "$name")
    rm -f "$bundle/Data/$id.img"
    mkfile -n "${gb}g" "$bundle/Data/$id.img"
}

# vm_boot_from_disk NAME
#
# Drop both CDs *and* the direct-kernel arguments, so the next start goes
# through firmware -> GRUB -> the installed system. Clearing the arguments is
# the load-bearing half: leaving -kernel in place would silently boot the
# installer's kernel again and the suite would "pass" without ever executing
# the bootloader it is supposed to be testing.
vm_boot_from_disk () {
    local name=$1 drives
    drives=$(vm_drives "$name" | jq 'map(select(.ImageType != "CD"))')
    vm_rewrite "$name" "$drives" "[]"
}

# ------------------------------------------------------------------- serial --

# The guest console is a TCP server on localhost. Nothing is listening until
# QEMU is running, so callers poll.
#
# This deliberately does NOT connect. UTM's serial TcpServer serves a single
# client, and an `nc -z` readiness probe consumes it: the connection that
# matters then gets an immediate EOF and the phase looks like a guest that
# never printed anything. Checking for a LISTEN socket leaves the one
# connection for the expect session that actually needs it.
vm_serial_ready () {
    local port=$1 tries=${2:-60}
    while (( tries-- > 0 )); do
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}
