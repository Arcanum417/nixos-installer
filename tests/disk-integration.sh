#!/usr/bin/env bash
# Exercises the real partitioning / mirror code against loop devices.
#
# Needs root, losetup, sgdisk, mkfs.vfat, mkfs.ext4, partx.
# The ZFS section additionally needs a working zfs kernel module and is
# skipped (not failed) when the module is unavailable.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
set +e; trap - ERR
# shellcheck source=assert.sh
source "$HERE/assert.sh"

[[ $EUID -eq 0 ]] || { echo "disk-integration.sh must run as root"; exit 77; }
for c in losetup sgdisk mkfs.vfat mkfs.ext4 partx blockdev; do
    command -v "$c" >/dev/null || { echo "missing $c"; exit 77; }
done

DISK_MB=${DISK_MB:-8192}
WORK=$(mktemp -d)
BYID="$WORK/by-id"; mkdir -p "$BYID"
LOOPS=()

cleanup () {
    zpool destroy -f ziltest 2>/dev/null
    local l
    for l in ${LOOPS[@]+"${LOOPS[@]}"}; do losetup -d "$l" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- fake udev: keep $BYID/<name>[-partN] pointing at the loop devices ------
refresh_links () {
    local n=0 l base p
    for l in ${LOOPS[@]+"${LOOPS[@]}"}; do
        base="$BYID/test-disk$n"
        ln -sfn "$l" "$base"
        rm -f "$base"-part*
        partx -u "$l" >/dev/null 2>&1
        for p in "$l"p*; do
            [[ -b $p ]] || continue
            ln -sfn "$p" "$base-part${p##*p}"
        done
        n=$((n+1))
    done
}
settle () { refresh_links; }        # override: no udev in this environment

make_disk () { # make_disk index size_mb
    local f="$WORK/disk$1.img" l
    truncate -s "${2}M" "$f"
    l=$(losetup --show -f -P "$f") || return 1
    echo "$l"
}

section "loop device setup"
for i in 0 1 2; do
    l=$(make_disk "$i" "$DISK_MB") || { echo "losetup failed"; exit 77; }
    LOOPS+=("$l")
done
refresh_links
eq "three loop devices" "${#LOOPS[@]}" "3"
D0="$BYID/test-disk0"; D1="$BYID/test-disk1"; D2="$BYID/test-disk2"
if [[ -b $D0 ]]; then _pass "by-id symlink resolves to a block device"
else _fail "by-id symlink resolves to a block device" "$D0 is not a block device"; fi

section "check_identical_disks"
expect_ok   "three identical disks pass" check_identical_disks "$D0" "$D1" "$D2"
LSMALL=$(make_disk 9 $((DISK_MB - 512))); LOOPS+=("$LSMALL"); refresh_links
DSMALL="$BYID/test-disk3"
expect_fail "a smaller disk is rejected by default" check_identical_disks "$D0" "$DSMALL"
expect_ok   "ALLOW_MIXED_SIZE=1 overrides" env ALLOW_MIXED_SIZE=1 bash -c \
    "source '$ROOT/lib/common.sh'; check_identical_disks '$D0' '$DSMALL'"

section "wait_for_nodes"
expect_ok   "returns for nodes that exist" wait_for_nodes "$D0"
expect_fail "times out for a node that never appears" \
    env WAIT_FOR_NODES_TRIES=2 bash -c \
    "source '$ROOT/lib/common.sh'; settle(){ :; }; wait_for_nodes '$BYID/nope-part1'"

# ---------------------------------------------------------------------------
partition_all () { # partition_all uefi|bios
    local mode=$1 d
    set_part_numbers "$mode"
    for d in "$D0" "$D1" "$D2"; do nuke_disk "$d"; done
    ZFS_END=$(compute_zfs_end "$D0" "$D1" "$D2")
    for d in "$D0" "$D1" "$D2"; do partition_boot_disk "$mode" "$d" "$ZFS_END"; done
    refresh_links
    wait_for_nodes "$(part_path "$D0" "$BOOTPART")" "$(part_path "$D0" "$ZFSPART")" \
                   "$(part_path "$D1" "$BOOTPART")" "$(part_path "$D1" "$ZFSPART")" \
                   "$(part_path "$D2" "$BOOTPART")" "$(part_path "$D2" "$ZFSPART")"
}
pcode ()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-F-]*\).*/\1/p'; }
pguid ()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^Partition unique GUID: //p'; }
plast ()  { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^Last sector: \([0-9]*\).*/\1/p'; }
pfirst () { sgdisk -i "$2" "$1" 2>/dev/null | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
dguid ()  { sgdisk -p "$1" 2>/dev/null | sed -n 's/^Disk identifier (GUID): //p'; }

ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
ZFS_GUID=6A898CC3-1DD2-11B2-99A6-080020736631
BIOSBOOT_GUID=21686148-6449-6E6F-744E-656564454649
LINUX_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4

section "UEFI partitioning"
partition_all uefi
eq "esp type is EF00"        "$(pcode "$D0" 1)" "$ESP_GUID"
eq "zfs type is BF01"        "$(pcode "$D0" 2)" "$ZFS_GUID"
eq "no third partition"      "$(pcode "$D0" 3)" ""
esp_bytes=$(blockdev --getsize64 "$(part_path "$D0" 1)")
eq "esp is 2 GiB"            "$esp_bytes" "$((2*1024*1024*1024))"

z0=$(blockdev --getsize64 "$(part_path "$D0" 2)")
z1=$(blockdev --getsize64 "$(part_path "$D1" 2)")
z2=$(blockdev --getsize64 "$(part_path "$D2" 2)")
eq "zfs partitions identical (0 vs 1)" "$z0" "$z1"
eq "zfs partitions identical (0 vs 2)" "$z0" "$z2"

total=$(blockdev --getsize64 "$D0")
slack=$(( total - ( $(plast "$D0" 2) + 1 ) * 512 ))
between "1 GiB of end slack for a smaller replacement disk" \
        "$slack" "$((1024*1024*1024))" "$((1024*1024*1024 + 1024*1024))"

section "GPT identities must be unique (regression: sfdisk --dump | sfdisk)"
ne "disk GUIDs differ (0/1)" "$(dguid "$D0")" "$(dguid "$D1")"
ne "disk GUIDs differ (0/2)" "$(dguid "$D0")" "$(dguid "$D2")"
ne "disk GUIDs differ (1/2)" "$(dguid "$D1")" "$(dguid "$D2")"
ne "esp GUIDs differ"        "$(pguid "$D0" 1)" "$(pguid "$D1" 1)"
ne "zfs part GUIDs differ"   "$(pguid "$D0" 2)" "$(pguid "$D1" 2)"

section "ESP must be FAT32, not FAT16"
mkfs_boot uefi "$(part_path "$D0" 1)" 0
fstype=$(dd if="$(part_path "$D0" 1)" bs=1 skip=82 count=8 2>/dev/null)
eq "boot sector declares FAT32" "$fstype" "FAT32   "
label=$(dd if="$(part_path "$D0" 1)" bs=1 skip=71 count=11 2>/dev/null)
eq "volume label"               "$label"  "ESP0       "
mkfs_boot uefi "$(part_path "$D1" 1)" 1
l1=$(dd if="$(part_path "$D1" 1)" bs=1 skip=71 count=11 2>/dev/null)
ne "labels are distinct per disk" "$label" "$l1"

section "BIOS partitioning"
partition_all bios
eq "p1 is BIOS boot"      "$(pcode "$D0" 1)" "$BIOSBOOT_GUID"
eq "p2 is linux /boot"    "$(pcode "$D0" 2)" "$LINUX_GUID"
eq "p3 is zfs"            "$(pcode "$D0" 3)" "$ZFS_GUID"
eq "bios boot is 2 MiB"   "$(blockdev --getsize64 "$(part_path "$D0" 1)")" "$((2*1024*1024))"
eq "/boot is 2 GiB"       "$(blockdev --getsize64 "$(part_path "$D0" 2)")" "$((2*1024*1024*1024))"
bz0=$(blockdev --getsize64 "$(part_path "$D0" 3)")
bz1=$(blockdev --getsize64 "$(part_path "$D1" 3)")
eq "bios zfs partitions identical" "$bz0" "$bz1"
bslack=$(( total - ( $(plast "$D0" 3) + 1 ) * 512 ))
between "bios end slack" "$bslack" "$((1024*1024*1024))" "$((1024*1024*1024 + 1024*1024))"
expect_ok "mkfs.ext4 on the bios /boot" mkfs_boot bios "$(part_path "$D0" 2)" 0

section "replacement disk: --replicate then --randomize-guids"
partition_all uefi
NEWL=$(make_disk 8 "$DISK_MB"); LOOPS+=("$NEWL"); refresh_links
NEW="$BYID/test-disk4"
nuke_disk "$NEW"
sgdisk --replicate="$NEW" "$D0" >/dev/null
sgdisk --randomize-guids "$NEW" >/dev/null
refresh_links
eq "layout copied: first sector"  "$(pfirst "$NEW" 2)" "$(pfirst "$D0" 2)"
eq "layout copied: last sector"   "$(plast  "$NEW" 2)" "$(plast  "$D0" 2)"
eq "layout copied: type code"     "$(pcode  "$NEW" 2)" "$(pcode  "$D0" 2)"
eq "replacement zfs part is the same size" \
   "$(blockdev --getsize64 "$(part_path "$NEW" 2)")" \
   "$(blockdev --getsize64 "$(part_path "$D0" 2)")"
ne "but the disk GUID is fresh"        "$(dguid "$NEW")"   "$(dguid "$D0")"
ne "and the esp partition GUID"        "$(pguid "$NEW" 1)" "$(pguid "$D0" 1)"
ne "and the zfs partition GUID"        "$(pguid "$NEW" 2)" "$(pguid "$D0" 2)"

# The whole point of END_RESERVE_BYTES: a replacement disk that is smaller than
# the original still has room for the original's partition table, because that
# table stops 1 GiB short of the end. replace-boot-disk.sh clones the healthy
# member's layout with `sgdisk --replicate`, so if the slack were not there the
# replicated table would run off the end of the smaller disk and the ZFS
# partition would come back short -- which ZFS then refuses to resilver onto.
#
# DSMALL is 512 MiB smaller than the others, i.e. inside the slack.
section "replacement disk that is smaller than the original"
nuke_disk "$DSMALL"
expect_ok "replicate the healthy layout onto a smaller disk" \
    sgdisk --replicate="$DSMALL" "$D0"
sgdisk --randomize-guids "$DSMALL" >/dev/null
refresh_links
expect_ok "the replicated table is valid on the smaller disk" \
    sgdisk --verify "$DSMALL"
eq "its zfs partition is still the full size" \
   "$(blockdev --getsize64 "$(part_path "$DSMALL" 2)")" \
   "$(blockdev --getsize64 "$(part_path "$D0" 2)")"
eq "and ends on the same sector as the original" \
   "$(plast "$DSMALL" 2)" "$(plast "$D0" 2)"

# ---------------------------------------------------------------------------
section "ZFS mirror"
if ! command -v zpool >/dev/null || ! grep -qw zfs /proc/filesystems 2>/dev/null; then
    skip "mirror create / degrade / replace" "no zfs kernel module here; runs in CI"
    summary "disk-integration"; exit $?
fi

POOL=ziltest
zpool destroy -f "$POOL" 2>/dev/null
expect_ok "create a 3-way mirror" zpool create -f -o ashift=12 -O mountpoint=none "$POOL" \
    mirror "$(part_path "$D0" 2)" "$(part_path "$D1" 2)" "$(part_path "$D2" 2)"
st=$(zpool status "$POOL")
contains "is a mirror"          "$st" "mirror-0"
eq       "three ONLINE members" "$(zpool status "$POOL" | grep -c 'test-disk[0-9]*-part2 *ONLINE')" "3"
eq       "pool is healthy"      "$(zpool status -x "$POOL")" "pool '$POOL' is healthy"

section "ZFS: survive a disk failure"
zpool offline -f "$POOL" "$(part_path "$D2" 2)" 2>/dev/null || zpool offline "$POOL" "$(part_path "$D2" 2)"
sleep 1
contains "pool reports DEGRADED" "$(zpool status "$POOL")" "DEGRADED"
ne       "zpool status -x notices" "$(zpool status -x "$POOL")" "pool '$POOL' is healthy"
expect_ok "pool still usable while degraded" zfs create -o mountpoint=none "$POOL/probe"

section "ZFS: replace the failed member"
expect_ok "zpool replace onto the new disk" \
    zpool replace -f "$POOL" "$(part_path "$D2" 2)" "$(part_path "$NEW" 2)"
for _ in $(seq 1 60); do
    zpool status "$POOL" | grep -q 'scan:.*resilvered\|state: ONLINE' && break
    sleep 1
done
sleep 2
contains "back to ONLINE"    "$(zpool status "$POOL")" "ONLINE"
eq       "healthy again"     "$(zpool status -x "$POOL")" "pool '$POOL' is healthy"
contains "new disk is a member" "$(zpool status -P "$POOL")" "test-disk4-part2"

# The slack, proved at the ZFS layer rather than only in the partition table.
# A replacement 512 MiB smaller than the original carries the replicated
# layout, so its ZFS partition is the same size and the pool accepts it. This
# is the case END_RESERVE_BYTES exists for, and it is the one that strands a
# recovery at 3am when it does not hold.
section "ZFS: resilver onto a disk smaller than the original"
zpool offline -f "$POOL" "$(part_path "$D1" 2)" 2>/dev/null ||     zpool offline "$POOL" "$(part_path "$D1" 2)"
sleep 1
expect_ok "zpool replace onto the smaller disk" \
    zpool replace -f "$POOL" "$(part_path "$D1" 2)" "$(part_path "$DSMALL" 2)"
for _ in $(seq 1 60); do
    zpool status "$POOL" | grep -q 'resilvered' && break
    sleep 1
done
sleep 2
eq       "healthy after resilvering onto it" \
         "$(zpool status -x "$POOL")" "pool '$POOL' is healthy"
contains "the smaller disk is a member" \
         "$(zpool status -P "$POOL")" "test-disk3-part2"

zpool destroy -f "$POOL"

summary "disk-integration"
