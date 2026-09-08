#! /usr/bin/env nix-shell
#! nix-shell -i bash -p bash gptfdisk util-linux dosfstools e2fsprogs coreutils gawk jq
# shellcheck shell=bash

# Full bare-metal NixOS install onto an N-way ZFS root mirror.
#
#   Bring: this repo, your machine's unique.nix, and (if you use a data pool)
#          the ZFS key at /root/.zfs-encrypt.key. Nothing else.
#
# Run as root from a ZFS-capable NixOS live ISO. This DESTROYS every disk you
# select. See README.md.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ROOT_POOL=${ROOT_POOL:-zroot}
DATA_POOL=${DATA_POOL:-zdata}
KEYFILE=${KEYFILE:-/root/.zfs-encrypt.key}
MNT=/mnt

need_root
need_cmds sgdisk lsblk blockdev wipefs udevadm findmnt jq zpool zfs \
          mkfs.vfat mkfs.ext4 nixos-generate-config nixos-install

# ------------------------------------------------------- 1. unique.nix ------

hdr "Machine identity"

UNIQUE_NIX="$SCRIPT_DIR/unique.nix"
[[ -r $UNIQUE_NIX ]] || die "no unique.nix next to this script.
        This installer needs the machine's unique.nix to know its hostname and
        hostId. The hostId is stamped into the ZFS pool labels and MUST match
        the value the installed system will use."

HOSTNAME_=$(nix_attr "$UNIQUE_NIX" "networking.hostName")
HOSTID=$(nix_attr "$UNIQUE_NIX" "networking.hostId")

[[ -n $HOSTNAME_ ]] || die "unique.nix does not set networking.hostName"
[[ $HOSTID =~ ^[0-9a-fA-F]{8}$ ]] || die "unique.nix must set networking.hostId to 8 hex digits (got '${HOSTID:-<unset>}').
        Generate one with:  tr -dc 0-9a-f < /dev/urandom | head -c 8
        Keep it with the machine forever - the pool will not import without it."

info "hostname : $HOSTNAME_"
info "hostId   : $HOSTID"

# Do this before touching any pool. It makes the pool labels carry the right
# hostid from the start, and it lets us import a dirty pool from a machine that
# crashed without resorting to -f.
set_hostid "$HOSTID"

BOOT_MODE=$(detect_boot_mode)
set_part_numbers "$BOOT_MODE"
STATE_VERSION=$(nixos-version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' | head -n1 || true)
[[ -n $STATE_VERSION ]] || STATE_VERSION=25.05

info "firmware : $BOOT_MODE$([[ $BOOT_MODE == uefi ]] && echo ' (GRUB installed as removable: EFI/BOOT/BOOTX64.EFI)')"
info "release  : $STATE_VERSION"

# --------------------------------------------------- 2. clear the decks ------

hdr "Releasing anything currently mounted or imported"

mountpoint -q "$MNT" && umount -R "$MNT"
for p in "$ROOT_POOL" "$DATA_POOL"; do
    if zpool list -H -o name 2>/dev/null | grep -qx "$p"; then
        warn "pool '$p' is currently imported"
        confirm "Export '$p' so the disks can be examined?" || die "aborted"
        zpool export "$p"
    fi
done
ok "nothing mounted at $MNT"

# ------------------------------------------------------- 3. pick disks ------

scan_disks

hdr "Root mirror disks"
say "Pick at least 2 identical disks. Picking 3 or more builds a wider mirror
  (any N-1 of them may die). Every disk gets its own /boot, so the machine
  boots from whichever survives."

select_disks 2 "the root mirror ($ROOT_POOL)"
BOOT_DISKS=("${SELECTED[@]}")
BOOT_MPS=()
for i in "${!BOOT_DISKS[@]}"; do BOOT_MPS+=("$(boot_mount_point "$i")"); done

check_identical_disks "${BOOT_DISKS[@]}"
assert_disks_free "${BOOT_DISKS[@]}"

# ------------------------------------------------------- 4. data pool -------

DATA_POOL_JSON=null
DATA_MODE=skip
DATA_DISKS=()
DATA_DATASETS=()

hdr "Data pool ($DATA_POOL)"
say "  1) create a new encrypted $DATA_POOL  (destroys the disks you pick)
  2) import an existing $DATA_POOL          (recovering a machine whose data disks survived)
  3) skip - root mirror only"
ask DATA_CHOICE "choose" "3"

case $DATA_CHOICE in
  1) DATA_MODE=create ;;
  2) DATA_MODE=import ;;
  *) DATA_MODE=skip   ;;
esac

if [[ $DATA_MODE != skip ]]; then
    if [[ ! -f $KEYFILE ]]; then
        warn "no encryption key at $KEYFILE"
        if [[ $DATA_MODE == import ]]; then
            die "you cannot open an existing encrypted $DATA_POOL without it. Copy it to $KEYFILE and re-run."
        fi
        confirm "Generate a NEW random 32-byte key at $KEYFILE?" || die "aborted"
        (umask 077; dd if=/dev/urandom of="$KEYFILE" bs=32 count=1 status=none)
        warn "BACK UP $KEYFILE NOW. Without it $DATA_POOL is unrecoverable."
        confirm "Backed up?" || die "aborted"
    fi
    chmod 0400 "$KEYFILE"
fi

if [[ $DATA_MODE == create ]]; then
    select_disks 1 "the data pool ($DATA_POOL)" "${BOOT_DISKS[@]}"
    DATA_DISKS=("${SELECTED[@]}")
    assert_disks_free "${DATA_DISKS[@]}"
    [[ ${#DATA_DISKS[@]} -ge 2 ]] || warn "only one data disk: $DATA_POOL will NOT be redundant"
    ask DATA_DS_LIST "datasets to create (space separated)" "docker docker_apps"
    read -r -a DATA_DATASETS <<<"$DATA_DS_LIST"
fi

# ---------------------------------------------------------- 5. confirm ------

hdr "About to install"
cat <<SUMMARY
    hostname     : $HOSTNAME_ ($HOSTID)
    firmware     : $BOOT_MODE
    root pool    : $ROOT_POOL, ${#BOOT_DISKS[@]}-way mirror
SUMMARY
for i in "${!BOOT_DISKS[@]}"; do
    printf '                   %s  ->  %s\n' "${BOOT_DISKS[$i]}" "${BOOT_MPS[$i]}"
done
if [[ $BOOT_MODE == uefi ]]; then
    echo "    per disk     : p1 ESP ${ESP_SIZE} vfat, p2 zfs (leaving $(hr_size $END_RESERVE_BYTES) slack)"
else
    echo "    per disk     : p1 BIOS boot 2M, p2 /boot ${ESP_SIZE} ext4, p3 zfs (leaving $(hr_size $END_RESERVE_BYTES) slack)"
fi
case $DATA_MODE in
  create) echo "    data pool    : CREATE $DATA_POOL on ${DATA_DISKS[*]}"
          echo "                   datasets: ${DATA_DATASETS[*]}" ;;
  import) echo "    data pool    : IMPORT existing $DATA_POOL (not modified)" ;;
  skip)   echo "    data pool    : none" ;;
esac
echo
warn "EVERY disk listed above will be wiped."

confirm_hard "This is destructive and irreversible." "DESTROY"

# --------------------------------------------------- 6. partition + fs ------

hdr "Partitioning"

for d in "${BOOT_DISKS[@]}"; do
    info "wiping $d"
    nuke_disk "$d"
done

ZFS_END=$(compute_zfs_end "${BOOT_DISKS[@]}")
info "ZFS partitions end at sector $ZFS_END on every disk"

EXPECT=()
for d in "${BOOT_DISKS[@]}"; do
    partition_boot_disk "$BOOT_MODE" "$d" "$ZFS_END"
    EXPECT+=("$(part_path "$d" "$BOOTPART")" "$(part_path "$d" "$ZFSPART")")
done

wait_for_nodes "${EXPECT[@]}"

# Every ZFS partition must be byte-identical or the mirror is only as useful as
# its smallest member.
ref=""
for d in "${BOOT_DISKS[@]}"; do
    sz=$(blockdev --getsize64 "$(part_path "$d" "$ZFSPART")")
    [[ -n $ref ]] || ref=$sz
    [[ $sz == "$ref" ]] || die "ZFS partition size mismatch on $d ($sz vs $ref)"
done
ok "all ZFS partitions are $(hr_size "$ref")"

hdr "Boot filesystems"
for i in "${!BOOT_DISKS[@]}"; do
    dev=$(part_path "${BOOT_DISKS[$i]}" "$BOOTPART")
    mkfs_boot "$BOOT_MODE" "$dev" "$i"
    ok "$dev"
done

# ------------------------------------------------------- 7. root pool -------

hdr "Creating $ROOT_POOL"

VDEV=()
for d in "${BOOT_DISKS[@]}"; do VDEV+=("$(part_path "$d" "$ZFSPART")"); done

# lz4 rather than zstd on the root pool on purpose: GRUB's ZFS reader is the
# weakest link in the boot path and this is a recovery tool. The data pool uses
# zstd, where no bootloader ever has to read it.
zpool create -f \
    -o ashift=12 \
    -o autoexpand=on \
    -O mountpoint=none \
    -O atime=off \
    -O acltype=posixacl \
    -O xattr=sa \
    -O compression=lz4 \
    "$ROOT_POOL" mirror "${VDEV[@]}"

zfs create -o mountpoint=legacy "$ROOT_POOL/root"
zfs create -o mountpoint=legacy "$ROOT_POOL/root/nix"
zfs create -o mountpoint=legacy "$ROOT_POOL/root/home"
# A 100%-full ZFS pool cannot free space by deleting files. This buys you the
# room to dig yourself out.
zfs create -o mountpoint=none -o refreservation=2G "$ROOT_POOL/reserved"

hdr "Verifying the mirror"
zpool status "$ROOT_POOL"
zpool status "$ROOT_POOL" | grep -q "mirror-0" \
    || die "$ROOT_POOL is not a mirror - refusing to continue"
info "expected ${#BOOT_DISKS[@]} mirror members, all ONLINE"
confirm "Does the pool above look right?" || die "aborted"

# --------------------------------------------------------- 8. mount --------

hdr "Mounting at $MNT"
mount -t zfs "$ROOT_POOL/root" "$MNT"
mkdir -p "$MNT/nix" "$MNT/home"
mount -t zfs "$ROOT_POOL/root/nix"  "$MNT/nix"
mount -t zfs "$ROOT_POOL/root/home" "$MNT/home"
for i in "${!BOOT_DISKS[@]}"; do
    mp="$MNT${BOOT_MPS[$i]}"
    mkdir -p "$mp"
    mount "$(part_path "${BOOT_DISKS[$i]}" "$BOOTPART")" "$mp"
    ok "$mp"
done

# ------------------------------------------------------ 9. data pool -------

if [[ $DATA_MODE == create ]]; then
    hdr "Creating $DATA_POOL"
    for d in "${DATA_DISKS[@]}"; do nuke_disk "$d"; done
    settle
    layout=()
    [[ ${#DATA_DISKS[@]} -ge 2 ]] && layout=(mirror)
    zpool create -f \
        -o ashift=12 \
        -o autoexpand=on \
        -O mountpoint=none \
        -O atime=off \
        -O acltype=posixacl \
        -O xattr=sa \
        -O compression=zstd \
        -O encryption=on \
        -O keyformat=raw \
        -O keylocation="file://$KEYFILE" \
        "$DATA_POOL" ${layout[@]+"${layout[@]}"} "${DATA_DISKS[@]}"
    for ds in "${DATA_DATASETS[@]}"; do
        zfs create -o mountpoint=legacy "$DATA_POOL/$ds"
    done
    zpool status "$DATA_POOL"
fi

if [[ $DATA_MODE == import ]]; then
    hdr "Importing existing $DATA_POOL"
    zpool import -N -R "$MNT" "$DATA_POOL" \
        || die "could not import $DATA_POOL. If it belonged to a machine with a
        different hostId, import it manually with -f and re-run."
    zfs load-key -a || warn "some keys did not load - check $KEYFILE"
    zpool status "$DATA_POOL"
fi

if [[ $DATA_MODE != skip ]]; then
    # Only legacy-mountpoint datasets become fileSystems entries; datasets with
    # a native ZFS mountpoint are left for zfs-mount.service.
    rows=""
    while IFS=$'\t' read -r name mp; do
        [[ $name == "$DATA_POOL" ]] && continue
        [[ $mp == legacy ]] || continue
        rows+="$name"$'\t'"/mnt/${name#"$DATA_POOL"/}"$'\n'
    done < <(zfs list -H -o name,mountpoint -r -d 1 "$DATA_POOL")

    DATA_POOL_JSON=$(printf '%s' "$rows" | jq -R -s \
        --arg name "$DATA_POOL" --arg keyFile "$KEYFILE" '{
          name: $name,
          keyFile: $keyFile,
          datasets: (split("\n") | map(select(length > 0)) | map(split("\t"))
                     | map({ dataset: .[0], mountPoint: .[1] }))
        }')
    info "data pool mounts:"
    jq -r '.datasets[] | "      \(.dataset) -> \(.mountPoint)"' <<<"$DATA_POOL_JSON"

    install -Dm0400 "$KEYFILE" "$MNT$KEYFILE"
    ok "copied $KEYFILE into the installed system"
fi

# ---------------------------------------------------- 10. write config -----

hdr "Generating configuration"

# --no-filesystems: disk-layout.nix owns every fileSystems entry, generated
# from disk-layout.json, so the config is deterministic and survives a disk
# swap without regenerating hardware-configuration.nix.
nixos-generate-config --no-filesystems --root "$MNT"

install -Dm0644 "$SCRIPT_DIR/configuration.nix" "$MNT/etc/nixos/configuration.nix"
install -Dm0644 "$SCRIPT_DIR/disk-layout.nix"   "$MNT/etc/nixos/disk-layout.nix"
install -Dm0644 "$SCRIPT_DIR/zfs-health.nix"    "$MNT/etc/nixos/zfs-health.nix"
install -Dm0644 "$UNIQUE_NIX"                   "$MNT/etc/nixos/unique.nix"

write_disk_layout_json "$MNT/etc/nixos/disk-layout.json"
ok "wrote /etc/nixos/disk-layout.json"
jq . "$MNT/etc/nixos/disk-layout.json"

# Keep the tooling with the machine so a future disk swap does not need this ISO.
install -Dm0755 "$SCRIPT_DIR/replace-boot-disk.sh" "$MNT/etc/nixos/replace-boot-disk.sh"
install -Dm0755 "$SCRIPT_DIR/add-data-pool.sh"     "$MNT/etc/nixos/add-data-pool.sh"
install -Dm0644 "$SCRIPT_DIR/lib/common.sh"        "$MNT/etc/nixos/lib/common.sh"

confirm "Review /mnt/etc/nixos now if you want. Continue to nixos-install?" || die "stopped before install"

# -------------------------------------------------------- 11. install ------

hdr "Running nixos-install"
# NIXOS_INSTALL_ARGS is an escape hatch for automated runs, empty by default so
# a real install is unchanged. tests/vm-boot.sh sets --no-channel-copy: copying
# the channel means writing tens of thousands of small files into a fresh ZFS
# pool, which is by far the slowest step of an emulated install and has no
# bearing on whether the machine boots. Do not set it for a real machine --
# `nixos-rebuild` there should have a channel to work from.
# shellcheck disable=SC2086
nixos-install --root "$MNT" ${NIXOS_INSTALL_ARGS-}

# --------------------------------------------------------- 12. finish ------

hdr "Unmounting and exporting"
# Exporting matters: it clears the "in use by another system" flag, so the
# first boot imports cleanly with boot.zfs.forceImportRoot = false.
sync
umount -R "$MNT"
zpool export -a
ok "pools exported"

say ""
say "Done. Reboot into $HOSTNAME_."
say ""
info "Keep together, this is your whole recovery kit:"
info "  - this repo"
info "  - unique.nix (hostId $HOSTID - the pool will not import without it)"
[[ $DATA_MODE == skip ]] || info "  - $KEYFILE"
info ""
info "To replace a failed disk later, on the running machine:"
info "  sudo /etc/nixos/replace-boot-disk.sh"
