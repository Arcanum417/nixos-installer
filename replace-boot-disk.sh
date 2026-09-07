#!/usr/bin/env bash

# Replace, drop, or add a member of the root mirror.
#
#   ./replace-boot-disk.sh            replace a failed disk with a new one
#   ./replace-boot-disk.sh --add      widen the mirror with another disk
#   ./replace-boot-disk.sh --drop     forget a dead disk without replacing it
#
#   --layout PATH   operate on a different disk-layout.json
#                   (e.g. /mnt/etc/nixos/disk-layout.json from a live ISO)
#
# Run as root on the affected machine. See "Replacing a failed disk" in
# README.md for the manual equivalent.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE=replace
LAYOUT=/etc/nixos/disk-layout.json

while [[ $# -gt 0 ]]; do
    case $1 in
        --add)    MODE=add;   shift ;;
        --drop)   MODE=drop;  shift ;;
        --layout) LAYOUT=$2;  shift 2 ;;
        -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

need_root
need_cmds sgdisk lsblk blockdev wipefs udevadm findmnt jq zpool zfs

read_disk_layout "$LAYOUT"
set_part_numbers "$BOOT_MODE"

# nixos-rebuild only makes sense against the running system's own config.
CAN_REBUILD=0
[[ $LAYOUT == /etc/nixos/disk-layout.json ]] && CAN_REBUILD=1

hdr "Current layout ($LAYOUT)"
info "firmware  : $BOOT_MODE"
info "root pool : $ROOT_POOL"
zpool status -P "$ROOT_POOL" || die "pool $ROOT_POOL is not imported"

# ------------------------------------------------- classify each member -----

POOL_STATUS=$(zpool status -P "$ROOT_POOL")

slot_state () { # slot_state index -> ONLINE | MISSING | NOT-IN-POOL | <zfs state>
    local dev; dev=$(part_path "${BOOT_DISKS[$1]}" "$ZFSPART")
    local line; line=$(grep -F "$dev" <<<"$POOL_STATUS" | head -n1 || true)
    if [[ -z $line ]]; then
        [[ -b $dev ]] && echo "NOT-IN-POOL" || echo "MISSING"
        return
    fi
    awk '{print $2}' <<<"$line"
}

echo
say "Root mirror members"
for i in "${!BOOT_DISKS[@]}"; do
    st=$(slot_state "$i")
    mark=" "; [[ $st == ONLINE ]] || mark="!"
    printf "  %s %d) %-10s %-22s %s\n" "$mark" "$((i+1))" "$st" "${BOOT_MPS[$i]}" "${BOOT_DISKS[$i]}"
done

# ------------------------------------------------------------- pick slot ----

SLOT=-1
if [[ $MODE != add ]]; then
    DEFAULT=""
    for i in "${!BOOT_DISKS[@]}"; do
        [[ $(slot_state "$i") == ONLINE ]] || { DEFAULT=$((i+1)); break; }
    done
    [[ -n $DEFAULT ]] || warn "every member reports ONLINE - are you sure a disk failed?"
    ask PICK "which member to $MODE (number)" "$DEFAULT"
    [[ $PICK =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#BOOT_DISKS[@]} )) || die "invalid selection"
    SLOT=$((PICK-1))
    info "selected: ${BOOT_DISKS[$SLOT]}  (${BOOT_MPS[$SLOT]})"
fi

# --------------------------------------------------------------- --drop -----

if [[ $MODE == drop ]]; then
    [[ ${#BOOT_DISKS[@]} -gt 2 ]] || warn "dropping this disk leaves ${#BOOT_DISKS[@]} configured member(s) - the mirror will not be redundant"
    OLD=${BOOT_DISKS[$SLOT]}
    confirm_hard "Detach ${OLD} from $ROOT_POOL and remove it from the layout." "DROP"

    OLDDEV=$(part_path "$OLD" "$ZFSPART")
    if grep -qF "$OLDDEV" <<<"$POOL_STATUS"; then
        zpool detach "$ROOT_POOL" "$OLDDEV" || warn "zpool detach failed - detach it by hand and re-run"
    else
        warn "$OLDDEV is not in the pool; only updating the layout"
    fi

    mountpoint -q "${BOOT_MPS[$SLOT]}" && umount "${BOOT_MPS[$SLOT]}"
    unset 'BOOT_DISKS[SLOT]' 'BOOT_MPS[SLOT]'
    BOOT_DISKS=("${BOOT_DISKS[@]}"); BOOT_MPS=("${BOOT_MPS[@]}")
    write_disk_layout_json "$LAYOUT"
    ok "updated $LAYOUT"
    jq . "$LAYOUT"

    if [[ $CAN_REBUILD == 1 ]]; then
        hdr "nixos-rebuild boot --install-bootloader"
        nixos-rebuild boot --install-bootloader
    else
        warn "run 'nixos-rebuild boot --install-bootloader' on the target system"
    fi
    ok "done"
    exit 0
fi

# -------------------------------------------------- pick the new disk -------

scan_disks
hdr "Replacement disk"
select_disks 1 "the new mirror member" "${BOOT_DISKS[@]}"
NEW=${SELECTED[0]}
assert_disks_free "$NEW"

# A healthy member is both the size reference and the partition-table template.
HEALTHY=""
for i in "${!BOOT_DISKS[@]}"; do
    [[ $i -eq $SLOT ]] && continue
    if [[ $(slot_state "$i") == ONLINE ]]; then HEALTHY=${BOOT_DISKS[$i]}; break; fi
done
[[ -n $HEALTHY ]] || die "no healthy member to copy the partition table from.
        The pool has no surviving disk in a usable state - this is a restore
        from backup, not a disk replacement."

HSIZE=$(disk_bytes "$HEALTHY"); NSIZE=$(disk_bytes "$NEW")
info "healthy member : $(hr_size "$HSIZE")  $HEALTHY"
info "new disk       : $(hr_size "$NSIZE")  $NEW"
if (( NSIZE < HSIZE )); then
    warn "the new disk is smaller than the surviving one"
    # Every ZFS partition stops 1 GiB short of the end of the disk, so a
    # slightly smaller replacement is still fine - what matters is whether the
    # existing partition layout fits.
    NEED=$(( $(blockdev --getsize64 "$(part_path "$HEALTHY" "$ZFSPART")") ))
    info "the existing ZFS partition needs $(hr_size "$NEED")"
    (( NSIZE > NEED )) || die "the new disk is too small to hold the mirror partition"
    warn "it fits, but only because of the end-of-disk slack"
fi

# ------------------------------------------------------------- do it --------

confirm_hard "ERASE $NEW and $([[ $MODE == add ]] && echo 'attach it to' || echo 'use it to replace a member of') $ROOT_POOL." "REPLACE"

hdr "Preparing $NEW"
nuke_disk "$NEW"

# Copy the surviving disk's table, then give the copy its own identity.
# (sgdisk --replicate alone would duplicate the disk GUID and every partition
# GUID, which is what the old installer did with sfdisk --dump.)
sgdisk --replicate="$NEW" "$HEALTHY" >/dev/null
sgdisk --randomize-guids "$NEW" >/dev/null
settle
wait_for_nodes "$(part_path "$NEW" "$BOOTPART")" "$(part_path "$NEW" "$ZFSPART")"
ok "partitioned, GUIDs randomised"

if [[ $MODE == add ]]; then
    SLOT=${#BOOT_DISKS[@]}
    MP=$(next_free_mount_point)
    BOOT_DISKS+=("$NEW"); BOOT_MPS+=("$MP")
else
    MP=${BOOT_MPS[$SLOT]}
fi

mkfs_boot "$BOOT_MODE" "$(part_path "$NEW" "$BOOTPART")" "$SLOT"
ok "made $BOOT_MODE boot filesystem on $(part_path "$NEW" "$BOOTPART")"

hdr "ZFS"
NEWDEV=$(part_path "$NEW" "$ZFSPART")
if [[ $MODE == add ]]; then
    ANCHOR=$(part_path "$HEALTHY" "$ZFSPART")
    zpool attach "$ROOT_POOL" "$ANCHOR" "$NEWDEV"
    ok "attached $NEWDEV to the mirror"
else
    OLDDEV=$(part_path "${BOOT_DISKS[$SLOT]}" "$ZFSPART")
    if ! grep -qF "$OLDDEV" <<<"$POOL_STATUS"; then
        warn "$OLDDEV does not appear in zpool status - the pool probably knows"
        warn "the failed vdev by GUID instead. Pick it from below."
        zpool status -Pg "$ROOT_POOL"
        ask OLDDEV "vdev to replace (path or GUID)" ""
        [[ -n $OLDDEV ]] || die "no vdev given"
    fi
    zpool replace "$ROOT_POOL" "$OLDDEV" "$NEWDEV"
    ok "resilver started"
    BOOT_DISKS[$SLOT]=$NEW
fi

# ------------------------------------------------------ boot filesystem -----

hdr "Boot filesystem at $MP"
if mountpoint -q "$MP"; then
    umount "$MP"
fi
mkdir -p "$MP"
# Residue from running with this mirror half unmounted: those files were
# written to the root pool, not to any disk. They only waste space now.
if [[ -n $(ls -A "$MP" 2>/dev/null) ]]; then
    warn "$MP is a non-empty directory on the root pool (written while the disk was missing)"
    if confirm "Delete its contents?"; then rm -rf -- "${MP:?}"/*; fi
fi
mount "$(part_path "$NEW" "$BOOTPART")" "$MP"
ok "mounted"

write_disk_layout_json "$LAYOUT"
ok "updated $LAYOUT"
jq . "$LAYOUT"

if [[ $CAN_REBUILD == 1 ]]; then
    hdr "nixos-rebuild boot --install-bootloader"
    # --install-bootloader forces grub-install to run, which is what actually
    # writes the bootloader onto the new disk.
    nixos-rebuild boot --install-bootloader
    ok "bootloader installed on every mirror member"
else
    warn "now run on the target system:  nixos-rebuild boot --install-bootloader"
fi

hdr "Resilver"
zpool status "$ROOT_POOL"
say ""
info "The pool is redundant again once the resilver finishes. Watch it with:"
info "  watch -n5 zpool status $ROOT_POOL"
info ""
info "Then confirm everything agrees:"
info "  systemctl start zfs-health-check && systemctl status zfs-health-check"
