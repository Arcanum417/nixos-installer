#!/usr/bin/env bash
# Boots the thing. This is the suite the other four cannot be:
# tests/nix-eval.sh proves the configuration evaluates and tests/disk-integration.sh
# proves the partitioning is right, but neither proves a machine built this way
# starts. That needs firmware, a bootloader and an initrd, so it needs a VM.
#
# Runs on macOS with UTM, which is why it is not in CI (the GitHub runners are
# Linux and cannot nest a hypervisor usefully). The guest is x86_64 because
# that is what this repo targets: BOOTX64.EFI and the EF02 BIOS boot partition
# are x86-only, and an aarch64 guest could not test the BIOS path at all. The
# host here is arm64, so QEMU runs in TCG emulation and a full install takes
# hours, not minutes. Budget accordingly.
#
#   bash tests/vm-boot.sh                  both firmware modes, all phases
#   bash tests/vm-boot.sh uefi             one firmware mode
#   bash tests/vm-boot.sh bios replace     resume at one phase (needs prior state)
#   VM_KEEP=1 bash tests/vm-boot.sh        leave the VMs behind for inspection
#
# Phases are sequential and stateful. A single VM per firmware mode is
# installed once and then abused: eject the CDs and boot it, pull a disk and
# boot it again, hand it a blank disk and make it resilver.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=assert.sh
source "$HERE/assert.sh"
# shellcheck source=vm/lib-utm.sh
source "$HERE/vm/lib-utm.sh"
# shellcheck source=vm/lib-assets.sh
source "$HERE/vm/lib-assets.sh"

# --------------------------------------------------------------- environment --

[[ $(uname -s) == Darwin ]] || { echo "vm-boot.sh needs macOS + UTM"; exit 77; }
utm_available || { echo "UTM not installed at $UTM_APP"; exit 77; }
for c in expect nc jq plutil mkfile hdiutil osascript curl; do
    command -v "$c" >/dev/null || { echo "missing $c"; exit 77; }
done

DISK_GB=${DISK_GB:-8}
NDISKS=${NDISKS:-3}
WORK=$(mktemp -d)
LOGDIR=${LOGDIR:-$ROOT/tests/vm/logs}
mkdir -p "$LOGDIR"

cleanup () {
    rm -rf "$WORK"
    [[ ${VM_KEEP-0} == 1 ]] || vm_destroy_all
}
trap cleanup EXIT

# --------------------------------------------------------------- assets ------

section "assets"
ISO=$(fetch_iso) || { echo "could not fetch the NixOS ISO"; exit 77; }
if [[ -s $ISO ]]; then _pass "installer ISO cached ($(du -h "$ISO" | cut -f1))"
else _fail "installer ISO cached" "$ISO is empty"; summary "vm-boot"; exit 1; fi

# Cheap gate in front of an expensive suite. The guest cannot report a bad
# configuration until nixos-install runs, which is an hour of emulation in;
# nix-instantiate says the same thing in two seconds. Bail rather than skip:
# every later phase depends on an install that cannot succeed.
if FIXTURE_ERR=$(fixture_evaluates "$ROOT"); then
    _pass "generated configuration evaluates"
else
    _fail "generated configuration evaluates" "$FIXTURE_ERR"
    summary "vm-boot"; exit 1
fi

REPO_ISO="$WORK/repo.iso"
if build_repo_iso "$ROOT" "$REPO_ISO"; then _pass "repo ISO built"
else _fail "repo ISO built" "hdiutil makehybrid failed"; summary "vm-boot"; exit 1; fi

# The stock ISO boots to a console this harness cannot reach: GRUB's default
# entry sets no console=, and GRUB ignores serial input, so there is no way to
# pick the serial entry by hand. Repacking it with serial as the default is the
# way in -- see repack_iso_for_serial for the two approaches that do not work.
SERIAL_ISO="$ASSET_CACHE/nixos-minimal-serial-x86_64.iso"
CAN_INSTALL=1
if repack_iso_for_serial "$ISO" "$SERIAL_ISO"; then
    _pass "installer ISO repacked with a serial console as the default entry"
    BOOT_ISO="$SERIAL_ISO"
else
    CAN_INSTALL=0
    skip "installer ISO repacked with a serial console" \
         "needs xorriso (nix-shell -p xorriso); without it the installer has no console to drive"
fi

# --------------------------------------------------------------- helpers -----

# Facts come back from the guest as PROBE:<name>:<value> lines on the serial
# log. Values have newlines squashed to '~' so one probe is always one line.
probe () { # probe LOGFILE NAME -> value
    # The transcript is a serial console capture, so it needs normalising
    # before the value can be read out of it:
    #   - lines end in CR, not LF, so without translating them sed sees the
    #     whole file as one line and a greedy match swallows everything
    #   - it is full of CSI and OSC escapes (the shell emits OSC 133 prompt
    #     markers around every command)
    #   - the guest squashes newlines in a value to '~', which leaves one
    #     trailing '~' from the value's own final newline
    #   - each command is echoed before it runs, so the literal
    #     'PROBE:name:$( ... )' text appears too and must be skipped
    tr '\r' '\n' < "$1" \
      | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
            -e 's/\x1b\][0-9;]*[A-Za-z]*//g' \
            -e 's/\x07//g' \
      | grep -a "PROBE:$2:" | grep -av '[$](' \
      | sed -n "s/.*PROBE:$2:\(.*\)/\1/p" \
      | tail -n1 | sed -e 's/~*$//'
}


# The driver writes its own transcript via expect's log_file (unbuffered, and
# it captures send_user too). Redirecting stdout here as well would only
# duplicate it, and expect buffers a redirected stdout anyway -- which makes a
# multi-hour phase impossible to watch while it runs.
run_expect () { # run_expect SCRIPT LOGFILE ARGS...
    local script=$1 log=$2; shift 2
    : > "$log"
    expect "$HERE/vm/$script" "$log" "$@" >/dev/null 2>&1
}

# A phase that cannot run because the one before it failed should not be
# reported as a code defect.
PHASE_OK=1

# --------------------------------------------------------------- phases ------

phase_install () { # phase_install NAME FIRMWARE PORT
    local name=$1 firmware=$2 port=$3
    local log="$LOGDIR/$firmware-install.log"

    if [[ $CAN_INSTALL != 1 ]]; then
        skip "$firmware: install-me.sh completes" "no serial-enabled installer ISO"
        PHASE_OK=0; return
    fi

    # A previous run with VM_KEEP=1 may have left this VM running, and its QEMU
    # would still hold the serial port while vm_define deletes the bundle out
    # from under it.
    vm_exists "$name" && vm_kill "$name"

    vm_define "$name" "$firmware" "$NDISKS" "$DISK_GB" "$port" "$BOOT_ISO" "$REPO_ISO"
    utm_reload
    vm_start "$name"

    if ! vm_serial_ready "$port" 120; then
        _fail "$firmware: guest serial port opens" "nothing listening on 127.0.0.1:$port"
        PHASE_OK=0; return
    fi
    _pass "$firmware: guest serial port opens"

    if run_expect install.expect "$log" "$port" "$NDISKS" "$firmware"; then
        _pass "$firmware: install-me.sh completes on a $NDISKS-disk mirror"
    else
        _fail "$firmware: install-me.sh completes on a $NDISKS-disk mirror" \
              "$(grep -m1 'FAILED:' "$log" || echo "see $log")"
        PHASE_OK=0; return
    fi

    # The installer's own invariants, read back off the console log.
    contains "$firmware: hostid was set before any pool existed" "$(cat "$log")" "hostid set to $TEST_HOSTID"
    contains "$firmware: pool is a mirror"                       "$(cat "$log")" "mirror-0"
    contains "$firmware: pools exported for a clean first import" "$(cat "$log")" "pools exported"

    vm_wait_stopped "$name" 300 || vm_kill "$name"
}

phase_boot () { # phase_boot NAME FIRMWARE PORT
    local name=$1 firmware=$2 port=$3
    local log="$LOGDIR/$firmware-boot.log"

    # Drops the CDs and the -kernel arguments together. Without the second part
    # the VM would quietly boot the installer's kernel again and this phase
    # would pass without ever running the bootloader it exists to test.
    vm_boot_from_disk "$name"
    utm_reload
    vm_start "$name"
    vm_serial_ready "$port" 120 || { _fail "$firmware: boot serial" "no serial"; PHASE_OK=0; return; }

    if run_expect postboot.expect "$log" "$port"; then
        _pass "$firmware: installed system boots off the mirror"
    else
        _fail "$firmware: installed system boots off the mirror" \
              "$(grep -m1 'FAILED:' "$log" || echo "see $log")"
        PHASE_OK=0; return
    fi

    eq "$firmware: hostname from unique.nix"  "$(probe "$log" hostname)"   "$TEST_HOSTNAME"
    eq "$firmware: hostid survived the install" "$(probe "$log" hostid)"   "$TEST_HOSTID"
    # The probe collapses the tab from `zpool list -H` to a single space. The
    # emulated serial console does not preserve tabs, so asserting on one made
    # this fail with "[zroot ONLINE] lacks [zroot<tab>ONLINE]".
    contains "$firmware: root pool is ONLINE"  "$(probe "$log" poolstate)" "zroot ONLINE"
    contains "$firmware: pool reports healthy" "$(probe "$log" poolhealthy)" "healthy"
    eq "$firmware: root is the zfs dataset"    "$(probe "$log" rootfs)"    "zroot/root"
    contains "$firmware: layout json matches the firmware" "$(probe "$log" layout)" "\"mode\":\"$firmware\""
    contains "$firmware: layout json records $NDISKS disks" "$(probe "$log" layout)" "\"n\":$NDISKS"

    # A clean boot means more than "a shell appeared". These facts are already
    # collected by postboot.expect on every phase, so asserting them costs no
    # extra emulated time -- they were simply going unchecked.

    # is-system-running reports "degraded" if any unit failed, which on a
    # machine this configuration built is a defect worth failing on. The
    # failed-unit names come along so the failure says which one.
    eq "$firmware: systemd reports the system running" \
       "$(probe "$log" systemstate)" "running"
    eq "$firmware: no failed units" "$(probe "$log" failedunits)" ""

    # The happy path of zfs-health.nix. The degraded phase already asserts this
    # check notices a broken pool; nothing asserted it stays quiet on a good one.
    contains "$firmware: zfs-health-check reports healthy" \
             "$(probe "$log" health_check)" "healthy"
    eq "$firmware: no vdev is DEGRADED" "$(probe "$log" degraded)" "0"

    # disk-layout.nix gives every mirror member its own ESP and its own mount.
    # On a clean boot all of them must be mounted, not just the one at /boot.
    contains "$firmware: every mirror member's boot partition is mounted" \
             "$(probe "$log" bootmounts)" "/boot-fallback-$((NDISKS - 1))"

    # boot.zfs.forceImportRoot = false is the reason the hostId handling has to
    # be right; if the kernel command line carried a force flag, a broken
    # hostId would be masked and this suite would prove nothing about it.
    lacks "$firmware: root pool imported without a force flag" \
          "$(probe "$log" forceimport)" "zfs_force"

    if [[ $firmware == uefi ]]; then
        contains "$firmware: GRUB is at the removable path" \
                 "$(probe "$log" removable_efi)" "BOOTX64.EFI"
    else
        skip "$firmware: removable EFI path" "BIOS mode has no ESP"
    fi

    vm_wait_stopped "$name" 300 || vm_kill "$name"
}

phase_degraded () { # phase_degraded NAME FIRMWARE PORT
    local name=$1 firmware=$2 port=$3
    local log="$LOGDIR/$firmware-degraded.log"

    # Pull the first disk. In UEFI mode that is also the disk whose ESP is
    # mounted at /boot, so this is the test that the machine really can boot
    # off a survivor and that `nofail` on the boot mounts is doing its job.
    vm_remove_drive "$name" disk0
    utm_reload
    vm_start "$name"
    vm_serial_ready "$port" 120 || { _fail "$firmware: degraded serial" "no serial"; PHASE_OK=0; return; }

    if run_expect postboot.expect "$log" "$port"; then
        _pass "$firmware: boots with the first mirror member pulled"
    else
        _fail "$firmware: boots with the first mirror member pulled" \
              "$(grep -m1 'FAILED:' "$log" || echo "see $log")"
        PHASE_OK=0; return
    fi

    ne "$firmware: pool notices the missing disk" "$(probe "$log" poolhealthy)" \
       "pool 'zroot' is healthy"
    contains "$firmware: pool is DEGRADED but usable" "$(probe "$log" poolstate)" "DEGRADED"
    eq "$firmware: root still mounted from the pool"  "$(probe "$log" rootfs)" "zroot/root"

    # nofail is what stops a missing /boot from blocking the boot; if it had
    # blocked, no probe would have been produced at all.
    _pass "$firmware: a missing /boot did not block startup (nofail)"

    # zfs-health.nix exists to notice exactly this state.
    contains "$firmware: zfs-health-check reports the degradation" \
             "$(probe "$log" health_check)" "DEGRADED"

    vm_wait_stopped "$name" 300 || vm_kill "$name"
}

phase_replace () { # phase_replace NAME FIRMWARE PORT
    local name=$1 firmware=$2 port=$3
    local log="$LOGDIR/$firmware-replace.log"

    # A genuinely new disk: a different device, so it gets its own by-id and
    # the installer's "exclude disks already in the layout" logic is exercised
    # for real.
    vm_blank_drive "$name" disk3 "$DISK_GB"
    vm_readd_drive "$name" disk3
    utm_reload
    vm_start "$name"
    vm_serial_ready "$port" 120 || { _fail "$firmware: replace serial" "no serial"; PHASE_OK=0; return; }

    if run_expect replace.expect "$log" "$port"; then
        _pass "$firmware: replace-boot-disk.sh resilvers onto a new disk"
    else
        _fail "$firmware: replace-boot-disk.sh resilvers onto a new disk" \
              "$(grep -m1 'FAILED:' "$log" || echo "see $log")"
        PHASE_OK=0; return
    fi

    contains "$firmware: GUIDs randomised on the replacement" "$(cat "$log")" "GUIDs randomised"
    contains "$firmware: bootloader reinstalled onto the new disk" "$(cat "$log")" "install-bootloader"
    contains "$firmware: pool healthy again after resilver" "$(probe "$log" poolhealthy)" "healthy"
    contains "$firmware: layout json now names the new disk" "$(probe "$log" layout)" "\"n\":$NDISKS"

    # A resilver that silently stopped at N-1 members would still report the
    # pool healthy, so check the state and the degraded count too.
    contains "$firmware: pool is ONLINE again, not just not-failing" \
             "$(probe "$log" poolstate)" "zroot ONLINE"
    eq "$firmware: no vdev left DEGRADED after the resilver" \
       "$(probe "$log" degraded)" "0"

    # The hostId is stamped into the pool labels, and forceImportRoot is false,
    # so a replace that disturbed it would leave a machine that cannot import
    # its own root pool on the next boot. replace-boot-disk.sh does not touch
    # it; this is what proves that.
    eq "$firmware: hostid unchanged by the replace" "$(probe "$log" hostid)" "$TEST_HOSTID"

    vm_wait_stopped "$name" 600 || vm_kill "$name"
}

# --------------------------------------------------------------- driver ------

MODES=(uefi bios)
PHASES=(install boot degraded replace)

if [[ ${1-} == uefi || ${1-} == bios ]]; then MODES=("$1"); shift; fi
[[ $# -gt 0 ]] && PHASES=("$@")

# Distinct ports so a leftover VM from a previous run cannot be driven by
# accident, and so both firmware modes could run concurrently later.
port_for () { case $1 in uefi) echo 4410 ;; bios) echo 4411 ;; esac; }

for mode in "${MODES[@]}"; do
    section "$mode"
    name="${VM_PREFIX}${mode}"
    port=$(port_for "$mode")
    PHASE_OK=1

    for ph in "${PHASES[@]}"; do
        if [[ $PHASE_OK != 1 ]]; then
            skip "$mode: phase $ph" "an earlier phase failed"
            continue
        fi
        case $ph in
            install)  phase_install  "$name" "$mode" "$port" ;;
            boot)     phase_boot     "$name" "$mode" "$port" ;;
            degraded) phase_degraded "$name" "$mode" "$port" ;;
            replace)  phase_replace  "$name" "$mode" "$port" ;;
            *) _fail "unknown phase" "$ph" ;;
        esac
    done
done

summary "vm-boot"
