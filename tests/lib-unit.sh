#!/usr/bin/env bash
# Unit tests for lib/common.sh. No root, no disks, no network.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
set +e; trap - ERR          # tests drive failure paths deliberately
# shellcheck source=assert.sh
source "$HERE/assert.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

section "hr_size"
eq "bytes"  "$(hr_size 512)"            "512B"
eq "1 GiB"  "$(hr_size 1073741824)"     "1.0GiB"
eq "1 MiB"  "$(hr_size 1048576)"        "1.0MiB"
eq "2 TB disk reads as TiB" "$(hr_size 2000398934016)" "1.8TiB"
eq "zero"   "$(hr_size 0)"              "0B"

section "boot mount points"
eq "first disk is /boot"    "$(boot_mount_point 0)" "/boot"
eq "second"                 "$(boot_mount_point 1)" "/boot-fallback-1"
eq "third"                  "$(boot_mount_point 2)" "/boot-fallback-2"
BOOT_MPS=(/boot /boot-fallback-1);  eq "next after 2"      "$(next_free_mount_point)" "/boot-fallback-2"
BOOT_MPS=(/boot /boot-fallback-2);  eq "reuses the gap"    "$(next_free_mount_point)" "/boot-fallback-1"
BOOT_MPS=(/boot-fallback-1);        eq "reclaims /boot"    "$(next_free_mount_point)" "/boot"
BOOT_MPS=();                        eq "empty -> /boot"    "$(next_free_mount_point)" "/boot"

section "partition numbering"
set_part_numbers uefi; eq "uefi boot part" "$BOOTPART" "1"; eq "uefi zfs part" "$ZFSPART" "2"
set_part_numbers bios; eq "bios boot part" "$BOOTPART" "2"; eq "bios zfs part" "$ZFSPART" "3"
eq "part_path" "$(part_path /dev/disk/by-id/ata-X 3)" "/dev/disk/by-id/ata-X-part3"

section "nix_attr (reading unique.nix without evaluating it)"
cat > u.nix <<'X'
{ config, pkgs, ... }:
{
  networking.hostName = "sm2-box"; # Define your hostname.
  networking.hostId   =    "37f2fb23";
  # networking.hostId = "deadbeef";
  time.timeZone = "Europe/Bratislava";
}
X
eq "hostName"                "$(nix_attr u.nix networking.hostName)" "sm2-box"
eq "hostId with odd spacing" "$(nix_attr u.nix networking.hostId)"   "37f2fb23"
eq "unrelated attr"          "$(nix_attr u.nix time.timeZone)"       "Europe/Bratislava"
eq "absent attr is empty"    "$(nix_attr u.nix networking.nope)"     ""
printf '{\n  # networking.hostId = "aaaaaaaa";\n  networking.hostId = "bbbbbbbb";\n}\n' > u2.nix
eq "commented-out line loses to the real one" "$(nix_attr u2.nix networking.hostId)" "bbbbbbbb"

section "set_hostid validation"
expect_fail "rejects non-hex"      set_hostid "ZmenMa"
expect_fail "rejects short"        set_hostid "37f2fb2"
expect_fail "rejects long"         set_hostid "37f2fb234"
expect_fail "rejects empty"        set_hostid ""
# byte order: /etc/hostid is a 32-bit int in host order (little-endian on x86)
hostid_bytes () { printf '%b' "\\x${1:6:2}\\x${1:4:2}\\x${1:2:2}\\x${1:0:2}"; }
eq "37f2fb23 -> LE"  "$(hostid_bytes 37f2fb23 | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')" "23 fb f2 37"
eq "embedded NUL"    "$(hostid_bytes 00ff0100 | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')" "00 01 ff 00"
eq "always 4 bytes"  "$(hostid_bytes 0a0b0c0d | wc -c)" "4"

section "by_id_path prefers a human-identifiable name"
mkdir -p fakebin
cat > fakebin/udevadm <<'X'
#!/usr/bin/env bash
case "$*" in
  *--name=/dev/nvme0n1*) echo "disk/by-id/nvme-eui.0025385891b1c1d2 disk/by-id/nvme-Samsung_SSD_980_S64ANL0T1 disk/by-id/wwn-0x1234" ;;
  *--name=/dev/sda*)     echo "disk/by-id/wwn-0x5000c500 disk/by-id/ata-INTEL_SSDSC_BTLA746 disk/by-path/pci-0000:00" ;;
  *--name=/dev/vda*)     echo "disk/by-id/virtio-abc123" ;;
  *--name=/dev/dm-0*)    echo "disk/by-id/dm-name-vg0 disk/by-id/dm-uuid-LVM-xyz" ;;
  *--name=/dev/nvme9n1*) echo "disk/by-id/nvme-eui.aaaa disk/by-id/wwn-0xbbbb" ;;
  *)                     echo "" ;;
esac
X
chmod +x fakebin/udevadm; PATH="$PWD/fakebin:$PATH"
eq "nvme model_serial beats eui and wwn" "$(by_id_path /dev/nvme0n1)" "/dev/disk/by-id/nvme-Samsung_SSD_980_S64ANL0T1"
eq "ata beats wwn"                       "$(by_id_path /dev/sda)"     "/dev/disk/by-id/ata-INTEL_SSDSC_BTLA746"
eq "virtio is accepted"                  "$(by_id_path /dev/vda)"     "/dev/disk/by-id/virtio-abc123"
eq "dm-* is never a whole disk"          "$(by_id_path /dev/dm-0)"    ""
eq "falls back to eui when nothing better" "$(by_id_path /dev/nvme9n1)" "/dev/disk/by-id/nvme-eui.aaaa"
eq "no by-id at all"                     "$(by_id_path /dev/sdz)"     ""

section "disk-layout.json round trip"
BOOT_MODE=uefi; ROOT_POOL=zroot; STATE_VERSION=25.05; set_part_numbers uefi
BOOT_DISKS=(/dev/disk/by-id/ata-A /dev/disk/by-id/ata-B /dev/disk/by-id/nvme-C)
BOOT_MPS=(/boot /boot-fallback-1 /boot-fallback-2)
DATA_POOL_JSON='{"name":"zdata","keyFile":"/root/.zfs-encrypt.key","datasets":[{"dataset":"zdata/docker","mountPoint":"/mnt/docker"}]}'
write_disk_layout_json dl.json
expect_ok "emits valid json"  jq -e . dl.json
eq "schema version"  "$(jq -r .version dl.json)"                  "1"
eq "three disks"     "$(jq -r '.bootDisks|length' dl.json)"       "3"
eq "part numbers are numbers, not strings" "$(jq -r '.bootDisks[0].zfsPart|type' dl.json)" "number"
eq "third mount point" "$(jq -r '.bootDisks[2].mountPoint' dl.json)" "/boot-fallback-2"
eq "data dataset"    "$(jq -r '.dataPool.datasets[0].dataset' dl.json)" "zdata/docker"

unset BOOT_MODE ROOT_POOL STATE_VERSION BOOT_DISKS BOOT_MPS DATA_POOL_JSON BOOTPART ZFSPART
read_disk_layout dl.json
eq "rt bootMode"     "$BOOT_MODE"        "uefi"
eq "rt rootPool"     "$ROOT_POOL"        "zroot"
eq "rt stateVersion" "$STATE_VERSION"    "25.05"
eq "rt disk count"   "${#BOOT_DISKS[@]}" "3"
eq "rt disk 3"       "${BOOT_DISKS[2]}"  "/dev/disk/by-id/nvme-C"
eq "rt mount 2"      "${BOOT_MPS[1]}"    "/boot-fallback-1"
eq "rt bootPart"     "$BOOTPART"         "1"
eq "rt zfsPart"      "$ZFSPART"          "2"
eq "rt dataPool preserved" "$(jq -r .name <<<"$DATA_POOL_JSON")" "zdata"
expect_fail "read_disk_layout on a missing file" read_disk_layout /nonexistent/dl.json

section "--drop must not renumber the survivors"
drop=1
unset "BOOT_DISKS[$drop]" "BOOT_MPS[$drop]"
BOOT_DISKS=("${BOOT_DISKS[@]}"); BOOT_MPS=("${BOOT_MPS[@]}")
write_disk_layout_json dropped.json
eq "two remain"                 "$(jq -r '.bootDisks|length' dropped.json)" "2"
eq "survivor keeps its id"      "$(jq -r '.bootDisks[1].id' dropped.json)" "/dev/disk/by-id/nvme-C"
eq "survivor keeps its mount"   "$(jq -r '.bootDisks[1].mountPoint' dropped.json)" "/boot-fallback-2"
eq "first disk untouched"       "$(jq -r '.bootDisks[0].mountPoint' dropped.json)" "/boot"

section "bios layout, no data pool"
BOOT_MODE=bios; set_part_numbers bios; DATA_POOL_JSON=null
write_disk_layout_json bios.json
eq "dataPool is json null" "$(jq -r '.dataPool' bios.json)"          "null"
eq "bios zfs part is 3"    "$(jq -r '.bootDisks[0].zfsPart' bios.json)" "3"
eq "bios boot part is 2"   "$(jq -r '.bootDisks[0].bootPart' bios.json)" "2"

section "select_disks"
live_medium_disks () { echo "sdz"; }          # stub: pretend we booted off sdz
DISK_KNAME=(sda sdb sdc sdz sdn)
DISK_BYID=(/dev/disk/by-id/ata-A /dev/disk/by-id/ata-B /dev/disk/by-id/ata-C /dev/disk/by-id/usb-LIVE "")
DISK_SIZE=(100 100 100 100 100)
DISK_LABEL=("sda" "sdb" "sdc" "sdz [LIVE MEDIUM]" "sdn [no by-id]")

# NB: feed stdin by redirection, not a pipe - a pipeline would run
# select_disks in a subshell and the SELECTED array would never come back.
pick () { printf '%s\n' "$@" > "$WORK/in"; SELECTED=(); }

pick 1 2 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "picks two"        "${#SELECTED[@]}" "2"
eq "first pick"       "${SELECTED[0]-}" "/dev/disk/by-id/ata-A"
eq "second pick"      "${SELECTED[1]-}" "/dev/disk/by-id/ata-B"

pick 1 2 3 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "supports a 3-way mirror" "${#SELECTED[@]}" "3"

# 'd' before the minimum is reached must not be accepted
pick d 1 2 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "minimum of 2 enforced" "${#SELECTED[@]}" "2"

# numbering is stable: entry 2 is always sdb no matter what was picked before
pick 1 2 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "entry 2 is still sdb after picking entry 1" "${SELECTED[1]-}" "/dev/disk/by-id/ata-B"

# picking the same number twice toggles it off rather than adding a duplicate
pick 1 1 2 3 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "re-picking deselects" "${#SELECTED[@]}" "2"
eq "left with B"  "${SELECTED[0]-}" "/dev/disk/by-id/ata-B"
eq "and C"        "${SELECTED[1]-}" "/dev/disk/by-id/ata-C"

# only sda/sdb/sdc are offered: sdz is the live medium and sdn has no by-id,
# so menu entry 4 does not exist and is rejected as invalid input
pick 4 1 2 d; select_disks 2 "root mirror" < "$WORK/in" >/dev/null
eq "live medium and no-by-id disks are not offered" "${#SELECTED[@]}" "2"
for s in "${SELECTED[@]}"; do
  ne "never selects the live medium" "$s" "/dev/disk/by-id/usb-LIVE"
done

pick 1 2 d; select_disks 1 "data pool" /dev/disk/by-id/ata-A < "$WORK/in" >/dev/null
ne "explicitly excluded disk is not offered" "${SELECTED[0]-}" "/dev/disk/by-id/ata-A"

# too few usable disks for the requested minimum must abort, not silently pass
DISK_KNAME=(sda); DISK_BYID=(/dev/disk/by-id/ata-A); DISK_SIZE=(100); DISK_LABEL=("sda")
pick d
too_few () { select_disks 2 "root mirror" < "$WORK/in" >/dev/null; }
expect_fail "aborts when fewer than 2 usable disks exist" too_few

summary "lib-unit"
