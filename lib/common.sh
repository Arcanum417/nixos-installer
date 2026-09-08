# shellcheck shell=bash
# Shared helpers for install-me.sh, replace-boot-disk.sh, add-data-pool.sh.
# Sourced, not executed.

set -Eeuo pipefail

# ---------------------------------------------------------------- output ----

C_RESET="\033[0m"; C_BLUE="\033[44m"; C_RED="\033[41m"; C_YEL="\033[33m"
C_GRN="\033[32m"; C_BOLD="\033[1m"

say ()  { echo -e "${C_BOLD}$*${C_RESET}"; }
info () { echo -e "  $*"; }
warn () { echo -e "${C_YEL}  ! $*${C_RESET}" >&2; }
ok ()   { echo -e "${C_GRN}  ok ${C_RESET}$*"; }
hdr ()  { echo; echo -e "${C_BLUE} > $* ${C_RESET}"; }
die ()  { echo; echo -e "${C_RED} FATAL ${C_RESET} $*" >&2; exit 1; }

trap 'echo -e "\n${C_RED} FATAL ${C_RESET} ${BASH_SOURCE[0]}:${LINENO}: \"${BASH_COMMAND}\" failed (exit $?)" >&2' ERR

# Yes/no. Default is yes; anything starting with n/N aborts.
confirm () {
    hdr "$1  [Y/n]"
    local reply=""
    read -r -n 1 reply || true
    echo
    [[ ! $reply =~ ^[Nn]$ ]]
}

# Destructive confirmation: must type the literal word.
confirm_hard () {
    hdr "$1"
    echo -e "  Type ${C_BOLD}$2${C_RESET} to continue, anything else aborts."
    local reply=""
    read -r reply || true
    [[ $reply == "$2" ]] || die "aborted by operator"
}

ask () { # ask VAR "prompt" "default"
    local __var=$1 __prompt=$2 __default=${3-} __reply=""
    if [[ -n $__default ]]; then
        read -r -p "  $__prompt [$__default]: " __reply || true
        __reply=${__reply:-$__default}
    else
        read -r -p "  $__prompt: " __reply || true
    fi
    printf -v "$__var" '%s' "$__reply"
}

need_root () { [[ $EUID -eq 0 ]] || die "run as root"; }

need_cmds () {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [[ ${#missing[@]} -eq 0 ]] || die "missing commands: ${missing[*]}"
}

# ------------------------------------------------------------ boot mode ----

detect_boot_mode () {
    if [[ -d /sys/firmware/efi/efivars ]]; then echo uefi; else echo bios; fi
}

# --------------------------------------------------------------- hostid ----

# The pool's labels are stamped with the hostid of whoever imported it. If the
# installer's hostid does not match what the installed system will use, the
# first boot cannot import the root pool (boot.zfs.forceImportRoot = false).
# Setting it here also lets us import a dirty pool from a crashed machine
# without -f, because we look like the same host.
set_hostid () {
    local id=$1
    [[ $id =~ ^[0-9a-fA-F]{8}$ ]] || die "hostId must be exactly 8 hex digits, got '$id'"
    id=${id,,}
    # On a NixOS live ISO /etc/hostid already exists as a symlink into
    # /etc/static, which lives in the read-only /nix/store. Writing *through*
    # that symlink fails with "fopen: Read-only file system" and takes the
    # installer down at its first step. /etc itself is a tmpfs and is
    # writable, so drop the symlink and let a real file be created in its
    # place. (Found by tests/vm-boot.sh; nothing short of a real ISO boot
    # reproduces it.)
    rm -f /etc/hostid
    if command -v zgenhostid >/dev/null 2>&1; then
        zgenhostid -f "$id"
    else
        # /etc/hostid is a 4-byte integer in host byte order (little-endian here).
        printf '%b' "\\x${id:6:2}\\x${id:4:2}\\x${id:2:2}\\x${id:0:2}" > /etc/hostid
    fi
    local got; got=$(hostid)
    [[ ${got,,} == "$id" ]] || die "failed to set hostid: wanted $id, hostid(1) reports $got"
    ok "hostid set to $id"
}

# Pull a value out of unique.nix without evaluating it.
nix_attr () { # nix_attr FILE ATTR
    sed -n "s@^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*@\1@p" "$1" | head -n1
}

# ---------------------------------------------------------------- disks ----

# Disks backing the live medium, so we never offer to wipe the USB stick we
# booted from.
live_medium_disks () {
    local mp src
    for mp in / /iso /nix/.ro-store /run/initramfs/live; do
        [[ -e $mp ]] || continue
        src=$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null | head -n1) || true
        [[ ${src-} == /dev/* ]] || continue
        src=${src%%\[*}
        lsblk -ndo PKNAME "$src" 2>/dev/null || true
        lsblk -ndo KNAME  "$src" 2>/dev/null || true
    done | sed '/^$/d' | sort -u
}

# Stable /dev/disk/by-id path for a whole disk, asked of udev rather than
# reconstructed from lsblk columns. Prefers human-identifiable names
# (model_serial) over opaque ones (wwn, eui) so `zpool status` names the disk
# you have to physically pull.
# Do two by-id paths name the same physical disk?
#
# String equality is not enough, and this is not hypothetical: an NVMe disk has
# both nvme-MODEL_SERIAL and the namespace-scoped nvme-MODEL_SERIAL_1 pointing
# at the same device. A layout recorded under one name and a scan that returned
# the other compared unequal, so a disk already in the mirror was offered as a
# candidate for a fresh one. Resolve both and compare the devices.
#
# Falls back to string equality when a path cannot be resolved -- during an
# install the layout may name a disk that is currently absent, and "absent" must
# not silently read as "some other disk".
same_disk () { # same_disk PATH_A PATH_B
    local a b
    a=$(readlink -f "$1" 2>/dev/null || true)
    b=$(readlink -f "$2" 2>/dev/null || true)
    if [[ -n $a && -n $b && -e $a && -e $b ]]; then
        [[ $a == "$b" ]]
    else
        [[ $1 == "$2" ]]
    fi
}

by_id_path () { # by_id_path /dev/sda
    local dev=$1 link best="" rank=99 r
    while read -r link; do
        [[ $link == disk/by-id/* ]] || continue
        case ${link#disk/by-id/} in
            nvme-eui.*|wwn-*)         r=8 ;;
            nvme-nvme.*)              r=7 ;;
            md-*|dm-*|lvm-*)          continue ;;
            nvme-*)                   r=1 ;;
            ata-*)                    r=2 ;;
            scsi-SATA_*|scsi-SAS*)    r=3 ;;
            usb-*)                    r=4 ;;
            virtio-*)                 r=5 ;;
            scsi-*)                   r=6 ;;
            *)                        r=7 ;;
        esac
        if (( r < rank )); then
            rank=$r; best=$link
        elif (( r == rank )) && [[ -n $best ]]; then
            # Deterministic tie-break, and not a theoretical one. udevadm does
            # not promise a symlink order, and an NVMe disk really does have
            # two by-id links of equal rank: nvme-MODEL_SERIAL and the
            # namespace-scoped nvme-MODEL_SERIAL_1, both pointing at the same
            # device. Taking whichever happened to arrive first meant the same
            # disk could be recorded under one name at install time and
            # rediscovered under the other later -- which is how a live mirror
            # member ended up offered as a replacement candidate.
            #
            # Shortest, then lexicographic: stable across runs, and it prefers
            # the device-level link over the namespace-scoped one.
            if (( ${#link} < ${#best} )) \
               || { (( ${#link} == ${#best} )) && [[ $link < $best ]]; }; then
                best=$link
            fi
        fi
    done < <(udevadm info --query=symlink --name="$dev" 2>/dev/null | tr ' ' '\n')
    [[ -n $best ]] || return 1
    echo "/dev/$best"
}

# Populates DISK_KNAME / DISK_BYID / DISK_SIZE / DISK_LABEL parallel arrays.
scan_disks () {
    DISK_KNAME=(); DISK_BYID=(); DISK_SIZE=(); DISK_LABEL=()
    local live; live=$(live_medium_disks)
    local kname size model serial byid tag
    while read -r kname; do
        [[ -n $kname ]] || continue
        size=$(blockdev --getsize64 "/dev/$kname" 2>/dev/null) || continue
        model=$(lsblk -dn -o MODEL  "/dev/$kname" 2>/dev/null | sed 's/[[:space:]]*$//')
        serial=$(lsblk -dn -o SERIAL "/dev/$kname" 2>/dev/null | sed 's/[[:space:]]*$//')
        byid=$(by_id_path "/dev/$kname" 2>/dev/null) || byid=""
        tag=""
        grep -qx "$kname" <<<"$live" && tag=" [LIVE MEDIUM]"
        [[ -n $byid ]] || tag+=" [no stable by-id - UNUSABLE]"
        DISK_KNAME+=("$kname")
        DISK_BYID+=("$byid")
        DISK_SIZE+=("$size")
        DISK_LABEL+=("$(printf '%-10s %9s  %-26s %-20s%s' \
            "$kname" "$(hr_size "$size")" "${model:-?}" "${serial:-?}" "$tag")")
    done < <(lsblk -dn -o KNAME --nodeps -e 1,7,11 2>/dev/null)
    [[ ${#DISK_KNAME[@]} -gt 0 ]] || die "no disks found"
}

hr_size () { # bytes -> human
    local b=$1
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB PiB",u," "); i=1
        while (b>=1024 && i<6) { b/=1024; i++ }
        printf (i==1 ? "%d%s" : "%.1f%s"), b, u[i]
    }'
}

# select_disks MIN "purpose" [excluded by-id ...]  -> sets SELECTED[]
#
# The candidate list is built once and the numbering never changes, even as
# disks are selected. An earlier version re-rendered the menu with the chosen
# disks removed, so the numbers shifted between picks - in a script that runs
# `sgdisk --zap-all` on what you chose, that is how you erase the wrong disk.
# A number toggles; already-selected disks are marked with *.
select_disks () {
    local min=$1 purpose=$2; shift 2
    local -a excluded=("$@")
    SELECTED=()
    local live; live=$(live_medium_disks)

    local -a cand=()
    local i s skip
    for i in "${!DISK_KNAME[@]}"; do
        [[ -n ${DISK_BYID[$i]} ]] || continue           # no stable by-id: unusable
        skip=""
        grep -qx "${DISK_KNAME[$i]}" <<<"$live" && skip=1
        for s in ${excluded[@]+"${excluded[@]}"}; do
            same_disk "$s" "${DISK_BYID[$i]}" && skip=1
        done
        [[ -z $skip ]] || continue
        cand+=("$i")
    done
    [[ ${#cand[@]} -ge $min ]] \
        || die "only ${#cand[@]} usable disk(s) available for $purpose, need at least $min"

    local n reply mark found
    local -a keep=()
    while :; do
        echo
        say "Disks available for $purpose  (selected ${#SELECTED[@]}, minimum $min)"
        for n in "${!cand[@]}"; do
            i=${cand[$n]}; mark=" "
            for s in ${SELECTED[@]+"${SELECTED[@]}"}; do
                same_disk "$s" "${DISK_BYID[$i]}" && mark="*"
            done
            printf "   %s %2d) %s\n" "$mark" "$((n+1))" "${DISK_LABEL[$i]}"
        done
        [[ ${#SELECTED[@]} -ge $min ]] \
            && printf "        d) done - use the %d disk(s) marked *\n" "${#SELECTED[@]}"

        reply=""
        read -r -p "  number toggles, d when done: " reply || true

        if [[ $reply == [dD] ]] && [[ ${#SELECTED[@]} -ge $min ]]; then break; fi
        if [[ $reply =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#cand[@]} )); then
            i=${cand[$((reply-1))]}
            keep=(); found=""
            for s in ${SELECTED[@]+"${SELECTED[@]}"}; do
                if same_disk "$s" "${DISK_BYID[$i]}"; then found=1; else keep+=("$s"); fi
            done
            if [[ -n $found ]]; then
                SELECTED=(${keep[@]+"${keep[@]}"})
                info "removed ${DISK_KNAME[$i]}"
            else
                SELECTED+=("${DISK_BYID[$i]}")
                ok "added ${DISK_KNAME[$i]}  ->  ${DISK_BYID[$i]}"
            fi
        else
            warn "invalid selection"
        fi
    done
    [[ ${#SELECTED[@]} -ge $min ]] || die "need at least $min disk(s) for $purpose"
}

disk_bytes () { blockdev --getsize64 "$1"; }
disk_lss ()   { blockdev --getss "$1"; }

# The installer's core promise is a mirror you can actually rebuild, so the
# members have to be interchangeable. Same size is the default requirement;
# ALLOW_MIXED_SIZE=1 downgrades it to "partition everything to the smallest".
check_identical_disks () { # check_identical_disks by-id...
    local -a devs=("$@") sizes=() lss=()
    local d i
    for d in "${devs[@]}"; do
        [[ -b $d ]] || die "not a block device: $d"
        sizes+=("$(disk_bytes "$d")")
        lss+=("$(disk_lss "$d")")
    done
    for i in "${!lss[@]}"; do
        [[ ${lss[$i]} == "${lss[0]}" ]] || \
            die "logical sector size mismatch (${lss[0]} vs ${lss[$i]}); refusing to mirror 512e and 4Kn disks"
    done
    local mismatch=0
    for i in "${!sizes[@]}"; do [[ ${sizes[$i]} == "${sizes[0]}" ]] || mismatch=1; done
    if (( mismatch )); then
        warn "the selected disks are NOT the same size:"
        for i in "${!devs[@]}"; do warn "    $(hr_size "${sizes[$i]}")  ${devs[$i]}"; done
        if [[ ${ALLOW_MIXED_SIZE-0} != 1 ]]; then
            die "this installer requires identical drives for the root mirror.
        Re-run with ALLOW_MIXED_SIZE=1 to size every partition to the smallest disk instead."
        fi
        warn "ALLOW_MIXED_SIZE=1: sizing every partition to the smallest disk"
    fi
}

settle () {
    udevadm trigger --subsystem-match=block 2>/dev/null || true
    udevadm settle --timeout=60 2>/dev/null || true
}

# Wait for device nodes to actually appear. The original installer ran mkfs
# straight after partitioning and hoped; on a fast machine the by-id symlinks
# are not there yet.
wait_for_nodes () {
    local tries=${WAIT_FOR_NODES_TRIES:-60} missing p
    while (( tries-- > 0 )); do
        missing=""
        for p in "$@"; do [[ -b $p ]] || missing="$p"; done
        [[ -n $missing ]] || { ok "device nodes present"; return 0; }
        settle
        sleep 1
    done
    die "timed out waiting for device node: $missing"
}

# Refuse to touch a disk that a currently imported pool is using.
assert_disks_free () {
    local inuse d pool
    inuse=$(zpool status -PL 2>/dev/null | grep -oE '/dev/[^ ]+' || true)
    for d in "$@"; do
        local real; real=$(readlink -f "$d")
        if grep -qF "$real" <<<"$inuse"; then
            pool=$(zpool status -PL 2>/dev/null | awk -v want="$real" '
                /^[[:space:]]*pool:/ {p=$2} index($0, want) {print p; exit}')
            die "$d is in use by imported pool '$pool'. Export it first: zpool export $pool"
        fi
    done
}

nuke_disk () { # nuke_disk /dev/disk/by-id/x
    local d=$1 p
    for p in "$d"-part*; do
        [[ -b $p ]] || continue
        wipefs -fa "$p" >/dev/null 2>&1 || true
        zpool labelclear -f "$p" >/dev/null 2>&1 || true
    done
    zpool labelclear -f "$d" >/dev/null 2>&1 || true
    sgdisk --zap-all "$d" >/dev/null
    wipefs -fa "$d" >/dev/null
    settle
}

# ------------------------------------------------------------ partitions ----

ESP_SIZE=2G                       # /boot per disk; holds configurationLimit generations
END_RESERVE_BYTES=$((1024*1024*1024))   # slack at end of every ZFS partition

# The single most common way to get stuck mid-recovery is a replacement disk
# that is a few MiB smaller than the original, so every ZFS partition stops
# END_RESERVE_BYTES short of the end of the smallest selected disk.
compute_zfs_end () { # compute_zfs_end disk... -> absolute last sector
    local lss min="" last d
    lss=$(disk_lss "$1")
    for d in "$@"; do
        last=$(sgdisk -E "$d" 2>/dev/null | tail -n1 | tr -dc '0-9')
        [[ -n $last ]] || die "cannot determine last usable sector of $d"
        if [[ -z $min || $last -lt $min ]]; then min=$last; fi
    done
    echo $(( min - END_RESERVE_BYTES / lss ))
}

# UEFI: p1 = ESP (vfat),        p2 = zfs
# BIOS: p1 = BIOS boot (2 MiB), p2 = /boot (ext4), p3 = zfs
set_part_numbers () { # set_part_numbers uefi|bios
    if [[ $1 == uefi ]]; then BOOTPART=1; ZFSPART=2; else BOOTPART=2; ZFSPART=3; fi
}

# Each disk is partitioned independently, so every GPT gets its own random disk
# and partition GUIDs. (The old installer cloned the table with
# `sfdisk --dump | sfdisk`, which duplicates label-id and every partition uuid.)
partition_boot_disk () { # partition_boot_disk uefi|bios disk end_sector
    local mode=$1 d=$2 end=$3
    if [[ $mode == uefi ]]; then
        sgdisk -a 2048 \
            -n1:1M:+"$ESP_SIZE" -t1:EF00 -c1:ESP \
            -n2:0:"$end"        -t2:BF01 -c2:zroot \
            "$d" >/dev/null
    else
        sgdisk -a 2048 \
            -n1:1M:+2M          -t1:EF02 -c1:BIOSboot \
            -n2:0:+"$ESP_SIZE"  -t2:8300 -c2:boot \
            -n3:0:"$end"        -t3:BF01 -c3:zroot \
            "$d" >/dev/null
    fi
    settle
}

part_path () { echo "$1-part$2"; }

boot_mount_point () { if [[ $1 -eq 0 ]]; then echo /boot; else echo "/boot-fallback-$1"; fi; }

# Mount points are stored per disk rather than derived from position, so
# dropping a dead disk does not renumber (and remount) the survivors.
next_free_mount_point () { # next_free_mount_point  (uses BOOT_MPS[])
    local n=0 mp used m
    while :; do
        mp=$(boot_mount_point "$n"); used=""
        for m in ${BOOT_MPS[@]+"${BOOT_MPS[@]}"}; do [[ $m == "$mp" ]] && used=1; done
        [[ -n $used ]] || { echo "$mp"; return; }
        n=$((n+1))
    done
}

# Distinct labels so /dev/disk/by-label/ does not collide between mirror halves.
mkfs_boot () { # mkfs_boot uefi|bios device label_index
    local mode=$1 dev=$2 n=$3
    if [[ $mode == uefi ]]; then
        # -F 32 explicitly: a 512 MiB ESP lands exactly on dosfstools'
        # FAT16/FAT32 auto-select boundary, and UEFI wants FAT32.
        mkfs.vfat -F 32 -n "ESP$n" "$dev" >/dev/null
    else
        mkfs.ext4 -q -F -L "boot$n" "$dev"
    fi
}

# --------------------------------------------------------- disk-layout.json --

# Consumed by disk-layout.nix via builtins.fromJSON. Written here by the
# installer and rewritten by replace-boot-disk.sh, so the Nix side stays a
# static file that ships in this repo.
write_disk_layout_json () { # write_disk_layout_json /path/to/disk-layout.json
    local out=$1 rows="" i mp
    for i in "${!BOOT_DISKS[@]}"; do
        mp=${BOOT_MPS[$i]-$(boot_mount_point "$i")}
        rows+="${BOOT_DISKS[$i]}"$'\t'"$BOOTPART"$'\t'"$ZFSPART"$'\t'"$mp"$'\n'
    done
    printf '%s' "$rows" | jq -R -s \
        --arg bootMode     "$BOOT_MODE" \
        --arg rootPool     "$ROOT_POOL" \
        --arg stateVersion "$STATE_VERSION" \
        --argjson dataPool "${DATA_POOL_JSON:-null}" '
        {
          version:      1,
          bootMode:     $bootMode,
          rootPool:     $rootPool,
          stateVersion: $stateVersion,
          bootDisks:    (split("\n") | map(select(length > 0)) | map(split("\t")) | map({
                           id:         .[0],
                           bootPart:   (.[1] | tonumber),
                           zfsPart:    (.[2] | tonumber),
                           mountPoint: .[3]
                         })),
          dataPool:     $dataPool
        }' > "$out"
    [[ -s $out ]] || die "failed to write $out"
}

read_disk_layout () { # read_disk_layout /path/to/disk-layout.json
    local f=$1
    [[ -r $f ]] || die "cannot read $f"
    BOOT_MODE=$(jq -r .bootMode "$f")
    ROOT_POOL=$(jq -r .rootPool "$f")
    STATE_VERSION=$(jq -r .stateVersion "$f")
    BOOTPART=$(jq -r '.bootDisks[0].bootPart' "$f")
    ZFSPART=$(jq -r '.bootDisks[0].zfsPart' "$f")
    DATA_POOL_JSON=$(jq -c .dataPool "$f")
    mapfile -t BOOT_DISKS < <(jq -r '.bootDisks[].id' "$f")
    mapfile -t BOOT_MPS   < <(jq -r '.bootDisks[].mountPoint' "$f")
    [[ ${#BOOT_DISKS[@]} -gt 0 ]] || die "$f lists no boot disks"
}
