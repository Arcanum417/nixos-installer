#!/usr/bin/env bash

# Create or adopt an encrypted data pool on a machine that is already installed,
# and wire it into disk-layout.json so it is imported and mounted at boot.
#
#   ./add-data-pool.sh [--layout PATH]
#
# Replaces the old finish-me.sh / finish-me-bios.sh, which could only run as
# part of an install and always insisted on building a data pool.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

LAYOUT=/etc/nixos/disk-layout.json
DATA_POOL=${DATA_POOL:-zdata}
KEYFILE=${KEYFILE:-/root/.zfs-encrypt.key}

while [[ $# -gt 0 ]]; do
    case $1 in
        --layout) LAYOUT=$2; shift 2 ;;
        -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

need_root
need_cmds sgdisk lsblk blockdev wipefs udevadm findmnt jq zpool zfs

read_disk_layout "$LAYOUT"
CAN_REBUILD=0
[[ $LAYOUT == /etc/nixos/disk-layout.json ]] && CAN_REBUILD=1

if [[ $DATA_POOL_JSON != null ]]; then
    warn "$LAYOUT already describes a data pool:"
    jq . <<<"$DATA_POOL_JSON"
    confirm "Replace that entry?" || die "aborted"
fi

hdr "Data pool ($DATA_POOL)"
say "  1) create a new encrypted $DATA_POOL  (destroys the disks you pick)
  2) adopt an existing $DATA_POOL           (already imported, or importable now)"
ask CHOICE "choose" "1"

if [[ ! -f $KEYFILE ]]; then
    warn "no encryption key at $KEYFILE"
    [[ $CHOICE == 1 ]] || die "cannot open an existing encrypted pool without it"
    confirm "Generate a NEW random 32-byte key at $KEYFILE?" || die "aborted"
    (umask 077; dd if=/dev/urandom of="$KEYFILE" bs=32 count=1 status=none)
    warn "BACK UP $KEYFILE NOW. Without it $DATA_POOL is unrecoverable."
    confirm "Backed up?" || die "aborted"
fi
chmod 0400 "$KEYFILE"

if [[ $CHOICE == 1 ]]; then
    scan_disks
    select_disks 1 "the data pool ($DATA_POOL)" "${BOOT_DISKS[@]}"
    DATA_DISKS=("${SELECTED[@]}")
    assert_disks_free "${DATA_DISKS[@]}"
    [[ ${#DATA_DISKS[@]} -ge 2 ]] || warn "only one disk: $DATA_POOL will NOT be redundant"
    check_identical_disks "${DATA_DISKS[@]}"

    ask DS_LIST "datasets to create (space separated)" "docker docker_apps"
    read -r -a DATASETS <<<"$DS_LIST"

    confirm_hard "ERASE ${DATA_DISKS[*]} and create $DATA_POOL." "DESTROY"

    for d in "${DATA_DISKS[@]}"; do nuke_disk "$d"; done
    settle

    layout=()
    [[ ${#DATA_DISKS[@]} -ge 2 ]] && layout=(mirror)
    # zstd here: no bootloader ever reads this pool, so there is no reason to
    # stay on lz4 the way the root pool does.
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

    for ds in "${DATASETS[@]}"; do zfs create -o mountpoint=legacy "$DATA_POOL/$ds"; done
else
    if ! zpool list -H -o name 2>/dev/null | grep -qx "$DATA_POOL"; then
        hdr "Importing $DATA_POOL"
        zpool import -N "$DATA_POOL" || die "could not import $DATA_POOL"
    fi
    zfs load-key -a || warn "some keys did not load - check $KEYFILE"
fi

zpool status "$DATA_POOL"

# Only legacy-mountpoint datasets get fileSystems entries; anything with a
# native ZFS mountpoint is left to zfs-mount.service.
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

hdr "Mounts to be added"
jq -r '.datasets[] | "    \(.dataset) -> \(.mountPoint)"' <<<"$DATA_POOL_JSON"

write_disk_layout_json "$LAYOUT"
ok "updated $LAYOUT"

if [[ $CAN_REBUILD == 1 ]]; then
    hdr "nixos-rebuild switch"
    nixos-rebuild switch
    ok "done - datasets are mounted and will be imported at boot"
else
    warn "run 'nixos-rebuild switch' on the target system"
fi
